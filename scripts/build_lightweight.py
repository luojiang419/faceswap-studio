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
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_modelscope import sources, file_url, read_json, write_json, sha256, read_remote
from sync_brand_icons import sync as sync_brand_icons


def application_sources(windows_root=None):
    """可直接打包新构建，无需关闭或覆盖正在使用的本机工作台。"""
    prefix = 'faceswap studio/runtime/windows_app/current/'
    if windows_root is not None:
        windows_root = windows_root.resolve(strict=True)
        for name in ('faceswap_studio.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat'):
            if not (windows_root / name).is_file() or not (windows_root / name).stat().st_size:
                raise ValueError('Windows 构建不完整：' + name)
    for file, name in sources():
        if windows_root is None or not name.startswith(prefix):
            yield file, name
    if windows_root is not None:
        for file in sorted(windows_root.rglob('*')):
            if file.is_file() and file.suffix not in ('.pdb', '.log'):
                yield file, prefix + file.relative_to(windows_root).as_posix()


def payload(output, windows_root=None):
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
    files.update({relative: file for file, relative in application_sources(windows_root)})
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


def refresh_payload(output, baseline, windows_root=None):
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
    overlays = dict((name, file) for file, name in application_sources(windows_root))
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
    sync_brand_icons()
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
    args.extend('/reference:' + name + '.dll' for name in ('System.Windows.Forms', 'System.Drawing', 'Accessibility', 'System.Web.Extensions', 'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Management'))
    args.extend(str(ROOT / 'installer/bootstrap' / name) for name in ('Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs', 'Maintenance.cs'))
    subprocess.run(args, check=True)
    return output


def publish_asset(file, remote, full_readback=False):
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
        existing = next((a for a in api.get_model_files(config['repository'], recursive=True) if a['Path'] == remote), None)
    if not existing or existing.get('Sha256') != digest or existing.get('Size') != file.stat().st_size:
        raise ValueError('远端资源 SHA-256 或大小不一致：' + remote)
    url = file_url(config['repository'], remote)
    verify_public_access(url, file.stat().st_size)
    if full_readback:
        verify_remote_asset(url, file.stat().st_size, digest)
    return {'url': url, 'sha256': digest, 'size': file.stat().st_size,
            'remoteMetadataVerified': True, 'anonymousAccessVerified': True,
            'anonymousFullVerified': full_readback}


def verify_public_access(url, size):
    """匿名读取一个字节验证可访问性；服务器忽略 Range 时也不下载整包。"""
    from urllib.request import build_opener, ProxyHandler, Request
    request = Request(url, headers={'Range': 'bytes=0-0', 'Accept-Encoding': 'identity'})
    with build_opener(ProxyHandler({})).open(request, timeout=30) as response:
        if response.status == 206:
            if response.headers.get('Content-Range') != f'bytes 0-0/{size}':
                raise ValueError('匿名访问的资源大小不一致')
        elif response.status != 200 or int(response.headers.get('Content-Length', -1)) != size:
            raise ValueError('匿名访问的资源状态或大小不一致')
        if size and not response.read(1):
            raise ValueError('匿名资源为空')


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
                read = getattr(response, 'read1', response.read)
                while chunk := read(256 * 1024):
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


