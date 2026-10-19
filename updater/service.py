"""Flutter/Bridge 的魔搭签名更新客户端；事务实现复用 VoxCPM。"""
from __future__ import annotations

from http.client import HTTPException
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, build_opener, ProxyHandler

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from updater.transaction import read_json, write_json, sha256, version, safe_path, alive


def permitted_url(url):
    parsed = urlparse(url)
    if parsed.scheme == 'https' and parsed.hostname == 'modelscope.cn' and not parsed.username:
        return
    if os.environ.get('FACESWAP_STUDIO_UPDATE_TEST') == '1' and parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost'):
        return
    raise ValueError('更新地址必须使用魔搭 HTTPS')


def verify_envelope(envelope, public_key):
    Ed25519PublicKey.from_public_bytes(bytes.fromhex(public_key)).verify(
        bytes.fromhex(envelope['signature']), envelope['payload'].encode('utf-8'))
    manifest = json.loads(envelope['payload'])
    if (manifest.get('protocol'), manifest.get('product'), manifest.get('platform')) != (1, 'faceswap-studio', 'win32-x64'):
        raise ValueError('更新清单与当前产品不兼容')
    version(manifest['version']); version(manifest['minVersion'])
    if not re.fullmatch(r'\d{14}', manifest.get('releaseId', '')):
        raise ValueError('更新发布序号无效')
    package = manifest['package']
    permitted_url(package['url'])
    if not isinstance(package['size'], int) or not 0 < package['size'] <= 2 * 1024**3 or not re.fullmatch('[a-f0-9]{64}', package['sha256']):
        raise ValueError('更新包元数据无效')
    installer = manifest.get('installer')
    if installer:
        permitted_url(installer['url'])
        if not isinstance(installer['size'], int) or not 0 < installer['size'] <= 16 * 1024**2 or not re.fullmatch('[a-f0-9]{64}', installer['sha256']):
            raise ValueError('安装维护入口元数据无效')
    if not manifest['files'] or len(manifest['files']) > 20000:
        raise ValueError('更新文件清单无效')
    names = set()
    for record in manifest['files']:
        name = safe_path(record['path']).lower()
        if name in names:
            raise ValueError('重复的更新文件')
        names.add(name)
    return manifest


