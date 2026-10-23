"""用内置运行时打开原版 FaceFusion WebUI，额外模型按清单自动下载。"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import runpy
import socket
import sys

ROOT = Path(__file__).resolve().parents[1]
DLL_HANDLES = []


def prepare_environment(root: Path) -> None:
    os.chdir(root)
    sys.path.insert(0, str(root))
    os.environ['FACESWAP_STUDIO_PREFER_MODELSCOPE'] = '1'
    os.environ.setdefault('FACEFUSION_DISABLE_PROXY', '1')
    os.environ['GRADIO_ANALYTICS_ENABLED'] = 'False'
    # 原始启动脚本的 NO_PROXY=* 会使外网模型无法使用 Windows 系统代理。
    for key in ('NO_PROXY', 'no_proxy'):
        entries = [v.strip() for v in os.environ.get(key, '').split(',') if v.strip() and v.strip() != '*']
        os.environ[key] = ','.join(dict.fromkeys(entries + ['localhost', '127.0.0.1', '::1']))
    paths = [root / '.python', root / '.runtime/ffmpeg']
    paths.extend(sorted((root / '.venv-win/Lib/site-packages/nvidia').glob('*/bin')))
    os.environ['PATH'] = os.pathsep.join([str(p) for p in paths] + [os.environ.get('PATH', '')])
    if os.name == 'nt':
        os.environ['FACEFUSION_CURL_PATH'] = str(Path(os.environ['SystemRoot']) / 'System32/curl.exe')
        for path in paths:
            if path.is_dir():
                DLL_HANDLES.append(os.add_dll_directory(str(path)))
    ffmpeg = root / '.runtime/ffmpeg/ffmpeg.exe'
    if ffmpeg.is_file():
        os.environ['FACEFUSION_FFMPEG_PATH'] = str(ffmpeg)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=7861)
    parser.add_argument('--no-browser', action='store_true')
    options, extra = parser.parse_known_args()
    if not 1 <= options.port <= 65535:
        parser.error('端口必须在 1–65535 之间')
    prepare_environment(ROOT)
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1', options.port)) == 0:
            print(f'端口 {options.port} 已被使用。请关闭已有 WebUI，或使用 --port 7862。', file=sys.stderr)
            return 1
    import onnxruntime as ort
    if os.name == 'nt':
        ort.preload_dlls(directory='')
    os.environ['GRADIO_SERVER_NAME'] = '127.0.0.1'
    os.environ['GRADIO_SERVER_PORT'] = str(options.port)
    os.environ['GRADIO_NUM_PORTS'] = '1'
    provider = 'cuda' if 'CUDAExecutionProvider' in ort.get_available_providers() else 'cpu'
    sys.argv = ['facefusion.py', 'run', '--ui-layouts', 'default', '--processors', 'face_swapper',
                '--face-swapper-model', 'hyperswap_1a_256', '--execution-providers', provider,
                '--download-providers', 'modelscope', 'huggingface', 'github']
    if not options.no_browser:
        sys.argv.append('--open-browser')
    sys.argv.extend(extra)
    print(f'原版 WebUI：http://127.0.0.1:{options.port}；缺少的模型将在选择时自动校验下载。', flush=True)
    runpy.run_path(str(ROOT / 'facefusion.py'), run_name='__main__')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
