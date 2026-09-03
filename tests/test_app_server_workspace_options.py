import importlib.util
import json
from pathlib import Path
import threading


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


def test_default_workspace_options_use_video_quality_100(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)

	defaults = runtime._default_workspace_options()

	assert defaults['output_video_quality'] == 100
	assert defaults['execution_thread_count'] == 14


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
