from __future__ import annotations

import base64
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import sys
import traceback
from typing import Any

import cv2
import numpy


BRIDGE_REPO_ROOT = Path(__file__).resolve().parents[3]
PROJECT_ROOT = BRIDGE_REPO_ROOT.parent

if str(BRIDGE_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_REPO_ROOT))

from facefusion import core, state_manager  # noqa: E402
from facefusion.args import apply_args  # noqa: E402
from facefusion.audio import create_empty_audio_frame, get_voice_frame  # noqa: E402
from facefusion.common_helper import get_first  # noqa: E402
from facefusion.filesystem import filter_audio_paths, is_image, is_video  # noqa: E402
from facefusion.program import create_program  # noqa: E402
from facefusion.uis.components.preview import process_preview_frame  # noqa: E402
from facefusion.vision import (  # noqa: E402
    count_video_frame_total,
    detect_frame_orientation,
    extract_vision_mask,
    merge_vision_mask,
    read_static_image,
    read_static_images,
    read_video_frame,
)


def _build_runtime_path_entries() -> list[str]:
    entries = [
        str(PROJECT_ROOT / ".runtime" / "ffmpeg"),
        str(PROJECT_ROOT / ".venv-win" / "Scripts"),
    ]
    nvidia_root = PROJECT_ROOT / ".venv-win" / "Lib" / "site-packages" / "nvidia"
    if nvidia_root.exists():
        for path in sorted(nvidia_root.rglob("bin")):
            entries.append(str(path))
    return entries


def _prepare_runtime_environment() -> None:
    path_entries = _build_runtime_path_entries()
    current_path = os.environ.get("PATH", "")
    os.environ["PATH"] = os.pathsep.join(path_entries + [current_path])
    os.environ.setdefault(
        "FACEFUSION_FFMPEG_PATH",
        str(PROJECT_ROOT / ".runtime" / "ffmpeg" / "ffmpeg.exe"),
    )
    os.environ.setdefault("FACEFUSION_CURL_PATH", r"C:\Windows\System32\curl.exe")

    try:
        import onnxruntime as ort

        if os.name == "nt" and hasattr(ort, "preload_dlls"):
            ort.preload_dlls(directory="")
    except Exception:
        pass


def _build_run_args(payload: dict[str, Any]) -> list[str]:
    return [
        "run",
        "--config-path",
        str(payload["config_path"]),
        "--temp-path",
        str(payload["temp_path"]),
        "--jobs-path",
        str(payload["jobs_path"]),
        "--source-paths",
        *[str(item) for item in payload["source_paths"]],
        "--target-path",
        str(payload["target_path"]),
        "--output-path",
        str(payload["output_path"]),
        "--ui-layouts",
        "studio",
        "--ui-workflow",
        "instant_runner",
    ]


def _initialize_state(payload: dict[str, Any]) -> dict[str, Any]:
    os.chdir(BRIDGE_REPO_ROOT)
    program = create_program()
    args = vars(program.parse_args(_build_run_args(payload)))
    apply_args(args, state_manager.init_item)

    options = payload.get("options") or {}
    for key, value in options.items():
        if key in {"preview_mode", "preview_resolution", "preview_frame_number"}:
            continue
        if value is None:
            continue
        state_manager.set_item(key, value)

    return options


def _resolve_source_audio_frame() -> tuple[Any, Any]:
    source_audio_path = get_first(filter_audio_paths(state_manager.get_item("source_paths")))
    source_audio_frame = create_empty_audio_frame()
    source_voice_frame = create_empty_audio_frame()

    if (
        source_audio_path
        and state_manager.get_item("output_video_fps")
        and state_manager.get_item("reference_frame_number") is not None
    ):
        reference_audio_frame_number = state_manager.get_item("reference_frame_number")
        if state_manager.get_item("trim_frame_start"):
            reference_audio_frame_number -= state_manager.get_item("trim_frame_start")
        temp_voice_frame = get_voice_frame(
            source_audio_path,
            state_manager.get_item("output_video_fps"),
            reference_audio_frame_number,
        )
        if temp_voice_frame is not None and numpy.any(temp_voice_frame):
            source_voice_frame = temp_voice_frame
    return source_audio_frame, source_voice_frame


