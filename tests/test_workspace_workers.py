import importlib.util
import inspect
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PREVIEW_WORKER_PATH = REPO_ROOT / 'faceswap studio' / 'bridge' / 'services' / 'workspace_preview_worker.py'
SOURCE_FACE_EXTRACTOR_PATH = REPO_ROOT / 'faceswap studio' / 'bridge' / 'services' / 'source_face_extractor_worker.py'


def load_worker(module_name : str, worker_path : Path):
	spec = importlib.util.spec_from_file_location(module_name, worker_path)
	assert spec is not None
	assert spec.loader is not None
	module = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(module)
	return module


def test_preview_worker_uses_current_core_face_api_and_layout() -> None:
	worker = load_worker('workspace_preview_worker_test', PREVIEW_WORKER_PATH)

	args = worker._build_run_args(
		{
			'config_path': 'facefusion.ini',
			'temp_path': 'temp',
			'jobs_path': 'jobs',
			'source_paths': [ 'source.jpg' ],
			'target_path': 'target.jpg',
			'output_path': 'output.jpg',
		}
	)

	assert args[args.index('--ui-layouts') + 1] == 'default'
	assert worker.get_many_faces.__module__ == 'facefusion.face_creator'
	assert list(inspect.signature(worker.process_preview_frame).parameters)[4] == 'target_vision_frames'


def test_source_face_extractor_uses_current_core_face_api_and_layout() -> None:
	worker = load_worker('source_face_extractor_worker_test', SOURCE_FACE_EXTRACTOR_PATH)

	args = worker._build_run_args(
		{
			'config_path': 'facefusion.ini',
			'temp_path': 'temp',
			'jobs_path': 'jobs',
			'source_paths': [ 'source.jpg' ],
			'output_dir': 'output',
		}
	)

	assert args[args.index('--ui-layouts') + 1] == 'default'
	assert worker.get_many_faces.__module__ == 'facefusion.face_creator'
