import hashlib
import http.server
import json
from pathlib import Path
import threading

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from updater.service import UpdateService, verify_envelope, permitted_url
from updater.transaction import write_json


@pytest.fixture
def source(tmp_path, monkeypatch):
    monkeypatch.setenv('FACESWAP_STUDIO_UPDATE_TEST', '1')
    key = Ed25519PrivateKey.generate()
    (tmp_path / 'VERSION').write_text('0.1.3')
    payload = b'actual HTTP package bytes' * 4096
    requests = []
    class Server(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            requests.append(self.headers.get('Range'))
            content = payload if self.path.startswith('/package') else json.dumps(envelope).encode()
            offset = int(self.headers['Range'][6:-1]) if self.headers.get('Range') and '/ignore' not in self.path else 0
            self.send_response(206 if offset else 200)
            if offset: self.send_header('Content-Range', f'bytes {offset}-{len(content)-1}/{len(content)}')
            self.send_header('Content-Length', str(len(content) - offset)); self.end_headers()
            if '/truncate' in self.path and offset == 0:
                self.wfile.write(content[:1024]); self.close_connection = True
            else:
                self.wfile.write(content[offset:])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
    url = f'http://127.0.0.1:{server.server_port}'
    manifest = {'protocol': 1, 'product': 'faceswap-studio', 'platform': 'win32-x64', 'version': '0.1.3',
                'minVersion': '0.1.3', 'releaseId': '20261018000002', 'notes': '测试更新',
                'package': {'name': 'package.zip', 'url': url + '/package', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()},
                'files': [{'path': 'VERSION', 'size': 5, 'sha256': hashlib.sha256(b'0.1.3').hexdigest()}]}
    def sign():
        text = json.dumps(manifest)
        return {'payload': text, 'signature': key.sign(text.encode()).hex()}
    envelope = sign()
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    write_json(tmp_path / 'update-config.json', {'publicKey': public, 'releaseId': '20261018000001', 'manifestUrl': url + '/manifest', 'repository': 'test/repo'})
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    yield UpdateService(tmp_path), manifest, envelope, public, payload, requests, sign
    server.shutdown(); server.server_close(); thread.join()


def test_real_check_same_version_release_and_resume(source):
    service, manifest, _, _, payload, requests, _ = source
    assert service.check()['state'] == 'update_available'
    session = service.cache / manifest['releaseId']; session.mkdir(parents=True)
    (session / 'package.part').write_bytes(payload[:123])
    service.download(); service.worker.join(10)
    assert service.status()['state'] == 'downloaded'
    assert (session / 'package.zip').read_bytes() == payload
    assert 'bytes=123-' in requests


def test_server_ignores_range_restarts_safely(source):
    service, manifest, _, _, payload, _, sign = source
    service.check()
    manifest['package']['url'] += '/ignore'
    service.envelope = sign()
    session = service.cache / manifest['releaseId']; session.mkdir(parents=True)
    (session / 'package.part').write_bytes(payload[:333])
    service.download(); service.worker.join(10)
    assert service.status()['state'] == 'downloaded'
    assert (session / 'package.zip').read_bytes() == payload


def test_bad_hash_does_not_offer_install(source):
    service, manifest, _, _, _, _, sign = source
    service.check(); manifest['package']['sha256'] = '0' * 64; service.envelope = sign()
    service.download(); service.worker.join(10)
    assert service.status()['state'] == 'failed'
    assert not (service.session / 'package.zip').exists()


def test_signature_and_signed_protected_path_rejected(source):
    _, manifest, envelope, public, _, _, sign = source
    with pytest.raises(InvalidSignature):
        verify_envelope({**envelope, 'payload': envelope['payload'] + ' '}, public)
    manifest['files'][0]['path'] = 'faceswap studio/config/settings.json'
    with pytest.raises(ValueError, match='禁止'):
        verify_envelope(sign(), public)


@pytest.mark.parametrize('url', ['http://modelscope.cn/a', 'https://example.com/a', 'https://modelscope.cn.evil/a', 'file:///c:/a'])
def test_remote_address_policy(url):
    with pytest.raises(ValueError): permitted_url(url)


def test_schedule_is_scoped_and_missing_runner_is_reported(source):
    service, *_ = source
    service.check(); service.download(); service.worker.join(10)
    assert service.apply()['state'] == 'failed'
    assert not (service.cache / 'scheduled.json').exists()


def test_truncated_http_response_is_resumed_automatically(source):
    service, manifest, _, _, payload, requests, sign = source
    service.check(); manifest['package']['url'] += '/truncate'; service.envelope = sign()
    service.download(); service.worker.join(10)
    assert service.status()['state'] == 'downloaded'
    assert (service.session / 'package.zip').read_bytes() == payload
    assert 'bytes=1024-' in requests


def test_publication_verifier_resumes_anonymous_truncated_stream(source):
    from scripts.build_lightweight import verify_remote_asset
    _, manifest, _, _, payload, requests, _ = source
    verify_remote_asset(manifest['package']['url'] + '/truncate', len(payload), hashlib.sha256(payload).hexdigest())
    assert 'bytes=1024-' in requests