def _encode_preview_frame(preview_vision_frame: Any) -> tuple[str, int, int, str]:
    preview_rgba = cv2.cvtColor(preview_vision_frame, cv2.COLOR_BGRA2RGBA)
    ok, encoded = cv2.imencode(".png", cv2.cvtColor(preview_rgba, cv2.COLOR_RGBA2BGRA))
    if not ok:
        raise RuntimeError("预览 PNG 编码失败。")
    return (
        base64.b64encode(encoded.tobytes()).decode("ascii"),
        int(preview_rgba.shape[1]),
        int(preview_rgba.shape[0]),
        detect_frame_orientation(preview_rgba),
    )


def _generate_preview(payload: dict[str, Any]) -> dict[str, Any]:
    options = _initialize_state(payload)
    preview_mode = str(options.get("preview_mode") or "default")
    preview_resolution = str(options.get("preview_resolution") or "1024x1024")
    preview_frame_number = int(options.get("preview_frame_number") or 0)

    if not core.common_pre_check() or not core.processors_pre_check():
        raise RuntimeError("FaceFusion 预览前置检查失败，请确认模型和运行环境可用。")

    source_vision_frames = read_static_images(state_manager.get_item("source_paths"))
    source_audio_frame, source_voice_frame = _resolve_source_audio_frame()
    target_path = state_manager.get_item("target_path")

    if is_image(target_path):
        reference_vision_frame = read_static_image(target_path)
        target_vision_frame = read_static_image(target_path, "rgba")
        if reference_vision_frame is None or target_vision_frame is None:
            raise RuntimeError("图片目标预览帧读取失败。")
        target_vision_mask = extract_vision_mask(target_vision_frame)
        target_vision_frame = merge_vision_mask(target_vision_frame, target_vision_mask)
        preview_vision_frame = process_preview_frame(
            reference_vision_frame,
            source_vision_frames,
            source_audio_frame,
            source_voice_frame,
            target_vision_frame,
            preview_mode,
            preview_resolution,
        )
        image_base64, width, height, orientation = _encode_preview_frame(preview_vision_frame)
        return {
            "ok": True,
            "mime_type": "image/png",
            "image_base64": image_base64,
            "width": width,
            "height": height,
            "orientation": orientation,
            "target_media_type": "image",
            "preview_mode": preview_mode,
            "preview_resolution": preview_resolution,
            "frame_number": 0,
            "reference_frame_number": 0,
        }

    if is_video(target_path):
        video_frame_total = count_video_frame_total(target_path)
        if video_frame_total > 0:
            preview_frame_number = min(max(preview_frame_number, 0), video_frame_total - 1)
        else:
            preview_frame_number = 0

        state_manager.set_item("reference_frame_number", preview_frame_number)
        reference_vision_frame = read_video_frame(target_path, preview_frame_number)
        temp_vision_frame = read_video_frame(target_path, preview_frame_number)
        if reference_vision_frame is None or temp_vision_frame is None:
            raise RuntimeError("视频目标预览帧读取失败。")
        temp_vision_mask = extract_vision_mask(temp_vision_frame)
        temp_vision_frame = merge_vision_mask(temp_vision_frame, temp_vision_mask)
        preview_vision_frame = process_preview_frame(
            reference_vision_frame,
            source_vision_frames,
            source_audio_frame,
            source_voice_frame,
            temp_vision_frame,
            preview_mode,
            preview_resolution,
        )
        image_base64, width, height, orientation = _encode_preview_frame(preview_vision_frame)
        return {
            "ok": True,
            "mime_type": "image/png",
            "image_base64": image_base64,
            "width": width,
            "height": height,
            "orientation": orientation,
            "target_media_type": "video",
            "preview_mode": preview_mode,
            "preview_resolution": preview_resolution,
            "frame_number": preview_frame_number,
            "reference_frame_number": preview_frame_number,
            "video_frame_total": video_frame_total,
        }

    raise RuntimeError("当前目标文件不是可预览的图片或视频。")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        sys.stdout.write(json.dumps({"ok": False, "message": f"预览请求 JSON 无效: {error}"}))
        return 1

    _prepare_runtime_environment()
    try:
        with redirect_stdout(sys.stderr):
            result = _generate_preview(payload)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        sys.stdout.write(
            json.dumps(
                {
                    "ok": False,
                    "message": str(error) or "预览生成失败。",
                },
                ensure_ascii=False,
            ),
        )
        return 1

    sys.stdout.write(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
