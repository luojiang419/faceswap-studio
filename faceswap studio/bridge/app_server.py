from __future__ import annotations

from collections import deque
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen
import webbrowser

from fastapi import FastAPI, Query
import psutil


BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 50741
FACEFUSION_UI_HOST = "127.0.0.1"
FACEFUSION_UI_PORT = 7860
LOG_LIMIT = 2000
JOB_STATUSES = ["drafted", "queued", "completed", "failed"]
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".mpeg", ".m4v"}


class FaceFusionRuntime:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._process: subprocess.Popen[str] | None = None
        self._state = "stopped"
        self._status_message = "FaceFusion is not running."
        self._started_at: str | None = None
        self._sequence = 0
        self._logs: deque[dict[str, Any]] = deque(maxlen=LOG_LIMIT)
        self._manual_stop_requested = False

        self._queue_lock = threading.RLock()
        self._queue_runner_thread: threading.Thread | None = None
        self._queue_runner_active = False
        self._queue_current_job_id: str | None = None
        self._queue_total_jobs = 0
        self._queue_completed_jobs = 0
        self._queue_last_error: str | None = None

        psutil.cpu_percent(interval=None)
        self._prepare_paths()
        self._append_log("[bridge] FaceSwap Studio Bridge initialized.")

    @property
    def webui_url(self) -> str:
        return f"http://{self._settings['facefusion_host']}:{self._settings['facefusion_port']}"

    @property
    def repo_root(self) -> Path:
        return self._repo_root

    def _prepare_paths(self) -> None:
        studio_root = Path(__file__).resolve().parent.parent
        self._studio_root = studio_root
        self._repo_root = studio_root.parent
        self._jobs_dir = studio_root / "data" / "jobs"
        self._temp_dir = studio_root / "data" / "cache" / "temp"
        self._settings_path = studio_root / "config" / "settings.json"
        self._favorites_path = studio_root / "data" / "favorites" / "favorites.json"
        self._runtime_dir = studio_root / "runtime"

        for directory in [
            self._jobs_dir,
            self._temp_dir,
            self._runtime_dir,
            self._settings_path.parent,
            self._favorites_path.parent,
        ]:
            directory.mkdir(parents=True, exist_ok=True)

        if not self._favorites_path.exists():
            self._favorites_path.write_text("[]", encoding="utf-8")

        self._settings = self._load_settings()
        self._apply_output_root(self._settings["default_output_dir"])

    def _load_settings(self) -> dict[str, Any]:
        defaults = {
            "theme": "dark",
            "facefusion_host": FACEFUSION_UI_HOST,
            "facefusion_port": FACEFUSION_UI_PORT,
            "default_output_dir": str(self._studio_root / "data" / "output"),
        }
        if not self._settings_path.exists():
            self._settings_path.write_text(json.dumps(defaults, indent=2, ensure_ascii=False), encoding="utf-8")
            return defaults

        try:
            payload = json.loads(self._settings_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}

        merged = {
            "theme": str(payload.get("theme") or defaults["theme"]),
            "facefusion_host": str(payload.get("facefusion_host") or defaults["facefusion_host"]),
            "facefusion_port": int(payload.get("facefusion_port") or defaults["facefusion_port"]),
            "default_output_dir": str(payload.get("default_output_dir") or defaults["default_output_dir"]),
        }
        self._settings_path.write_text(json.dumps(merged, indent=2, ensure_ascii=False), encoding="utf-8")
        return merged

    def _save_settings(self) -> None:
        self._settings_path.write_text(
            json.dumps(self._settings, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _apply_output_root(self, output_root: str) -> None:
        self._output_dir = Path(output_root)
        for directory in [
            self._output_dir,
            self._output_dir / "img",
            self._output_dir / "video",
        ]:
            directory.mkdir(parents=True, exist_ok=True)

    def _append_log(self, message: str) -> None:
        with self._lock:
            self._sequence += 1
            self._logs.append(
                {
                    "id": self._sequence,
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "message": message,
                }
            )

    def _build_command(self) -> list[str]:
        script_path = self.repo_root.parent / "scripts" / "run_facefusion.ps1"
        return [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
            "--ui-layouts",
            "studio",
            "--ui-workflow",
            "instant_runner",
            "--jobs-path",
            str(self._jobs_dir),
            "--temp-path",
            str(self._temp_dir),
            "--output-path",
            str(self._output_dir),
        ]

    def _build_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["FACEFUSION_UI_HOST"] = str(self._settings["facefusion_host"])
        env["FACEFUSION_UI_PORT"] = str(self._settings["facefusion_port"])
        return env

    def _is_webui_ready(self) -> bool:
        try:
            with urlopen(self.webui_url, timeout=0.75):
                return True
        except (URLError, OSError, TimeoutError):
            return False

    def _stream_output(self, process: subprocess.Popen[str]) -> None:
        assert process.stdout is not None
        for raw_line in process.stdout:
            line = raw_line.rstrip()
            if line:
                self._append_log(line)

    def _watch_process(self, process: subprocess.Popen[str]) -> None:
        exit_code = process.wait()
        with self._lock:
            is_current = self._process is process
            manual_stop = self._manual_stop_requested
            if is_current:
                self._process = None
                self._manual_stop_requested = False
                self._state = "stopped"
                self._status_message = "FaceFusion stopped."
        if manual_stop:
            self._append_log(f"[bridge] FaceFusion stopped by request, exit code {exit_code}.")
        else:
            self._append_log(f"[bridge] FaceFusion exited unexpectedly, exit code {exit_code}.")

    def _terminate_process_tree(self, pid: int) -> None:
        try:
            root = psutil.Process(pid)
        except psutil.Error:
            return

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
            try:
                root.kill()
            except psutil.Error:
                pass
        except psutil.Error:
            pass

    def start(self) -> dict[str, Any]:
        with self._lock:
            if self._process and self._process.poll() is None:
                self._refresh_state_locked()
                return self.status()

            command = self._build_command()
            self._append_log(f"[bridge] Starting FaceFusion with command: {' '.join(command)}")
            self._manual_stop_requested = False
            self._started_at = datetime.now().isoformat(timespec="seconds")
            process = subprocess.Popen(
                command,
                cwd=self.repo_root,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                env=self._build_env(),
            )
            self._process = process
            self._state = "starting"
            self._status_message = "FaceFusion is starting."

        threading.Thread(target=self._stream_output, args=(process,), daemon=True).start()
        threading.Thread(target=self._watch_process, args=(process,), daemon=True).start()
        time.sleep(0.2)
        return self.status()

    def stop(self) -> dict[str, Any]:
        process: subprocess.Popen[str] | None
        with self._lock:
            process = self._process
            if not process or process.poll() is not None:
                self._process = None
                self._state = "stopped"
                self._status_message = "FaceFusion is not running."
                return self.status()
            self._manual_stop_requested = True
            self._state = "stopping"
            self._status_message = "Stopping FaceFusion."
            self._append_log("[bridge] Stop requested for FaceFusion.")

        self._terminate_process_tree(process.pid)
        time.sleep(0.2)
        return self.status()

    def open_browser(self) -> dict[str, Any]:
        self._refresh_state()
        if self._is_webui_ready():
            webbrowser.open(self.webui_url)
            self._append_log(f"[bridge] Opened browser at {self.webui_url}")
            return {"ok": True, "url": self.webui_url}
        return {"ok": False, "url": self.webui_url, "message": "FaceFusion WebUI is not ready."}

    def _refresh_state_locked(self) -> None:
        if self._process and self._process.poll() is None:
            if self._is_webui_ready():
                self._state = "ready"
                self._status_message = "FaceFusion WebUI is ready."
            elif self._state != "stopping":
                self._state = "starting"
                self._status_message = "FaceFusion is starting."
        elif self._state != "stopped":
            self._state = "stopped"
            self._status_message = "FaceFusion is not running."

    def _refresh_state(self) -> None:
        with self._lock:
            self._refresh_state_locked()

    def status(self) -> dict[str, Any]:
        with self._lock:
            self._refresh_state_locked()
            pid = self._process.pid if self._process and self._process.poll() is None else None
            return {
                "state": self._state,
                "is_running": self._state in {"starting", "ready", "stopping"},
                "is_ready": self._state == "ready",
                "status_message": self._status_message,
                "pid": pid,
                "webui_url": self.webui_url,
                "started_at": self._started_at,
            }

    def metrics(self) -> dict[str, Any]:
        self._refresh_state()
        memory = psutil.virtual_memory()
        process_metrics = self._get_process_metrics()
        gpu_metrics = self._get_gpu_metrics()
        return {
            "cpu_percent": psutil.cpu_percent(interval=None),
            "memory_percent": memory.percent,
            "memory_used_gb": round(memory.used / (1024**3), 2),
            "memory_total_gb": round(memory.total / (1024**3), 2),
            "gpu_percent": gpu_metrics["gpu_percent"],
            "gpu_memory_percent": gpu_metrics["gpu_memory_percent"],
            "gpu_memory_used_mb": gpu_metrics["gpu_memory_used_mb"],
            "gpu_memory_total_mb": gpu_metrics["gpu_memory_total_mb"],
            "facefusion_process": process_metrics,
            "state": self._state,
        }

    def _get_process_metrics(self) -> dict[str, Any] | None:
        with self._lock:
            process = self._process
            if not process or process.poll() is not None:
                return None
            pid = process.pid

        try:
            current = psutil.Process(pid)
            return {
                "pid": pid,
                "cpu_percent": current.cpu_percent(interval=None),
                "memory_mb": round(current.memory_info().rss / (1024**2), 2),
            }
        except psutil.Error:
            return None

    def _get_gpu_metrics(self) -> dict[str, Any]:
        command = [
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=1.5,
                check=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            return {
                "gpu_percent": None,
                "gpu_memory_percent": None,
                "gpu_memory_used_mb": None,
                "gpu_memory_total_mb": None,
            }

        first_line = next((line.strip() for line in result.stdout.splitlines() if line.strip()), "")
        if not first_line:
            return {
                "gpu_percent": None,
                "gpu_memory_percent": None,
                "gpu_memory_used_mb": None,
                "gpu_memory_total_mb": None,
            }

        try:
            gpu_percent_raw, used_raw, total_raw = [segment.strip() for segment in first_line.split(",")]
            used = int(float(used_raw))
            total = int(float(total_raw))
            gpu_percent = float(gpu_percent_raw)
            gpu_memory_percent = round((used / total) * 100.0, 2) if total else 0.0
        except (TypeError, ValueError, ZeroDivisionError):
            return {
                "gpu_percent": None,
                "gpu_memory_percent": None,
                "gpu_memory_used_mb": None,
                "gpu_memory_total_mb": None,
            }

        return {
            "gpu_percent": gpu_percent,
            "gpu_memory_percent": gpu_memory_percent,
            "gpu_memory_used_mb": used,
            "gpu_memory_total_mb": total,
        }

    def get_logs(self, after: int, limit: int) -> dict[str, Any]:
        with self._lock:
            items = [item for item in self._logs if item["id"] > after]
            if limit > 0:
                items = items[:limit]
            latest_id = self._logs[-1]["id"] if self._logs else 0
        return {"entries": items, "latest_id": latest_id}

    def list_queue_tasks(self) -> dict[str, Any]:
        tasks = []
        for job_status in JOB_STATUSES:
            status_dir = self._jobs_dir / job_status
            if not status_dir.exists():
                continue
            for job_path in sorted(status_dir.glob("*.json"), key=lambda path: path.stat().st_mtime):
                try:
                    payload = json.loads(job_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                steps = payload.get("steps") or []
                first_step = steps[0] if steps else {}
                first_args = first_step.get("args") or {}
                source_paths = first_args.get("source_paths") or []
                target_path = first_args.get("target_path")
                output_path = first_args.get("output_path")
                completed_steps = sum(1 for step in steps if step.get("status") == "completed")
                started_steps = sum(1 for step in steps if step.get("status") == "started")

                tasks.append(
                    {
                        "job_id": job_path.stem,
                        "status": job_status,
                        "created_at": payload.get("date_created"),
                        "updated_at": payload.get("date_updated"),
                        "step_total": len(steps),
                        "completed_steps": completed_steps,
                        "started_steps": started_steps,
                        "source_paths": source_paths,
                        "source_thumbnail": self._resolve_thumbnail(source_paths[0] if source_paths else None),
                        "target_path": target_path,
                        "target_thumbnail": self._resolve_thumbnail(target_path),
                        "output_path": output_path,
                        "is_active": self._queue_current_job_id == job_path.stem,
                    }
                )

        return {
            "tasks": tasks,
            "runner": {
                "active": self._queue_runner_active,
                "current_job_id": self._queue_current_job_id,
                "total_jobs": self._queue_total_jobs,
                "completed_jobs": self._queue_completed_jobs,
                "last_error": self._queue_last_error,
            },
        }

    def run_queue(self) -> dict[str, Any]:
        with self._queue_lock:
            if self._queue_runner_active:
                return self.list_queue_tasks()
            queued_job_ids = [task["job_id"] for task in self.list_queue_tasks()["tasks"] if task["status"] == "queued"]
            if not queued_job_ids:
                return self.list_queue_tasks()

            self._queue_runner_active = True
            self._queue_total_jobs = len(queued_job_ids)
            self._queue_completed_jobs = 0
            self._queue_last_error = None
            self._queue_runner_thread = threading.Thread(target=self._run_queue_worker, daemon=True)
            self._queue_runner_thread.start()
            self._append_log(f"[bridge] Queue runner started with {len(queued_job_ids)} queued jobs.")
        return self.list_queue_tasks()

    def delete_queue_task(self, job_id: str) -> dict[str, Any]:
        for job_status in JOB_STATUSES:
            job_path = self._jobs_dir / job_status / f"{job_id}.json"
            if job_path.exists():
                job_path.unlink()
                self._append_log(f"[bridge] Deleted queue task: {job_id}")
                break
        return self.list_queue_tasks()

    def _run_queue_worker(self) -> None:
        try:
            while True:
                queued_job_ids = [task["job_id"] for task in self.list_queue_tasks()["tasks"] if task["status"] == "queued"]
                if not queued_job_ids:
                    break
                job_id = queued_job_ids[0]
                with self._queue_lock:
                    self._queue_current_job_id = job_id
                self._append_log(f"[bridge] Running queued job: {job_id}")
                result = self._run_single_job(job_id)
                if result != 0:
                    self._queue_last_error = f"Job failed: {job_id} (exit code {result})"
                    self._append_log(f"[bridge] Queued job failed: {job_id} (exit code {result})")
                else:
                    self._append_log(f"[bridge] Queued job completed: {job_id}")
                with self._queue_lock:
                    self._queue_completed_jobs += 1
                    self._queue_current_job_id = None
        finally:
            with self._queue_lock:
                self._queue_runner_active = False
                self._queue_current_job_id = None
            self._append_log("[bridge] Queue runner finished.")

    def _run_single_job(self, job_id: str) -> int:
        command = [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.repo_root.parent / "scripts" / "facefusion.ps1"),
            "job-run",
            job_id,
            "--jobs-path",
            str(self._jobs_dir),
            "--temp-path",
            str(self._temp_dir),
        ]
        process = subprocess.Popen(
            command,
            cwd=self.repo_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            env=self._build_env(),
        )
        assert process.stdout is not None
        for raw_line in process.stdout:
            line = raw_line.rstrip()
            if line:
                self._append_log(line)
        return process.wait()

    def _resolve_thumbnail(self, file_path: str | None) -> str | None:
        if not file_path:
            return None
        candidate = Path(file_path)
        if candidate.exists() and candidate.suffix.lower() in IMAGE_EXTENSIONS:
            return str(candidate)
        return None

    def get_settings(self) -> dict[str, Any]:
        return dict(self._settings)

    def update_settings(self, payload: dict[str, Any]) -> dict[str, Any]:
        if "theme" in payload and payload["theme"] in {"dark", "light"}:
            self._settings["theme"] = payload["theme"]
        if "default_output_dir" in payload and payload["default_output_dir"]:
            self._settings["default_output_dir"] = str(payload["default_output_dir"])
            self._apply_output_root(self._settings["default_output_dir"])
        self._save_settings()
        self._append_log("[bridge] Settings updated.")
        return self.get_settings()

    def list_works(self, favorite_only: bool = False) -> dict[str, Any]:
        favorite_paths = self._read_favorites()
        items = []
        for file_path in self._scan_output_files():
            path_str = str(file_path)
            is_favorite = path_str in favorite_paths
            if favorite_only and not is_favorite:
                continue
            items.append(
                {
                    "id": self._work_id_for_path(file_path),
                    "path": path_str,
                    "file_name": file_path.name,
                    "media_type": "image" if file_path.suffix.lower() in IMAGE_EXTENSIONS else "video",
                    "modified_at": datetime.fromtimestamp(file_path.stat().st_mtime).isoformat(timespec="seconds"),
                    "size_bytes": file_path.stat().st_size,
                    "is_favorite": is_favorite,
                }
            )
        items.sort(key=lambda item: item["modified_at"], reverse=True)
        return {
            "items": items,
            "output_root": str(self._output_dir),
        }

    def favorite_work(self, work_id: str, favorite: bool) -> dict[str, Any]:
        target = self._resolve_work_path(work_id)
        if target is None:
            return self.list_works()
        favorites = self._read_favorites()
        target_path = str(target)
        if favorite:
            favorites.add(target_path)
            self._append_log(f"[bridge] Favorited work: {target_path}")
        else:
            favorites.discard(target_path)
            self._append_log(f"[bridge] Unfavorited work: {target_path}")
        self._write_favorites(favorites)
        return self.list_works()

    def delete_work(self, work_id: str) -> dict[str, Any]:
        target = self._resolve_work_path(work_id)
        if target and target.exists():
            target.unlink()
            favorites = self._read_favorites()
            favorites.discard(str(target))
            self._write_favorites(favorites)
            self._append_log(f"[bridge] Deleted work: {target}")
        return self.list_works()

    def _scan_output_files(self) -> list[Path]:
        files = []
        if not self._output_dir.exists():
            return files
        for path in self._output_dir.rglob("*"):
            if not path.is_file():
                continue
            extension = path.suffix.lower()
            if extension in IMAGE_EXTENSIONS or extension in VIDEO_EXTENSIONS:
                files.append(path)
        return files

    def _work_id_for_path(self, file_path: Path) -> str:
        return hashlib.sha1(str(file_path).encode("utf-8")).hexdigest()

    def _resolve_work_path(self, work_id: str) -> Path | None:
        for file_path in self._scan_output_files():
            if self._work_id_for_path(file_path) == work_id:
                return file_path
        return None

    def _read_favorites(self) -> set[str]:
        try:
            payload = json.loads(self._favorites_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = []
        return {str(item) for item in payload if item}

    def _write_favorites(self, favorites: set[str]) -> None:
        self._favorites_path.write_text(
            json.dumps(sorted(favorites), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def shutdown(self) -> None:
        self.stop()


runtime = FaceFusionRuntime()
app = FastAPI(title="FaceSwap Studio Bridge", version="0.3.0")


@app.on_event("shutdown")
def on_shutdown() -> None:
    runtime.shutdown()


@app.get("/health")
def health() -> dict[str, Any]:
    status = runtime.status()
    return {
        "status": "ok",
        "service": "faceswap-studio-bridge",
        "bridge_host": BRIDGE_HOST,
        "bridge_port": BRIDGE_PORT,
        "facefusion": status,
    }


@app.get("/facefusion/status")
def facefusion_status() -> dict[str, Any]:
    return runtime.status()


@app.post("/facefusion/start")
def facefusion_start() -> dict[str, Any]:
    return runtime.start()


@app.post("/facefusion/stop")
def facefusion_stop() -> dict[str, Any]:
    return runtime.stop()


@app.post("/facefusion/open-browser")
def facefusion_open_browser() -> dict[str, Any]:
    return runtime.open_browser()


@app.get("/metrics/system")
def metrics_system() -> dict[str, Any]:
    return runtime.metrics()


@app.get("/logs")
def logs(
    after: int = Query(default=0, ge=0),
    limit: int = Query(default=200, ge=1, le=500),
) -> dict[str, Any]:
    return runtime.get_logs(after=after, limit=limit)


@app.get("/queue/tasks")
def queue_tasks() -> dict[str, Any]:
    return runtime.list_queue_tasks()


@app.post("/queue/run")
def queue_run() -> dict[str, Any]:
    return runtime.run_queue()


@app.delete("/queue/tasks/{job_id}")
def queue_delete(job_id: str) -> dict[str, Any]:
    return runtime.delete_queue_task(job_id)


@app.get("/settings")
def settings_get() -> dict[str, Any]:
    return runtime.get_settings()


@app.put("/settings")
def settings_put(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.update_settings(payload)


@app.get("/works")
def works_list() -> dict[str, Any]:
    return runtime.list_works(favorite_only=False)


@app.get("/works/favorites")
def works_favorites() -> dict[str, Any]:
    return runtime.list_works(favorite_only=True)


@app.post("/works/{work_id}/favorite")
def works_favorite(work_id: str) -> dict[str, Any]:
    return runtime.favorite_work(work_id, True)


@app.delete("/works/{work_id}/favorite")
def works_unfavorite(work_id: str) -> dict[str, Any]:
    return runtime.favorite_work(work_id, False)


@app.delete("/works/{work_id}")
def works_delete(work_id: str) -> dict[str, Any]:
    return runtime.delete_work(work_id)
