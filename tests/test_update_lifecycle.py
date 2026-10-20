"""升级生命周期回归：正常退出、失败保留部署、健康确认与预检拒绝。"""
import shutil
import zipfile
from pathlib import Path
from unittest.mock import Mock

import pytest

from scripts import deploy_flutter_app as deploy
from updater import transaction as u
from updater.preflight import run_preflight
from tests.test_signed_updater import prepare

ROOT = Path(__file__).resolve().parents[1]


def make_build(root, value):
    root.mkdir(parents=True)
    for name in deploy.REQUIRED:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(value)


def test_deploy_waits_and_replaces_whole_directory(tmp_path, monkeypatch):
    root, source = tmp_path / '中文 软件', tmp_path / 'build'
    current = root / 'faceswap studio/runtime/windows_app/current'
    make_build(current, b'old')
    (current / 'obsolete.dll').write_bytes(b'old')
    make_build(source, b'new')
    stopped = []
    def stop(path):
        assert (current / 'faceswap_studio.exe').read_bytes() == b'old'
        stopped.append(path)
    monkeypatch.setattr(deploy, 'stop_studio', stop)
    assert deploy.deploy(root, source) == current
    assert stopped == [root]
    assert (current / 'faceswap_studio.exe').read_bytes() == b'new'
    assert not (current / 'obsolete.dll').exists()


def test_exit_timeout_preserves_deployment(tmp_path, monkeypatch):
    root, source = tmp_path / 'app', tmp_path / 'build'
    current = root / 'faceswap studio/runtime/windows_app/current'
    make_build(current, b'old')
    make_build(source, b'new')
    monkeypatch.setattr(deploy, 'stop_studio', Mock(side_effect=TimeoutError('尚未退出')))
    with pytest.raises(TimeoutError):
        deploy.deploy(root, source)
    assert (current / 'faceswap_studio.exe').read_bytes() == b'old'


def test_failed_switch_restores_old_directory(tmp_path, monkeypatch):
    root, source = tmp_path / 'app', tmp_path / 'build'
    current = root / 'faceswap studio/runtime/windows_app/current'
    make_build(current, b'old')
    make_build(source, b'new')
    monkeypatch.setattr(deploy, 'stop_studio', lambda root: None)
    original = Path.rename
    def rename(path, destination):
        if path.name == 'new':
            raise PermissionError('文件占用')
        return original(path, destination)
    monkeypatch.setattr(Path, 'rename', rename)
    with pytest.raises(PermissionError):
        deploy.deploy(root, source)
    assert (current / 'faceswap_studio.exe').read_bytes() == b'old'


def test_health_requires_current_process_root_token_and_core(tmp_path):
    manifest = {'version': '1.2.3', 'releaseId': '20261019000000'}
    receipt = dict(manifest, ok=True, status='ready', root=str(tmp_path), pid=42, token='new', coreState='ready', checkedAt=u.time.time())
    assert u.valid_health(receipt, tmp_path, manifest, 42, 'new')
    for name, value in [('pid', 41), ('root', 'other'), ('token', 'old'), ('version', '1.2.2'),
                        ('releaseId', '20261018000000'), ('coreState', 'starting'), ('ok', False), ('checkedAt', 0)]:
        assert not u.valid_health(dict(receipt, **{name: value}), tmp_path, manifest, 42, 'new')


def test_dead_child_cannot_pass_with_health_file(tmp_path, monkeypatch):
    root, session, settings = prepare(tmp_path)
    monkeypatch.setattr(u, 'wait_exit', lambda *args: None)
    monkeypatch.setattr(u, 'preflight_update', lambda *args: None)
    u.write_json(session / 'health-challenge.json', {'token': 'new'})
    calls = []
    def restart(root, session, health=True):
        calls.append(health)
        u.write_json(session / 'healthy.json', {'version': '2.0.2', 'ok': True, 'status': 'ready',
                     'root': str(root), 'pid': 42, 'token': 'new', 'coreState': 'ready', 'checkedAt': u.time.time()})
        return Mock(pid=42, poll=lambda: 1)
    monkeypatch.setattr(u, 'restart', restart)
    with pytest.raises(RuntimeError, match='启动失败'):
        u.run(session)
    assert calls == [True, False]
    assert (root / 'VERSION').read_text() == '2.0.1'


