import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import zipfile

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from scripts import build_lightweight as p


def fixture(tmp_path, monkeypatch):
    monkeypatch.setattr(p, 'ROOT', tmp_path)
    key = Ed25519PrivateKey.generate()
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    (tmp_path / 'installer').mkdir()
    p.write_json(tmp_path / 'update-config.json', {'publicKey': public, 'repository': 'test/repo'})
    base = tmp_path / 'base'; base.mkdir()
    old = {'name': '易容 Studio.exe', 'size': 3, 'sha256': hashlib.sha256(b'old').hexdigest()}
    dependency = {'name': '.python/runtime.bin', 'size': 7, 'sha256': hashlib.sha256(b'runtime').hexdigest()}
    p.write_json(base / 'bootstrap-manifest.json', {'appVersion': '0.1.3', 'releaseId': '20261019000000', 'publicKey': public,
        'files': [old, dependency], 'package': {'name': 'base.zip', 'size': 4000000000, 'sha256': 'a' * 64,
        'urls': [p.file_url('test/repo', 'bootstrap/base.zip')]}})
    app = tmp_path / 'app'; app.mkdir()
    package = app / 'application.zip'
    with zipfile.ZipFile(package, 'w') as archive: archive.writestr('启动FaceSwap Studio.exe', b'new')
    manifest = {'protocol': 1, 'product': 'faceswap-studio', 'platform': 'win32-x64', 'version': '0.1.3', 'minVersion': '0.1.3',
        'releaseId': '20261019000001', 'files': [{'path': '启动FaceSwap Studio.exe', 'size': 3, 'sha256': hashlib.sha256(b'new').hexdigest()}],
        'package': {'name': package.name, 'size': package.stat().st_size, 'sha256': p.sha256(package),
        'url': p.file_url('test/repo', 'releases/application.zip')}}
    payload = json.dumps(manifest)
    p.write_json(app / 'envelope.json', {'payload': payload, 'signature': key.sign(payload.encode()).hex()})
    def compile_installer(manifest, target): target.write_bytes(b'native-installer'); return target
    monkeypatch.setattr(p, 'compile_installer', compile_installer)
    return base, app


def test_composite_build_reuses_base_without_copying_or_rebuilding_it(tmp_path, monkeypatch):
    base, app = fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(p, 'payload', lambda *a, **k: pytest.fail('不能重建完整包'))
    output = tmp_path / 'first'
    manifest = p.build_composite(output, app, base)
    plan = p.read_json(output / 'publication-plan.json')
    assert manifest['package']['size'] == 4000000000
    assert manifest['applicationEntry'] == '启动FaceSwap Studio.exe'
    assert manifest['files'][1]['sha256'] == hashlib.sha256(b'new').hexdigest()
    assert plan['reusedPayload']['urls'] == manifest['package']['urls']
    assert not list(output.glob('*Runtime*')) and 'payload' not in plan
    monkeypatch.setattr(p, 'read_remote', lambda *a: pytest.fail('有效描述缓存不能重复下载'))
    second = p.build_composite(tmp_path / 'second', app)
    assert second['package'] == manifest['package']
    assert second['files'] == manifest['files']


def test_tampered_application_cannot_enter_composite_installer(tmp_path, monkeypatch):
    base, app = fixture(tmp_path, monkeypatch)
    (app / 'application.zip').write_bytes(b'tampered')
    with pytest.raises(ValueError, match='应用包与签名'):
        p.build_composite(tmp_path / 'bad', app, base)


@pytest.mark.parametrize('existing', [True, False])
def test_base_reference_never_uploads_runtime_even_when_missing(monkeypatch, existing):
    asset = {'size': 4000000000, 'sha256': 'a' * 64, 'urls': [p.file_url('test/repo', 'base.zip')]}
    api = SimpleNamespace(get_model_files=lambda *a, **k: [{'Path': 'base.zip', 'Size': asset['size'], 'Sha256': asset['sha256']}] if existing else [],
                          upload_file=lambda **k: pytest.fail('禁止重传基础包'))
    monkeypatch.setitem(sys.modules, 'modelscope.hub.api', SimpleNamespace(HubApi=lambda: api))
    monkeypatch.setattr(p, 'read_json', lambda *a: {'repository': 'test/repo'})
    monkeypatch.setattr(p, 'verify_public_access', lambda *a: None)
    if existing:
        assert p.verify_published_reference(asset)['reusedWithoutUpload'] is True
    else:
        with pytest.raises(ValueError, match='不会自动上传完整包'):
            p.verify_published_reference(asset)
