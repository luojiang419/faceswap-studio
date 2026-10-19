import hashlib
import shutil
import zipfile

import pytest

from scripts import build_lightweight as packaging


def test_new_windows_build_replaces_deployed_frontend_without_modifying_it(tmp_path, monkeypatch):
    deployed = tmp_path / 'deployed-app.so'; deployed.write_bytes(b'old deployed app')
    unrelated = tmp_path / 'facefusion.py'; unrelated.write_bytes(b'current core')
    prefix = 'faceswap studio/runtime/windows_app/current/'
    monkeypatch.setattr(packaging, 'sources', lambda: [(deployed, prefix + 'data/app.so'), (unrelated, 'facefusion.py')])
    release = tmp_path / 'Release'
    for name in ('faceswap_studio.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'plugin.dll'):
        target = release / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(b'new build')
    (release / 'debug.pdb').write_bytes(b'debug')
    records = {name: file for file, name in packaging.application_sources(release)}
    assert records[prefix + 'data/app.so'].read_bytes() == b'new build'
    assert prefix + 'plugin.dll' in records
    assert prefix + 'debug.pdb' not in records
    assert records['facefusion.py'] == unrelated
    assert deployed.read_bytes() == b'old deployed app'
    (release / 'flutter_windows.dll').unlink()
    with pytest.raises(ValueError, match='Windows 构建不完整'):
        list(packaging.application_sources(release))


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
