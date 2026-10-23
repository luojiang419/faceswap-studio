"""隔离验收全量包；仅操作 build/full-offline-validation 内的专用测试安装。"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/full-offline-validation'
INSTALL = WORK / '中文安装/易容 Studio'
COMPILER = 'C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe'
SESSION = '0123456789abcdef0123456789abcdef'


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), 'utf-8')


def environment():
    env = dict(os.environ)
    for key in list(env):
        if key.upper().startswith(('CUDA_PATH', 'PYTHONPATH', 'PYTHONHOME')):
            env.pop(key)
    env.update(PYTHONIOENCODING='utf-8', PYTHONDONTWRITEBYTECODE='1',
               FACESWAP_STUDIO_ISOLATED='1', FACESWAP_STUDIO_BRIDGE_HOST='127.0.0.1',
               FACESWAP_STUDIO_BRIDGE_PORT='52782', FACESWAP_STUDIO_DATA_ROOT=str(INSTALL / 'data'),
               FACESWAP_STUDIO_INSTALL_REPORT=str(INSTALL / 'data/cache/install' / (SESSION + '.json')),
               FACESWAP_STUDIO_INSTALL_SESSION=SESSION)
    windows = os.environ.get('SystemRoot', 'C:\\Windows')
    env['PATH'] = os.pathsep.join([str(INSTALL / '.venv-win/Scripts'), str(INSTALL / '.python'),
                                  str(Path(windows) / 'System32'), windows])
    return env


def native(distribution, mode):
    executable = distribution / '易容 Studio 全量安装器.exe'
    helper = distribution / '.NativeSmoke.exe'
    if mode in ('prepare', 'refresh', 'complete') or not helper.is_file():
        subprocess.run([COMPILER, '/nologo', '/target:exe', '/out:' + str(helper),
                        '/win32manifest:' + str(ROOT / 'installer/bootstrap/app.manifest'),
                        '/reference:' + str(executable), '/reference:System.Web.Extensions.dll',
                        str(ROOT / 'installer/bootstrap/OfflineSmoke.cs')], check=True)
    subprocess.run([str(helper), mode, str(INSTALL), str(executable), str(WORK)], check=True)


def prepare(distribution, refresh=False):
    WORK.mkdir(parents=True, exist_ok=True)
    if refresh != 'resume':
        native(distribution, 'refresh' if refresh else 'prepare')
    env = environment()
    python = INSTALL / '.venv-win/Scripts/python.exe'
    subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    str(INSTALL / 'scripts/repair_runtime.ps1'), '-Root', str(INSTALL)], env=env, check=True)
    subprocess.run([str(python), '-m', 'pip', 'check'], env=env, cwd=INSTALL, check=True)
    subprocess.run([str(python), str(ROOT / 'scripts/verify_offline_gpu.py'), '--root', str(INSTALL),
                    '--report', str(WORK / 'gpu.json')], env=env, cwd=INSTALL, check=True)
    write(INSTALL / 'faceswap studio/runtime/settings.json', {'facefusion_port': 17860, 'model_download_mode': 'domestic'})
    proof = INSTALL / 'faceswap studio/data/output/proof.txt'
    proof.parent.mkdir(parents=True, exist_ok=True)
    proof.write_text('隔离验收作品保留凭证', 'utf-8')
    report = INSTALL / 'data/cache/install' / (SESSION + '.json')
    report.unlink(missing_ok=True)
    log = (WORK / 'desktop.log').open('w', encoding='utf-8')
    desktop = subprocess.Popen([str(python), str(INSTALL / 'launch_faceswap_studio.py')],
                               env=env, cwd=INSTALL, stdout=log, stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    write(WORK / 'processes.json', {'desktopPid': desktop.pid})
    opener = build_opener(ProxyHandler({}))
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if desktop.poll() is not None:
            raise RuntimeError('隔离桌面提前退出，请查看 desktop.log')
        try:
            with opener.open('http://127.0.0.1:52782/facefusion/status', timeout=2) as response:
                status = json.load(response)
            write(WORK / 'core-status.json', status)
            if report.is_file() and status.get('state') == 'ready':
                break
        except OSError:
            pass
        time.sleep(.5)
    else:
        raise RuntimeError('桌面首帧/核心 ready 未在 180 秒内同时就绪')
    native(distribution, 'complete')
    if (INSTALL / 'data/cache/bootstrap').exists():
        raise AssertionError('离线安装不应缓存大运行包')
    proc = subprocess.Popen([str(python), str(INSTALL / 'scripts/launch_original_webui.py'),
                             '--port', '17861', '--no-browser'], env=env, cwd=INSTALL,
                            stdout=(WORK / 'original-webui.log').open('w', encoding='utf-8'),
                            stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
    write(WORK / 'processes.json', {'desktopPid': desktop.pid, 'webuiPid': proc.pid})
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError('原版 WebUI 提前退出，请查看 original-webui.log')
        try:
            with opener.open('http://127.0.0.1:17861/config', timeout=2) as response:
                config = json.load(response)
            write(WORK / 'webui-config.json', config)
            write(WORK / 'runtime-verification.json', {'ok': True, 'root': str(INSTALL),
                   'firstFrameReport': json.loads(report.read_text('utf-8-sig')), 'core': status,
                   'originalWebuiUrl': 'http://127.0.0.1:17861/', 'bootstrapCacheCreated': False})
            print('实际离线展开、首帧握手、核心 ready、原版 WebUI HTTP 就绪。', flush=True)
            return
        except OSError:
            time.sleep(.5)
    raise RuntimeError('原版 WebUI 未就绪')


def stop():
    import psutil
    processes = []
    for process in psutil.process_iter(['pid', 'exe']):
        try:
            if process.info['exe'] and Path(process.info['exe']).resolve().is_relative_to(INSTALL):
                processes.append(process)
        except (psutil.Error, OSError):
            pass
    for process in processes:
        try:
            process.terminate()
        except psutil.Error:
            pass
    _, alive = psutil.wait_procs(processes, timeout=15)
    if alive:
        raise RuntimeError('隔离安装仍有进程未退出；不修改其他安装')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--distribution', type=Path, required=True)
    parser.add_argument('--phase', choices=['prepare', 'refresh', 'resume', 'stop', 'remove'], default='prepare')
    args = parser.parse_args()
    if args.phase in ('prepare', 'refresh', 'resume'):
        prepare(args.distribution.resolve(), 'resume' if args.phase == 'resume' else args.phase == 'refresh')
    else:
        stop()
        if args.phase == 'remove':
            native(args.distribution.resolve(), 'remove')
