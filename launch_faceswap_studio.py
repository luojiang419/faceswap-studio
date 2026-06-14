import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 50741
BRIDGE_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/health"
MODEL_BOOTSTRAP_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/models/bootstrap"
FACEFUSION_STATUS_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/status"
FACEFUSION_START_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/start"
FACEFUSION_STOP_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}/facefusion/stop"
BRIDGE_HEALTH_TIMEOUT_SECONDS = 3.0
BRIDGE_COMPATIBILITY_TIMEOUT_SECONDS = 5.0
BRIDGE_OCCUPIED_PORT_WAIT_SECONDS = 20.0
FRONTEND_MIN_MANAGED_SESSION_SECONDS = 30.0


def resolve_repo_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def resolve_flutter_binary(repo_root: Path) -> Path | None:
    flutter_root = Path(os.environ["FLUTTER_ROOT"]) if "FLUTTER_ROOT" in os.environ else None
    candidates = [
        flutter_root / "bin" / "flutter.bat" if flutter_root else None,
        repo_root / ".tools" / "flutter" / "bin" / "flutter.bat",
        Path(r"D:\flutter\bin\flutter.bat"),
    ]

    for candidate in candidates:
        if candidate and candidate.exists():
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

    command = [
        str(python_path),
        "-m",
        "uvicorn",
        "app_server:app",
        "--host",
        BRIDGE_HOST,
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


def launch_frontend(command: list[str], command_cwd: Path) -> tuple[int, float]:
    started_at = time.monotonic()
    process = subprocess.Popen(command, cwd=command_cwd, shell=False)

    exit_code = process.wait()
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
    frontend_exit_code = 1
    frontend_run_seconds = 0.0

    executable = next((candidate for candidate in built_candidates if candidate.exists()), None)
    if executable:
        command = [str(executable)]
        command_cwd = executable.parent
        write_launcher_log(studio_root, f"Using packaged studio build: {executable}")
    else:
        if not flutter_binary:
            raise RuntimeError(
                "No packaged Flutter build was found and flutter is not installed. "
                "Run scripts/build_flutter_app.ps1 or install Flutter first."
            )
        command = [str(flutter_binary), "run", "-d", "windows"]
        command_cwd = flutter_project
        write_launcher_log(studio_root, f"Using flutter run fallback in: {flutter_project}")

    try:
        bridge_process, bridge_log_handle = start_bridge_if_needed(repo_root, studio_root)
        if should_start_facefusion_on_launch(studio_root):
            start_facefusion_service(studio_root)
        write_launcher_log(studio_root, f"Launching command: {' '.join(command)}")
        frontend_exit_code, frontend_run_seconds = launch_frontend(command, command_cwd)
        return frontend_exit_code
    finally:
        write_launcher_log(
            studio_root,
            f"Frontend exited after {frontend_run_seconds:.1f}s; exit code {frontend_exit_code}.",
        )
        if frontend_run_seconds >= FRONTEND_MIN_MANAGED_SESSION_SECONDS:
            write_launcher_log(studio_root, "Cleaning up managed services.")
            stop_facefusion_service(studio_root)
            if bridge_process:
                terminate_process_tree(bridge_process, studio_root)
            if bridge_log_handle:
                bridge_log_handle.close()
        else:
            write_launcher_log(
                studio_root,
                "Frontend exited during startup; keeping Bridge and FaceFusion running.",
            )


if __name__ == "__main__":
    raise SystemExit(main())
