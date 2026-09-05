import importlib.util
import json
import threading
import zipfile
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
	runtime._core_update_download_thread = None
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


def write_core_payload(root : Path, marker : str) -> None:
	core_dir = root / 'facefusion'
	core_dir.mkdir(parents = True, exist_ok = True)
	(core_dir / '__init__.py').write_text('', encoding = 'utf-8')
	(core_dir / 'marker.txt').write_text(marker, encoding = 'utf-8')
	(root / 'facefusion.py').write_text(marker, encoding = 'utf-8')
	(root / 'requirements.txt').write_text(marker, encoding = 'utf-8')
	(root / 'install.py').write_text(marker, encoding = 'utf-8')


def write_core_archive(tmp_path : Path, marker : str = 'new') -> Path:
	package_path = tmp_path / 'facefusion-3.9.0.zip'
	with zipfile.ZipFile(package_path, 'w') as archive:
		archive.writestr('facefusion-source/facefusion/__init__.py', '')
		archive.writestr('facefusion-source/facefusion/marker.txt', marker)
		archive.writestr('facefusion-source/facefusion.py', marker)
		archive.writestr('facefusion-source/requirements.txt', marker)
		archive.writestr('facefusion-source/install.py', marker)
	return package_path


def prepare_core_update(runtime : FaceFusionRuntime, package_path : Path) -> None:
	runtime._update_state['core_update'].update({
		'state': 'downloaded',
		'latest_version': '3.9.0',
		'package_path': str(package_path),
	})


def test_core_update_preflight_accepts_current_core(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	runtime._validate_core_update_source(REPO_ROOT, '3.9.0')


def test_apply_core_update_rejects_unsafe_archive(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	write_core_payload(runtime.repo_root, 'old')
	package_path = tmp_path / 'unsafe.zip'
	with zipfile.ZipFile(package_path, 'w') as archive:
		archive.writestr('../escaped.txt', 'unsafe')
	prepare_core_update(runtime, package_path)

	status = runtime.apply_core_update()

	assert status['core_update']['state'] == 'failed'
	assert status['core_update']['message'] == 'FaceFusion 核心升级包兼容性检查失败，当前核心未修改。'
	assert (runtime.repo_root / 'facefusion' / 'marker.txt').read_text(encoding = 'utf-8') == 'old'
	assert (package_path.parent / 'escaped.txt').exists() is False


def test_apply_core_update_preflight_failure_preserves_current_core(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	write_core_payload(runtime.repo_root, 'old')
	package_path = write_core_archive(tmp_path)
	prepare_core_update(runtime, package_path)

	def fail_preflight(source_root : Path, expected_version : str) -> None:
		raise RuntimeError('incompatible core')

	monkeypatch.setattr(runtime, '_validate_core_update_source', fail_preflight)

	status = runtime.apply_core_update()

	assert status['core_update']['state'] == 'failed'
	assert status['core_update']['message'] == 'FaceFusion 核心升级包兼容性检查失败，当前核心未修改。'
	assert status['core_update']['backup_path'] is None
	assert (runtime.repo_root / 'facefusion' / 'marker.txt').read_text(encoding = 'utf-8') == 'old'


def test_apply_core_update_postflight_failure_rolls_back(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	write_core_payload(runtime.repo_root, 'old')
	package_path = write_core_archive(tmp_path)
	prepare_core_update(runtime, package_path)

	def validate_until_installed(source_root : Path, expected_version : str) -> None:
		if source_root.resolve() == runtime.repo_root.resolve():
			raise RuntimeError('installed core failed import')

	monkeypatch.setattr(runtime, '_validate_core_update_source', validate_until_installed)

	status = runtime.apply_core_update()

	assert status['core_update']['state'] == 'failed'
	assert status['core_update']['message'] == 'FaceFusion 核心升级失败，已自动恢复原核心。'
	assert status['core_update']['backup_path']
	assert (runtime.repo_root / 'facefusion' / 'marker.txt').read_text(encoding = 'utf-8') == 'old'
	assert (runtime.repo_root / 'facefusion.py').read_text(encoding = 'utf-8') == 'old'


def test_apply_core_update_success_keeps_backup(monkeypatch, tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	write_core_payload(runtime.repo_root, 'old')
	package_path = write_core_archive(tmp_path)
	prepare_core_update(runtime, package_path)
	monkeypatch.setattr(runtime, '_validate_core_update_source', lambda source_root, expected_version : None)

	status = runtime.apply_core_update()
	backup_path = Path(status['core_update']['backup_path'])

	assert status['core_update']['state'] == 'applied'
	assert status['core_update']['current_version'] == '3.9.0'
	assert (runtime.repo_root / 'facefusion' / 'marker.txt').read_text(encoding = 'utf-8') == 'new'
	assert (backup_path / 'facefusion' / 'marker.txt').read_text(encoding = 'utf-8') == 'old'


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
