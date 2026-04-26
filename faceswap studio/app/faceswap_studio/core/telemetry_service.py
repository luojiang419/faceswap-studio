from __future__ import annotations

from dataclasses import dataclass
import subprocess

import psutil


@dataclass(slots=True)
class TelemetrySnapshot:
    cpu_percent: float
    memory_percent: float
    memory_used_gb: float
    memory_total_gb: float
    gpu_percent: float | None
    gpu_memory_percent: float | None
    gpu_memory_used_mb: int | None
    gpu_memory_total_mb: int | None


class TelemetryService:
    def __init__(self) -> None:
        psutil.cpu_percent(interval=None)

    def read_snapshot(self) -> TelemetrySnapshot:
        memory = psutil.virtual_memory()
        gpu = self._read_gpu_snapshot()
        return TelemetrySnapshot(
            cpu_percent=psutil.cpu_percent(interval=None),
            memory_percent=memory.percent,
            memory_used_gb=memory.used / (1024**3),
            memory_total_gb=memory.total / (1024**3),
            gpu_percent=gpu["gpu_percent"],
            gpu_memory_percent=gpu["gpu_memory_percent"],
            gpu_memory_used_mb=gpu["gpu_memory_used_mb"],
            gpu_memory_total_mb=gpu["gpu_memory_total_mb"],
        )

    def _read_gpu_snapshot(self) -> dict[str, float | int | None]:
        command = [
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=1.0, check=True)
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
            memory_percent = (used / total * 100.0) if total else 0.0
        except (TypeError, ValueError, ZeroDivisionError):
            return {
                "gpu_percent": None,
                "gpu_memory_percent": None,
                "gpu_memory_used_mb": None,
                "gpu_memory_total_mb": None,
            }

        return {
            "gpu_percent": gpu_percent,
            "gpu_memory_percent": memory_percent,
            "gpu_memory_used_mb": used,
            "gpu_memory_total_mb": total,
        }
