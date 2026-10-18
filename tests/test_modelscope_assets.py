import hashlib
import http.server
import importlib
import json
from pathlib import Path
import threading
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, ProxyHandler, build_opener
import zlib

import pytest

from facefusion import download, modelscope_assets as ms
from facefusion.hash_helper import validate_hash
from scripts.modelscope_models import inventory


@pytest.fixture
def server():
    payload = b'FaceFusion optional model bytes' * 4096
    calls = []
    mode = {'value': 'range'}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            content = f'{zlib.crc32(payload):08x}'.encode() if self.path.endswith('.hash') else payload
            offset = int(self.headers['Range'][6:-1]) if self.headers.get('Range') else 0
            calls.append(offset)
            if mode['value'] == 'ignore': offset = 0
            end = min(len(content)-1, offset + 8191) if mode['value'] == 'segments' else len(content)-1
            partial = (offset > 0 or mode['value'] == 'segments') and mode['value'] != 'ignore'
            self.send_response(206 if partial else 200)
            self.send_header('Content-Length', str(end-offset+1))
            if partial:
                self.send_header('Content-Range', f'bytes {0 if mode["value"] == "bad-range" else offset}-{end}/{len(content)}')
            self.end_headers()
            body = b'x' * len(content) if mode['value'] == 'corrupt' else content
            if mode['value'] == 'truncate' and len(calls) == 1:
                self.wfile.write(body[:1024]); self.close_connection = True
            else:
                self.wfile.write(body[offset:end+1])
    http_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=http_server.serve_forever, daemon=True); thread.start()
    yield f'http://127.0.0.1:{http_server.server_port}', payload, calls, mode
    http_server.shutdown(); http_server.server_close(); thread.join()


def descriptor(payload):
    return {'id': 'models-test/optional.onnx', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
            'url': 'https://modelscope.cn/api/v1/models/test/models/repo?Revision=master&FilePath=models%2Foptional.onnx'}


@pytest.mark.parametrize('mode_name', ['range', 'ignore', 'truncate', 'segments'])
def test_real_http_resume_and_segmented_responses(server, tmp_path, mode_name):
    url, payload, calls, mode = server
    mode['value'] = mode_name
    target = tmp_path / '中文 模型/optional.onnx'; target.parent.mkdir()
    if mode_name != 'truncate': target.with_suffix('.onnx.part').write_bytes(payload[:101])
    ms.download_file(url, target, size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), allow_http=True)
    assert target.read_bytes() == payload
    assert not target.with_suffix('.onnx.part').exists()
    if mode_name == 'truncate': assert calls == [0, 1024]
    if mode_name == 'segments': assert len(calls) > 2


def test_valid_local_file_does_not_contact_server(server, tmp_path):
    url, payload, calls, _ = server
    target = tmp_path / 'cached.onnx'; target.write_bytes(payload)
    ms.download_file(url, target, size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), allow_http=True)
    assert calls == []


def test_hash_mismatch_preserves_old_file_and_rejects_partial(server, tmp_path):
    url, payload, _, mode = server; mode['value'] = 'corrupt'
    target = tmp_path / 'model.dfm'; target.write_bytes(b'previous model')
    with pytest.raises(ValueError, match='SHA-256'):
        ms.download_file(url, target, size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), allow_http=True)
    assert target.read_bytes() == b'previous model'
    assert not target.with_suffix('.dfm.part').exists()


def test_wrong_range_retains_recoverable_bytes(server, tmp_path):
    url, payload, _, mode = server; mode['value'] = 'bad-range'
    target = tmp_path / 'model.onnx'; part = target.with_suffix('.onnx.part'); part.write_bytes(payload[:17])
    with pytest.raises(ValueError, match='断点'):
        ms.download_file(url, target, size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), allow_http=True)
    assert part.read_bytes() == payload[:17]
    assert not target.exists()


def test_space_preflight_does_not_start_download(server, tmp_path, monkeypatch):
    url, payload, calls, _ = server
    monkeypatch.setattr(ms.shutil, 'disk_usage', lambda path: type('Disk', (), {'free': 0})())
    with pytest.raises(OSError, match='空间不足'):
        ms.download_file(url, tmp_path / 'model.onnx', size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), allow_http=True)
    assert calls == []


