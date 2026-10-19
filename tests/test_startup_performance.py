"""首帧与服务解耦、退出交接、启动取消和编码器复用回归。"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from unittest.mock import Mock

import psutil
import pytest

import launch_faceswap_studio as launcher
from updater import preflight, startup


@pytest.fixture(scope='module')
def bridge_module():
    source = Path(__file__).resolve().parents[1] / 'faceswap studio/bridge/app_server.py'
    spec = importlib.util.spec_from_file_location('startup_bridge_test', source)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    return bridge


def test_duplicate_during_exit_reacquires_instead_of_losing_reopen(tmp_path, monkeypatch):
    binary = tmp_path / 'faceswap studio/runtime/windows_app/current/faceswap_studio.exe'
    binary.parent.mkdir(parents=True)
    binary.touch()
    monkeypatch.setattr(launcher, 'resolve_repo_root', lambda: tmp_path)
    monkeypatch.setattr(launcher, 'resolve_flutter_binary', lambda root: None)
    monkeypatch.setattr(startup, 'active_update', lambda root: False)
    monkeypatch.setattr(startup, 'resume_update', lambda root: False)
    locks = iter([(None, True), (42, False)])
    monkeypatch.setattr(launcher, 'acquire_single_instance_lock', lambda root: next(locks))
    monkeypatch.setattr(launcher, 'notify_running_instance', lambda: False)
    events = []
    monkeypatch.setattr(launcher, 'release_single_instance_lock', lambda *args: events.append('unlock'))
    runtime = Mock(close=lambda: events.append('cleanup'))
    monkeypatch.setattr(launcher, 'ManagedRuntime', lambda *args: runtime)
    def frontend(command, cwd, services):
        assert services is runtime
        events.append('frontend')
        return 0, 1
    monkeypatch.setattr(launcher, 'launch_frontend', frontend)
    assert launcher.main() == 0
    assert events == ['frontend', 'unlock', 'cleanup']


@pytest.mark.skipif(os.name != 'nt', reason='Windows named mutex')
def test_new_session_waits_for_old_services_without_blocking_frontend(tmp_path, monkeypatch):
    monkeypatch.setattr(launcher, 'LAUNCHER_MUTEX_NAME', f'Local\\StudioTest.{os.getpid()}.{time.time_ns()}')
    monkeypatch.setenv('FACESWAP_STUDIO_ISOLATED', '1')
    monkeypatch.delenv('FACESWAP_STUDIO_UPDATE_SESSION', raising=False)
    monkeypatch.delenv('FACESWAP_STUDIO_INSTALL_REPORT', raising=False)
    monkeypatch.setattr(launcher, 'should_start_facefusion_on_launch', lambda root: False)
    old_ready, new_ready, cleaning, finish_cleanup = (threading.Event() for _ in range(4))
    old_process, new_process = Mock(), Mock()
    calls = []
    def start(root, studio, cancel):
        calls.append(len(calls))
        if len(calls) == 1:
            old_ready.set()
            return old_process, None
        new_ready.set()
        return new_process, None
    def terminate(process, root):
        if process is old_process:
            cleaning.set()
            assert finish_cleanup.wait(3)
    monkeypatch.setattr(launcher, 'start_bridge_if_needed', start)
    monkeypatch.setattr(launcher, 'stop_facefusion_service', lambda root: None)
    monkeypatch.setattr(launcher, 'terminate_process_tree', terminate)
    old = launcher.ManagedRuntime(tmp_path, tmp_path / 'faceswap studio')
    new = launcher.ManagedRuntime(tmp_path, tmp_path / 'faceswap studio')
    try:
        old.start()
        assert old_ready.wait(2)
        old.cancel.set()
        assert cleaning.wait(2)
        start = time.monotonic()
        new.start()
        assert time.monotonic() - start < .2
        assert not new_ready.wait(.2)
        finish_cleanup.set()
        assert new_ready.wait(2)
    finally:
        finish_cleanup.set()
        old.close()
        new.close()
    assert calls == [0, 1]


def test_closing_during_bridge_import_cancels_child(tmp_path, monkeypatch):
    monkeypatch.setattr(launcher, 'is_bridge_compatible', lambda: False)
    monkeypatch.setattr(launcher, 'is_bridge_ready', lambda: False)
    monkeypatch.setattr(launcher, 'is_bridge_port_open', lambda: False)
    monkeypatch.setattr(launcher, 'resolve_runtime_python', lambda root: Path(sys.executable))
    (tmp_path / 'faceswap studio/bridge').mkdir(parents=True)
    original = subprocess.Popen
    children = []
    cancel = threading.Event()
    def popen(*args, **kwargs):
        child = original([sys.executable, '-c', 'import time; time.sleep(60)'],
                         creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        children.append(child)
        cancel.set()
        return child
    monkeypatch.setattr(launcher.subprocess, 'Popen', popen)
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        launcher.start_bridge_if_needed(tmp_path, tmp_path / 'faceswap studio', cancel)
    assert time.monotonic() - started < 3
    assert all(child.poll() is not None for child in children)


def test_preflight_is_cancellable_without_orphans(tmp_path, monkeypatch):
    original = subprocess.Popen
    cancel = threading.Event()
    children = []
    def popen(*args, **kwargs):
        child = original([sys.executable, '-c', 'import time; time.sleep(60)'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        children.append(child)
        cancel.set()
        return child
    monkeypatch.setattr(preflight.subprocess, 'Popen', popen)
    with pytest.raises(InterruptedError):
        preflight.run_preflight(tmp_path, cancel=cancel)
    assert all(child.poll() is not None for child in children)


def test_stale_cleanup_leaves_new_frontend_and_wrapper_untouched(tmp_path, monkeypatch):
    processes = []
    for pid, name, command in [(901, 'python.exe', 'launch_faceswap_studio.py'),
                               (902, 'faceswap_studio.exe', 'faceswap_studio.exe'),
                               (903, 'python.exe', 'uvicorn app_server:app')]:
        process = Mock(pid=pid, info={'name': name})
        process.as_dict.return_value = {'name': name, 'exe': str(tmp_path / name),
                                       'cmdline': [str(tmp_path), command]}
        process.children.return_value = []
        processes.append(process)
    monkeypatch.setattr(psutil, 'process_iter', lambda *args: iter(processes))
    launcher.cleanup_stale_runtime_processes(tmp_path, tmp_path / 'faceswap studio')
    processes[0].terminate.assert_not_called()
    processes[1].terminate.assert_not_called()
    processes[2].terminate.assert_called_once()


def test_valid_bundled_encoder_does_not_probe_external_installations(tmp_path, monkeypatch, bridge_module):
    bridge = bridge_module
    runtime = object.__new__(bridge.FaceFusionRuntime)
    runtime._repo_root = tmp_path
    target = runtime._bundled_ffmpeg_executable()
    target.parent.mkdir(parents=True)
    target.touch()
    runtime._ffmpeg_has_video_encoder = Mock(return_value=True)
    runtime._resolve_ffmpeg_source = Mock(side_effect=AssertionError('不应探测系统编码器'))
    monkeypatch.delenv(bridge.FFMPEG_SOURCE_ENV, raising=False)
    runtime._ensure_bundled_ffmpeg()
    runtime._resolve_ffmpeg_source.assert_not_called()
    monkeypatch.setenv(bridge.FFMPEG_SOURCE_ENV, str(tmp_path / 'override.exe'))
    runtime._resolve_ffmpeg_source = Mock(return_value=None)
    runtime._ensure_bundled_ffmpeg()
    runtime._resolve_ffmpeg_source.assert_called_once()


def test_bridge_health_does_not_wait_for_core_lock_or_scan_network(monkeypatch, bridge_module):
    bridge = bridge_module
    monkeypatch.setattr(bridge.runtime, 'status', Mock(side_effect=AssertionError('核心检查不能阻塞存活探测')))
    monkeypatch.setattr(bridge.psutil, 'net_connections', Mock(side_effect=AssertionError('不能全机扫描')))
    with bridge.runtime._lock:
        result = []
        worker = threading.Thread(target=lambda: result.append(bridge.health()))
        worker.start()
        worker.join(timeout=.3)
        blocked = worker.is_alive()
    worker.join(timeout=1)
    assert not blocked
    assert result[0]['status'] == 'ok'
    assert result[0]['pid'] == os.getpid()
    assert result[0]['root'] == str(bridge.runtime.repo_root)


def test_stopped_core_does_not_scan_all_tcp_connections(monkeypatch, bridge_module):
    bridge = bridge_module
    monkeypatch.setattr(bridge.socket, 'create_connection', Mock(side_effect=OSError('closed')))
    scan = Mock(side_effect=AssertionError('未监听端口不应扫描全机'))
    monkeypatch.setattr(bridge.psutil, 'net_connections', scan)
    request = Mock(side_effect=AssertionError('未监听端口不应发 HTTP'))
    monkeypatch.setattr(bridge, 'urlopen', request)
    assert bridge.runtime._find_webui_process_pid() is None
    assert not bridge.runtime._is_webui_ready()


def test_update_launch_retains_preflight_before_bridge(tmp_path, monkeypatch):
    monkeypatch.setenv('FACESWAP_STUDIO_ISOLATED', '1')
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_SESSION', 'session')
    monkeypatch.setattr(launcher, 'LAUNCHER_MUTEX_NAME', f'Local\\StudioUpdateTest.{time.time_ns()}')
    monkeypatch.setattr(launcher, 'resolve_runtime_python', lambda root: Path(sys.executable))
    events = []
    ready = threading.Event()
    def check(*args, **kwargs):
        events.append('preflight')
        return {'coreVersion': '3.9.1'}
    def bridge(*args):
        events.append('bridge')
        ready.set()
        return None, None
    monkeypatch.setattr(preflight, 'run_preflight', check)
    monkeypatch.setattr(launcher, 'start_bridge_if_needed', bridge)
    monkeypatch.setattr(launcher, 'should_start_facefusion_on_launch', lambda root: False)
    monkeypatch.setattr(launcher, 'stop_facefusion_service', lambda root: None)
    runtime = launcher.ManagedRuntime(tmp_path, tmp_path / 'faceswap studio')
    try:
        runtime.start()
        assert ready.wait(2)
    finally:
        runtime.close()
    assert events == ['preflight', 'bridge']
