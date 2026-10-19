import os
from pathlib import Path
import pytest
from updater import startup
from updater.transaction import write_json


def test_scheduled_update_handoff_is_scoped(tmp_path, monkeypatch):
    root = tmp_path / '中文 软件'; root.mkdir()
    session = root / 'faceswap studio/data/cache/updates/20261018000002'; session.mkdir(parents=True)
    write_json(session / 'session.json', {'root': str(root), 'parentPid': 1})
    write_json(session.parent / 'scheduled.json', {'session': str(session)})
    started = []
    monkeypatch.setattr(startup.subprocess, 'Popen', lambda args, **kwargs: started.append(args))
    assert startup.resume_update(root)
    assert started[0][1] == str(session)
    assert startup.read_json(session / 'session.json')['parentPid'] == os.getpid()
    assert not (session.parent / 'scheduled.json').exists()


def test_foreign_schedule_rejected(tmp_path):
    root = tmp_path / 'app'; root.mkdir()
    outside = tmp_path / 'outside'; outside.mkdir()
    write_json(root / 'faceswap studio/data/cache/updates/scheduled.json', {'session': str(outside)})
    with pytest.raises(ValueError, match='不属于'): startup.resume_update(root)


def test_active_transaction_prevents_second_launcher(tmp_path, monkeypatch):
    root = tmp_path / 'app'; root.mkdir()
    session = root / 'faceswap studio/data/cache/updates/session'; session.mkdir(parents=True)
    write_json(session.parent / 'pending.json', {'session': str(session), 'pid': 42})
    monkeypatch.setattr(startup, 'alive', lambda pid: True)
    assert startup.resume_update(root)


def test_first_frame_ack_contains_version_and_release(tmp_path, monkeypatch):
    (tmp_path / 'VERSION').write_text('0.1.3')
    write_json(tmp_path / 'update-config.json', {'releaseId': '20261018000002'})
    session = tmp_path / 'faceswap studio/data/cache/updates/20261018000002'
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_SESSION', str(session))
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_HEALTH_FILE', str(session / 'healthy.json'))
    receipt = startup.confirm_ready(tmp_path)
    assert receipt['status'] == 'ready'
    assert startup.read_json(session / 'frontend-ready.json')['releaseId'] == '20261018000002'
    assert not (session / 'healthy.json').exists()


def test_scheduled_update_waits_for_wrapper(tmp_path, monkeypatch):
    session = tmp_path / 'faceswap studio/data/cache/updates/session'
    write_json(session / 'session.json', {'root': str(tmp_path)})
    write_json(session.parent / 'scheduled.json', {'session': str(session)})
    monkeypatch.setenv('FACESWAP_STUDIO_WRAPPER_PID', '12345')
    monkeypatch.setattr(startup.subprocess, 'Popen', lambda *args, **kwargs: None)
    assert startup.resume_update(tmp_path)
    assert startup.read_json(session / 'session.json')['parentPid'] == 12345


def test_installer_receipt_path_unchanged(tmp_path, monkeypatch):
    (tmp_path / 'VERSION').write_text('0.1.3')
    write_json(tmp_path / 'update-config.json', {'releaseId': '20261018000002'})
    target = tmp_path / 'data/cache/install/test.json'
    monkeypatch.setenv('FACESWAP_STUDIO_INSTALL_REPORT', str(target))
    monkeypatch.setenv('FACESWAP_STUDIO_INSTALL_SESSION', 'test')
    startup.confirm_ready(tmp_path)
    assert startup.read_json(target)['session'] == 'test'