def test_health_monitor_waits_for_core_then_keeps_heartbeat(tmp_path, monkeypatch):
    import launch_faceswap_studio as launcher
    session = tmp_path / 'faceswap studio/data/cache/updates/session'
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_SESSION', str(session))
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_HEALTH_FILE', str(session / 'healthy.json'))
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_TOKEN', 'new')
    monkeypatch.setenv('FACESWAP_STUDIO_WRAPPER_PID', '42')
    u.write_json(session / 'frontend-ready.json', {'pid': 42, 'root': str(tmp_path), 'token': 'new'})
    monkeypatch.setattr(launcher, 'get_model_bootstrap_status', lambda: {'ready': True})
    states = iter(['starting', 'ready', 'failed'])
    monkeypatch.setattr(launcher, 'get_facefusion_status', lambda: {'state': next(states)})
    observed = []
    class Stop:
        def wait(self, interval):
            observed.append((session / 'healthy.json').exists())
            return len(observed) > 3
    launcher.monitor_update_health(tmp_path, Stop())
    assert observed == [False, False, True, False]


def test_preflight_rejection_reopens_unmodified_version(tmp_path, monkeypatch):
    root, session, settings = prepare(tmp_path)
    monkeypatch.setattr(u, 'wait_exit', lambda *args: None)
    restart = Mock()
    monkeypatch.setattr(u, 'restart', restart)
    with pytest.raises(ValueError, match='缺少核心兼容性预检'):
        u.run(session)
    assert (root / 'VERSION').read_text() == '2.0.1'
    restart.assert_called_once_with(root, session, health=False)


def test_preflight_imports_actual_candidate_and_does_not_write_data(tmp_path):
    from facefusion import metadata
    for folder in ('facefusion', 'faceswap studio/bridge', 'updater'):
        shutil.copytree(ROOT / folder, tmp_path / folder, ignore=shutil.ignore_patterns('__pycache__'))
    assert run_preflight(tmp_path)['coreVersion'] == metadata.get('version')
    assert not (tmp_path / 'faceswap studio/data').exists()
    source = tmp_path / 'facefusion/filesystem.py'
    source.write_text(source.read_text('utf-8').replace('def get_file_extension(', 'def removed_file_extension('), 'utf-8')
    with pytest.raises(RuntimeError, match='get_file_extension'):
        run_preflight(tmp_path)


def test_restart_discards_old_health_and_inherited_identity(tmp_path, monkeypatch):
    session = tmp_path / 'session'
    for name in ('healthy.json', 'frontend-ready.json', 'healthy.json.preparing'):
        u.write_json(session / name, {'old': True})
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_TOKEN', 'old')
    monkeypatch.setenv('FACESWAP_STUDIO_WRAPPER_PID', '123')
    popen = Mock()
    monkeypatch.setattr(u.subprocess, 'Popen', popen)
    u.restart(tmp_path, session)
    env = popen.call_args.kwargs['env']
    assert env['FACESWAP_STUDIO_UPDATE_TOKEN'] != 'old'
    assert 'FACESWAP_STUDIO_WRAPPER_PID' not in env
    assert not (session / 'healthy.json').exists()
    assert env['FACESWAP_STUDIO_UPDATE_TOKEN'] == u.read_json(session / 'health-challenge.json')['token']


@pytest.mark.parametrize('name, error', [('VERSION', '缺少必要文件'), ('../VERSION', '更新')])
def test_release_gate_rejects_incomplete_or_unsafe_zip(tmp_path, name, error):
    from scripts.release_modelscope import validate_package
    package = tmp_path / 'package.zip'
    with zipfile.ZipFile(package, 'w') as archive:
        archive.writestr(name, '0.1.3')
    with pytest.raises(ValueError, match=error):
        validate_package(package)