def build(directory, existing=None, refresh_from=None, windows_root=None):
    sync_brand_icons()
    config = read_json(ROOT / 'update-config.json')
    version = (ROOT / 'VERSION').read_text('utf-8-sig').strip()
    release = config['releaseId']
    directory.mkdir(parents=True, exist_ok=True)
    package = existing.resolve(strict=True) if existing else directory / f'易容-Studio-{version}-{release}-Runtime.zip'
    if refresh_from:
        refresh_payload(package, refresh_from, windows_root)
    records = read_json(package.with_suffix('.files.json')) if package.exists() else payload(package, windows_root)
    prefix = f'bootstrap/{version}/{release}'
    payload_remote = prefix + '/' + package.name
    app_release = release
    package_digest = sha256(package)
    if existing:
        previous = read_json(package.parent / 'bootstrap-manifest.json')
        if previous['package']['sha256'] != package_digest or previous['package']['size'] != package.stat().st_size:
            raise ValueError('复用运行包与原发行清单不一致')
        if previous['appVersion'] != version or previous['entry'] != '易容 Studio.exe':
            raise ValueError('复用运行包的版本或启动入口不兼容')
        if previous['files'] != records or previous['publicKey'] != config['publicKey']:
            raise ValueError('复用运行包的文件记录或信任公钥不一致')
        old_url = previous['package']['urls'][0]
        payload_remote = urllib.parse.parse_qs(urllib.parse.urlsplit(old_url).query)['FilePath'][0]
        if file_url(config['repository'], payload_remote) != old_url:
            raise ValueError('复用运行包必须来自当前分发仓库')
        app_release = previous.get('appReleaseId', previous['releaseId'])
    manifest = {'protocol': 1, 'componentProtocol': 0, 'releaseId': release, 'appVersion': version, 'appReleaseId': release, 'publicKey': config['publicKey'],
                'entry': '易容 Studio.exe', 'files': records,
                'package': {'name': package.name, 'size': package.stat().st_size, 'sha256': package_digest,
                            'urls': [file_url(config['repository'], payload_remote)]}}
    manifest['appReleaseId'] = app_release
    write_json(directory / 'bootstrap-manifest.json', manifest)
    executable = compile_installer(manifest, directory / '易容 Studio 安装器.exe')
    (directory / '使用说明.txt').write_text('双击 易容 Studio 安装器.exe，首次选择专用安装目录后安装并运行。\n再次运行会识别已有安装并自动进行只读检查；正常时提示一切正常，可直接开始创作。\n发现问题后点击“开始修复”，正常关闭本目录工作台后按需恢复，保留作品、人物数据、配置与清单外模型。\n修复入口独立于目标 Python；修复失败会回滚本次修改，不把检查失败报告为正常。较新版本禁止被旧修复包覆盖。\n修复前请完成或取消生成任务；无法正常退出时请从托盘退出后重试，不会强杀正在生成的任务。\n检查与修复日志位于 %LOCALAPPDATA%/FaceSwapStudioMaintenance/sessions。\n安装器从魔搭下载固定 SHA-256 的完整运行包（包含 Python、常用模型和 FFmpeg），无需预装 Python。\n首次安装需要联网、至少 12 GiB 可用空间；中断后重新运行可续传。\n完成后从桌面快捷方式运行换脸工作台。软件自动检查魔搭签名更新，更新保留模型、配置与作品。\nWindows 应用列表可卸载，默认保留个人数据。\n', 'utf-8')
    (directory / 'SHA256SUMS.txt').write_text(f'{sha256(executable)}  {executable.name}\n', 'utf-8')
    distribution = directory / '易容-Studio-轻量安装器.zip'
    with zipfile.ZipFile(distribution, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in (executable, directory / '使用说明.txt', directory / 'SHA256SUMS.txt'):
            archive.write(file, file.name)
    write_json(directory / 'publication-plan.json', {'prefix': prefix, 'payloadRemote': payload_remote, 'payload': str(package), 'installer': str(executable), 'distribution': str(distribution)})
    print(json.dumps({'installer': str(executable), 'bytes': executable.stat().st_size, 'runtimeBytes': package.stat().st_size}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/modelscope/installer')
    parser.add_argument('--payload', type=Path)
    parser.add_argument('--refresh-from', type=Path, help='从已验证运行包复制并增量更新；保留旧产物')
    parser.add_argument('--windows-build-root', type=Path, help='使用指定 Windows Release 构建，不改动本机部署')
    parser.add_argument('--publish', action='store_true')
    parser.add_argument('--full-readback', action='store_true', help='发布时额外匿名完整下载校验；默认仅核对远端哈希、大小与匿名访问')
    args = parser.parse_args()
    if args.full_readback and not args.publish:
        parser.error('--full-readback 仅用于发布验证')
    if args.refresh_from and (args.publish or args.payload):
        parser.error('--refresh-from仅用于构建，不能与--payload或--publish合用')
    if args.windows_build_root and (args.payload or args.publish):
        parser.error('--windows-build-root 仅用于构建新运行包，不能与 --payload 或 --publish 合用')
    if not args.publish:
        build(args.output.resolve(), args.payload, args.refresh_from, args.windows_build_root)
    else:
        plan = read_json(args.output / 'publication-plan.json')
        proof = {}
        for name in ('payload', 'installer', 'distribution'):
            remote = plan.get('payloadRemote') if name == 'payload' else None
            remote = remote or plan['prefix'] + '/' + Path(plan[name]).name
            proof[name] = publish_asset(Path(plan[name]), remote, full_readback=args.full_readback)
        write_json(args.output / 'publication.json', proof)
        print(json.dumps(proof, ensure_ascii=False, indent=2))
