import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


BRIDGE_URL = "http://127.0.0.1:50741/health"
FACEFUSION_STATUS_URL = "http://127.0.0.1:50741/facefusion/status"
FACEFUSION_START_URL = "http://127.0.0.1:50741/facefusion/start"


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
        with urlopen(BRIDGE_URL, timeout=0.75):
            return True
    except (URLError, OSError, TimeoutError):
        return False


def get_facefusion_status() -> dict[str, object] | None:
    try:
        with urlopen(FACEFUSION_STATUS_URL, timeout=1.5) as response:
            return json.loads(response.read().decode("utf-8"))
    except (URLError, OSError, TimeoutError, json.JSONDecodeError):
        return None


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


def start_bridge_if_needed(
    repo_root: Path,
    studio_root: Path,
) -> tuple[subprocess.Popen[str] | None, object | None]:
    if is_bridge_ready():
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
        env=env,
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
        start_facefusion_service(studio_root)
        write_launcher_log(studio_root, f"Launching command: {' '.join(command)}")
        return launch_frontend(command, command_cwd)
    finally:
        if bridge_log_handle:
            bridge_log_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
