from pathlib import Path

from faceswap_studio.config.models import AppPaths


def build_paths(studio_root: Path) -> AppPaths:
    repo_root = studio_root.parent
    app_dir = studio_root / "app"
    config_dir = studio_root / "config"
    data_dir = studio_root / "data"
    input_dir = data_dir / "input"
    output_dir = data_dir / "output"
    output_image_dir = output_dir / "img"
    output_video_dir = output_dir / "video"
    favorites_dir = data_dir / "favorites"
    cache_dir = data_dir / "cache"
    temp_dir = cache_dir / "temp"
    jobs_dir = data_dir / "jobs"
    app_state_dir = data_dir / "app_state"
    runtime_dir = studio_root / "runtime"
    settings_file = config_dir / "settings.json"

    return AppPaths(
        studio_root=studio_root,
        repo_root=repo_root,
        app_dir=app_dir,
        config_dir=config_dir,
        data_dir=data_dir,
        input_dir=input_dir,
        output_dir=output_dir,
        output_image_dir=output_image_dir,
        output_video_dir=output_video_dir,
        favorites_dir=favorites_dir,
        cache_dir=cache_dir,
        temp_dir=temp_dir,
        jobs_dir=jobs_dir,
        app_state_dir=app_state_dir,
        runtime_dir=runtime_dir,
        settings_file=settings_file,
    )


def ensure_directories(paths: AppPaths) -> None:
    for directory in [
        paths.config_dir,
        paths.data_dir,
        paths.input_dir,
        paths.output_dir,
        paths.output_image_dir,
        paths.output_video_dir,
        paths.favorites_dir,
        paths.cache_dir,
        paths.temp_dir,
        paths.jobs_dir,
        paths.app_state_dir,
        paths.runtime_dir,
    ]:
        directory.mkdir(parents=True, exist_ok=True)
