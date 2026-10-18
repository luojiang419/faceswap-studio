"""审计并镜像当前源码的全部内置模型；只发布不可变资源，逐项记录可恢复进度。"""
from __future__ import annotations

import argparse
import ast
import concurrent.futures
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import threading
import time
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from facefusion.modelscope_assets import download_file, file_sha256

DEFAULT_REPO = 'jiangjiang419/facefusion-workbench-updates'
PREFIX = 'models/facefusion-3.9.0-v1'


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), 'utf-8')
    for attempt in range(7):
        try:
            temporary.replace(path)
            break
        except PermissionError:
            if attempt == 6:
                raise
            time.sleep(0.05 * (attempt + 1))


def file_url(repo, relative):
    return f'https://modelscope.cn/api/v1/models/{repo}/repo?' + urlencode({'Revision': 'master', 'FilePath': relative})


def inventory(root=ROOT):
    models, assets = [], {}
    for path in sorted((root / 'facefusion').rglob('*.py')):
        tree = ast.parse(path.read_text('utf-8-sig'))
        for original in tree.body:
            if not isinstance(original, ast.FunctionDef) or original.name != 'create_static_model_set':
                continue
            node = copy.deepcopy(original)
            node.decorator_list = []
            node.returns = None
            for arg in node.args.args:
                arg.annotation = None
            unit = ast.fix_missing_locations(ast.Module(body=[node], type_ignores=[]))
            namespace = {
                'resolve_download_url': lambda base, name: base + '/' + name,
                'resolve_download_url_by_provider': lambda provider, base, name: base + '/' + name,
                'resolve_relative_path': lambda value: value,
                'resolve_file_paths': lambda value: [],
            }
            exec(compile(unit, str(path), 'exec'), namespace)
            for name, model in namespace[node.name]('full').items():
                record = {'module': path.relative_to(root).as_posix(), 'name': name,
                          'metadata': model.get('__metadata__', {}), 'assets': []}
                for kind in ('hashes', 'sources'):
                    for value in model.get(kind, {}).values():
                        if value.get('url'):
                            key = value['url']
                            asset = assets.setdefault(key, {'id': key, 'path': value['path'].removeprefix('../.assets/models/'), 'kind': kind, 'models': []})
                            if name not in asset['models']:
                                asset['models'].append(name)
                            record['assets'].append(key)
                models.append(record)
    return {'models': models, 'assets': list(assets.values())}


def json_from(url, opener):
    with opener.open(Request(url, headers={'Accept': 'application/json'}), timeout=45) as response:
        return json.load(response)


