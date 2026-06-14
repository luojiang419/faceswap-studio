from __future__ import annotations

from collections import deque
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
from typing import Any
from urllib.parse import urlparse
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener, urlopen
import webbrowser

BRIDGE_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(BRIDGE_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_REPO_ROOT))

import facefusion.choices as facefusion_choices
from facefusion.processors.modules.face_enhancer import choices as face_enhancer_choices
from facefusion.processors.modules.face_swapper import choices as face_swapper_choices
from facefusion.processors.modules.frame_enhancer import choices as frame_enhancer_choices
from facefusion.uis import choices as ui_choices
from fastapi import FastAPI, Query
import psutil


BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 50741
FACEFUSION_UI_HOST = "0.0.0.0"
FACEFUSION_UI_PORT = 7860
FACEFUSION_LOCAL_HOST = "127.0.0.1"
FACEFUSION_WILDCARD_HOSTS = {"0.0.0.0", "::", "[::]"}
LOG_LIMIT = 2000
JOB_STATUSES = ["drafted", "queued", "completed", "failed"]
AUDIO_EXTENSIONS = {".mp3", ".wav", ".aac", ".flac", ".ogg", ".m4a", ".opus"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".mpeg", ".m4v"}
LOCAL_FFMPEG_EXE = Path(r"G:\data\ffmpeg\bin\ffmpeg.exe")
FFMPEG_VERSION_FILE = "ffmpeg-source.json"
MODEL_DOWNLOAD_MODE_DOMESTIC = "domestic_mirror"
MODEL_DOWNLOAD_MODE_SYSTEM_PROXY = "system_proxy"
MODEL_DOWNLOAD_MODE_CUSTOM_PROXY = "custom_proxy"
MODEL_DOWNLOAD_MODES = {
    MODEL_DOWNLOAD_MODE_DOMESTIC,
    MODEL_DOWNLOAD_MODE_SYSTEM_PROXY,
    MODEL_DOWNLOAD_MODE_CUSTOM_PROXY,
}
DEFAULT_CUSTOM_PROXY_URL = "http://127.0.0.1:7890"
DOMESTIC_HUGGINGFACE_MIRROR = "https://hf-mirror.com"
OFFICIAL_HUGGINGFACE_URL = "https://huggingface.co"
OFFICIAL_GITHUB_URL = "https://github.com"
LOCAL_NO_PROXY = "localhost,127.0.0.1,::1"
CORE_MODEL_SCOPE = "core"
CORE_MODEL_USER_AGENT = "FaceSwap Studio Model Bootstrap/1.0"
UPDATE_USER_AGENT = "FaceSwap Studio Updater/1.0"
UPDATE_REPOSITORY = "luojiang419/faceswap-studio"
UPDATE_MANIFEST_ASSET = "update-manifest.json"
UPDATE_CACHE_DIRNAME = "FaceSwap Studio"
CORE_MODEL_PACKAGE: list[dict[str, Any]] = [
    {"label": "NSFW 内容检测 1", "base": "models-3.3.0", "file": "nsfw_1.hash", "size": 8},
    {"label": "NSFW 内容检测 1", "base": "models-3.3.0", "file": "nsfw_1.onnx", "size": 80414194},
    {"label": "NSFW 内容检测 2", "base": "models-3.3.0", "file": "nsfw_2.hash", "size": 8},
    {"label": "NSFW 内容检测 2", "base": "models-3.3.0", "file": "nsfw_2.onnx", "size": 22489928},
    {"label": "NSFW 内容检测 3", "base": "models-3.3.0", "file": "nsfw_3.hash", "size": 8},
    {"label": "NSFW 内容检测 3", "base": "models-3.3.0", "file": "nsfw_3.onnx", "size": 358188033},
    {"label": "人脸属性识别", "base": "models-3.0.0", "file": "fairface.hash", "size": 8},
    {"label": "人脸属性识别", "base": "models-3.0.0", "file": "fairface.onnx", "size": 85170772},
    {"label": "YOLO 人脸检测", "base": "models-3.0.0", "file": "yoloface_8n.hash", "size": 8},
    {"label": "YOLO 人脸检测", "base": "models-3.0.0", "file": "yoloface_8n.onnx", "size": 12659761},
    {"label": "2D 人脸关键点", "base": "models-3.0.0", "file": "2dfan4.hash", "size": 8},
    {"label": "2D 人脸关键点", "base": "models-3.0.0", "file": "2dfan4.onnx", "size": 97904803},
    {"label": "68 点关键点", "base": "models-3.0.0", "file": "fan_68_5.hash", "size": 8},
    {"label": "68 点关键点", "base": "models-3.0.0", "file": "fan_68_5.onnx", "size": 944321},
    {"label": "脸部遮罩", "base": "models-3.1.0", "file": "xseg_1.hash", "size": 8},
    {"label": "脸部遮罩", "base": "models-3.1.0", "file": "xseg_1.onnx", "size": 70324286},
    {"label": "脸部分区", "base": "models-3.0.0", "file": "bisenet_resnet_34.hash", "size": 8},
    {"label": "脸部分区", "base": "models-3.0.0", "file": "bisenet_resnet_34.onnx", "size": 93632546},
    {"label": "ArcFace 识别", "base": "models-3.0.0", "file": "arcface_w600k_r50.hash", "size": 8},
    {"label": "ArcFace 识别", "base": "models-3.0.0", "file": "arcface_w600k_r50.onnx", "size": 174388474},
    {"label": "人声分离", "base": "models-3.0.0", "file": "kim_vocal_2.hash", "size": 8},
    {"label": "人声分离", "base": "models-3.0.0", "file": "kim_vocal_2.onnx", "size": 66766794},
    {"label": "默认换脸模型", "base": "models-3.3.0", "file": "hyperswap_1a_256.hash", "size": 8},
    {"label": "默认换脸模型", "base": "models-3.3.0", "file": "hyperswap_1a_256.onnx", "size": 402742682},
    {"label": "常用人脸增强", "base": "models-3.0.0", "file": "gfpgan_1.4.hash", "size": 8},
    {"label": "常用人脸增强", "base": "models-3.0.0", "file": "gfpgan_1.4.onnx", "size": 340299087},
    {"label": "常用画面增强", "base": "models-3.0.0", "file": "span_kendata_x4.hash", "size": 8},
    {"label": "常用画面增强", "base": "models-3.0.0", "file": "span_kendata_x4.onnx", "size": 0},
]


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
        self._preview_lock = threading.Lock()
        self._workspace_state: dict[str, Any] = {}
        self._workspace_options: dict[str, Any] = {}
        self._model_bootstrap_lock = threading.RLock()
        self._model_bootstrap_thread: threading.Thread | None = None
        self._update_lock = threading.RLock()
        self._update_download_thread: threading.Thread | None = None

        psutil.cpu_percent(interval=None)
        self._prepare_paths()
        self._model_bootstrap_state: dict[str, Any] = self._default_model_bootstrap_state()
        self._update_state: dict[str, Any] = self._default_update_state()
        self._append_log("[bridge] FaceSwap Studio Bridge initialized.")

    @property
    def webui_bind_host(self) -> str:
        host = str(self._settings.get("facefusion_host") or FACEFUSION_UI_HOST).strip()
        return host or FACEFUSION_UI_HOST

    @property
    def webui_client_host(self) -> str:
        if self.webui_bind_host.lower() in FACEFUSION_WILDCARD_HOSTS:
            return FACEFUSION_LOCAL_HOST
        return self.webui_bind_host

    @property
    def webui_url(self) -> str:
        return f"http://{self.webui_client_host}:{self._settings['facefusion_port']}"

    @property
    def webui_bind_url(self) -> str:
        return f"http://{self.webui_bind_host}:{self._settings['facefusion_port']}"

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
        self._models_dir = self._repo_root / ".assets" / "models"
        self._thumbnail_dir = studio_root / "data" / "cache" / "thumbnails"
        self._workspace_state_path = self._runtime_dir / "workspace_state.json"
        self._workspace_options_path = self._runtime_dir / "workspace_options.json"

        for directory in [
            self._jobs_dir,
            self._temp_dir,
            self._models_dir,
            self._thumbnail_dir,
            self._runtime_dir,
            self._settings_path.parent,
            self._favorites_path.parent,
        ]:
            directory.mkdir(parents=True, exist_ok=True)

        if not self._favorites_path.exists():
            self._favorites_path.write_text("[]", encoding="utf-8")

        self._settings = self._load_settings()
        self._ensure_bundled_ffmpeg()
        self._apply_output_root(self._settings["default_output_dir"])
        self._workspace_state = self._load_workspace_state()
        self._workspace_options = self._load_workspace_options()

    def _bundled_ffmpeg_root(self) -> Path:
        return self.repo_root / ".runtime" / "ffmpeg"

    def _bundled_ffmpeg_executable(self) -> Path:
        return self._bundled_ffmpeg_root() / "ffmpeg.exe"

    def _bundled_ffmpeg_marker(self) -> Path:
        return self._bundled_ffmpeg_root() / FFMPEG_VERSION_FILE

    def _ffmpeg_source_metadata(self, ffmpeg_path: Path) -> dict[str, Any]:
        stat = ffmpeg_path.stat()
        return {
            "source_path": str(ffmpeg_path),
            "size_bytes": stat.st_size,
            "modified_at": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
        }

    def _read_ffmpeg_marker(self) -> dict[str, Any]:
        marker_path = self._bundled_ffmpeg_marker()
        if not marker_path.exists():
            return {}
        try:
            payload = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _ensure_bundled_ffmpeg(self) -> None:
        target_path = self._bundled_ffmpeg_executable()
        marker_path = self._bundled_ffmpeg_marker()
        if not LOCAL_FFMPEG_EXE.exists():
            self._append_log(f"[bridge] Local ffmpeg source not found: {LOCAL_FFMPEG_EXE}")
            return

        try:
            source_metadata = self._ffmpeg_source_metadata(LOCAL_FFMPEG_EXE)
        except OSError as error:
            self._append_log(f"[bridge] Unable to inspect local ffmpeg source: {error}")
            return

        marker_payload = self._read_ffmpeg_marker()
        marker_metadata = {
            "source_path": marker_payload.get("source_path"),
            "size_bytes": marker_payload.get("size_bytes"),
            "modified_at": marker_payload.get("modified_at"),
        }
        should_copy = not target_path.exists() or not marker_path.exists() or marker_metadata != source_metadata
        if not should_copy:
            return

        try:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(LOCAL_FFMPEG_EXE, target_path)
            marker_path.write_text(
                json.dumps(
                    {
                        **source_metadata,
                        "copied_at": datetime.now().isoformat(timespec="seconds"),
                    },
                    indent=2,
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            self._append_log(f"[bridge] Copied ffmpeg to {target_path}")
        except OSError as error:
            self._append_log(f"[bridge] Failed to copy ffmpeg from {LOCAL_FFMPEG_EXE}: {error}")

    def _load_settings(self) -> dict[str, Any]:
        defaults = {
            "theme": "dark",
            "facefusion_host": FACEFUSION_UI_HOST,
            "facefusion_port": FACEFUSION_UI_PORT,
            "default_output_dir": str(self._studio_root / "data" / "output"),
            "model_download_mode": MODEL_DOWNLOAD_MODE_DOMESTIC,
            "custom_proxy_url": DEFAULT_CUSTOM_PROXY_URL,
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
            "model_download_mode": self._normalize_model_download_mode(payload.get("model_download_mode")),
            "custom_proxy_url": self._normalize_proxy_url(payload.get("custom_proxy_url")),
        }
        self._settings_path.write_text(json.dumps(merged, indent=2, ensure_ascii=False), encoding="utf-8")
        return merged

    def _save_settings(self) -> None:
        self._settings_path.write_text(
            json.dumps(self._settings, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _normalize_model_download_mode(self, value: Any) -> str:
        mode = str(value or MODEL_DOWNLOAD_MODE_DOMESTIC).strip()
        if mode in MODEL_DOWNLOAD_MODES:
            return mode
        return MODEL_DOWNLOAD_MODE_DOMESTIC

    def _normalize_proxy_url(self, value: Any) -> str:
        proxy_url = str(value or DEFAULT_CUSTOM_PROXY_URL).strip()
        return proxy_url or DEFAULT_CUSTOM_PROXY_URL

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

    def _default_model_bootstrap_state(self) -> dict[str, Any]:
        return {
            "state": "idle",
            "scope": CORE_MODEL_SCOPE,
            "message": "核心模型尚未检查。",
            "current_file": None,
            "current_label": None,
            "file_index": 0,
            "file_total": len(CORE_MODEL_PACKAGE),
            "downloaded_bytes": 0,
            "total_bytes": self._core_model_expected_total(),
            "percent": 0.0,
            "speed_bps": 0.0,
            "missing_count": 0,
            "ready": False,
            "error": None,
            "started_at": None,
            "completed_at": None,
        }

    def _core_model_expected_total(self) -> int:
        return sum(int(model.get("size") or 0) for model in CORE_MODEL_PACKAGE)

    def _core_model_path(self, model: dict[str, Any]) -> Path:
        return self._models_dir / str(model["file"])

    def _core_model_url(self, model: dict[str, Any]) -> str:
        mode = self._normalize_model_download_mode(self._settings.get("model_download_mode"))
        if mode == MODEL_DOWNLOAD_MODE_DOMESTIC:
            base_url = DOMESTIC_HUGGINGFACE_MIRROR
        else:
            base_url = OFFICIAL_HUGGINGFACE_URL
        return f"{base_url.rstrip('/')}/facefusion/{model['base']}/resolve/main/{model['file']}"

    def _core_model_opener(self):
        mode = self._normalize_model_download_mode(self._settings.get("model_download_mode"))
        proxy_url = self._normalize_proxy_url(self._settings.get("custom_proxy_url"))
        if mode == MODEL_DOWNLOAD_MODE_CUSTOM_PROXY:
            return build_opener(ProxyHandler({"http": proxy_url, "https": proxy_url}))
        if mode == MODEL_DOWNLOAD_MODE_DOMESTIC:
            return build_opener(ProxyHandler({}))
        return build_opener()

    def _is_core_model_present(self, model: dict[str, Any]) -> bool:
        path = self._core_model_path(model)
        expected_size = int(model.get("size") or 0)
        if not path.exists() or not path.is_file():
            return False
        if expected_size <= 0:
            return path.stat().st_size > 0
        return path.stat().st_size >= expected_size

    def _scan_core_models(self) -> dict[str, Any]:
        missing: list[dict[str, Any]] = []
        present_bytes = 0
        total_bytes = self._core_model_expected_total()

        for model in CORE_MODEL_PACKAGE:
            path = self._core_model_path(model)
            expected_size = int(model.get("size") or 0)
            if self._is_core_model_present(model):
                present_bytes += expected_size or path.stat().st_size
            else:
                missing.append(model)

        return {
            "missing": missing,
            "missing_count": len(missing),
            "present_count": len(CORE_MODEL_PACKAGE) - len(missing),
            "file_total": len(CORE_MODEL_PACKAGE),
            "downloaded_bytes": present_bytes,
            "total_bytes": total_bytes,
            "ready": not missing,
        }

    def _copy_model_bootstrap_state(self) -> dict[str, Any]:
        with self._model_bootstrap_lock:
            return dict(self._model_bootstrap_state)

    def _set_model_bootstrap_state(self, **updates: Any) -> None:
        with self._model_bootstrap_lock:
            self._model_bootstrap_state.update(updates)

    def get_model_bootstrap_status(self) -> dict[str, Any]:
        state = self._copy_model_bootstrap_state()
        if state["state"] in {"starting", "downloading"}:
            return state

        scan = self._scan_core_models()
        if scan["ready"]:
            state.update(
                {
                    "state": "ready",
                    "message": "核心模型已准备就绪。",
                    "current_file": None,
                    "current_label": None,
                    "file_index": scan["file_total"],
                    "file_total": scan["file_total"],
                    "downloaded_bytes": scan["total_bytes"],
                    "total_bytes": scan["total_bytes"],
                    "percent": 100.0,
                    "speed_bps": 0.0,
                    "missing_count": 0,
                    "ready": True,
                    "error": None,
                }
            )
        elif state["state"] != "failed":
            percent = 0.0
            if scan["total_bytes"] > 0:
                percent = round(min(scan["downloaded_bytes"] / scan["total_bytes"] * 100.0, 99.0), 2)
            state.update(
                {
                    "state": "missing",
                    "message": f"缺少 {scan['missing_count']} 个核心模型文件。",
                    "current_file": None,
                    "current_label": None,
                    "file_index": scan["present_count"],
                    "file_total": scan["file_total"],
                    "downloaded_bytes": scan["downloaded_bytes"],
                    "total_bytes": scan["total_bytes"],
                    "percent": percent,
                    "speed_bps": 0.0,
                    "missing_count": scan["missing_count"],
                    "ready": False,
                    "error": None,
                }
            )
        return state

    def start_model_bootstrap(self) -> dict[str, Any]:
        scan = self._scan_core_models()
        if scan["ready"]:
            return self.get_model_bootstrap_status()

        with self._model_bootstrap_lock:
            if self._model_bootstrap_thread and self._model_bootstrap_thread.is_alive():
                return dict(self._model_bootstrap_state)

            self._model_bootstrap_state = self._default_model_bootstrap_state()
            self._model_bootstrap_state.update(
                {
                    "state": "starting",
                    "message": "正在准备核心模型下载...",
                    "missing_count": scan["missing_count"],
                    "ready": False,
                    "started_at": datetime.now().isoformat(timespec="seconds"),
                }
            )
            self._model_bootstrap_thread = threading.Thread(target=self._download_core_models, daemon=True)
            self._model_bootstrap_thread.start()
            return dict(self._model_bootstrap_state)

    def _resolve_model_download_size(self, opener: Any, model: dict[str, Any]) -> int:
        expected_size = int(model.get("size") or 0)
        if expected_size > 0:
            return expected_size

        request = Request(
            self._core_model_url(model),
            method="HEAD",
            headers={"User-Agent": CORE_MODEL_USER_AGENT},
        )
        try:
            with opener.open(request, timeout=15) as response:
                content_length = response.headers.get("Content-Length")
                if content_length:
                    return int(content_length)
        except (OSError, URLError, TimeoutError, ValueError):
            pass
        return 0

    def _download_core_models(self) -> None:
        opener = self._core_model_opener()
        scan = self._scan_core_models()
        missing = list(scan["missing"])
        sizes = {model["file"]: self._resolve_model_download_size(opener, model) for model in missing}
        total_missing_bytes = sum(sizes.values())
        completed_bytes = 0
        started_at = time.monotonic()

        if total_missing_bytes <= 0:
            total_missing_bytes = max(scan["total_bytes"] - scan["downloaded_bytes"], 1)

        self._append_log(f"[bridge] Core model bootstrap started with {len(missing)} missing file(s).")
        self._set_model_bootstrap_state(
            state="downloading",
            message="正在下载核心模型...",
            file_index=0,
            file_total=len(missing),
            downloaded_bytes=0,
            total_bytes=total_missing_bytes,
            percent=0.0,
            speed_bps=0.0,
            error=None,
        )

        try:
            for index, model in enumerate(missing, start=1):
                target_path = self._core_model_path(model)
                temp_path = target_path.with_suffix(target_path.suffix + ".download")
                target_path.parent.mkdir(parents=True, exist_ok=True)
                if temp_path.exists():
                    temp_path.unlink()

                url = self._core_model_url(model)
                expected_size = sizes.get(model["file"], 0)
                request = Request(url, headers={"User-Agent": CORE_MODEL_USER_AGENT})
                self._set_model_bootstrap_state(
                    current_file=model["file"],
                    current_label=model["label"],
                    file_index=index,
                    message=f"正在下载 {model['label']} ({model['file']})",
                )

                file_bytes = 0
                last_tick = time.monotonic()
                last_tick_bytes = completed_bytes
                with opener.open(request, timeout=30) as response, open(temp_path, "wb") as output:
                    content_length = response.headers.get("Content-Length")
                    if content_length:
                        try:
                            expected_size = int(content_length)
                            sizes[model["file"]] = expected_size
                            total_missing_bytes = max(
                                sum(sizes.values()),
                                completed_bytes + expected_size,
                                1,
                            )
                        except ValueError:
                            pass

                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                        file_bytes += len(chunk)
                        downloaded_bytes = completed_bytes + file_bytes
                        now = time.monotonic()
                        elapsed = max(now - started_at, 0.001)
                        tick_elapsed = max(now - last_tick, 0.001)
                        speed_bps = (downloaded_bytes - last_tick_bytes) / tick_elapsed
                        if tick_elapsed >= 0.5:
                            last_tick = now
                            last_tick_bytes = downloaded_bytes
                        percent = round(min(downloaded_bytes / total_missing_bytes * 100.0, 99.9), 2)
                        self._set_model_bootstrap_state(
                            downloaded_bytes=downloaded_bytes,
                            total_bytes=total_missing_bytes,
                            percent=percent,
                            speed_bps=speed_bps if speed_bps > 0 else downloaded_bytes / elapsed,
                        )

                if expected_size > 0 and file_bytes < expected_size:
                    raise RuntimeError(f"Downloaded file is incomplete: {model['file']}")
                temp_path.replace(target_path)
                completed_bytes += file_bytes
                self._append_log(f"[bridge] Downloaded core model file: {model['file']}")

            final_scan = self._scan_core_models()
            if not final_scan["ready"]:
                raise RuntimeError(f"{final_scan['missing_count']} core model file(s) are still missing.")

            self._set_model_bootstrap_state(
                state="ready",
                message="核心模型下载完成。",
                current_file=None,
                current_label=None,
                downloaded_bytes=max(completed_bytes, total_missing_bytes),
                total_bytes=max(completed_bytes, total_missing_bytes),
                percent=100.0,
                speed_bps=0.0,
                missing_count=0,
                ready=True,
                error=None,
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log("[bridge] Core model bootstrap completed.")
        except Exception as error:
            self._set_model_bootstrap_state(
                state="failed",
                message="核心模型下载失败。",
                speed_bps=0.0,
                ready=False,
                error=str(error),
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log(f"[bridge] Core model bootstrap failed: {error}")

    def _read_app_version(self) -> str:
        version_path = self.repo_root / "VERSION"
        try:
            version = version_path.read_text(encoding="utf-8").strip()
        except OSError:
            version = "0.0.0"
        return version or "0.0.0"

    def _default_update_state(self) -> dict[str, Any]:
        return {
            "state": "idle",
            "message": "尚未检查更新。",
            "current_version": self._read_app_version(),
            "latest_version": None,
            "update_available": False,
            "delta_available": False,
            "full_installer_url": None,
            "release_url": None,
            "asset_name": None,
            "package_path": None,
            "downloaded_bytes": 0,
            "total_bytes": 0,
            "percent": 0.0,
            "speed_bps": 0.0,
            "error": None,
            "checked_at": None,
            "completed_at": None,
        }

    def _copy_update_state(self) -> dict[str, Any]:
        with self._update_lock:
            return dict(self._update_state)

    def _set_update_state(self, **updates: Any) -> None:
        with self._update_lock:
            self._update_state.update(updates)

    def _updates_root(self) -> Path:
        base = os.environ.get("LOCALAPPDATA")
        if base:
            return Path(base) / UPDATE_CACHE_DIRNAME / "updates"
        return Path.home() / ".faceswap-studio" / "updates"

    def _update_opener(self):
        return build_opener()

    def _version_parts(self, version: str) -> tuple[int, ...]:
        parts: list[int] = []
        for segment in version.strip().lstrip("v").replace("-", ".").split("."):
            digits = "".join(ch for ch in segment if ch.isdigit())
            if digits:
                parts.append(int(digits))
            else:
                parts.append(0)
        return tuple(parts or [0])

    def _is_newer_version(self, latest: str, current: str) -> bool:
        latest_parts = list(self._version_parts(latest))
        current_parts = list(self._version_parts(current))
        width = max(len(latest_parts), len(current_parts))
        latest_parts += [0] * (width - len(latest_parts))
        current_parts += [0] * (width - len(current_parts))
        return latest_parts > current_parts

    def _download_json(self, url: str, timeout: int = 20) -> dict[str, Any]:
        request = Request(url, headers={"Accept": "application/json", "User-Agent": UPDATE_USER_AGENT})
        with self._update_opener().open(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8-sig"))

    def _latest_release_metadata(self) -> tuple[dict[str, Any], dict[str, str]]:
        manifest_override = os.environ.get("FACESWAP_STUDIO_UPDATE_MANIFEST_URL")
        if manifest_override:
            manifest = self._download_json(manifest_override)
            return manifest, {}

        repository = os.environ.get("FACESWAP_STUDIO_UPDATE_REPOSITORY", UPDATE_REPOSITORY)
        release_api_url = f"https://api.github.com/repos/{repository}/releases/latest"
        release = self._download_json(release_api_url)
        assets = release.get("assets") or []
        asset_urls: dict[str, str] = {}
        for asset in assets:
            name = str(asset.get("name") or "")
            url = str(asset.get("browser_download_url") or "")
            if name and url:
                asset_urls[name] = url

        manifest_url = asset_urls.get(UPDATE_MANIFEST_ASSET)
        if not manifest_url:
            raise RuntimeError(f"{UPDATE_MANIFEST_ASSET} was not found in the latest release.")

        manifest = self._download_json(manifest_url)
        manifest["release_url"] = release.get("html_url")
        return manifest, asset_urls

    def _resolve_update_url(self, package: dict[str, Any], asset_urls: dict[str, str]) -> str | None:
        direct_url = package.get("url") or package.get("download_url")
        if direct_url:
            return str(direct_url)
        asset_name = str(package.get("asset_name") or "")
        if asset_name:
            return asset_urls.get(asset_name)
        return None

    def _select_delta_package(
        self,
        manifest: dict[str, Any],
        asset_urls: dict[str, str],
        current_version: str,
    ) -> dict[str, Any] | None:
        for package in manifest.get("delta_packages") or []:
            if str(package.get("from_version") or "") != current_version:
                continue
            url = self._resolve_update_url(package, asset_urls)
            if not url:
                continue
            selected = dict(package)
            selected["download_url"] = url
            return selected
        return None

    def update_status(self) -> dict[str, Any]:
        state = self._copy_update_state()
        state["current_version"] = self._read_app_version()
        return state

    def check_updates(self) -> dict[str, Any]:
        with self._update_lock:
            self._update_state = self._default_update_state()
            self._update_state.update(
                {
                    "state": "checking",
                    "message": "正在检查更新...",
                    "checked_at": datetime.now().isoformat(timespec="seconds"),
                }
            )

        try:
            current_version = self._read_app_version()
            manifest, asset_urls = self._latest_release_metadata()
            latest_version = str(manifest.get("version") or "")
            if not latest_version:
                raise RuntimeError("Update manifest does not contain a version.")

            full_package = dict(manifest.get("full_package") or {})
            full_installer_url = self._resolve_update_url(full_package, asset_urls)
            release_url = manifest.get("release_url")
            update_available = self._is_newer_version(latest_version, current_version)
            selected_delta = self._select_delta_package(manifest, asset_urls, current_version)

            state_updates: dict[str, Any] = {
                "latest_version": latest_version,
                "update_available": update_available,
                "delta_available": bool(update_available and selected_delta),
                "full_installer_url": full_installer_url,
                "release_url": release_url,
                "manifest": manifest,
                "selected_delta": selected_delta,
                "error": None,
            }

            if not update_available:
                state_updates.update({"state": "current", "message": "当前已是最新版本。"})
            elif selected_delta:
                state_updates.update(
                    {
                        "state": "update_available",
                        "message": f"发现新版本 {latest_version}。",
                        "asset_name": selected_delta.get("asset_name"),
                        "total_bytes": int(selected_delta.get("size") or 0),
                    }
                )
            else:
                state_updates.update(
                    {
                        "state": "full_required",
                        "message": "当前版本没有可用增量包，请下载全量安装器。",
                        "asset_name": full_package.get("asset_name"),
                        "total_bytes": int(full_package.get("size") or 0),
                    }
                )

            self._set_update_state(**state_updates)
        except Exception as error:
            self._set_update_state(
                state="failed",
                message="检查更新失败。",
                update_available=False,
                delta_available=False,
                error=str(error),
            )
            self._append_log(f"[bridge] Update check failed: {error}")

        return self.update_status()

    def download_update(self) -> dict[str, Any]:
        state = self._copy_update_state()
        if state.get("state") in {"idle", "failed", "current"}:
            state = self.check_updates()
        if not state.get("update_available"):
            return self.update_status()
        if not state.get("delta_available"):
            return self.update_status()

        with self._update_lock:
            if self._update_download_thread and self._update_download_thread.is_alive():
                return dict(self._update_state)
            self._update_state.update(
                {
                    "state": "downloading",
                    "message": "正在下载更新包...",
                    "downloaded_bytes": 0,
                    "percent": 0.0,
                    "speed_bps": 0.0,
                    "error": None,
                }
            )
            self._update_download_thread = threading.Thread(target=self._download_update_worker, daemon=True)
            self._update_download_thread.start()
            return dict(self._update_state)

    def _download_update_worker(self) -> None:
        state = self._copy_update_state()
        package = dict(state.get("selected_delta") or {})
        download_url = str(package.get("download_url") or "")
        if not download_url:
            self._set_update_state(state="failed", message="更新包下载地址缺失。", error="Missing delta download URL")
            return

        version = str(state.get("latest_version") or "unknown")
        asset_name = str(package.get("asset_name") or Path(urlparse(download_url).path).name or "update.delta.zip")
        expected_hash = str(package.get("sha256") or "")
        expected_size = int(package.get("size") or 0)
        target_dir = self._updates_root() / version
        target_dir.mkdir(parents=True, exist_ok=True)
        target_path = target_dir / asset_name
        temp_path = target_path.with_suffix(target_path.suffix + ".download")

        try:
            if temp_path.exists():
                temp_path.unlink()
            request = Request(download_url, headers={"User-Agent": UPDATE_USER_AGENT})
            started_at = time.monotonic()
            downloaded = 0
            with self._update_opener().open(request, timeout=30) as response, open(temp_path, "wb") as output:
                content_length = response.headers.get("Content-Length")
                if content_length:
                    try:
                        expected_size = int(content_length)
                    except ValueError:
                        pass
                last_tick = time.monotonic()
                last_tick_bytes = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    downloaded += len(chunk)
                    now = time.monotonic()
                    tick_elapsed = max(now - last_tick, 0.001)
                    speed = (downloaded - last_tick_bytes) / tick_elapsed
                    if tick_elapsed >= 0.5:
                        last_tick = now
                        last_tick_bytes = downloaded
                    percent = 0.0
                    if expected_size > 0:
                        percent = round(min(downloaded / expected_size * 100.0, 99.9), 2)
                    elapsed = max(now - started_at, 0.001)
                    self._set_update_state(
                        downloaded_bytes=downloaded,
                        total_bytes=expected_size,
                        percent=percent,
                        speed_bps=speed if speed > 0 else downloaded / elapsed,
                    )

            if expected_size > 0 and downloaded < expected_size:
                raise RuntimeError("Downloaded update package is incomplete.")

            actual_hash = hashlib.sha256(temp_path.read_bytes()).hexdigest().upper()
            if expected_hash and actual_hash.upper() != expected_hash.upper():
                raise RuntimeError("Update package SHA256 mismatch.")

            temp_path.replace(target_path)
            self._set_update_state(
                state="downloaded",
                message="更新包下载完成。",
                package_path=str(target_path),
                downloaded_bytes=downloaded,
                total_bytes=expected_size or downloaded,
                percent=100.0,
                speed_bps=0.0,
                completed_at=datetime.now().isoformat(timespec="seconds"),
                error=None,
            )
            self._append_log(f"[bridge] Update package downloaded: {target_path}")
        except Exception as error:
            self._set_update_state(
                state="failed",
                message="更新包下载失败。",
                speed_bps=0.0,
                error=str(error),
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log(f"[bridge] Update download failed: {error}")

    def apply_update(self) -> dict[str, Any]:
        state = self._copy_update_state()
        package_path = Path(str(state.get("package_path") or ""))
        if not package_path.exists():
            return {
                **state,
                "state": "failed",
                "message": "更新包尚未下载。",
                "error": "Update package was not downloaded.",
            }

        updater_source = self.repo_root / "FaceSwapStudioUpdater.exe"
        if not updater_source.exists():
            return {
                **state,
                "state": "failed",
                "message": "更新程序缺失。",
                "error": f"Updater not found: {updater_source}",
            }

        updater_dir = self._updates_root() / "runner"
        updater_dir.mkdir(parents=True, exist_ok=True)
        updater_copy = updater_dir / "FaceSwapStudioUpdater.exe"
        shutil.copy2(updater_source, updater_copy)

        restart_path = self.repo_root / "启动FaceSwap Studio.exe"
        args = [
            "--root",
            str(self.repo_root),
            "--package",
            str(package_path),
            "--restart",
            str(restart_path),
        ]
        escaped_file = str(updater_copy).replace("'", "''")
        escaped_args = ", ".join("'" + arg.replace("'", "''") + "'" for arg in args)
        command = f"Start-Process -FilePath '{escaped_file}' -ArgumentList @({escaped_args}) -Verb RunAs"
        powershell = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        subprocess.Popen(
            [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self._set_update_state(state="applying", message="更新程序已启动，请确认系统权限提示。", error=None)
        self._append_log("[bridge] Updater launched.")
        return self.update_status()

    def _default_workspace_state(self) -> dict[str, Any]:
        return {
            "source_paths": [],
            "target_path": None,
        }

    def _load_workspace_state(self) -> dict[str, Any]:
        state = self._default_workspace_state()
        if self._workspace_state_path.exists():
            try:
                payload = json.loads(self._workspace_state_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                payload = {}
            state["source_paths"] = self._normalize_source_paths(payload.get("source_paths"))
            state["target_path"] = self._normalize_target_path(payload.get("target_path"))
        self._save_workspace_state(state)
        return state

    def _save_workspace_state(self, state: dict[str, Any] | None = None) -> None:
        payload = state or self._workspace_state
        self._workspace_state_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _available_processor_names(self) -> list[str]:
        modules_dir = self.repo_root / "facefusion" / "processors" / "modules"
        processors = []
        if not modules_dir.exists():
            return processors
        for path in sorted(modules_dir.iterdir(), key=lambda item: item.name):
            if path.is_dir() and (path / "core.py").exists():
                processors.append(path.name)
        return processors

    def _default_workspace_options(self) -> dict[str, Any]:
        available_processors = self._available_processor_names()
        default_processors = ["face_swapper"] if "face_swapper" in available_processors else available_processors[:1]

        default_face_swapper_model = (
            "hyperswap_1a_256"
            if "hyperswap_1a_256" in face_swapper_choices.face_swapper_models
            else face_swapper_choices.face_swapper_models[0]
        )
        default_face_swapper_pixel_boost_choices = face_swapper_choices.face_swapper_set.get(
            default_face_swapper_model,
            [],
        )
        default_video_encoder = (
            "libx264"
            if "libx264" in facefusion_choices.output_video_encoders
            else (
                facefusion_choices.output_video_encoders[0]
                if facefusion_choices.output_video_encoders
                else None
            )
        )
        default_video_preset = (
            "veryfast"
            if "veryfast" in facefusion_choices.output_video_presets
            else (
                facefusion_choices.output_video_presets[0]
                if facefusion_choices.output_video_presets
                else None
            )
        )

        return {
            "processors": default_processors,
            "face_swapper_model": default_face_swapper_model,
            "face_swapper_pixel_boost": (
                default_face_swapper_pixel_boost_choices[0]
                if default_face_swapper_pixel_boost_choices
                else None
            ),
            "face_swapper_weight": 0.5,
            "face_enhancer_model": "gfpgan_1.4",
            "face_enhancer_blend": 80,
            "face_enhancer_weight": 0.5,
            "frame_enhancer_model": "span_kendata_x4",
            "frame_enhancer_blend": 80,
            "output_image_quality": 80,
            "output_image_scale": 1.0,
            "output_video_encoder": default_video_encoder,
            "output_video_preset": default_video_preset,
            "output_video_quality": 80,
            "output_video_scale": 1.0,
            "output_video_fps": None,
            "preview_mode": ui_choices.preview_modes[0],
            "preview_resolution": ui_choices.preview_resolutions[-1],
            "preview_frame_number": 0,
        }

    def _load_workspace_options(self) -> dict[str, Any]:
        defaults = self._default_workspace_options()
        if not self._workspace_options_path.exists():
            self._save_workspace_options(defaults)
            return defaults

        try:
            payload = json.loads(self._workspace_options_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}

        normalized = self._normalize_workspace_options(payload, defaults)
        self._save_workspace_options(normalized)
        return normalized

    def _save_workspace_options(self, options: dict[str, Any] | None = None) -> None:
        payload = options or self._workspace_options
        self._workspace_options_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _choice_contains_float(self, choices: list[float], value: float) -> bool:
        return any(abs(choice - value) < 1e-9 for choice in choices)

    def _normalize_choice(self, value: Any, choices: list[Any], default: Any) -> Any:
        return value if value in choices else default

    def _normalize_list_choice(
        self,
        value: Any,
        choices: list[str],
        default: list[str],
    ) -> list[str]:
        if not isinstance(value, list):
            return list(default)

        normalized = []
        for item in value:
            candidate = str(item)
            if candidate in choices and candidate not in normalized:
                normalized.append(candidate)
        return normalized or list(default)

    def _normalize_int_choice(self, value: Any, choices: list[int], default: int) -> int:
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            return default
        return candidate if candidate in choices else default

    def _normalize_float_choice(
        self,
        value: Any,
        choices: list[float],
        default: float,
    ) -> float:
        try:
            candidate = float(value)
        except (TypeError, ValueError):
            return default
        return candidate if self._choice_contains_float(choices, candidate) else default

    def _normalize_optional_bounded_float(
        self,
        value: Any,
        default: float | None,
        minimum: float,
        maximum: float,
    ) -> float | None:
        if value in [None, ""]:
            return default
        try:
            candidate = round(float(value), 2)
        except (TypeError, ValueError):
            return default
        if minimum <= candidate <= maximum:
            return candidate
        return default

    def _normalize_non_negative_int(self, value: Any, default: int) -> int:
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            return default
        return candidate if candidate >= 0 else default

    def _normalize_workspace_options(
        self,
        payload: Any,
        base: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        defaults = self._default_workspace_options()
        normalized = dict(base or defaults)
        if not isinstance(payload, dict):
            return normalized

        available_processors = self._available_processor_names()
        normalized["processors"] = self._normalize_list_choice(
            payload.get("processors", normalized["processors"]),
            available_processors,
            defaults["processors"],
        )

        normalized["face_swapper_model"] = self._normalize_choice(
            payload.get("face_swapper_model", normalized["face_swapper_model"]),
            list(face_swapper_choices.face_swapper_models),
            defaults["face_swapper_model"],
        )
        face_swapper_pixel_boost_choices = list(
            face_swapper_choices.face_swapper_set.get(normalized["face_swapper_model"], []),
        )
        normalized["face_swapper_pixel_boost"] = self._normalize_choice(
            payload.get("face_swapper_pixel_boost", normalized["face_swapper_pixel_boost"]),
            face_swapper_pixel_boost_choices,
            face_swapper_pixel_boost_choices[0] if face_swapper_pixel_boost_choices else None,
        )
        normalized["face_swapper_weight"] = self._normalize_float_choice(
            payload.get("face_swapper_weight", normalized["face_swapper_weight"]),
            list(face_swapper_choices.face_swapper_weight_range),
            defaults["face_swapper_weight"],
        )

        normalized["face_enhancer_model"] = self._normalize_choice(
            payload.get("face_enhancer_model", normalized["face_enhancer_model"]),
            list(face_enhancer_choices.face_enhancer_models),
            defaults["face_enhancer_model"],
        )
        normalized["face_enhancer_blend"] = self._normalize_int_choice(
            payload.get("face_enhancer_blend", normalized["face_enhancer_blend"]),
            list(face_enhancer_choices.face_enhancer_blend_range),
            defaults["face_enhancer_blend"],
        )
        normalized["face_enhancer_weight"] = self._normalize_float_choice(
            payload.get("face_enhancer_weight", normalized["face_enhancer_weight"]),
            list(face_enhancer_choices.face_enhancer_weight_range),
            defaults["face_enhancer_weight"],
        )

        normalized["frame_enhancer_model"] = self._normalize_choice(
            payload.get("frame_enhancer_model", normalized["frame_enhancer_model"]),
            list(frame_enhancer_choices.frame_enhancer_models),
            defaults["frame_enhancer_model"],
        )
        normalized["frame_enhancer_blend"] = self._normalize_int_choice(
            payload.get("frame_enhancer_blend", normalized["frame_enhancer_blend"]),
            list(frame_enhancer_choices.frame_enhancer_blend_range),
            defaults["frame_enhancer_blend"],
        )

        normalized["output_image_quality"] = self._normalize_int_choice(
            payload.get("output_image_quality", normalized["output_image_quality"]),
            list(facefusion_choices.output_image_quality_range),
            defaults["output_image_quality"],
        )
        normalized["output_image_scale"] = self._normalize_float_choice(
            payload.get("output_image_scale", normalized["output_image_scale"]),
            list(facefusion_choices.output_image_scale_range),
            defaults["output_image_scale"],
        )
        normalized["output_video_encoder"] = self._normalize_choice(
            payload.get("output_video_encoder", normalized["output_video_encoder"]),
            list(facefusion_choices.output_video_encoders),
            defaults["output_video_encoder"],
        )
        normalized["output_video_preset"] = self._normalize_choice(
            payload.get("output_video_preset", normalized["output_video_preset"]),
            list(facefusion_choices.output_video_presets),
            defaults["output_video_preset"],
        )
        normalized["output_video_quality"] = self._normalize_int_choice(
            payload.get("output_video_quality", normalized["output_video_quality"]),
            list(facefusion_choices.output_video_quality_range),
            defaults["output_video_quality"],
        )
        normalized["output_video_scale"] = self._normalize_float_choice(
            payload.get("output_video_scale", normalized["output_video_scale"]),
            list(facefusion_choices.output_video_scale_range),
            defaults["output_video_scale"],
        )
        normalized["output_video_fps"] = self._normalize_optional_bounded_float(
            payload.get("output_video_fps", normalized["output_video_fps"]),
            normalized["output_video_fps"],
            1.0,
            60.0,
        )

        normalized["preview_mode"] = self._normalize_choice(
            payload.get("preview_mode", normalized["preview_mode"]),
            list(ui_choices.preview_modes),
            defaults["preview_mode"],
        )
        normalized["preview_resolution"] = self._normalize_choice(
            payload.get("preview_resolution", normalized["preview_resolution"]),
            list(ui_choices.preview_resolutions),
            defaults["preview_resolution"],
        )
        normalized["preview_frame_number"] = self._normalize_non_negative_int(
            payload.get("preview_frame_number", normalized["preview_frame_number"]),
            defaults["preview_frame_number"],
        )
        return normalized

    def workspace_options_state(self) -> dict[str, Any]:
        with self._lock:
            options = dict(self._workspace_options)
        return {
            "version": 1,
            "target_media_type": self._workspace_target_media_type(),
            "options": options,
        }

    def workspace_options_schema(self) -> dict[str, Any]:
        with self._lock:
            options = dict(self._workspace_options)

        current_face_swapper_model = str(
            options.get("face_swapper_model") or self._default_workspace_options()["face_swapper_model"],
        )
        pixel_boost_choices = list(
            face_swapper_choices.face_swapper_set.get(current_face_swapper_model, []),
        )

        fields = {
            "processors": {
                "type": "multi_select",
                "section": "processors",
                "label": "处理器",
                "choices": self._available_processor_names(),
                "default": self._default_workspace_options()["processors"],
                "visible_for": ["all"],
            },
            "face_swapper_model": {
                "type": "select",
                "section": "processors",
                "label": "换脸模型",
                "choices": list(face_swapper_choices.face_swapper_models),
                "default": self._default_workspace_options()["face_swapper_model"],
                "visible_for": ["all"],
            },
            "face_swapper_pixel_boost": {
                "type": "select",
                "section": "processors",
                "label": "像素增强",
                "choices": pixel_boost_choices,
                "default": pixel_boost_choices[0] if pixel_boost_choices else None,
                "depends_on": "face_swapper_model",
                "visible_for": ["all"],
            },
            "face_swapper_weight": {
                "type": "float",
                "section": "processors",
                "label": "换脸权重",
                "minimum": face_swapper_choices.face_swapper_weight_range[0],
                "maximum": face_swapper_choices.face_swapper_weight_range[-1],
                "step": 0.05,
                "default": self._default_workspace_options()["face_swapper_weight"],
                "visible_for": ["all"],
            },
            "face_enhancer_model": {
                "type": "select",
                "section": "enhancers",
                "label": "人脸增强模型",
                "choices": list(face_enhancer_choices.face_enhancer_models),
                "default": self._default_workspace_options()["face_enhancer_model"],
                "visible_for": ["all"],
            },
            "face_enhancer_blend": {
                "type": "int",
                "section": "enhancers",
                "label": "人脸增强混合",
                "minimum": face_enhancer_choices.face_enhancer_blend_range[0],
                "maximum": face_enhancer_choices.face_enhancer_blend_range[-1],
                "step": 1,
                "default": self._default_workspace_options()["face_enhancer_blend"],
                "visible_for": ["all"],
            },
            "face_enhancer_weight": {
                "type": "float",
                "section": "enhancers",
                "label": "人脸增强权重",
                "minimum": face_enhancer_choices.face_enhancer_weight_range[0],
                "maximum": face_enhancer_choices.face_enhancer_weight_range[-1],
                "step": 0.05,
                "default": self._default_workspace_options()["face_enhancer_weight"],
                "visible_for": ["all"],
            },
            "frame_enhancer_model": {
                "type": "select",
                "section": "enhancers",
                "label": "画面增强模型",
                "choices": list(frame_enhancer_choices.frame_enhancer_models),
                "default": self._default_workspace_options()["frame_enhancer_model"],
                "visible_for": ["all"],
            },
            "frame_enhancer_blend": {
                "type": "int",
                "section": "enhancers",
                "label": "画面增强混合",
                "minimum": frame_enhancer_choices.frame_enhancer_blend_range[0],
                "maximum": frame_enhancer_choices.frame_enhancer_blend_range[-1],
                "step": 1,
                "default": self._default_workspace_options()["frame_enhancer_blend"],
                "visible_for": ["all"],
            },
            "output_image_quality": {
                "type": "int",
                "section": "output",
                "label": "图片质量",
                "minimum": facefusion_choices.output_image_quality_range[0],
                "maximum": facefusion_choices.output_image_quality_range[-1],
                "step": 1,
                "default": self._default_workspace_options()["output_image_quality"],
                "visible_for": ["image"],
            },
            "output_image_scale": {
                "type": "float",
                "section": "output",
                "label": "图片缩放",
                "minimum": facefusion_choices.output_image_scale_range[0],
                "maximum": facefusion_choices.output_image_scale_range[-1],
                "step": 0.25,
                "default": self._default_workspace_options()["output_image_scale"],
                "visible_for": ["image"],
            },
            "output_video_encoder": {
                "type": "select",
                "section": "output",
                "label": "视频编码器",
                "choices": list(facefusion_choices.output_video_encoders),
                "default": self._default_workspace_options()["output_video_encoder"],
                "visible_for": ["video"],
            },
            "output_video_preset": {
                "type": "select",
                "section": "output",
                "label": "视频预设",
                "choices": list(facefusion_choices.output_video_presets),
                "default": self._default_workspace_options()["output_video_preset"],
                "visible_for": ["video"],
            },
            "output_video_quality": {
                "type": "int",
                "section": "output",
                "label": "视频质量",
                "minimum": facefusion_choices.output_video_quality_range[0],
                "maximum": facefusion_choices.output_video_quality_range[-1],
                "step": 1,
                "default": self._default_workspace_options()["output_video_quality"],
                "visible_for": ["video"],
            },
            "output_video_scale": {
                "type": "float",
                "section": "output",
                "label": "视频缩放",
                "minimum": facefusion_choices.output_video_scale_range[0],
                "maximum": facefusion_choices.output_video_scale_range[-1],
                "step": 0.25,
                "default": self._default_workspace_options()["output_video_scale"],
                "visible_for": ["video"],
            },
            "output_video_fps": {
                "type": "float",
                "section": "output",
                "label": "输出 FPS",
                "minimum": 1.0,
                "maximum": 60.0,
                "step": 0.01,
                "default": self._default_workspace_options()["output_video_fps"],
                "visible_for": ["video"],
            },
            "preview_mode": {
                "type": "select",
                "section": "preview",
                "label": "预览模式",
                "choices": list(ui_choices.preview_modes),
                "default": self._default_workspace_options()["preview_mode"],
                "visible_for": ["all"],
            },
            "preview_resolution": {
                "type": "select",
                "section": "preview",
                "label": "预览分辨率",
                "choices": list(ui_choices.preview_resolutions),
                "default": self._default_workspace_options()["preview_resolution"],
                "visible_for": ["all"],
            },
            "preview_frame_number": {
                "type": "int",
                "section": "preview",
                "label": "预览帧号",
                "minimum": 0,
                "default": self._default_workspace_options()["preview_frame_number"],
                "visible_for": ["video"],
            },
        }

        return {
            "version": 1,
            "target_media_type": self._workspace_target_media_type(),
            "fields": fields,
        }

    def update_workspace_options(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self._workspace_options = self._normalize_workspace_options(
                payload,
                dict(self._workspace_options),
            )
            self._save_workspace_options()
        self._append_log("[bridge] Updated workspace options draft.")
        return self.workspace_options_state()

    def clear_workspace_options(self) -> dict[str, Any]:
        with self._lock:
            self._workspace_options = self._default_workspace_options()
            self._save_workspace_options()
        self._append_log("[bridge] Reset workspace options draft to defaults.")
        return self.workspace_options_state()

    def _workspace_step_option_cli_args(self, options: dict[str, Any]) -> list[str]:
        cli_args: list[str] = []
        processors = [
            str(item) for item in (options.get("processors") or []) if item
        ]

        if processors:
            cli_args.extend(["--processors", *processors])

        if options.get("face_swapper_model") is not None:
            cli_args.extend(["--face-swapper-model", str(options["face_swapper_model"])])
        if options.get("face_swapper_pixel_boost") is not None:
            cli_args.extend(
                [
                    "--face-swapper-pixel-boost",
                    str(options["face_swapper_pixel_boost"]),
                ],
            )
        if options.get("face_swapper_weight") is not None:
            cli_args.extend(["--face-swapper-weight", str(options["face_swapper_weight"])])

        if "face_enhancer" in processors:
            if options.get("face_enhancer_model") is not None:
                cli_args.extend(
                    ["--face-enhancer-model", str(options["face_enhancer_model"])],
                )
            if options.get("face_enhancer_blend") is not None:
                cli_args.extend(
                    ["--face-enhancer-blend", str(options["face_enhancer_blend"])],
                )
            if options.get("face_enhancer_weight") is not None:
                cli_args.extend(
                    ["--face-enhancer-weight", str(options["face_enhancer_weight"])],
                )

        if "frame_enhancer" in processors:
            if options.get("frame_enhancer_model") is not None:
                cli_args.extend(
                    ["--frame-enhancer-model", str(options["frame_enhancer_model"])],
                )
            if options.get("frame_enhancer_blend") is not None:
                cli_args.extend(
                    ["--frame-enhancer-blend", str(options["frame_enhancer_blend"])],
                )

        if options.get("output_image_quality") is not None:
            cli_args.extend(
                ["--output-image-quality", str(options["output_image_quality"])],
            )
        if options.get("output_image_scale") is not None:
            cli_args.extend(["--output-image-scale", str(options["output_image_scale"])])
        if options.get("output_video_encoder") is not None:
            cli_args.extend(
                ["--output-video-encoder", str(options["output_video_encoder"])],
            )
        if options.get("output_video_preset") is not None:
            cli_args.extend(
                ["--output-video-preset", str(options["output_video_preset"])],
            )
        if options.get("output_video_quality") is not None:
            cli_args.extend(
                ["--output-video-quality", str(options["output_video_quality"])],
            )
        if options.get("output_video_scale") is not None:
            cli_args.extend(["--output-video-scale", str(options["output_video_scale"])])
        if options.get("output_video_fps") is not None:
            cli_args.extend(["--output-video-fps", str(options["output_video_fps"])])

        return cli_args

    def _workspace_preview_worker_path(self) -> Path:
        return self._studio_root / "bridge" / "services" / "workspace_preview_worker.py"

    def _compose_preview_request(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        payload = payload if isinstance(payload, dict) else {}
        current_workspace = self.workspace_state()
        current_options = self.workspace_options_state()["options"]

        raw_source_paths = payload["source_paths"] if "source_paths" in payload else current_workspace["source_paths"]
        raw_target_path = payload["target_path"] if "target_path" in payload else current_workspace["target_path"]
        source_paths = self._normalize_source_paths(raw_source_paths)
        target_path = self._normalize_target_path(raw_target_path)
        if not source_paths or not target_path:
            return None

        option_overrides = payload.get("options") or {}
        merged_options = self._normalize_workspace_options(option_overrides, dict(current_options))
        preview_output_name = "preview-" + datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
        output_path = self._resolve_workspace_output_path(target_path, preview_output_name)

        return {
            "config_path": "facefusion.ini",
            "jobs_path": str(self._jobs_dir),
            "temp_path": str(self._temp_dir),
            "source_paths": source_paths,
            "target_path": target_path,
            "output_path": output_path,
            "options": merged_options,
        }

    def preview_workspace(self, payload: dict[str, Any]) -> dict[str, Any]:
        request_payload = self._compose_preview_request(payload)
        if request_payload is None:
            return {
                "ok": False,
                "message": "预览需要有效的源文件和目标文件。",
                "workspace": self.workspace_state(),
                "options": self.workspace_options_state(),
            }

        worker_path = self._workspace_preview_worker_path()
        command = [sys.executable, str(worker_path)]
        self._append_log(
            "[bridge] Workspace preview requested: "
            f"{len(request_payload['source_paths'])} source file(s), target={request_payload['target_path']}",
        )

        try:
            with self._preview_lock:
                result = subprocess.run(
                    command,
                    input=json.dumps(request_payload, ensure_ascii=False),
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    cwd=self.repo_root,
                    env=self._build_env(),
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                    timeout=300,
                )
        except subprocess.TimeoutExpired:
            self._append_log("[bridge] Workspace preview timed out after 300 seconds.")
            return {
                "ok": False,
                "message": "预览超时，请稍后重试或缩小参数范围。",
                "workspace": self.workspace_state(),
                "options": self.workspace_options_state(),
            }

        stderr_text = (result.stderr or "").strip()
        if stderr_text:
            for line in stderr_text.splitlines()[-20:]:
                line = line.strip()
                if line:
                    self._append_log(f"[preview] {line}")

        stdout_text = (result.stdout or "").strip()
        if not stdout_text:
            self._append_log(
                f"[bridge] Workspace preview failed with empty output, exit code {result.returncode}.",
            )
            return {
                "ok": False,
                "message": "预览进程未返回结果。",
                "workspace": self.workspace_state(),
                "options": self.workspace_options_state(),
            }

        try:
            preview_result = json.loads(stdout_text)
        except json.JSONDecodeError:
            self._append_log(
                f"[bridge] Workspace preview returned invalid JSON, exit code {result.returncode}.",
            )
            return {
                "ok": False,
                "message": "预览结果解析失败。",
                "raw_output": stdout_text[:500],
                "workspace": self.workspace_state(),
                "options": self.workspace_options_state(),
            }

        if result.returncode != 0 or not preview_result.get("ok"):
            message = preview_result.get("message") or "预览生成失败。"
            self._append_log(f"[bridge] Workspace preview failed: {message}")
            return {
                "ok": False,
                "message": message,
                "workspace": self.workspace_state(),
                "options": self.workspace_options_state(),
            }

        self._append_log("[bridge] Workspace preview generated successfully.")
        preview_result["workspace"] = self.workspace_state()
        preview_result["options"] = {
            "version": 1,
            "target_media_type": self._workspace_target_media_type(),
            "options": request_payload["options"],
        }
        return preview_result

    def _normalize_source_paths(self, paths: Any) -> list[str]:
        if not isinstance(paths, list):
            return []
        normalized = []
        for item in paths:
            candidate = Path(str(item))
            if candidate.exists() and candidate.suffix.lower() in AUDIO_EXTENSIONS.union(IMAGE_EXTENSIONS):
                normalized.append(str(candidate))
        return normalized

    def _normalize_target_path(self, path: Any) -> str | None:
        if not path:
            return None
        candidate = Path(str(path))
        if candidate.exists() and candidate.suffix.lower() in IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS):
            return str(candidate)
        return None

    def _resolve_workspace_output_directory(self, target_path: str | None) -> str:
        if not target_path:
            return str(self._output_dir)
        target = Path(target_path)
        if target.suffix.lower() in IMAGE_EXTENSIONS:
            return str(self._output_dir / "img")
        if target.suffix.lower() in VIDEO_EXTENSIONS:
            return str(self._output_dir / "video")
        return str(self._output_dir)

    def _resolve_workspace_output_path(self, target_path: str, output_name: str) -> str:
        output_directory = Path(self._resolve_workspace_output_directory(target_path))
        output_directory.mkdir(parents=True, exist_ok=True)
        return str(output_directory / f"{output_name}{Path(target_path).suffix.lower()}")

    def _suggest_studio_job_id(self) -> str:
        return "studio-" + datetime.now().strftime("%Y-%m-%d-%H-%M-%S")

    def _find_workspace_source_thumbnail(self) -> str | None:
        for source_path in self._workspace_state.get("source_paths", []):
            thumbnail = self._resolve_thumbnail(source_path)
            if thumbnail:
                return thumbnail
        return None

    def _workspace_target_media_type(self) -> str | None:
        target_path = self._workspace_state.get("target_path")
        return self._media_type_for_path(target_path)

    def _media_type_for_path(self, file_path: str | None) -> str | None:
        if not file_path:
            return None
        suffix = Path(file_path).suffix.lower()
        if suffix in IMAGE_EXTENSIONS:
            return "image"
        if suffix in VIDEO_EXTENSIONS:
            return "video"
        if suffix in AUDIO_EXTENSIONS:
            return "audio"
        return None

    def _run_facefusion_cli(self, args: list[str]) -> bool:
        powershell_executable = self._resolve_powershell_executable()
        command = [
            powershell_executable,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.repo_root / "scripts" / "facefusion.ps1"),
            *args,
        ]
        self._append_log(f"[bridge] Running FaceFusion CLI: {' '.join(command)}")
        process = subprocess.run(
            command,
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            env=self._build_env(),
        )
        for raw_line in (process.stdout or "").splitlines():
            line = raw_line.rstrip()
            if line:
                self._append_log(line)
        for raw_line in (process.stderr or "").splitlines():
            line = raw_line.rstrip()
            if line:
                self._append_log(line)
        if process.returncode != 0:
            self._append_log(f"[bridge] FaceFusion CLI failed with exit code {process.returncode}.")
            return False
        return True

    def _resolve_facefusion_python_executable(self) -> str:
        candidates = [
            self.repo_root / ".venv-win" / "Scripts" / "python.exe",
            self.repo_root / ".bootstrap" / "nuget" / "python" / "tools" / "python.exe",
            Path(sys.executable),
        ]
        for candidate in candidates:
            if candidate.exists():
                return str(candidate)
        return sys.executable

    def _facefusion_bootstrap_code(self) -> str:
        return (
            "import os\n"
            "import runpy\n"
            "import sys\n"
            "try:\n"
            "    import onnxruntime as ort\n"
            "    if os.name == 'nt' and hasattr(ort, 'preload_dlls'):\n"
            "        ort.preload_dlls(directory='')\n"
            "except Exception as exception:\n"
            "    print(f'[WARN] onnxruntime preload_dlls failed: {exception}', file=sys.stderr)\n"
            "sys.argv = ['facefusion.py'] + sys.argv[1:]\n"
            "runpy.run_path('facefusion.py', run_name='__main__')\n"
        )

    def workspace_state(self) -> dict[str, Any]:
        with self._lock:
            source_paths = list(self._workspace_state.get("source_paths", []))
            target_path = self._workspace_state.get("target_path")

        return {
            "source_paths": source_paths,
            "target_path": target_path,
            "source_thumbnail": self._find_workspace_source_thumbnail(),
            "target_thumbnail": self._resolve_thumbnail(target_path),
            "target_media_type": self._workspace_target_media_type(),
            "output_root": str(self._output_dir),
            "output_directory": self._resolve_workspace_output_directory(target_path),
            "can_submit": bool(source_paths and target_path),
        }

    def set_workspace_source_paths(self, source_paths: list[str]) -> dict[str, Any]:
        normalized = self._normalize_source_paths(source_paths)
        with self._lock:
            self._workspace_state["source_paths"] = normalized
            self._save_workspace_state()
        self._append_log(f"[bridge] Updated workspace source paths: {len(normalized)} file(s).")
        return self.workspace_state()

    def clear_workspace_source_paths(self) -> dict[str, Any]:
        with self._lock:
            self._workspace_state["source_paths"] = []
            self._save_workspace_state()
        self._append_log("[bridge] Cleared workspace source paths.")
        return self.workspace_state()

    def set_workspace_target_path(self, target_path: str | None) -> dict[str, Any]:
        normalized = self._normalize_target_path(target_path)
        with self._lock:
            self._workspace_state["target_path"] = normalized
            self._save_workspace_state()
        self._append_log(f"[bridge] Updated workspace target path: {normalized or 'None'}.")
        return self.workspace_state()

    def clear_workspace_target_path(self) -> dict[str, Any]:
        with self._lock:
            self._workspace_state["target_path"] = None
            self._save_workspace_state()
        self._append_log("[bridge] Cleared workspace target path.")
        return self.workspace_state()

    def _create_workspace_job(self) -> tuple[str, str] | None:
        workspace = self.workspace_state()
        source_paths = workspace["source_paths"]
        target_path = workspace["target_path"]
        if not source_paths or not target_path:
            return None

        workspace_options = self.workspace_options_state()["options"]
        option_cli_args = self._workspace_step_option_cli_args(workspace_options)

        job_id = self._suggest_studio_job_id()
        output_path = self._resolve_workspace_output_path(target_path, job_id)
        job_commands = [
            ["job-create", job_id, "--jobs-path", str(self._jobs_dir)],
            [
                "job-add-step",
                job_id,
                "--jobs-path",
                str(self._jobs_dir),
                "--source-paths",
                *source_paths,
                "--target-path",
                target_path,
                "--output-path",
                output_path,
                *option_cli_args,
            ],
            ["job-submit", job_id, "--jobs-path", str(self._jobs_dir)],
        ]
        self._append_log(
            "[bridge] Workspace queue step options: "
            f"processors={workspace_options.get('processors')}, "
            f"face_swapper_model={workspace_options.get('face_swapper_model')}, "
            f"output_image_quality={workspace_options.get('output_image_quality')}, "
            f"output_video_encoder={workspace_options.get('output_video_encoder')}",
        )
        for command in job_commands:
            if not self._run_facefusion_cli(command):
                return None
        return job_id, output_path

    def queue_workspace(self) -> dict[str, Any]:
        job = self._create_workspace_job()
        if job is None:
            return {
                "ok": False,
                "message": "工作台源文件或目标文件无效。",
                "workspace": self.workspace_state(),
            }
        job_id, output_path = job
        self._append_log(f"[bridge] Workspace job queued: {job_id}")
        return {
            "ok": True,
            "job_id": job_id,
            "output_path": output_path,
            "workspace": self.workspace_state(),
            "queue": self.list_queue_tasks(),
        }

    def run_workspace(self) -> dict[str, Any]:
        queued = self.queue_workspace()
        if not queued.get("ok"):
            return queued
        queue_state = self.run_queue()
        queued["queue"] = queue_state
        return queued

    def _build_command(self) -> list[str]:
        return [
            self._resolve_facefusion_python_executable(),
            "-c",
            self._facefusion_bootstrap_code(),
            "run",
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

    def _resolve_powershell_executable(self) -> str:
        candidates = [
            r"C:\Program Files\PowerShell\7\pwsh.exe",
            r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "pwsh",
            "powershell",
        ]
        for candidate in candidates:
            if ":" in candidate:
                if Path(candidate).exists():
                    return candidate
            else:
                return candidate
        return "pwsh"

    def _build_runtime_path_entries(self) -> list[str]:
        entries = [
            r"C:\Windows\System32",
            str(self.repo_root / ".runtime" / "ffmpeg"),
            str(Path(sys.executable).resolve().parent),
        ]
        nvidia_root = self.repo_root / ".venv-win" / "Lib" / "site-packages" / "nvidia"
        if nvidia_root.exists():
            for path in sorted(nvidia_root.rglob("bin")):
                entries.append(str(path))
        return entries

    def _build_env(self) -> dict[str, str]:
        env = dict(os.environ)
        current_path = env.get("PATH", "")
        path_entries = self._build_runtime_path_entries()
        env["PATH"] = os.pathsep.join(path_entries + [current_path])
        ffmpeg_path = self.repo_root / ".runtime" / "ffmpeg" / "ffmpeg.exe"
        if ffmpeg_path.exists():
            env["FACEFUSION_FFMPEG_PATH"] = str(ffmpeg_path)
        env["FACEFUSION_CURL_PATH"] = r"C:\Windows\System32\curl.exe"
        env["FACEFUSION_UI_HOST"] = self.webui_bind_host
        env["FACEFUSION_UI_PORT"] = str(self._settings["facefusion_port"])
        self._apply_model_download_env(env)
        return env

    def _apply_model_download_env(self, env: dict[str, str]) -> None:
        mode = self._normalize_model_download_mode(self._settings.get("model_download_mode"))
        proxy_url = self._normalize_proxy_url(self._settings.get("custom_proxy_url"))
        proxy_keys = [
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy",
        ]

        env.pop("FACEFUSION_PROXY_URL", None)
        if mode == MODEL_DOWNLOAD_MODE_DOMESTIC:
            env["FACEFUSION_HUGGINGFACE_MIRRORS"] = DOMESTIC_HUGGINGFACE_MIRROR
            env["FACEFUSION_GITHUB_MIRRORS"] = OFFICIAL_GITHUB_URL
            env["FACEFUSION_DISABLE_PROXY"] = "1"
            env["NO_PROXY"] = "*"
            env["no_proxy"] = "*"
            for proxy_key in proxy_keys:
                env.pop(proxy_key, None)
            return

        env["FACEFUSION_HUGGINGFACE_MIRRORS"] = OFFICIAL_HUGGINGFACE_URL
        env["FACEFUSION_GITHUB_MIRRORS"] = OFFICIAL_GITHUB_URL
        env["FACEFUSION_DISABLE_PROXY"] = "0"
        env["NO_PROXY"] = LOCAL_NO_PROXY
        env["no_proxy"] = LOCAL_NO_PROXY

        if mode == MODEL_DOWNLOAD_MODE_CUSTOM_PROXY:
            env["FACEFUSION_PROXY_URL"] = proxy_url
            for proxy_key in proxy_keys:
                env[proxy_key] = proxy_url

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

    def _find_webui_process_pid(self) -> int | None:
        try:
            connections = psutil.net_connections(kind="tcp")
        except psutil.Error:
            return None

        target_port = int(self._settings["facefusion_port"])
        target_host = self.webui_bind_host

        for connection in connections:
            if not connection.pid or not connection.laddr:
                continue
            if connection.status != psutil.CONN_LISTEN:
                continue
            if connection.laddr.port != target_port:
                continue
            if connection.laddr.ip not in {target_host, "0.0.0.0", "::", "::1"}:
                continue
            return connection.pid
        return None

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

            adopted_pid = self._find_webui_process_pid()
            if adopted_pid and self._is_webui_ready():
                self._state = "ready"
                self._status_message = "FaceFusion WebUI is already running."
                if not self._started_at:
                    self._started_at = datetime.now().isoformat(timespec="seconds")
                self._append_log(
                    f"[bridge] Reusing existing FaceFusion WebUI process on port {self._settings['facefusion_port']} (pid {adopted_pid}).",
                )
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
                adopted_pid = self._find_webui_process_pid()
                if adopted_pid:
                    self._append_log(f"[bridge] Stop requested for adopted FaceFusion process {adopted_pid}.")
                    self._terminate_process_tree(adopted_pid)
                    self._process = None
                    self._state = "stopped"
                    self._status_message = "FaceFusion stopped."
                    return self.status()
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
            self._append_log(
                f"[bridge] Opened browser at {self.webui_url} (bind: {self.webui_bind_url})",
            )
            return {"ok": True, "url": self.webui_url, "bind_url": self.webui_bind_url}
        return {
            "ok": False,
            "url": self.webui_url,
            "bind_url": self.webui_bind_url,
            "message": "FaceFusion WebUI is not ready.",
        }

    def _refresh_state_locked(self) -> None:
        if self._process and self._process.poll() is None:
            if self._is_webui_ready():
                self._state = "ready"
                self._status_message = "FaceFusion WebUI is ready."
            elif self._state != "stopping":
                self._state = "starting"
                self._status_message = "FaceFusion is starting."
        elif self._is_webui_ready():
            self._state = "ready"
            self._status_message = "FaceFusion WebUI is ready."
        elif self._state != "stopped":
            self._state = "stopped"
            self._status_message = "FaceFusion is not running."

    def _refresh_state(self) -> None:
        with self._lock:
            self._refresh_state_locked()

    def status(self) -> dict[str, Any]:
        with self._lock:
            self._refresh_state_locked()
            pid = self._process.pid if self._process and self._process.poll() is None else self._find_webui_process_pid()
            return {
                "state": self._state,
                "is_running": self._state in {"starting", "ready", "stopping"},
                "is_ready": self._state == "ready",
                "status_message": self._status_message,
                "pid": pid,
                "webui_url": self.webui_url,
                "webui_bind_host": self.webui_bind_host,
                "webui_bind_url": self.webui_bind_url,
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
            if after > 0:
                items = [item for item in self._logs if item["id"] > after]
            else:
                items = list(self._logs)
                if limit > 0:
                    items = items[-limit:]
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
                        "source_media_type": self._media_type_for_path(source_paths[0] if source_paths else None),
                        "target_path": target_path,
                        "target_thumbnail": self._resolve_thumbnail(target_path),
                        "target_media_type": self._media_type_for_path(target_path),
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
            self._resolve_powershell_executable(),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.repo_root / "scripts" / "facefusion.ps1"),
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

    def _resolve_ffmpeg_for_thumbnail(self) -> str | None:
        self._ensure_bundled_ffmpeg()
        bundled_ffmpeg = self._bundled_ffmpeg_executable()
        if bundled_ffmpeg.exists():
            return str(bundled_ffmpeg)
        system_ffmpeg = shutil.which("ffmpeg")
        if system_ffmpeg:
            return system_ffmpeg
        return None

    def _thumbnail_cache_path(self, file_path: Path) -> Path | None:
        try:
            stat = file_path.stat()
            resolved_path = file_path.resolve()
        except OSError:
            return None
        cache_key = hashlib.sha1(
            f"{resolved_path}|{stat.st_mtime_ns}|{stat.st_size}".encode("utf-8"),
        ).hexdigest()
        return self._thumbnail_dir / f"{cache_key}.png"

    def _generate_video_thumbnail(self, file_path: Path, thumbnail_path: Path) -> bool:
        ffmpeg_path = self._resolve_ffmpeg_for_thumbnail()
        if not ffmpeg_path:
            self._append_log("[bridge] Unable to generate video thumbnail: ffmpeg was not found.")
            return False

        thumbnail_path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = thumbnail_path.with_suffix(".tmp.png")
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)

        command = [
            ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(file_path),
            "-frames:v",
            "1",
            "-vf",
            "scale=640:-2",
            str(temp_path),
        ]
        result = subprocess.run(
            command,
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            timeout=45,
        )
        if result.returncode == 0 and temp_path.exists() and temp_path.stat().st_size > 0:
            temp_path.replace(thumbnail_path)
            return True

        temp_path.unlink(missing_ok=True)
        message = (result.stderr or result.stdout or "").strip()
        if message:
            self._append_log(f"[bridge] Video thumbnail generation failed: {message.splitlines()[-1]}")
        else:
            self._append_log(f"[bridge] Video thumbnail generation failed for {file_path}")
        return False

    def _resolve_video_thumbnail(self, file_path: Path) -> str | None:
        thumbnail_path = self._thumbnail_cache_path(file_path)
        if thumbnail_path is None:
            return None
        if thumbnail_path.exists() and thumbnail_path.stat().st_size > 0:
            return str(thumbnail_path)
        if self._generate_video_thumbnail(file_path, thumbnail_path):
            return str(thumbnail_path)
        return None

    def _resolve_thumbnail(self, file_path: str | None) -> str | None:
        if not file_path:
            return None
        candidate = Path(file_path)
        if not candidate.exists():
            return None
        extension = candidate.suffix.lower()
        if extension in IMAGE_EXTENSIONS:
            return str(candidate)
        if extension in VIDEO_EXTENSIONS:
            return self._resolve_video_thumbnail(candidate)
        return None

    def get_settings(self) -> dict[str, Any]:
        return dict(self._settings)

    def update_settings(self, payload: dict[str, Any]) -> dict[str, Any]:
        if "theme" in payload and payload["theme"] in {"dark", "light"}:
            self._settings["theme"] = payload["theme"]
        if "default_output_dir" in payload and payload["default_output_dir"]:
            self._settings["default_output_dir"] = str(payload["default_output_dir"])
            self._apply_output_root(self._settings["default_output_dir"])
        if "model_download_mode" in payload:
            self._settings["model_download_mode"] = self._normalize_model_download_mode(
                payload["model_download_mode"]
            )
        if "custom_proxy_url" in payload:
            self._settings["custom_proxy_url"] = self._normalize_proxy_url(payload["custom_proxy_url"])
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
                    "thumbnail_path": self._resolve_thumbnail(path_str),
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
app = FastAPI(title="FaceSwap Studio Bridge", version="0.4.0")


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


@app.get("/models/bootstrap")
def models_bootstrap_status() -> dict[str, Any]:
    return runtime.get_model_bootstrap_status()


@app.post("/models/bootstrap/start")
def models_bootstrap_start() -> dict[str, Any]:
    return runtime.start_model_bootstrap()


@app.get("/updates/status")
def updates_status() -> dict[str, Any]:
    return runtime.update_status()


@app.post("/updates/check")
def updates_check() -> dict[str, Any]:
    return runtime.check_updates()


@app.post("/updates/download")
def updates_download() -> dict[str, Any]:
    return runtime.download_update()


@app.post("/updates/apply")
def updates_apply() -> dict[str, Any]:
    return runtime.apply_update()


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


@app.get("/workspace/draft")
def workspace_draft() -> dict[str, Any]:
    return runtime.workspace_state()


@app.get("/workspace/options/schema")
def workspace_options_schema() -> dict[str, Any]:
    return runtime.workspace_options_schema()


@app.get("/workspace/options")
def workspace_options_get() -> dict[str, Any]:
    return runtime.workspace_options_state()


@app.put("/workspace/options")
def workspace_options_put(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.update_workspace_options(payload)


@app.delete("/workspace/options")
def workspace_options_delete() -> dict[str, Any]:
    return runtime.clear_workspace_options()


@app.post("/workspace/preview")
def workspace_preview(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.preview_workspace(payload)


@app.put("/workspace/draft/source-paths")
def workspace_source_paths_put(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.set_workspace_source_paths(payload.get("paths") or [])


@app.delete("/workspace/draft/source-paths")
def workspace_source_paths_delete() -> dict[str, Any]:
    return runtime.clear_workspace_source_paths()


@app.put("/workspace/draft/target-path")
def workspace_target_path_put(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.set_workspace_target_path(payload.get("path"))


@app.delete("/workspace/draft/target-path")
def workspace_target_path_delete() -> dict[str, Any]:
    return runtime.clear_workspace_target_path()


@app.post("/workspace/queue")
def workspace_queue() -> dict[str, Any]:
    return runtime.queue_workspace()


@app.post("/workspace/run")
def workspace_run() -> dict[str, Any]:
    return runtime.run_workspace()


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
