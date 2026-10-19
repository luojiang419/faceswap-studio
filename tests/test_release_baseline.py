import json
import zipfile

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from scripts import release_modelscope as release


@pytest.mark.parametrize('legacy', [True, False])
def test_transition_package_uses_entry_supported_by_old_clients(tmp_path, monkeypatch, legacy):
    monkeypatch.setattr(release, 'ROOT', tmp_path)
    key = Ed25519PrivateKey.generate()
    config = {'publicKey': 'test-key', 'repository': 'test/repo', 'releaseId': '20260101000000'}
    (tmp_path / 'VERSION').write_text('0.1.3', 'utf-8')
    (tmp_path / '易容 Studio.exe').write_bytes(b'current native launcher')
    release.write_json(tmp_path / 'update-config.json', config)
    monkeypatch.setattr(release, 'keys', lambda: (key, config))
    monkeypatch.setattr(release, 'run_preflight', lambda root: {'ok': True})
    monkeypatch.setattr(release.subprocess, 'run', lambda *a, **k: None)
    monkeypatch.setattr(release, 'sources', lambda: [(tmp_path / name, name) for name in ('VERSION', 'update-config.json', '易容 Studio.exe')])
    monkeypatch.setattr(release, 'validate_package', lambda package: {'ok': True})
    output = release.build('transition', '0.1.3', legacy_entry=legacy)
    manifest = release.read_json(output / 'manifest.json')
    expected = '启动FaceSwap Studio.exe' if legacy else '易容 Studio.exe'
    forbidden = '易容 Studio.exe' if legacy else '启动FaceSwap Studio.exe'
    with zipfile.ZipFile(output / manifest['package']['name']) as archive:
        assert expected in archive.namelist() and forbidden not in archive.namelist()
        assert json.loads(archive.read('update-config.json'))['releaseId'] == manifest['releaseId']
    assert expected in {file['path'] for file in manifest['files']}
