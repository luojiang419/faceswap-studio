from PySide6.QtWidgets import QLabel, QVBoxLayout, QWidget


class AboutPage(QWidget):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(16)

        title = QLabel("关于 FaceSwap Studio")
        title.setObjectName("SectionTitle")
        layout.addWidget(title)

        body = QLabel(
            "FaceSwap Studio 用于更高效地驱动 FaceFusion 工作流，当前版本优先建设桌面端壳层、启动控制、"
            "队列管理与作品管理能力。\n\n"
            "版权声明：本软件仅限合法、合规与经授权场景使用，不得用于侵犯他人肖像权、隐私权、著作权或任何非法用途，"
            "违者需自行承担全部法律责任。\n\n"
            "联系作者：QQ 419773176 / 微信 15085152352"
        )
        body.setWordWrap(True)
        layout.addWidget(body)
        layout.addStretch(1)
