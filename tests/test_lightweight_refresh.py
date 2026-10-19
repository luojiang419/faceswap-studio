import hashlib
import shutil
import zipfile
import sys
from types import SimpleNamespace

import pytest

from scripts import build_lightweight as packaging


@pytest.mark.parametrize('existing', [True, False])
@pytest.mark.parametrize('full', [True, False])
def test_publication_reuses_identical_asset_and_only_full_reads_when_requested(tmp_path, monkeypatch, existing, full):
    file = tmp_path / 'runtime.zip'; file.write_bytes(b'unchanged-runtime')
    record = {'Path': 'bootstrap/runtime.zip', 'Size': file.stat().st_size, 'Sha256': packaging.sha256(file)}
    remote, uploads, access, reads = ([record] if existing else []), [], [], []
    def upload(**kwargs):
        uploads.append(kwargs); remote.append(record)
    api = SimpleNamespace(get_model_files=lambda *a, **k: remote, upload_file=upload)
    monkeypatch.setitem(sys.modules, 'modelscope.hub.api', SimpleNamespace(HubApi=lambda: api))
    monkeypatch.setattr(packaging, 'read_json', lambda p: {'repository': 'test/repo'})
    monkeypatch.setattr(packaging, 'verify_public_access', lambda *a: access.append(a))
    monkeypatch.setattr(packaging, 'verify_remote_asset', lambda *a: reads.append(a))
    proof = packaging.publish_asset(file, record['Path'], full_readback=full)
    assert len(uploads) == (0 if existing else 1)
    assert len(access) == 1 and len(reads) == int(full)
    assert proof['remoteMetadataVerified'] and proof['anonymousFullVerified'] == full


def test_publication_refuses_different_remote_content_without_upload(tmp_path, monkeypatch):
    file = tmp_path / 'runtime.zip'; file.write_bytes(b'new')
    api = SimpleNamespace(get_model_files=lambda *a, **k: [{'Path': 'runtime.zip', 'Size': 3, 'Sha256': 'bad'}],
                          upload_file=lambda **k: pytest.fail('禁止覆盖已有不同内容资源'))
    monkeypatch.setitem(sys.modules, 'modelscope.hub.api', SimpleNamespace(HubApi=lambda: api))
    monkeypatch.setattr(packaging, 'read_json', lambda p: {'repository': 'test/repo'})
    with pytest.raises(ValueError, match='拒绝覆盖'):
        packaging.publish_asset(file, 'runtime.zip')


@pytest.mark.parametrize('status,partial', [(200, False), (206, True), (200, True)])
def test_public_access_reads_only_one_byte_even_when_server_ignores_range(monkeypatch, status, partial):
    size = 4 * 1024**3
    class Response:
        headers = {'Content-Length': '1' if partial else str(size)}
        if partial:
            headers['Content-Range'] = f'bytes 0-0/{size}'
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, count):
            assert count == 1, '匿名访问检查不能下载整包'
            return b'x'
    response = Response(); response.status = status
    def open(request, **kwargs):
        assert request.get_header('Range') == 'bytes=0-0'
        return response
    monkeypatch.setattr('urllib.request.build_opener', lambda *a: SimpleNamespace(open=open))
    packaging.verify_public_access('https://example.test/runtime.zip', size)


@pytest.mark.parametrize('status', [200, 206])
def test_public_access_rejects_wrong_range_size_even_with_status_200(monkeypatch, status):
    class Response:
        headers = {'Content-Length': '1', 'Content-Range': 'bytes 0-0/99'}
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, count): pytest.fail('范围不匹配时不得接受响应正文')
    response = Response(); response.status = status
    monkeypatch.setattr('urllib.request.build_opener', lambda *a: SimpleNamespace(open=lambda *a, **k: response))
    with pytest.raises(ValueError, match='资源大小不一致'):
        packaging.verify_public_access('https://example.test/catalog.json', 100)


def test_installer_only_build_reuses_published_runtime_url_and_release(tmp_path, monkeypatch):
    monkeypatch.setattr(packaging, 'ROOT', tmp_path)
    monkeypatch.setattr(packaging, 'sync_brand_icons', lambda: None)
    (tmp_path / 'VERSION').write_text('0.1.3', 'utf-8')
    packaging.write_json(tmp_path / 'update-config.json', {'releaseId': 'new-installer', 'repository': 'test/repo', 'publicKey': 'trusted'})
    old = tmp_path / 'old'; old.mkdir()
    package = old / 'runtime.zip'
    with zipfile.ZipFile(package, 'w') as archive:
        archive.writestr('FaceSwapStudio/易容 Studio.exe', b'unchanged-app')
    records = [{'name': '易容 Studio.exe', 'size': 13, 'sha256': hashlib.sha256(b'unchanged-app').hexdigest()}]
    packaging.write_json(package.with_suffix('.files.json'), records)
    url = packaging.file_url('test/repo', 'bootstrap/original/runtime.zip')
    packaging.write_json(old / 'bootstrap-manifest.json', {'releaseId': 'old-installer', 'appReleaseId': 'original-app',
        'appVersion': '0.1.3', 'entry': '易容 Studio.exe', 'publicKey': 'trusted', 'files': records,
        'package': {'size': package.stat().st_size, 'sha256': packaging.sha256(package), 'urls': [url]}})
    def compile(manifest, output):
        output.write_bytes(b'installer'); return output
    monkeypatch.setattr(packaging, 'compile_installer', compile)
    monkeypatch.setattr(packaging, 'payload', lambda *a: pytest.fail('仅改安装器不得重新打包运行环境'))
    output = tmp_path / 'new'
    packaging.build(output, existing=package)
    manifest = packaging.read_json(output / 'bootstrap-manifest.json')
    plan = packaging.read_json(output / 'publication-plan.json')
    assert manifest['releaseId'] == 'new-installer' and manifest['appReleaseId'] == 'original-app'
    assert manifest['package']['urls'] == [url]
    assert plan['payloadRemote'] == 'bootstrap/original/runtime.zip'
    assert not list(output.glob('*-Runtime.zip'))


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
