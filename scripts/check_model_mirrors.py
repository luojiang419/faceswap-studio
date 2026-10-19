"""只读检查外网模型的 HF 兼容镜像；不修改客户端清单或下载完整权重。"""
from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
USER_AGENT = 'Mozilla/5.0 (compatible; FaceFusion-MirrorAudit/1.0)'


def save(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', 'utf-8')
    temporary.replace(path)


class MirrorAudit:
    def __init__(self, endpoint, timeout, sample_bytes):
        parsed = urlparse(endpoint)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
            raise ValueError('镜像端点必须是无路径、无凭据的 HTTPS 地址')
        self.endpoint = endpoint.rstrip('/')
        self.timeout = timeout
        self.sample_bytes = sample_bytes
        self.limited = threading.Event()

    def open(self, url, **headers):
        if self.limited.is_set():
            raise RuntimeError('端点已返回429，本轮停止新增请求')
        # 匿名直连；无需读取登录凭据、系统代理或更改系统配置。
        opener = build_opener(ProxyHandler({}))
        request = Request(url, headers={'User-Agent': USER_AGENT, 'Accept-Encoding': 'identity', **headers})
        try:
            return opener.open(request, timeout=self.timeout)
        except HTTPError as error:
            if error.code == 429:
                self.limited.set()
            raise

    @staticmethod
    def error(error):
        result = {'error': str(error)}
        if isinstance(error, HTTPError):
            result.update(http_status=error.code, retry_after=error.headers.get('Retry-After'))
            # 只保留有限诊断文本，不保存包含签名凭据的 CDN Location。
            result['response'] = error.read(1024).decode('utf-8', errors='replace')
            error.close()
        return result

    def tree(self, base, commit):
        url = f'{self.endpoint}/api/models/facefusion/{base}/tree/{commit}?recursive=true&expand=false'
        with self.open(url) as response:
            if 'json' not in response.headers.get('Content-Type', ''):
                raise ValueError('仓库接口返回了非JSON内容')
            content = response.read(4 * 1024**2 + 1)
            if len(content) > 4 * 1024**2:
                raise ValueError('仓库目录超过探测上限')
            records = json.loads(content)
            if not isinstance(records, list) or len(records) >= 1000 or response.headers.get('Link'):
                raise ValueError('仓库目录非完整单页，禁止静默漏项')
        return {item['path']: item for item in records if item.get('type') == 'file'}

    def probe(self, asset, metadata):
        result = {key: asset[key] for key in ('id', 'size', 'sha256', 'upstream_commit')}
        url = self.endpoint + asset['upstream_url'].removeprefix('https://huggingface.co')
        result.update(url=url, metadata_verified=False, range_verified=False, full_sha256_verified=False)
        started = time.monotonic()
        try:
            base, name = asset['id'].split('/', 1)
            tree = metadata[(base, asset['upstream_commit'])]
            if isinstance(tree, Exception):
                raise RuntimeError('固定提交目录不可用：' + str(tree))
            record = tree.get(name, {})
            if record.get('size') != asset['size'] or record.get('lfs', {}).get('oid') != asset['sha256']:
                raise ValueError('镜像文件大小或LFS SHA-256与固定清单不一致')
            result['metadata_verified'] = True
            samples = []
            result['samples'] = samples
            for start in (0, max(0, asset['size'] - self.sample_bytes)):
                end = min(asset['size'] - 1, start + self.sample_bytes - 1)
                with self.open(url, Range=f'bytes={start}-{end}') as response:
                    expected = f'bytes {start}-{end}/{asset["size"]}'
                    if response.status != 206 or response.headers.get('Content-Range') != expected:
                        raise ValueError('文件未返回精确的206/Content-Range：' + str(response.headers.get('Content-Range')))
                    content = response.read(end - start + 2)
                    if len(content) != end - start + 1:
                        raise ValueError('文件分段被截断或超过请求范围')
                    samples.append({'offset': start, 'size': len(content),
                                    'sha256': hashlib.sha256(content).hexdigest(),
                                    'final_host': urlparse(response.url).hostname,
                                    'content_range': response.headers['Content-Range']})
            result['range_verified'] = True
        except Exception as error:
            result.update(self.error(error))
        result['seconds'] = round(time.monotonic() - started, 2)
        return result


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', action='append', help='可重复；默认检查AI快站与HF-Mirror')
    parser.add_argument('--catalog', type=Path, default=ROOT / 'facefusion/model_catalog.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/domestic-mirror-audit')
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=2)
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--sample-bytes', type=int, default=16384)
    parser.add_argument('--limit', type=int, help='仅探测前N项；报告保留总项数，避免冒充全量')
    args = parser.parse_args()
    if args.timeout <= 0 or not 1 <= args.sample_bytes <= 1024**2 or (args.limit is not None and args.limit <= 0):
        parser.error('timeout/limit必须为正；sample-bytes须介于1字节和1MiB')
    catalog = json.loads(args.catalog.read_text('utf-8-sig'))
    all_assets = [a for a in catalog['assets'] if a.get('download_origin') == 'external']
    assets = all_assets[:args.limit] if args.limit else all_assets
    for asset in assets:
        parsed = urlparse(asset['upstream_url'])
        if parsed.scheme != 'https' or parsed.hostname != 'huggingface.co' or parsed.username or f'/resolve/{asset["upstream_commit"]}/' not in parsed.path:
            parser.error('清单必须使用原始HF固定提交')
    for endpoint in args.endpoint or ['https://aifasthub.com', 'https://hf-mirror.com']:
        audit = MirrorAudit(endpoint, args.timeout, args.sample_bytes)
        path = args.output / (urlparse(endpoint).hostname + '.json')
        report = {'checked_at': datetime.now(timezone(timedelta(hours=8))).isoformat(),
                  'endpoint': audit.endpoint, 'proxy': 'disabled', 'anonymous': True,
                  'catalog_sha256': hashlib.sha256(args.catalog.read_bytes()).hexdigest(),
                  'external_asset_count': len(all_assets), 'selected_asset_count': len(assets),
                  'sample_bytes': args.sample_bytes, 'assets': []}
        metadata = {}
        for base, commit in sorted({(a['id'].split('/')[0], a['upstream_commit']) for a in assets}):
            try:
                metadata[(base, commit)] = audit.tree(base, commit)
            except Exception as error:
                metadata[(base, commit)] = error
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(audit.probe, a, metadata) for a in assets]
            for future in as_completed(futures):
                result = future.result()
                report['assets'].append(result)
                report['assets'].sort(key=lambda a: a['id'])
                report['summary'] = {'completed': len(report['assets']),
                                     'metadata_verified': sum(a['metadata_verified'] for a in report['assets']),
                                     'range_verified': sum(a['range_verified'] for a in report['assets']),
                                     'http_errors': dict(Counter(str(a['http_status']) for a in report['assets'] if 'http_status' in a)),
                                     'rate_limited': audit.limited.is_set()}
                save(path, report)
                print(f'{audit.endpoint} {len(report["assets"])}/{len(assets)} ' + result['id'] +
                      (' OK' if result['range_verified'] else ' FAIL: ' + result['error']), flush=True)
        print(json.dumps(report.get('summary', {}), ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
