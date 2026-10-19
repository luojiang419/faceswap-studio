import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


BRIDGE_CHECK_HOST = "127.0.0.1"
BRIDGE_LISTEN_HOST = os.environ.get("FACESWAP_STUDIO_BRIDGE_HOST", "0.0.0.0")
BRIDGE_HOST = BRIDGE_CHECK_HOST
BRIDGE_PORT = int(os.environ.get("FACESWAP_STUDIO_BRIDGE_PORT", "52741"))
BRIDGE_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/health"
MODEL_BOOTSTRAP_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/models/bootstrap"
FACEFUSION_STATUS_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/status"
FACEFUSION_START_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/start"
FACEFUSION_STOP_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/stop"
BRIDGE_HEALTH_TIMEOUT_SECONDS = 3.0
BRIDGE_COMPATIBILITY_TIMEOUT_SECONDS = 5.0
BRIDGE_OCCUPIED_PORT_WAIT_SECONDS = 20.0
FRONTEND_MIN_MANAGED_SESSION_SECONDS = 30.0
FACEFUSION_DEFERRED_START_SECONDS = 8.0
WINDOWS_FRONTEND_ENGINE_FLAGS = ["--enable-software-rendering"]
LAUNCHER_MUTEX_NAME = "Local\\FaceSwapStudio.Runtime"
UPDATE_CACHE_DIRNAME = "FaceSwap Studio"
STALE_RUNTIME_COMMAND_MARKERS = (
    "launch_faceswap_studio.py",
    "uvicorn app_server:app",
    "facefusion.py",
)
STALE_RUNTIME_EXECUTABLE_NAMES = {
    "faceswap_studio.exe",
}
WINDOW_CLASS_NAME = "FLUTTER_RUNNER_WIN32_WINDOW"
WINDOW_TITLE = "易容 Studio"
ACTIVATE_WINDOW_MESSAGE_NAME = "FaceSwapStudio.ActivateWindow"
ERROR_ALREADY_EXISTS = 183
SW_RESTORE = 9


def acquire_single_instance_lock(studio_root: Path) -> tuple[int | None, bool]:
    if os.name != "nt":
        return None, False

    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        kernel32.CreateMutexW.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_bool
        handle = kernel32.CreateMutexW(None, True, LAUNCHER_MUTEX_NAME)
        if not handle:
            write_launcher_log(studio_root, "Launcher mutex could not be created; continuing without single-instance guard.")
            return None, False
        if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
            kernel32.CloseHandle(handle)
            return None, True
        return int(handle), False
    except Exception as error:
        write_launcher_log(studio_root, f"Launcher mutex check failed; continuing without guard: {error}")
        return None, False


def release_single_instance_lock(handle: int | None, studio_root: Path) -> None:
    if os.name != "nt" or not handle:
        return

    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        kernel32.ReleaseMutex.argtypes = [ctypes.c_void_p]
        kernel32.ReleaseMutex.restype = ctypes.c_bool
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_bool
        kernel32.ReleaseMutex(handle)
        kernel32.CloseHandle(handle)
    except Exception as error:
        write_launcher_log(studio_root, f"Launcher mutex release failed: {error}")


def notify_running_instance() -> bool:
    if os.name != "nt":
        return False

    try:
        import ctypes

        user32 = ctypes.windll.user32
        user32.RegisterWindowMessageW.argtypes = [ctypes.c_wchar_p]
        user32.RegisterWindowMessageW.restype = ctypes.c_uint
        user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t]
        user32.PostMessageW.restype = ctypes.c_bool
        user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
        user32.ShowWindow.restype = ctypes.c_bool
        user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
        user32.SetForegroundWindow.restype = ctypes.c_bool
        activate_message = user32.RegisterWindowMessageW(ACTIVATE_WINDOW_MESSAGE_NAME)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            existing_window = user32.FindWindowW(WINDOW_CLASS_NAME, WINDOW_TITLE)
            if existing_window:
                if activate_message:
                    user32.PostMessageW(existing_window, activate_message, 0, 0)
                user32.ShowWindow(existing_window, SW_RESTORE)
                user32.SetForegroundWindow(existing_window)
                return True
            time.sleep(0.1)
    except Exception:
        return False
    return False


