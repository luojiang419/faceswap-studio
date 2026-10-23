import importlib.util
import json
from pathlib import Path
import threading
from concurrent.futures import ThreadPoolExecutor
import pytest
from types import SimpleNamespace


APP_SERVER_PATH = Path(__file__).resolve().parents[1] / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server_personas', APP_SERVER_PATH)
assert APP_SERVER_SPEC is not None
assert APP_SERVER_SPEC.loader is not None
APP_SERVER_MODULE = importlib.util.module_from_spec(APP_SERVER_SPEC)
APP_SERVER_SPEC.loader.exec_module(APP_SERVER_MODULE)
FaceFusionRuntime = APP_SERVER_MODULE.FaceFusionRuntime


def create_runtime(tmp_path : Path) -> FaceFusionRuntime:
	runtime = object.__new__(FaceFusionRuntime)
	studio_root = tmp_path / 'studio-root'
	repo_root = tmp_path / 'repo-root'
	output_dir = studio_root / 'data' / 'output'
	jobs_dir = studio_root / 'data' / 'jobs'
	runtime_dir = studio_root / 'runtime'
	favorites_path = studio_root / 'data' / 'favorites' / 'favorites.json'
	thumbnail_dir = studio_root / 'data' / 'cache' / 'thumbnails'
	playback_dir = studio_root / 'data' / 'cache' / 'playback'
	temp_dir = studio_root / 'data' / 'cache' / 'temp'
	models_dir = repo_root / '.assets' / 'models'
	personas_dir = studio_root / 'data' / 'personas'
	extracted_faces_dir = studio_root / 'data' / 'input' / 'extracted_faces'

	for path in [
		studio_root,
		repo_root,
		output_dir,
		runtime_dir,
		thumbnail_dir,
		playback_dir,
		temp_dir,
		models_dir,
		favorites_path.parent,
		personas_dir,
		extracted_faces_dir
	]:
		path.mkdir(parents = True, exist_ok = True)

	for status in APP_SERVER_MODULE.JOB_STATUSES:
		(jobs_dir / status).mkdir(parents = True, exist_ok = True)

	favorites_path.write_text('[]', encoding = 'utf-8')

	runtime._lock = threading.RLock()
	runtime._queue_lock = threading.RLock()
	runtime._workspace_run_lock = threading.Lock()
	runtime._preview_lock = threading.Lock()
	runtime._studio_root = studio_root
	runtime._repo_root = repo_root
	runtime._jobs_dir = jobs_dir
	runtime._temp_dir = temp_dir
	runtime._personas_dir = personas_dir
	runtime._extracted_faces_dir = extracted_faces_dir
	runtime._settings_template_path = studio_root / 'config' / 'settings.json'
	runtime._favorites_path = favorites_path
	runtime._runtime_dir = runtime_dir
	runtime._settings_path = runtime_dir / 'settings.json'
	runtime._models_dir = models_dir
	runtime._thumbnail_dir = thumbnail_dir
	runtime._playback_dir = playback_dir
	runtime._workspace_state_path = runtime_dir / 'workspace_state.json'
	runtime._workspace_options_path = runtime_dir / 'workspace_options.json'
	runtime._works_metadata_path = runtime_dir / 'works_metadata.json'
	runtime._output_dir = output_dir
	runtime._settings = { 'default_output_dir': str(output_dir), 'facefusion_port': 7860 }
	runtime._workspace_state = { 'source_paths': [], 'target_path': None }
	runtime._workspace_options = {}
	runtime._works_metadata = {}
	runtime._queue_runner_thread = None
	runtime._queue_runner_active = False
	runtime._queue_current_job_id = None
	runtime._queue_total_jobs = 0
	runtime._queue_completed_jobs = 0
	runtime._queue_last_error = None
	runtime._queue_progress_by_job = {}
	runtime._last_cli_error = None
	runtime._last_workspace_job_error = None
	runtime._append_log = lambda message : None
	runtime._resolve_thumbnail = lambda file_path : str(Path(file_path)) if file_path and Path(file_path).suffix.lower() in APP_SERVER_MODULE.IMAGE_EXTENSIONS else None

	return runtime


def create_source_image(runtime : FaceFusionRuntime, name : str) -> Path:
	source_path = runtime._studio_root / 'data' / 'input' / name
	source_path.parent.mkdir(parents = True, exist_ok = True)
	source_path.write_bytes(b'test-image')
	return source_path


