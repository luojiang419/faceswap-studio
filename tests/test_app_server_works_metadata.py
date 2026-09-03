import importlib.util
import json
from pathlib import Path
import threading


APP_SERVER_PATH = Path(__file__).resolve().parents[1] / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server', APP_SERVER_PATH)
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

	for path in [ studio_root, repo_root, output_dir, runtime_dir, thumbnail_dir, temp_dir, models_dir, favorites_path.parent ]:
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
	runtime._settings = { 'default_output_dir': str(output_dir) }
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


def create_media_fixture(runtime : FaceFusionRuntime, suffix : str = '.png') -> tuple[Path, Path, Path]:
	source_path = runtime._studio_root / 'data' / 'input' / f'source{suffix}'
	target_path = runtime._studio_root / 'data' / 'input' / f'target{suffix}'
	output_path = runtime._output_dir / f'output{suffix}'

	source_path.parent.mkdir(parents = True, exist_ok = True)
	for path in [ source_path, target_path, output_path ]:
		path.write_bytes(b'test-media')

	return source_path, target_path, output_path


def write_job_record(
	runtime : FaceFusionRuntime,
	*,
	job_id : str,
	status : str,
	source_path : Path,
	target_path : Path,
	output_path : Path
) -> None:
	job_path = runtime._jobs_dir / status / f'{job_id}.json'
	job_path.write_text(
		json.dumps(
			{
				'date_created': '2026-06-23T10:00:00',
				'date_updated': '2026-06-23T10:05:00',
				'steps': [
					{
						'args': {
							'source_paths': [ str(source_path) ],
							'target_path': str(target_path),
							'output_path': str(output_path)
						}
					}
				]
			},
			ensure_ascii = False,
			indent = 2
		),
		encoding = 'utf-8'
	)


def get_file_work(works_state : dict) -> dict:
	return next(item for item in works_state['items'] if item.get('source') == 'file')


def read_works_metadata(runtime : FaceFusionRuntime) -> dict:
	return json.loads(runtime._works_metadata_path.read_text(encoding = 'utf-8'))


def test_list_works_persists_compare_metadata(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	write_job_record(
		runtime,
		job_id = 'job-test-works-metadata',
		status = 'completed',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)

	works_state = runtime.list_works()
	work_item = get_file_work(works_state)
	output_key = runtime._normalize_work_metadata_key(str(output_path))
	metadata = read_works_metadata(runtime)

	assert work_item['target_path'] == str(target_path.resolve())
	assert work_item['target_media_type'] == 'image'
	assert work_item['output_media_type'] == 'image'
	assert output_key in metadata
	assert metadata[output_key]['target_path'] == str(target_path.resolve())
	assert metadata[output_key]['output_media_type'] == 'image'


def test_list_works_keeps_compare_metadata_after_clearing_completed_tasks(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	write_job_record(
		runtime,
		job_id = 'job-test-clear-completed',
		status = 'completed',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)

	runtime.list_works()
	clear_state = runtime.clear_completed_queue_tasks()
	works_state = runtime.list_works()
	work_item = get_file_work(works_state)

	assert clear_state['ok'] is True
	assert clear_state['removed_count'] == 1
	assert work_item['target_path'] == str(target_path.resolve())
	assert work_item['target_media_type'] == 'image'
	assert work_item['output_media_type'] == 'image'


def test_delete_work_removes_persisted_metadata(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	write_job_record(
		runtime,
		job_id = 'job-test-delete-work',
		status = 'completed',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)

	works_state = runtime.list_works()
	work_item = get_file_work(works_state)
	output_key = runtime._normalize_work_metadata_key(str(output_path))

	assert output_key in read_works_metadata(runtime)

	delete_state = runtime.delete_work(work_item['id'])
	metadata = read_works_metadata(runtime)

	assert not output_path.exists()
	assert output_key not in metadata
	assert not any(item.get('source') == 'file' and item.get('path') == str(output_path.resolve()) for item in delete_state['items'])
