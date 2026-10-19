"""独立更新窗口的选择执行器；延后选择不要求提前下载。"""
from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import sys
import subprocess
from urllib.parse import urlparse
from urllib.request import build_opener, ProxyHandler
import json


def load_offer(session):
    from updater.transaction import read_json
    from updater.service import verify_envelope
    session = Path(session).resolve(strict=True)
    prompt = read_json(session / 'prompt.json')
    root = Path(prompt['root']).resolve(strict=True)
    config = read_json(root / 'update-config.json')
    manifest = verify_envelope(read_json(session / 'envelope.json'), config['publicKey'])
    if session != (root / 'faceswap studio/data/cache/updates' / manifest['releaseId']).resolve():
        raise ValueError('更新选择会话不属于当前安装')
    settings = read_json(session / 'session.json')
    if Path(settings['root']).resolve() != root or settings['publicKey'] != config['publicKey']:
        raise ValueError('更新选择的安装身份不匹配')
    return root, prompt, manifest


def close_studio(root, bridge_url):
    """先检查队列，再经现有托盘退出命令正常关闭本安装的前端。"""
    import psutil
    frontends = []
    expected = (root / 'faceswap studio/runtime/windows_app/current/faceswap_studio.exe').resolve()
    for process in psutil.process_iter(['exe']):
        try:
            if process.info['exe'] and Path(process.info['exe']).resolve() == expected:
                frontends.append(process)
        except (OSError, psutil.Error):
            pass
    parsed = urlparse(bridge_url)
    if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.username or parsed.path:
        raise ValueError('更新队列检查地址无效')
    try:
        with build_opener(ProxyHandler({})).open(bridge_url + '/queue/tasks', timeout=5) as response:
            queue = json.load(response)
        if queue['runner']['active'] or any(t.get('status') in ('running', 'processing') for t in queue.get('tasks', [])):
            raise RuntimeError('生成任务正在运行，请完成或取消任务后再更新。')
    except OSError:
        if frontends:
            raise RuntimeError('无法确认生成队列状态，暂不退出工作台。')
    if not frontends:
        return
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_ssize_t)
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
    user32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
    pids = {p.pid for p in frontends}
    sent = set()
    @callback_type
    def visit(window, _):
        pid = ctypes.c_ulong(); user32.GetWindowThreadProcessId(window, ctypes.byref(pid))
        name = ctypes.create_unicode_buffer(256); user32.GetClassNameW(window, name, len(name))
        if pid.value in pids and name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
            if user32.PostMessageW(window, 0x0111, 1002, 0): sent.add(pid.value)
        return True
    user32.EnumWindows(visit, 0)
    if sent != pids:
        raise RuntimeError('无法正常退出工作台，请从托盘退出后重试。')
    _, remaining = psutil.wait_procs(frontends, timeout=30)
    if remaining:
        raise RuntimeError('工作台尚未正常退出，未开始下载或安装更新。')


def launch_studio(root):
    executable = root / '易容 Studio.exe'
    if not executable.is_file():
        executable = root / '启动FaceSwap Studio.exe'
    env = {k: v for k, v in os.environ.items() if k not in (
        'FACESWAP_STUDIO_UPDATE_SESSION', 'FACESWAP_STUDIO_UPDATE_HEALTH_FILE', 'FACESWAP_STUDIO_UPDATE_TOKEN',
        'FACESWAP_STUDIO_WRAPPER_PID', 'FACESWAP_STUDIO_LAUNCHER_PID', 'FACESWAP_STUDIO_UPDATER_PID',
        'FACESWAP_STUDIO_UPDATE_UPDATER_PID', 'FACESWAP_STUDIO_START_HIDDEN')}
    env.update(FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE='1', FACESWAP_STUDIO_SKIP_UPDATE_PROMPT='1')
    return subprocess.Popen([str(executable), '--faceswap-run', '--faceswap-show'], cwd=root, env=env,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))


def execute(session, action):
    from updater.service import UpdateService
    from updater.transaction import read_json, write_json, emit, validate, run, version
    root, prompt, manifest = load_offer(session)
    session = Path(session).resolve()
    if action == 'show':
        from updater.transaction import wait_exit
        active = session.parent / 'active-offer.json'
        write_json(active, {'root': str(root), 'session': str(session), 'pid': os.getpid()})
        close_studio(root, prompt['bridge_url'])
        settings = read_json(session / 'session.json')
        wait_exit(settings['parentPid'], timeout=30)
        prompt['resume_studio'] = True
        write_json(session / 'prompt.json', prompt)
        try:
            child = subprocess.Popen([str(session / 'FaceSwapStudioUpdater.exe'), '--offer', str(session), sys.executable],
                                     cwd=session, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if isinstance(getattr(child, 'pid', None), int):
                write_json(active, {'root': str(root), 'session': str(session), 'pid': child.pid})
        except OSError:
            active.unlink(missing_ok=True)
            launch_studio(root)
            raise
        return
    service = UpdateService(root)
    if action == 'later':
        write_json(service.cache / 'deferred.json', {'session': str(session), 'root': str(root)})
        (service.cache / 'scheduled.json').unlink(missing_ok=True)
        emit('已安排下次启动时自动下载并更新，当前可以继续使用。', 100)
        return
    if version(service.current_version) < version(manifest['minVersion']):
        raise ValueError('当前版本需要使用完整安装器更新')
    if (version(service.current_version), service.config['releaseId']) >= (version(manifest['version']), manifest['releaseId']):
        emit('当前已是该版本或更新版本，无需重复安装。', 100)
        return 2
    emit('正在正常退出工作台…', 0)
    close_studio(root, prompt['bridge_url'])
    service.envelope = read_json(session / 'envelope.json')
    service.set(state='update_available', update_available=True, delta_available=True)
    service.download()
    while service.worker.is_alive():
        status = service.status()
        emit(status.get('message', '正在下载更新…'), int(status.get('percent', 0) * .25))
        service.worker.join(.3)
    status = service.status()
    if status['state'] != 'downloaded':
        raise RuntimeError(status.get('error') or status['message'])
    settings = read_json(session / 'session.json')
    validate(session, settings)
    emit('更新包已验证，正在安装更新…', 28)
    (service.cache / 'deferred.json').unlink(missing_ok=True)
    (service.cache / 'scheduled.json').unlink(missing_ok=True)
    run(session)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    parser.add_argument('action', choices=('now', 'later', 'show'))
    args = parser.parse_args()
    # 会话中的副本启动时，将已验证的安装根加入模块搜索路径。
    try:
        prompt = json.loads((args.session / 'prompt.json').read_text('utf-8-sig'))
        sys.path.insert(1, str(Path(prompt['root']).resolve(strict=True)))
        raise SystemExit(execute(args.session, args.action) or 0)
    except Exception as error:
        print(json.dumps({'message': str(error), 'progress': 0}, ensure_ascii=True), flush=True)
        if args.action == 'show':
            from updater.transaction import write_json
            write_json(args.session / 'handoff-error.json', {'error': str(error)})
            ctypes.windll.user32.MessageBoxW(None, str(error), '暂时无法进入更新', 0x10)
        raise SystemExit(1)
