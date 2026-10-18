"""复用 VoxCPM 原生安装器；运行包独立存放魔搭，安装 EXE 不内置依赖与模型。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_modelscope import sources, file_url, read_json, write_json, sha256, read_remote


def payload(output):
    baseline = ROOT / 'build/installer/app'
    if not (baseline / '.python/python.exe').exists():
        raise ValueError('需要经过离线验证的安装 staging：先运行 scripts/build_installer.ps1 -SkipInnoBuild')
    files = {}
    for folder in ('.python', '.venv-win', '.runtime', '.assets'):
        for file in sorted((baseline / folder).rglob('*')):
            relative = file.relative_to(baseline)
            if file.is_file() and not any(p in ('__pycache__', 'Doc', 'include', '.pytest_cache') for p in relative.parts) and file.suffix not in ('.pyc', '.pyo', '.log'):
                files[relative.as_posix()] = file
    # 签名依赖固定版本加入独立运行环境，兼容既有离线 staging。
    site = ROOT / '.venv-win/Lib/site-packages'
    for pattern in ('cryptography*', 'cffi*', '_cffi_backend*', 'pycparser*'):
        for match in site.glob(pattern):
            for file in ([match] if match.is_file() else match.rglob('*')):
                if file.is_file() and '__pycache__' not in file.parts:
                    files['.venv-win/Lib/site-packages/' + file.relative_to(site).as_posix()] = file
    files.update({relative: file for file, relative in sources()})
    for name in ('facefusion.ini', 'requirements.txt', 'LICENSE.md', 'scripts/validate_offline_models.py', 'installer/core-models.txt'):
        files[name] = ROOT / name
    output.parent.mkdir(parents=True, exist_ok=True)
    records = []
    with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
        for index, (name, file) in enumerate(sorted(files.items())):
            archive.write(file, 'FaceSwapStudio/' + name)
            records.append({'name': name, 'size': file.stat().st_size, 'sha256': sha256(file)})
            if index % 1000 == 0:
                print(f'打包 {index}/{len(files)}', flush=True)
    write_json(output.with_suffix('.files.json'), records)
    return records


def refresh_payload(output, baseline):
    """保留旧运行包，用7z增量替换应用文件，避免重新压缩全部依赖。"""
    from updater.transaction import safe_path
    baseline = baseline.resolve(strict=True)
    records = read_json(baseline.with_suffix('.files.json'))
    if output.exists() or output.with_suffix('.files.json').exists():
        raise ValueError('拒绝覆盖已有运行包：' + str(output))
    by_name = {item['name']: item for item in records}
    with zipfile.ZipFile(baseline) as archive:
        entries = {item.filename: item for item in archive.infolist() if not item.is_dir()}
        if len(entries) != len(records) or any(entries.get('FaceSwapStudio/' + item['name']) is None or
                entries['FaceSwapStudio/' + item['name']].file_size != item['size'] for item in records):
            raise ValueError('旧运行包与文件记录不一致')
    output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output.parent).free < baseline.stat().st_size * 2 + 512 * 1024**2:
        raise OSError('运行包增量更新需要两倍压缩包大小和512MiB临时空间')
    executable = shutil.which('7z')
    if not executable:
        raise ValueError('增量更新运行包需要7z')
    stage = ROOT / 'build/lightweight-overlay' / output.stem
    overlays = dict((name, file) for file, name in sources())
    overlays['facefusion.ini'] = ROOT / 'facefusion.ini'
    for name, file in overlays.items():
        if name != 'facefusion.ini':
            safe_path(name)
        target = stage / 'FaceSwapStudio' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
        by_name[name] = {'name': name, 'size': file.stat().st_size, 'sha256': sha256(file)}
    with baseline.open('rb') as source, output.open('xb') as destination:
        shutil.copyfileobj(source, destination, 4 * 1024**2)
    subprocess.run([executable, 'u', '-tzip', '-mx=1', '-y', str(output), 'FaceSwapStudio'],
                   cwd=stage, check=True, stdout=subprocess.DEVNULL)
    records = sorted(by_name.values(), key=lambda item: item['name'])
    with zipfile.ZipFile(output) as archive:
        entries = {item.filename: item for item in archive.infolist() if not item.is_dir()}
        if len(entries) != len(records) or any(entries['FaceSwapStudio/' + item['name']].file_size != item['size'] for item in records):
            raise ValueError('新运行包文件集合不一致')
        for name in overlays:
            if hashlib.sha256(archive.read('FaceSwapStudio/' + name)).hexdigest() != by_name[name]['sha256']:
                raise ValueError('运行包增量文件内容不一致：' + name)
    write_json(output.with_suffix('.files.json'), records)
    return output


def compile_installer(manifest, output, demo=False):
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = output.with_suffix('.manifest.json.gz')
    descriptor.write_bytes(gzip.compress(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode(), mtime=0))
    args = ['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe', '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/out:' + str(output),
            '/win32icon:' + str(ROOT / 'facefusion.ico'),
            '/win32manifest:' + str(ROOT / 'installer/bootstrap/app.manifest'),
            '/resource:' + str(ROOT / 'facefusion.ico') + ',app.ico',
            '/resource:' + str(ROOT / 'facefusion.ico') + ',installer.ico',
            '/resource:' + str(ROOT / 'installer/assets/app-mark.png') + ',app-mark.png',
            '/resource:' + str(ROOT / 'installer/assets/disk-local-256.png') + ',disk-local.png',
            '/resource:' + str(descriptor) + ',bootstrap-manifest.json']
    if demo:
        args.append('/define:DEMO')
    args.extend('/reference:' + name + '.dll' for name in ('System.Windows.Forms', 'System.Drawing', 'Accessibility', 'System.Web.Extensions', 'System.IO.Compression', 'System.IO.Compression.FileSystem'))
    args.extend(str(ROOT / 'installer/bootstrap' / name) for name in ('Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs'))
    subprocess.run(args, check=True)
    return output


def publish_asset(file, remote):
    from modelscope.hub.api import HubApi
    config = read_json(ROOT / 'update-config.json')
    api = HubApi()
    existing = next((a for a in api.get_model_files(config['repository'], recursive=True) if a['Path'] == remote), None)
    digest = sha256(file)
    if existing:
        if existing.get('Sha256') != digest or existing.get('Size') != file.stat().st_size:
            raise ValueError('拒绝覆盖魔搭同名不同内容资源：' + remote)
    else:
        api.upload_file(path_or_fileobj=str(file), path_in_repo=remote, repo_id=config['repository'], commit_message='assets: immutable FaceFusion desktop distribution')
    # 流式匿名完整回读，避免数 GB 的内存峰值。
    url = file_url(config['repository'], remote)
    verify_remote_asset(url, file.stat().st_size, digest)
    return {'url': url, 'sha256': digest, 'size': file.stat().st_size, 'anonymousFullVerified': True}


def verify_remote_asset(url, size, expected):
    """按实际收到的字节续接匿名回读，完整覆盖后才接受 SHA-256。"""
    from http.client import HTTPException
    import re
    from urllib.error import URLError
    from urllib.request import build_opener, ProxyHandler, Request
    offset = 0
    digest = hashlib.sha256()
    failures = 0
    next_report = 256 * 1024**2
    while offset < size:
        before = offset
        try:
            request = Request(url, headers={'Range': f'bytes={offset}-', 'Accept-Encoding': 'identity'})
            with build_opener(ProxyHandler({})).open(request, timeout=120) as response:
                if response.status == 206:
                    match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                    if not match or int(match[1]) != offset or int(match[3]) != size:
                        raise ValueError('匿名回读范围不匹配')
                elif response.status == 200:
                    if offset:
                        offset = 0
                        digest = hashlib.sha256()
                else:
                    raise ValueError('匿名回读状态无效')
                while chunk := response.read(256 * 1024):
                    offset += len(chunk)
                    if offset > size:
                        raise ValueError('匿名回读超过资源大小')
                    digest.update(chunk)
                    if offset >= next_report:
                        print(f'匿名回读 {offset}/{size}', flush=True)
                        next_report = offset + 256 * 1024**2
        except (OSError, URLError, HTTPException):
            failures += 1
            if failures >= 3:
                raise
        if offset <= before:
            failures += 1
            if failures >= 3:
                raise OSError('匿名回读多次没有进展')
        else:
            failures = 0
    if digest.hexdigest() != expected:
        raise ValueError('匿名完整回读 SHA-256 不一致')


def build(directory, existing=None, refresh_from=None):
    config = read_json(ROOT / 'update-config.json')
    version = (ROOT / 'VERSION').read_text('utf-8-sig').strip()
    release = config['releaseId']
    directory.mkdir(parents=True, exist_ok=True)
    package = existing or directory / f'FaceSwap-Studio-{version}-{release}-Runtime.zip'
    if refresh_from:
        refresh_payload(package, refresh_from)
    records = read_json(package.with_suffix('.files.json')) if package.exists() else payload(package)
    prefix = f'bootstrap/{version}/{release}'
    manifest = {'protocol': 1, 'componentProtocol': 0, 'releaseId': release, 'appVersion': version, 'appReleaseId': release,
                'entry': '启动FaceSwap Studio.exe', 'files': records,
                'package': {'name': package.name, 'size': package.stat().st_size, 'sha256': sha256(package),
                            'urls': [file_url(config['repository'], prefix + '/' + package.name)]}}
    write_json(directory / 'bootstrap-manifest.json', manifest)
    executable = compile_installer(manifest, directory / 'FaceSwap安装器.exe')
    (directory / '使用说明.txt').write_text('双击 FaceSwap安装器.exe，选择安装位置后安装并运行。\n安装器从魔搭下载固定 SHA-256 的完整运行包（包含 Python、常用模型和 FFmpeg），无需预装 Python。\n首次安装需要联网、至少 12 GiB 可用空间；中断后重新运行可续传。\n完成后从桌面快捷方式运行换脸工作台。软件自动检查魔搭签名更新，更新保留模型、配置与作品。\nWindows 应用列表可卸载，默认保留个人数据。\n', 'utf-8')
    (directory / 'SHA256SUMS.txt').write_text(f'{sha256(executable)}  {executable.name}\n', 'utf-8')
    distribution = directory / 'FaceSwap-Studio-轻量安装器.zip'
    with zipfile.ZipFile(distribution, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in (executable, directory / '使用说明.txt', directory / 'SHA256SUMS.txt'):
            archive.write(file, file.name)
    write_json(directory / 'publication-plan.json', {'prefix': prefix, 'payload': str(package), 'installer': str(executable), 'distribution': str(distribution)})
    print(json.dumps({'installer': str(executable), 'bytes': executable.stat().st_size, 'runtimeBytes': package.stat().st_size}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/modelscope/installer')
    parser.add_argument('--payload', type=Path)
    parser.add_argument('--refresh-from', type=Path, help='从已验证运行包复制并增量更新；保留旧产物')
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    if args.refresh_from and (args.publish or args.payload):
        parser.error('--refresh-from仅用于构建，不能与--payload或--publish合用')
    if not args.publish:
        build(args.output.resolve(), args.payload, args.refresh_from)
    else:
        plan = read_json(args.output / 'publication-plan.json')
        proof = {name: publish_asset(Path(plan[name]), plan['prefix'] + '/' + Path(plan[name]).name) for name in ('payload', 'installer', 'distribution')}
        write_json(args.output / 'publication.json', proof)
        print(json.dumps(proof, ensure_ascii=False, indent=2))
