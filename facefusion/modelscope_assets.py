"""当前版本模型的固定魔搭清单、续传下载与完整性验证。"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from functools import lru_cache
from http.client import HTTPException
from pathlib import Path, PurePosixPath
from typing import Callable
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import ProxyHandler, Request, build_opener


def file_sha256(path: Path) -> str:
	with path.open('rb') as stream:
		return hashlib.file_digest(stream, 'sha256').hexdigest()


@lru_cache(maxsize=1)
def catalog() -> dict:
	path = Path(__file__).with_name('model_catalog.json')
	if not path.exists():
		return {}
	value = json.loads(path.read_text('utf-8-sig'))
	if value.get('protocol') != 1 or value.get('product') != 'facefusion-models':
		raise ValueError('模型清单协议无效')
	records = {}
	for item in value['assets']:
		key = item['id']
		parts = PurePosixPath(key).parts
		parsed = urlparse(item['url'])
		if len(parts) != 2 or any(not re.fullmatch(r'[A-Za-z0-9_.-]+', p) or p in ('.', '..') for p in parts):
			raise ValueError('模型清单路径无效')
		if key in records or not isinstance(item['size'], int) or item['size'] <= 0 or not re.fullmatch(r'[a-f0-9]{64}', item['sha256']):
			raise ValueError('模型清单大小、哈希或重复项无效')
		if parsed.scheme != 'https' or parsed.hostname != 'modelscope.cn' or parsed.username:
			raise ValueError('模型清单下载地址必须使用魔搭HTTPS')
		records[key] = item
	return records


def get_asset(base_name: str, file_name: str) -> dict | None:
	return catalog().get(base_name + '/' + file_name)


@lru_cache(maxsize=1)
def _urls() -> dict:
	return {item['url']: item for item in catalog().values()}


def asset_for_url(url: str) -> dict | None:
	return _urls().get(url)


def download_file(url: str, destination: Path, *, size: int, sha256: str,
				  opener=None, progress: Callable[[int, int], None] | None = None,
				  allow_http: bool = False) -> Path:
	"""固定大小/SHA的有界下载；中断保留分片，完成后原子替换。"""
	parsed = urlparse(url)
	if parsed.scheme != 'https' and not (allow_http and parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost')):
		raise ValueError('模型下载必须使用HTTPS')
	if not isinstance(size, int) or size <= 0 or not re.fullmatch(r'[a-f0-9]{64}', sha256):
		raise ValueError('模型下载元数据无效')
	destination = Path(destination)
	destination.parent.mkdir(parents=True, exist_ok=True)
	if destination.is_file() and destination.stat().st_size == size and file_sha256(destination) == sha256:
		if progress:
			progress(size, size)
		return destination
	partial = destination.with_name(destination.name + '.part')
	offset = partial.stat().st_size if partial.exists() else 0
	if offset > size:
		partial.unlink()
		offset = 0
	if shutil.disk_usage(destination.parent).free < size - offset + 16 * 1024**2:
		raise OSError('模型目录空间不足，已保留现有文件和下载分片')
	opener = opener or build_opener(ProxyHandler())
	failures = 0
	while offset < size:
		before = offset
		try:
			# 有界分段避免代理/CDN长期占住整个大文件连接。
			end = min(size - 1, offset + 64 * 1024**2 - 1)
			request = Request(url, headers={'Range': f'bytes={offset}-{end}', 'Accept-Encoding': 'identity', 'User-Agent': 'FaceFusion-ModelScope/1.0'})
			with opener.open(request, timeout=60) as response:
				if response.status == 206:
					match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
					if not match or int(match[1]) != offset or int(match[3]) != size or not offset <= int(match[2]) < size:
						raise ValueError('模型服务器断点范围无效')
				elif response.status == 200:
					offset = 0
				else:
					raise ValueError('模型服务器响应状态无效')
				with partial.open('ab' if offset else 'wb') as stream:
					read = getattr(response, 'read1', response.read)
					while chunk := read(512 * 1024):
						if offset + len(chunk) > size:
							raise ValueError('模型文件超过清单声明大小')
						stream.write(chunk)
						offset += len(chunk)
						if progress:
							progress(offset, size)
					stream.flush()
		except (OSError, URLError, HTTPException):
			failures += 1
			if failures >= 3:
				raise
		offset = partial.stat().st_size if partial.exists() else 0
		if offset <= before:
			failures += 1
			if failures >= 3:
				raise OSError('模型下载多次没有进展，已保留分片，可稍后重试')
		else:
			failures = 0
	if file_sha256(partial) != sha256:
		partial.unlink(missing_ok=True)
		raise ValueError('模型SHA-256校验失败')
	os.replace(partial, destination)
	if progress:
		progress(size, size)
	return destination


def download_asset(asset: dict, destination: Path, progress=None, opener=None) -> Path:
	return download_file(asset['url'], destination, size=asset['size'], sha256=asset['sha256'], progress=progress, opener=opener)
