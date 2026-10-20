import importlib.util
import json
from pathlib import Path
import threading
import base64
import os
import pytest


APP_SERVER_PATH = Path(__file__).resolve().parents[1] / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server_workspace_options', APP_SERVER_PATH)
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
	temp_dir = studio_root / 'data' / 'cache' / 'temp'
	models_dir = repo_root / '.assets' / 'models'

	for path in [
		studio_root,
		repo_root,
		output_dir,
		runtime_dir,
		thumbnail_dir,
		temp_dir,
		models_dir,
		favorites_path.parent
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
	runtime._personas_dir = studio_root / 'data' / 'personas'
	runtime._extracted_faces_dir = studio_root / 'data' / 'input' / 'extracted_faces'
	runtime._settings_template_path = studio_root / 'config' / 'settings.json'
	runtime._favorites_path = favorites_path
	runtime._runtime_dir = runtime_dir
	runtime._settings_path = runtime_dir / 'settings.json'
	runtime._models_dir = models_dir
	runtime._thumbnail_dir = thumbnail_dir
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


@pytest.mark.parametrize('dimensions', [(640, 360), (360, 640)])
def test_frame_thumbnail_reads_exact_frame_without_preview_lock_and_invalidates_cache(tmp_path, dimensions):

	import cv2
	import numpy
	runtime = create_runtime(tmp_path)
	video = runtime._studio_root / 'frames.avi'
	writer = cv2.VideoWriter(str(video), cv2.VideoWriter_fourcc(*'MJPG'), 10, dimensions)
	assert writer.isOpened()
	colors = [(0, 0, 240), (0, 240, 0), (240, 0, 0)]
	for color in colors:
		writer.write(numpy.full((dimensions[1], dimensions[0], 3), color, dtype=numpy.uint8))
	writer.release()
	runtime._workspace_state['target_path'] = str(video)
	runtime._workspace_options = {'preview_frame_number': 2}
	runtime._video_frame_thumbnail.cache_clear()
	# 生成模型可以占用预览锁，缩略图读取仍须立即完成。
	with runtime._preview_lock:
		for frame, color in enumerate(colors):
			result = runtime.workspace_frame_thumbnail({'target_path': str(video), 'frame_number': frame})
			image = cv2.imdecode(numpy.frombuffer(base64.b64decode(result['image_base64']), dtype=numpy.uint8), cv2.IMREAD_COLOR)
			assert result['frame_number'] == frame
			assert image.shape[1] <= 320 and image.shape[0] <= 180
			assert numpy.max(numpy.abs(image.mean(axis=(0, 1)) - color)) < 8
	assert runtime._workspace_options == {'preview_frame_number': 2}
	assert not runtime._workspace_state_path.exists()
	payload = {'target_path': str(video), 'frame_number': 1}
	runtime.workspace_frame_thumbnail(payload)
	assert runtime._video_frame_thumbnail.cache_info().hits == 1
	stat = video.stat()
	os.utime(video, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1000000000))
	runtime.workspace_frame_thumbnail(payload)
	assert runtime._video_frame_thumbnail.cache_info().misses == 4
	assert runtime._video_frame_thumbnail.cache_info().maxsize == 96
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail({**payload, 'frame_number': 3})
	assert error.value.status_code == 400
	video.unlink()  # 独立解码器已释放，Windows 上也应可立即删除。
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail(payload)
	assert error.value.status_code == 404


@pytest.mark.parametrize('frame', [None, True, -1, 1.5, '1'])
def test_frame_thumbnail_rejects_invalid_frame_numbers(tmp_path, frame):

	runtime = create_runtime(tmp_path)
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail({'frame_number': frame})
	assert error.value.status_code == 400


