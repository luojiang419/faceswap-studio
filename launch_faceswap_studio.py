from pathlib import Path
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import urlopen


BRIDGE_URL = "http://127.0.0.1:50741/health"


def is_bridge_ready() -> bool:
    try:
        with urlopen(BRIDGE_URL, timeout=0.75):
            return True
    except (URLError, OSError, TimeoutError):
        return False


def start_bridge_if_needed(studio_root: Path) -> tuple[subprocess.Popen[str] | None, object | None]:
    if is_bridge_ready():
        return None, None

    bridge_dir = studio_root / "bridge"
    runtime_dir = studio_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    log_path = runtime_dir / "bridge.log"
    log_handle = open(log_path, "a", encoding="utf-8")

    command = [
        sys.executable,
        "-m",
        "uvicorn",
        "app_server:app",
        "--host",
        "127.0.0.1",
        "--port",
        "50741",
    ]
    process = subprocess.Popen(
        command,
        cwd=bridge_dir,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )

    for _ in range(60):
        if is_bridge_ready():
            return process, log_handle
        if process.poll() is not None:
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


def launch_frontend(command: list[str], command_cwd: Path) -> int:
    process = subprocess.Popen(command, cwd=command_cwd, shell=False)

    # Treat the launcher as a bootstrapper: if the frontend stays alive for a
    # short grace period, consider startup successful and let it keep running
    # independently from this script.
    for _ in range(30):
        if process.poll() is not None:
            return process.returncode or 0
        time.sleep(0.1)
    return 0


def main() -> int:
    repo_root = Path(__file__).resolve().parent
    studio_root = repo_root / "faceswap studio"
    flutter_project = studio_root / "flutter_app"
    flutter_binary = Path(r"D:\APPdata\flutter\bin\flutter.bat")
    deployed_binary = studio_root / "runtime" / "windows_app" / "current" / "faceswap_studio.exe"
    built_candidates = [
        deployed_binary,
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Release" / "faceswap_studio.exe",
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Debug" / "faceswap_studio.exe",
    ]
    bridge_process = None
    bridge_log_handle = None

    executable = next((candidate for candidate in built_candidates if candidate.exists()), None)
    if executable:
        command = [str(executable)]
        command_cwd = executable.parent
        write_launcher_log(studio_root, f"Using packaged studio build: {executable}")
    else:
        command = [str(flutter_binary), "run", "-d", "windows"]
        if not flutter_binary.exists():
            command = ["flutter", "run", "-d", "windows"]
        command_cwd = flutter_project
        write_launcher_log(studio_root, f"Using flutter run fallback in: {flutter_project}")

    try:
        bridge_process, bridge_log_handle = start_bridge_if_needed(studio_root)
        write_launcher_log(studio_root, f"Launching command: {' '.join(command)}")
        return launch_frontend(command, command_cwd)
    finally:
        if bridge_log_handle:
            bridge_log_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
