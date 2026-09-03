from __future__ import annotations

from contextlib import redirect_stdout
from datetime import datetime
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

from facefusion import face_classifier, face_detector, face_landmarker, face_recognizer, state_manager  # noqa: E402
from facefusion.args import apply_args  # noqa: E402
from facefusion.face_creator import get_many_faces  # noqa: E402
from facefusion.face_selector import sort_and_filter_faces  # noqa: E402
from facefusion.filesystem import is_image  # noqa: E402
from facefusion.program import create_program  # noqa: E402
from facefusion.vision import read_static_image  # noqa: E402


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff"}


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
    source_paths = payload.get("source_paths") or []
    first_source_path = str(source_paths[0])
    output_dir = Path(payload["output_dir"])
    return [
        "run",
        "--config-path",
        str(payload["config_path"]),
        "--temp-path",
        str(payload["temp_path"]),
        "--jobs-path",
        str(payload["jobs_path"]),
        "--source-paths",
        first_source_path,
        "--target-path",
        first_source_path,
        "--output-path",
        str(output_dir / f"extract-placeholder{Path(first_source_path).suffix.lower()}"),
        "--ui-layouts",
        "default",
        "--ui-workflow",
        "instant_runner",
    ]


def _initialize_state(payload: dict[str, Any]) -> None:
    os.chdir(BRIDGE_REPO_ROOT)
    program = create_program()
    args = vars(program.parse_args(_build_run_args(payload)))
    apply_args(args, state_manager.init_item)
    state_manager.set_item("face_selector_order", "large-small")


def _models_pre_check() -> bool:
    return all(
        module.pre_check()
        for module in [face_detector, face_landmarker, face_recognizer, face_classifier]
    )


def _face_area_score(face: Any, frame_width: int, frame_height: int) -> float:
    start_x, start_y, end_x, end_y = map(float, face.bounding_box)
    area = max(0.0, end_x - start_x) * max(0.0, end_y - start_y)
    frame_area = max(1.0, float(frame_width * frame_height))
    return min(1.0, area / frame_area * 8.0)


def _symmetry_score(face: Any) -> float:
    landmarks = face.landmark_set.get("5/68")
    if landmarks is None:
        landmarks = face.landmark_set.get("5")
    if landmarks is None or len(landmarks) < 5:
        return 0.5

    left_eye, right_eye, nose, left_mouth, right_mouth = landmarks[:5]
    left_eye_distance = abs(float(nose[0] - left_eye[0]))
    right_eye_distance = abs(float(right_eye[0] - nose[0]))
    left_mouth_distance = abs(float(nose[0] - left_mouth[0]))
    right_mouth_distance = abs(float(right_mouth[0] - nose[0]))
    eye_balance = 1.0 - min(1.0, abs(left_eye_distance - right_eye_distance) / max(1.0, (left_eye_distance + right_eye_distance) / 2.0))
    mouth_balance = 1.0 - min(1.0, abs(left_mouth_distance - right_mouth_distance) / max(1.0, (left_mouth_distance + right_mouth_distance) / 2.0))
    return max(0.0, min(1.0, eye_balance * 0.65 + mouth_balance * 0.35))


def _preview_score(face: Any, frame_width: int, frame_height: int) -> float:
    detector_score = float((face.score_set or {}).get("detector") or 0.0)
    angle_score = 1.0 if int(face.angle or 0) == 0 else 0.55
    return round(
        detector_score * 0.42
        + _face_area_score(face, frame_width, frame_height) * 0.28
        + _symmetry_score(face) * 0.22
        + angle_score * 0.08,
        6,
    )


def _select_best_face(faces: list[Any], frame_width: int, frame_height: int) -> Any:
    return max(
        faces,
        key=lambda face: _preview_score(face, frame_width, frame_height),
    )


