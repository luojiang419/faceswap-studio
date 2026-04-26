from PySide6.QtWidgets import QFrame, QLabel, QVBoxLayout


class StatusCard(QFrame):
    def __init__(self, title: str, value: str = "--", detail: str = "", parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("GlassCard")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(8)

        self.title_label = QLabel(title)
        self.title_label.setObjectName("CardTitle")
        layout.addWidget(self.title_label)

        self.value_label = QLabel(value)
        self.value_label.setObjectName("CardValue")
        layout.addWidget(self.value_label)

        self.detail_label = QLabel(detail)
        self.detail_label.setObjectName("MutedText")
        self.detail_label.setWordWrap(True)
        layout.addWidget(self.detail_label)

    def update_content(self, value: str, detail: str) -> None:
        self.value_label.setText(value)
        self.detail_label.setText(detail)
