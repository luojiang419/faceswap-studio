from __future__ import annotations

from PySide6.QtWidgets import (
    QHBoxLayout,
    QMainWindow,
    QStackedWidget,
    QWidget,
)

from faceswap_studio.config.models import AppContext
from faceswap_studio.core.facefusion_process import FaceFusionProcess
from faceswap_studio.core.telemetry_service import TelemetryService
from faceswap_studio.ui.pages.about_page import AboutPage
from faceswap_studio.ui.pages.home_page import HomePage
from faceswap_studio.ui.pages.settings_page import SettingsPage
from faceswap_studio.ui.pages.works_page import WorksPage
from faceswap_studio.ui.pages.workspace_page import WorkspacePage
from faceswap_studio.ui.theme import build_stylesheet
from faceswap_studio.ui.widgets.sidebar import Sidebar


class MainWindow(QMainWindow):
    def __init__(self, context: AppContext) -> None:
        super().__init__()
        self._context = context
        self._process_service = FaceFusionProcess(context.paths, context.settings, self)
        self._telemetry_service = TelemetryService()

        self.setWindowTitle("Facefusion Studion")
        self.resize(1520, 920)

        container = QWidget()
        self.setCentralWidget(container)

        layout = QHBoxLayout(container)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(18)

        self.sidebar = Sidebar(context.settings.theme)
        self.sidebar.setFixedWidth(280)
        layout.addWidget(self.sidebar)

        self.pages = QStackedWidget()
        layout.addWidget(self.pages, 1)

        self.home_page = HomePage(self._process_service, self._telemetry_service)
        self.workspace_page = WorkspacePage(self._process_service.url)
        self.works_page = WorksPage()
        self.settings_page = SettingsPage(context.paths, context.settings)
        self.about_page = AboutPage()

        for page in [
            self.home_page,
            self.workspace_page,
            self.works_page,
            self.settings_page,
            self.about_page,
        ]:
            self.pages.addWidget(page)

        self.sidebar.page_selected.connect(self.pages.setCurrentIndex)
        self.sidebar.theme_toggle_requested.connect(self.toggle_theme)
        self.settings_page.settings_saved.connect(self._handle_settings_saved)
        self._process_service.process_state_changed.connect(self._sync_backend_url)

        self._apply_theme()

    def toggle_theme(self) -> None:
        self._context.settings.theme = "light" if self._context.settings.theme == "dark" else "dark"
        self.settings_page.theme_combo.setCurrentText(self._context.settings.theme)
        self.settings_page._save()
        self._apply_theme()

    def _handle_settings_saved(self) -> None:
        self.sidebar.set_theme(self._context.settings.theme)
        self._apply_theme()
        self._sync_backend_url()

    def _sync_backend_url(self, *_args) -> None:
        self.workspace_page.load_backend_url(self._process_service.url)

    def _apply_theme(self) -> None:
        self.setStyleSheet(build_stylesheet(self._context.settings.theme))
        self.sidebar.set_theme(self._context.settings.theme)

    def closeEvent(self, event) -> None:  # type: ignore[override]
        if self._process_service.is_running():
            self._process_service.stop()
        super().closeEvent(event)
