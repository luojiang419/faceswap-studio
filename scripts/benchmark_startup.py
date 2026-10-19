"""实际启动正式 EXE，测量首帧可见、消息响应及关闭后立即重开；仅操作本次创建的前端。"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import urlopen

import psutil

sys.path.insert(0, str(Path(__file__).resolve().parent))
from deploy_flutter_app import project_processes, request_exit


def frontend_window(root):
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    callback = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_ssize_t)
    user32.EnumWindows.argtypes = [callback, ctypes.c_ssize_t]
    user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
    user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
    matches = []

    @callback
    def visit(window, _):
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(window, name, len(name))
        if name.value != 'FLUTTER_RUNNER_WIN32_WINDOW' or not user32.IsWindowVisible(window):
            return True
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(window, ctypes.byref(pid))
        try:
            if Path(psutil.Process(pid.value).exe()).resolve().is_relative_to(root):
                matches.append((window, pid.value))
        except psutil.Error:
            pass
        return True

    user32.EnumWindows(visit, 0)
    return matches[0] if matches else None


def responsive(window):
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    user32.SendMessageTimeoutW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t,
                                          ctypes.c_ssize_t, ctypes.c_uint, ctypes.c_uint,
                                          ctypes.POINTER(ctypes.c_size_t)]
    result = ctypes.c_size_t()
    return bool(user32.SendMessageTimeoutW(window, 0, 0, 0, 2, 1000, ctypes.byref(result)))


def benchmark(root, iterations=3, timeout=90, wait_core=False, settle_seconds=0, duplicate=False):
    root = Path(root).resolve(strict=True)
    if project_processes(root):
        raise RuntimeError('目标安装已有运行进程，请先自行关闭；计时器不操作用户现有窗口。')
    records, wrappers, owned = [], [], []
    try:
        for index in range(iterations):
            start = time.perf_counter()
            process = subprocess.Popen([str(root / '易容 Studio.exe')], cwd=root)
            wrappers.append(process)
            deadline = start + timeout
            while not (found := frontend_window(root)):
                if process.poll() is not None:
                    raise RuntimeError(f'启动器提前退出：{process.returncode}')
                if time.perf_counter() >= deadline:
                    raise TimeoutError('真实首帧窗口未在限定时间内出现')
                time.sleep(.02)
            window, pid = found
            frontend = psutil.Process(pid)
            owned.append(frontend)
            record = {'iteration': index + 1, 'wrapperPid': process.pid, 'frontendPid': pid,
                      'visibleSeconds': round(time.perf_counter() - start, 3),
                      'responsive': responsive(window)}
            if duplicate:
                activated = time.perf_counter()
                repeated = subprocess.Popen([str(root / '易容 Studio.exe')], cwd=root)
                repeated.wait(timeout=10)
                assert repeated.returncode == 0
                assert frontend_window(root)[1] == pid, '重复点击创建了另一个前端'
                record['duplicateActivationSeconds'] = round(time.perf_counter() - activated, 3)
            if wait_core:
                while time.perf_counter() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f'核心就绪前启动器已退出：{process.returncode}')
                    state_file = root / 'faceswap studio/runtime/startup-state.json'
                    if state_file.is_file():
                        state = json.loads(state_file.read_text('utf-8'))
                        if state.get('state') == 'failed':
                            raise RuntimeError(state.get('message'))
                    try:
                        with urlopen('http://127.0.0.1:52741/facefusion/status', timeout=.5) as reply:
                            status = json.load(reply)
                        if status['state'] == 'ready':
                            record['coreReadySeconds'] = round(time.perf_counter() - start, 3)
                            break
                    except (OSError, ValueError):
                        pass
                    time.sleep(.2)
                else:
                    raise TimeoutError('核心未就绪')
            if settle_seconds:
                time.sleep(settle_seconds)
            closed = time.perf_counter()
            request_exit(frontend)
            frontend.wait(timeout=15)
            record['frontendCloseSeconds'] = round(time.perf_counter() - closed, 3)
            # 下一次立即启动，不等待旧 wrapper 的服务清理。
            records.append(record)
            print(json.dumps(record, ensure_ascii=False), flush=True)
        for process in wrappers:
            process.wait(timeout=45)
            if process.returncode:
                raise RuntimeError(f'启动器退出码异常：{process.returncode}')
        remaining = project_processes(root)
        if remaining:
            raise RuntimeError(f'仍有残留进程：{[p.pid for p in remaining]}')
        return {'root': str(root), 'records': records, 'remainingProcesses': [], 'ok': True}
    finally:
        for frontend in owned:
            try:
                if frontend.is_running():
                    request_exit(frontend)
            except psutil.NoSuchProcess:
                pass
        for process in wrappers:
            process.wait(timeout=45)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=3)
    parser.add_argument('--timeout', type=float, default=90)
    parser.add_argument('--wait-core', action='store_true')
    parser.add_argument('--settle-seconds', type=float, default=0)
    parser.add_argument('--duplicate', action='store_true')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = benchmark(args.root, args.iterations, args.timeout, args.wait_core, args.settle_seconds, args.duplicate)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