def test_rename_persona_preserves_identity_images_and_workspace(tmp_path):
	runtime = create_runtime(tmp_path)
	source = create_source_image(runtime, 'face.png')
	runtime.set_workspace_source_paths([str(source)])
	persona = runtime.save_workspace_persona({'name': '原名称'})['persona']
	before = dict(persona)
	result = runtime.rename_persona(persona['id'], {'name': '  新名称  '})
	assert result['ok']
	assert result['persona']['name'] == '新名称'
	assert result['persona']['id'] == before['id']
	assert result['persona']['face_paths'] == before['face_paths']
	assert runtime.list_personas()['items'][0]['name'] == '新名称'
	assert runtime.workspace_state()['source_paths'] == [str(source)]
	assert Path(persona['face_paths'][0]).read_bytes() == b'test-image'
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.rename_persona(persona['id'], {'name': '  '})
	assert error.value.status_code == 400
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.rename_persona('../outside', {'name': 'bad'})
	assert error.value.status_code == 404


def test_source_progress_is_batch_scoped_and_does_not_hold_extraction_lock(tmp_path):
	runtime = create_runtime(tmp_path)
	path = runtime._source_progress_path('batch-a')
	path.parent.mkdir(parents=True)
	path.write_text(json.dumps({'request_id': 'batch-a', 'processed': 2, 'total': 4}), encoding='utf-8')
	with runtime._preview_lock:
		assert runtime.source_extraction_progress('batch-a')['processed'] == 2
		assert runtime.source_extraction_progress('batch-b')['processed'] == 0
	for invalid in ['../settings', 'a/b', 'a\\b', 'x' * 81]:
		with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
			runtime.source_extraction_progress(invalid)
		assert error.value.status_code == 400


@pytest.mark.parametrize('failure', ['timeout', 'invalid_json', 'empty', 'worker_error'])
def test_source_progress_stops_on_worker_failure_without_losing_partial_count(tmp_path, monkeypatch, failure):
	runtime = create_runtime(tmp_path)
	runtime._build_env = lambda: {}
	def fail(command, **kwargs):
		payload = json.loads(kwargs['input'])
		path = Path(payload['progress_path'])
		path.write_text(json.dumps({'request_id': 'batch-failed', 'state': 'running',
			'processed': 1, 'recognized': 1, 'skipped': 0, 'total': 2}), encoding='utf-8')
		if failure == 'timeout':
			raise APP_SERVER_MODULE.subprocess.TimeoutExpired(command, 300)
		return SimpleNamespace(returncode=1 if failure == 'worker_error' else 0, stderr='',
			stdout={'invalid_json': '{', 'empty': '', 'worker_error': '{"ok": false, "message": "failed"}'}[failure])
	monkeypatch.setattr(APP_SERVER_MODULE.subprocess, 'run', fail)
	result = runtime._run_source_face_extractor(['a.jpg', 'b.jpg'], request_id='batch-failed')
	assert not result['ok']
	progress = runtime.source_extraction_progress('batch-failed')
	assert progress['state'] == 'failed'
	assert progress['processed'] == progress['recognized'] == 1
	assert progress['total'] == 2


