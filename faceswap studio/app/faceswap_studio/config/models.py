from dataclasses import dataclass
from pathlib import Path


@dataclass(slots=True)
class AppPaths:
    studio_root: Path
    repo_root: Path
    app_dir: Path
    config_dir: Path
    data_dir: Path
    input_dir: Path
    output_dir: Path
    output_image_dir: Path
    output_video_dir: Path
    favorites_dir: Path
    cache_dir: Path
    temp_dir: Path
    jobs_dir: Path
    app_state_dir: Path
    runtime_dir: Path
    settings_file: Path


@dataclass(slots=True)
class AppSettings:
    theme: str = "dark"
    facefusion_host: str = "127.0.0.1"
    facefusion_port: int = 7860
    default_output_dir: str = ""


@dataclass(slots=True)
class AppContext:
    paths: AppPaths
    settings: AppSettings