def test_frame_thumbnail_rejects_changed_nonvideo_or_unreadable_target(tmp_path):

	runtime = create_runtime(tmp_path)
	video = runtime._studio_root / 'broken.mp4'
	video.write_bytes(b'not a video')
	runtime._workspace_state['target_path'] = str(video)
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail({'target_path': 'previous.mp4', 'frame_number': 0})
	assert error.value.status_code == 409
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail({'target_path': str(video), 'frame_number': 0})
	assert error.value.status_code == 422
	runtime._workspace_state['target_path'] = str(video.with_suffix('.png'))
	with pytest.raises(APP_SERVER_MODULE.HTTPException) as error:
		runtime.workspace_frame_thumbnail({'target_path': str(video), 'frame_number': 0})
	assert error.value.status_code == 400


def test_close_behavior_defaults_to_first_prompt_and_persists_all_choices(tmp_path : Path) -> None:

	runtime = create_runtime(tmp_path)
	runtime._settings_template_path.parent.mkdir(parents = True)
	runtime._settings = runtime._load_settings()
	assert runtime.get_settings()['close_behavior'] == 'ask'
	assert runtime.get_settings()['close_behavior_configured'] is False
	for behavior in ('exit', 'minimize_to_tray', 'ask'):
		runtime.update_settings({ 'close_behavior': behavior })
		runtime._settings = runtime._load_settings()
		assert runtime.get_settings()['close_behavior'] == behavior
		assert runtime.get_settings()['close_behavior_configured'] is True
		assert json.loads(runtime._settings_path.read_text(encoding = 'utf-8'))['close_behavior'] == behavior


def test_close_behavior_save_failure_does_not_claim_preference_was_remembered(tmp_path, monkeypatch):

	runtime = create_runtime(tmp_path)
	runtime._settings = runtime._default_settings()
	def fail_save():
		raise OSError('disk full')
	monkeypatch.setattr(runtime, '_save_settings', fail_save)
	with pytest.raises(OSError):
		runtime.update_settings({ 'close_behavior': 'exit' })
	assert runtime.get_settings()['close_behavior'] == 'ask'
	assert runtime.get_settings()['close_behavior_configured'] is False


def test_close_behavior_preserves_legacy_choice_and_falls_back_to_ask(tmp_path : Path) -> None:

	runtime = create_runtime(tmp_path)
	for behavior in ('exit', 'minimize_to_tray'):
		assert runtime._normalize_settings({ 'close_behavior': behavior })['close_behavior'] == behavior
	for invalid in (None, '', 'unknown', False):
		assert runtime._normalize_settings({ 'close_behavior': invalid })['close_behavior'] == 'ask'
	assert runtime._normalize_settings({ 'close_behavior_configured': 'true' })['close_behavior_configured'] is False