def resolve_repo_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def read_app_version(repo_root: Path) -> str:
    version_path = repo_root / "VERSION"
    try:
        version = version_path.read_text(encoding="utf-8").strip()
    except OSError:
        version = "0.0.0"
    return version or "0.0.0"


def version_parts(version: str) -> tuple[int, ...]:
    parts: list[int] = []
    for segment in version.strip().lstrip("v").replace("-", ".").split("."):
        digits = "".join(ch for ch in segment if ch.isdigit())
        if digits:
            parts.append(int(digits))
        else:
            parts.append(0)
    return tuple(parts or [0])


def is_newer_version(latest: str, current: str) -> bool:
    latest_parts = list(version_parts(latest))
    current_parts = list(version_parts(current))
    width = max(len(latest_parts), len(current_parts))
    latest_parts += [0] * (width - len(latest_parts))
    current_parts += [0] * (width - len(current_parts))
    return latest_parts > current_parts


def resolve_flutter_binary(repo_root: Path) -> Path | None:
    candidates: list[Path] = []
    for env_key in ["FACESWAP_STUDIO_FLUTTER_ROOT", "FLUTTER_ROOT"]:
        flutter_root = os.environ.get(env_key)
        if not flutter_root:
            continue
        flutter_path = Path(flutter_root)
        candidates.append(
            flutter_path
            if flutter_path.name.lower() == "flutter.bat"
            else flutter_path / "bin" / "flutter.bat"
        )
    candidates.append(repo_root / ".tools" / "flutter" / "bin" / "flutter.bat")

    for candidate in candidates:
        if candidate.exists():
            return candidate

    flutter_from_path = shutil.which("flutter")
    if flutter_from_path:
        return Path(flutter_from_path)
    return None


