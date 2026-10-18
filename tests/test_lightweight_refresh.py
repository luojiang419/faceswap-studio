import hashlib
import shutil
import zipfile

import pytest

from scripts import build_lightweight as packaging


@pytest.mark.skipif(not shutil.which('7z'), reason='运行包增量集成测试需要7z')
def test_refresh_keeps_baseline_and_dependencies_and_updates_catalog(tmp_path, monkeypatch):
    monkeypatch.setattr(packaging, 'ROOT', tmp_path)
    baseline = tmp_path / 'old.zip'
    original = {'VERSION': b'0.1.3', '.python/python.exe': b'portable dependency', 'facefusion.ini': b'old providers'}
    with zipfile.ZipFile(baseline, 'w') as archive:
        for name, data in original.items():
            archive.writestr('FaceSwapStudio/' + name, data)
    packaging.write_json(baseline.with_suffix('.files.json'), [
        {'name': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()} for name, data in original.items()])
    old_sha = packaging.sha256(baseline)
    (tmp_path / 'facefusion.ini').write_bytes(b'download_providers = modelscope huggingface github')
    catalog = tmp_path / 'model_catalog.json'; catalog.write_bytes(b'{"assets": ["all optional models"]}')
    monkeypatch.setattr(packaging, 'sources', lambda: [(catalog, 'facefusion/model_catalog.json')])
    output = tmp_path / 'new.zip'
    packaging.refresh_payload(output, baseline)
    assert packaging.sha256(baseline) == old_sha
    with zipfile.ZipFile(output) as archive:
        assert archive.read('FaceSwapStudio/.python/python.exe') == original['.python/python.exe']
        assert archive.read('FaceSwapStudio/facefusion/model_catalog.json') == catalog.read_bytes()
        assert archive.read('FaceSwapStudio/facefusion.ini').startswith(b'download_providers = modelscope')
        assert len([item for item in archive.infolist() if not item.is_dir()]) == 4
    records = packaging.read_json(output.with_suffix('.files.json'))
    assert {r['name'] for r in records} == {*original, 'facefusion/model_catalog.json'}
    with pytest.raises(ValueError, match='覆盖'):
        packaging.refresh_payload(output, baseline)