def prepare(directory, proxy=None, repo=DEFAULT_REPO):
    data = inventory()
    opener = build_opener(ProxyHandler({'http': proxy, 'https': proxy} if proxy else {}))
    bases = sorted({a['id'].split('/')[0] for a in data['assets']})
    info = {}
    def repository(base):
        value = json_from(f'https://huggingface.co/api/models/facefusion/{base}', opener)
        commit = value['sha']
        tree = json_from(f'https://huggingface.co/api/models/facefusion/{base}/tree/{commit}?recursive=true&expand=false', opener)
        # 当前各仓库少于1000项，拒绝静默漏掉分页结果。
        if len(tree) >= 1000:
            raise ValueError('上游模型树需要显式分页：' + base)
        return base, {'commit': commit, 'card': value.get('cardData'), 'files': {f['path']: f for f in tree if f.get('type') == 'file'}}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for base, value in pool.map(repository, bases):
            info[base] = value
    directory.mkdir(parents=True, exist_ok=True)
    hash_dir = directory / 'hashes'
    hash_dir.mkdir(exist_ok=True)
    def descriptor(asset):
        base, name = asset['id'].split('/', 1)
        upstream = info[base]['files'].get(name)
        if upstream is None:
            raise FileNotFoundError('上游缺少内置模型资产：' + asset['id'])
        asset.update(size=upstream['size'], upstream_sha256=upstream.get('lfs', {}).get('oid'),
                     upstream_blob=upstream.get('oid'), upstream_commit=info[base]['commit'],
                     upstream_url=f'https://huggingface.co/facefusion/{base}/resolve/{info[base]["commit"]}/{name}',
                     remote_path=PREFIX + '/' + asset['id'], url=file_url(repo, PREFIX + '/' + asset['id']))
        if asset['kind'] == 'hashes':
            target = hash_dir / base / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                with opener.open(Request(asset['upstream_url']), timeout=45) as response:
                    content = response.read(1024)
                if len(content) != asset['size']:
                    raise ValueError('上游hash文件大小不一致：' + asset['id'])
                target.write_bytes(content)
            content = target.read_bytes()
            git_oid = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
            if git_oid != asset['upstream_blob'] or not re.fullmatch(rb'[a-fA-F0-9]{8}', content):
                raise ValueError('上游hash内容与Git对象不一致：' + asset['id'])
            asset.update(sha256=hashlib.sha256(content).hexdigest(), crc32=content.decode().lower())
        else:
            asset['sha256'] = asset['upstream_sha256']
            if not re.fullmatch(r'[a-f0-9]{64}', asset['sha256'] or ''):
                raise ValueError('权重缺少上游LFS SHA-256：' + asset['id'])
        return asset
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        data['assets'] = list(pool.map(descriptor, data['assets']))
    hashes = {a['id']: a for a in data['assets'] if a['kind'] == 'hashes'}
    for asset in data['assets']:
        if asset['kind'] == 'sources':
            base, name = asset['id'].split('/', 1)
            asset['crc32'] = hashes[base + '/' + Path(name).stem + '.hash']['crc32']
    data.update(protocol=1, product='facefusion-models', repository=repo, prefix=PREFIX,
                total_bytes=sum(a['size'] for a in data['assets']), upstream={base: {'commit': v['commit'], 'card': v['card']} for base, v in info.items()})
    save(directory / 'plan.json', data)
    print(f'模型{len(data["models"])}；资产{len(data["assets"])}；总量{data["total_bytes"] / 1024**3:.2f}GiB', flush=True)
    return data