def test_plain_http_is_rejected_by_production_default(server, tmp_path):
    url, payload, calls, _ = server
    with pytest.raises(ValueError, match='HTTPS'):
        ms.download_file(url, tmp_path / 'model.onnx', size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
    assert calls == []


@pytest.fixture
def catalog_file(tmp_path, monkeypatch):
    monkeypatch.setattr(ms, '__file__', str(tmp_path / 'modelscope_assets.py'))
    ms.catalog.cache_clear(); ms._urls.cache_clear()
    yield tmp_path / 'model_catalog.json'
    ms.catalog.cache_clear(); ms._urls.cache_clear()


@pytest.mark.parametrize('change', ['duplicate', 'path', 'host', 'sha'])
def test_catalog_rejects_invalid_metadata(catalog_file, change):
    record = descriptor(b'1234'); values = [record]
    if change == 'duplicate': values.append(dict(record))
    if change == 'path': record['id'] = '../optional.onnx'
    if change == 'host': record['url'] = 'https://example.com/model.onnx'
    if change == 'sha': record['sha256'] = 'bad'
    catalog_file.write_text(json.dumps({'protocol': 1, 'product': 'facefusion-models', 'assets': values}), 'utf-8')
    with pytest.raises(ValueError): ms.catalog()


def test_query_url_download_uses_real_model_filename_and_crc(server, tmp_path, monkeypatch, catalog_file):
    url, payload, _, _ = server
    source = descriptor(payload)
    checksum = f'{zlib.crc32(payload):08x}'.encode()
    hash_record = {**source, 'id': 'models-test/optional.hash', 'size': len(checksum), 'sha256': hashlib.sha256(checksum).hexdigest(),
                   'url': source['url'].replace('.onnx', '.hash')}
    catalog_file.write_text(json.dumps({'protocol': 1, 'product': 'facefusion-models', 'assets': [source, hash_record]}), 'utf-8')
    actual_opener = build_opener(ProxyHandler({}))
    class MappedOpener:
        def open(self, request, timeout):
            name = Path(parse_qs(urlparse(request.full_url).query)['FilePath'][0]).name
            return actual_opener.open(Request(url + '/' + name, headers=dict(request.headers)), timeout=timeout)
    monkeypatch.setattr(ms, 'build_opener', lambda *args: MappedOpener())
    monkeypatch.setattr(download.state_manager, 'get_item', lambda key: 'error')
    monkeypatch.setattr(download.process_manager, 'check', lambda: None)
    monkeypatch.setattr(download.process_manager, 'end', lambda: None)
    monkeypatch.setattr(download.logger, 'debug', lambda *args: None)
    hashes = {'test': {'url': hash_record['url'], 'path': str(tmp_path / 'optional.hash')}}
    assert download.conditional_download_hashes(hashes)
    download.conditional_download(str(tmp_path), [source['url']])
    assert (tmp_path / 'optional.onnx').read_bytes() == payload
    assert validate_hash(str(tmp_path / 'optional.onnx'))
    assert not (tmp_path / 'repo').exists()
    assert download.get_static_download_size(source['url']) == len(payload)


def test_provider_selection_and_legacy_explicit_urls(monkeypatch):
    item = descriptor(b'data')
    monkeypatch.setattr(download, 'get_asset', lambda base, name: item)
    monkeypatch.setattr(download, 'ping_static_url', lambda url: True)
    assert download.resolve_download_url_by_provider('modelscope', 'models-test', 'optional.onnx') == item['url']
    assert download.resolve_download_url_by_provider('github', 'models-3.0.0', 'fairface.onnx').startswith('https://github.com/')
    monkeypatch.setenv('FACESWAP_STUDIO_PREFER_MODELSCOPE', '1')
    assert download.resolve_download_url('models-test', 'optional.onnx') == item['url']


def test_full_inventory_matches_actual_builtin_functions(monkeypatch):
    scanned = inventory()
    assert len(scanned['models']) == 247
    assert len(scanned['assets']) == 508
    actual = set()
    modules = []
    try:
        for path in sorted({a['module'] for a in scanned['models']}):
            module = importlib.import_module(path.removesuffix('.py').replace('/', '.'))
            modules.append(module)
            monkeypatch.setattr(module, 'resolve_download_url', lambda base, name: base + '/' + name, raising=False)
            monkeypatch.setattr(module, 'resolve_download_url_by_provider', lambda provider, base, name: base + '/' + name, raising=False)
            monkeypatch.setattr(module, 'resolve_file_paths', lambda path: [], raising=False)
            module.create_static_model_set.cache_clear()
            for model in module.create_static_model_set('full').values():
                for kind in ('hashes', 'sources'):
                    actual.update(a['url'] for a in model.get(kind, {}).values() if a.get('url'))
        assert actual == {a['id'] for a in scanned['assets']}
    finally:
        for module in modules: module.create_static_model_set.cache_clear()


@pytest.mark.skipif(not Path(ms.__file__).with_name('model_catalog.json').exists(), reason='完整镜像清单尚未生成')
def test_published_catalog_routes_every_builtin_asset_to_modelscope(monkeypatch):
    monkeypatch.setenv('FACESWAP_STUDIO_PREFER_MODELSCOPE', '1')
    monkeypatch.setattr(download.state_manager, 'get_item', lambda key: ['modelscope'] if key == 'download_providers' else None)
    ms.catalog.cache_clear(); ms._urls.cache_clear()
    scanned = inventory()
    expected = ms.catalog()
    assert set(expected) == {a['id'] for a in scanned['assets']}
    modules = {}
    routed = set()
    try:
        for option in scanned['models']:
            path = option['module']
            if path not in modules:
                module = importlib.import_module(path.removesuffix('.py').replace('/', '.'))
                module.create_static_model_set.cache_clear()
                modules[path] = module
            model = modules[path].create_static_model_set('full')[option['name']]
            actual_urls = {a['url'] for kind in ('hashes', 'sources') for a in model.get(kind, {}).values() if a.get('url')}
            assert actual_urls == {expected[key]['url'] for key in option['assets']}
            routed.update(actual_urls)
        assert routed == {a['url'] for a in expected.values()}
    finally:
        for module in modules.values():
            module.create_static_model_set.cache_clear()
        ms.catalog.cache_clear(); ms._urls.cache_clear()
