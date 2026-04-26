from PySide6.QtCore import Signal
from PySide6.QtWidgets import QFrame, QLabel, QPushButton, QSpacerItem, QSizePolicy, QVBoxLayout


class Sidebar(QFrame):
    page_selected = Signal(int)
    theme_toggle_requested = Signal()

    def __init__(self, current_theme: str, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("SidebarPanel")
        self._buttons: list[QPushButton] = []
        self._theme_button = QPushButton()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 20, 18, 20)
        layout.setSpacing(10)

        title = QLabel("Facefusion Studion")
        title.setObjectName("WindowTitle")
        layout.addWidget(title)

        subtitle = QLabel("左侧管理导航 / 右侧专业工作区")
        subtitle.setObjectName("MutedText")
        layout.addWidget(subtitle)
        layout.addSpacing(18)

        pages = ["首页", "工作台", "作品管理", "设置", "关于"]
        for index, text in enumerate(pages):
            button = QPushButton(text)
            button.setObjectName("NavButton")
            button.setCheckable(True)
            button.clicked.connect(lambda checked=False, idx=index: self._select(idx))
            layout.addWidget(button)
            self._buttons.append(button)

        layout.addItem(QSpacerItem(20, 20, QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Expanding))

        self._theme_button.setObjectName("SecondaryButton")
        self._theme_button.clicked.connect(self.theme_toggle_requested.emit)
        layout.addWidget(self._theme_button)
        self.set_theme(current_theme)
        self._select(0)

    def _select(self, index: int) -> None:
        for button_index, button in enumerate(self._buttons):
            button.setChecked(button_index == index)
        self.page_selected.emit(index)

    def set_theme(self, theme: str) -> None:
        label = "切换到浅色主题" if theme == "dark" else "切换到暗色主题"
        self._theme_button.setText(label)
