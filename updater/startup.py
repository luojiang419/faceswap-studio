"""启动恢复、安装握手与桌面首帧健康确认。"""
import json
import os
from pathlib import Path
import subprocess
import sys

from updater.transaction import alive, read_json, write_json, run


def finalize_installation(root, session):
    """事务确认完成后迁移受管理的入口；旧更新事务也可经新启动器完成此步骤。"""
    from updater.service import verify_envelope
    root, session = Path(root).resolve(strict=True), Path(session).resolve(strict=True)
    if not (root / '.faceswap-install.json').is_file():
        return
    config = read_json(root / 'update-config.json')
    manifest = verify_envelope(read_json(session / 'envelope.json'), config['publicKey'])
    if session != (root / 'faceswap studio/data/cache/updates' / manifest['releaseId']).resolve():
        raise ValueError('安装入口迁移会话不匹配')
    if config['releaseId'] != manifest['releaseId'] or read_json(session / 'status.json').get('status') != 'complete':
        raise ValueError('更新尚未确认完成，不能迁移入口')
    if (session / 'integration-result.json').exists():
        return
    subprocess.run([str(root / 'FaceSwapStudioUpdater.exe'), '--finalize-installation', str(root), str(session)],
                   check=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))


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
    if not os.environ.get('FACESWAP_STUDIO_UPDATE_SESSION') and (root / '.faceswap-install.json').is_file() and (root / 'update-config.json').is_file():
        session = cache / read_json(root / 'update-config.json')['releaseId']
        if (session / 'status.json').is_file() and not (session / 'integration-result.json').exists():
            if read_json(session / 'status.json').get('status') == 'complete':
                try:
                    finalize_installation(root, session)
                except Exception as error:
                    with (cache / 'integration-pending.log').open('a', encoding='utf-8') as log:
                        log.write(str(error) + '\n')
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
