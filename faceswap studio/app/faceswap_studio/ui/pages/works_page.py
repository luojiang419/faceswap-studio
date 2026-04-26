from PySide6.QtWidgets import QLabel, QVBoxLayout, QWidget


class WorksPage(QWidget):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(12)

        title = QLabel("作品管理")
        title.setObjectName("SectionTitle")
        layout.addWidget(title)

        tip = QLabel(
            "本阶段先完成桌面壳层和首页控制。作品管理页将在后续阶段接入图片/视频浏览、右键菜单、收藏与删除逻辑。"
        )
        tip.setWordWrap(True)
        layout.addWidget(tip)
        layout.addStretch(1)