def _crop_face(vision_frame: Any, face: Any) -> tuple[Any, list[int]]:
    frame_height, frame_width = vision_frame.shape[:2]
    start_x, start_y, end_x, end_y = map(int, face.bounding_box)
    start_x = max(0, min(start_x, frame_width))
    start_y = max(0, min(start_y, frame_height))
    end_x = max(0, min(end_x, frame_width))
    end_y = max(0, min(end_y, frame_height))
    if end_x <= start_x or end_y <= start_y:
        raise RuntimeError("检测到的人脸边界无效。")

    padding_x = int((end_x - start_x) * 0.25)
    padding_y = int((end_y - start_y) * 0.25)
    crop_start_x = max(0, start_x - padding_x)
    crop_start_y = max(0, start_y - padding_y)
    crop_end_x = min(frame_width, end_x + padding_x)
    crop_end_y = min(frame_height, end_y + padding_y)
    crop_vision_frame = vision_frame[crop_start_y:crop_end_y, crop_start_x:crop_end_x]
    if not numpy.any(crop_vision_frame):
        raise RuntimeError("裁切后的人脸图片为空。")
    return crop_vision_frame, [crop_start_x, crop_start_y, crop_end_x, crop_end_y]


def _encode_params(extension: str) -> list[int]:
    if extension in {".jpg", ".jpeg"}:
        return [int(cv2.IMWRITE_JPEG_QUALITY), 100]
    if extension == ".webp":
        return [int(cv2.IMWRITE_WEBP_QUALITY), 100]
    if extension == ".png":
        return [int(cv2.IMWRITE_PNG_COMPRESSION), 1]
    return []


def _write_image(image_path: Path, vision_frame: Any) -> None:
    extension = image_path.suffix.lower()
    ok, encoded = cv2.imencode(extension, vision_frame, _encode_params(extension))
    if not ok:
        raise RuntimeError(f"人脸图片编码失败：{image_path.name}")
    encoded.tofile(str(image_path))


def _extract_faces(payload: dict[str, Any]) -> dict[str, Any]:
    source_paths = [str(path) for path in payload.get("source_paths") or []]
    output_dir = Path(payload["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    _initialize_state(payload)

    if not _models_pre_check():
        raise RuntimeError("人脸提取模型未准备就绪，请先完成核心模型下载。")

    faces: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    output_index = 1

    for source_index, source_path in enumerate(source_paths, start=1):
        source = Path(source_path)
        extension = source.suffix.lower()
        if extension not in IMAGE_EXTENSIONS or not is_image(str(source)):
            skipped.append({"source_path": source_path, "reason": "不是支持的图片格式。"})
            continue

        vision_frame = read_static_image(str(source))
        if vision_frame is None or not numpy.any(vision_frame):
            skipped.append({"source_path": source_path, "reason": "图片读取失败。"})
            continue

        detected_faces = sort_and_filter_faces([], get_many_faces([vision_frame]))
        if not detected_faces:
            skipped.append({"source_path": source_path, "reason": "未检测到人脸。"})
            continue

        frame_height, frame_width = vision_frame.shape[:2]
        face = _select_best_face(detected_faces, frame_width, frame_height)
        crop_vision_frame, crop_box = _crop_face(vision_frame, face)
        face_path = output_dir / f"{output_index:03d}{extension}"
        _write_image(face_path, crop_vision_frame)

        faces.append(
            {
                "source_index": source_index,
                "source_path": str(source),
                "face_path": str(face_path),
                "bounding_box": [int(value) for value in face.bounding_box],
                "crop_box": crop_box,
                "detector_score": float((face.score_set or {}).get("detector") or 0.0),
                "preview_score": _preview_score(face, frame_width, frame_height),
                "detected_face_count": len(detected_faces),
            }
        )
        output_index += 1

    result = {
        "ok": bool(faces),
        "message": f"已提取 {len(faces)} 张源脸。" if faces else "未能从源图片中检测到可用人脸。",
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "faces": faces,
        "skipped": skipped,
    }
    (output_dir / "faces.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return result


def _write_json(payload: dict[str, Any]) -> None:
    sys.stdout.buffer.write(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.flush()


def main() -> int:
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _write_json({"ok": False, "message": f"源脸提取请求 JSON 无效: {error}", "faces": [], "skipped": []})
        return 1

    _prepare_runtime_environment()
    try:
        with redirect_stdout(sys.stderr):
            result = _extract_faces(payload)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        _write_json(
            {
                "ok": False,
                "message": str(error) or "源脸提取失败。",
                "faces": [],
                "skipped": [],
            }
        )
        return 1

    _write_json(result)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
