from pathlib import Path
import sys

from PySide6.QtWidgets import QApplication

from faceswap_studio.bootstrap import bootstrap
from faceswap_studio.ui.window import MainWindow


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Facefusion Studion")
    app.setOrganizationName("FaceSwap Studio")

    studio_root = Path(__file__).resolve().parent.parent
    context = bootstrap(studio_root)

    window = MainWindow(context)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
