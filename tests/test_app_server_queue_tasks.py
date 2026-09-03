import importlib.util
import json
from pathlib import Path
import threading


APP_SERVER_PATH = Path(__file__).resolve().parents[1] / 'faceswap studio' / 'bridge' / 'app_server.py'
APP_SERVER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_bridge_app_server_queue_tasks', APP_SERVER_PATH)
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
	runtime._queue_current_process = None
	runtime._queue_total_jobs = 0
	runtime._queue_completed_jobs = 0
	runtime._queue_last_error = None
	runtime._queue_progress_by_job = {}
	runtime._queue_cancel_requested_job_ids = set()
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
				'date_created': '2026-06-24T10:00:00',
				'date_updated': '2026-06-24T10:05:00',
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


class StubProcess:
	def __init__(self, pid : int) -> None:
		self.pid = pid

	def poll(self) -> None:
		return None


def test_cancel_queue_task_removes_inactive_queued_job_and_updates_runner_total(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	active_output_path = runtime._output_dir / 'active.png'
	active_output_path.write_bytes(b'active')
	write_job_record(
		runtime,
		job_id = 'job-active',
		status = 'queued',
		source_path = source_path,
		target_path = target_path,
		output_path = active_output_path
	)
	write_job_record(
		runtime,
		job_id = 'job-pending',
		status = 'queued',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)
	runtime._queue_runner_active = True
	runtime._queue_current_job_id = 'job-active'
	runtime._queue_total_jobs = 2

	result = runtime.cancel_queue_task('job-pending')

	assert result['ok'] is True
	assert result['message'] == '已取消任务：job-pending'
	assert not (runtime._jobs_dir / 'queued' / 'job-pending.json').exists()
	assert result['runner']['total_jobs'] == 1


def test_cancel_queue_task_requests_termination_for_active_job(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	write_job_record(
		runtime,
		job_id = 'job-running',
		status = 'queued',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)
	runtime._queue_current_job_id = 'job-running'
	runtime._queue_current_process = StubProcess(4321)
	runtime._queue_progress_by_job['job-running'] = {
		'progress_percent': 48.5,
		'progress_phase': 'processing',
		'progress_detail': '处理中'
	}
	terminated_pids : list[int] = []
	runtime._terminate_process_tree = lambda pid : terminated_pids.append(pid)

	result = runtime.cancel_queue_task('job-running')

	assert result['ok'] is True
	assert result['message'] == '已请求取消运行中的任务：job-running'
	assert terminated_pids == [ 4321 ]
	assert 'job-running' in runtime._queue_cancel_requested_job_ids
	assert result['tasks'][0]['progress_detail'] == '正在取消任务...'
	assert (runtime._jobs_dir / 'queued' / 'job-running.json').exists()


def test_run_queue_worker_marks_cancelled_job_as_failed_without_last_error(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	source_path, target_path, output_path = create_media_fixture(runtime)
	write_job_record(
		runtime,
		job_id = 'job-cancelled',
		status = 'queued',
		source_path = source_path,
		target_path = target_path,
		output_path = output_path
	)
	runtime._queue_runner_active = True
	runtime._queue_total_jobs = 1
	runtime._queue_cancel_requested_job_ids.add('job-cancelled')
	runtime._run_single_job = lambda job_id : APP_SERVER_MODULE.QUEUE_CANCELLED_EXIT_CODE

	runtime._run_queue_worker()

	failed_path = runtime._jobs_dir / 'failed' / 'job-cancelled.json'
	assert failed_path.exists()
	assert not (runtime._jobs_dir / 'queued' / 'job-cancelled.json').exists()
	assert runtime._queue_last_error is None
	assert runtime._queue_current_job_id is None
	assert runtime._queue_completed_jobs == 1
	assert 'job-cancelled' not in runtime._queue_cancel_requested_job_ids

	payload = json.loads(failed_path.read_text(encoding = 'utf-8'))
	assert payload['studio_queue_detail'] == '任务已取消。'
	assert payload['steps'][0]['status'] == 'failed'


def test_normalize_job_payload_paths_keeps_installed_studio_output_path(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	install_root = tmp_path / 'Program Files' / 'FaceSwap Studio'
	runtime._studio_root = install_root / 'faceswap studio'
	output_path = runtime._studio_root / 'data' / 'output' / 'video' / 'queued.mp4'
	payload = {
		'steps': [
			{
				'args': {
					'output_path': str(output_path)
				}
			}
		]
	}

	changed = runtime._normalize_job_payload_paths(payload)

	assert changed is False
	assert payload['steps'][0]['args']['output_path'] == str(output_path)


def test_normalize_job_payload_paths_collapses_repeated_installed_studio_output_path(tmp_path : Path) -> None:
	runtime = create_runtime(tmp_path)
	install_root = tmp_path / 'Program Files' / 'FaceSwap Studio'
	runtime._studio_root = install_root / 'faceswap studio'
	output_path = runtime._studio_root / 'data' / 'output' / 'video' / 'queued.mp4'
	repeated_output_path = (
		runtime._studio_root /
		'faceswap studio' /
		'faceswap studio' /
		'data' /
		'output' /
		'video' /
		'queued.mp4'
	)
	payload = {
		'steps': [
			{
				'args': {
					'output_path': str(repeated_output_path)
				}
			}
		]
	}

	changed = runtime._normalize_job_payload_paths(payload)

	assert changed is True
	assert payload['steps'][0]['args']['output_path'] == str(output_path)
