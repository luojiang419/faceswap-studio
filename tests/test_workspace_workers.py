import importlib.util
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import numpy


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


def test_source_extraction_publishes_real_per_image_progress(tmp_path, monkeypatch):
	worker = load_worker('source_face_progress_test', SOURCE_FACE_EXTRACTOR_PATH)
	progress_path = tmp_path / 'progress.json'
	payload = {'source_paths': ['a.jpg', 'b.jpg', 'c.jpg'],
		'output_dir': str(tmp_path / 'faces'), 'progress_path': str(progress_path), 'request_id': 'batch-1'}
	face = SimpleNamespace(bounding_box=[20, 20, 70, 80], landmark_set={}, score_set={'detector': .9}, angle=0)
	results = iter([[face], [], [face]])
	monkeypatch.setattr(worker, '_initialize_state', lambda _: None)
	monkeypatch.setattr(worker, '_models_pre_check', lambda: True)
	monkeypatch.setattr(worker, 'is_image', lambda _: True)
	monkeypatch.setattr(worker, 'read_static_image', lambda _: numpy.ones((100, 100, 3), dtype=numpy.uint8))
	monkeypatch.setattr(worker, 'get_many_faces', lambda _: next(results))
	monkeypatch.setattr(worker, 'sort_and_filter_faces', lambda _, faces: faces)
	snapshots = []
	write_json = worker.atomic_write_json
	def capture(path, value):
		write_json(path, value)
		snapshots.append(json.loads(path.read_text('utf-8')))
	monkeypatch.setattr(worker, 'atomic_write_json', capture)
	result = worker._extract_faces(payload)
	assert result['ok']
	assert [value['processed'] for value in snapshots] == [0, 0, 1, 2, 3, 3]
	assert snapshots[3]['recognized'] == 1
	assert snapshots[3]['skipped'] == 1
	assert snapshots[-1] == {'request_id': 'batch-1', 'state': 'completed', 'processed': 3,
		'recognized': 2, 'skipped': 1, 'total': 3}
	assert all(Path(face['face_path']).is_file() for face in result['faces'])
