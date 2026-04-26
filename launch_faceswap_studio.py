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


def main() -> int:
    repo_root = Path(__file__).resolve().parent
    studio_root = repo_root / "faceswap studio"
    flutter_project = studio_root / "flutter_app"
    flutter_binary = Path(r"D:\APPdata\flutter\bin\flutter.bat")
    built_candidates = [
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Release" / "faceswap_studio.exe",
        studio_root / "flutter_app" / "build" / "windows" / "x64" / "runner" / "Debug" / "faceswap_studio.exe",
    ]
    bridge_process = None
    bridge_log_handle = None

    executable = next((candidate for candidate in built_candidates if candidate.exists()), None)
    if executable:
        command = [str(executable)]
        command_cwd = executable.parent
    else:
        command = [str(flutter_binary), "run", "-d", "windows"]
        if not flutter_binary.exists():
            command = ["flutter", "run", "-d", "windows"]
        command_cwd = flutter_project

    try:
        bridge_process, bridge_log_handle = start_bridge_if_needed(studio_root)
        return subprocess.call(command, cwd=command_cwd, shell=False)
    finally:
        if bridge_process and bridge_process.poll() is None:
            bridge_process.terminate()
            try:
                bridge_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge_process.kill()
        if bridge_log_handle:
            bridge_log_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
