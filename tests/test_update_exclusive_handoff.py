import os
import subprocess
from unittest.mock import Mock

import pytest

import launch_faceswap_studio as launcher
from updater import offer, transaction
from updater.startup import active_update
from updater.service import UpdateService
from tests.test_modelscope_client import source, prepare_offer


def test_show_waits_for_workbench_and_wrapper_before_opening_updater(source, monkeypatch):
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer()
    actions = []
    monkeypatch.setattr(offer, 'close_studio', lambda *a: actions.append('workbench-exited'))
    monkeypatch.setattr(transaction, 'wait_exit', lambda *a, **k: actions.append('wrapper-exited'))
    monkeypatch.setattr(offer.subprocess, 'Popen', lambda args, **k: actions.append('updater-opened'))
    offer.execute(session, 'show')
    assert actions == ['workbench-exited', 'wrapper-exited', 'updater-opened']
    assert transaction.read_json(session / 'prompt.json')['resume_studio'] is True
    assert not (session / 'package.zip').exists()


def test_active_queue_cannot_open_updater_or_download(source, monkeypatch):
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer()
    def reject(*a): raise RuntimeError('生成任务正在运行')
    monkeypatch.setattr(offer, 'close_studio', reject)
    monkeypatch.setattr(offer.subprocess, 'Popen', lambda *a, **k: pytest.fail('不能显示更新器'))
    with pytest.raises(RuntimeError, match='生成任务'):
        offer.execute(session, 'show')
    assert not (session / 'package.zip').exists()


def test_cancelled_update_skips_only_automatic_prompt(source, monkeypatch):
    original, *_ = source
    monkeypatch.setenv('FACESWAP_STUDIO_SKIP_UPDATE_PROMPT', '1')
    service = UpdateService(original.root)
    service.check()
    assert service.offer(automatic=True)['prompt_skipped'] is True
    assert 'FACESWAP_STUDIO_SKIP_UPDATE_PROMPT' not in os.environ
    service, _, launched = prepare_offer((service, *source[1:]), monkeypatch)
    assert service.offer(automatic=False)['native_prompt_opened'] is True
    assert launched


def test_successful_restart_is_hidden_until_updater_exits(tmp_path, monkeypatch):
    monkeypatch.setattr(transaction, 'native_updater_pid', lambda session: 55)
    popen = Mock()
    monkeypatch.setattr(transaction.subprocess, 'Popen', popen)
    session = tmp_path / 'session'; session.mkdir()
    transaction.restart(tmp_path, session)
    env = popen.call_args.kwargs['env']
    assert env['FACESWAP_STUDIO_START_HIDDEN'] == '1'
    assert env['FACESWAP_STUDIO_UPDATE_UPDATER_PID'] == '55'


def test_rollback_waits_for_error_window_without_inheriting_pipes(tmp_path, monkeypatch):
    monkeypatch.setattr(transaction, 'native_updater_pid', lambda session: 55)
    popen = Mock()
    monkeypatch.setattr(transaction.subprocess, 'Popen', popen)
    session = tmp_path / 'session'; session.mkdir()
    transaction.restart(tmp_path, session, health=False)
    command = popen.call_args.args[0]
    assert command[1] == '-c' and command[3] == '55'
    assert transaction.read_json(session / 'restore-after-updater.json')['pid'] == 55
    options = popen.call_args.kwargs
    assert options['stdout'] == options['stderr'] == options['stdin'] == subprocess.DEVNULL
    assert options['env']['FACESWAP_STUDIO_SKIP_UPDATE_PROMPT'] == '1'


def test_frontend_revealed_only_after_success_and_updater_exit(tmp_path, monkeypatch):
    session = tmp_path / 'session'; session.mkdir()
    transaction.write_json(session / 'status.json', {'status': 'installing'})
    monkeypatch.setenv('FACESWAP_STUDIO_START_HIDDEN', '1')
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_UPDATER_PID', '55')
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_SESSION', str(session))
    states = []
    class Stop:
        def wait(self, interval):
            states.append(len(states) + 1)
            if len(states) == 3:
                transaction.write_json(session / 'status.json', {'status': 'complete'})
            return len(states) > 3
    monkeypatch.setattr(transaction, 'alive', lambda pid: len(states) == 1)
    shown = []
    monkeypatch.setattr(launcher, 'reveal_frontend', lambda pid: shown.append(pid) or True)
    launcher.monitor_frontend_visibility(tmp_path, 66, Stop())
    assert states == [1, 2, 3] and shown == [66]
    assert transaction.read_json(session / 'frontend-revealed.json')['updaterExited'] is True


def test_running_updater_blocks_shortcut_relaunch_and_rejects_foreign_marker(tmp_path, monkeypatch):
    import updater.startup as startup
    import psutil
    session = tmp_path / 'faceswap studio/data/cache/updates/20261019000000'
    transaction.write_json(session.parent / 'active-offer.json', {'root': str(tmp_path), 'session': str(session), 'pid': 55})
    monkeypatch.setattr(startup, 'alive', lambda pid: pid == 55)
    monkeypatch.setattr(psutil, 'Process', lambda pid: Mock(exe=lambda: str(session / 'FaceSwapStudioUpdater.exe')))
    assert active_update(tmp_path)
    transaction.write_json(session.parent / 'active-offer.json', {'root': str(tmp_path), 'session': str(tmp_path.parent / 'foreign'), 'pid': 55})
    assert not active_update(tmp_path)


def test_reused_pid_cannot_leave_workbench_blocked(tmp_path, monkeypatch):
    import updater.startup as startup
    import psutil
    session = tmp_path / 'faceswap studio/data/cache/updates/20261019000000'
    marker = session.parent / 'active-offer.json'
    transaction.write_json(marker, {'root': str(tmp_path), 'session': str(session), 'pid': 55})
    monkeypatch.setattr(startup, 'alive', lambda pid: True)
    monkeypatch.setattr(psutil, 'Process', lambda pid: Mock(exe=lambda: str(tmp_path / 'other.exe'), cmdline=lambda: []))
    assert not active_update(tmp_path)
    assert not marker.exists()


def test_normal_launcher_does_not_activate_frontend_while_updater_owns_session(tmp_path, monkeypatch):
    import updater.startup as startup
    monkeypatch.delenv('FACESWAP_STUDIO_UPDATE_SESSION', raising=False)
    monkeypatch.setattr(launcher, 'resolve_repo_root', lambda: tmp_path)
    monkeypatch.setattr(startup, 'active_update', lambda root: True)
    monkeypatch.setattr(launcher, 'notify_running_instance', lambda *a: pytest.fail('不能激活更新检查中的隐藏工作台'))
    assert launcher.main() == 0
