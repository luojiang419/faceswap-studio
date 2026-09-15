import importlib.util
import json
import threading
from collections import deque
from pathlib import Path

from fastapi.testclient import TestClient


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_SERVER_PATH = REPO_ROOT / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server_updates', APP_SERVER_PATH)
assert APP_SERVER_SPEC is not None
assert APP_SERVER_SPEC.loader is not None
APP_SERVER_MODULE = importlib.util.module_from_spec(APP_SERVER_SPEC)
APP_SERVER_SPEC.loader.exec_module(APP_SERVER_MODULE)
FaceFusionRuntime = APP_SERVER_MODULE.FaceFusionRuntime


def create_runtime(tmp_path : Path) -> FaceFusionRuntime:
	runtime = object.__new__(FaceFusionRuntime)
	repo_root = tmp_path / 'repo'
	repo_root.mkdir(parents = True, exist_ok = True)
	(repo_root / 'VERSION').write_text('0.1.1', encoding = 'utf-8')
	(repo_root / '启动FaceSwap Studio.exe').write_bytes(b'launcher')

	runtime._repo_root = repo_root
	runtime._update_lock = threading.RLock()
	runtime._update_download_thread = None
	runtime._process = None
	runtime._queue_current_process = None
	runtime._lock = threading.RLock()
	runtime._logs = deque(maxlen = 50)
	runtime._sequence = 0
	runtime._settings = {
		'model_download_mode': APP_SERVER_MODULE.MODEL_DOWNLOAD_MODE_DOMESTIC,
		'custom_proxy_url': APP_SERVER_MODULE.DEFAULT_CUSTOM_PROXY_URL
	}
	runtime._update_state = runtime._default_update_state()
	return runtime


def test_core_update_routes_removed() -> None:
	client = TestClient(APP_SERVER_MODULE.app)
	for route in ('/updates/core/download', '/updates/core/apply'):
		assert client.post(route).status_code == 404