class UpdateService:
    def __init__(self, root, logger=lambda message: None):
        self.root = Path(root)
        self.log = logger
        self.lock = threading.RLock()
        self.worker = None
        self.envelope = None
        self.session = None
        self.prompt_pid = None
        self.prompted_release = None
        self.state = {'state': 'idle', 'message': '通过魔搭检查软件更新。', 'current_version': self.current_version,
                      'update_available': False, 'delta_available': False, 'percent': 0, 'error': None}

    @property
    def current_version(self):
        return (self.root / 'VERSION').read_text('utf-8-sig').strip()

    @property
    def config(self):
        return read_json(self.root / 'update-config.json')

    @property
    def cache(self):
        return self.root / 'faceswap studio/data/cache/updates'

    def status(self):
        with self.lock:
            return dict(self.state)

    def set(self, **values):
        with self.lock:
            self.state.update(values)
        return self.status()

    def check(self):
        with self.lock:
            if self.state['state'] in ('checking', 'downloading', 'applying'):
                return dict(self.state)
            self.state.update(state='checking', message='正在检查魔搭更新…', error=None)
        try:
            config = self.config
            url = os.environ.get('FACESWAP_STUDIO_UPDATE_MANIFEST_URL', config['manifestUrl'])
            permitted_url(url)
            with build_opener(ProxyHandler({})).open(Request(url, headers={'Accept': 'application/json'}), timeout=25) as response:
                envelope = json.loads(response.read(16 * 1024**2).decode('utf-8-sig'))
            manifest = verify_envelope(envelope, config['publicKey'])
            newer = (version(manifest['version']), manifest['releaseId']) > (version(self.current_version), config['releaseId'])
            compatible = version(self.current_version) >= version(manifest['minVersion'])
            with self.lock:
                self.envelope = envelope
            return self.set(state=('update_available' if compatible else 'full_required') if newer else 'current',
                            message='发现新的软件更新。' if newer else '当前已是最新版本。', current_version=self.current_version,
                            latest_version=manifest['version'], release_id=manifest['releaseId'], notes=manifest.get('notes', ''),
                            update_available=newer, delta_available=newer and compatible, manifest=manifest,
                            total_bytes=manifest['package']['size'], asset_name=manifest['package']['name'],
                            release_url=f"https://modelscope.cn/models/{config['repository']}", error=None)
        except Exception as error:
            self.log(f'[update] {error}')
            return self.set(state='failed', message='检查更新失败，可稍后重试。', error=str(error), update_available=False, delta_available=False)

    def download(self):
        with self.lock:
            if self.worker and self.worker.is_alive():
                return dict(self.state)
            if not self.envelope or not self.state.get('delta_available'):
                return dict(self.state)
            self.state.update(state='downloading', message='正在从魔搭下载更新…', error=None)
            self.worker = threading.Thread(target=self._download, daemon=True)
            self.worker.start()
            return dict(self.state)

    def offer(self, automatic=False):
        """先打开独立选择窗口，不下载、不关闭当前工作台。"""
        with self.lock:
            if not self.envelope or not self.state.get('delta_available'):
                return self.status()
            manifest = verify_envelope(self.envelope, self.config['publicKey'])
            release = manifest['releaseId']
            if (self.prompt_pid and alive(self.prompt_pid)) or (automatic and self.prompted_release == release):
                return {**self.status(), 'native_prompt_opened': True}
            try:
                session = self.cache / release
                session.mkdir(parents=True, exist_ok=True)
                config = self.config
                write_json(session / 'envelope.json', self.envelope)
                write_json(session / 'prompt.json', {
                    'root': str(self.root.resolve()), 'session': str(session.resolve()),
                    'current_version': self.current_version, 'latest_version': manifest['version'],
                    'release_id': release, 'notes': manifest.get('notes', ''),
                    'bridge_url': 'http://127.0.0.1:' + str(int(os.environ.get('FACESWAP_STUDIO_BRIDGE_PORT', '52741'))),
                })
                write_json(session / 'session.json', {
                    'root': str(self.root.resolve()), 'session': str(session.resolve()),
                    'publicKey': config['publicKey'], 'currentVersion': self.current_version,
                    'currentReleaseId': config['releaseId'],
                    'parentPid': int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.environ.get('FACESWAP_STUDIO_LAUNCHER_PID', os.getpid()))),
                })
                for source, name in ((self.root / 'updater/offer.py', 'offer.py'),
                                     (self.root / 'FaceSwapStudioUpdater.exe', 'FaceSwapStudioUpdater.exe')):
                    shutil.copy2(source, session / name)
                # 更新过程不依赖正在被覆盖的安装目录里的执行模块。
                (session / 'updater').mkdir(exist_ok=True)
                for name in ('__init__.py', 'service.py', 'transaction.py'):
                    shutil.copy2(self.root / 'updater' / name, session / 'updater' / name)
                helper = subprocess.run([
                    sys.executable, '-c',
                    'import subprocess,sys; p=subprocess.Popen(sys.argv[1:],creationflags=0x208); print(p.pid)',
                    str(session / 'FaceSwapStudioUpdater.exe'), '--offer', str(session), sys.executable,
                ], check=True, capture_output=True, text=True,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                self.prompt_pid = int(helper.stdout.strip())
                self.prompted_release = release
                return {**self.status(), 'native_prompt_opened': True, 'updater_pid': self.prompt_pid}
            except Exception as error:
                self.log(f'[update] 独立更新提示启动失败：{error}')
                return {**self.status(), 'native_prompt_opened': False, 'error': str(error)}

    def _download(self):
        try:
            manifest = verify_envelope(self.envelope, self.config['publicKey'])
            self.session = self.cache / manifest['releaseId']
            self.session.mkdir(parents=True, exist_ok=True)
            write_json(self.session / 'envelope.json', self.envelope)
            package = manifest['package']; part = self.session / 'package.part'; target = self.session / 'package.zip'
            if not (target.exists() and target.stat().st_size == package['size'] and sha256(target) == package['sha256']):
                offset = part.stat().st_size if part.exists() else 0
                if offset > package['size']:
                    part.unlink(); offset = 0
                started = time.monotonic(); initial = offset; failures = 0
                while offset < package['size']:
                    before = offset
                    try:
                        headers = {'Range': f'bytes={offset}-', 'Accept-Encoding': 'identity'}
                        with build_opener(ProxyHandler({})).open(Request(package['url'], headers=headers), timeout=45) as response:
                            if response.status == 206:
                                match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                                if not match or int(match[1]) != offset or int(match[3]) != package['size'] or not offset <= int(match[2]) < package['size']:
                                    raise ValueError('下载断点响应不匹配')
                            elif response.status == 200:
                                offset = initial = 0
                            else:
                                raise ValueError('下载返回了无效的响应状态')
                            with part.open('ab' if offset else 'wb') as stream:
                                while chunk := response.read(256 * 1024):
                                    offset += len(chunk)
                                    if offset > package['size']:
                                        raise ValueError('下载超过签名大小')
                                    stream.write(chunk)
                                    self.set(downloaded_bytes=offset, total_bytes=package['size'], percent=offset * 100 / package['size'],
                                             speed_bps=(offset - initial) / max(.01, time.monotonic() - started))
                    except (OSError, URLError, HTTPException):
                        # 网络提前断开时，文件上下文已关闭，直接从实际写入位置续接。
                        failures += 1
                        if failures >= 3:
                            raise
                    offset = part.stat().st_size if part.exists() else 0
                    if offset <= before:
                        failures += 1
                        if failures >= 3:
                            raise OSError('更新下载多次中断，已保留断点，请稍后重试')
                    elif offset > before:
                        failures = 0
                if sha256(part) != package['sha256']:
                    part.unlink(missing_ok=True)
                    raise ValueError('下载文件 SHA-256 校验失败，请重试')
                os.replace(part, target)
            return self.set(state='downloaded', message='签名与更新包校验通过，可以安装。', package_path=str(target), percent=100, error=None)
        except Exception as error:
            return self.set(state='failed', message='更新下载失败，已保留可恢复分片。', error=str(error))

    def apply(self, scheduled=False):
        try:
            if self.state['state'] != 'downloaded' or self.session is None:
                raise ValueError('请先下载并验证更新包')
            config = self.config
            write_json(self.session / 'session.json', {'root': str(self.root), 'session': str(self.session),
                       'publicKey': config['publicKey'], 'currentVersion': self.current_version,
                       'currentReleaseId': config['releaseId'], 'parentPid': int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.environ.get('FACESWAP_STUDIO_LAUNCHER_PID', os.getpid())))})
            # 复制独立窗口/事务脚本到会话，避免安装期间覆盖正在执行的更新器。
            shutil.copy2(self.root / 'updater/transaction.py', self.session / 'transaction.py')
            shutil.copy2(self.root / 'FaceSwapStudioUpdater.exe', self.session / 'FaceSwapStudioUpdater.exe')
            runner = {'session': str(self.session), 'python': str(Path(sys.executable)), 'root': str(self.root)}
            write_json(self.cache / 'scheduled.json', runner)
            if scheduled:
                return self.set(scheduled_for_next_launch=True, message='将在下次启动时安装更新。')
            # 用短生命周期父进程启动窗口。主启动器会清理 Bridge 的整棵进程树，
            # 直接作为 Bridge 子进程的更新器也会被一起关闭。
            helper = subprocess.run([
                sys.executable, '-c',
                'import subprocess,sys; p=subprocess.Popen(sys.argv[1:],creationflags=0x208); print(p.pid)',
                str(self.session / 'FaceSwapStudioUpdater.exe'), str(self.session), sys.executable,
            ], check=True, capture_output=True, text=True,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            updater_pid = int(helper.stdout.strip())
            self.cache.joinpath('scheduled.json').unlink(missing_ok=True)
            return self.set(state='applying', message='独立更新器已启动，正在退出工作台…', updater_pid=updater_pid)
        except Exception as error:
            return self.set(state='failed', message='更新程序未能启动。', error=str(error))
