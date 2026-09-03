import importlib.util
from pathlib import Path

from fastapi.testclient import TestClient


APP_SERVER_PATH = Path(__file__).resolve().parents[1] / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server_web_studio', APP_SERVER_PATH)
assert APP_SERVER_SPEC is not None
assert APP_SERVER_SPEC.loader is not None
APP_SERVER_MODULE = importlib.util.module_from_spec(APP_SERVER_SPEC)
APP_SERVER_SPEC.loader.exec_module(APP_SERVER_MODULE)
FaceFusionRuntime = APP_SERVER_MODULE.FaceFusionRuntime


def create_runtime(tmp_path : Path) -> FaceFusionRuntime:
	runtime = object.__new__(FaceFusionRuntime)
	studio_root = tmp_path / 'studio-root'
	output_dir = studio_root / 'data' / 'output'
	thumbnail_dir = studio_root / 'data' / 'cache' / 'thumbnails'
	playback_dir = studio_root / 'data' / 'cache' / 'playback'
	uploads_dir = studio_root / 'data' / 'uploads' / 'workspace'
	personas_dir = studio_root / 'data' / 'personas'
	extracted_faces_dir = studio_root / 'data' / 'input' / 'extracted_faces'
	web_root = studio_root / 'flutter_app' / 'build' / 'web'

	for path in [
		studio_root,
		output_dir,
		thumbnail_dir,
		playback_dir,
		uploads_dir,
		personas_dir,
		extracted_faces_dir,
		web_root
	]:
		path.mkdir(parents = True, exist_ok = True)

	runtime._studio_root = studio_root
	runtime._output_dir = output_dir
	runtime._thumbnail_dir = thumbnail_dir
	runtime._playback_dir = playback_dir
	runtime._studio_uploads_dir = uploads_dir
	runtime._personas_dir = personas_dir
	runtime._extracted_faces_dir = extracted_faces_dir
	runtime._flutter_web_root = web_root

	return runtime


def test_studio_status_reports_missing_web_build(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	status = runtime.studio_status()

	assert status['ok'] is True
	assert status['available'] is False
	assert status['local_url'].endswith('/studio/')
	assert status['path'] == str(runtime._flutter_web_root)


def test_studio_status_reports_available_web_build(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	(runtime._flutter_web_root / 'index.html').write_text('<html></html>', encoding = 'utf-8')

	status = runtime.studio_status()

	assert status['available'] is True
	assert status['message'] == 'Web 工作台可用。'


def test_studio_routes_serve_status_and_index(tmp_path : Path, monkeypatch) -> None:
	runtime = create_runtime(tmp_path)
	(runtime._flutter_web_root / 'index.html').write_text('<html>studio</html>', encoding = 'utf-8')
	monkeypatch.setattr(APP_SERVER_MODULE, 'runtime', runtime)
	client = TestClient(APP_SERVER_MODULE.app)

	status_response = client.get('/studio/status')
	index_response = client.get('/studio/')

	assert status_response.status_code == 200
	assert status_response.json()['available'] is True
	assert index_response.status_code == 200
	assert 'studio' in index_response.text


def test_studio_media_path_is_limited_to_allowed_roots(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	output_file = runtime._output_dir / 'result.png'
	upload_file = runtime._studio_uploads_dir / 'source.png'
	outside_file = tmp_path / 'private.png'
	for path in [ output_file, upload_file, outside_file ]:
		path.parent.mkdir(parents = True, exist_ok = True)
		path.write_bytes(b'image')

	assert runtime.resolve_studio_media_path(str(output_file)) == output_file.resolve()
	assert runtime.resolve_studio_media_path(str(upload_file)) == upload_file.resolve()
	assert runtime.resolve_studio_media_path(str(outside_file)) is None


def test_studio_upload_name_rejects_unsupported_extension(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	assert runtime._safe_upload_name('payload.exe', APP_SERVER_MODULE.IMAGE_EXTENSIONS) is None
	assert runtime._safe_upload_name('face.png', APP_SERVER_MODULE.IMAGE_EXTENSIONS) is not None
