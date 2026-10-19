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


def prepare_offer(source, monkeypatch):
    from types import SimpleNamespace
    from updater import service as module
    service, manifest, *_ = source
    (service.root / 'updater').mkdir(exist_ok=True)
    (service.root / 'updater/offer.py').write_text('# independent worker', 'utf-8')
    for name in ('__init__.py', 'service.py', 'transaction.py'):
        (service.root / 'updater' / name).write_text('# snapshot fixture', 'utf-8')
    (service.root / 'FaceSwapStudioUpdater.exe').write_bytes(b'native updater')
    launched = []
    monkeypatch.setattr(module.subprocess, 'run', lambda args, **kwargs: launched.append(args) or SimpleNamespace(stdout='99999999'))
    monkeypatch.setattr(module, 'alive', lambda pid: False)
    assert service.check()['state'] == 'update_available'
    return service, service.cache / manifest['releaseId'], launched


def test_startup_offer_opens_native_before_any_download_and_deduplicates(source, monkeypatch):
    service, session, launched = prepare_offer(source, monkeypatch)
    assert service.offer(automatic=True)['native_prompt_opened']
    assert '--offer' in launched[0]
    assert service.worker is None and not (session / 'package.zip').exists()
    service.offer(automatic=True)
    assert len(launched) == 1
    service.offer(automatic=False)
    assert len(launched) == 2  # 手动检查允许重新打开已关闭的提示。


def test_later_requires_no_download_and_next_launch_starts_native_auto_update(source, monkeypatch):
    from updater import offer, startup
    from updater.transaction import read_json
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer()
    before = list(source[5])
    offer.execute(session, 'later')
    assert source[5] == before and service.worker is None
    assert not (session / 'package.zip').exists()
    assert read_json(service.cache / 'deferred.json')['session'] == str(session)
    started = []
    monkeypatch.setattr(startup.subprocess, 'Popen', lambda args, **kwargs: started.append(args))
    monkeypatch.setenv('FACESWAP_STUDIO_WRAPPER_PID', '12345')
    assert startup.resume_update(service.root)
    assert started[0][1] == '--install-offer' and started[0][2] == str(session)
    assert read_json(session / 'session.json')['parentPid'] == 12345
    assert not (service.cache / 'deferred.json').exists()


def test_return_to_app_skips_deferred_once_without_losing_choice(source, monkeypatch):
    from updater import offer, startup
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer(); offer.execute(session, 'later')
    monkeypatch.setenv('FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE', '1')
    monkeypatch.setattr(startup.subprocess, 'Popen', lambda *a, **k: pytest.fail('继续使用不得立即再次更新'))
    assert not startup.resume_update(service.root)
    assert (service.cache / 'deferred.json').exists()
    assert 'FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE' not in __import__('os').environ


def test_deferred_obsolete_release_is_removed_without_reinstall(source, monkeypatch):
    from updater import offer, startup
    from updater.transaction import write_json
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer(); offer.execute(session, 'later')
    config = service.config; config['releaseId'] = source[1]['releaseId']
    write_json(service.root / 'update-config.json', config)
    monkeypatch.setattr(startup.subprocess, 'Popen', lambda *a, **k: pytest.fail('已经更新后不能重复安装'))
    assert not startup.resume_update(service.root)
    assert not (service.cache / 'deferred.json').exists()


def test_now_downloads_and_verifies_before_closing_or_installing(source, monkeypatch):
    from updater import offer, transaction
    service, session, _ = prepare_offer(source, monkeypatch)
    service.offer()
    actions = []
    monkeypatch.setattr(transaction, 'validate', lambda *a: actions.append('verified'))
    monkeypatch.setattr(offer, 'close_studio', lambda *a: actions.append('close'))
    monkeypatch.setattr(transaction, 'run', lambda *a: actions.append('install'))
    offer.execute(session, 'now')
    assert (session / 'package.zip').read_bytes() == source[4]
    assert actions == ['verified', 'close', 'install']


def test_bad_download_keeps_current_app_running(source, monkeypatch):
    from updater import offer, transaction
    service, session, _ = prepare_offer(source, monkeypatch)
    source[1]['package']['sha256'] = '0' * 64
    service.envelope = source[6]()
    service.offer()
    monkeypatch.setattr(offer, 'close_studio', lambda *a: pytest.fail('坏包不能退出当前软件'))
    monkeypatch.setattr(transaction, 'run', lambda *a: pytest.fail('坏包不能安装'))
    with pytest.raises(RuntimeError, match='SHA-256'):
        offer.execute(session, 'now')


def test_offer_launch_failure_allows_retry_without_download(source, monkeypatch):
    from updater import service as module
    service, _, _ = prepare_offer(source, monkeypatch)
    monkeypatch.setattr(module.subprocess, 'run', lambda *a, **k: (_ for _ in ()).throw(OSError('launch denied')))
    assert not service.offer(automatic=True)['native_prompt_opened']
    assert service.prompted_release is None and service.worker is None


def test_independent_update_refuses_active_queue_before_sending_exit(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from updater import offer
    import io
    import psutil
    monkeypatch.setattr(psutil, 'process_iter', lambda *a: [])
    monkeypatch.setattr(offer, 'build_opener', lambda *a: SimpleNamespace(open=lambda *a, **k: io.BytesIO(b'{"runner":{"active":true}}')))
    with pytest.raises(RuntimeError, match='生成任务正在运行'):
        offer.close_studio(tmp_path, 'http://127.0.0.1:52741')


def test_publication_verifier_resumes_anonymous_truncated_stream(source):
    from scripts.build_lightweight import verify_remote_asset
    _, manifest, _, _, payload, requests, _ = source
    verify_remote_asset(manifest['package']['url'] + '/truncate', len(payload), hashlib.sha256(payload).hexdigest())
    assert 'bytes=1024-' in requests