def test_check_updates_only_queries_app_release(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	monkeypatch.setattr(runtime, '_latest_release_metadata', lambda: ({'version': '0.1.1'}, {}))
	monkeypatch.setattr(runtime, '_download_json', lambda *a, **k: (_ for _ in ()).throw(AssertionError('unexpected network request')))
	status = runtime.check_updates()
	assert status['state'] == 'current'
	assert 'core_update' not in status
	assert not hasattr(runtime, 'apply_core_update')


def test_select_delta_package_matches_current_version(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	selected = runtime._select_delta_package(
		{
			'delta_packages': [
				{ 'from_version': '0.1.0', 'asset_name': 'from-010.zip' },
				{ 'from_version': '0.1.1', 'asset_name': 'from-011.zip' }
			]
		},
		{
			'from-010.zip': 'https://example.com/from-010.zip',
			'from-011.zip': 'https://example.com/from-011.zip'
		},
		'0.1.1'
	)

	assert selected is not None
	assert selected['from_version'] == '0.1.1'
	assert selected['download_url'] == 'https://example.com/from-011.zip'


def test_update_opener_uses_custom_proxy(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings['model_download_mode'] = APP_SERVER_MODULE.MODEL_DOWNLOAD_MODE_CUSTOM_PROXY
	runtime._settings['custom_proxy_url'] = 'http://127.0.0.1:7890'
	captured : dict[str, object] = {}

	def fake_build_opener(*handlers):
		captured['handlers'] = handlers
		return 'opener'

	monkeypatch.setattr(APP_SERVER_MODULE, 'build_opener', fake_build_opener)

	assert runtime._update_opener() == 'opener'
	handler = captured['handlers'][0]
	assert isinstance(handler, APP_SERVER_MODULE.ProxyHandler)
	assert handler.proxies['http'] == 'http://127.0.0.1:7890'
	assert handler.proxies['https'] == 'http://127.0.0.1:7890'


def test_update_opener_uses_system_proxy(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings['model_download_mode'] = APP_SERVER_MODULE.MODEL_DOWNLOAD_MODE_SYSTEM_PROXY
	captured : dict[str, object] = {}

	def fake_build_opener(*handlers):
		captured['handlers'] = handlers
		return 'opener'

	monkeypatch.setattr(APP_SERVER_MODULE, 'getproxies', lambda : {
		'http': 'http://system-proxy:7890',
		'https': 'http://system-proxy:7890'
	})
	monkeypatch.setattr(APP_SERVER_MODULE, 'build_opener', fake_build_opener)

	assert runtime._update_opener() == 'opener'
	handler = captured['handlers'][0]
	assert isinstance(handler, APP_SERVER_MODULE.ProxyHandler)
	assert handler.proxies['http'] == 'http://system-proxy:7890'
	assert handler.proxies['https'] == 'http://system-proxy:7890'


def test_update_opener_without_system_proxy_falls_back_to_direct(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings['model_download_mode'] = APP_SERVER_MODULE.MODEL_DOWNLOAD_MODE_SYSTEM_PROXY
	captured : dict[str, object] = {}

	def fake_build_opener(*handlers):
		captured['handlers'] = handlers
		return 'opener'

	monkeypatch.setattr(APP_SERVER_MODULE, 'getproxies', lambda : {})
	monkeypatch.setattr(APP_SERVER_MODULE, 'build_opener', fake_build_opener)

	assert runtime._update_opener() == 'opener'
	assert captured['handlers'] == ()


def test_schedule_update_writes_marker_and_status(monkeypatch, tmp_path : Path) -> None:
	localappdata = tmp_path / 'localappdata'
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	runtime = create_runtime(tmp_path)
	package_path = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'delta.zip'
	package_path.parent.mkdir(parents = True, exist_ok = True)
	package_path.write_bytes(b'delta')
	runtime._update_state.update({
		'state': 'downloaded',
		'latest_version': '0.1.2',
		'package_path': str(package_path)
	})

	status = runtime.schedule_update()
	marker_path = localappdata / 'FaceSwap Studio' / 'updates' / 'pending-update.json'
	marker = json.loads(marker_path.read_text(encoding = 'utf-8'))

	assert status['scheduled_for_next_launch'] is True
	assert status['pending_package_path'] == str(package_path)
	assert marker['version'] == '0.1.2'
	assert marker['package_path'] == str(package_path)
	assert marker['root_path'] == str(runtime.repo_root)


def test_update_status_reads_pending_marker(monkeypatch, tmp_path : Path) -> None:
	localappdata = tmp_path / 'localappdata'
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	runtime = create_runtime(tmp_path)
	package_path = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'delta.zip'
	package_path.parent.mkdir(parents = True, exist_ok = True)
	package_path.write_bytes(b'delta')
	runtime._write_pending_update_marker(package_path, '0.1.2')
	runtime._update_state = runtime._default_update_state()

	status = runtime.update_status()

	assert status['scheduled_for_next_launch'] is True
	assert status['state'] == 'downloaded'
	assert status['latest_version'] == '0.1.2'
	assert status['pending_package_path'] == str(package_path)


def test_schedule_update_fails_when_package_missing(monkeypatch, tmp_path : Path) -> None:
	localappdata = tmp_path / 'localappdata'
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	runtime = create_runtime(tmp_path)
	missing_package = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'missing.zip'
	runtime._update_state.update({
		'state': 'downloaded',
		'latest_version': '0.1.2',
		'package_path': str(missing_package)
	})

	status = runtime.schedule_update()

	assert status['state'] == 'failed'
	assert status['message'] == '更新包尚未下载。'


def test_apply_update_fails_when_package_missing_and_clears_marker(monkeypatch, tmp_path : Path) -> None:
	localappdata = tmp_path / 'localappdata'
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	runtime = create_runtime(tmp_path)
	missing_package = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'missing.zip'
	runtime._update_state.update({
		'state': 'downloaded',
		'latest_version': '0.1.2',
		'package_path': str(missing_package)
	})
	runtime._write_pending_update_marker(missing_package, '0.1.2')

	status = runtime.apply_update()

	assert status['state'] == 'failed'
	assert status['message'] == '更新包尚未下载。'
	assert runtime._pending_update_marker_path().exists() is False


def test_updates_schedule_route_uses_runtime(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	monkeypatch.setattr(APP_SERVER_MODULE, 'runtime', runtime)
	monkeypatch.setattr(runtime, 'schedule_update', lambda : { 'ok': True, 'state': 'downloaded' })
	client = TestClient(APP_SERVER_MODULE.app)

	response = client.post('/updates/schedule')

	assert response.status_code == 200
	assert response.json()['ok'] is True
