"""正常退出本目录 Studio 并整体切换前端；失败保留旧版，绝不强杀前端。"""
from __future__ import annotations

import argparse
import ctypes
from pathlib import Path
import shutil
import sys
import tempfile

import psutil

REQUIRED = ('faceswap_studio.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')


def project_processes(root):
    root = Path(root).resolve()
    matches = []
    for process in psutil.process_iter(['exe', 'cmdline']):
        try:
            exe = Path(process.info['exe'] or '')
            if not exe.is_absolute() or not exe.resolve().is_relative_to(root):
                continue
            args = process.info['cmdline'] or []
            if exe.name.lower() in ('faceswap_studio.exe', '启动faceswap studio.exe') or any(
                    Path(arg).name in ('launch_faceswap_studio.py', 'facefusion.py') for arg in args) or (
                    'uvicorn' in args and 'app_server:app' in args):
                matches.append(process)
        except (psutil.Error, OSError):
            continue
    managed = {process.pid: process for process in matches}
    for process in matches:
        try:
            # venv 的重定向进程可能继续运行安装目录外的基础 Python。
            managed.update((child.pid, child) for child in process.children(recursive=True))
        except psutil.Error:
            pass
    return list(managed.values())


def request_exit(process):
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_ssize_t)
    user32.EnumWindows.argtypes = [callback_type, ctypes.c_ssize_t]
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
    user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
    sent = []

    @callback_type
    def visit(window, _):
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(window, ctypes.byref(pid))
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(window, name, len(name))
        if pid.value == process.pid and name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
            # 已有托盘“退出程序”命令，兼容关闭按钮默认最小化的旧版本。
            sent.append(bool(user32.PostMessageW(window, 0x0111, 1002, 0)))
        return True

    user32.EnumWindows(visit, 0)
    if not any(sent) and process.is_running():
        raise RuntimeError(f'无法请求前端 {process.pid} 正常退出，请从托盘退出程序后重试')


def stop_studio(root, timeout=60):
    processes = project_processes(root)
    for process in processes:
        try:
            if process.name().lower() == 'faceswap_studio.exe':
                request_exit(process)
        except psutil.NoSuchProcess:
            pass
    _, active = psutil.wait_procs(processes, timeout=timeout)
    active = [p for p in active if p.is_running()]
    if active or project_processes(root):
        raise TimeoutError('Studio/启动器/核心尚未退出，已取消覆盖；请退出程序后重试')


def deploy(root, source):
    root, source = Path(root).resolve(strict=True), Path(source).resolve(strict=True)
    for relative in REQUIRED:
        if not (source / relative).is_file() or not (source / relative).stat().st_size:
            raise ValueError('前端构建不完整：' + relative)
    parent = root / 'faceswap studio/runtime/windows_app'
    parent.mkdir(parents=True, exist_ok=True)
    current = parent / 'current'
    if not parent.resolve().is_relative_to(root) or current.is_symlink() or current.is_junction():
        raise ValueError('拒绝替换安装目录外或通过链接指向的前端目录')
    temp = Path(tempfile.mkdtemp(prefix='deploy-', dir=parent))
    stage, previous = temp / 'new', temp / 'previous'
    try:
        shutil.copytree(source, stage)
        stop_studio(root)
        if current.exists():
            current.rename(previous)
        try:
            stage.rename(current)
        except BaseException:
            if previous.exists():
                previous.rename(current)
            raise
    except BaseException:
        # 恢复也失败时必须保留 previous，不能由临时目录上下文删除唯一旧版。
        if not previous.exists():
            shutil.rmtree(temp)
        raise
    else:
        shutil.rmtree(temp)
    return current


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if args.source:
        print(deploy(args.root, args.source))
    else:
        stop_studio(args.root)
        print('Studio 已正常退出，文件可以安全替换。')
