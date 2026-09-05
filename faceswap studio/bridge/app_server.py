from __future__ import annotations

from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from typing import Any, AsyncIterator
from urllib.parse import quote, urlparse
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener, getproxies, urlopen
import webbrowser

BRIDGE_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(BRIDGE_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_REPO_ROOT))

import facefusion.choices as facefusion_choices
from facefusion import metadata as facefusion_metadata
from facefusion.filesystem import get_file_extension
from facefusion.processors.modules.age_modifier import choices as age_modifier_choices
from facefusion.processors.modules.background_remover import choices as background_remover_choices
from facefusion.processors.modules.deep_swapper import choices as deep_swapper_choices
from facefusion.processors.modules.expression_restorer import choices as expression_restorer_choices
from facefusion.processors.modules.face_debugger import choices as face_debugger_choices
from facefusion.processors.modules.face_editor import choices as face_editor_choices
from facefusion.processors.modules.face_enhancer import choices as face_enhancer_choices
from facefusion.processors.modules.face_swapper import choices as face_swapper_choices
from facefusion.processors.modules.frame_colorizer import choices as frame_colorizer_choices
from facefusion.processors.modules.frame_enhancer import choices as frame_enhancer_choices
from facefusion.processors.modules.lip_syncer import choices as lip_syncer_choices
from facefusion.uis import choices as ui_choices
from facefusion.vision import count_video_frame_total
from fastapi import FastAPI, File, HTTPException, Query, Request as FastAPIRequest, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse
import psutil


def get_output_file_extension(target_path: str, output_video_encoder: str | None = None) -> str | None:
    """Return the output container extension expected by Studio.

    FaceFusion 3.8.x removed the project-specific helper from
    ``facefusion.filesystem``.  Keep this small compatibility shim in the
    Bridge so a core update cannot make the service fail during import.
    ProRes KS is the one encoder that must switch a video target to a MOV
    container; all other formats retain the target extension.
    """
    target_extension = get_file_extension(target_path)
    if not target_extension:
        return None
    target_format = target_extension.lstrip(".")
    if target_format in facefusion_choices.video_formats and output_video_encoder == "prores_ks":
        return ".mov"
    return target_extension


