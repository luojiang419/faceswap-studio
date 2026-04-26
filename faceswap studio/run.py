from pathlib import Path
import sys


def main() -> int:
    studio_root = Path(__file__).resolve().parent
    app_dir = studio_root / "app"
    if str(app_dir) not in sys.path:
        sys.path.insert(0, str(app_dir))

    from main import main as app_main

    return app_main()


if __name__ == "__main__":
    raise SystemExit(main())
