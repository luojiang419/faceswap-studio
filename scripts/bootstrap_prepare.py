"""安装器通过便携 Python 调用；修复路径、自检后启动真实工作台。"""
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    python_root = root / '.python'
    python = root / '.venv-win/Scripts/python.exe'
    cfg = root / '.venv-win/pyvenv.cfg'
    cfg.write_text(f'home = {python_root}\ninclude-system-site-packages = false\nversion = {sys.version.split()[0]}\nexecutable = {python_root / "python.exe"}\n', encoding='utf-8')
    subprocess.run([str(python), '-c', 'import onnxruntime, cv2, fastapi, cryptography, uvicorn; print(onnxruntime.get_available_providers())'], cwd=root, check=True)
    subprocess.run([str(python), str(root / 'scripts/validate_offline_models.py'), '--manifest', str(root / 'installer/core-models.txt'), '--models-dir', str(root / '.assets/models')], cwd=root, check=True)
    env = dict(os.environ)
    env['FACESWAP_STUDIO_BRIDGE_HOST'] = '127.0.0.1'
    child = subprocess.Popen([str(python), str(root / 'launch_faceswap_studio.py')], cwd=root, env=env)
    # 保持启动准备进程存活，直至安装器收到来自真实 Flutter 首帧的握手。
    return child.wait()


if __name__ == '__main__':
    raise SystemExit(main())
