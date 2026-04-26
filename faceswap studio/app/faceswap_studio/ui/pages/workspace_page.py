from PySide6.QtCore import QUrl
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWidgets import QLabel, QPushButton, QTabWidget, QVBoxLayout, QWidget


class WorkspacePage(QWidget):
    def __init__(self, backend_url: str, parent=None) -> None:
        super().__init__(parent)
        self._backend_url = backend_url

        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(12)

        title = QLabel("工作台")
        title.setObjectName("SectionTitle")
        layout.addWidget(title)

        self.tabs = QTabWidget()

        operation_tab = QWidget()
        operation_layout = QVBoxLayout(operation_tab)
        operation_layout.setContentsMargins(0, 0, 0, 0)
        operation_layout.setSpacing(10)

        self.reload_button = QPushButton("重新加载嵌入页面")
        self.reload_button.setObjectName("SecondaryButton")
        self.reload_button.clicked.connect(self.reload_page)
        operation_layout.addWidget(self.reload_button)

        self.web_view = QWebEngineView()
        self.web_view.setUrl(QUrl(self._backend_url))
        operation_layout.addWidget(self.web_view, 1)

        queue_tab = QWidget()
        queue_layout = QVBoxLayout(queue_tab)
        queue_layout.setContentsMargins(0, 0, 0, 0)
        queue_tip = QLabel("生成队列页将在下一阶段接入任务卡片、执行按钮和进度显示。")
        queue_tip.setWordWrap(True)
        queue_layout.addWidget(queue_tip)
        queue_layout.addStretch(1)

        self.tabs.addTab(operation_tab, "操作台")
        self.tabs.addTab(queue_tab, "生成队列")
        layout.addWidget(self.tabs, 1)

    def load_backend_url(self, backend_url: str) -> None:
        self._backend_url = backend_url
        self.web_view.setUrl(QUrl(self._backend_url))

    def reload_page(self) -> None:
        self.web_view.setUrl(QUrl(self._backend_url))
