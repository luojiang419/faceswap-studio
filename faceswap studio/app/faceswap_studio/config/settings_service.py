import json
from pathlib import Path

from faceswap_studio.config.models import AppSettings


DEFAULT_SETTINGS = AppSettings()


def load_settings(settings_file: Path) -> AppSettings:
    if not settings_file.exists():
        return AppSettings(
            theme=DEFAULT_SETTINGS.theme,
            facefusion_host=DEFAULT_SETTINGS.facefusion_host,
            facefusion_port=DEFAULT_SETTINGS.facefusion_port,
            default_output_dir=DEFAULT_SETTINGS.default_output_dir,
        )

    try:
        data = json.loads(settings_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        data = {}

    return AppSettings(
        theme=str(data.get("theme") or DEFAULT_SETTINGS.theme),
        facefusion_host=str(data.get("facefusion_host") or DEFAULT_SETTINGS.facefusion_host),
        facefusion_port=int(data.get("facefusion_port") or DEFAULT_SETTINGS.facefusion_port),
        default_output_dir=str(data.get("default_output_dir") or DEFAULT_SETTINGS.default_output_dir),
    )


def save_settings(settings_file: Path, settings: AppSettings) -> None:
    settings_file.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "theme": settings.theme,
        "facefusion_host": settings.facefusion_host,
        "facefusion_port": settings.facefusion_port,
        "default_output_dir": settings.default_output_dir,
    }
    settings_file.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
