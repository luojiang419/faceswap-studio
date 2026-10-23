import os
import hashlib
import zipfile
from pathlib import Path

import pytest

from scripts import build_full_offline as builder
from scripts import launch_original_webui as webui


def test_runtime_inventory_excludes_personal_data_and_partial_downloads(tmp_path):
    for name in ('.python/python.exe', '.venv-win/Scripts/python.exe', '.runtime/ffmpeg/ffmpeg.exe',
                 '.assets/models/model.onnx', '.assets/models/model.onnx.part', '.python/__pycache__/private.pyc',
                 'data/cache/bootstrap/large.zip', 'faceswap studio/data/favorites/person.jpg', '.env'):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'data')
    assert set(dict(builder.runtime_files(tmp_path))) == {
        '.python/python.exe', '.venv-win/Scripts/python.exe', '.runtime/ffmpeg/ffmpeg.exe', '.assets/models/model.onnx'}


def test_webui_preserves_explicit_proxy_and_removes_wildcard_bypass(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(webui, 'DLL_HANDLES', [])
    monkeypatch.setenv('NO_PROXY', '*,.example.com')
    monkeypatch.setenv('HTTPS_PROXY', 'http://127.0.0.1:9999')
    monkeypatch.setenv('PATH', os.environ['PATH'])
    monkeypatch.setattr(webui.sys, 'path', list(webui.sys.path))
    webui.prepare_environment(tmp_path)
    assert os.environ['NO_PROXY'] == '.example.com,localhost,127.0.0.1,::1'
    assert os.environ['no_proxy'] == '.example.com,localhost,127.0.0.1,::1'
    assert os.environ['HTTPS_PROXY'] == 'http://127.0.0.1:9999'
    assert os.environ['FACESWAP_STUDIO_PREFER_MODELSCOPE'] == '1'


def test_distribution_refuses_tampered_payload(tmp_path):
    builder.write_json(tmp_path / 'bootstrap-manifest.json', {
        'package': {'name': 'runtime.zip', 'sha256': 'a' * 64}, 'files': []})
    (tmp_path / 'runtime.zip').write_bytes(b'tampered')
    with pytest.raises(ValueError, match='SHA-256'):
        builder.distribute(tmp_path)


def test_distribution_verifies_real_files_with_explicit_zip_directories(tmp_path):
    output = tmp_path / 'bundle'
    output.mkdir()
    package = output / 'runtime.zip'
    payload = b'verified-runtime-file'
    with zipfile.ZipFile(package, 'w') as archive:
        archive.writestr('FaceSwapStudio/', b'')
        archive.writestr('FaceSwapStudio/runtime.bin', payload)
    builder.write_json(output / 'bootstrap-manifest.json', {
        'package': {'name': package.name, 'sha256': builder.sha256(package)},
        'files': [{'name': 'runtime.bin', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}]})
    result = builder.distribute(output)
    with zipfile.ZipFile(result) as archive:
        assert archive.testzip() is None
        assert 'bundle/runtime.zip' in archive.namelist()
    assert result.with_suffix('.zip.sha256').is_file()