def resolve_runtime_python(repo_root: Path) -> Path:
    candidates = [
        repo_root / ".venv-win" / "Scripts" / "python.exe",
        repo_root / ".bootstrap" / "nuget" / "python" / "tools" / "python.exe",
        Path(sys.executable),
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.name.lower() == "python.exe":
            return candidate
    raise RuntimeError(
        "No usable Python runtime was found. "
        "Run scripts/install_facefusion.ps1 first."
    )


def build_launcher_env(repo_root: Path, python_path: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["FACESWAP_STUDIO_LAUNCHER_PID"] = str(os.getpid())
    env["FACEFUSION_HUGGINGFACE_MIRRORS"] = "https://hf-mirror.com"
    env["FACEFUSION_GITHUB_MIRRORS"] = "https://github.com"
    env["FACEFUSION_DISABLE_PROXY"] = "1"
    env["NO_PROXY"] = "*"
    env["no_proxy"] = "*"

    for proxy_key in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ]:
        env.pop(proxy_key, None)

    path_entries = [
        str(python_path.parent),
        r"C:\Windows\System32",
    ]
    existing_path = env.get("PATH", "")
    env["PATH"] = os.pathsep.join(path_entries + [existing_path])
    return env


def is_bridge_ready() -> bool:
    try:
        with urlopen(BRIDGE_URL, timeout=BRIDGE_HEALTH_TIMEOUT_SECONDS):
            return True
    except (URLError, OSError, TimeoutError):
        return False


def is_bridge_compatible() -> bool:
    if not is_bridge_ready():
        return False
    try:
        with urlopen(MODEL_BOOTSTRAP_URL, timeout=BRIDGE_COMPATIBILITY_TIMEOUT_SECONDS):
            return True
    except (URLError, OSError, TimeoutError):
        return False


def is_bridge_port_open() -> bool:
    try:
        with socket.create_connection((BRIDGE_HOST, BRIDGE_PORT), timeout=0.75):
            return True
    except OSError:
        return False


def wait_for_bridge_ready(timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if is_bridge_compatible():
            return True
        time.sleep(0.25)
    return is_bridge_compatible()


def terminate_bridge_listener(studio_root: Path) -> None:
    try:
        import psutil
    except Exception as error:
        write_launcher_log(studio_root, f"psutil unavailable for stale Bridge cleanup: {error}")
        return

    def is_bridge_process(process: object) -> bool:
        try:
            command_line = " ".join(process.cmdline()).lower()
        except psutil.Error:
            return False
        return "uvicorn" in command_line and "app_server:app" in command_line

    def terminate_bridge_process(process: object) -> None:
        try:
            parent = process.parent()
            if parent and is_bridge_process(parent):
                process = parent
        except psutil.Error:
            pass

        try:
            children = process.children(recursive=True)
            for child in children:
                child.terminate()
            _, alive_children = psutil.wait_procs(children, timeout=3)
            for child in alive_children:
                child.kill()

            process.terminate()
            process.wait(timeout=5)
        except psutil.TimeoutExpired:
            process.kill()
        except psutil.Error as error:
            write_launcher_log(studio_root, f"Stale Bridge cleanup failed: {error}")

    for connection in psutil.net_connections(kind="inet"):
        local_address = connection.laddr
        if not local_address or local_address.port != BRIDGE_PORT or not connection.pid:
            continue
        try:
            process = psutil.Process(connection.pid)
        except psutil.Error as error:
            write_launcher_log(studio_root, f"Could not inspect Bridge listener: {error}")
            continue

        if not is_bridge_process(process):
            write_launcher_log(
                studio_root,
                f"Port {BRIDGE_PORT} is occupied by a non-Bridge process; leaving it untouched.",
            )
            continue

        write_launcher_log(
            studio_root,
            f"Stopping stale Bridge process {process.pid} on port {BRIDGE_PORT}.",
        )
        terminate_bridge_process(process)

    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if not is_bridge_port_open():
            return
        time.sleep(0.25)


def cleanup_stale_runtime_processes(repo_root: Path, studio_root: Path) -> None:
    try:
        import psutil
    except Exception as error:
        write_launcher_log(studio_root, f"psutil unavailable for stale runtime cleanup: {error}")
        return

    def resolve_marker(path: Path) -> str:
        try:
            return str(path.resolve()).casefold()
        except OSError:
            return str(path).casefold()

    runtime_roots = {
        marker
        for marker in [resolve_marker(repo_root), resolve_marker(studio_root)]
        if marker
    }

    protected_pids: set[int] = {os.getpid()}
    try:
        current_process = psutil.Process(os.getpid())
        for parent in current_process.parents():
            protected_pids.add(parent.pid)
    except psutil.Error:
        pass

    def process_text(process: object) -> tuple[str, str]:
        try:
            info = process.as_dict(attrs=["name", "exe", "cmdline"])
        except psutil.Error:
            return "", ""

        name = str(info.get("name") or "").casefold()
        exe = str(info.get("exe") or "")
        cmdline = " ".join(str(part) for part in (info.get("cmdline") or []))
        return name, f"{exe} {cmdline}".casefold()

    def is_project_process(name: str, text: str) -> bool:
        if not any(root in text for root in runtime_roots):
            return False
        if name in STALE_RUNTIME_EXECUTABLE_NAMES:
            return True
        return any(marker in text for marker in STALE_RUNTIME_COMMAND_MARKERS)

    def terminate_process(process: object) -> bool:
        try:
            children = [
                child
                for child in process.children(recursive=True)
                if child.pid not in protected_pids
            ]
        except psutil.Error:
            children = []

        for child in children:
            try:
                child.terminate()
            except psutil.Error:
                pass
        _, alive_children = psutil.wait_procs(children, timeout=3)
        for child in alive_children:
            try:
                child.kill()
            except psutil.Error:
                pass

        try:
            process.terminate()
            process.wait(timeout=5)
            return True
        except psutil.TimeoutExpired:
            try:
                process.kill()
                return True
            except psutil.Error:
                return False
        except psutil.Error:
            return False

    stopped_processes: list[str] = []
    for process in psutil.process_iter(["pid", "name", "exe", "cmdline"]):
        if process.pid in protected_pids:
            continue

        name, text = process_text(process)
        if not is_project_process(name, text):
            continue

        label = f"{name or 'process'}:{process.pid}"
        write_launcher_log(studio_root, f"Stopping stale runtime process {label}.")
        if terminate_process(process):
            stopped_processes.append(label)

    if stopped_processes:
        write_launcher_log(
            studio_root,
            f"Stopped stale runtime processes: {', '.join(stopped_processes)}.",
        )


def get_facefusion_status() -> dict[str, object] | None:
    try:
        with urlopen(FACEFUSION_STATUS_URL, timeout=1.5) as response:
            return json.loads(response.read().decode("utf-8"))
    except (URLError, OSError, TimeoutError, json.JSONDecodeError):
        return None


def get_model_bootstrap_status() -> dict[str, object] | None:
    try:
        with urlopen(MODEL_BOOTSTRAP_URL, timeout=BRIDGE_COMPATIBILITY_TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode("utf-8"))
    except (URLError, OSError, TimeoutError, json.JSONDecodeError):
        return None


def should_start_facefusion_on_launch(studio_root: Path) -> bool:
    status = get_model_bootstrap_status()
    if not status:
        write_launcher_log(
            studio_root,
            "Model bootstrap status unavailable; starting FaceFusion for compatibility.",
        )
        return True

    if status.get("ready") is True:
        return True

    missing_count = status.get("missing_count")
    state = status.get("state", "unknown")
    write_launcher_log(
        studio_root,
        f"Core models are not ready ({state}, missing: {missing_count}); frontend will prompt download.",
    )
    return False


def start_facefusion_service(studio_root: Path) -> None:
    status = get_facefusion_status()
    if status and status.get("state") in {"starting", "ready"}:
        write_launcher_log(
            studio_root,
            f"FaceFusion already active: {status.get('state')}",
        )
        return

    request = Request(FACEFUSION_START_URL, method="POST")
    with urlopen(request, timeout=5) as response:
        payload = json.loads(response.read().decode("utf-8"))
    write_launcher_log(
        studio_root,
        f"FaceFusion start requested: {payload.get('state', 'unknown')}",
    )

    for _ in range(80):
        status = get_facefusion_status()
        if status and status.get("state") in {"starting", "ready"}:
            write_launcher_log(
                studio_root,
                f"FaceFusion service state: {status.get('state')}",
            )
            return
        time.sleep(0.25)

    raise RuntimeError("FaceFusion service failed to enter starting/ready state.")


def start_facefusion_service_delayed(studio_root: Path, delay_seconds: float) -> threading.Event:
    cancel_event = threading.Event()

    def worker() -> None:
        write_launcher_log(
            studio_root,
            f"FaceFusion start deferred for {delay_seconds:.1f}s to let the frontend initialize.",
        )
        if cancel_event.wait(delay_seconds):
            write_launcher_log(studio_root, "Deferred FaceFusion start cancelled.")
            return
        try:
            start_facefusion_service(studio_root)
        except Exception as error:
            write_launcher_log(studio_root, f"Deferred FaceFusion start failed: {error}")

    threading.Thread(target=worker, name="FaceFusionDeferredStart", daemon=True).start()
    return cancel_event


def stop_facefusion_service(studio_root: Path) -> None:
    status = get_facefusion_status()
    if not status or status.get("state") in {"stopped", "bridge_offline"}:
        return

    try:
        request = Request(FACEFUSION_STOP_URL, method="POST")
        with urlopen(request, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
        write_launcher_log(
            studio_root,
            f"FaceFusion stop requested: {payload.get('state', 'unknown')}",
        )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError) as error:
        write_launcher_log(studio_root, f"FaceFusion stop request failed: {error}")


def start_bridge_if_needed(
    repo_root: Path,
    studio_root: Path,
) -> tuple[subprocess.Popen[str] | None, object | None]:
    if is_bridge_compatible():
        return None, None
    if is_bridge_ready():
        write_launcher_log(
            studio_root,
            "Bridge health is ready but required APIs are missing; restarting stale Bridge.",
        )
        terminate_bridge_listener(studio_root)
    if is_bridge_port_open():
        write_launcher_log(
            studio_root,
            f"Bridge port {BRIDGE_PORT} is occupied; waiting for existing Bridge.",
        )
        if wait_for_bridge_ready(BRIDGE_OCCUPIED_PORT_WAIT_SECONDS):
            write_launcher_log(studio_root, "Existing Bridge became ready.")
            return None, None

    bridge_dir = studio_root / "bridge"
    runtime_dir = studio_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    log_path = runtime_dir / "bridge.log"
    log_handle = open(log_path, "a", encoding="utf-8")
    python_path = resolve_runtime_python(repo_root)
    env = build_launcher_env(repo_root, python_path)
    env["FACESWAP_STUDIO_BRIDGE_HOST"] = BRIDGE_LISTEN_HOST

    command = [
        str(python_path),
        "-m",
        "uvicorn",
        "app_server:app",
        "--host",
        BRIDGE_LISTEN_HOST,
        "--port",
        str(BRIDGE_PORT),
    ]
    process = subprocess.Popen(
        command,
        cwd=bridge_dir,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        env=env,
    )

    for _ in range(60):
        if is_bridge_compatible():
            return process, log_handle
        if process.poll() is not None:
            if wait_for_bridge_ready(3.0):
                log_handle.close()
                write_launcher_log(studio_root, "Existing Bridge became ready after bind race.")
                return None, None
            break
        time.sleep(0.25)

    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
    log_handle.close()
    raise RuntimeError(f"Bridge failed to start. Check log: {log_path}")


def write_launcher_log(studio_root: Path, message: str) -> None:
    runtime_dir = studio_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    log_path = runtime_dir / "launcher.log"
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as log_handle:
        log_handle.write(f"[{timestamp}] {message}\n")


def monitor_update_health(repo_root: Path, stop: threading.Event) -> None:
    from updater.transaction import read_json, write_json
    health_file = os.environ.get('FACESWAP_STUDIO_UPDATE_HEALTH_FILE')
    session = os.environ.get('FACESWAP_STUDIO_UPDATE_SESSION')
    if not health_file or not session:
        return
    target = Path(health_file).resolve()
    if target != (Path(session) / 'healthy.json').resolve() or not target.is_relative_to(
            (repo_root / 'faceswap studio/data/cache/updates').resolve()):
        return
    expected_pid = int(os.environ.get('FACESWAP_STUDIO_WRAPPER_PID', os.getpid()))
    while not stop.wait(0.5):
        try:
            receipt = read_json(target.with_name('frontend-ready.json'))
            if (receipt.get('pid') != expected_pid or receipt.get('root') != str(repo_root.resolve()) or
                    receipt.get('token') != os.environ.get('FACESWAP_STUDIO_UPDATE_TOKEN')):
                continue
            bootstrap = get_model_bootstrap_status()
            status = get_facefusion_status()
            if not bootstrap or not status:
                continue
            if bootstrap.get('ready') is True and status.get('state') != 'ready':
                target.unlink(missing_ok=True)
                continue
            if bootstrap.get('ready') is not True and bootstrap.get('missing_count', 0) <= 0:
                continue
            receipt['coreState'] = status.get('state')
            receipt['modelsReady'] = bootstrap.get('ready') is True
            receipt['checkedAt'] = time.time()
            write_json(target, receipt)
        except (OSError, ValueError):
            continue


def launch_frontend(command: list[str], command_cwd: Path) -> tuple[int, float]:
    started_at = time.monotonic()
    process = subprocess.Popen(command, cwd=command_cwd, shell=False)

    stop = threading.Event()
    monitor = threading.Thread(target=monitor_update_health, args=(resolve_repo_root(), stop), daemon=True)
    monitor.start()
    try:
        exit_code = process.wait()
    finally:
        stop.set()
        monitor.join(timeout=10)
    return exit_code, time.monotonic() - started_at


def terminate_process_tree(process: subprocess.Popen[str], studio_root: Path) -> None:
    if process.poll() is not None:
        return

    try:
        import psutil

        root = psutil.Process(process.pid)
        children = root.children(recursive=True)
        for child in children:
            try:
                child.terminate()
            except psutil.Error:
                pass

        _, alive_children = psutil.wait_procs(children, timeout=3)
        for child in alive_children:
            try:
                child.kill()
            except psutil.Error:
                pass

        try:
            root.terminate()
            root.wait(timeout=5)
        except psutil.TimeoutExpired:
            root.kill()
        except psutil.Error:
            pass
    except Exception as error:
        write_launcher_log(studio_root, f"psutil process cleanup failed: {error}")
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def main() -> int:
    repo_root = resolve_repo_root()
    studio_root = repo_root / "faceswap studio"
    if os.environ.get("FACESWAP_STUDIO_ISOLATED"):
        global LAUNCHER_MUTEX_NAME
        import hashlib
        LAUNCHER_MUTEX_NAME += "." + hashlib.sha256(str(repo_root).encode()).hexdigest()[:16]
    single_instance_lock, already_running = acquire_single_instance_lock(studio_root)
    if already_running:
        if notify_running_instance():
            write_launcher_log(studio_root, "Duplicate launcher request activated the existing window.")
        else:
            write_launcher_log(studio_root, "Duplicate launcher request ignored while the existing instance is starting.")
        return 0
    if not os.environ.get("FACESWAP_STUDIO_ISOLATED") and notify_running_instance():
        write_launcher_log(
            studio_root,
            "Existing frontend window found without launcher mutex; activated and exiting.",
        )
        release_single_instance_lock(single_instance_lock, studio_root)
        return 0

    from updater.startup import resume_update
    if resume_update(repo_root):
        release_single_instance_lock(single_instance_lock, studio_root)
        return 0

    flutter_project = studio_root / "flutter_app"
    flutter_binary = resolve_flutter_binary(repo_root)
    deployed_binary = studio_root / "runtime" / "windows_app" / "current" / "faceswap_studio.exe"
    built_candidates = [
        deployed_binary,
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Release" / "faceswap_studio.exe",
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Debug" / "faceswap_studio.exe",
    ]
    bridge_process = None
    bridge_log_handle = None
    deferred_facefusion_start_cancel = None
    frontend_exit_code = 1
    frontend_run_seconds = 0.0

    executable = next((candidate for candidate in built_candidates if candidate.exists()), None)
    if executable:
        command = [str(executable), *WINDOWS_FRONTEND_ENGINE_FLAGS]
        command_cwd = executable.parent
        write_launcher_log(studio_root, f"Using packaged studio build: {executable}")
    else:
        if not flutter_binary:
            raise RuntimeError(
                "No packaged Flutter build was found and flutter is not installed. "
                "Run scripts/build_flutter_app.ps1 or install Flutter first."
            )
        command = [str(flutter_binary), "run", "-d", "windows", *WINDOWS_FRONTEND_ENGINE_FLAGS]
        command_cwd = flutter_project
        write_launcher_log(studio_root, f"Using flutter run fallback in: {flutter_project}")

    try:
        from updater.preflight import run_preflight
        preflight = run_preflight(repo_root, resolve_runtime_python(repo_root))
        write_launcher_log(studio_root, f"Core/Bridge/worker preflight passed: {preflight['coreVersion']}.")
        if not os.environ.get("FACESWAP_STUDIO_ISOLATED"):
            cleanup_stale_runtime_processes(repo_root, studio_root)
        bridge_process, bridge_log_handle = start_bridge_if_needed(repo_root, studio_root)
        if should_start_facefusion_on_launch(studio_root):
            deferred_facefusion_start_cancel = start_facefusion_service_delayed(
                studio_root,
                FACEFUSION_DEFERRED_START_SECONDS,
            )
        write_launcher_log(studio_root, f"Launching command: {' '.join(command)}")
        frontend_exit_code, frontend_run_seconds = launch_frontend(command, command_cwd)
        return frontend_exit_code
    finally:
        if deferred_facefusion_start_cancel:
            deferred_facefusion_start_cancel.set()
        write_launcher_log(
            studio_root,
            f"Frontend exited after {frontend_run_seconds:.1f}s; exit code {frontend_exit_code}.",
        )
        if frontend_run_seconds < FRONTEND_MIN_MANAGED_SESSION_SECONDS and frontend_exit_code != 0:
            write_launcher_log(
                studio_root,
                "Frontend exited during startup; cleaning up managed services after failure.",
            )
        else:
            write_launcher_log(studio_root, "Cleaning up managed services.")
        stop_facefusion_service(studio_root)
        if bridge_process:
            terminate_process_tree(bridge_process, studio_root)
        if bridge_log_handle:
            bridge_log_handle.close()
        release_single_instance_lock(single_instance_lock, studio_root)


if __name__ == "__main__":
    raise SystemExit(main())