BRIDGE_HOST = os.environ.get("FACESWAP_STUDIO_BRIDGE_HOST", "127.0.0.1")
BRIDGE_PORT = 52741
FACEFUSION_UI_HOST = "0.0.0.0"
FACEFUSION_UI_PORT = 7860
FACEFUSION_LOCAL_HOST = "127.0.0.1"
FACEFUSION_WILDCARD_HOSTS = {"0.0.0.0", "::", "[::]"}
LOG_LIMIT = 2000
JOB_STATUSES = ["drafted", "queued", "completed", "failed"]
AUDIO_EXTENSIONS = {".mp3", ".wav", ".aac", ".flac", ".ogg", ".m4a", ".opus"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".mpeg", ".m4v"}
FFMPEG_SOURCE_ENV = "FACESWAP_STUDIO_FFMPEG_SOURCE"
FFMPEG_VERSION_FILE = "ffmpeg-source.json"
DEFAULT_OUTPUT_DIR_VALUE = "${studio_root}\\data\\output"
QUEUE_PROGRESS_PATTERN = re.compile(r"\b(extracting|processing|merging)\b.*?(\d{1,3})\s*%", re.IGNORECASE)
QUEUE_PROGRESS_PHASES = ("extracting", "processing", "merging")
QUEUE_VIDEO_PHASE_RANGES = {
    "extracting": (0.0, 20.0),
    "processing": (20.0, 65.0),
    "merging": (85.0, 15.0),
}
QUEUE_CANCELLED_EXIT_CODE = -9999
MODEL_DOWNLOAD_MODE_DOMESTIC = "domestic_mirror"
MODEL_DOWNLOAD_MODE_SYSTEM_PROXY = "system_proxy"
MODEL_DOWNLOAD_MODE_CUSTOM_PROXY = "custom_proxy"
MODEL_DOWNLOAD_MODES = {
    MODEL_DOWNLOAD_MODE_DOMESTIC,
    MODEL_DOWNLOAD_MODE_SYSTEM_PROXY,
    MODEL_DOWNLOAD_MODE_CUSTOM_PROXY,
}
WINDOW_CLOSE_BEHAVIOR_MINIMIZE_TO_TRAY = "minimize_to_tray"
WINDOW_CLOSE_BEHAVIOR_EXIT = "exit"
WINDOW_CLOSE_BEHAVIORS = {
    WINDOW_CLOSE_BEHAVIOR_MINIMIZE_TO_TRAY,
    WINDOW_CLOSE_BEHAVIOR_EXIT,
}
DEFAULT_CUSTOM_PROXY_URL = "http://127.0.0.1:7890"
DEFAULT_CONTENT_ANALYSER_SCORE = 100.0
DEFAULT_WORKSPACE_OPTIONS_PANEL_WIDTH = 430.0
MIN_WORKSPACE_OPTIONS_PANEL_WIDTH = 320.0
MAX_WORKSPACE_OPTIONS_PANEL_WIDTH = 760.0
DOMESTIC_HUGGINGFACE_MIRROR = "https://hf-mirror.com"
OFFICIAL_HUGGINGFACE_URL = "https://huggingface.co"
OFFICIAL_GITHUB_URL = "https://github.com"
LOCAL_NO_PROXY = "localhost,127.0.0.1,::1"
CORE_MODEL_SCOPE = "core"
CORE_MODEL_USER_AGENT = "FaceSwap Studio Model Bootstrap/1.0"
UPDATE_USER_AGENT = "FaceSwap Studio Updater/1.0"
UPDATE_REPOSITORY = "luojiang419/faceswap-studio"
FACEFUSION_CORE_REPOSITORY = "facefusion/facefusion"
CORE_UPDATE_PAYLOAD_NAMES = ("facefusion", "facefusion.py", "requirements.txt", "install.py")
UPDATE_MANIFEST_ASSET = "update-manifest.json"
UPDATE_CACHE_DIRNAME = "FaceSwap Studio"
STUDIO_ROOT_CHILD_NAMES = {
    "bridge",
    "config",
    "data",
    "flutter_app",
    "launcher",
    "runtime",
}
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
        self._workspace_run_lock = threading.Lock()
        self._queue_runner_thread: threading.Thread | None = None
        self._queue_runner_active = False
        self._queue_current_job_id: str | None = None
        self._queue_current_process: subprocess.Popen[str] | None = None
        self._queue_total_jobs = 0
        self._queue_completed_jobs = 0
        self._queue_last_error: str | None = None
        self._queue_progress_by_job: dict[str, dict[str, Any]] = {}
        self._queue_cancel_requested_job_ids: set[str] = set()
        self._last_cli_error: str | None = None
        self._last_workspace_job_error: str | None = None
        self._preview_lock = threading.Lock()
        self._workspace_state: dict[str, Any] = {}
        self._workspace_options: dict[str, Any] = {}
        self._workspace_video_frame_total_cache: dict[str, int | None] = {}
        self._works_metadata: dict[str, dict[str, Any]] = {}
        self._model_bootstrap_lock = threading.RLock()
        self._model_bootstrap_thread: threading.Thread | None = None
        self._update_lock = threading.RLock()
        self._update_download_thread: threading.Thread | None = None
        self._core_update_download_thread: threading.Thread | None = None

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
        self._personas_dir = studio_root / "data" / "personas"
        self._extracted_faces_dir = studio_root / "data" / "input" / "extracted_faces"
        self._settings_template_path = studio_root / "config" / "settings.json"
        self._favorites_path = studio_root / "data" / "favorites" / "favorites.json"
        self._runtime_dir = studio_root / "runtime"
        self._settings_path = self._runtime_dir / "settings.json"
        self._models_dir = self._repo_root / ".assets" / "models"
        self._thumbnail_dir = studio_root / "data" / "cache" / "thumbnails"
        self._playback_dir = studio_root / "data" / "cache" / "playback"
        self._studio_uploads_dir = studio_root / "data" / "uploads" / "workspace"
        self._flutter_web_root = studio_root / "flutter_app" / "build" / "web"
        self._workspace_state_path = self._runtime_dir / "workspace_state.json"
        self._workspace_options_path = self._runtime_dir / "workspace_options.json"
        self._works_metadata_path = self._runtime_dir / "works_metadata.json"

        for directory in [
            self._jobs_dir,
            self._temp_dir,
            self._personas_dir,
            self._extracted_faces_dir,
            self._models_dir,
            self._thumbnail_dir,
            self._playback_dir,
            self._studio_uploads_dir,
            self._runtime_dir,
            self._settings_template_path.parent,
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
        self._works_metadata = self._load_works_metadata()

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

    def _ffmpeg_has_video_encoder(self, ffmpeg_path: Path, encoder: str = "libx264") -> bool:
        if not ffmpeg_path.exists() or not ffmpeg_path.is_file():
            return False
        try:
            result = subprocess.run(
                [str(ffmpeg_path), "-hide_banner", "-encoders"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                timeout=8,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        output = f"{result.stdout}\n{result.stderr}".lower()
        return result.returncode == 0 and encoder.lower() in output

    def _read_ffmpeg_marker(self) -> dict[str, Any]:
        marker_path = self._bundled_ffmpeg_marker()
        if not marker_path.exists():
            return {}
        try:
            payload = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _resolve_ffmpeg_source(self) -> Path | None:
        candidates: list[Path] = []
        env_source = os.environ.get(FFMPEG_SOURCE_ENV)
        if env_source:
            candidates.append(Path(env_source))

        system_ffmpeg = shutil.which("ffmpeg")
        if system_ffmpeg:
            candidates.append(Path(system_ffmpeg))

        candidates.extend(
            [
                Path(r"C:\ProgramData\chocolatey\lib\ffmpeg\tools\ffmpeg\bin\ffmpeg.exe"),
                self.repo_root / "build" / "installer" / "app" / ".runtime" / "ffmpeg" / "ffmpeg.exe",
            ],
        )

        target_path = self._bundled_ffmpeg_executable()
        for candidate in candidates:
            if not candidate.exists() or not candidate.is_file():
                continue
            try:
                if os.name == "nt" and candidate.stat().st_size < 5_000_000:
                    self._append_log(f"[bridge] Skipping ffmpeg launcher shim: {candidate}")
                    continue
            except OSError:
                continue
            try:
                if candidate.resolve() == target_path.resolve():
                    continue
            except OSError:
                pass
            if not self._ffmpeg_has_video_encoder(candidate):
                self._append_log(f"[bridge] Skipping unusable ffmpeg candidate: {candidate}")
                continue
            return candidate
        return None

    def _ensure_bundled_ffmpeg(self) -> None:
        target_path = self._bundled_ffmpeg_executable()
        marker_path = self._bundled_ffmpeg_marker()
        target_usable = self._ffmpeg_has_video_encoder(target_path)
        if target_path.exists() and not target_usable:
            self._append_log(f"[bridge] Bundled ffmpeg is unusable and will be replaced: {target_path}")
        ffmpeg_source = self._resolve_ffmpeg_source()
        if ffmpeg_source is None:
            if not target_path.exists():
                self._append_log(
                    f"[bridge] ffmpeg was not found. Set {FFMPEG_SOURCE_ENV} or add ffmpeg to PATH."
                )
            elif not target_usable:
                self._append_log(
                    f"[bridge] ffmpeg cannot list video encoders. Set {FFMPEG_SOURCE_ENV} to a full ffmpeg.exe."
                )
            return

        try:
            source_metadata = self._ffmpeg_source_metadata(ffmpeg_source)
        except OSError as error:
            self._append_log(f"[bridge] Unable to inspect local ffmpeg source: {error}")
            return

        marker_payload = self._read_ffmpeg_marker()
        marker_metadata = {
            "source_path": marker_payload.get("source_path"),
            "size_bytes": marker_payload.get("size_bytes"),
            "modified_at": marker_payload.get("modified_at"),
        }
        should_copy = (
            not target_usable
            or not target_path.exists()
            or not marker_path.exists()
            or marker_metadata != source_metadata
        )
        if not should_copy:
            return

        try:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ffmpeg_source, target_path)
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
            self._append_log(f"[bridge] Failed to copy ffmpeg from {ffmpeg_source}: {error}")

    def _default_output_dir(self) -> str:
        return str(self._studio_root / "data" / "output")

    def _normalize_output_dir(self, value: Any) -> str:
        raw_path = str(value or "").strip()
        if not raw_path:
            return self._default_output_dir()

        studio_root = str(self._studio_root)
        expanded_path = (
            raw_path.replace("${studio_root}", studio_root)
            .replace("{studio_root}", studio_root)
            .replace("%STUDIO_ROOT%", studio_root)
        )
        expanded_path = os.path.expandvars(os.path.expanduser(expanded_path))
        output_path = Path(expanded_path)
        if not output_path.is_absolute():
            output_path = self._studio_root / output_path
        return str(output_path)

    def _is_default_output_dir(self, output_dir: Any) -> bool:
        normalized_output_dir = os.path.normcase(os.path.abspath(str(output_dir or "")))
        normalized_default_dir = os.path.normcase(os.path.abspath(self._default_output_dir()))
        return normalized_output_dir == normalized_default_dir

    def _settings_payload_for_disk(self, settings: dict[str, Any]) -> dict[str, Any]:
        payload = dict(settings)
        if self._is_default_output_dir(payload.get("default_output_dir")):
            payload["default_output_dir"] = DEFAULT_OUTPUT_DIR_VALUE
        return payload

    def _default_settings(self) -> dict[str, Any]:
        return {
            "theme": "dark",
            "facefusion_host": FACEFUSION_UI_HOST,
            "facefusion_port": FACEFUSION_UI_PORT,
            "default_output_dir": self._default_output_dir(),
            "model_download_mode": MODEL_DOWNLOAD_MODE_DOMESTIC,
            "custom_proxy_url": DEFAULT_CUSTOM_PROXY_URL,
            "close_behavior": WINDOW_CLOSE_BEHAVIOR_MINIMIZE_TO_TRAY,
            "sidebar_expanded": False,
            "content_analyser_score": DEFAULT_CONTENT_ANALYSER_SCORE,
            "workspace_options_panel_width": DEFAULT_WORKSPACE_OPTIONS_PANEL_WIDTH,
        }

    def _read_settings_file(self, settings_path: Path) -> dict[str, Any]:
        if not settings_path.exists():
            return {}

        try:
            payload = json.loads(settings_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _normalize_settings(self, payload: dict[str, Any]) -> dict[str, Any]:
        defaults = self._default_settings()
        return {
            "theme": str(payload.get("theme") or defaults["theme"]),
            "facefusion_host": str(payload.get("facefusion_host") or defaults["facefusion_host"]),
            "facefusion_port": int(payload.get("facefusion_port") or defaults["facefusion_port"]),
            "default_output_dir": self._normalize_output_dir(payload.get("default_output_dir")),
            "model_download_mode": self._normalize_model_download_mode(payload.get("model_download_mode")),
            "custom_proxy_url": self._normalize_proxy_url(payload.get("custom_proxy_url")),
            "close_behavior": self._normalize_close_behavior(payload.get("close_behavior")),
            "sidebar_expanded": payload.get("sidebar_expanded") is True,
            "content_analyser_score": self._normalize_content_analyser_score(payload.get("content_analyser_score")),
            "workspace_options_panel_width": self._normalize_workspace_options_panel_width(
                payload.get("workspace_options_panel_width")
            ),
        }

    def _write_settings_template(self, settings: dict[str, Any]) -> None:
        self._settings_template_path.write_text(
            json.dumps(self._settings_payload_for_disk(settings), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _write_settings(self, settings: dict[str, Any]) -> None:
        self._settings_path.write_text(
            json.dumps(self._settings_payload_for_disk(settings), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _load_settings(self) -> dict[str, Any]:
        defaults = self._default_settings()
        template_payload = self._read_settings_file(self._settings_template_path)
        runtime_payload = self._read_settings_file(self._settings_path)
        merged = self._normalize_settings(
            {
                **defaults,
                **template_payload,
                **runtime_payload,
            }
        )
        if not self._settings_template_path.exists():
            self._write_settings_template(defaults)
        self._write_settings(merged)
        return merged

    def _save_settings(self) -> None:
        self._write_settings(self._settings)

    def _normalize_model_download_mode(self, value: Any) -> str:
        mode = str(value or MODEL_DOWNLOAD_MODE_DOMESTIC).strip()
        if mode in MODEL_DOWNLOAD_MODES:
            return mode
        return MODEL_DOWNLOAD_MODE_DOMESTIC

    def _normalize_proxy_url(self, value: Any) -> str:
        proxy_url = str(value or DEFAULT_CUSTOM_PROXY_URL).strip()
        return proxy_url or DEFAULT_CUSTOM_PROXY_URL

    def _normalize_close_behavior(self, value: Any) -> str:
        behavior = str(value or WINDOW_CLOSE_BEHAVIOR_MINIMIZE_TO_TRAY).strip()
        if behavior in WINDOW_CLOSE_BEHAVIORS:
            return behavior
        return WINDOW_CLOSE_BEHAVIOR_MINIMIZE_TO_TRAY

    def _normalize_content_analyser_score(self, value: Any) -> float:
        if not hasattr(facefusion_choices, "content_analyser_score_range"):
            return DEFAULT_CONTENT_ANALYSER_SCORE
        try:
            candidate = float(value)
        except (TypeError, ValueError):
            return DEFAULT_CONTENT_ANALYSER_SCORE
        if self._choice_contains_float(list(facefusion_choices.content_analyser_score_range), candidate):
            return candidate
        return DEFAULT_CONTENT_ANALYSER_SCORE

    def _normalize_workspace_options_panel_width(self, value: Any) -> float:
        try:
            candidate = float(value)
        except (TypeError, ValueError):
            return DEFAULT_WORKSPACE_OPTIONS_PANEL_WIDTH
        return float(
            max(
                MIN_WORKSPACE_OPTIONS_PANEL_WIDTH,
                min(MAX_WORKSPACE_OPTIONS_PANEL_WIDTH, round(candidate, 1)),
            ),
        )

    def _content_analyser_cli_args(self) -> list[str]:
        if not hasattr(facefusion_choices, "content_analyser_score_range"):
            return []
        content_analyser_score = self._normalize_content_analyser_score(
            self._settings.get("content_analyser_score"),
        )
        return ["--content-analyser-score", str(content_analyser_score)]

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
        return self._network_opener(disable_proxy_for_domestic=True)

    def _system_proxy_opener(self):
        proxies = getproxies()
        if proxies:
            return build_opener(ProxyHandler(proxies))
        return build_opener()

    def _network_opener(self, disable_proxy_for_domestic: bool = False):
        mode = self._normalize_model_download_mode(self._settings.get("model_download_mode"))
        proxy_url = self._normalize_proxy_url(self._settings.get("custom_proxy_url"))
        if mode == MODEL_DOWNLOAD_MODE_CUSTOM_PROXY:
            return build_opener(ProxyHandler({"http": proxy_url, "https": proxy_url}))
        if mode == MODEL_DOWNLOAD_MODE_SYSTEM_PROXY:
            return self._system_proxy_opener()
        if mode == MODEL_DOWNLOAD_MODE_DOMESTIC and disable_proxy_for_domestic:
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

    def _read_facefusion_core_version(self) -> str:
        return str(facefusion_metadata.get("version") or "0.0.0")

    def _default_core_update_state(self) -> dict[str, Any]:
        return {
            "name": "FaceFusion 核心",
            "state": "idle",
            "message": "尚未检查 FaceFusion 核心更新。",
            "current_version": self._read_facefusion_core_version(),
            "latest_version": None,
            "update_available": False,
            "release_url": None,
            "archive_url": None,
            "package_path": None,
            "backup_path": None,
            "downloaded_bytes": 0,
            "total_bytes": 0,
            "percent": 0.0,
            "speed_bps": 0.0,
            "repository": os.environ.get("FACESWAP_STUDIO_FACEFUSION_REPOSITORY", FACEFUSION_CORE_REPOSITORY),
            "error": None,
            "checked_at": None,
            "completed_at": None,
        }

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
            "scheduled_for_next_launch": False,
            "scheduled_at": None,
            "pending_package_path": None,
            "core_update": self._default_core_update_state(),
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

    def _pending_update_marker_path(self) -> Path:
        return self._updates_root() / "pending-update.json"

    def _clear_pending_update_marker(self) -> None:
        marker_path = self._pending_update_marker_path()
        try:
            if marker_path.exists():
                marker_path.unlink()
        except OSError as error:
            self._append_log(f"[bridge] Failed to clear pending update marker: {error}")

    def _read_pending_update_marker(self) -> dict[str, Any] | None:
        marker_path = self._pending_update_marker_path()
        if not marker_path.exists():
            return None

        try:
            payload = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            self._append_log(f"[bridge] Pending update marker is invalid and will be removed: {error}")
            self._clear_pending_update_marker()
            return None

        if not isinstance(payload, dict):
            self._append_log("[bridge] Pending update marker is not an object and will be removed.")
            self._clear_pending_update_marker()
            return None

        version = str(payload.get("version") or "").strip()
        package_path = str(payload.get("package_path") or "").strip()
        if not version or not package_path:
            self._append_log("[bridge] Pending update marker is missing required fields and will be removed.")
            self._clear_pending_update_marker()
            return None

        return {
            "version": version,
            "package_path": package_path,
            "restart_path": str(payload.get("restart_path") or "").strip(),
            "root_path": str(payload.get("root_path") or "").strip(),
            "scheduled_at": str(payload.get("scheduled_at") or "").strip() or None,
        }

    def _write_pending_update_marker(self, package_path: Path, version: str) -> dict[str, Any]:
        marker_path = self._pending_update_marker_path()
        marker_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": version,
            "package_path": str(package_path),
            "restart_path": str(self.repo_root / "启动FaceSwap Studio.exe"),
            "root_path": str(self.repo_root),
            "scheduled_at": datetime.now().isoformat(timespec="seconds"),
        }
        marker_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return payload

    def _apply_pending_update_marker_to_state(self, state: dict[str, Any]) -> dict[str, Any]:
        marker = self._read_pending_update_marker()
        if not marker:
            state["scheduled_for_next_launch"] = False
            state["scheduled_at"] = None
            state["pending_package_path"] = None
            return state

        marker_version = str(marker.get("version") or "").strip()
        marker_path = Path(str(marker.get("package_path") or ""))
        current_version = str(state.get("current_version") or self._read_app_version())
        if not marker_version or not marker_path.exists() or not self._is_newer_version(marker_version, current_version):
            self._clear_pending_update_marker()
            state["scheduled_for_next_launch"] = False
            state["scheduled_at"] = None
            state["pending_package_path"] = None
            return state

        state["scheduled_for_next_launch"] = True
        state["scheduled_at"] = marker.get("scheduled_at")
        state["pending_package_path"] = str(marker_path)
        state["package_path"] = str(state.get("package_path") or marker_path)
        if not state.get("latest_version"):
            state["latest_version"] = marker_version
        if not state.get("asset_name"):
            state["asset_name"] = marker_path.name
        if state.get("state") in {"idle", "current"}:
            state["state"] = "downloaded"
            state["message"] = "更新包已下载，并安排在下次启动时安装。"
        return state

    def _update_opener(self):
        return self._network_opener(disable_proxy_for_domestic=True)

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

    def _check_facefusion_core_update(self) -> dict[str, Any]:
        state = self._default_core_update_state()
        state.update(
            {
                "state": "checking",
                "message": "正在检查 FaceFusion 核心更新...",
                "checked_at": datetime.now().isoformat(timespec="seconds"),
            }
        )
        try:
            repository = str(state["repository"])
            release_api_url = f"https://api.github.com/repos/{repository}/releases/latest"
            release = self._download_json(release_api_url)
            latest_version = str(release.get("tag_name") or release.get("name") or "").lstrip("v")
            if not latest_version:
                raise RuntimeError("FaceFusion latest release does not contain a version.")

            current_version = self._read_facefusion_core_version()
            update_available = self._is_newer_version(latest_version, current_version)
            state.update(
                {
                    "state": "update_available" if update_available else "current",
                    "message": f"发现 FaceFusion 核心新版本 {latest_version}。"
                    if update_available
                    else "FaceFusion 核心已是当前可检测到的最新版本。",
                    "current_version": current_version,
                    "latest_version": latest_version,
                    "update_available": update_available,
                    "release_url": release.get("html_url"),
                    "archive_url": release.get("zipball_url"),
                    "error": None,
                }
            )
        except Exception as error:
            state.update(
                {
                    "state": "failed",
                    "message": "FaceFusion 核心更新检查失败。",
                    "update_available": False,
                    "error": str(error),
                }
            )
            self._append_log(f"[bridge] FaceFusion core update check failed: {error}")
        return state

    def _set_core_update_state(self, **updates: Any) -> dict[str, Any]:
        with self._update_lock:
            core_update = dict(self._update_state.get("core_update") or self._default_core_update_state())
            core_update.update(updates)
            self._update_state["core_update"] = core_update
            return dict(core_update)

    def _core_updates_root(self) -> Path:
        return self._updates_root() / "facefusion-core"

    def download_core_update(self) -> dict[str, Any]:
        state = self.update_status()
        core_update = dict(state.get("core_update") or {})
        if core_update.get("state") in {"idle", "failed", "current"}:
            state = self.check_updates()
            core_update = dict(state.get("core_update") or {})
        if not core_update.get("update_available"):
            return self.update_status()

        with self._update_lock:
            if self._core_update_download_thread and self._core_update_download_thread.is_alive():
                return self.update_status()
            self._set_core_update_state(
                state="downloading",
                message="正在下载 FaceFusion 核心源码包...",
                downloaded_bytes=0,
                percent=0.0,
                speed_bps=0.0,
                error=None,
            )
            self._core_update_download_thread = threading.Thread(
                target=self._download_core_update_worker,
                daemon=True,
            )
            self._core_update_download_thread.start()
            return self.update_status()

    def _download_core_update_worker(self) -> None:
        state = self.update_status()
        core_update = dict(state.get("core_update") or {})
        archive_url = str(core_update.get("archive_url") or "")
        latest_version = str(core_update.get("latest_version") or "unknown")
        if not archive_url:
            self._set_core_update_state(
                state="failed",
                message="FaceFusion 核心源码包地址缺失。",
                error="Missing FaceFusion archive URL.",
            )
            return

        target_dir = self._core_updates_root() / latest_version
        target_dir.mkdir(parents=True, exist_ok=True)
        target_path = target_dir / f"facefusion-{latest_version}.zip"
        temp_path = target_path.with_suffix(".zip.download")

        try:
            if temp_path.exists():
                temp_path.unlink()
            request = Request(archive_url, headers={"User-Agent": UPDATE_USER_AGENT})
            started_at = time.monotonic()
            downloaded = 0
            expected_size = 0
            with self._update_opener().open(request, timeout=30) as response, open(temp_path, "wb") as output:
                content_length = response.headers.get("Content-Length")
                if content_length:
                    try:
                        expected_size = int(content_length)
                    except ValueError:
                        expected_size = 0
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
                    self._set_core_update_state(
                        downloaded_bytes=downloaded,
                        total_bytes=expected_size,
                        percent=percent,
                        speed_bps=speed if speed > 0 else downloaded / elapsed,
                    )

            if expected_size > 0 and downloaded < expected_size:
                raise RuntimeError("Downloaded FaceFusion core package is incomplete.")
            temp_path.replace(target_path)
            self._set_core_update_state(
                state="downloaded",
                message="FaceFusion 核心源码包下载完成。",
                package_path=str(target_path),
                downloaded_bytes=downloaded,
                total_bytes=expected_size or downloaded,
                percent=100.0,
                speed_bps=0.0,
                completed_at=datetime.now().isoformat(timespec="seconds"),
                error=None,
            )
            self._append_log(f"[bridge] FaceFusion core package downloaded: {target_path}")
        except Exception as error:
            self._set_core_update_state(
                state="failed",
                message="FaceFusion 核心源码包下载失败。",
                speed_bps=0.0,
                error=str(error),
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log(f"[bridge] FaceFusion core download failed: {error}")

    def _extract_core_update_source(self, package_path: Path, extract_dir: Path) -> Path:
        import zipfile

        if extract_dir.exists():
            shutil.rmtree(extract_dir)
        extract_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(package_path) as archive:
            for member in archive.infolist():
                member_path = extract_dir / member.filename
                if not self._path_is_within(member_path, extract_dir):
                    raise RuntimeError(f"FaceFusion core package contains an unsafe path: {member.filename}")
            archive.extractall(extract_dir)

        source_roots = [path for path in extract_dir.iterdir() if path.is_dir()]
        if len(source_roots) != 1:
            raise RuntimeError("FaceFusion core package must contain exactly one source directory.")
        return source_roots[0]

    def _validate_core_update_source(self, source_root: Path, expected_version: str) -> None:
        missing_names = [name for name in CORE_UPDATE_PAYLOAD_NAMES if not (source_root / name).exists()]
        if missing_names:
            raise RuntimeError(f"FaceFusion core package is incomplete: {', '.join(missing_names)}")

        preflight_script = """
import inspect
import sys

source_root = sys.argv[1]
expected_version = sys.argv[2].lstrip('v')
sys.path.insert(0, source_root)

import facefusion.choices as facefusion_choices
from facefusion import core, metadata
from facefusion.face_creator import get_many_faces
from facefusion.filesystem import filter_audio_paths, get_file_extension, is_image, is_video
from facefusion.processors.modules.age_modifier import choices as age_modifier_choices
from facefusion.processors.modules.background_remover import choices as background_remover_choices
from facefusion.processors.modules.deep_swapper import choices as deep_swapper_choices
from facefusion.processors.modules.expression_restorer import choices as expression_restorer_choices
from facefusion.processors.modules.face_debugger import choices as face_debugger_choices
from facefusion.processors.modules.face_editor import choices as face_editor_choices
from facefusion.processors.modules.face_enhancer import choices as face_enhancer_choices
from facefusion.processors.modules.face_swapper import choices as face_swapper_choices
from facefusion.processors.modules.frame_colorizer import choices as frame_colorizer_choices
from facefusion.processors.modules.frame_enhancer import choices as frame_enhancer_choices
from facefusion.processors.modules.lip_syncer import choices as lip_syncer_choices
from facefusion.program import create_program
from facefusion.uis import choices as ui_choices
from facefusion.uis.components.preview import process_preview_frame
from facefusion.vision import count_video_frame_total, read_static_image

actual_version = str(metadata.get('version') or '').lstrip('v')
if not actual_version or actual_version != expected_version:
    raise RuntimeError(f'core version mismatch: expected {expected_version}, got {actual_version or "missing"}')
preview_parameters = list(inspect.signature(process_preview_frame).parameters)
if preview_parameters[4:5] != ['target_vision_frames']:
    raise RuntimeError('preview API is incompatible with FaceSwap Studio workers')
if get_many_faces.__module__ != 'facefusion.face_creator':
    raise RuntimeError('face_creator API is incompatible with FaceSwap Studio workers')
"""
        result = subprocess.run(
            [sys.executable, "-c", preflight_script, str(source_root.resolve()), expected_version],
            cwd=str(source_root),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            timeout=60,
        )
        if result.returncode != 0:
            details = (result.stderr or result.stdout or "unknown import error").strip()
            raise RuntimeError(f"FaceFusion core compatibility check failed: {details[-2000:]}")

    def _copy_core_update_payload(self, source_root: Path, target_root: Path) -> None:
        for name in CORE_UPDATE_PAYLOAD_NAMES:
            source = source_root / name
            target = target_root / name
            if target.exists():
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            if not source.exists():
                continue
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)

    def _backup_core_update_payload(self, backup_dir: Path) -> None:
        backup_dir.mkdir(parents=True, exist_ok=False)
        for name in CORE_UPDATE_PAYLOAD_NAMES:
            source = self.repo_root / name
            if not source.exists():
                continue
            target = backup_dir / name
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)

    def apply_core_update(self) -> dict[str, Any]:
        core_update = dict(self.update_status().get("core_update") or {})
        package_path_value = str(core_update.get("package_path") or "").strip()
        if not package_path_value:
            return self._set_core_update_state(
                state="failed",
                message="FaceFusion 核心源码包尚未下载。",
                error="FaceFusion core package was not downloaded.",
            )
        package_path = Path(package_path_value)
        if not package_path.exists():
            return self._set_core_update_state(
                state="failed",
                message="FaceFusion 核心源码包尚未下载。",
                error="FaceFusion core package was not downloaded.",
            )
        if self._process and self._process.poll() is None:
            return self._set_core_update_state(
                state="failed",
                message="请先停止 FaceFusion 后再升级核心。",
                error="FaceFusion process is still running.",
            )
        if self._queue_current_process and self._queue_current_process.poll() is None:
            return self._set_core_update_state(
                state="failed",
                message="请先停止生成队列后再升级核心。",
                error="FaceFusion queue process is still running.",
            )

        backup_dir: Path | None = None
        update_started = False
        try:
            self._set_core_update_state(
                state="applying",
                message="正在检查、备份并应用 FaceFusion 核心升级...",
                error=None,
            )
            extract_dir = package_path.parent / "source"
            source_root = self._extract_core_update_source(package_path, extract_dir)
            expected_version = str(core_update.get("latest_version") or "").strip()
            if not expected_version:
                raise RuntimeError("FaceFusion core update version is missing.")
            self._validate_core_update_source(source_root, expected_version)

            backup_root = self._core_updates_root() / "backups"
            backup_dir = backup_root / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            self._backup_core_update_payload(backup_dir)
            update_started = True
            self._copy_core_update_payload(source_root, self.repo_root)
            self._validate_core_update_source(self.repo_root, expected_version)

            self._set_core_update_state(
                state="applied",
                message="FaceFusion 核心升级已应用，重启 Bridge/FaceFusion 后生效。",
                backup_path=str(backup_dir),
                current_version=expected_version,
                update_available=False,
                error=None,
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log(f"[bridge] FaceFusion core update applied. Backup: {backup_dir}")
        except Exception as error:
            rollback_error: Exception | None = None
            rollback_succeeded = False
            if update_started and backup_dir is not None:
                try:
                    self._copy_core_update_payload(backup_dir, self.repo_root)
                    rollback_succeeded = True
                    self._append_log(f"[bridge] FaceFusion core update rolled back: {backup_dir}")
                except Exception as restore_error:
                    rollback_error = restore_error
                    self._append_log(f"[bridge] FaceFusion core rollback failed: {restore_error}")
            if rollback_succeeded:
                message = "FaceFusion 核心升级失败，已自动恢复原核心。"
            elif update_started:
                message = "FaceFusion 核心升级失败，自动恢复也失败，请使用备份恢复。"
            else:
                message = "FaceFusion 核心升级包兼容性检查失败，当前核心未修改。"
            error_text = str(error)
            if rollback_error is not None:
                error_text = f"{error_text}; rollback failed: {rollback_error}"
            self._set_core_update_state(
                state="failed",
                message=message,
                backup_path=str(backup_dir) if backup_dir is not None else None,
                error=error_text,
                completed_at=datetime.now().isoformat(timespec="seconds"),
            )
            self._append_log(f"[bridge] FaceFusion core apply failed: {error}")
        return self.update_status()

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
        core_update = dict(state.get("core_update") or self._default_core_update_state())
        core_update["current_version"] = self._read_facefusion_core_version()
        state["core_update"] = core_update
        return self._apply_pending_update_marker_to_state(state)

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
            core_update = self._check_facefusion_core_update()
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
                "core_update": core_update,
                "error": None,
            }

            if not update_available:
                message = "当前已是最新版本。"
                if core_update.get("update_available"):
                    message = f"壳软件已是最新版本，FaceFusion 核心发现新版本 {core_update.get('latest_version')}。"
                state_updates.update({"state": "current", "message": message})
            elif selected_delta:
                message = f"发现新版本 {latest_version}。"
                if core_update.get("update_available"):
                    message += f" FaceFusion 核心也发现新版本 {core_update.get('latest_version')}。"
                state_updates.update(
                    {
                        "state": "update_available",
                        "message": message,
                        "asset_name": selected_delta.get("asset_name"),
                        "total_bytes": int(selected_delta.get("size") or 0),
                    }
                )
            else:
                message = "当前版本没有可用增量包，请下载全量安装器。"
                if core_update.get("update_available"):
                    message += f" FaceFusion 核心发现新版本 {core_update.get('latest_version')}。"
                state_updates.update(
                    {
                        "state": "full_required",
                        "message": message,
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
                core_update=self._check_facefusion_core_update(),
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
            self._clear_pending_update_marker()
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

    def schedule_update(self) -> dict[str, Any]:
        state = self.update_status()
        package_path_value = str(state.get("package_path") or "").strip()
        if not package_path_value:
            return {
                **state,
                "state": "failed",
                "message": "更新包尚未下载。",
                "error": "Update package was not downloaded.",
            }

        package_path = Path(package_path_value)
        if not package_path.exists():
            self._clear_pending_update_marker()
            return {
                **state,
                "state": "failed",
                "message": "更新包尚未下载。",
                "error": "Update package was not downloaded.",
            }

        latest_version = str(state.get("latest_version") or "").strip() or self._read_app_version()
        marker = self._write_pending_update_marker(package_path, latest_version)
        self._set_update_state(
            message="更新包已安排在下次启动时安装。",
            error=None,
            package_path=str(package_path),
            scheduled_for_next_launch=True,
            scheduled_at=marker.get("scheduled_at"),
            pending_package_path=str(package_path),
        )
        self._append_log(f"[bridge] Update scheduled for next launch: {package_path}")
        return self.update_status()

    def apply_update(self) -> dict[str, Any]:
        state = self.update_status()
        package_path = Path(str(state.get("package_path") or ""))
        if not package_path.exists():
            self._clear_pending_update_marker()
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
        self._clear_pending_update_marker()
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

    def _remap_studio_root_path(self, path: Path) -> Path:
        studio_root_name = self._studio_root.name.lower()
        for index in range(len(path.parts) - 2, -1, -1):
            part = path.parts[index]
            next_part = path.parts[index + 1].lower()
            if part.lower() == studio_root_name and next_part in STUDIO_ROOT_CHILD_NAMES:
                return self._studio_root.joinpath(*path.parts[index + 1 :])
        return path

    def _resolve_portable_path(self, value: Any, *, require_exists: bool = False) -> str | None:
        raw_path = str(value or "").strip()
        if not raw_path:
            return None

        candidate = Path(raw_path)
        if candidate.exists():
            return str(candidate)

        remapped = self._remap_studio_root_path(candidate)
        if remapped != candidate and (remapped.exists() or not require_exists):
            return str(remapped)
        if require_exists:
            return None
        return str(candidate)

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

        def preferred_choice(preferred: str, choices: list[str], fallback: str | None = None) -> str | None:
            if preferred in choices:
                return preferred
            if fallback and fallback in choices:
                return fallback
            return choices[0] if choices else None

        def filtered_defaults(preferred_items: list[str], choices: list[str], fallback: list[str]) -> list[str]:
            normalized = [item for item in preferred_items if item in choices]
            if normalized:
                return normalized
            normalized_fallback = [item for item in fallback if item in choices]
            if normalized_fallback:
                return normalized_fallback
            return choices[:1]

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
            "age_modifier_model": preferred_choice("fran", list(age_modifier_choices.age_modifier_models)),
            "age_modifier_direction": 0,
            "background_remover_model": preferred_choice(
                "modnet",
                list(background_remover_choices.background_remover_models),
            ),
            "background_remover_fill_color": [0, 0, 0, 0],
            "background_remover_despill_color": [0, 0, 0, 0],
            "deep_swapper_model": preferred_choice(
                "iperov/elon_musk_224",
                list(deep_swapper_choices.deep_swapper_models),
            ),
            "deep_swapper_morph": 100,
            "expression_restorer_model": preferred_choice(
                "live_portrait",
                list(expression_restorer_choices.expression_restorer_models),
            ),
            "expression_restorer_factor": 80,
            "expression_restorer_areas": list(expression_restorer_choices.expression_restorer_areas),
            "face_debugger_items": filtered_defaults(
                ["face-landmark-5/68", "face-mask"],
                list(face_debugger_choices.face_debugger_items),
                ["face-mask"],
            ),
            "face_editor_model": preferred_choice("live_portrait", list(face_editor_choices.face_editor_models)),
            "face_editor_eyebrow_direction": 0.0,
            "face_editor_eye_gaze_horizontal": 0.0,
            "face_editor_eye_gaze_vertical": 0.0,
            "face_editor_eye_open_ratio": 0.0,
            "face_editor_lip_open_ratio": 0.0,
            "face_editor_mouth_grim": 0.0,
            "face_editor_mouth_pout": 0.0,
            "face_editor_mouth_purse": 0.0,
            "face_editor_mouth_smile": 0.0,
            "face_editor_mouth_position_horizontal": 0.0,
            "face_editor_mouth_position_vertical": 0.0,
            "face_editor_head_pitch": 0.0,
            "face_editor_head_yaw": 0.0,
            "face_editor_head_roll": 0.0,
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
            "frame_colorizer_model": preferred_choice(
                "ddcolor",
                list(frame_colorizer_choices.frame_colorizer_models),
            ),
            "frame_colorizer_size": preferred_choice(
                "256x256",
                list(frame_colorizer_choices.frame_colorizer_sizes),
            ),
            "frame_colorizer_blend": 100,
            "frame_enhancer_model": "span_kendata_x4",
            "frame_enhancer_blend": 80,
            "lip_syncer_model": preferred_choice(
                "wav2lip_gan_96",
                list(lip_syncer_choices.lip_syncer_models),
            ),
            "lip_syncer_weight": 0.5,
            "face_detector_model": preferred_choice(
                "yolo_face",
                list(facefusion_choices.face_detector_models),
            ),
            "face_detector_size": preferred_choice(
                "640x640",
                list(
                    facefusion_choices.face_detector_set.get(
                        preferred_choice("yolo_face", list(facefusion_choices.face_detector_models), "many") or "many",
                        [],
                    ),
                ),
                "640x640",
            ),
            "face_detector_margin": [0, 0, 0, 0],
            "face_detector_angles": [0],
            "face_detector_score": 0.5,
            "face_landmarker_model": preferred_choice(
                "2dfan4",
                list(facefusion_choices.face_landmarker_models),
            ),
            "face_landmarker_score": 0.5,
            "output_image_quality": 80,
            "output_image_scale": 1.0,
            "output_audio_encoder": (
                facefusion_choices.output_audio_encoders[0]
                if facefusion_choices.output_audio_encoders
                else None
            ),
            "output_audio_quality": 80,
            "output_audio_volume": 100,
            "output_video_encoder": default_video_encoder,
            "output_video_preset": default_video_preset,
            "output_video_quality": 100,
            "output_video_scale": 1.0,
            "output_video_fps": None,
            "face_selector_mode": "many",
            "face_selector_order": "large-small",
            "face_selector_gender": None,
            "face_selector_race": None,
            "face_selector_age_start": None,
            "face_selector_age_end": None,
            "reference_face_position": 0,
            "reference_face_distance": 0.3,
            "face_occluder_model": preferred_choice(
                "xseg_1",
                list(facefusion_choices.face_occluder_models),
            ),
            "face_parser_model": preferred_choice(
                "bisenet_resnet_34",
                list(facefusion_choices.face_parser_models),
            ),
            "face_mask_types": ["box"],
            "face_mask_areas": list(facefusion_choices.face_mask_areas),
            "face_mask_regions": list(facefusion_choices.face_mask_regions),
            "face_mask_blur": 0.3,
            "face_mask_padding": [0, 0, 0, 0],
            "voice_extractor_model": preferred_choice(
                "kim_vocal_2",
                list(facefusion_choices.voice_extractor_models),
            ),
            "trim_frame_start": None,
            "trim_frame_end": None,
            "temp_frame_format": preferred_choice(
                "png",
                list(facefusion_choices.temp_frame_formats),
            ),
            "keep_temp": False,
            "execution_thread_count": 14,
            "preview_mode": ui_choices.preview_modes[0],
            "preview_resolution": ui_choices.preview_resolutions[-1],
            "preview_frame_number": 0,
        }

    def _migrate_workspace_options_payload(self, payload: Any) -> dict[str, Any]:
        if not isinstance(payload, dict):
            return {}

        migrated = dict(payload)
        legacy_video_quality = migrated.get("output_video_quality")
        if legacy_video_quality in (80, "80"):
            # 历史工作台默认值是 80，新版本统一提升到 100。
            migrated["output_video_quality"] = 100
        return migrated

    def _load_workspace_options(self) -> dict[str, Any]:
        defaults = self._default_workspace_options()
        if not self._workspace_options_path.exists():
            self._save_workspace_options(defaults)
            return defaults

        try:
            payload = json.loads(self._workspace_options_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}

        payload = self._migrate_workspace_options_payload(payload)
        normalized = self._normalize_workspace_options(payload, defaults)
        self._save_workspace_options(normalized)
        return normalized

    def _save_workspace_options(self, options: dict[str, Any] | None = None) -> None:
        payload = options or self._workspace_options
        self._workspace_options_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _normalize_work_metadata_path(self, path: Any, allowed_extensions: set[str]) -> str | None:
        portable_path = self._resolve_portable_path(path)
        if not portable_path:
            return None
        candidate = Path(portable_path)
        if candidate.suffix.lower() not in allowed_extensions:
            return None
        return str(self._resolve_existing_path(candidate))

    def _normalize_work_metadata_key(self, output_path: Any) -> str | None:
        normalized_path = self._normalize_work_metadata_path(
            output_path,
            IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS),
        )
        if not normalized_path:
            return None
        return os.path.normcase(os.path.abspath(normalized_path))

    def _normalize_work_metadata_source_paths(self, paths: Any) -> list[str]:
        if not isinstance(paths, list):
            return []
        normalized = []
        for item in paths:
            portable_path = self._resolve_portable_path(item)
            if not portable_path:
                continue
            candidate = Path(portable_path)
            if candidate.suffix.lower() in AUDIO_EXTENSIONS.union(IMAGE_EXTENSIONS):
                normalized.append(str(self._resolve_existing_path(candidate)))
        return normalized

    def _normalize_works_metadata_entry(self, payload: Any) -> dict[str, Any] | None:
        if not isinstance(payload, dict):
            return None

        output_path = self._normalize_work_metadata_path(
            payload.get("output_path"),
            IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS),
        )
        if not output_path:
            return None

        target_path = self._normalize_work_metadata_path(
            payload.get("target_path"),
            IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS),
        )
        output_media_type = payload.get("output_media_type")
        if output_media_type not in {"image", "video"}:
            output_media_type = self._media_type_for_path(output_path)
        target_media_type = payload.get("target_media_type")
        if target_media_type not in {"image", "video"}:
            target_media_type = self._media_type_for_path(target_path)

        return {
            "output_path": output_path,
            "job_id": str(payload.get("job_id") or "") or None,
            "target_path": target_path,
            "target_media_type": target_media_type,
            "output_media_type": output_media_type,
            "source_paths": self._normalize_work_metadata_source_paths(
                payload.get("source_paths"),
            ),
            "updated_at": str(
                payload.get("updated_at")
                or datetime.now().isoformat(timespec="seconds")
            ),
        }

    def _load_works_metadata(self) -> dict[str, dict[str, Any]]:
        if not self._works_metadata_path.exists():
            return {}
        try:
            payload = json.loads(self._works_metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}

        if not isinstance(payload, dict):
            return {}

        metadata_by_output_path: dict[str, dict[str, Any]] = {}
        for output_key, raw_entry in payload.items():
            if not isinstance(raw_entry, dict):
                continue
            entry = dict(raw_entry)
            if not entry.get("output_path"):
                entry["output_path"] = output_key
            normalized_entry = self._normalize_works_metadata_entry(entry)
            normalized_key = self._normalize_work_metadata_key(
                normalized_entry.get("output_path") if normalized_entry else None,
            )
            if normalized_entry and normalized_key:
                metadata_by_output_path[normalized_key] = normalized_entry
        return metadata_by_output_path

    def _cleanup_works_metadata(self, active_output_keys: set[str] | None = None) -> bool:
        active_keys = set(active_output_keys or set())
        changed = False
        normalized_metadata: dict[str, dict[str, Any]] = {}

        for output_key, raw_entry in self._works_metadata.items():
            normalized_entry = self._normalize_works_metadata_entry(raw_entry)
            normalized_key = self._normalize_work_metadata_key(
                normalized_entry.get("output_path") if normalized_entry else None,
            )
            if not normalized_entry or not normalized_key:
                changed = True
                continue

            output_exists = self._resolve_portable_path(
                normalized_entry["output_path"],
                require_exists=True,
            )
            if not output_exists and normalized_key not in active_keys:
                changed = True
                continue

            previous_entry = normalized_metadata.get(normalized_key)
            if previous_entry is not None and previous_entry != normalized_entry:
                changed = True
            normalized_metadata[normalized_key] = normalized_entry

            if output_key != normalized_key or raw_entry != normalized_entry:
                changed = True

        if normalized_metadata != self._works_metadata:
            changed = True
        self._works_metadata = normalized_metadata
        return changed

    def _save_works_metadata(
        self,
        active_output_keys: set[str] | None = None,
        *,
        force: bool = False,
    ) -> None:
        with self._lock:
            changed = self._cleanup_works_metadata(active_output_keys)
            if not force and not changed and self._works_metadata_path.exists():
                return
            payload = {
                output_key: self._works_metadata[output_key]
                for output_key in sorted(self._works_metadata.keys())
            }
            self._works_metadata_path.write_text(
                json.dumps(payload, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )

    def _persist_works_metadata_entries(
        self,
        entries: list[dict[str, Any]],
        active_output_keys: set[str] | None = None,
    ) -> None:
        changed = False
        with self._lock:
            for raw_entry in entries:
                normalized_entry = self._normalize_works_metadata_entry(raw_entry)
                normalized_key = self._normalize_work_metadata_key(
                    normalized_entry.get("output_path") if normalized_entry else None,
                )
                if not normalized_entry or not normalized_key:
                    continue
                if self._works_metadata.get(normalized_key) != normalized_entry:
                    self._works_metadata[normalized_key] = normalized_entry
                    changed = True
            self._save_works_metadata(active_output_keys, force=changed)

    def _remove_works_metadata_entry(self, output_path: Any) -> None:
        output_key = self._normalize_work_metadata_key(output_path)
        if not output_key:
            return
        with self._lock:
            if self._works_metadata.pop(output_key, None) is not None:
                self._save_works_metadata(force=True)

    def _works_metadata_by_output_path(
        self,
        active_output_keys: set[str] | None = None,
    ) -> dict[str, dict[str, Any]]:
        with self._lock:
            self._save_works_metadata(active_output_keys)
            return {
                output_key: dict(metadata)
                for output_key, metadata in self._works_metadata.items()
            }

    def _works_metadata_entry_from_queue_task(
        self,
        task: dict[str, Any],
    ) -> dict[str, Any] | None:
        output_key = self._normalize_work_metadata_key(task.get("output_path"))
        if not output_key:
            return None
        return {
            "output_path": task.get("output_path"),
            "job_id": task.get("job_id"),
            "target_path": task.get("target_path"),
            "target_media_type": task.get("target_media_type"),
            "output_media_type": task.get("output_media_type"),
            "source_paths": task.get("source_paths") or [],
            "updated_at": task.get("updated_at")
            or task.get("created_at")
            or datetime.now().isoformat(timespec="seconds"),
        }

    def _active_queue_output_keys(self, tasks: list[dict[str, Any]]) -> set[str]:
        active_output_keys: set[str] = set()
        for task in tasks:
            output_key = self._normalize_work_metadata_key(task.get("output_path"))
            if not output_key:
                continue
            status = str(task.get("status") or "")
            if task.get("can_open_output") is True or status in {"drafted", "queued"}:
                active_output_keys.add(output_key)
        return active_output_keys

    def _choice_contains_float(self, choices: list[float], value: float) -> bool:
        return any(abs(choice - value) < 1e-9 for choice in choices)

    def _normalize_choice(self, value: Any, choices: list[Any], default: Any) -> Any:
        return value if value in choices else default

    def _normalize_optional_choice(self, value: Any, choices: list[str], default: str | None) -> str | None:
        if value in [None, "", "none"]:
            return default
        candidate = str(value)
        return candidate if candidate in choices else default

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

    def _normalize_int_list_choice(
        self,
        value: Any,
        choices: list[int],
        default: list[int],
    ) -> list[int]:
        if not isinstance(value, list):
            return list(default)

        normalized: list[int] = []
        for item in value:
            try:
                candidate = int(item)
            except (TypeError, ValueError):
                continue
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

    def _normalize_optional_int_choice(
        self,
        value: Any,
        choices: list[int],
        default: int | None,
    ) -> int | None:
        if value in [None, "", "none"]:
            return default
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            return default
        return candidate if candidate in choices else default

    def _normalize_non_negative_int(self, value: Any, default: int) -> int:
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            return default
        return candidate if candidate >= 0 else default

    def _normalize_optional_non_negative_int(self, value: Any, default: int | None) -> int | None:
        if value in [None, "", "none"]:
            return default
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            return default
        return candidate if candidate >= 0 else default

    def _normalize_bool(self, value: Any, default: bool) -> bool:
        if value is None:
            return default
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in {"true", "1", "yes", "on"}:
                return True
            if lowered in {"false", "0", "no", "off"}:
                return False
        return bool(value)

    def _normalize_fixed_int_list(
        self,
        value: Any,
        choices: list[int],
        default: list[int],
        *,
        length: int,
        repeat_scalar: bool = False,
    ) -> list[int]:
        if isinstance(value, (list, tuple)):
            raw_values = list(value)
        elif repeat_scalar:
            raw_values = [value]
        else:
            return list(default)

        if len(raw_values) == 1 and repeat_scalar:
            raw_values = raw_values * length
        if len(raw_values) != length:
            return list(default)

        normalized: list[int] = []
        for item in raw_values:
            try:
                candidate = int(item)
            except (TypeError, ValueError):
                return list(default)
            if candidate not in choices:
                return list(default)
            normalized.append(candidate)
        return normalized

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

        normalized["age_modifier_model"] = self._normalize_choice(
            payload.get("age_modifier_model", normalized["age_modifier_model"]),
            list(age_modifier_choices.age_modifier_models),
            defaults["age_modifier_model"],
        )
        normalized["age_modifier_direction"] = self._normalize_int_choice(
            payload.get("age_modifier_direction", normalized["age_modifier_direction"]),
            list(age_modifier_choices.age_modifier_direction_range),
            defaults["age_modifier_direction"],
        )

        normalized["background_remover_model"] = self._normalize_choice(
            payload.get("background_remover_model", normalized["background_remover_model"]),
            list(background_remover_choices.background_remover_models),
            defaults["background_remover_model"],
        )
        normalized["background_remover_fill_color"] = self._normalize_fixed_int_list(
            payload.get("background_remover_fill_color", normalized["background_remover_fill_color"]),
            list(background_remover_choices.background_remover_color_range),
            defaults["background_remover_fill_color"],
            length=4,
        )
        normalized["background_remover_despill_color"] = self._normalize_fixed_int_list(
            payload.get(
                "background_remover_despill_color",
                normalized["background_remover_despill_color"],
            ),
            list(background_remover_choices.background_remover_color_range),
            defaults["background_remover_despill_color"],
            length=4,
        )

        normalized["deep_swapper_model"] = self._normalize_choice(
            payload.get("deep_swapper_model", normalized["deep_swapper_model"]),
            list(deep_swapper_choices.deep_swapper_models),
            defaults["deep_swapper_model"],
        )
        normalized["deep_swapper_morph"] = self._normalize_int_choice(
            payload.get("deep_swapper_morph", normalized["deep_swapper_morph"]),
            list(deep_swapper_choices.deep_swapper_morph_range),
            defaults["deep_swapper_morph"],
        )

        normalized["expression_restorer_model"] = self._normalize_choice(
            payload.get(
                "expression_restorer_model",
                normalized["expression_restorer_model"],
            ),
            list(expression_restorer_choices.expression_restorer_models),
            defaults["expression_restorer_model"],
        )
        normalized["expression_restorer_factor"] = self._normalize_int_choice(
            payload.get(
                "expression_restorer_factor",
                normalized["expression_restorer_factor"],
            ),
            list(expression_restorer_choices.expression_restorer_factor_range),
            defaults["expression_restorer_factor"],
        )
        normalized["expression_restorer_areas"] = self._normalize_list_choice(
            payload.get(
                "expression_restorer_areas",
                normalized["expression_restorer_areas"],
            ),
            list(expression_restorer_choices.expression_restorer_areas),
            defaults["expression_restorer_areas"],
        )

        normalized["face_debugger_items"] = self._normalize_list_choice(
            payload.get("face_debugger_items", normalized["face_debugger_items"]),
            list(face_debugger_choices.face_debugger_items),
            defaults["face_debugger_items"],
        )

        normalized["face_editor_model"] = self._normalize_choice(
            payload.get("face_editor_model", normalized["face_editor_model"]),
            list(face_editor_choices.face_editor_models),
            defaults["face_editor_model"],
        )
        normalized["face_editor_eyebrow_direction"] = self._normalize_float_choice(
            payload.get(
                "face_editor_eyebrow_direction",
                normalized["face_editor_eyebrow_direction"],
            ),
            list(face_editor_choices.face_editor_eyebrow_direction_range),
            defaults["face_editor_eyebrow_direction"],
        )
        normalized["face_editor_eye_gaze_horizontal"] = self._normalize_float_choice(
            payload.get(
                "face_editor_eye_gaze_horizontal",
                normalized["face_editor_eye_gaze_horizontal"],
            ),
            list(face_editor_choices.face_editor_eye_gaze_horizontal_range),
            defaults["face_editor_eye_gaze_horizontal"],
        )
        normalized["face_editor_eye_gaze_vertical"] = self._normalize_float_choice(
            payload.get(
                "face_editor_eye_gaze_vertical",
                normalized["face_editor_eye_gaze_vertical"],
            ),
            list(face_editor_choices.face_editor_eye_gaze_vertical_range),
            defaults["face_editor_eye_gaze_vertical"],
        )
        normalized["face_editor_eye_open_ratio"] = self._normalize_float_choice(
            payload.get(
                "face_editor_eye_open_ratio",
                normalized["face_editor_eye_open_ratio"],
            ),
            list(face_editor_choices.face_editor_eye_open_ratio_range),
            defaults["face_editor_eye_open_ratio"],
        )
        normalized["face_editor_lip_open_ratio"] = self._normalize_float_choice(
            payload.get(
                "face_editor_lip_open_ratio",
                normalized["face_editor_lip_open_ratio"],
            ),
            list(face_editor_choices.face_editor_lip_open_ratio_range),
            defaults["face_editor_lip_open_ratio"],
        )
        normalized["face_editor_mouth_grim"] = self._normalize_float_choice(
            payload.get("face_editor_mouth_grim", normalized["face_editor_mouth_grim"]),
            list(face_editor_choices.face_editor_mouth_grim_range),
            defaults["face_editor_mouth_grim"],
        )
        normalized["face_editor_mouth_pout"] = self._normalize_float_choice(
            payload.get("face_editor_mouth_pout", normalized["face_editor_mouth_pout"]),
            list(face_editor_choices.face_editor_mouth_pout_range),
            defaults["face_editor_mouth_pout"],
        )
        normalized["face_editor_mouth_purse"] = self._normalize_float_choice(
            payload.get("face_editor_mouth_purse", normalized["face_editor_mouth_purse"]),
            list(face_editor_choices.face_editor_mouth_purse_range),
            defaults["face_editor_mouth_purse"],
        )
        normalized["face_editor_mouth_smile"] = self._normalize_float_choice(
            payload.get("face_editor_mouth_smile", normalized["face_editor_mouth_smile"]),
            list(face_editor_choices.face_editor_mouth_smile_range),
            defaults["face_editor_mouth_smile"],
        )
        normalized["face_editor_mouth_position_horizontal"] = self._normalize_float_choice(
            payload.get(
                "face_editor_mouth_position_horizontal",
                normalized["face_editor_mouth_position_horizontal"],
            ),
            list(face_editor_choices.face_editor_mouth_position_horizontal_range),
            defaults["face_editor_mouth_position_horizontal"],
        )
        normalized["face_editor_mouth_position_vertical"] = self._normalize_float_choice(
            payload.get(
                "face_editor_mouth_position_vertical",
                normalized["face_editor_mouth_position_vertical"],
            ),
            list(face_editor_choices.face_editor_mouth_position_vertical_range),
            defaults["face_editor_mouth_position_vertical"],
        )
        normalized["face_editor_head_pitch"] = self._normalize_float_choice(
            payload.get("face_editor_head_pitch", normalized["face_editor_head_pitch"]),
            list(face_editor_choices.face_editor_head_pitch_range),
            defaults["face_editor_head_pitch"],
        )
        normalized["face_editor_head_yaw"] = self._normalize_float_choice(
            payload.get("face_editor_head_yaw", normalized["face_editor_head_yaw"]),
            list(face_editor_choices.face_editor_head_yaw_range),
            defaults["face_editor_head_yaw"],
        )
        normalized["face_editor_head_roll"] = self._normalize_float_choice(
            payload.get("face_editor_head_roll", normalized["face_editor_head_roll"]),
            list(face_editor_choices.face_editor_head_roll_range),
            defaults["face_editor_head_roll"],
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

        normalized["frame_colorizer_model"] = self._normalize_choice(
            payload.get("frame_colorizer_model", normalized["frame_colorizer_model"]),
            list(frame_colorizer_choices.frame_colorizer_models),
            defaults["frame_colorizer_model"],
        )
        normalized["frame_colorizer_size"] = self._normalize_choice(
            payload.get("frame_colorizer_size", normalized["frame_colorizer_size"]),
            list(frame_colorizer_choices.frame_colorizer_sizes),
            defaults["frame_colorizer_size"],
        )
        normalized["frame_colorizer_blend"] = self._normalize_int_choice(
            payload.get("frame_colorizer_blend", normalized["frame_colorizer_blend"]),
            list(frame_colorizer_choices.frame_colorizer_blend_range),
            defaults["frame_colorizer_blend"],
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

        normalized["lip_syncer_model"] = self._normalize_choice(
            payload.get("lip_syncer_model", normalized["lip_syncer_model"]),
            list(lip_syncer_choices.lip_syncer_models),
            defaults["lip_syncer_model"],
        )
        normalized["lip_syncer_weight"] = self._normalize_float_choice(
            payload.get("lip_syncer_weight", normalized["lip_syncer_weight"]),
            list(lip_syncer_choices.lip_syncer_weight_range),
            defaults["lip_syncer_weight"],
        )

        normalized["face_detector_model"] = self._normalize_choice(
            payload.get("face_detector_model", normalized["face_detector_model"]),
            list(facefusion_choices.face_detector_models),
            defaults["face_detector_model"],
        )
        face_detector_size_choices = list(
            facefusion_choices.face_detector_set.get(normalized["face_detector_model"], []),
        )
        normalized["face_detector_size"] = self._normalize_choice(
            payload.get("face_detector_size", normalized["face_detector_size"]),
            face_detector_size_choices,
            face_detector_size_choices[-1] if face_detector_size_choices else defaults["face_detector_size"],
        )
        normalized["face_detector_margin"] = self._normalize_fixed_int_list(
            payload.get("face_detector_margin", normalized["face_detector_margin"]),
            list(facefusion_choices.face_detector_margin_range),
            defaults["face_detector_margin"],
            length=4,
            repeat_scalar=True,
        )
        normalized["face_detector_angles"] = self._normalize_int_list_choice(
            payload.get("face_detector_angles", normalized["face_detector_angles"]),
            list(facefusion_choices.face_detector_angles),
            defaults["face_detector_angles"],
        )
        normalized["face_detector_score"] = self._normalize_float_choice(
            payload.get("face_detector_score", normalized["face_detector_score"]),
            list(facefusion_choices.face_detector_score_range),
            defaults["face_detector_score"],
        )

        normalized["face_landmarker_model"] = self._normalize_choice(
            payload.get("face_landmarker_model", normalized["face_landmarker_model"]),
            list(facefusion_choices.face_landmarker_models),
            defaults["face_landmarker_model"],
        )
        normalized["face_landmarker_score"] = self._normalize_float_choice(
            payload.get("face_landmarker_score", normalized["face_landmarker_score"]),
            list(facefusion_choices.face_landmarker_score_range),
            defaults["face_landmarker_score"],
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
        normalized["output_audio_encoder"] = self._normalize_choice(
            payload.get("output_audio_encoder", normalized["output_audio_encoder"]),
            list(facefusion_choices.output_audio_encoders),
            defaults["output_audio_encoder"],
        )
        normalized["output_audio_quality"] = self._normalize_int_choice(
            payload.get("output_audio_quality", normalized["output_audio_quality"]),
            list(facefusion_choices.output_audio_quality_range),
            defaults["output_audio_quality"],
        )
        normalized["output_audio_volume"] = self._normalize_int_choice(
            payload.get("output_audio_volume", normalized["output_audio_volume"]),
            list(facefusion_choices.output_audio_volume_range),
            defaults["output_audio_volume"],
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

        normalized["face_selector_mode"] = self._normalize_choice(
            payload.get("face_selector_mode", normalized["face_selector_mode"]),
            list(facefusion_choices.face_selector_modes),
            defaults["face_selector_mode"],
        )
        normalized["face_selector_order"] = self._normalize_choice(
            payload.get("face_selector_order", normalized["face_selector_order"]),
            list(facefusion_choices.face_selector_orders),
            defaults["face_selector_order"],
        )
        normalized["face_selector_gender"] = self._normalize_optional_choice(
            payload.get("face_selector_gender", normalized["face_selector_gender"]),
            list(facefusion_choices.face_selector_genders),
            defaults["face_selector_gender"],
        )
        normalized["face_selector_race"] = self._normalize_optional_choice(
            payload.get("face_selector_race", normalized["face_selector_race"]),
            list(facefusion_choices.face_selector_races),
            defaults["face_selector_race"],
        )
        normalized["face_selector_age_start"] = self._normalize_optional_int_choice(
            payload.get("face_selector_age_start", normalized["face_selector_age_start"]),
            list(facefusion_choices.face_selector_age_range),
            defaults["face_selector_age_start"],
        )
        normalized["face_selector_age_end"] = self._normalize_optional_int_choice(
            payload.get("face_selector_age_end", normalized["face_selector_age_end"]),
            list(facefusion_choices.face_selector_age_range),
            defaults["face_selector_age_end"],
        )
        normalized["reference_face_position"] = self._normalize_non_negative_int(
            payload.get("reference_face_position", normalized["reference_face_position"]),
            defaults["reference_face_position"],
        )
        normalized["reference_face_distance"] = self._normalize_float_choice(
            payload.get("reference_face_distance", normalized["reference_face_distance"]),
            list(facefusion_choices.reference_face_distance_range),
            defaults["reference_face_distance"],
        )

        normalized["face_occluder_model"] = self._normalize_choice(
            payload.get("face_occluder_model", normalized["face_occluder_model"]),
            list(facefusion_choices.face_occluder_models),
            defaults["face_occluder_model"],
        )
        normalized["face_parser_model"] = self._normalize_choice(
            payload.get("face_parser_model", normalized["face_parser_model"]),
            list(facefusion_choices.face_parser_models),
            defaults["face_parser_model"],
        )
        normalized["face_mask_types"] = self._normalize_list_choice(
            payload.get("face_mask_types", normalized["face_mask_types"]),
            list(facefusion_choices.face_mask_types),
            defaults["face_mask_types"],
        )
        normalized["face_mask_areas"] = self._normalize_list_choice(
            payload.get("face_mask_areas", normalized["face_mask_areas"]),
            list(facefusion_choices.face_mask_areas),
            defaults["face_mask_areas"],
        )
        normalized["face_mask_regions"] = self._normalize_list_choice(
            payload.get("face_mask_regions", normalized["face_mask_regions"]),
            list(facefusion_choices.face_mask_regions),
            defaults["face_mask_regions"],
        )
        normalized["face_mask_blur"] = self._normalize_float_choice(
            payload.get("face_mask_blur", normalized["face_mask_blur"]),
            list(facefusion_choices.face_mask_blur_range),
            defaults["face_mask_blur"],
        )
        normalized["face_mask_padding"] = self._normalize_fixed_int_list(
            payload.get("face_mask_padding", normalized["face_mask_padding"]),
            list(facefusion_choices.face_mask_padding_range),
            defaults["face_mask_padding"],
            length=4,
        )

        normalized["voice_extractor_model"] = self._normalize_choice(
            payload.get("voice_extractor_model", normalized["voice_extractor_model"]),
            list(facefusion_choices.voice_extractor_models),
            defaults["voice_extractor_model"],
        )
        normalized["trim_frame_start"] = self._normalize_optional_non_negative_int(
            payload.get("trim_frame_start", normalized["trim_frame_start"]),
            defaults["trim_frame_start"],
        )
        normalized["trim_frame_end"] = self._normalize_optional_non_negative_int(
            payload.get("trim_frame_end", normalized["trim_frame_end"]),
            defaults["trim_frame_end"],
        )
        normalized["temp_frame_format"] = self._normalize_choice(
            payload.get("temp_frame_format", normalized["temp_frame_format"]),
            list(facefusion_choices.temp_frame_formats),
            defaults["temp_frame_format"],
        )
        normalized["keep_temp"] = self._normalize_bool(
            payload.get("keep_temp", normalized["keep_temp"]),
            defaults["keep_temp"],
        )
        normalized["execution_thread_count"] = self._normalize_int_choice(
            payload.get("execution_thread_count", normalized["execution_thread_count"]),
            list(facefusion_choices.execution_thread_count_range),
            defaults["execution_thread_count"],
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
        if (
            normalized["face_selector_age_start"] is not None
            and normalized["face_selector_age_end"] is not None
            and normalized["face_selector_age_start"] > normalized["face_selector_age_end"]
        ):
            normalized["face_selector_age_start"], normalized["face_selector_age_end"] = (
                normalized["face_selector_age_end"],
                normalized["face_selector_age_start"],
            )
        if (
            normalized["trim_frame_start"] is not None
            and normalized["trim_frame_end"] is not None
            and normalized["trim_frame_start"] > normalized["trim_frame_end"]
        ):
            normalized["trim_frame_start"], normalized["trim_frame_end"] = (
                normalized["trim_frame_end"],
                normalized["trim_frame_start"],
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

        defaults = self._default_workspace_options()

        def field(
            key: str,
            *,
            type: str,
            panel: str,
            section: str,
            section_label: str,
            label: str,
            visible_for: list[str] | None = None,
            choices: list[Any] | None = None,
            default: Any | None = None,
            minimum: float | int | None = None,
            maximum: float | int | None = None,
            step: float | int | None = None,
            depends_on: str | None = None,
            depends_values: list[Any] | None = None,
            requires_processors: list[str] | None = None,
            control: str | None = None,
            paired_key: str | None = None,
            pair_label: str | None = None,
        ) -> tuple[str, dict[str, Any]]:
            payload: dict[str, Any] = {
                "type": type,
                "panel": panel,
                "section": section,
                "section_label": section_label,
                "label": label,
                "default": default,
                "visible_for": visible_for or ["all"],
            }
            if choices is not None:
                payload["choices"] = [str(item) for item in choices]
            if minimum is not None:
                payload["minimum"] = minimum
            if maximum is not None:
                payload["maximum"] = maximum
            if step is not None:
                payload["step"] = step
            if depends_on is not None:
                payload["depends_on"] = depends_on
            if depends_values is not None:
                payload["depends_values"] = [str(item) for item in depends_values]
            if requires_processors is not None:
                payload["requires_processors"] = [str(item) for item in requires_processors]
            if control is not None:
                payload["control"] = control
            if paired_key is not None:
                payload["paired_key"] = paired_key
            if pair_label is not None:
                payload["pair_label"] = pair_label
            return key, payload

        fields = dict(
            [
                field(
                    "processors",
                    type="multi_select",
                    panel="common",
                    section="processors",
                    section_label="处理器与模型",
                    label="处理器",
                    choices=self._available_processor_names(),
                    default=defaults["processors"],
                ),
                field(
                    "face_swapper_model",
                    type="select",
                    panel="common",
                    section="processors",
                    section_label="处理器与模型",
                    label="换脸模型",
                    choices=list(face_swapper_choices.face_swapper_models),
                    default=defaults["face_swapper_model"],
                    requires_processors=["face_swapper"],
                ),
                field(
                    "face_swapper_pixel_boost",
                    type="select",
                    panel="common",
                    section="processors",
                    section_label="处理器与模型",
                    label="像素增强",
                    choices=pixel_boost_choices,
                    default=pixel_boost_choices[0] if pixel_boost_choices else None,
                    depends_on="face_swapper_model",
                    requires_processors=["face_swapper"],
                ),
                field(
                    "face_swapper_weight",
                    type="float",
                    panel="common",
                    section="processors",
                    section_label="处理器与模型",
                    label="换脸权重",
                    minimum=face_swapper_choices.face_swapper_weight_range[0],
                    maximum=face_swapper_choices.face_swapper_weight_range[-1],
                    step=0.05,
                    default=defaults["face_swapper_weight"],
                    requires_processors=["face_swapper"],
                ),
                field(
                    "face_enhancer_model",
                    type="select",
                    panel="common",
                    section="face_enhancer",
                    section_label="人脸增强",
                    label="增强模型",
                    choices=list(face_enhancer_choices.face_enhancer_models),
                    default=defaults["face_enhancer_model"],
                    requires_processors=["face_enhancer"],
                ),
                field(
                    "face_enhancer_blend",
                    type="int",
                    panel="common",
                    section="face_enhancer",
                    section_label="人脸增强",
                    label="增强混合",
                    minimum=face_enhancer_choices.face_enhancer_blend_range[0],
                    maximum=face_enhancer_choices.face_enhancer_blend_range[-1],
                    step=1,
                    default=defaults["face_enhancer_blend"],
                    requires_processors=["face_enhancer"],
                ),
                field(
                    "face_enhancer_weight",
                    type="float",
                    panel="common",
                    section="face_enhancer",
                    section_label="人脸增强",
                    label="增强权重",
                    minimum=face_enhancer_choices.face_enhancer_weight_range[0],
                    maximum=face_enhancer_choices.face_enhancer_weight_range[-1],
                    step=0.05,
                    default=defaults["face_enhancer_weight"],
                    requires_processors=["face_enhancer"],
                ),
                field(
                    "frame_enhancer_model",
                    type="select",
                    panel="common",
                    section="frame_enhancer",
                    section_label="画面增强",
                    label="增强模型",
                    choices=list(frame_enhancer_choices.frame_enhancer_models),
                    default=defaults["frame_enhancer_model"],
                    requires_processors=["frame_enhancer"],
                ),
                field(
                    "frame_enhancer_blend",
                    type="int",
                    panel="common",
                    section="frame_enhancer",
                    section_label="画面增强",
                    label="增强混合",
                    minimum=frame_enhancer_choices.frame_enhancer_blend_range[0],
                    maximum=frame_enhancer_choices.frame_enhancer_blend_range[-1],
                    step=1,
                    default=defaults["frame_enhancer_blend"],
                    requires_processors=["frame_enhancer"],
                ),
                field(
                    "output_image_quality",
                    type="int",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="图片质量",
                    minimum=facefusion_choices.output_image_quality_range[0],
                    maximum=facefusion_choices.output_image_quality_range[-1],
                    step=1,
                    default=defaults["output_image_quality"],
                    visible_for=["image"],
                ),
                field(
                    "output_image_scale",
                    type="float",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="图片缩放",
                    minimum=facefusion_choices.output_image_scale_range[0],
                    maximum=facefusion_choices.output_image_scale_range[-1],
                    step=0.25,
                    default=defaults["output_image_scale"],
                    visible_for=["image"],
                ),
                field(
                    "output_video_encoder",
                    type="select",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="视频编码器",
                    choices=list(facefusion_choices.output_video_encoders),
                    default=defaults["output_video_encoder"],
                    visible_for=["video"],
                ),
                field(
                    "output_video_preset",
                    type="select",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="视频预设",
                    choices=list(facefusion_choices.output_video_presets),
                    default=defaults["output_video_preset"],
                    visible_for=["video"],
                ),
                field(
                    "output_video_quality",
                    type="int",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="视频质量",
                    minimum=facefusion_choices.output_video_quality_range[0],
                    maximum=facefusion_choices.output_video_quality_range[-1],
                    step=1,
                    default=defaults["output_video_quality"],
                    visible_for=["video"],
                ),
                field(
                    "output_video_scale",
                    type="float",
                    panel="common",
                    section="output",
                    section_label="输出参数",
                    label="视频缩放",
                    minimum=facefusion_choices.output_video_scale_range[0],
                    maximum=facefusion_choices.output_video_scale_range[-1],
                    step=0.25,
                    default=defaults["output_video_scale"],
                    visible_for=["video"],
                ),
                field(
                    "preview_resolution",
                    type="select",
                    panel="common",
                    section="preview",
                    section_label="预览参数",
                    label="预览分辨率",
                    choices=list(ui_choices.preview_resolutions),
                    default=defaults["preview_resolution"],
                ),
                field(
                    "age_modifier_model",
                    type="select",
                    panel="advanced",
                    section="age_modifier",
                    section_label="年龄修改",
                    label="模型",
                    choices=list(age_modifier_choices.age_modifier_models),
                    default=defaults["age_modifier_model"],
                    requires_processors=["age_modifier"],
                ),
                field(
                    "age_modifier_direction",
                    type="int",
                    panel="advanced",
                    section="age_modifier",
                    section_label="年龄修改",
                    label="方向",
                    minimum=age_modifier_choices.age_modifier_direction_range[0],
                    maximum=age_modifier_choices.age_modifier_direction_range[-1],
                    step=1,
                    default=defaults["age_modifier_direction"],
                    requires_processors=["age_modifier"],
                ),
                field(
                    "background_remover_model",
                    type="select",
                    panel="advanced",
                    section="background_remover",
                    section_label="背景移除",
                    label="模型",
                    choices=list(background_remover_choices.background_remover_models),
                    default=defaults["background_remover_model"],
                    requires_processors=["background_remover"],
                ),
                field(
                    "background_remover_fill_color",
                    type="int_list",
                    panel="advanced",
                    section="background_remover",
                    section_label="背景移除",
                    label="填充颜色 RGBA",
                    minimum=background_remover_choices.background_remover_color_range[0],
                    maximum=background_remover_choices.background_remover_color_range[-1],
                    step=1,
                    default=defaults["background_remover_fill_color"],
                    requires_processors=["background_remover"],
                    control="rgba",
                ),
                field(
                    "background_remover_despill_color",
                    type="int_list",
                    panel="advanced",
                    section="background_remover",
                    section_label="背景移除",
                    label="去溢色 RGBA",
                    minimum=background_remover_choices.background_remover_color_range[0],
                    maximum=background_remover_choices.background_remover_color_range[-1],
                    step=1,
                    default=defaults["background_remover_despill_color"],
                    requires_processors=["background_remover"],
                    control="rgba",
                ),
                field(
                    "deep_swapper_model",
                    type="select",
                    panel="advanced",
                    section="deep_swapper",
                    section_label="深度换脸",
                    label="模型",
                    choices=list(deep_swapper_choices.deep_swapper_models),
                    default=defaults["deep_swapper_model"],
                    requires_processors=["deep_swapper"],
                ),
                field(
                    "deep_swapper_morph",
                    type="int",
                    panel="advanced",
                    section="deep_swapper",
                    section_label="深度换脸",
                    label="形变强度",
                    minimum=deep_swapper_choices.deep_swapper_morph_range[0],
                    maximum=deep_swapper_choices.deep_swapper_morph_range[-1],
                    step=1,
                    default=defaults["deep_swapper_morph"],
                    requires_processors=["deep_swapper"],
                ),
                field(
                    "expression_restorer_model",
                    type="select",
                    panel="advanced",
                    section="expression_restorer",
                    section_label="表情修复",
                    label="模型",
                    choices=list(expression_restorer_choices.expression_restorer_models),
                    default=defaults["expression_restorer_model"],
                    requires_processors=["expression_restorer"],
                ),
                field(
                    "expression_restorer_factor",
                    type="int",
                    panel="advanced",
                    section="expression_restorer",
                    section_label="表情修复",
                    label="修复强度",
                    minimum=expression_restorer_choices.expression_restorer_factor_range[0],
                    maximum=expression_restorer_choices.expression_restorer_factor_range[-1],
                    step=1,
                    default=defaults["expression_restorer_factor"],
                    requires_processors=["expression_restorer"],
                ),
                field(
                    "expression_restorer_areas",
                    type="multi_select",
                    panel="advanced",
                    section="expression_restorer",
                    section_label="表情修复",
                    label="修复区域",
                    choices=list(expression_restorer_choices.expression_restorer_areas),
                    default=defaults["expression_restorer_areas"],
                    requires_processors=["expression_restorer"],
                ),
                field(
                    "face_debugger_items",
                    type="multi_select",
                    panel="advanced",
                    section="face_debugger",
                    section_label="人脸调试",
                    label="调试项目",
                    choices=list(face_debugger_choices.face_debugger_items),
                    default=defaults["face_debugger_items"],
                    requires_processors=["face_debugger"],
                ),
                field(
                    "face_editor_model",
                    type="select",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="模型",
                    choices=list(face_editor_choices.face_editor_models),
                    default=defaults["face_editor_model"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_eyebrow_direction",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="眉毛方向",
                    minimum=face_editor_choices.face_editor_eyebrow_direction_range[0],
                    maximum=face_editor_choices.face_editor_eyebrow_direction_range[-1],
                    step=0.05,
                    default=defaults["face_editor_eyebrow_direction"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_eye_gaze_horizontal",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="眼睛水平视线",
                    minimum=face_editor_choices.face_editor_eye_gaze_horizontal_range[0],
                    maximum=face_editor_choices.face_editor_eye_gaze_horizontal_range[-1],
                    step=0.05,
                    default=defaults["face_editor_eye_gaze_horizontal"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_eye_gaze_vertical",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="眼睛垂直视线",
                    minimum=face_editor_choices.face_editor_eye_gaze_vertical_range[0],
                    maximum=face_editor_choices.face_editor_eye_gaze_vertical_range[-1],
                    step=0.05,
                    default=defaults["face_editor_eye_gaze_vertical"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_eye_open_ratio",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="眼睛张开比例",
                    minimum=face_editor_choices.face_editor_eye_open_ratio_range[0],
                    maximum=face_editor_choices.face_editor_eye_open_ratio_range[-1],
                    step=0.05,
                    default=defaults["face_editor_eye_open_ratio"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_lip_open_ratio",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴唇张开比例",
                    minimum=face_editor_choices.face_editor_lip_open_ratio_range[0],
                    maximum=face_editor_choices.face_editor_lip_open_ratio_range[-1],
                    step=0.05,
                    default=defaults["face_editor_lip_open_ratio"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_grim",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴型 grim",
                    minimum=face_editor_choices.face_editor_mouth_grim_range[0],
                    maximum=face_editor_choices.face_editor_mouth_grim_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_grim"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_pout",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴型 pout",
                    minimum=face_editor_choices.face_editor_mouth_pout_range[0],
                    maximum=face_editor_choices.face_editor_mouth_pout_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_pout"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_purse",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴型 purse",
                    minimum=face_editor_choices.face_editor_mouth_purse_range[0],
                    maximum=face_editor_choices.face_editor_mouth_purse_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_purse"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_smile",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴角微笑",
                    minimum=face_editor_choices.face_editor_mouth_smile_range[0],
                    maximum=face_editor_choices.face_editor_mouth_smile_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_smile"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_position_horizontal",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴巴水平位移",
                    minimum=face_editor_choices.face_editor_mouth_position_horizontal_range[0],
                    maximum=face_editor_choices.face_editor_mouth_position_horizontal_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_position_horizontal"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_mouth_position_vertical",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="嘴巴垂直位移",
                    minimum=face_editor_choices.face_editor_mouth_position_vertical_range[0],
                    maximum=face_editor_choices.face_editor_mouth_position_vertical_range[-1],
                    step=0.05,
                    default=defaults["face_editor_mouth_position_vertical"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_head_pitch",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="头部 pitch",
                    minimum=face_editor_choices.face_editor_head_pitch_range[0],
                    maximum=face_editor_choices.face_editor_head_pitch_range[-1],
                    step=0.05,
                    default=defaults["face_editor_head_pitch"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_head_yaw",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="头部 yaw",
                    minimum=face_editor_choices.face_editor_head_yaw_range[0],
                    maximum=face_editor_choices.face_editor_head_yaw_range[-1],
                    step=0.05,
                    default=defaults["face_editor_head_yaw"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "face_editor_head_roll",
                    type="float",
                    panel="advanced",
                    section="face_editor",
                    section_label="人脸编辑",
                    label="头部 roll",
                    minimum=face_editor_choices.face_editor_head_roll_range[0],
                    maximum=face_editor_choices.face_editor_head_roll_range[-1],
                    step=0.05,
                    default=defaults["face_editor_head_roll"],
                    requires_processors=["face_editor"],
                ),
                field(
                    "frame_colorizer_model",
                    type="select",
                    panel="advanced",
                    section="frame_colorizer",
                    section_label="画面上色",
                    label="模型",
                    choices=list(frame_colorizer_choices.frame_colorizer_models),
                    default=defaults["frame_colorizer_model"],
                    requires_processors=["frame_colorizer"],
                ),
                field(
                    "frame_colorizer_size",
                    type="select",
                    panel="advanced",
                    section="frame_colorizer",
                    section_label="画面上色",
                    label="处理尺寸",
                    choices=list(frame_colorizer_choices.frame_colorizer_sizes),
                    default=defaults["frame_colorizer_size"],
                    requires_processors=["frame_colorizer"],
                ),
                field(
                    "frame_colorizer_blend",
                    type="int",
                    panel="advanced",
                    section="frame_colorizer",
                    section_label="画面上色",
                    label="混合强度",
                    minimum=frame_colorizer_choices.frame_colorizer_blend_range[0],
                    maximum=frame_colorizer_choices.frame_colorizer_blend_range[-1],
                    step=1,
                    default=defaults["frame_colorizer_blend"],
                    requires_processors=["frame_colorizer"],
                ),
                field(
                    "lip_syncer_model",
                    type="select",
                    panel="advanced",
                    section="lip_syncer",
                    section_label="唇形同步",
                    label="模型",
                    choices=list(lip_syncer_choices.lip_syncer_models),
                    default=defaults["lip_syncer_model"],
                    requires_processors=["lip_syncer"],
                ),
                field(
                    "lip_syncer_weight",
                    type="float",
                    panel="advanced",
                    section="lip_syncer",
                    section_label="唇形同步",
                    label="权重",
                    minimum=lip_syncer_choices.lip_syncer_weight_range[0],
                    maximum=lip_syncer_choices.lip_syncer_weight_range[-1],
                    step=0.05,
                    default=defaults["lip_syncer_weight"],
                    requires_processors=["lip_syncer"],
                ),
                field(
                    "face_selector_mode",
                    type="select",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="选择模式",
                    choices=list(facefusion_choices.face_selector_modes),
                    default=defaults["face_selector_mode"],
                ),
                field(
                    "face_selector_order",
                    type="select",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="排序方式",
                    choices=list(facefusion_choices.face_selector_orders),
                    default=defaults["face_selector_order"],
                ),
                field(
                    "face_selector_gender",
                    type="select",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="性别过滤",
                    choices=["none", *list(facefusion_choices.face_selector_genders)],
                    default=defaults["face_selector_gender"],
                ),
                field(
                    "face_selector_race",
                    type="select",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="种族过滤",
                    choices=["none", *list(facefusion_choices.face_selector_races)],
                    default=defaults["face_selector_race"],
                ),
                field(
                    "face_selector_age_start",
                    type="int",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="年龄范围",
                    minimum=facefusion_choices.face_selector_age_range[0],
                    maximum=facefusion_choices.face_selector_age_range[-1],
                    step=1,
                    default=defaults["face_selector_age_start"],
                    control="range",
                    paired_key="face_selector_age_end",
                    pair_label="年龄结束",
                ),
                field(
                    "reference_face_distance",
                    type="float",
                    panel="advanced",
                    section="face_selector",
                    section_label="人脸选择",
                    label="参考脸距离",
                    minimum=facefusion_choices.reference_face_distance_range[0],
                    maximum=facefusion_choices.reference_face_distance_range[-1],
                    step=0.05,
                    default=defaults["reference_face_distance"],
                    depends_on="face_selector_mode",
                    depends_values=["reference"],
                ),
                field(
                    "face_detector_model",
                    type="select",
                    panel="advanced",
                    section="face_detector",
                    section_label="人脸检测",
                    label="检测模型",
                    choices=list(facefusion_choices.face_detector_models),
                    default=defaults["face_detector_model"],
                ),
                field(
                    "face_detector_size",
                    type="select",
                    panel="advanced",
                    section="face_detector",
                    section_label="人脸检测",
                    label="检测尺寸",
                    choices=facefusion_choices.face_detector_set.get(options.get("face_detector_model"), []) or facefusion_choices.face_detector_set.get(defaults["face_detector_model"], []),
                    default=defaults["face_detector_size"],
                    depends_on="face_detector_model",
                ),
                field(
                    "face_detector_margin",
                    type="int_list",
                    panel="advanced",
                    section="face_detector",
                    section_label="人脸检测",
                    label="检测边距",
                    minimum=facefusion_choices.face_detector_margin_range[0],
                    maximum=facefusion_choices.face_detector_margin_range[-1],
                    step=1,
                    default=defaults["face_detector_margin"],
                    control="uniform_tuple4",
                ),
                field(
                    "face_detector_angles",
                    type="multi_select",
                    panel="advanced",
                    section="face_detector",
                    section_label="人脸检测",
                    label="检测角度",
                    choices=list(facefusion_choices.face_detector_angles),
                    default=defaults["face_detector_angles"],
                ),
                field(
                    "face_detector_score",
                    type="float",
                    panel="advanced",
                    section="face_detector",
                    section_label="人脸检测",
                    label="检测阈值",
                    minimum=facefusion_choices.face_detector_score_range[0],
                    maximum=facefusion_choices.face_detector_score_range[-1],
                    step=0.05,
                    default=defaults["face_detector_score"],
                ),
                field(
                    "face_landmarker_model",
                    type="select",
                    panel="advanced",
                    section="face_landmarker",
                    section_label="特征点检测",
                    label="特征点模型",
                    choices=list(facefusion_choices.face_landmarker_models),
                    default=defaults["face_landmarker_model"],
                ),
                field(
                    "face_landmarker_score",
                    type="float",
                    panel="advanced",
                    section="face_landmarker",
                    section_label="特征点检测",
                    label="特征点阈值",
                    minimum=facefusion_choices.face_landmarker_score_range[0],
                    maximum=facefusion_choices.face_landmarker_score_range[-1],
                    step=0.05,
                    default=defaults["face_landmarker_score"],
                ),
                field(
                    "face_occluder_model",
                    type="select",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮挡模型",
                    choices=list(facefusion_choices.face_occluder_models),
                    default=defaults["face_occluder_model"],
                ),
                field(
                    "face_parser_model",
                    type="select",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="解析模型",
                    choices=list(facefusion_choices.face_parser_models),
                    default=defaults["face_parser_model"],
                ),
                field(
                    "face_mask_types",
                    type="multi_select",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮罩类型",
                    choices=list(facefusion_choices.face_mask_types),
                    default=defaults["face_mask_types"],
                ),
                field(
                    "face_mask_areas",
                    type="multi_select",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮罩区域",
                    choices=list(facefusion_choices.face_mask_areas),
                    default=defaults["face_mask_areas"],
                    depends_on="face_mask_types",
                    depends_values=["area"],
                ),
                field(
                    "face_mask_regions",
                    type="multi_select",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮罩部位",
                    choices=list(facefusion_choices.face_mask_regions),
                    default=defaults["face_mask_regions"],
                    depends_on="face_mask_types",
                    depends_values=["region"],
                ),
                field(
                    "face_mask_blur",
                    type="float",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮罩模糊",
                    minimum=facefusion_choices.face_mask_blur_range[0],
                    maximum=facefusion_choices.face_mask_blur_range[-1],
                    step=0.05,
                    default=defaults["face_mask_blur"],
                    depends_on="face_mask_types",
                    depends_values=["box"],
                ),
                field(
                    "face_mask_padding",
                    type="int_list",
                    panel="advanced",
                    section="face_masker",
                    section_label="人脸遮罩",
                    label="遮罩四向留白",
                    minimum=facefusion_choices.face_mask_padding_range[0],
                    maximum=facefusion_choices.face_mask_padding_range[-1],
                    step=1,
                    default=defaults["face_mask_padding"],
                    depends_on="face_mask_types",
                    depends_values=["box"],
                    control="tuple4",
                ),
                field(
                    "output_audio_encoder",
                    type="select",
                    panel="advanced",
                    section="audio_output",
                    section_label="音频输出",
                    label="音频编码器",
                    choices=list(facefusion_choices.output_audio_encoders),
                    default=defaults["output_audio_encoder"],
                    visible_for=["video"],
                ),
                field(
                    "output_audio_quality",
                    type="int",
                    panel="advanced",
                    section="audio_output",
                    section_label="音频输出",
                    label="音频质量",
                    minimum=facefusion_choices.output_audio_quality_range[0],
                    maximum=facefusion_choices.output_audio_quality_range[-1],
                    step=1,
                    default=defaults["output_audio_quality"],
                    visible_for=["video"],
                ),
                field(
                    "output_audio_volume",
                    type="int",
                    panel="advanced",
                    section="audio_output",
                    section_label="音频输出",
                    label="音量",
                    minimum=facefusion_choices.output_audio_volume_range[0],
                    maximum=facefusion_choices.output_audio_volume_range[-1],
                    step=1,
                    default=defaults["output_audio_volume"],
                    visible_for=["video"],
                ),
                field(
                    "output_video_fps",
                    type="float",
                    panel="advanced",
                    section="frame_processing",
                    section_label="视频帧处理",
                    label="输出 FPS",
                    minimum=1.0,
                    maximum=60.0,
                    step=0.01,
                    default=defaults["output_video_fps"],
                    visible_for=["video"],
                ),
                field(
                    "temp_frame_format",
                    type="select",
                    panel="advanced",
                    section="frame_processing",
                    section_label="视频帧处理",
                    label="临时帧格式",
                    choices=list(facefusion_choices.temp_frame_formats),
                    default=defaults["temp_frame_format"],
                    visible_for=["video"],
                ),
                field(
                    "keep_temp",
                    type="bool",
                    panel="advanced",
                    section="frame_processing",
                    section_label="视频帧处理",
                    label="保留临时文件",
                    default=defaults["keep_temp"],
                    visible_for=["video"],
                ),
                field(
                    "trim_frame_start",
                    type="int",
                    panel="advanced",
                    section="frame_processing",
                    section_label="视频帧处理",
                    label="裁剪帧范围",
                    minimum=0,
                    step=1,
                    default=defaults["trim_frame_start"],
                    visible_for=["video"],
                    control="frame_range",
                    paired_key="trim_frame_end",
                    pair_label="裁剪结束帧",
                ),
                field(
                    "voice_extractor_model",
                    type="select",
                    panel="advanced",
                    section="frame_processing",
                    section_label="视频帧处理",
                    label="语音提取模型",
                    choices=list(facefusion_choices.voice_extractor_models),
                    default=defaults["voice_extractor_model"],
                    visible_for=["video"],
                ),
                field(
                    "execution_thread_count",
                    type="int",
                    panel="advanced",
                    section="execution",
                    section_label="执行设置",
                    label="执行线程数",
                    minimum=facefusion_choices.execution_thread_count_range[0],
                    maximum=facefusion_choices.execution_thread_count_range[-1],
                    step=1,
                    default=defaults["execution_thread_count"],
                ),
                field(
                    "preview_mode",
                    type="select",
                    panel="advanced",
                    section="preview_advanced",
                    section_label="预览参数",
                    label="预览模式",
                    choices=list(ui_choices.preview_modes),
                    default=defaults["preview_mode"],
                ),
                field(
                    "preview_frame_number",
                    type="int",
                    panel="advanced",
                    section="preview_advanced",
                    section_label="预览参数",
                    label="预览帧号",
                    minimum=0,
                    default=defaults["preview_frame_number"],
                    visible_for=["video"],
                ),
            ],
        )

        return {
            "version": 2,
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

        def has_processor(name: str) -> bool:
            return name in processors

        def extend_list_option(flag: str, values: Any) -> None:
            if not isinstance(values, list) or not values:
                return
            cli_args.extend([flag, *[str(item) for item in values if item is not None]])

        if processors:
            cli_args.extend(["--processors", *processors])

        if has_processor("age_modifier"):
            if options.get("age_modifier_model") is not None:
                cli_args.extend(["--age-modifier-model", str(options["age_modifier_model"])])
            if options.get("age_modifier_direction") is not None:
                cli_args.extend(["--age-modifier-direction", str(options["age_modifier_direction"])])

        if has_processor("background_remover"):
            if options.get("background_remover_model") is not None:
                cli_args.extend(
                    ["--background-remover-model", str(options["background_remover_model"])],
                )
            extend_list_option("--background-remover-fill-color", options.get("background_remover_fill_color"))
            extend_list_option(
                "--background-remover-despill-color",
                options.get("background_remover_despill_color"),
            )

        if has_processor("deep_swapper"):
            if options.get("deep_swapper_model") is not None:
                cli_args.extend(["--deep-swapper-model", str(options["deep_swapper_model"])])
            if options.get("deep_swapper_morph") is not None:
                cli_args.extend(["--deep-swapper-morph", str(options["deep_swapper_morph"])])

        if has_processor("expression_restorer"):
            if options.get("expression_restorer_model") is not None:
                cli_args.extend(
                    ["--expression-restorer-model", str(options["expression_restorer_model"])],
                )
            if options.get("expression_restorer_factor") is not None:
                cli_args.extend(
                    ["--expression-restorer-factor", str(options["expression_restorer_factor"])],
                )
            extend_list_option(
                "--expression-restorer-areas",
                options.get("expression_restorer_areas"),
            )

        if has_processor("face_debugger"):
            extend_list_option("--face-debugger-items", options.get("face_debugger_items"))

        if has_processor("face_editor"):
            if options.get("face_editor_model") is not None:
                cli_args.extend(["--face-editor-model", str(options["face_editor_model"])])
            for key, flag in [
                ("face_editor_eyebrow_direction", "--face-editor-eyebrow-direction"),
                ("face_editor_eye_gaze_horizontal", "--face-editor-eye-gaze-horizontal"),
                ("face_editor_eye_gaze_vertical", "--face-editor-eye-gaze-vertical"),
                ("face_editor_eye_open_ratio", "--face-editor-eye-open-ratio"),
                ("face_editor_lip_open_ratio", "--face-editor-lip-open-ratio"),
                ("face_editor_mouth_grim", "--face-editor-mouth-grim"),
                ("face_editor_mouth_pout", "--face-editor-mouth-pout"),
                ("face_editor_mouth_purse", "--face-editor-mouth-purse"),
                ("face_editor_mouth_smile", "--face-editor-mouth-smile"),
                ("face_editor_mouth_position_horizontal", "--face-editor-mouth-position-horizontal"),
                ("face_editor_mouth_position_vertical", "--face-editor-mouth-position-vertical"),
                ("face_editor_head_pitch", "--face-editor-head-pitch"),
                ("face_editor_head_yaw", "--face-editor-head-yaw"),
                ("face_editor_head_roll", "--face-editor-head-roll"),
            ]:
                if options.get(key) is not None:
                    cli_args.extend([flag, str(options[key])])

        if options.get("face_selector_mode") is not None:
            cli_args.extend(["--face-selector-mode", str(options["face_selector_mode"])])
        if options.get("face_selector_order") is not None:
            cli_args.extend(["--face-selector-order", str(options["face_selector_order"])])
        if options.get("face_selector_gender") is not None:
            cli_args.extend(["--face-selector-gender", str(options["face_selector_gender"])])
        if options.get("face_selector_race") is not None:
            cli_args.extend(["--face-selector-race", str(options["face_selector_race"])])
        if options.get("face_selector_age_start") is not None:
            cli_args.extend(["--face-selector-age-start", str(options["face_selector_age_start"])])
        if options.get("face_selector_age_end") is not None:
            cli_args.extend(["--face-selector-age-end", str(options["face_selector_age_end"])])
        if options.get("reference_face_position") is not None:
            cli_args.extend(["--reference-face-position", str(options["reference_face_position"])])
        if options.get("reference_face_distance") is not None:
            cli_args.extend(["--reference-face-distance", str(options["reference_face_distance"])])
        if options.get("preview_frame_number") is not None:
            cli_args.extend(["--reference-frame-number", str(options["preview_frame_number"])])

        if options.get("face_detector_model") is not None:
            cli_args.extend(["--face-detector-model", str(options["face_detector_model"])])
        if options.get("face_detector_size") is not None:
            cli_args.extend(["--face-detector-size", str(options["face_detector_size"])])
        extend_list_option("--face-detector-margin", options.get("face_detector_margin"))
        extend_list_option("--face-detector-angles", options.get("face_detector_angles"))
        if options.get("face_detector_score") is not None:
            cli_args.extend(["--face-detector-score", str(options["face_detector_score"])])

        if options.get("face_landmarker_model") is not None:
            cli_args.extend(["--face-landmarker-model", str(options["face_landmarker_model"])])
        if options.get("face_landmarker_score") is not None:
            cli_args.extend(["--face-landmarker-score", str(options["face_landmarker_score"])])

        if options.get("face_occluder_model") is not None:
            cli_args.extend(["--face-occluder-model", str(options["face_occluder_model"])])
        if options.get("face_parser_model") is not None:
            cli_args.extend(["--face-parser-model", str(options["face_parser_model"])])
        extend_list_option("--face-mask-types", options.get("face_mask_types"))
        extend_list_option("--face-mask-areas", options.get("face_mask_areas"))
        extend_list_option("--face-mask-regions", options.get("face_mask_regions"))
        if options.get("face_mask_blur") is not None:
            cli_args.extend(["--face-mask-blur", str(options["face_mask_blur"])])
        extend_list_option("--face-mask-padding", options.get("face_mask_padding"))

        if has_processor("face_swapper"):
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

        if has_processor("frame_colorizer"):
            if options.get("frame_colorizer_model") is not None:
                cli_args.extend(
                    ["--frame-colorizer-model", str(options["frame_colorizer_model"])],
                )
            if options.get("frame_colorizer_size") is not None:
                cli_args.extend(
                    ["--frame-colorizer-size", str(options["frame_colorizer_size"])],
                )
            if options.get("frame_colorizer_blend") is not None:
                cli_args.extend(
                    ["--frame-colorizer-blend", str(options["frame_colorizer_blend"])],
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

        if has_processor("lip_syncer"):
            if options.get("lip_syncer_model") is not None:
                cli_args.extend(["--lip-syncer-model", str(options["lip_syncer_model"])])
            if options.get("lip_syncer_weight") is not None:
                cli_args.extend(["--lip-syncer-weight", str(options["lip_syncer_weight"])])

        if options.get("trim_frame_start") is not None:
            cli_args.extend(["--trim-frame-start", str(options["trim_frame_start"])])
        if options.get("trim_frame_end") is not None:
            cli_args.extend(["--trim-frame-end", str(options["trim_frame_end"])])
        if options.get("temp_frame_format") is not None:
            cli_args.extend(["--temp-frame-format", str(options["temp_frame_format"])])
        if options.get("keep_temp") is True:
            cli_args.append("--keep-temp")

        if options.get("voice_extractor_model") is not None:
            cli_args.extend(["--voice-extractor-model", str(options["voice_extractor_model"])])

        if options.get("output_image_quality") is not None:
            cli_args.extend(
                ["--output-image-quality", str(options["output_image_quality"])],
            )
        if options.get("output_image_scale") is not None:
            cli_args.extend(["--output-image-scale", str(options["output_image_scale"])])
        if options.get("output_audio_encoder") is not None:
            cli_args.extend(["--output-audio-encoder", str(options["output_audio_encoder"])])
        if options.get("output_audio_quality") is not None:
            cli_args.extend(["--output-audio-quality", str(options["output_audio_quality"])])
        if options.get("output_audio_volume") is not None:
            cli_args.extend(["--output-audio-volume", str(options["output_audio_volume"])])
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

    def _source_face_extractor_worker_path(self) -> Path:
        return self._studio_root / "bridge" / "services" / "source_face_extractor_worker.py"

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
        merged_options["content_analyser_score"] = self._normalize_content_analyser_score(
            self._settings.get("content_analyser_score"),
        )
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
        preview_output_path = preview_result.get("output_path") or preview_result.get("path")
        preview_result["media_url"] = self._media_url_for_path(preview_output_path)
        preview_result["workspace"] = self.workspace_state()
        preview_result["options"] = {
            "version": 1,
            "target_media_type": self._workspace_target_media_type(),
            "options": request_payload["options"],
        }
        return preview_result

    def _run_source_face_extractor(self, image_paths: list[str]) -> dict[str, Any]:
        output_dir = self._extracted_faces_dir / datetime.now().strftime("%Y-%m-%d-%H-%M-%S-%f")
        output_dir.mkdir(parents=True, exist_ok=True)
        request_payload = {
            "source_paths": image_paths,
            "output_dir": str(output_dir),
            "config_path": str(self._settings_path),
            "temp_path": str(self._temp_dir),
            "jobs_path": str(self._jobs_dir),
        }
        command = [sys.executable, str(self._source_face_extractor_worker_path())]
        self._append_log(f"[bridge] Source face extraction requested: {len(image_paths)} image(s).")

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
            self._append_log("[bridge] Source face extraction timed out after 300 seconds.")
            return {
                "ok": False,
                "message": "源脸提取超时，请减少图片数量后重试。",
                "faces": [],
                "skipped": [],
            }

        stderr_text = (result.stderr or "").strip()
        if stderr_text:
            for line in stderr_text.splitlines()[-20:]:
                line = line.strip()
                if line:
                    self._append_log(f"[extract] {line}")

        stdout_text = (result.stdout or "").strip()
        if not stdout_text:
            self._append_log(
                f"[bridge] Source face extraction failed with empty output, exit code {result.returncode}.",
            )
            return {
                "ok": False,
                "message": "源脸提取进程未返回结果。",
                "faces": [],
                "skipped": [],
            }

        try:
            extract_result = json.loads(stdout_text)
        except json.JSONDecodeError:
            self._append_log(
                f"[bridge] Source face extraction returned invalid JSON, exit code {result.returncode}.",
            )
            return {
                "ok": False,
                "message": "源脸提取结果解析失败。",
                "raw_output": stdout_text[:500],
                "faces": [],
                "skipped": [],
            }

        if result.returncode != 0 or not extract_result.get("ok"):
            message = extract_result.get("message") or "源脸提取失败。"
            self._append_log(f"[bridge] Source face extraction failed: {message}")
            return {
                **extract_result,
                "ok": False,
                "message": message,
                "faces": extract_result.get("faces") or [],
                "skipped": extract_result.get("skipped") or [],
            }

        self._append_log(f"[bridge] Source face extraction completed: {len(extract_result.get('faces') or [])} face(s).")
        return extract_result

    def extract_workspace_source_faces(self, source_paths: list[str]) -> dict[str, Any]:
        normalized = self._normalize_source_paths(source_paths)
        image_paths = [path for path in normalized if Path(path).suffix.lower() in IMAGE_EXTENSIONS]
        passthrough_paths = [path for path in normalized if Path(path).suffix.lower() in AUDIO_EXTENSIONS]

        if not normalized:
            return {
                "ok": False,
                "message": "请选择有效的源图片或音频文件。",
                "workspace": self.workspace_state(),
                "faces": [],
                "skipped": [],
            }

        if not image_paths:
            workspace = self.set_workspace_source_paths(normalized)
            return {
                "ok": True,
                "message": f"已更新源文件，共 {len(workspace['source_paths'])} 个。",
                "workspace": workspace,
                "faces": [],
                "skipped": [],
            }

        extract_result = self._run_source_face_extractor(image_paths)
        faces = [
            item
            for item in extract_result.get("faces") or []
            if isinstance(item, dict) and self._normalize_source_paths([item.get("face_path")])
        ]
        skipped = extract_result.get("skipped") or []
        extracted_by_source = {
            str(item.get("source_path")): str(item.get("face_path"))
            for item in faces
            if item.get("source_path") and item.get("face_path")
        }

        extracted_paths: list[str] = []
        for path in normalized:
            if Path(path).suffix.lower() in IMAGE_EXTENSIONS:
                extracted_path = extracted_by_source.get(path)
                if extracted_path:
                    extracted_paths.append(extracted_path)
            elif path in passthrough_paths:
                extracted_paths.append(path)

        if not extracted_paths or not faces:
            return {
                "ok": False,
                "message": extract_result.get("message") or "未能从源图片中检测到可用人脸。",
                "workspace": self.workspace_state(),
                "faces": faces,
                "skipped": skipped,
            }

        workspace = self.set_workspace_source_paths(extracted_paths)
        if skipped:
            message = f"已自动提取 {len(faces)} 张源脸，{len(skipped)} 个文件未检测到可用人脸。"
        else:
            message = f"已自动提取 {len(faces)} 张源脸。"
        return {
            "ok": True,
            "message": message,
            "workspace": workspace,
            "faces": faces,
            "skipped": skipped,
        }

    def _sanitize_persona_name(self, value: Any) -> str:
        name = str(value or "").strip()
        name = re.sub(r"[\r\n\t]+", " ", name)
        name = re.sub(r"\s{2,}", " ", name)
        return name[:80]

    def _create_persona_id(self, name: str) -> str:
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S%f")
        digest = hashlib.sha1(f"{timestamp}|{name}".encode("utf-8")).hexdigest()[:8]
        return f"persona-{timestamp}-{digest}"

    def _resolve_persona_dir(self, persona_id: Any) -> Path | None:
        raw_id = str(persona_id or "").strip()
        if not raw_id or not re.fullmatch(r"[A-Za-z0-9._-]+", raw_id):
            return None
        try:
            root = self._personas_dir.resolve()
            candidate = (self._personas_dir / raw_id).resolve()
            common_path = os.path.commonpath([str(root), str(candidate)])
        except (OSError, ValueError):
            return None
        if os.path.normcase(common_path) != os.path.normcase(str(root)):
            return None
        return candidate

    def _resolve_persona_media_path(self, persona_dir: Path, value: Any) -> str | None:
        raw_path = str(value or "").strip()
        if not raw_path:
            return None
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            candidate = persona_dir / candidate
        portable_path = self._resolve_portable_path(candidate, require_exists=True)
        if not portable_path:
            return None
        resolved = self._resolve_existing_path(Path(portable_path))
        if resolved.exists() and resolved.suffix.lower() in IMAGE_EXTENSIONS:
            return str(resolved)
        return None

    def _normalize_persona_manifest(self, persona_dir: Path, payload: Any) -> dict[str, Any] | None:
        if not isinstance(payload, dict):
            return None
        persona_id = str(payload.get("id") or persona_dir.name)
        name = self._sanitize_persona_name(payload.get("name")) or persona_id
        face_paths = []
        for item in payload.get("face_paths") or []:
            face_path = self._resolve_persona_media_path(persona_dir, item)
            if face_path:
                face_paths.append(face_path)
        if not face_paths:
            return None

        preview_path = self._resolve_persona_media_path(persona_dir, payload.get("preview_path"))
        if preview_path not in face_paths:
            preview_path = face_paths[0]
        source_paths = []
        for item in payload.get("source_paths") or []:
            portable_path = self._resolve_portable_path(item, require_exists=False)
            if portable_path:
                source_paths.append(portable_path)

        return {
            "id": persona_id,
            "name": name,
            "created_at": str(payload.get("created_at") or datetime.now().isoformat(timespec="seconds")),
            "updated_at": str(payload.get("updated_at") or payload.get("created_at") or datetime.now().isoformat(timespec="seconds")),
            "preview_path": preview_path,
            "face_paths": face_paths,
            "source_paths": source_paths,
            "face_count": len(face_paths),
        }

    def _read_persona_manifest(self, persona_dir: Path) -> dict[str, Any] | None:
        manifest_path = persona_dir / "manifest.json"
        if not manifest_path.exists():
            return None
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        return self._normalize_persona_manifest(persona_dir, payload)

    def _write_persona_manifest(self, persona_dir: Path, payload: dict[str, Any]) -> None:
        manifest_payload = dict(payload)
        manifest_payload["face_paths"] = [str(Path(path)) for path in payload.get("face_paths") or []]
        manifest_payload["source_paths"] = [str(Path(path)) for path in payload.get("source_paths") or []]
        manifest_payload["preview_path"] = str(Path(payload["preview_path"]))
        (persona_dir / "manifest.json").write_text(
            json.dumps(manifest_payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _read_extracted_face_score(self, face_path: str) -> float:
        path = Path(face_path)
        manifest_path = path.parent / "faces.json"
        if not manifest_path.exists():
            return 0.0
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return 0.0
        target_key = os.path.normcase(os.path.abspath(face_path))
        for item in payload.get("faces") or []:
            if not isinstance(item, dict):
                continue
            item_path = str(item.get("face_path") or "")
            if os.path.normcase(os.path.abspath(item_path)) == target_key:
                try:
                    return float(item.get("preview_score") or 0.0)
                except (TypeError, ValueError):
                    return 0.0
        return 0.0

    def _select_persona_preview_path(self, face_paths: list[str]) -> str:
        if not face_paths:
            return ""
        return max(face_paths, key=lambda path: self._read_extracted_face_score(path))

    def _save_persona_face_paths(
        self,
        name: str,
        face_source_paths: list[str],
        original_source_paths: list[str],
    ) -> dict[str, Any]:
        persona_id = self._create_persona_id(name)
        persona_dir = self._personas_dir / persona_id
        persona_dir.mkdir(parents=True, exist_ok=False)

        face_paths = []
        for index, source_path in enumerate(face_source_paths, start=1):
            source = Path(source_path)
            target = persona_dir / f"{index:03d}{source.suffix.lower()}"
            shutil.copy2(source, target)
            face_paths.append(str(self._resolve_existing_path(target)))

        preview_path = self._select_persona_preview_path(face_source_paths)
        if preview_path in face_source_paths:
            preview_index = face_source_paths.index(preview_path)
            preview_path = face_paths[preview_index]
        else:
            preview_path = face_paths[0]

        timestamp = datetime.now().isoformat(timespec="seconds")
        manifest = {
            "id": persona_id,
            "name": name,
            "created_at": timestamp,
            "updated_at": timestamp,
            "preview_path": preview_path,
            "face_paths": face_paths,
            "source_paths": original_source_paths,
            "face_count": len(face_paths),
        }
        self._write_persona_manifest(persona_dir, manifest)
        persona = self._read_persona_manifest(persona_dir) or manifest
        self._append_log(f"[bridge] Saved persona {persona_id}: {len(face_paths)} face image(s).")
        return {
            "ok": True,
            "message": f"已保存人物形象：{name}",
            "persona": persona,
        }

    def list_personas(self) -> dict[str, Any]:
        items = []
        if self._personas_dir.exists():
            for persona_dir in sorted(self._personas_dir.iterdir(), key=lambda item: item.name):
                if not persona_dir.is_dir():
                    continue
                manifest = self._read_persona_manifest(persona_dir)
                if manifest:
                    items.append(manifest)
        items.sort(key=lambda item: item.get("updated_at") or "", reverse=True)
        return {
            "root": str(self._personas_dir),
            "items": items,
        }

    def save_workspace_persona(self, payload: dict[str, Any]) -> dict[str, Any]:
        name = self._sanitize_persona_name(payload.get("name"))
        if not name:
            return {
                "ok": False,
                "message": "请输入人物形象名称。",
                "workspace": self.workspace_state(),
            }

        workspace = self.workspace_state()
        source_paths = [
            path
            for path in workspace.get("source_paths") or []
            if Path(path).suffix.lower() in IMAGE_EXTENSIONS and Path(path).exists()
        ]
        if not source_paths:
            return {
                "ok": False,
                "message": "当前工作台没有可保存的人物脸部图片。",
                "workspace": workspace,
            }

        result = self._save_persona_face_paths(name, source_paths, source_paths)
        result["workspace"] = self.workspace_state()
        return result

    def save_persona_from_images(self, payload: dict[str, Any]) -> dict[str, Any]:
        name = self._sanitize_persona_name(payload.get("name"))
        if not name:
            return {
                "ok": False,
                "message": "请输入人物形象名称。",
                "workspace": self.workspace_state(),
                "faces": [],
                "skipped": [],
            }

        normalized = self._normalize_source_paths(payload.get("paths") or [])
        image_paths = [
            path
            for path in normalized
            if Path(path).suffix.lower() in IMAGE_EXTENSIONS and Path(path).exists()
        ]
        if not image_paths:
            return {
                "ok": False,
                "message": "请选择有效的人物图片。",
                "workspace": self.workspace_state(),
                "faces": [],
                "skipped": [],
            }

        extract_result = self._run_source_face_extractor(image_paths)
        faces = [
            item
            for item in extract_result.get("faces") or []
            if isinstance(item, dict) and self._normalize_source_paths([item.get("face_path")])
        ]
        skipped = extract_result.get("skipped") or []
        face_paths = [
            str(item.get("face_path"))
            for item in faces
            if item.get("face_path")
        ]
        if not face_paths:
            return {
                "ok": False,
                "message": extract_result.get("message") or "未能从图片中检测到可用人脸。",
                "workspace": self.workspace_state(),
                "faces": faces,
                "skipped": skipped,
            }

        result = self._save_persona_face_paths(name, face_paths, image_paths)
        if skipped:
            result["message"] = f"{result['message']}，{len(skipped)} 个文件未检测到可用人脸。"
        result["workspace"] = self.workspace_state()
        result["faces"] = faces
        result["skipped"] = skipped
        return result

    def use_persona(self, persona_id: str) -> dict[str, Any]:
        persona_dir = self._resolve_persona_dir(persona_id)
        if persona_dir is None or not persona_dir.exists():
            return {
                "ok": False,
                "message": "人物形象不存在。",
                "workspace": self.workspace_state(),
            }
        persona = self._read_persona_manifest(persona_dir)
        if not persona:
            return {
                "ok": False,
                "message": "人物形象数据无效。",
                "workspace": self.workspace_state(),
            }
        workspace = self.set_workspace_source_paths(persona["face_paths"])
        self._append_log(f"[bridge] Loaded persona {persona['id']} into workspace.")
        return {
            "ok": True,
            "message": f"已加载人物形象：{persona['name']}",
            "persona": persona,
            "workspace": workspace,
        }

    def delete_persona(self, persona_id: str) -> dict[str, Any]:
        persona_dir = self._resolve_persona_dir(persona_id)
        if persona_dir is None or not persona_dir.exists():
            return {
                "ok": False,
                "message": "人物形象不存在。",
                **self.list_personas(),
            }
        persona = self._read_persona_manifest(persona_dir)
        try:
            shutil.rmtree(persona_dir)
        except OSError as error:
            return {
                "ok": False,
                "message": f"删除人物形象失败：{error}",
                **self.list_personas(),
            }
        label = persona["name"] if persona else persona_id
        self._append_log(f"[bridge] Deleted persona {persona_id}.")
        return {
            "ok": True,
            "message": f"已删除人物形象：{label}",
            **self.list_personas(),
        }

    def open_persona_directory(self, persona_id: str) -> dict[str, Any]:
        persona_dir = self._resolve_persona_dir(persona_id)
        if persona_dir is None or not persona_dir.exists():
            return {"ok": False, "message": "人物形象不存在。"}
        try:
            if os.name == "nt":
                os.startfile(str(persona_dir))
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(persona_dir)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            else:
                subprocess.Popen(["xdg-open", str(persona_dir)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError as error:
            self._append_log(f"[bridge] Open persona directory failed: {persona_dir} ({error})")
            return {"ok": False, "message": f"打开目录失败：{error}"}
        self._append_log(f"[bridge] Opened persona directory: {persona_dir}")
        return {"ok": True, "path": str(persona_dir)}

    def _normalize_source_paths(self, paths: Any) -> list[str]:
        if not isinstance(paths, list):
            return []
        normalized = []
        for item in paths:
            portable_path = self._resolve_portable_path(item, require_exists=True)
            if not portable_path:
                continue
            candidate = Path(portable_path)
            if candidate.exists() and candidate.suffix.lower() in AUDIO_EXTENSIONS.union(IMAGE_EXTENSIONS):
                normalized.append(str(candidate))
        return normalized

    def _normalize_target_path(self, path: Any) -> str | None:
        if not path:
            return None
        portable_path = self._resolve_portable_path(path, require_exists=True)
        if not portable_path:
            return None
        candidate = Path(portable_path)
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
        output_extension = get_output_file_extension(
            target_path,
            self._workspace_options.get("output_video_encoder"),
        ) or Path(target_path).suffix.lower()
        output_path = output_directory / f"{output_name}{output_extension}"
        return str(self._find_available_output_path(output_path))

    def _find_available_output_path(self, output_path: Path) -> Path:
        if not output_path.exists():
            return output_path

        output_directory = output_path.parent
        output_name = output_path.stem
        output_extension = output_path.suffix
        index = 1
        while True:
            candidate_path = output_directory / f"{output_name}_{index:03d}{output_extension}"
            if not candidate_path.exists():
                return candidate_path
            index += 1

    def _suggest_studio_job_id(self) -> str:
        base_job_id = "studio-" + datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
        job_id = base_job_id
        index = 1
        while any((self._jobs_dir / job_status / f"{job_id}.json").exists() for job_status in JOB_STATUSES):
            job_id = f"{base_job_id}_{index:03d}"
            index += 1
        return job_id

    def _find_workspace_source_thumbnail(self) -> str | None:
        for source_path in self._workspace_state.get("source_paths", []):
            thumbnail = self._resolve_thumbnail(source_path)
            if thumbnail:
                return thumbnail
        return None

    def _workspace_target_media_type(self) -> str | None:
        target_path = self._workspace_state.get("target_path")
        return self._media_type_for_path(target_path)

    def _workspace_target_video_frame_total(self, target_path: str | None) -> int | None:
        if not target_path or self._media_type_for_path(target_path) != "video":
            return None

        cache = getattr(self, "_workspace_video_frame_total_cache", {})
        if target_path in cache:
            return cache[target_path]

        frame_total = count_video_frame_total(target_path)
        normalized_frame_total = frame_total if frame_total > 1 else None
        cache[target_path] = normalized_frame_total
        self._workspace_video_frame_total_cache = cache
        return normalized_frame_total

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

    def _studio_web_root(self) -> Path:
        return getattr(
            self,
            "_flutter_web_root",
            self._studio_root / "flutter_app" / "build" / "web",
        )

    def _studio_upload_root(self) -> Path:
        return getattr(
            self,
            "_studio_uploads_dir",
            self._studio_root / "data" / "uploads" / "workspace",
        )

    def _studio_url_for_host(self, host: str) -> str:
        return f"http://{host}:{BRIDGE_PORT}/studio/"

    def _lan_ipv4_addresses(self) -> list[str]:
        addresses: set[str] = set()
        try:
            for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                address = item[4][0]
                if address and not address.startswith("127."):
                    addresses.add(address)
        except OSError:
            pass
        try:
            for address in socket.gethostbyname_ex(socket.gethostname())[2]:
                if address and not address.startswith("127."):
                    addresses.add(address)
        except OSError:
            pass
        return sorted(addresses)

    def studio_status(self, request: FastAPIRequest | None = None) -> dict[str, Any]:
        web_root = self._studio_web_root()
        index_path = web_root / "index.html"
        current_url = ""
        if request is not None:
            current_url = f"{str(request.base_url).rstrip('/')}/studio/"
        lan_urls = [self._studio_url_for_host(address) for address in self._lan_ipv4_addresses()]
        available = index_path.exists()
        return {
            "ok": True,
            "available": available,
            "message": "Web 工作台可用。" if available else "Web 工作台尚未构建，请先生成 Flutter Web 产物。",
            "path": str(web_root),
            "local_url": self._studio_url_for_host("127.0.0.1"),
            "current_url": current_url,
            "lan_urls": lan_urls,
        }

    def open_studio_browser(self) -> dict[str, Any]:
        status = self.studio_status()
        url = status["local_url"]
        if status["available"]:
            webbrowser.open(url)
            status["message"] = "已打开实验性 Web 工作台。"
        status["opened_url"] = url
        return status

    def _safe_upload_name(self, filename: str | None, allowed_extensions: set[str]) -> str | None:
        original_name = Path(filename or "upload").name
        suffix = Path(original_name).suffix.lower()
        if suffix not in allowed_extensions:
            return None
        stem = Path(original_name).stem.strip() or "upload"
        stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip(".-") or "upload"
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S%f")
        digest = hashlib.sha1(f"{timestamp}|{original_name}".encode("utf-8")).hexdigest()[:8]
        return f"{timestamp}-{digest}-{stem}{suffix}"

    async def _save_studio_upload(
        self,
        upload: UploadFile,
        *,
        allowed_extensions: set[str],
        role: str,
    ) -> dict[str, Any] | None:
        safe_name = self._safe_upload_name(upload.filename, allowed_extensions)
        if safe_name is None:
            return None
        upload_dir = self._studio_upload_root() / role / datetime.now().strftime("%Y%m%d")
        upload_dir.mkdir(parents=True, exist_ok=True)
        output_path = upload_dir / safe_name
        size = 0
        with output_path.open("wb") as handle:
            while True:
                chunk = await upload.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                handle.write(chunk)
        if size <= 0:
            output_path.unlink(missing_ok=True)
            return None
        return {
            "name": upload.filename or safe_name,
            "path": str(output_path),
            "size_bytes": size,
            "media_type": self._media_type_for_path(str(output_path)),
            "media_url": self._media_url_for_path(str(output_path)),
        }

    async def upload_workspace_sources(self, uploads: list[UploadFile]) -> dict[str, Any]:
        files = []
        for upload in uploads:
            saved = await self._save_studio_upload(
                upload,
                allowed_extensions=AUDIO_EXTENSIONS.union(IMAGE_EXTENSIONS),
                role="source",
            )
            if saved is not None:
                files.append(saved)
        if not files:
            return {
                "ok": False,
                "files": [],
                "workspace": self.workspace_state(),
                "message": "未上传有效源文件。源文件支持图片和音频格式。",
            }
        workspace = self.set_workspace_source_paths([file["path"] for file in files])
        return {
            "ok": True,
            "files": files,
            "workspace": workspace,
            "message": f"已上传 {len(files)} 个源文件。",
        }

    async def upload_workspace_target(self, upload: UploadFile) -> dict[str, Any]:
        saved = await self._save_studio_upload(
            upload,
            allowed_extensions=IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS),
            role="target",
        )
        if saved is None:
            return {
                "ok": False,
                "file": None,
                "workspace": self.workspace_state(),
                "message": "未上传有效目标文件。目标文件支持图片和视频格式。",
            }
        workspace = self.set_workspace_target_path(saved["path"])
        return {
            "ok": True,
            "file": saved,
            "workspace": workspace,
            "message": "已上传目标文件。",
        }

    def _allowed_studio_media_roots(self) -> list[Path]:
        candidates = [
            self._output_dir,
            self._thumbnail_dir,
            getattr(self, "_playback_dir", self._studio_root / "data" / "cache" / "playback"),
            self._studio_upload_root(),
            getattr(self, "_personas_dir", self._studio_root / "data" / "personas"),
            getattr(self, "_extracted_faces_dir", self._studio_root / "data" / "input" / "extracted_faces"),
        ]
        return [candidate for candidate in candidates if candidate.exists()]

    def _path_is_within(self, path: Path, root: Path) -> bool:
        try:
            path.resolve().relative_to(root.resolve())
            return True
        except (OSError, ValueError):
            return False

    def resolve_studio_media_path(self, value: Any) -> Path | None:
        portable_path = self._resolve_portable_path(value, require_exists=True)
        if not portable_path:
            return None
        candidate = Path(portable_path)
        if not candidate.is_file():
            return None
        if candidate.suffix.lower() not in IMAGE_EXTENSIONS.union(VIDEO_EXTENSIONS).union(AUDIO_EXTENSIONS):
            return None
        resolved = self._resolve_existing_path(candidate)
        if any(self._path_is_within(resolved, root) for root in self._allowed_studio_media_roots()):
            return resolved
        return None

    def _media_url_for_path(self, path: str | None) -> str | None:
        resolved = self.resolve_studio_media_path(path)
        if resolved is None:
            return None
        return f"/studio/media?path={quote(str(resolved), safe='')}"

    def _run_facefusion_cli(self, args: list[str]) -> bool:
        self._last_cli_error = None
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
        output_lines: list[str] = []
        for raw_line in (process.stdout or "").splitlines():
            line = raw_line.rstrip()
            if line:
                output_lines.append(line)
                self._append_log(line)
        for raw_line in (process.stderr or "").splitlines():
            line = raw_line.rstrip()
            if line:
                output_lines.append(line)
                self._append_log(line)
        if process.returncode != 0:
            detail = "\n".join(output_lines[-8:]).strip()
            self._last_cli_error = detail or f"FaceFusion CLI failed with exit code {process.returncode}."
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
        target_media_type = self._media_type_for_path(target_path)
        source_thumbnail = self._find_workspace_source_thumbnail()
        target_thumbnail = self._resolve_thumbnail(target_path)

        return {
            "source_paths": source_paths,
            "target_path": target_path,
            "source_media_urls": [self._media_url_for_path(path) for path in source_paths],
            "target_media_url": self._media_url_for_path(target_path),
            "source_thumbnail": source_thumbnail,
            "source_thumbnail_url": self._media_url_for_path(source_thumbnail),
            "target_thumbnail": target_thumbnail,
            "target_thumbnail_url": self._media_url_for_path(target_thumbnail),
            "target_media_type": target_media_type,
            "target_video_frame_total": self._workspace_target_video_frame_total(target_path),
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
            self._workspace_video_frame_total_cache = {}
            self._save_workspace_state()
        self._append_log(f"[bridge] Updated workspace target path: {normalized or 'None'}.")
        return self.workspace_state()

    def clear_workspace_target_path(self) -> dict[str, Any]:
        with self._lock:
            self._workspace_state["target_path"] = None
            self._workspace_video_frame_total_cache = {}
            self._save_workspace_state()
        self._append_log("[bridge] Cleared workspace target path.")
        return self.workspace_state()

    def _delete_partial_workspace_job(self, job_id: str) -> None:
        for job_status in JOB_STATUSES:
            job_path = self._jobs_dir / job_status / f"{job_id}.json"
            if not job_path.exists():
                continue
            try:
                payload = json.loads(job_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                payload = {}
            steps = payload.get("steps") if isinstance(payload, dict) else None
            if steps:
                return
            try:
                job_path.unlink()
                self._append_log(f"[bridge] Removed partial empty workspace job: {job_id}")
            except OSError as error:
                self._append_log(f"[bridge] Failed to remove partial workspace job {job_id}: {error}")
            return

    def _create_workspace_job(self) -> tuple[str, str] | None:
        self._last_workspace_job_error = None
        workspace = self.workspace_state()
        source_paths = workspace["source_paths"]
        target_path = workspace["target_path"]
        if not source_paths or not target_path:
            self._last_workspace_job_error = "工作台需要有效的源文件和目标文件。"
            return None

        self._ensure_bundled_ffmpeg()
        workspace_options = self.workspace_options_state()["options"]
        option_cli_args = self._workspace_step_option_cli_args(workspace_options)
        content_analyser_cli_args = self._content_analyser_cli_args()

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
                *content_analyser_cli_args,
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
                self._last_workspace_job_error = (
                    self._last_cli_error
                    or f"创建生成任务失败：{' '.join(command[:2])}"
                )
                self._delete_partial_workspace_job(job_id)
                return None
        return job_id, output_path

    def queue_workspace(self) -> dict[str, Any]:
        job = self._create_workspace_job()
        if job is None:
            return {
                "ok": False,
                "message": self._last_workspace_job_error or "工作台源文件或目标文件无效。",
                "workspace": self.workspace_state(),
                "queue": self.list_queue_tasks(),
            }
        job_id, output_path = job
        workspace = self.workspace_state()
        output_key = self._normalize_work_metadata_key(output_path)
        self._persist_works_metadata_entries(
            [
                {
                    "output_path": output_path,
                    "job_id": job_id,
                    "target_path": workspace.get("target_path"),
                    "target_media_type": workspace.get("target_media_type"),
                    "output_media_type": self._media_type_for_path(output_path),
                    "source_paths": workspace.get("source_paths") or [],
                    "updated_at": datetime.now().isoformat(timespec="seconds"),
                }
            ],
            active_output_keys={output_key} if output_key else None,
        )
        self._append_log(f"[bridge] Workspace job queued: {job_id}")
        return {
            "ok": True,
            "job_id": job_id,
            "output_path": output_path,
            "workspace": self.workspace_state(),
            "queue": self.list_queue_tasks(),
        }

    def run_workspace(self) -> dict[str, Any]:
        if not self._workspace_run_lock.acquire(blocking=False):
            return {
                "ok": False,
                "message": "已有立即生成请求正在提交，请勿重复点击。",
                "workspace": self.workspace_state(),
                "queue": self.list_queue_tasks(),
            }

        try:
            with self._queue_lock:
                if self._queue_runner_active:
                    return {
                        "ok": False,
                        "message": "已有生成任务正在运行，请在生成队列中查看进度。",
                        "workspace": self.workspace_state(),
                        "queue": self.list_queue_tasks(),
                    }

            queued = self.queue_workspace()
            if not queued.get("ok"):
                return queued
            queue_state = self.run_queue()
            queued["queue"] = queue_state
            return queued
        finally:
            self._workspace_run_lock.release()

    def _build_command(self) -> list[str]:
        return [
            self._resolve_facefusion_python_executable(),
            "-c",
            self._facefusion_bootstrap_code(),
            "run",
            "--ui-layouts",
            "default",
            "--ui-workflow",
            "instant_runner",
            "--jobs-path",
            str(self._jobs_dir),
            "--temp-path",
            str(self._temp_dir),
            "--output-path",
            str(self._output_dir),
            *self._content_analyser_cli_args(),
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
        elif shutil.which("ffmpeg", path=env["PATH"]):
            env["FACEFUSION_FFMPEG_PATH"] = shutil.which("ffmpeg", path=env["PATH"]) or ""
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

    def _normalize_job_payload_paths(self, payload: dict[str, Any]) -> bool:
        changed = False
        steps = payload.get("steps") or []
        if not isinstance(steps, list):
            return False

        for step in steps:
            if not isinstance(step, dict):
                continue
            args = step.get("args") or {}
            if not isinstance(args, dict):
                continue

            raw_source_paths = args.get("source_paths") or []
            if isinstance(raw_source_paths, list):
                source_paths = []
                for source_path in raw_source_paths:
                    source_paths.append(
                        self._resolve_portable_path(source_path, require_exists=True) or str(source_path)
                    )
                if source_paths != raw_source_paths:
                    args["source_paths"] = source_paths
                    changed = True

            target_path = self._resolve_portable_path(args.get("target_path"), require_exists=True)
            if target_path and target_path != args.get("target_path"):
                args["target_path"] = target_path
                changed = True

            output_path = self._resolve_portable_path(args.get("output_path"))
            if output_path and output_path != args.get("output_path"):
                args["output_path"] = output_path
                changed = True

        return changed

    def _save_job_payload_if_changed(self, job_path: Path, payload: dict[str, Any], changed: bool) -> None:
        if not changed or self._queue_current_job_id == job_path.stem:
            return
        try:
            job_path.write_text(
                json.dumps(payload, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
        except OSError as error:
            self._append_log(f"[bridge] Failed to migrate job paths for {job_path.stem}: {error}")

    def _queue_phase_label(self, phase: str | None) -> str:
        return {
            "extracting": "提取帧",
            "processing": "处理帧",
            "merging": "合成视频",
            "running": "生成中",
            "queued": "等待中",
            "completed": "已完成",
            "failed": "失败",
        }.get(phase or "", "待命")

    def _calculate_task_progress_percent(
        self,
        *,
        status: str,
        is_active: bool,
        job_id: str,
    ) -> float:
        if status == "completed":
            return 100.0
        if status == "failed":
            return float(self._queue_progress_by_job.get(job_id, {}).get("progress_percent", 100.0))
        if not is_active:
            return 0.0
        progress_state = self._queue_progress_by_job.get(job_id) or {}
        return float(progress_state.get("progress_percent", 0.0))

    def _queue_runner_progress_percent(self) -> float:
        total_jobs = self._queue_total_jobs
        if total_jobs <= 0:
            return 0.0

        current_job_progress = 0.0
        if self._queue_runner_active and self._queue_current_job_id:
            current_job_progress = float(
                self._queue_progress_by_job.get(self._queue_current_job_id, {}).get("progress_percent", 0.0)
            )

        processed_units = min(self._queue_completed_jobs, total_jobs)
        if self._queue_runner_active:
            progress = (processed_units + current_job_progress / 100.0) / total_jobs * 100.0
        else:
            progress = processed_units / total_jobs * 100.0
        return round(max(0.0, min(progress, 100.0)), 1)

    def _initialize_queue_progress(self, job_id: str) -> None:
        with self._queue_lock:
            self._queue_progress_by_job[job_id] = {
                "progress_percent": 0.0,
                "progress_phase": "running",
                "progress_detail": "任务已开始。",
            }

    def _finish_queue_progress(self, job_id: str, *, failed: bool = False, detail: str | None = None) -> None:
        with self._queue_lock:
            self._queue_progress_by_job[job_id] = {
                "progress_percent": 100.0,
                "progress_phase": "failed" if failed else "completed",
                "progress_detail": detail or ("任务失败。" if failed else "任务已完成。"),
            }

    def _parse_queue_progress_line(self, line: str, target_media_type: str | None) -> tuple[float, str, str] | None:
        normalized_line = line.strip()
        if not normalized_line:
            return None

        match = QUEUE_PROGRESS_PATTERN.search(normalized_line)
        if match:
            phase = match.group(1).lower()
            raw_percent = max(0, min(int(match.group(2)), 100))
            if target_media_type == "video" and phase in QUEUE_VIDEO_PHASE_RANGES:
                offset, weight = QUEUE_VIDEO_PHASE_RANGES[phase]
                progress_percent = offset + raw_percent / 100.0 * weight
            else:
                progress_percent = float(raw_percent)
            return progress_percent, phase, normalized_line[:160]

        lower_line = normalized_line.lower()
        phase = next((item for item in QUEUE_PROGRESS_PHASES if item in lower_line), None)
        if phase is None:
            return None

        if target_media_type == "video" and phase in QUEUE_VIDEO_PHASE_RANGES:
            progress_percent = QUEUE_VIDEO_PHASE_RANGES[phase][0]
        else:
            progress_percent = 50.0 if phase == "processing" else 0.0
        return progress_percent, phase, normalized_line[:160]

    def _update_queue_progress_from_line(
        self,
        job_id: str,
        line: str,
        target_media_type: str | None,
    ) -> None:
        parsed = self._parse_queue_progress_line(line, target_media_type)
        if parsed is None:
            return

        progress_percent, phase, detail = parsed
        with self._queue_lock:
            current_state = self._queue_progress_by_job.get(job_id) or {}
            current_percent = float(current_state.get("progress_percent", 0.0))
            self._queue_progress_by_job[job_id] = {
                "progress_percent": round(max(current_percent, min(progress_percent, 99.0)), 1),
                "progress_phase": phase,
                "progress_detail": detail,
            }

    def _target_media_type_for_job(self, job_id: str) -> str | None:
        for task in self.list_queue_tasks()["tasks"]:
            if task["job_id"] == job_id:
                return task.get("target_media_type")
        return None

    def _find_job_record_path(self, job_id: str, statuses: list[str] | None = None) -> Path | None:
        for job_status in statuses or JOB_STATUSES:
            job_path = self._jobs_dir / job_status / f"{job_id}.json"
            if job_path.exists():
                return job_path
        return None

    def _read_job_record(self, job_path: Path) -> dict[str, Any] | None:
        try:
            payload = json.loads(job_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    def _write_job_record(self, job_path: Path, payload: dict[str, Any]) -> None:
        payload["date_updated"] = datetime.now().astimezone().isoformat()
        job_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def _mark_job_record_status(
        self,
        payload: dict[str, Any],
        status: str,
        detail: str | None = None,
    ) -> None:
        steps = payload.get("steps") or []
        if isinstance(steps, list):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                if status == "completed":
                    step["status"] = "completed"
                elif status == "failed" and step.get("status") != "completed":
                    step["status"] = "failed"
        if detail:
            payload["studio_queue_detail"] = detail

    def _move_job_record_to_status(
        self,
        job_id: str,
        status: str,
        *,
        detail: str | None = None,
    ) -> bool:
        job_path = self._find_job_record_path(job_id)
        if job_path is None:
            return False

        payload = self._read_job_record(job_path)
        if payload is None:
            return False

        self._mark_job_record_status(payload, status, detail)
        try:
            self._write_job_record(job_path, payload)
            target_dir = self._jobs_dir / status
            target_dir.mkdir(parents=True, exist_ok=True)
            target_path = target_dir / f"{job_id}.json"
            if job_path.resolve() != target_path.resolve():
                job_path.replace(target_path)
        except OSError as error:
            self._append_log(f"[bridge] Failed to move queue task {job_id} to {status}: {error}")
            return False
        return True

    def _shrink_queue_total_jobs_after_removal(self, removed_status: str) -> None:
        if removed_status != "queued" or not self._queue_runner_active:
            return
        minimum_total_jobs = self._queue_completed_jobs + (1 if self._queue_current_job_id else 0)
        self._queue_total_jobs = max(minimum_total_jobs, self._queue_total_jobs - 1)

    def _validate_queued_job(self, job_id: str) -> str | None:
        job_path = self._find_job_record_path(job_id, statuses=["queued"])
        if job_path is None:
            return "任务记录不在 queued 队列中。"

        payload = self._read_job_record(job_path)
        if payload is None:
            return "任务记录损坏，无法读取。"

        steps = payload.get("steps") or []
        if not isinstance(steps, list) or not steps:
            return "任务没有可执行步骤。"

        for index, step in enumerate(steps, start=1):
            if not isinstance(step, dict):
                return f"第 {index} 步格式无效。"
            args = step.get("args") or {}
            if not isinstance(args, dict):
                return f"第 {index} 步参数无效。"

            source_paths = args.get("source_paths") or []
            if not isinstance(source_paths, list) or not source_paths:
                return f"第 {index} 步缺少源文件。"
            missing_sources = [str(path) for path in source_paths if not Path(str(path)).exists()]
            if missing_sources:
                return f"第 {index} 步源文件不存在：{missing_sources[0]}"

            target_path = args.get("target_path")
            if not target_path or not Path(str(target_path)).exists():
                return f"第 {index} 步目标文件不存在：{target_path or '未设置'}"

            output_path = args.get("output_path")
            if not output_path:
                return f"第 {index} 步缺少输出路径。"
            try:
                Path(str(output_path)).parent.mkdir(parents=True, exist_ok=True)
            except OSError as error:
                return f"第 {index} 步输出目录不可写：{error}"

        return None

    def _validate_completed_job_output(self, job_id: str) -> str | None:
        job_path = self._find_job_record_path(job_id)
        if job_path is None:
            return "任务记录不存在。"
        payload = self._read_job_record(job_path)
        if payload is None:
            return "任务记录损坏，无法读取。"
        for step in payload.get("steps") or []:
            if not isinstance(step, dict):
                continue
            args = step.get("args") or {}
            if not isinstance(args, dict):
                continue
            output_path = args.get("output_path")
            if output_path and not Path(str(output_path)).exists():
                return f"输出文件不存在：{output_path}"
        return None

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
                paths_changed = self._normalize_job_payload_paths(payload)
                self._save_job_payload_if_changed(job_path, payload, paths_changed)
                steps = payload.get("steps") or []
                if job_status == "drafted" and not steps:
                    continue
                first_step = steps[0] if steps else {}
                first_args = first_step.get("args") or {}
                source_paths = first_args.get("source_paths") or []
                target_path = first_args.get("target_path")
                output_path = first_args.get("output_path")
                completed_steps = sum(1 for step in steps if step.get("status") == "completed")
                started_steps = sum(1 for step in steps if step.get("status") == "started")
                is_active = self._queue_current_job_id == job_path.stem
                output_media_type = self._media_type_for_path(output_path)
                output_exists = bool(output_path and Path(output_path).exists())
                source_thumbnail = self._resolve_thumbnail(source_paths[0] if source_paths else None)
                target_thumbnail = self._resolve_thumbnail(target_path)
                output_thumbnail = self._resolve_thumbnail(output_path) if output_exists else None
                progress_state = self._queue_progress_by_job.get(job_path.stem) or {}
                progress_phase = str(
                    progress_state.get("progress_phase")
                    or ("completed" if job_status == "completed" else "failed" if job_status == "failed" else "queued")
                )
                progress_detail = (
                    progress_state.get("progress_detail")
                    or payload.get("studio_queue_detail")
                    or self._queue_phase_label(progress_phase)
                )
                progress_percent = self._calculate_task_progress_percent(
                    status=job_status,
                    is_active=is_active,
                    job_id=job_path.stem,
                )

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
                        "source_media_urls": [self._media_url_for_path(path) for path in source_paths],
                        "source_thumbnail": source_thumbnail,
                        "source_thumbnail_url": self._media_url_for_path(source_thumbnail),
                        "source_media_type": self._media_type_for_path(source_paths[0] if source_paths else None),
                        "target_path": target_path,
                        "target_media_url": self._media_url_for_path(target_path),
                        "target_thumbnail": target_thumbnail,
                        "target_thumbnail_url": self._media_url_for_path(target_thumbnail),
                        "target_media_type": self._media_type_for_path(target_path),
                        "output_path": output_path,
                        "output_media_url": self._media_url_for_path(output_path) if output_exists else None,
                        "output_thumbnail": output_thumbnail,
                        "output_thumbnail_url": self._media_url_for_path(output_thumbnail),
                        "output_media_type": output_media_type,
                        "can_open_output": output_exists and output_media_type in {"image", "video"},
                        "progress_percent": round(progress_percent, 1),
                        "progress_phase": progress_phase,
                        "progress_detail": progress_detail,
                        "is_active": is_active,
                    }
                )

        self._persist_works_metadata_entries(
            [
                metadata_entry
                for metadata_entry in (
                    self._works_metadata_entry_from_queue_task(task)
                    for task in tasks
                )
                if metadata_entry is not None
            ],
            active_output_keys=self._active_queue_output_keys(tasks),
        )

        return {
            "tasks": tasks,
            "runner": {
                "active": self._queue_runner_active,
                "current_job_id": self._queue_current_job_id,
                "total_jobs": self._queue_total_jobs,
                "completed_jobs": self._queue_completed_jobs,
                "processed_jobs": self._queue_completed_jobs,
                "progress_percent": self._queue_runner_progress_percent(),
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
            self._queue_progress_by_job = {}
            self._queue_cancel_requested_job_ids = set()
            self._queue_current_process = None
            for job_id in queued_job_ids:
                self._queue_progress_by_job[job_id] = {
                    "progress_percent": 0.0,
                    "progress_phase": "queued",
                    "progress_detail": "等待执行。",
                }
            self._queue_runner_thread = threading.Thread(target=self._run_queue_worker, daemon=True)
            self._queue_runner_thread.start()
            self._append_log(f"[bridge] Queue runner started with {len(queued_job_ids)} queued jobs.")
        return self.list_queue_tasks()

    def delete_queue_task(self, job_id: str) -> dict[str, Any]:
        with self._queue_lock:
            if self._queue_current_job_id == job_id:
                self._append_log(f"[bridge] Refused to delete active queue task: {job_id}")
                queue_state = self.list_queue_tasks()
                queue_state["ok"] = False
                queue_state["message"] = "正在运行的任务不能删除，请等待完成或停止后再操作。"
                return queue_state

            for job_status in JOB_STATUSES:
                job_path = self._jobs_dir / job_status / f"{job_id}.json"
                if job_path.exists():
                    job_path.unlink()
                    self._queue_progress_by_job.pop(job_id, None)
                    self._queue_cancel_requested_job_ids.discard(job_id)
                    self._shrink_queue_total_jobs_after_removal(job_status)
                    self._append_log(f"[bridge] Deleted queue task: {job_id}")
                    break
        queue_state = self.list_queue_tasks()
        queue_state["ok"] = True
        return queue_state

    def cancel_queue_task(self, job_id: str) -> dict[str, Any]:
        process_to_terminate: subprocess.Popen[str] | None = None

        with self._queue_lock:
            if self._queue_current_job_id == job_id:
                self._queue_cancel_requested_job_ids.add(job_id)
                progress_state = dict(self._queue_progress_by_job.get(job_id) or {})
                progress_state["progress_phase"] = progress_state.get("progress_phase") or "running"
                progress_state["progress_detail"] = "正在取消任务..."
                self._queue_progress_by_job[job_id] = progress_state
                process_to_terminate = self._queue_current_process
                self._append_log(f"[bridge] Cancel requested for active queue task: {job_id}")
            else:
                for job_status in JOB_STATUSES:
                    job_path = self._jobs_dir / job_status / f"{job_id}.json"
                    if not job_path.exists():
                        continue
                    job_path.unlink()
                    self._queue_progress_by_job.pop(job_id, None)
                    self._queue_cancel_requested_job_ids.discard(job_id)
                    self._shrink_queue_total_jobs_after_removal(job_status)
                    self._append_log(f"[bridge] Cancelled queue task: {job_id}")
                    queue_state = self.list_queue_tasks()
                    queue_state["ok"] = True
                    queue_state["message"] = f"已取消任务：{job_id}"
                    return queue_state

                queue_state = self.list_queue_tasks()
                queue_state["ok"] = False
                queue_state["message"] = f"未找到任务：{job_id}"
                return queue_state

        if process_to_terminate and process_to_terminate.poll() is None:
            self._terminate_process_tree(process_to_terminate.pid)

        queue_state = self.list_queue_tasks()
        queue_state["ok"] = True
        queue_state["message"] = f"已请求取消运行中的任务：{job_id}"
        return queue_state

    def clear_completed_queue_tasks(self) -> dict[str, Any]:
        removed_count = 0
        completed_dir = self._jobs_dir / "completed"
        with self._queue_lock:
            if completed_dir.exists():
                for job_path in sorted(completed_dir.glob("*.json")):
                    try:
                        job_path.unlink()
                    except OSError as error:
                        self._append_log(f"[bridge] Failed to clear completed queue task {job_path.stem}: {error}")
                        continue
                    self._queue_progress_by_job.pop(job_path.stem, None)
                    removed_count += 1
            self._append_log(f"[bridge] Cleared {removed_count} completed queue task(s).")

        queue_state = self.list_queue_tasks()
        queue_state["ok"] = True
        queue_state["removed_count"] = removed_count
        return queue_state

    def _run_queue_worker(self) -> None:
        attempted_job_ids: set[str] = set()
        try:
            while True:
                queued_job_ids = [
                    task["job_id"]
                    for task in self.list_queue_tasks()["tasks"]
                    if task["status"] == "queued" and task["job_id"] not in attempted_job_ids
                ]
                if not queued_job_ids:
                    break
                job_id = queued_job_ids[0]
                attempted_job_ids.add(job_id)
                with self._queue_lock:
                    self._queue_current_job_id = job_id
                self._initialize_queue_progress(job_id)

                validation_error = self._validate_queued_job(job_id)
                if validation_error:
                    self._finish_queue_progress(job_id, failed=True, detail=validation_error)
                    self._move_job_record_to_status(job_id, "failed", detail=validation_error)
                    self._queue_last_error = f"Job invalid: {job_id} ({validation_error})"
                    self._append_log(f"[bridge] Queued job invalid: {job_id} ({validation_error})")
                    with self._queue_lock:
                        self._queue_completed_jobs += 1
                        self._queue_current_job_id = None
                    continue

                self._append_log(f"[bridge] Running queued job: {job_id}")
                result = self._run_single_job(job_id)
                cancelled = (
                    result == QUEUE_CANCELLED_EXIT_CODE
                    or job_id in self._queue_cancel_requested_job_ids
                )
                if cancelled:
                    detail = "任务已取消。"
                    self._finish_queue_progress(job_id, failed=True, detail=detail)
                    self._move_job_record_to_status(job_id, "failed", detail=detail)
                    self._append_log(f"[bridge] Queued job cancelled: {job_id}")
                elif result != 0:
                    detail = f"任务执行失败，退出码 {result}。"
                    self._finish_queue_progress(job_id, failed=True, detail=detail)
                    self._move_job_record_to_status(job_id, "failed", detail=detail)
                    self._queue_last_error = f"Job failed: {job_id} (exit code {result})"
                    self._append_log(f"[bridge] Queued job failed: {job_id} (exit code {result})")
                else:
                    output_error = self._validate_completed_job_output(job_id)
                    if output_error:
                        self._finish_queue_progress(job_id, failed=True, detail=output_error)
                        self._move_job_record_to_status(job_id, "failed", detail=output_error)
                        self._queue_last_error = f"Job output missing: {job_id} ({output_error})"
                        self._append_log(f"[bridge] Queued job output missing: {job_id} ({output_error})")
                    else:
                        self._finish_queue_progress(job_id)
                        self._move_job_record_to_status(job_id, "completed", detail="任务已完成。")
                        self._append_log(f"[bridge] Queued job completed: {job_id}")
                with self._queue_lock:
                    self._queue_completed_jobs += 1
                    self._queue_current_job_id = None
                    self._queue_current_process = None
                    self._queue_cancel_requested_job_ids.discard(job_id)
        finally:
            with self._queue_lock:
                self._queue_runner_active = False
                self._queue_current_job_id = None
                self._queue_current_process = None
            self._append_log("[bridge] Queue runner finished.")

    def _run_single_job(self, job_id: str) -> int:
        target_media_type = self._target_media_type_for_job(job_id)
        with self._queue_lock:
            if job_id in self._queue_cancel_requested_job_ids:
                return QUEUE_CANCELLED_EXIT_CODE
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
        with self._queue_lock:
            self._queue_current_process = process
        assert process.stdout is not None
        try:
            for raw_line in process.stdout:
                for line in raw_line.replace("\r", "\n").splitlines():
                    line = line.strip()
                    if line:
                        self._update_queue_progress_from_line(job_id, line, target_media_type)
                        self._append_log(line)
            return process.wait()
        finally:
            with self._queue_lock:
                if self._queue_current_process is process:
                    self._queue_current_process = None

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
        portable_path = self._resolve_portable_path(file_path, require_exists=True)
        if not portable_path:
            return None
        candidate = Path(portable_path)
        if not candidate.exists():
            return None
        extension = candidate.suffix.lower()
        if extension in IMAGE_EXTENSIONS:
            return str(candidate)
        if extension in VIDEO_EXTENSIONS:
            return self._resolve_video_thumbnail(candidate)
        return None

    def _playback_proxy_cache_path(self, file_path: Path) -> Path | None:
        try:
            stat = file_path.stat()
            resolved_path = file_path.resolve()
        except OSError:
            return None
        cache_key = hashlib.sha1(
            f"{resolved_path}|{stat.st_mtime_ns}|{stat.st_size}".encode("utf-8"),
        ).hexdigest()
        return self._playback_dir / f"{cache_key}.mp4"

    def _playback_proxy_temp_path(self, proxy_path: Path) -> Path:
        return proxy_path.with_name(
            f"{proxy_path.stem}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp{proxy_path.suffix}",
        )

    def _unlink_path_quietly(self, file_path: Path) -> None:
        try:
            file_path.unlink(missing_ok=True)
        except OSError:
            return

    def _generate_playback_proxy(self, file_path: Path, proxy_path: Path) -> bool:
        ffmpeg_path = self._resolve_ffmpeg_for_thumbnail()
        if not ffmpeg_path:
            self._append_log("[bridge] Unable to generate playback proxy: ffmpeg was not found.")
            return False

        proxy_path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = self._playback_proxy_temp_path(proxy_path)

        command = [
            ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(file_path),
            "-map",
            "0:v:0",
            "-an",
            "-vf",
            "scale=trunc(min(1920\\,iw)/2)*2:-2",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(temp_path),
        ]
        try:
            result = subprocess.run(
                command,
                cwd=self.repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                timeout=300,
            )
        except subprocess.TimeoutExpired:
            self._unlink_path_quietly(temp_path)
            self._append_log("[bridge] Playback proxy generation timed out after 300 seconds.")
            return False
        except OSError as error:
            self._unlink_path_quietly(temp_path)
            self._append_log(f"[bridge] Playback proxy generation crashed: {error}")
            return False

        if result.returncode == 0 and temp_path.exists() and temp_path.stat().st_size > 0:
            try:
                temp_path.replace(proxy_path)
                return True
            except OSError as error:
                self._unlink_path_quietly(temp_path)
                if proxy_path.exists() and proxy_path.stat().st_size > 0:
                    return True
                self._append_log(f"[bridge] Playback proxy finalize failed: {error}")
                return False

        self._unlink_path_quietly(temp_path)
        message = (result.stderr or result.stdout or "").strip()
        if message:
            self._append_log(f"[bridge] Playback proxy generation failed: {message.splitlines()[-1]}")
        else:
            self._append_log(f"[bridge] Playback proxy generation failed for {file_path}")
        return False

    def prepare_video_playback(self, payload: dict[str, Any]) -> dict[str, Any]:
        portable_path = self._resolve_portable_path(payload.get("path"), require_exists=True)
        if not portable_path:
            return {
                "ok": False,
                "path": "",
                "playback_path": "",
                "proxied": False,
                "message": "视频文件不存在，无法准备播放。",
            }

        file_path = Path(portable_path)
        if file_path.suffix.lower() not in VIDEO_EXTENSIONS:
            return {
                "ok": False,
                "path": str(file_path),
                "playback_path": str(file_path),
                "proxied": False,
                "message": "当前文件不是支持的视频格式。",
            }

        resolved_path = self._resolve_existing_path(file_path)
        if resolved_path.suffix.lower() != ".mov":
            return {
                "ok": True,
                "path": str(resolved_path),
                "playback_path": str(resolved_path),
                "proxied": False,
                "message": "视频可直接播放。",
            }

        proxy_path = self._playback_proxy_cache_path(resolved_path)
        if proxy_path is None:
            return {
                "ok": False,
                "path": str(resolved_path),
                "playback_path": str(resolved_path),
                "proxied": False,
                "message": "无法创建视频播放代理缓存。",
            }
        if proxy_path.exists() and proxy_path.stat().st_size > 0:
            return {
                "ok": True,
                "path": str(resolved_path),
                "playback_path": str(proxy_path),
                "proxied": True,
                "message": "已使用缓存播放代理。",
            }
        try:
            generated = self._generate_playback_proxy(resolved_path, proxy_path)
        except OSError as error:
            self._append_log(f"[bridge] Playback proxy generation raised an OS error: {error}")
            generated = False
        if not generated:
            return {
                "ok": False,
                "path": str(resolved_path),
                "playback_path": str(resolved_path),
                "proxied": False,
                "message": "ProRes 播放代理生成失败。",
            }
        return {
            "ok": True,
            "path": str(resolved_path),
            "playback_path": str(proxy_path),
            "proxied": True,
            "message": "已生成播放代理。",
        }

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
        if "close_behavior" in payload:
            self._settings["close_behavior"] = self._normalize_close_behavior(payload["close_behavior"])
        if "sidebar_expanded" in payload:
            self._settings["sidebar_expanded"] = payload["sidebar_expanded"] is True
        if "content_analyser_score" in payload:
            self._settings["content_analyser_score"] = self._normalize_content_analyser_score(
                payload["content_analyser_score"],
            )
        if "workspace_options_panel_width" in payload:
            self._settings["workspace_options_panel_width"] = (
                self._normalize_workspace_options_panel_width(
                    payload["workspace_options_panel_width"],
                )
            )
        self._save_settings()
        self._append_log("[bridge] Settings updated.")
        return self.get_settings()

    def _queue_metadata_by_output_path(
        self,
        tasks: list[dict[str, Any]] | None = None,
    ) -> dict[str, dict[str, Any]]:
        metadata_by_output_path: dict[str, dict[str, Any]] = {}
        task_items = tasks if tasks is not None else self.list_queue_tasks()["tasks"]
        for task in task_items:
            normalized_output_path = self._normalize_work_metadata_key(
                task.get("output_path"),
            )
            if not normalized_output_path:
                continue
            metadata_by_output_path[normalized_output_path] = {
                "job_id": task.get("job_id"),
                "target_path": task.get("target_path"),
                "target_media_type": task.get("target_media_type"),
                "output_media_type": task.get("output_media_type"),
                "updated_at": task.get("updated_at")
                or task.get("created_at")
                or datetime.now().isoformat(timespec="seconds"),
                "source_paths": task.get("source_paths") or [],
            }
        return metadata_by_output_path

    def list_works(self, favorite_only: bool = False) -> dict[str, Any]:
        favorite_paths = self._read_favorites()
        items = []
        seen_output_paths: set[str] = set()
        queue_tasks = self.list_queue_tasks()["tasks"]
        queue_metadata_by_output_path = self._queue_metadata_by_output_path(queue_tasks)
        persisted_metadata_by_output_path = self._works_metadata_by_output_path(
            self._active_queue_output_keys(queue_tasks),
        )
        for file_path in self._scan_output_files():
            resolved_path = self._resolve_existing_path(file_path)
            path_str = str(resolved_path)
            normalized_output_path = os.path.normcase(os.path.abspath(path_str))
            seen_output_paths.add(normalized_output_path)
            is_favorite = path_str in favorite_paths or str(file_path) in favorite_paths
            if favorite_only and not is_favorite:
                continue
            work_metadata = dict(
                persisted_metadata_by_output_path.get(normalized_output_path) or {},
            )
            queue_metadata = queue_metadata_by_output_path.get(normalized_output_path)
            if queue_metadata:
                work_metadata.update(queue_metadata)
            thumbnail_path = self._resolve_thumbnail(path_str)
            items.append(
                {
                    "id": self._work_id_for_path(resolved_path),
                    "path": path_str,
                    "file_name": resolved_path.name,
                    "media_type": "image" if resolved_path.suffix.lower() in IMAGE_EXTENSIONS else "video",
                    "media_url": self._media_url_for_path(path_str),
                    "thumbnail_path": thumbnail_path,
                    "thumbnail_url": self._media_url_for_path(thumbnail_path),
                    "modified_at": datetime.fromtimestamp(resolved_path.stat().st_mtime).isoformat(timespec="seconds"),
                    "size_bytes": resolved_path.stat().st_size,
                    "is_favorite": is_favorite,
                    "source": "file",
                    "queue_status": "completed",
                    "job_id": None,
                    "progress_percent": 100.0,
                    "progress_phase": "completed",
                    "progress_detail": "作品已生成。",
                    "can_open_output": True,
                    "output_path": path_str,
                    "target_path": None,
                    **work_metadata,
                }
            )
        if not favorite_only:
            items.extend(self._queue_work_items(queue_tasks, seen_output_paths))
        items.sort(key=lambda item: item["modified_at"], reverse=True)
        return {
            "items": items,
            "output_root": str(self._resolve_existing_path(self._output_dir)),
        }

    def _queue_work_items(
        self,
        tasks: list[dict[str, Any]],
        seen_output_paths: set[str],
    ) -> list[dict[str, Any]]:
        queue_items: list[dict[str, Any]] = []
        for task in tasks:
            output_path = task.get("output_path")
            output_exists = bool(output_path and Path(str(output_path)).exists())
            output_path_str = ""
            if output_path:
                output_path_str = str(self._resolve_existing_path(Path(str(output_path))))
                normalized_output_path = os.path.normcase(os.path.abspath(output_path_str))
                if output_exists and normalized_output_path in seen_output_paths:
                    continue

            job_id = str(task.get("job_id") or "")
            media_type = (
                task.get("output_media_type")
                or task.get("target_media_type")
                or self._media_type_for_path(str(output_path) if output_path else None)
                or "image"
            )
            modified_at = (
                task.get("updated_at")
                or task.get("created_at")
                or datetime.now().isoformat(timespec="seconds")
            )
            thumbnail_path = task.get("output_thumbnail") or task.get("target_thumbnail") or task.get("source_thumbnail")
            size_bytes = 0
            if output_exists and output_path_str:
                try:
                    size_bytes = Path(output_path_str).stat().st_size
                except OSError:
                    size_bytes = 0

            queue_items.append(
                {
                    "id": self._work_id_for_path(Path(output_path_str)) if output_exists else f"queue:{job_id}",
                    "path": output_path_str if output_exists else "",
                    "file_name": Path(str(output_path)).name if output_path else job_id,
                    "media_type": media_type,
                    "media_url": self._media_url_for_path(output_path_str) if output_exists else None,
                    "thumbnail_path": thumbnail_path,
                    "thumbnail_url": self._media_url_for_path(thumbnail_path),
                    "modified_at": modified_at,
                    "size_bytes": size_bytes,
                    "is_favorite": False,
                    "source": "queue",
                    "queue_status": task.get("status") or "queued",
                    "job_id": job_id,
                    "progress_percent": task.get("progress_percent") or 0.0,
                    "progress_phase": task.get("progress_phase") or "queued",
                    "progress_detail": task.get("progress_detail") or self._queue_phase_label(task.get("progress_phase")),
                    "can_open_output": task.get("can_open_output") is True,
                    "is_active": task.get("is_active") is True,
                    "output_path": output_path,
                    "target_path": task.get("target_path"),
                    "target_media_type": task.get("target_media_type"),
                    "output_media_type": task.get("output_media_type"),
                    "source_paths": task.get("source_paths") or [],
                }
            )
        return queue_items

    def favorite_work(self, work_id: str, favorite: bool) -> dict[str, Any]:
        target = self._resolve_work_path(work_id)
        if target is None:
            return self.list_works()
        favorites = self._read_favorites()
        target_path = str(self._resolve_existing_path(target))
        if favorite:
            favorites.add(target_path)
            self._append_log(f"[bridge] Favorited work: {target_path}")
        else:
            favorites.discard(target_path)
            favorites.discard(str(target))
            self._append_log(f"[bridge] Unfavorited work: {target_path}")
        self._write_favorites(favorites)
        return self.list_works()

    def delete_work(self, work_id: str) -> dict[str, Any]:
        target = self._resolve_work_path(work_id)
        if target and target.exists():
            target.unlink()
            self._remove_works_metadata_entry(str(target))
            favorites = self._read_favorites()
            favorites.discard(str(self._resolve_existing_path(target)))
            favorites.discard(str(target))
            self._write_favorites(favorites)
            self._append_log(f"[bridge] Deleted work: {target}")
        return self.list_works()

    def open_work_directory(self, work_id: str) -> dict[str, Any]:
        target = self._resolve_work_path(work_id)
        if target is None or not target.exists():
            return {"ok": False, "message": "作品文件不存在，无法打开所在目录。"}

        directory = self._resolve_existing_path(target).parent
        try:
            if os.name == "nt":
                os.startfile(str(directory))
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(directory)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            else:
                subprocess.Popen(["xdg-open", str(directory)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError as error:
            self._append_log(f"[bridge] Open work directory failed: {directory} ({error})")
            return {"ok": False, "message": f"打开目录失败：{error}"}

        self._append_log(f"[bridge] Opened work directory: {directory}")
        return {"ok": True, "path": str(directory)}

    def resolve_work_download_path(self, work_id: str) -> Path | None:
        target = self._resolve_work_path(work_id)
        if target is None or not target.exists() or not target.is_file():
            return None
        return self._resolve_existing_path(target)

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
        return hashlib.sha1(str(self._resolve_existing_path(file_path)).encode("utf-8")).hexdigest()

    def _resolve_work_path(self, work_id: str) -> Path | None:
        for file_path in self._scan_output_files():
            if self._work_id_for_path(file_path) == work_id:
                return file_path
        return None

    def _resolve_existing_path(self, path: Path) -> Path:
        portable_path = self._resolve_portable_path(path)
        if portable_path:
            path = Path(portable_path)
        try:
            return path.resolve()
        except OSError:
            return path.absolute()

    def _read_favorites(self) -> set[str]:
        try:
            payload = json.loads(self._favorites_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = []
        return {self._resolve_portable_path(item) or str(item) for item in payload if item}

    def _write_favorites(self, favorites: set[str]) -> None:
        self._favorites_path.write_text(
            json.dumps(sorted(favorites), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    def shutdown(self) -> None:
        self.stop()


runtime = FaceFusionRuntime()


@asynccontextmanager
async def bridge_lifespan(_: FastAPI) -> AsyncIterator[None]:
    try:
        yield
    finally:
        runtime.shutdown()


app = FastAPI(
    title="FaceSwap Studio Bridge",
    version="0.4.0",
    lifespan=bridge_lifespan,
)


@app.get("/studio")
def studio_redirect() -> RedirectResponse:
    return RedirectResponse(url="/studio/")


@app.get("/studio/status")
def studio_status(request: FastAPIRequest) -> dict[str, Any]:
    return runtime.studio_status(request)


@app.post("/studio/open-browser")
def studio_open_browser() -> dict[str, Any]:
    return runtime.open_studio_browser()


@app.post("/studio/uploads/workspace-source")
async def studio_upload_workspace_source(
    files: list[UploadFile] = File(...),
) -> dict[str, Any]:
    return await runtime.upload_workspace_sources(files)


@app.post("/studio/uploads/workspace-target")
async def studio_upload_workspace_target(
    file: UploadFile = File(...),
) -> dict[str, Any]:
    return await runtime.upload_workspace_target(file)


@app.get("/studio/media")
def studio_media(path: str = Query(..., min_length=1)):
    media_path = runtime.resolve_studio_media_path(path)
    if media_path is None:
        return HTMLResponse("Media file is not available.", status_code=404)
    return FileResponse(media_path)


def _studio_asset_response(asset_path: str):
    web_root = runtime._studio_web_root()
    index_path = web_root / "index.html"
    if not index_path.exists():
        return HTMLResponse(
            "FaceSwap Studio Web workbench has not been built yet.",
            status_code=404,
        )
    if asset_path:
        requested_path = (web_root / asset_path).resolve()
        if requested_path.is_file() and runtime._path_is_within(requested_path, web_root):
            return FileResponse(requested_path)
    return FileResponse(index_path)


@app.get("/studio/")
def studio_index():
    return _studio_asset_response("")


@app.get("/studio/{asset_path:path}")
def studio_asset(asset_path: str):
    return _studio_asset_response(asset_path)


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


@app.post("/updates/schedule")
def updates_schedule() -> dict[str, Any]:
    return runtime.schedule_update()


@app.post("/updates/apply")
def updates_apply() -> dict[str, Any]:
    return runtime.apply_update()


@app.post("/updates/core/download")
def updates_core_download() -> dict[str, Any]:
    return runtime.download_core_update()


@app.post("/updates/core/apply")
def updates_core_apply() -> dict[str, Any]:
    return runtime.apply_core_update()


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


@app.delete("/queue/tasks/completed")
def queue_clear_completed() -> dict[str, Any]:
    return runtime.clear_completed_queue_tasks()


@app.delete("/queue/tasks/{job_id}")
def queue_delete(job_id: str) -> dict[str, Any]:
    return runtime.delete_queue_task(job_id)


@app.post("/queue/tasks/{job_id}/cancel")
def queue_cancel(job_id: str) -> dict[str, Any]:
    return runtime.cancel_queue_task(job_id)


@app.post("/media/playback-proxy")
def media_playback_proxy(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.prepare_video_playback(payload)


@app.get("/workspace/draft")
def workspace_draft() -> dict[str, Any]:
    return runtime.workspace_state()


@app.post("/workspace/draft/extract-source-faces")
def workspace_source_faces_extract(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.extract_workspace_source_faces(payload.get("paths") or [])


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


@app.get("/personas")
def personas_list() -> dict[str, Any]:
    return runtime.list_personas()


@app.post("/personas")
def personas_save(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.save_workspace_persona(payload)


@app.post("/personas/from-images")
def personas_save_from_images(payload: dict[str, Any]) -> dict[str, Any]:
    return runtime.save_persona_from_images(payload)


@app.post("/personas/{persona_id}/use")
def personas_use(persona_id: str) -> dict[str, Any]:
    return runtime.use_persona(persona_id)


@app.delete("/personas/{persona_id}")
def personas_delete(persona_id: str) -> dict[str, Any]:
    return runtime.delete_persona(persona_id)


@app.post("/personas/{persona_id}/open-directory")
def personas_open_directory(persona_id: str) -> dict[str, Any]:
    return runtime.open_persona_directory(persona_id)


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


@app.get("/works/{work_id}/download")
def works_download(work_id: str):
    target = runtime.resolve_work_download_path(work_id)
    if target is None:
        raise HTTPException(status_code=404, detail="作品文件不存在，无法下载。")
    return FileResponse(target, filename=target.name, media_type="application/octet-stream")


@app.post("/works/{work_id}/open-directory")
def works_open_directory(work_id: str) -> dict[str, Any]:
    return runtime.open_work_directory(work_id)
