"""从已安装运行环境与当前应用构建全量离线包，不包含个人数据或下载缓存。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'scripts'))
from build_lightweight import application_sources, compile_installer, refresh_payload
from release_modelscope import read_json, sha256, write_json
from validate_offline_models import create_file_hash, validate_offline_models

IGNORED_DIRS = {'__pycache__', '.pytest_cache', '.git'}
MSVC_NAMES = ('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll',
              'msvcp140_codecvt_ids.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'concrt140.dll')


def runtime_files(installation: Path):
    for directory in ('.python', '.venv-win', '.runtime/ffmpeg', '.assets/models'):
        base = installation / directory
        if not base.is_dir():
            raise ValueError('运行环境缺少目录：' + str(base))
        for current, dirs, names in os.walk(base, followlinks=False):
            for directory_name in dirs:
                directory_path = Path(current) / directory_name
                if directory_path.is_symlink() or directory_path.is_junction():
                    raise ValueError('不打包运行时链接：' + str(directory_path))
            dirs[:] = sorted(d for d in dirs if d not in IGNORED_DIRS)
            for name in sorted(names):
                file = Path(current) / name
                if file.suffix.lower() in ('.pyc', '.pyo', '.log', '.part', '.tmp'):
                    continue
                if file.is_symlink() or file.is_junction():
                    raise ValueError('不打包运行时链接：' + str(file))
                yield file.relative_to(installation).as_posix(), file


def validate_models(installation: Path) -> list[dict]:
    models = installation / '.assets/models'
    validate_offline_models(ROOT / 'installer/core-models.txt', models)
    result = []
    for model in sorted(models.rglob('*')):
        if model.suffix.lower() not in ('.onnx', '.dfm'):
            continue
        crc = model.with_suffix('.hash')
        if crc.is_file() and create_file_hash(model) != crc.read_text('utf-8-sig').strip().lower():
            raise ValueError('本机模型 CRC 校验失败：' + model.name)
        result.append({'name': model.relative_to(models).as_posix(), 'size': model.stat().st_size,
                       'sha256': sha256(model), 'crcVerified': crc.is_file()})
    return result


def inspect_runtime(installation: Path) -> dict:
    python = installation / '.venv-win/Scripts/python.exe'
    subprocess.run([str(python), '-m', 'pip', 'check'], check=True)
    code = ('import json,sys,importlib.metadata as m; '
            'print(json.dumps({"python":sys.version.split()[0],"packages":'
            'dict(sorted((d.metadata["Name"],d.version) for d in m.distributions()))}))')
    value = json.loads(subprocess.check_output([str(python), '-I', '-c', code], text=True))
    required = {'onnxruntime-gpu': '1.24.4', 'nvidia-cuda-runtime-cu12': '12.9.79', 'nvidia-cudnn-cu12': '9.23.1.3'}
    for name, version in required.items():
        if value['packages'].get(name) != version:
            raise ValueError(f'运行环境与已审核 GPU 组合不一致：{name} 需要 {version}')
    value.update({'cuda': '12.9', 'minimumRecommendedWindowsDriver': '576.57',
                  'gpuFamilies': {'RTX 20': 'Turing / sm_75', 'RTX 30': 'Ampere / sm_86',
                                  'RTX 40': 'Ada Lovelace / sm_89', 'RTX 50': 'Blackwell / sm_120'},
                  'sharedRuntime': True, 'gpuValidation': '实机验证结果见 verification.json；兼容表不表示全部显卡已实测',
                  'sources': ['https://docs.nvidia.com/deeplearning/cudnn/backend/v9.23.1/reference/support-matrix.html',
                              'https://docs.nvidia.com/cuda/archive/12.9.1/cuda-toolkit-release-notes/index.html',
                              'https://onnxruntime.ai/docs/execution-providers/CUDA-ExecutionProvider.html']})
    return value


def build(installation: Path, output: Path, msvc_root: Path, windows_root: Path | None = None, refresh_from: Path | None = None) -> dict:
    installation = installation.resolve(strict=True)
    windows_root = windows_root or installation / 'faceswap studio/runtime/windows_app/current'
    output = output.resolve()
    if output.exists():
        raise ValueError('拒绝覆盖已有产物目录，请指定新目录：' + str(output))
    if output.is_relative_to(installation):
        raise ValueError('分发目录不能位于源安装目录内')
    models = validate_models(installation)
    profile = inspect_runtime(installation)
    files = dict(runtime_files(installation))
    files.update({name: file for file, name in application_sources(windows_root)})
    for name in ('facefusion.ini', 'requirements.txt', 'LICENSE.md', 'README.md', 'installer/core-models.txt',
                 'scripts/validate_offline_models.py', 'scripts/launch_original_webui.py', '启动原版WebUI.cmd'):
        files[name] = ROOT / name
    # App-local VC++：Python/venv 与 Flutter 均不依赖用户预装开发工具。
    for name in MSVC_NAMES:
        file = msvc_root / name
        if not file.is_file():
            raise ValueError('VC++ 可分发运行库缺失：' + str(file))
        for directory in ('.python', '.venv-win/Scripts', 'faceswap studio/runtime/windows_app/current'):
            files[directory + '/' + name] = file
    required = ('.python/python.exe', '.venv-win/Scripts/python.exe', '.runtime/ffmpeg/ffmpeg.exe',
                '.runtime/ffmpeg/ffprobe.exe', '.venv-win/Lib/site-packages/nvidia/cublas/bin/cublas64_12.dll',
                '.venv-win/Lib/site-packages/nvidia/cudnn/bin/cudnn64_9.dll')
    for name in required:
        if name not in files:
            raise ValueError('全量包缺少必要运行文件：' + name)
    total = sum(file.stat().st_size for file in files.values())
    output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output.parent).free < total * 3 + 1024**3:
        raise OSError('至少预留三倍待打包文件大小与 1 GiB 临时空间')
    output.mkdir()
    write_json(output / 'runtime-profile.json', profile)
    write_json(output / 'included-models.json', models)
    (output / 'requirements-runtime.lock.txt').write_text(''.join(f'{k}=={v}\n' for k, v in profile['packages'].items()), 'utf-8')
    for name in ('runtime-profile.json', 'included-models.json', 'requirements-runtime.lock.txt'):
        files[name] = output / name
    package = output / '易容-Studio-完整运行环境.zip'
    records = []
    if refresh_from:
        previous = read_json(refresh_from / 'bootstrap-manifest.json')
        if not previous.get('offline') or read_json(refresh_from / 'runtime-profile.json') != profile or read_json(refresh_from / 'included-models.json') != models:
            raise ValueError('仅允许相同运行时与模型的应用增量重打包')
        baseline = refresh_from / previous['package']['name']
        if sha256(baseline) != previous['package']['sha256']:
            raise ValueError('旧离线包校验失败')
        write_json(baseline.with_suffix('.files.json'), previous['files'])
        refresh_payload(package, baseline, windows_root)
        records = read_json(package.with_suffix('.files.json'))
        # 新的独立入口与模型校验定义也必须与当前源码一致。
        by_name = {r['name']: r for r in records}
        for name in ('scripts/launch_original_webui.py', '启动原版WebUI.cmd', 'installer/core-models.txt', 'scripts/validate_offline_models.py'):
            if name not in by_name or sha256(files[name]) != by_name[name]['sha256']:
                raise ValueError('离线入口或模型定义已变化，请重新完整构建：' + name)
    else:
        with zipfile.ZipFile(package, 'x', zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
            for index, (name, file) in enumerate(sorted(files.items())):
                archive.write(file, 'FaceSwapStudio/' + name)
                records.append({'name': name, 'size': file.stat().st_size, 'sha256': sha256(file)})
                if index % 1000 == 0:
                    print(f'打包 {index}/{len(files)}：{name}', flush=True)
    config = read_json(ROOT / 'update-config.json')
    manifest = {'protocol': 1, 'componentProtocol': 0, 'offline': True,
                'releaseId': datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'),
                'appVersion': (ROOT / 'VERSION').read_text('utf-8-sig').strip(),
                'appReleaseId': config['releaseId'], 'publicKey': config['publicKey'],
                'entry': '易容 Studio.exe', 'files': records,
                'package': {'name': package.name, 'size': package.stat().st_size, 'sha256': sha256(package), 'urls': []}}
    write_json(output / 'bootstrap-manifest.json', manifest)
    executable = compile_installer(manifest, output / '易容 Studio 全量安装器.exe')
    (output / '使用说明.txt').write_text(
        '易容 Studio 0.1.3 全量离线包（Windows x64）\n\n'
        '1. 完整解压分发 ZIP，再双击“易容 Studio 全量安装器.exe”；保持安装器与“易容-Studio-完整运行环境.zip”在同一目录。\n'
        '2. Python、CUDA/cuDNN、所有 Python 依赖、FFmpeg、桌面与 Web 工作台、当前本机模型已包含；首装不联网补运行环境。\n'
        '3. RTX 20/30/40/50 系共用 CUDA 12.9 / cuDNN 9，建议 NVIDIA Windows 驱动 576.57 或更新；不包含显卡驱动。\n'
        '4. 至少预留 12 GiB 安装盘空间；同盘同时保留分发 ZIP、解压资源和软件时建议 25 GiB。\n'
        '5. 正常使用桌面“易容 Studio”。需要原版界面时，双击安装目录“启动原版WebUI.cmd”，默认地址 http://127.0.0.1:7861 。\n'
        '   端口占用可运行“启动原版WebUI.cmd --port 7862”；窗口关闭后 WebUI 停止。\n'
        '6. 额外模型在原版 WebUI 选择时自动校验并补齐；魔搭已有资源优先，74 个可选 DFM 从固定原 Hugging Face 仓库下载，跟随系统代理。\n'
        '   模型下载需要联网；原仓库无法访问时请使用可用的系统代理后重试，已下载分片保留。自定义私有模型需自行提供。\n'
        '7. 再运行此全量安装器可检查修复；离线修复需保留完整资源 ZIP。Windows 应用列表可卸载软件、环境与模型，默认保留个人作品和配置。\n'
        '8. 全量包不含本机人物照片、作品、配置、任务记录或下载缓存。模型与第三方组件保留各自授权。\n'
        '9. RTX 40 系有本机实际 GPU 验证；20/30/50 系依据官方兼容矩阵，尚无对应实机验证。\n', 'utf-8')
    sums = ''.join(f'{sha256(f)}  {f.name}\n' for f in (executable, package))
    (output / 'SHA256SUMS.txt').write_text(sums, 'utf-8')
    write_json(output / 'build-report.json', {'createdAt': datetime.now(timezone.utc).isoformat(),
               'sourceInstallation': str(installation), 'runtimeFileCount': len(records),
               'installedBytes': sum(r['size'] for r in records), 'packageBytes': package.stat().st_size,
               'modelCount': len(models), 'modelBytes': sum(m['size'] for m in models),
               'excluded': ['个人照片与作品', '设置与任务记录', 'data/cache', '下载分片', '编译缓存'],
               'applicationSource': str(ROOT), 'windowsSource': str(windows_root or ROOT / 'faceswap studio/runtime/windows_app/current')})
    print(json.dumps({'output': str(output), 'bytes': package.stat().st_size, 'files': len(records)}, ensure_ascii=False), flush=True)
    return manifest


def distribute(output: Path) -> Path:
    manifest = read_json(output / 'bootstrap-manifest.json')
    package = output / manifest['package']['name']
    if sha256(package) != manifest['package']['sha256']:
        raise ValueError('资源包 SHA-256 校验失败')
    expected = {f['name']: f for f in manifest['files']}
    with zipfile.ZipFile(package) as archive:
        entries = [entry for entry in archive.infolist() if not entry.is_dir()]
        if len(entries) != len(expected):
            raise ValueError('资源包文件集合不一致')
        for entry in entries:
            if not entry.filename.startswith('FaceSwapStudio/'):
                raise ValueError('资源包根目录无效')
            name = entry.filename.removeprefix('FaceSwapStudio/')
            record = expected.pop(name)
            with archive.open(entry) as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if digest != record['sha256'] or entry.file_size != record['size']:
                raise ValueError('资源包实际文件校验失败：' + name)
    distribution = output.parent / (output.name + '.zip')
    with zipfile.ZipFile(distribution, 'x', zipfile.ZIP_STORED, allowZip64=True) as archive:
        for file in sorted(output.iterdir()):
            if file.is_file() and file.suffix != '.gz':
                archive.write(file, output.name + '/' + file.name)
    with zipfile.ZipFile(distribution) as archive:
        if archive.testzip() is not None:
            raise ValueError('最终分发 ZIP CRC 校验失败')
    distribution.with_suffix('.zip.sha256').write_text(f'{sha256(distribution)}  {distribution.name}\n', 'utf-8')
    return distribution


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', type=Path, default=Path('D:/Program Files/FaceSwapStudio'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--msvc-root', type=Path, help='Visual Studio x64 CRT 可分发 DLL 目录')
    parser.add_argument('--windows-build-root', type=Path)
    parser.add_argument('--refresh-from', type=Path, help='相同运行时与模型，复用旧完整包仅替换最新应用')
    parser.add_argument('--distribute', action='store_true', help='完成验收后校验并生成分发 ZIP')
    args = parser.parse_args()
    if args.distribute:
        print(distribute(args.output.resolve()))
    elif args.msvc_root is None:
        parser.error('构建需要 --msvc-root 指向已验证的 x64 VC++ 可分发运行库')
    else:
        build(args.installation, args.output, args.msvc_root.resolve(), args.windows_build_root, args.refresh_from)
