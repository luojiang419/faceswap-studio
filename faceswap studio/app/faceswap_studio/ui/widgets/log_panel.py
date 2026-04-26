from PySide6.QtWidgets import QFrame, QLabel, QPlainTextEdit, QVBoxLayout


class LogPanel(QFrame):
    def __init__(self, title: str, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("GlassCard")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(10)

        label = QLabel(title)
        label.setObjectName("SectionTitle")
        layout.addWidget(label)

        self.editor = QPlainTextEdit()
        self.editor.setReadOnly(True)
        self.editor.document().setMaximumBlockCount(1200)
        layout.addWidget(self.editor)

    def append_text(self, text: str) -> None:
        self.editor.appendPlainText(text)

    def clear(self) -> None:
        self.editor.clear()
