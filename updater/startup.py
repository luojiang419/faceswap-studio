"""启动恢复、安装握手与桌面首帧健康确认。"""
import json
import os
from pathlib import Path
import subprocess
import sys

from updater.transaction import alive, read_json, write_json, run


def resume_update(root):
    root = Path(root).resolve()
    cache = root / 'faceswap studio/data/cache/updates'
    skip_deferred = os.environ.pop('FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE', None) == '1'
    pending = cache / 'pending.json'
    if pending.exists() and not os.environ.get('FACESWAP_STUDIO_UPDATE_SESSION'):
        marker = read_json(pending)
        session = Path(marker['session']).resolve(strict=True)
        if not session.is_relative_to(cache.resolve()):
            raise ValueError('待恢复更新不属于当前安装')
        if alive(marker['pid']):
            return True
        run(session, recover=True)
    deferred = cache / 'deferred.json'
    if deferred.exists() and not skip_deferred and not os.environ.get('FACESWAP_STUDIO_UPDATE_SESSION'):
        marker = read_json(deferred)
        session = Path(marker['session']).resolve(strict=True)
        if not session.is_relative_to(cache.resolve()):
            raise ValueError('延后更新不属于当前安装')
        from updater.offer import load_offer
        offer_root, _, manifest = load_offer(session)
        if offer_root != root:
            raise ValueError('延后更新安装目录不匹配')
        from updater.transaction import version
        if (version((root / 'VERSION').read_text('utf-8-sig').strip()), read_json(root / 'update-config.json')['releaseId']) >= (version(manifest['version']), manifest['releaseId']):
            deferred.unlink()
            return False
        settings = read_json(session / 'session.json')
        settings['parentPid'] = int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.getpid()))
        write_json(session / 'session.json', settings)
        subprocess.Popen([str(session / 'FaceSwapStudioUpdater.exe'), '--install-offer', str(session), sys.executable],
                         creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deferred.unlink()
        return True
    scheduled = cache / 'scheduled.json'
    if scheduled.exists():
        marker = read_json(scheduled)
        session = Path(marker['session']).resolve(strict=True)
        if not session.is_relative_to(cache.resolve()):
            raise ValueError('计划更新不属于当前安装')
        settings = read_json(session / 'session.json')
        if Path(settings['root']).resolve() != root:
            raise ValueError('计划更新安装目录不匹配')
        settings['parentPid'] = int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.getpid()))
        write_json(session / 'session.json', settings)
        subprocess.Popen([str(session / 'FaceSwapStudioUpdater.exe'), str(session), sys.executable],
                         creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        scheduled.unlink()
        return True
    return False


def confirm_ready(root):
    root = Path(root).resolve()
    config = read_json(root / 'update-config.json')
    receipt = {'ok': True, 'status': 'ready', 'root': str(root),
               'version': (root / 'VERSION').read_text('utf-8-sig').strip(),
               'releaseId': config['releaseId'],
               'pid': int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.environ.get('FACESWAP_STUDIO_LAUNCHER_PID', os.getpid()))),
               'token': os.environ.get('FACESWAP_STUDIO_UPDATE_TOKEN')}
    report = os.environ.get('FACESWAP_STUDIO_INSTALL_REPORT')
    session_id = os.environ.get('FACESWAP_STUDIO_INSTALL_SESSION')
    if report and session_id:
        target = Path(report).resolve()
        expected = root / 'data/cache/install' / (session_id + '.json')
        if target != expected.resolve():
            raise ValueError('安装握手位置不匹配')
        receipt['session'] = session_id
        write_json(target, receipt)
    health = os.environ.get('FACESWAP_STUDIO_UPDATE_HEALTH_FILE')
    session = os.environ.get('FACESWAP_STUDIO_UPDATE_SESSION')
    if health and session:
        target = Path(health).resolve()
        cache = root / 'faceswap studio/data/cache/updates'
        if target != (Path(session) / 'healthy.json').resolve() or not target.is_relative_to(cache.resolve()):
            raise ValueError('更新健康确认位置不匹配')
        # 首帧仅代表桌面出现；launcher 确认核心状态后才写最终 healthy.json。
        write_json(target.with_name('frontend-ready.json'), receipt)
    return receipt
