from __future__ import annotations

import base64
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import shutil
import sys
import traceback
from typing import Any

import cv2
import numpy


BRIDGE_REPO_ROOT = Path(__file__).resolve().parents[3]
PROJECT_ROOT = BRIDGE_REPO_ROOT

if str(BRIDGE_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_REPO_ROOT))

from facefusion import core, state_manager  # noqa: E402
from facefusion.args import apply_args  # noqa: E402
from facefusion.audio import create_empty_audio_frame, get_voice_frame  # noqa: E402
from facefusion.common_helper import get_first  # noqa: E402
from facefusion.content_analyser import analyse_frame  # noqa: E402
from facefusion.face_creator import get_many_faces  # noqa: E402
from facefusion.face_selector import sort_and_filter_faces  # noqa: E402
from facefusion.filesystem import filter_audio_paths, is_image, is_video  # noqa: E402
from facefusion.program import create_program  # noqa: E402
from facefusion.uis.components.preview import process_preview_frame  # noqa: E402
from facefusion.vision import (  # noqa: E402
    count_video_frame_total,
    detect_frame_orientation,
    extract_vision_mask,
    fit_cover_frame,
    merge_vision_mask,
    obscure_frame,
    read_static_image,
    read_static_images,
    read_video_frame,
    restrict_frame,
    unpack_resolution,
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
    bundled_ffmpeg = PROJECT_ROOT / ".runtime" / "ffmpeg" / "ffmpeg.exe"
    if bundled_ffmpeg.exists():
        os.environ.setdefault("FACEFUSION_FFMPEG_PATH", str(bundled_ffmpeg))
    else:
        system_ffmpeg = shutil.which("ffmpeg")
        if system_ffmpeg:
            os.environ.setdefault("FACEFUSION_FFMPEG_PATH", system_ffmpeg)
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
        "default",
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


def _encode_bgr_frame_base64(vision_frame: Any) -> str:
    ok, encoded = cv2.imencode(".png", vision_frame)
    if not ok:
        raise RuntimeError("人脸缩略图 PNG 编码失败。")
    return base64.b64encode(encoded.tobytes()).decode("ascii")


def _extract_face_choices(target_vision_frame: Any) -> list[dict[str, Any]]:
    face_choices: list[dict[str, Any]] = []
    faces = sort_and_filter_faces([], get_many_faces([target_vision_frame]))
    selected_position = int(state_manager.get_item("reference_face_position") or 0)
    frame_height, frame_width = target_vision_frame.shape[:2]

    for index, face in enumerate(faces):
        start_x, start_y, end_x, end_y = map(int, face.bounding_box)
        start_x = max(0, min(start_x, frame_width))
        start_y = max(0, min(start_y, frame_height))
        end_x = max(0, min(end_x, frame_width))
        end_y = max(0, min(end_y, frame_height))
        if end_x <= start_x or end_y <= start_y:
            continue

        padding_x = int((end_x - start_x) * 0.25)
        padding_y = int((end_y - start_y) * 0.25)
        crop_start_x = max(0, start_x - padding_x)
        crop_start_y = max(0, start_y - padding_y)
        crop_end_x = min(frame_width, end_x + padding_x)
        crop_end_y = min(frame_height, end_y + padding_y)
        crop_vision_frame = target_vision_frame[crop_start_y:crop_end_y, crop_start_x:crop_end_x]
        crop_vision_frame = fit_cover_frame(crop_vision_frame, (128, 128))

        face_choices.append(
            {
                "index": index,
                "image_base64": _encode_bgr_frame_base64(crop_vision_frame),
                "bounding_box": [start_x, start_y, end_x, end_y],
                "selected": index == selected_position,
            },
        )
    return face_choices


def _prepare_compare_frame(target_vision_frame: Any, preview_resolution: str) -> Any:
    compare_vision_frame = restrict_frame(target_vision_frame, unpack_resolution(preview_resolution))
    if analyse_frame(compare_vision_frame[:, :, :3]):
        return obscure_frame(compare_vision_frame)
    return compare_vision_frame


def _build_preview_payload(
    *,
    preview_vision_frame: Any,
    before_vision_frame: Any,
    after_vision_frame: Any,
    target_media_type: str,
    preview_mode: str,
    preview_resolution: str,
    frame_number: int,
    reference_frame_number: int,
    face_choices: list[dict[str, Any]],
    video_frame_total: int | None = None,
) -> dict[str, Any]:
    image_base64, width, height, orientation = _encode_preview_frame(preview_vision_frame)
    before_image_base64, _, _, _ = _encode_preview_frame(before_vision_frame)
    after_image_base64, _, _, _ = _encode_preview_frame(after_vision_frame)
    payload = {
        "ok": True,
        "mime_type": "image/png",
        "image_base64": image_base64,
        "before_image_base64": before_image_base64,
        "after_image_base64": after_image_base64,
        "width": width,
        "height": height,
        "orientation": orientation,
        "target_media_type": target_media_type,
        "preview_mode": preview_mode,
        "preview_resolution": preview_resolution,
        "frame_number": frame_number,
        "reference_frame_number": reference_frame_number,
        "face_selector_mode": state_manager.get_item("face_selector_mode"),
        "reference_face_position": state_manager.get_item("reference_face_position"),
        "face_choices": face_choices,
    }
    if video_frame_total is not None:
        payload["video_frame_total"] = video_frame_total
    return payload


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
            [target_vision_frame],
            preview_mode,
            preview_resolution,
        )
        before_vision_frame = _prepare_compare_frame(target_vision_frame, preview_resolution)
        face_choices = _extract_face_choices(reference_vision_frame)
        after_vision_frame = (
            preview_vision_frame
            if preview_mode == "default"
            else process_preview_frame(
                reference_vision_frame,
                source_vision_frames,
                source_audio_frame,
                source_voice_frame,
                [target_vision_frame],
                "default",
                preview_resolution,
            )
        )
        return _build_preview_payload(
            preview_vision_frame=preview_vision_frame,
            before_vision_frame=before_vision_frame,
            after_vision_frame=after_vision_frame,
            target_media_type="image",
            preview_mode=preview_mode,
            preview_resolution=preview_resolution,
            frame_number=0,
            reference_frame_number=0,
            face_choices=face_choices,
        )

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
            [temp_vision_frame],
            preview_mode,
            preview_resolution,
        )
        before_vision_frame = _prepare_compare_frame(temp_vision_frame, preview_resolution)
        face_choices = _extract_face_choices(reference_vision_frame)
        after_vision_frame = (
            preview_vision_frame
            if preview_mode == "default"
            else process_preview_frame(
                reference_vision_frame,
                source_vision_frames,
                source_audio_frame,
                source_voice_frame,
                [temp_vision_frame],
                "default",
                preview_resolution,
            )
        )
        return _build_preview_payload(
            preview_vision_frame=preview_vision_frame,
            before_vision_frame=before_vision_frame,
            after_vision_frame=after_vision_frame,
            target_media_type="video",
            preview_mode=preview_mode,
            preview_resolution=preview_resolution,
            frame_number=preview_frame_number,
            reference_frame_number=preview_frame_number,
            face_choices=face_choices,
            video_frame_total=video_frame_total,
        )

    raise RuntimeError("当前目标文件不是可预览的图片或视频。")


def _write_json(payload: dict[str, Any]) -> None:
    sys.stdout.buffer.write(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.flush()


def main() -> int:
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _write_json({"ok": False, "message": f"预览请求 JSON 无效: {error}"})
        return 1

    _prepare_runtime_environment()
    try:
        with redirect_stdout(sys.stderr):
            result = _generate_preview(payload)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        _write_json(
            {
                "ok": False,
                "message": str(error) or "预览生成失败。",
            },
        )
        return 1

    _write_json(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