def test_default_workspace_options_use_video_quality_100(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	defaults = runtime._default_workspace_options()

	assert defaults['output_video_quality'] == 100
	assert defaults['execution_thread_count'] == 14


def test_latest_core_models_reach_workspace_and_cli(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._available_processor_names = lambda : [ 'face_swapper' ]
	fields = runtime.workspace_options_schema()['fields']
	assert 'alphaface_256' in fields['face_swapper_model']['choices']
	assert 'hrffa' in fields['face_landmarker_model']['choices']
	options = runtime._normalize_workspace_options({
		'face_swapper_model': 'alphaface_256',
		'face_swapper_pixel_boost': '1024x1024',
		'face_landmarker_model': 'hrffa',
	})
	args = runtime._workspace_step_option_cli_args(options)
	for flag, value in [
		('--face-swapper-model', 'alphaface_256'),
		('--face-swapper-pixel-boost', '1024x1024'),
		('--face-landmarker-model', 'hrffa'),
	]:
		assert args[args.index(flag) + 1] == value
	from facefusion.program import create_program
	parsed = create_program().parse_args(['headless-run', *args])
	assert parsed.face_swapper_model == 'alphaface_256'
	assert parsed.face_swapper_pixel_boost == '1024x1024'
	assert parsed.face_landmarker_model == 'hrffa'


def test_webui_env_binds_gradio_to_configured_address(tmp_path : Path, monkeypatch) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings.update({'facefusion_host': '127.0.0.1', 'facefusion_port': 17861})
	monkeypatch.setenv('GRADIO_SERVER_PORT', '7860')
	monkeypatch.setenv('GRADIO_SERVER_NAME', '0.0.0.0')
	monkeypatch.setenv('GRADIO_NUM_PORTS', '100')
	env = runtime._build_env()
	assert env['GRADIO_SERVER_NAME'] == '127.0.0.1'
	assert env['GRADIO_SERVER_PORT'] == '17861'
	assert env['GRADIO_NUM_PORTS'] == '1'


def test_external_model_label_and_domestic_env_allow_system_proxy(tmp_path, monkeypatch):
    from facefusion import modelscope_assets
    # 标签路由使用固定夹具，不依赖不断补齐的实际魔搭镜像清单。
    monkeypatch.setattr(modelscope_assets, 'model_download_labels', lambda: {'deoldify_stable': '外网下载'})
    runtime = create_runtime(tmp_path)
    schema = runtime.workspace_options_schema()
    assert '外网下载' in schema['fields']['frame_colorizer_model']['choice_labels']['deoldify_stable']
    runtime._settings['model_download_mode'] = APP_SERVER_MODULE.MODEL_DOWNLOAD_MODE_DOMESTIC
    env = {'HTTPS_PROXY': 'http://old-proxy:9999', 'NO_PROXY': '*'}
    runtime._apply_model_download_env(env)
    assert env['NO_PROXY'] == APP_SERVER_MODULE.LOCAL_NO_PROXY
    assert 'HTTPS_PROXY' not in env
    assert env['FACEFUSION_DISABLE_PROXY'] == '1'


def test_facefusion_webui_command_uses_supported_default_layout(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	command = runtime._build_command()
	layout_index = command.index('--ui-layouts')

	assert command[layout_index + 1] == 'default'


def test_load_workspace_options_migrates_legacy_video_quality_80(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._workspace_options_path.write_text(
		json.dumps({ 'output_video_quality': 80 }, ensure_ascii = False),
		encoding = 'utf-8'
	)

	loaded = runtime._load_workspace_options()

	assert loaded['output_video_quality'] == 100


def test_load_workspace_options_preserves_non_default_video_quality(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._workspace_options_path.write_text(
		json.dumps({ 'output_video_quality': 72 }, ensure_ascii = False),
		encoding = 'utf-8'
	)

	loaded = runtime._load_workspace_options()

	assert loaded['output_video_quality'] == 72


def test_clear_workspace_options_resets_video_quality_to_100(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._workspace_options = runtime._default_workspace_options()
	runtime._workspace_options['output_video_quality'] = 61

	result = runtime.clear_workspace_options()

	assert result['options']['output_video_quality'] == 100


def test_workspace_state_includes_cached_target_video_frame_total(tmp_path : Path, monkeypatch) -> None:
	runtime = create_runtime(tmp_path)
	target_path = tmp_path / 'target.mp4'
	target_path.write_bytes(b'fake video')
	counted_paths = []

	def fake_count_video_frame_total(path : str) -> int:
		counted_paths.append(path)
		return 270

	monkeypatch.setattr(APP_SERVER_MODULE, 'count_video_frame_total', fake_count_video_frame_total)
	runtime._workspace_state['target_path'] = str(target_path)

	state = runtime.workspace_state()
	state_again = runtime.workspace_state()

	assert state['target_media_type'] == 'video'
	assert state['target_video_frame_total'] == 270
	assert state_again['target_video_frame_total'] == 270
	assert counted_paths == [ str(target_path) ]


def test_settings_persist_sidebar_expanded(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings = runtime._default_settings()

	assert runtime._settings['sidebar_expanded'] is False

	result = runtime.update_settings({ 'sidebar_expanded': True })

	assert result['sidebar_expanded'] is True
	assert json.loads(runtime._settings_path.read_text(encoding = 'utf-8'))['sidebar_expanded'] is True


def test_settings_persist_content_analyser_score(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings = runtime._default_settings()

	result = runtime.update_settings({ 'content_analyser_score': 150.0 })
	saved_settings = json.loads(runtime._settings_path.read_text(encoding = 'utf-8'))

	if hasattr(APP_SERVER_MODULE.facefusion_choices, 'content_analyser_score_range'):
		assert result['content_analyser_score'] == 150.0
		assert saved_settings['content_analyser_score'] == 150.0
		assert runtime._content_analyser_cli_args() == [ '--content-analyser-score', '150.0' ]
	else:
		assert result['content_analyser_score'] == APP_SERVER_MODULE.DEFAULT_CONTENT_ANALYSER_SCORE
		assert saved_settings['content_analyser_score'] == APP_SERVER_MODULE.DEFAULT_CONTENT_ANALYSER_SCORE
		assert runtime._content_analyser_cli_args() == []


def test_settings_persist_workspace_options_panel_width(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._settings = runtime._default_settings()

	result = runtime.update_settings({ 'workspace_options_panel_width': 612.4 })
	saved_settings = json.loads(runtime._settings_path.read_text(encoding = 'utf-8'))

	assert result['workspace_options_panel_width'] == 612.4
	assert saved_settings['workspace_options_panel_width'] == 612.4


def test_workspace_options_schema_exposes_advanced_metadata(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._available_processor_names = lambda : [ 'face_swapper', 'face_enhancer', 'background_remover' ]
	runtime._workspace_options = runtime._default_workspace_options()

	schema = runtime.workspace_options_schema()
	fields = schema['fields']

	assert schema['version'] == 2
	assert fields['processors']['choices'] == [ 'face_swapper', 'face_enhancer', 'background_remover' ]
	assert fields['output_video_encoder']['panel'] == 'common'
	assert fields['background_remover_fill_color']['control'] == 'rgba'
	assert fields['face_selector_age_start']['paired_key'] == 'face_selector_age_end'
	assert fields['trim_frame_start']['control'] == 'frame_range'
	assert fields['execution_thread_count']['panel'] == 'advanced'
	assert fields['execution_thread_count']['section_label'] == '执行设置'
	assert fields['execution_thread_count']['default'] == 14
	assert fields['execution_thread_count']['minimum'] == 1
	assert fields['execution_thread_count']['maximum'] == 32
	assert 'reference_face_position' not in fields


def test_workspace_step_option_cli_args_cover_extended_core_controls(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	runtime._available_processor_names = lambda : [ 'face_swapper', 'background_remover', 'lip_syncer' ]
	options = runtime._default_workspace_options()
	options.update(
		{
			'processors': [ 'face_swapper', 'background_remover', 'lip_syncer' ],
			'background_remover_fill_color': [ 12, 34, 56, 78 ],
			'background_remover_despill_color': [ 87, 65, 43, 21 ],
			'face_selector_gender': 'female',
			'face_selector_age_start': 18,
			'face_selector_age_end': 42,
			'face_mask_types': [ 'box', 'region' ],
			'face_mask_regions': [ 'skin', 'mouth' ],
			'face_mask_padding': [ 1, 2, 3, 4 ],
			'trim_frame_start': 10,
			'trim_frame_end': 80,
			'keep_temp': True,
			'preview_frame_number': 24,
			'output_audio_encoder': 'aac',
			'output_audio_quality': 73,
			'output_audio_volume': 88,
			'voice_extractor_model': 'kim_vocal_2',
			'lip_syncer_weight': 0.75,
			'execution_thread_count': 14,
		}
	)

	args = runtime._workspace_step_option_cli_args(options)

	assert '--background-remover-fill-color' in args
	fill_index = args.index('--background-remover-fill-color')
	assert args[fill_index + 1:fill_index + 5] == [ '12', '34', '56', '78' ]
	assert '--background-remover-despill-color' in args
	assert '--face-selector-gender' in args
	assert '--face-selector-age-start' in args
	assert '--reference-frame-number' in args
	assert '--face-mask-padding' in args
	assert '--trim-frame-start' in args
	assert '--trim-frame-end' in args
	assert '--keep-temp' in args
	assert '--output-audio-encoder' in args
	assert '--voice-extractor-model' in args
	assert '--lip-syncer-weight' in args
	assert '--execution-thread-count' not in args
