import importlib.util
from pathlib import Path
import zlib

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_SERVER_PATH = REPO_ROOT / 'faceswap studio' / 'bridge' / 'app_server.py'
MODEL_VALIDATOR_PATH = REPO_ROOT / 'scripts' / 'validate_offline_models.py'
OFFLINE_MODEL_MANIFEST = REPO_ROOT / 'installer' / 'core-models.txt'


def load_module(name : str, path : Path):
	spec = importlib.util.spec_from_file_location(name, path)
	assert spec is not None
	assert spec.loader is not None
	module = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(module)
	return module


APP_SERVER = load_module('faceswap_studio_offline_models_app_server', APP_SERVER_PATH)
MODEL_VALIDATOR = load_module('faceswap_studio_offline_models_validator', MODEL_VALIDATOR_PATH)


def test_offline_model_manifest_matches_bridge_core_package() -> None:
	manifest_names = MODEL_VALIDATOR.load_manifest(OFFLINE_MODEL_MANIFEST)
	bridge_names = [ model['file'] for model in APP_SERVER.CORE_MODEL_PACKAGE ]

	assert manifest_names == bridge_names


def test_validate_offline_models_accepts_matching_hash(tmp_path : Path) -> None:
	models_dir = tmp_path / 'models'
	models_dir.mkdir()
	model_bytes = b'offline model fixture'
	(models_dir / 'example.onnx').write_bytes(model_bytes)
	(models_dir / 'example.hash').write_text(format(zlib.crc32(model_bytes), '08x'), encoding = 'utf-8')
	manifest_path = tmp_path / 'models.txt'
	manifest_path.write_text('example.hash\nexample.onnx\n', encoding = 'utf-8')

	result = MODEL_VALIDATOR.validate_offline_models(manifest_path, models_dir)

	assert result == {
		'file_count': 2,
		'model_count': 1,
		'total_bytes': len(model_bytes) + 8,
	}


def test_validate_offline_models_rejects_hash_mismatch(tmp_path : Path) -> None:
	models_dir = tmp_path / 'models'
	models_dir.mkdir()
	(models_dir / 'example.onnx').write_bytes(b'corrupt')
	(models_dir / 'example.hash').write_text('00000000', encoding = 'utf-8')
	manifest_path = tmp_path / 'models.txt'
	manifest_path.write_text('example.hash\nexample.onnx\n', encoding = 'utf-8')

	with pytest.raises(ValueError, match='hash mismatch'):
		MODEL_VALIDATOR.validate_offline_models(manifest_path, models_dir)
