"""发布门禁：未完成、过期或缺少证据的模型清单不能激活。"""
import hashlib
import json

import pytest

from scripts import modelscope_models as mirror


@pytest.fixture
def completed(tmp_path, monkeypatch):
    monkeypatch.setattr(mirror, 'ROOT', tmp_path)
    source = {'id': 'models-test/example.onnx', 'path': 'example.onnx', 'kind': 'sources', 'models': ['example']}
    model = {'module': 'facefusion/example.py', 'name': 'example', 'metadata': {}, 'assets': [source['id']]}
    actual = {'models': [model], 'assets': [dict(source)]}
    monkeypatch.setattr(mirror, 'inventory', lambda: actual)
    asset = {**source, 'size': 4, 'sha256': hashlib.sha256(b'data').hexdigest(),
             'url': 'https://modelscope.cn/api/v1/models/test/repo/repo?FilePath=example.onnx'}
    plan = {'protocol': 1, 'product': 'facefusion-models', 'models': [model], 'assets': [asset],
            'repository': 'test/repo', 'upstream': {}, 'total_bytes': 4}
    directory = tmp_path / 'mirror'
    mirror.save(directory / 'plan.json', plan)
    mirror.save(directory / 'publication.json', {'complete': True, 'missing': [], 'failures': [],
                'repository': 'test/repo', 'modelCount': 1, 'assetCount': 1, 'bytes': 4})
    proof = directory / 'proofs' / (hashlib.sha256(asset['id'].encode()).hexdigest() + '.json')
    mirror.save(proof, {**asset, 'verified': True, 'anonymousRangeVerified': True})
    mirror.save(tmp_path / 'facefusion/model_catalog.json', plan)
    return directory, actual, proof


def test_completed_catalog_has_matching_source_and_proofs(completed):
    directory, _, _ = completed
    result = mirror.audit(directory)
    assert result['complete'] is True
    assert result['assetCount'] == 1
    assert result['allProofsMatch'] is True


@pytest.mark.parametrize('damage', ['unfinished', 'missing-proof', 'wrong-sha', 'no-anonymous-proof', 'changed-source', 'changed-catalog'])
def test_incomplete_or_stale_catalog_cannot_be_published(completed, damage, monkeypatch):
    directory, actual, proof = completed
    if damage == 'unfinished':
        path = directory / 'publication.json'
        value = json.loads(path.read_text('utf-8')); value['complete'] = False
        mirror.save(path, value)
    elif damage == 'missing-proof':
        proof.unlink()
    elif damage in ('wrong-sha', 'no-anonymous-proof'):
        value = json.loads(proof.read_text('utf-8'))
        value['sha256' if damage == 'wrong-sha' else 'anonymousRangeVerified'] = 'bad'
        mirror.save(proof, value)
    elif damage == 'changed-source':
        actual['assets'][0]['path'] = 'changed.onnx'
    else:
        path = mirror.ROOT / 'facefusion/model_catalog.json'
        value = json.loads(path.read_text('utf-8')); value['assets'][0]['size'] = 8
        mirror.save(path, value)
    # 使用真实发布入口；审计失败时不能调用任何外部发布操作。
    import scripts.build_lightweight as installer
    monkeypatch.setattr(installer, 'publish_asset', lambda *args: pytest.fail('无效清单不应上传'))
    with pytest.raises((ValueError, FileNotFoundError)):
        mirror.publish_catalog(directory)