def verify_anonymous(asset, local=None, full=False):
    opener = build_opener(ProxyHandler({}))
    if asset['kind'] == 'hashes' or full:
        # 小hash完整回读；权重完整SHA在客户端实际下载时执行。
        digest = hashlib.sha256()
        offset = 0
        while offset < asset['size']:
            with opener.open(Request(asset['url'], headers={'Range': f'bytes={offset}-', 'Accept-Encoding': 'identity'}), timeout=90) as response:
                if response.status == 206 and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                    raise ValueError('匿名完整回读Range错误')
                if response.status == 200 and offset:
                    digest = hashlib.sha256(); offset = 0
                before = offset
                while chunk := response.read(512 * 1024):
                    digest.update(chunk); offset += len(chunk)
            if offset <= before or offset > asset['size']:
                raise ValueError('匿名完整回读大小错误')
        if digest.hexdigest() != asset['sha256']:
            raise ValueError('匿名完整回读SHA不一致：' + asset['id'])
        return {'anonymousFullSha256Verified': True}
    samples = []
    for start in (0, max(0, asset['size'] - 16384)):
        end = min(asset['size'] - 1, start + 16383)
        with opener.open(Request(asset['url'], headers={'Range': f'bytes={start}-{end}', 'Accept-Encoding': 'identity'}), timeout=60) as response:
            expected = f'bytes {start}-{end}/{asset["size"]}'
            if response.status != 206 or response.headers.get('Content-Range') != expected:
                raise ValueError('匿名分段回读范围无效：' + asset['id'])
            content = response.read(end - start + 2)
        if len(content) != end - start + 1:
            raise ValueError('匿名分段回读大小无效：' + asset['id'])
        if local:
            with Path(local).open('rb') as stream:
                stream.seek(start)
                if stream.read(len(content)) != content:
                    raise ValueError('匿名分段回读内容不同：' + asset['id'])
        samples.append({'offset': start, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
    return {'anonymousRangeVerified': True, 'samples': samples}


def audit(directory):
    """只有源码、计划、逐项证明和最终清单完全一致，才允许发布清单。"""
    plan = json.loads((directory / 'plan.json').read_text('utf-8'))
    publication = json.loads((directory / 'publication.json').read_text('utf-8'))
    if publication.get('complete') is not True or publication.get('missing') or publication.get('failures'):
        raise ValueError('镜像尚未全部完成，禁止发布完整清单')
    actual = inventory()
    if actual['models'] != plan['models']:
        raise ValueError('当前源码模型选项已变化，需要重新生成计划')
    planned = {a['id']: a for a in plan['assets']}
    if len(planned) != len(plan['assets']) or set(planned) != {a['id'] for a in actual['assets']}:
        raise ValueError('当前源码与计划的资产集合不同')
    for item in actual['assets']:
        asset = planned[item['id']]
        if any(asset.get(key) != value for key, value in item.items()):
            raise ValueError('当前源码资产路径或用途变化：' + item['id'])
        proof_path = directory / 'proofs' / (hashlib.sha256(asset['id'].encode()).hexdigest() + '.json')
        proof = json.loads(proof_path.read_text('utf-8'))
        if proof.get('verified') is not True or any(proof.get(key) != asset[key] for key in ('id', 'sha256', 'size', 'url')):
            raise ValueError('资产证明缺失或不匹配：' + asset['id'])
        mode = 'anonymousFullSha256Verified' if asset['kind'] == 'hashes' else 'anonymousRangeVerified'
        if proof.get(mode) is not True:
            raise ValueError('资产缺少匿名回读证明：' + asset['id'])
    total = sum(a['size'] for a in plan['assets'])
    if any(publication.get(key) != value for key, value in {
        'repository': plan['repository'], 'assetCount': len(planned),
        'modelCount': len(actual['models']), 'bytes': total,
    }.items()) or total != plan['total_bytes']:
        raise ValueError('最终发布报告与完整计划不一致')
    catalog = {key: plan[key] for key in ('protocol', 'product', 'models', 'assets', 'repository', 'upstream', 'total_bytes')}
    path = ROOT / 'facefusion/model_catalog.json'
    if json.loads(path.read_text('utf-8')) != catalog:
        raise ValueError('应用模型清单与已验证计划不一致')
    report = {'complete': True, 'modelCount': len(actual['models']), 'assetCount': len(planned),
              'bytes': total, 'catalogSha256': file_sha256(path), 'sourceInventoryMatches': True,
              'allProofsMatch': True}
    save(directory / 'audit.json', report)
    return report


def publish_catalog(directory):
    from scripts.build_lightweight import publish_asset
    report = audit(directory)
    plan = json.loads((directory / 'plan.json').read_text('utf-8'))
    config = json.loads((ROOT / 'update-config.json').read_text('utf-8'))
    if config['repository'] != plan['repository']:
        raise ValueError('模型镜像与应用发布仓库不一致')
    proof = publish_asset(ROOT / 'facefusion/model_catalog.json', plan['prefix'] + '/catalog.json')
    save(directory / 'catalog-publication.json', {**report, **proof})
    return proof


def publish(directory, workers=4, proxy=None):
    from modelscope.hub.api import HubApi
    from modelscope.utils.repo_utils import CommitOperationAdd, UploadInfo
    from requests.exceptions import RequestException
    plan = json.loads((directory / 'plan.json').read_text('utf-8'))
    repo = plan['repository']
    api = HubApi()
    remote = {a['Path']: a for a in api.get_model_files(repo, recursive=True) if a['Type'] == 'blob'}
    sources = [a for a in plan['assets'] if a['kind'] == 'sources']
    global_status = api._validate_blob(repo_id=repo, repo_type='model', objects=[{'oid': a['sha256'], 'size': a['size']} for a in sources])
    operations = []
    for asset in plan['assets']:
        old = remote.get(asset['remote_path'])
        if old:
            if old.get('Size') != asset['size'] or (old.get('Sha256') and old['Sha256'] != asset['sha256']):
                raise ValueError('远端不可变资源冲突：' + asset['id'])
            continue
        if asset['kind'] == 'hashes':
            base, name = asset['id'].split('/', 1)
            operation = CommitOperationAdd(asset['remote_path'], (directory / 'hashes' / base / name).read_bytes())
            operation._upload_mode = 'normal'
            operations.append(operation)
        elif asset['sha256'] in global_status and global_status[asset['sha256']] is None:
            # SDK已确认全局LFS对象存在，只提交该SHA的引用。
            operation = CommitOperationAdd(asset['remote_path'], b'')
            operation.upload_info = UploadInfo(sha256=asset['sha256'], size=asset['size'], sample=b'')
            operation._upload_mode = 'lfs'
            operation._is_uploaded = True
            operations.append(operation)
    for index in range(0, len(operations), 80):
        api.create_commit(repo, operations[index:index + 80], commit_message='models: immutable checksums and existing model objects')
    proofs = directory / 'proofs'
    proofs.mkdir(exist_ok=True)
    cache = directory / 'cache'
    cache.mkdir(exist_ok=True)
    lock = threading.Lock()
    commit_lock = threading.Lock()
    counters = {'done': 0, 'bytes': 0, 'failed': 0}
    def worker(asset):
        proof_path = proofs / (hashlib.sha256(asset['id'].encode()).hexdigest() + '.json')
        if proof_path.exists():
            value = json.loads(proof_path.read_text('utf-8'))
            if value.get('sha256') == asset['sha256'] and value.get('verified'):
                with lock:
                    counters['done'] += 1; counters['bytes'] += asset['size']
                return value
        thread_api = HubApi()
        generated = None
        try:
            reused = asset['remote_path'] in remote or (asset['sha256'] in global_status and global_status[asset['sha256']] is None)
            local = None
            if asset['kind'] == 'hashes':
                base, name = asset['id'].split('/', 1)
                local = directory / 'hashes' / base / name
            elif not reused:
                candidate = ROOT / '.assets/models' / asset['path']
                if candidate.is_file() and candidate.stat().st_size == asset['size'] and file_sha256(candidate) == asset['sha256']:
                    local = candidate
                else:
                    generated = cache / asset['sha256'] / Path(asset['id']).name
                    opener = build_opener(ProxyHandler({'http': proxy, 'https': proxy} if proxy else {}))
                    with lock:
                        print('DOWNLOAD ' + asset['id'] + f' {asset["size"] / 1024**2:.1f}MiB', flush=True)
                    download_file(asset['upstream_url'], generated, size=asset['size'], sha256=asset['sha256'], opener=opener)
                    local = generated
                checksum = 0
                with local.open('rb') as stream:
                    while chunk := stream.read(1024 * 1024):
                        checksum = zlib.crc32(chunk, checksum)
                if f'{checksum & 0xffffffff:08x}' != asset['crc32']:
                    raise ValueError('上游CRC与权重不一致：' + asset['id'])
                with lock:
                    print('UPLOAD ' + asset['id'], flush=True)
                for attempt in range(3):
                    try:
                        transfer = thread_api._upload_blob(repo_id=repo, repo_type='model', sha256=asset['sha256'], size=asset['size'], data=str(local), disable_tqdm=True)
                        break
                    except (RequestException, OSError):
                        if attempt == 2:
                            raise
                        with lock:
                            print('RETRY UPLOAD ' + asset['id'], flush=True)
                        time.sleep(2 ** attempt)
                operation = CommitOperationAdd(asset['remote_path'], local, file_hash_info={'file_size': asset['size'], 'file_hash': asset['sha256']})
                operation._upload_mode = 'lfs'
                operation._is_uploaded = True
                with commit_lock:
                    for attempt in range(7):
                        try:
                            thread_api.create_commit(repo, [operation], commit_message='models: immutable FaceFusion model weights')
                            break
                        except ValueError as error:
                            if '429' not in str(error) or attempt == 6:
                                raise
                            time.sleep(min(8, 0.5 * 2**attempt))
                reused = reused or transfer.get('is_reused', False)
            for attempt in range(3):
                try:
                    result = verify_anonymous(asset, local=local)
                    break
                except (OSError, ValueError):
                    if attempt == 2:
                        raise
                    with lock:
                        print('RETRY VERIFY ' + asset['id'], flush=True)
                    time.sleep(2 ** attempt)
            proof = {'id': asset['id'], 'sha256': asset['sha256'], 'size': asset['size'], 'url': asset['url'],
                     'verified': True, 'globallyReused': reused, 'verifiedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), **result}
            save(proof_path, proof)
            if generated and generated.is_relative_to(cache.resolve()) and generated.is_file():
                # 只清理本次生成并已上传校验的单个缓存文件。
                generated.unlink()
            with lock:
                counters['done'] += 1; counters['bytes'] += asset['size']
                print(f'DONE {counters["done"]}/{len(plan["assets"])} {counters["bytes"] / 1024**3:.2f}GiB ' + asset['id'], flush=True)
                save(directory / 'progress.json', {**counters, 'total': len(plan['assets']), 'totalBytes': plan['total_bytes']})
            return proof
        except Exception as error:
            with lock:
                counters['failed'] += 1
                save(directory / 'errors' / (hashlib.sha256(asset['id'].encode()).hexdigest() + '.json'), {'id': asset['id'], 'error': re.sub(r'(https?://[^\s?]+)\?[^\s]+', r'\1?[redacted]', str(error))})
                print('FAILED ' + asset['id'] + ' ' + re.sub(r'(https?://[^\s?]+)\?[^\s]+', r'\1?[redacted]', str(error)), flush=True)
            return {'id': asset['id'], 'verified': False, 'error': str(error)}
    # 小hash与可复用对象优先，尽早验证仓库和链接；每个worker最多占一个权重缓存。
    assets = sorted(plan['assets'], key=lambda a: (a['kind'] != 'hashes', a['sha256'] not in global_status or global_status.get(a['sha256']) is not None, not (cache / a['sha256'] / Path(a['id']).name).is_file(), a['size']))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(worker, assets))
    metadata = {a['Path']: a for a in api.get_model_files(repo, recursive=True) if a['Type'] == 'blob'}
    missing = []
    for asset in plan['assets']:
        entry = metadata.get(asset['remote_path'])
        if not entry or entry.get('Size') != asset['size'] or (entry.get('Sha256') and entry['Sha256'] != asset['sha256']):
            missing.append(asset['id'])
    failures = [a for a in results if not a.get('verified')]
    save(directory / 'publication.json', {'repository': repo, 'modelCount': len(plan['models']), 'assetCount': len(plan['assets']),
         'bytes': plan['total_bytes'], 'complete': not failures and not missing, 'missing': missing, 'failures': failures,
         'verification': '上游SHA-256和CRC、本地完整校验、服务端元数据与匿名首尾范围回读；hash文件完整回读'})
    if failures or missing:
        raise RuntimeError(f'模型覆盖尚未完成：失败{len(failures)}，远端缺失/冲突{len(missing)}，已保存可恢复进度')
    catalog = {key: plan[key] for key in ('protocol', 'product', 'models', 'assets', 'repository', 'upstream', 'total_bytes')}
    save(ROOT / 'facefusion/model_catalog.json', catalog)
    print('ALL MODELS VERIFIED: ' + str(len(plan['assets'])), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'publish', 'audit', 'publish-catalog'])
    parser.add_argument('--directory', type=Path, default=ROOT / 'build/modelscope-all-models')
    parser.add_argument('--proxy', help='仅供维护者读取上游；客户端魔搭下载不使用此设置')
    parser.add_argument('--workers', type=int, default=4)
    args = parser.parse_args()
    if args.mode == 'prepare':
        prepare(args.directory.resolve(), args.proxy)
    elif args.mode == 'audit':
        print(json.dumps(audit(args.directory.resolve()), ensure_ascii=False, indent=2))
    elif args.mode == 'publish-catalog':
        print(json.dumps(publish_catalog(args.directory.resolve()), ensure_ascii=False, indent=2))
    else:
        if not 1 <= args.workers <= 5:
            parser.error('并发缓存上限为5个权重')
        publish(args.directory.resolve(), args.workers, args.proxy)