def test_save_workspace_persona_generates_numbered_files_and_manifest(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_a = create_source_image(runtime, 'face-a.png')
	source_b = create_source_image(runtime, 'face-b.jpg')
	runtime.set_workspace_source_paths([ str(source_a), str(source_b) ])

	result = runtime.save_workspace_persona({ 'name': '测试人物' })
	persona = result['persona']
	persona_dir = runtime._personas_dir / persona['id']
	manifest = json.loads((persona_dir / 'manifest.json').read_text(encoding = 'utf-8'))

	assert result['ok'] is True
	assert (persona_dir / '001.png').exists()
	assert (persona_dir / '002.jpg').exists()
	assert manifest['name'] == '测试人物'
	assert manifest['preview_path'] == persona['preview_path']
	assert len(manifest['face_paths']) == 2


def test_use_persona_loads_all_face_paths_into_workspace(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_a = create_source_image(runtime, 'angle-a.png')
	source_b = create_source_image(runtime, 'angle-b.png')
	runtime.set_workspace_source_paths([ str(source_a), str(source_b) ])
	persona = runtime.save_workspace_persona({ 'name': '多角度人物' })['persona']
	runtime.clear_workspace_source_paths()

	result = runtime.use_persona(persona['id'])

	assert result['ok'] is True
	assert result['workspace']['source_paths'] == persona['face_paths']


def test_delete_persona_removes_directory_and_list_entry(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path = create_source_image(runtime, 'delete-me.png')
	runtime.set_workspace_source_paths([ str(source_path) ])
	persona = runtime.save_workspace_persona({ 'name': '待删除人物' })['persona']
	persona_dir = runtime._personas_dir / persona['id']

	result = runtime.delete_persona(persona['id'])

	assert result['ok'] is True
	assert not persona_dir.exists()
	assert all(item['id'] != persona['id'] for item in result['items'])


def test_extract_workspace_source_faces_updates_workspace_from_worker_result(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path = create_source_image(runtime, 'full-body.png')
	extracted_path = create_source_image(runtime, 'extracted_faces/batch/001.png')

	def fake_extract(image_paths : list[str]) -> dict:
		return {
			'ok': True,
			'message': '已提取 1 张源脸。',
			'faces': [
				{
					'source_path': image_paths[0],
					'face_path': str(extracted_path),
					'preview_score': 0.9
				}
			],
			'skipped': []
		}

	runtime._run_source_face_extractor = fake_extract

	result = runtime.extract_workspace_source_faces([ str(source_path) ])

	assert result['ok'] is True
	assert result['workspace']['source_paths'] == [ str(extracted_path) ]


@pytest.mark.parametrize('extract_ok', [True, False])
def test_target_import_completes_while_source_extraction_waits(tmp_path : Path, extract_ok : bool) -> None:
	runtime = create_runtime(tmp_path)
	previous_source = create_source_image(runtime, 'previous-face.png')
	source_path = create_source_image(runtime, 'full-body.png')
	extracted_path = create_source_image(runtime, 'extracted_faces/batch/001.png')
	target_path = create_source_image(runtime, 'target.png')
	runtime.set_workspace_source_paths([str(previous_source)])
	started = threading.Event()
	release = threading.Event()

	def fake_extract(image_paths : list[str]) -> dict:
		started.set()
		assert release.wait(5), '测试识别等待未被释放'
		return {
			'ok': extract_ok,
			'faces': [{'source_path': image_paths[0], 'face_path': str(extracted_path)}] if extract_ok else [],
			'skipped': []
		}

	runtime._run_source_face_extractor = fake_extract
	with ThreadPoolExecutor(max_workers = 2) as executor:
		source_future = executor.submit(runtime.extract_workspace_source_faces, [str(source_path)])
		try:
			assert started.wait(3)
			target_future = executor.submit(runtime.set_workspace_target_path, str(target_path))
			target_result = target_future.result(timeout = 3)
			assert target_result['target_path'] == str(target_path)
			assert not source_future.done(), '视频应在人脸识别完成之前返回'
		finally:
			release.set()
		source_result = source_future.result(timeout = 3)

	assert source_result['ok'] is extract_ok
	state = runtime.workspace_state()
	assert state['target_path'] == str(target_path)
	assert state['source_paths'] == [str(extracted_path if extract_ok else previous_source)]
	saved = json.loads(runtime._workspace_state_path.read_text(encoding = 'utf-8'))
	assert saved['source_paths'] == state['source_paths']
	assert saved['target_path'] == state['target_path']


@pytest.mark.parametrize('append', [True, False])
def test_multi_batch_source_drop_preserves_previous_faces_only_when_appending(tmp_path : Path, append : bool) -> None:
	runtime = create_runtime(tmp_path)
	previous = create_source_image(runtime, 'previous.png')
	sources = [create_source_image(runtime, f'source-{index}.png') for index in range(2)]
	faces = [create_source_image(runtime, f'faces/{index}.png') for index in range(2)]
	runtime.set_workspace_source_paths([str(previous)])
	runtime._run_source_face_extractor = lambda paths: {
		'ok': True,
		'faces': [{'source_path': path, 'face_path': str(face)} for path, face in zip(paths, faces)],
	}
	for _ in range(2):
		result = runtime.extract_workspace_source_faces([str(path) for path in sources], append=append)
		assert result['ok'] is True
		expected = ([str(previous)] if append else []) + [str(path) for path in faces]
		assert result['workspace']['source_paths'] == expected
		assert json.loads(runtime._workspace_state_path.read_text(encoding='utf-8'))['source_paths'] == expected


def test_failed_appending_keeps_previous_faces_and_audio_appending_keeps_faces(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	previous = create_source_image(runtime, 'previous.png')
	source = create_source_image(runtime, 'no-face.png')
	audio = runtime._studio_root / 'sample.wav'
	audio.write_bytes(b'fixture')
	runtime.set_workspace_source_paths([str(previous)])
	runtime._run_source_face_extractor = lambda paths: {'ok': False, 'faces': [], 'skipped': paths}
	result = runtime.extract_workspace_source_faces([str(source)], append=True)
	assert result['ok'] is False
	assert result['workspace']['source_paths'] == [str(previous)]
	for _ in range(2):
		result = runtime.extract_workspace_source_faces([str(audio)], append=True)
		assert result['workspace']['source_paths'] == [str(previous), str(audio)]


def test_save_persona_from_images_does_not_change_workspace(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	workspace_source = create_source_image(runtime, 'workspace-face.png')
	persona_source = create_source_image(runtime, 'persona-source.png')
	extracted_path = create_source_image(runtime, 'extracted_faces/batch/persona-face.png')
	runtime.set_workspace_source_paths([ str(workspace_source) ])

	def fake_extract(image_paths : list[str]) -> dict:
		return {
			'ok': True,
			'message': '已提取 1 张源脸。',
			'faces': [
				{
					'source_path': image_paths[0],
					'face_path': str(extracted_path),
					'preview_score': 0.95
				}
			],
			'skipped': []
		}

	runtime._run_source_face_extractor = fake_extract

	result = runtime.save_persona_from_images({
		'name': '页面添加人物',
		'paths': [ str(persona_source) ]
	})

	assert result['ok'] is True
	assert result['workspace']['source_paths'] == [ str(workspace_source) ]
	assert runtime.workspace_state()['source_paths'] == [ str(workspace_source) ]
	assert result['persona']['name'] == '页面添加人物'
	assert len(result['persona']['face_paths']) == 1
	assert Path(result['persona']['face_paths'][0]).exists()


def test_prepare_video_playback_returns_direct_path_for_non_mov(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	video_path = runtime._studio_root / 'data' / 'output' / 'sample.mp4'
	video_path.parent.mkdir(parents = True, exist_ok = True)
	video_path.write_bytes(b'test-video')

	result = runtime.prepare_video_playback({ 'path': str(video_path) })

	assert result['ok'] is True
	assert result['path'] == str(video_path.resolve())
	assert result['playback_path'] == str(video_path.resolve())
	assert result['proxied'] is False


def test_prepare_video_playback_generates_proxy_for_mov(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	video_path = runtime._studio_root / 'data' / 'output' / 'prores.mov'
	video_path.parent.mkdir(parents = True, exist_ok = True)
	video_path.write_bytes(b'test-prores')

	def fake_generate(file_path : Path, proxy_path : Path) -> bool:
		assert file_path == video_path.resolve()
		proxy_path.parent.mkdir(parents = True, exist_ok = True)
		proxy_path.write_bytes(b'proxy-video')
		return True

	runtime._generate_playback_proxy = fake_generate

	result = runtime.prepare_video_playback({ 'path': str(video_path) })

	assert result['ok'] is True
	assert result['path'] == str(video_path.resolve())
	assert result['playback_path'].endswith('.mp4')
	assert Path(result['playback_path']).exists()
	assert result['proxied'] is True


def test_generate_playback_proxy_uses_unique_temp_file(tmp_path : Path, monkeypatch) -> None:
	runtime = create_runtime(tmp_path)
	video_path = runtime._studio_root / 'data' / 'output' / 'locked-prores.mov'
	video_path.parent.mkdir(parents = True, exist_ok = True)
	video_path.write_bytes(b'test-prores')
	proxy_path = runtime._playback_proxy_cache_path(video_path.resolve())
	assert proxy_path is not None
	legacy_temp_path = proxy_path.with_suffix('.tmp.mp4')
	legacy_temp_path.parent.mkdir(parents = True, exist_ok = True)
	legacy_temp_path.write_bytes(b'legacy-temp')
	commands : list[list[str]] = []

	runtime._resolve_ffmpeg_for_thumbnail = lambda : 'ffmpeg.exe'

	class FakeResult:
		returncode = 0
		stdout = ''
		stderr = ''

	def fake_run(command : list[str], **kwargs) -> FakeResult:
		commands.append(command)
		Path(command[-1]).write_bytes(b'proxy-video')
		return FakeResult()

	monkeypatch.setattr(APP_SERVER_MODULE.subprocess, 'run', fake_run)

	assert runtime._generate_playback_proxy(video_path.resolve(), proxy_path) is True
	assert commands
	assert commands[0][-1] != str(legacy_temp_path)
	assert proxy_path.exists()
	assert legacy_temp_path.exists()


def test_prepare_video_playback_handles_proxy_generation_os_error(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	video_path = runtime._studio_root / 'data' / 'output' / 'locked-prores.mov'
	video_path.parent.mkdir(parents = True, exist_ok = True)
	video_path.write_bytes(b'test-prores')

	def fake_generate(file_path : Path, proxy_path : Path) -> bool:
		raise PermissionError('locked temp file')

	runtime._generate_playback_proxy = fake_generate

	result = runtime.prepare_video_playback({ 'path': str(video_path) })

	assert result['ok'] is False
	assert result['path'] == str(video_path.resolve())
	assert result['playback_path'] == str(video_path.resolve())
	assert result['proxied'] is False
	assert result['message'] == 'ProRes 播放代理生成失败。'


def test_prepare_video_playback_rejects_missing_file(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	result = runtime.prepare_video_playback({ 'path': str(tmp_path / 'missing.mov') })

	assert result['ok'] is False
	assert result['playback_path'] == ''
	assert result['proxied'] is False
