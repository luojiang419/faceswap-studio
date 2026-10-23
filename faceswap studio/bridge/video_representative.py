"""本地寻找视频中的首个人脸采样帧，缓存结果；不加载换脸模型或下载资源。"""
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def _detector():
    import onnxruntime as ort
    model = Path(__file__).resolve().parents[2] / '.assets/models/yoloface_8n.onnx'
    if not model.is_file():
        return None
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    return ort.InferenceSession(str(model), sess_options=options, providers=['CPUExecutionProvider'])


def _contains_face(image, detector):
    import cv2
    import numpy as np
    height, width = image.shape[:2]
    scale = min(1, 640 / width, 640 / height)
    image = cv2.resize(image, (round(width * scale), round(height * scale)))
    # 沿用 FaceFusion YOLOFace 的 BGR、右下补黑、CHW / 255 输入。
    tensor = np.zeros((640, 640, 3), np.float32)
    tensor[:image.shape[0], :image.shape[1]] = image
    tensor = tensor.transpose(2, 0, 1)[None] / 255.0
    detection = np.squeeze(detector.run(None, {'input': tensor})[0]).T
    return bool(np.any(detection[:, 4] > 0.65))


@lru_cache(maxsize=96)
def representative_frame(path: str, modified: int, size: int) -> dict:
    import cv2
    reader = cv2.VideoCapture(path)
    try:
        if not reader.isOpened():
            return {"frame": 0, "seconds": 0.0, "fps": 0.0, "has_face": False}
        fps = reader.get(cv2.CAP_PROP_FPS) or 25.0
        total = max(1, int(reader.get(cv2.CAP_PROP_FRAME_COUNT)))
        detector = _detector()
        if detector is None:
            return {"frame": 0, "seconds": 0.0, "fps": fps, "has_face": False}
        # 先检查开头 15 秒，每半秒采样；长空镜再检查全片均匀采样点。
        frames = list(range(0, min(total, round(fps * 15)), max(1, round(fps / 2))))
        frames += [round((total - 1) * i / 12) for i in range(1, 13)]
        for number in sorted(set(frames)):
            reader.set(cv2.CAP_PROP_POS_FRAMES, number)
            ok, image = reader.read()
            if not ok or image is None:
                continue
            if _contains_face(image, detector):
                return {"frame": number, "seconds": number / fps, "fps": fps, "has_face": True}
        return {"frame": 0, "seconds": 0.0, "fps": fps, "has_face": False}
    except (cv2.error, OSError, AttributeError):
        return {"frame": 0, "seconds": 0.0, "fps": 0.0, "has_face": False}
    finally:
        reader.release()
