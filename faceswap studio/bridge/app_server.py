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
from urllib.error import URLError
from urllib.request import urlopen
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

        psutil.cpu_percent(interval=None)
        self._prepare_paths()
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
        self._thumbnail_dir = studio_root / "data" / "cache" / "thumbnails"
        self._workspace_state_path = self._runtime_dir / "workspace_state.json"
        self._workspace_options_path = self._runtime_dir / "workspace_options.json"

        for directory in [
            self._jobs_dir,
            self._temp_dir,
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
        env.setdefault("FACEFUSION_HUGGINGFACE_MIRRORS", "https://hf-mirror.com")
        env.setdefault("FACEFUSION_GITHUB_MIRRORS", "https://github.com")
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
