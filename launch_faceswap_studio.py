from pathlib import Path
import runpy


def main() -> None:
    repo_root = Path(__file__).resolve().parent
    studio_root = repo_root / "faceswap studio"
    runpy.run_path(str(studio_root / "run.py"), run_name="__main__")


if __name__ == "__main__":
    main()
