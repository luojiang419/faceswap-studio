#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
import zlib


def load_manifest(manifest_path : Path) -> list[str]:
	model_names = []
	for raw_line in manifest_path.read_text(encoding = 'utf-8').splitlines():
		model_name = raw_line.strip()
		if not model_name or model_name.startswith('#'):
			continue
		if Path(model_name).name != model_name:
			raise ValueError(f'Offline model manifest contains an unsafe path: {model_name}')
		if model_name in model_names:
			raise ValueError(f'Offline model manifest contains a duplicate: {model_name}')
		model_names.append(model_name)
	return model_names


def create_file_hash(file_path : Path) -> str:
	checksum = 0
	with file_path.open('rb') as file_handle:
		while chunk := file_handle.read(1024 * 1024):
			checksum = zlib.crc32(chunk, checksum)
	return format(checksum & 0xffffffff, '08x')


def validate_offline_models(manifest_path : Path, models_dir : Path) -> dict[str, int]:
	model_names = load_manifest(manifest_path)
	if not model_names:
		raise ValueError('Offline model manifest is empty.')

	missing_files = [ model_name for model_name in model_names if not (models_dir / model_name).is_file() ]
	if missing_files:
		raise FileNotFoundError(f"Offline model files are missing: {', '.join(missing_files)}")

	onnx_names = [ model_name for model_name in model_names if model_name.endswith('.onnx') ]
	for onnx_name in onnx_names:
		hash_name = str(Path(onnx_name).with_suffix('.hash'))
		if hash_name not in model_names:
			raise ValueError(f'Offline model hash is not listed: {hash_name}')
		expected_hash = (models_dir / hash_name).read_text(encoding = 'utf-8').strip().lower()
		actual_hash = create_file_hash(models_dir / onnx_name)
		if actual_hash != expected_hash:
			raise ValueError(f'Offline model hash mismatch: {onnx_name}')

	return {
		'file_count': len(model_names),
		'model_count': len(onnx_names),
		'total_bytes': sum((models_dir / model_name).stat().st_size for model_name in model_names),
	}


def main() -> None:
	parser = argparse.ArgumentParser()
	parser.add_argument('--manifest', required = True, type = Path)
	parser.add_argument('--models-dir', required = True, type = Path)
	args = parser.parse_args()
	result = validate_offline_models(args.manifest, args.models_dir)
	print(json.dumps(result, ensure_ascii = False))


if __name__ == '__main__':
	main()
