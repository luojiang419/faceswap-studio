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
	(repo_root / '易容 Studio.exe').write_bytes(b'launcher')

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


def test_check_updates_uses_signed_service(tmp_path):
    runtime = create_runtime(tmp_path)
    class Service:
        def check(self): return {"state": "current", "provider": "modelscope"}
    runtime._signed_update_service = Service()
    assert runtime.check_updates() == {"state": "current", "provider": "modelscope"}


def test_apply_blocked_while_generation_runs(tmp_path):
    runtime = create_runtime(tmp_path)
    runtime._queue_runner_active = True
    runtime._queue_current_process = None
    class Service:
        def status(self): return {"state": "downloaded"}
        def apply(self): raise AssertionError("不能在任务执行中升级")
    runtime._signed_update_service = Service()
    assert runtime.apply_update()["state"] == "failed"
