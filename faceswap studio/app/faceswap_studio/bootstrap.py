from pathlib import Path

from faceswap_studio.config.models import AppContext
from faceswap_studio.config.settings_service import load_settings, save_settings
from faceswap_studio.core.path_service import build_paths, ensure_directories


def bootstrap(studio_root: Path) -> AppContext:
    paths = build_paths(studio_root)
    ensure_directories(paths)
    settings = load_settings(paths.settings_file)

    if not settings.default_output_dir:
        settings.default_output_dir = str(paths.output_dir)
        save_settings(paths.settings_file, settings)

    return AppContext(paths=paths, settings=settings)
