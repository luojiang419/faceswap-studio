"""在独立进程校验待运行源码；不启动服务、不下载模型、不改用户配置。"""
from __future__ import annotations

import argparse
import ast
import importlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def check(root):
    root = Path(root).resolve(strict=True)
    sys.path.insert(0, str(root))
    bridge = root / 'faceswap studio/bridge'
    sys.path.insert(1, str(bridge))
    # 执行 Bridge 的真实顶层导入，不构造会写入用户数据的全局 runtime。
    source = bridge / 'app_server.py'
    tree = ast.parse(source.read_text('utf-8-sig'), filename=str(source))
    imports = ast.Module(body=[n for n in tree.body if isinstance(n, (ast.Import, ast.ImportFrom))], type_ignores=[])
    exec(compile(imports, str(source), 'exec'), {'__file__': str(source), '__name__': 'bridge_preflight'})
    for name in ('workspace_preview_worker', 'source_face_extractor_worker'):
        path = bridge / 'services' / (name + '.py')
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

    from facefusion import core, face_creator, metadata
    from facefusion.uis.components.preview import process_preview_frame
    if not Path(core.__file__).resolve().is_relative_to(root):
        raise RuntimeError('预检错误地加载了其他安装目录的核心')
    inspect.signature(face_creator.get_many_faces).bind([])
    inspect.signature(process_preview_frame).bind(None, [], None, None, [], 'default', '512x512')
    for directory in sorted((root / 'facefusion/processors/modules').iterdir()):
        if (directory / 'core.py').is_file():
            importlib.import_module(f'facefusion.processors.modules.{directory.name}.core')
    if not core.common_pre_check():
        raise RuntimeError('FaceFusion 核心完整性校验失败')
    return {'ok': True, 'coreVersion': metadata.get('version'), 'root': str(root)}


def run_preflight(root, python=None, *, cancel=None):
    if cancel is not None and cancel.is_set():
        raise InterruptedError('Startup preflight cancelled')
    root = Path(root).resolve(strict=True)
    env = dict(os.environ)
    env.pop('PYTHONPATH', None)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    command = [str(python or sys.executable), '-B', str(Path(__file__).resolve()), '--root', str(root)]
    options = dict(cwd=root, env=env, text=True, encoding='utf-8', errors='replace',
                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if cancel is None:
        result = subprocess.run(command, capture_output=True, timeout=120, **options)
    else:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
        deadline = time.monotonic() + 120
        try:
            while not cancel.is_set():
                try:
                    stdout, stderr = process.communicate(timeout=.1)
                    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        raise
            else:
                raise InterruptedError('Startup preflight cancelled')
        finally:
            if process.poll() is None:
                import psutil
                try:
                    root_process = psutil.Process(process.pid)
                    children = root_process.children(recursive=True)
                    for child in children:
                        try:
                            child.kill()
                        except psutil.NoSuchProcess:
                            pass
                    root_process.kill()
                except psutil.NoSuchProcess:
                    pass
                process.communicate(timeout=5)
    if result.returncode:
        raise RuntimeError('核心与 Studio 兼容性预检失败：\n' + (result.stderr or result.stdout)[-6000:])
    return json.loads(result.stdout.strip().splitlines()[-1])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.root), ensure_ascii=True))
