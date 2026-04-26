from __future__ import annotations

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from faceswap_studio.core.facefusion_process import FaceFusionProcess
from faceswap_studio.core.telemetry_service import TelemetryService
from faceswap_studio.ui.widgets.log_panel import LogPanel
from faceswap_studio.ui.widgets.status_card import StatusCard


class HomePage(QWidget):
    def __init__(
        self,
        process_service: FaceFusionProcess,
        telemetry_service: TelemetryService,
        parent=None,
    ) -> None:
        super().__init__(parent)
        self._process_service = process_service
        self._telemetry_service = telemetry_service

        root_layout = QVBoxLayout(self)
        root_layout.setContentsMargins(24, 24, 24, 24)
        root_layout.setSpacing(18)

        title = QLabel("首页")
        title.setObjectName("SectionTitle")
        root_layout.addWidget(title)

        controls_layout = QHBoxLayout()
        controls_layout.setSpacing(10)

        self.status_label = QLabel("后端状态：已停止")
        self.status_label.setObjectName("MutedText")
        controls_layout.addWidget(self.status_label)
        controls_layout.addStretch(1)

        self.start_button = QPushButton("启动 FaceFusion")
        self.start_button.setObjectName("PrimaryButton")
        self.start_button.clicked.connect(self._process_service.start)
        controls_layout.addWidget(self.start_button)

        self.stop_button = QPushButton("停止")
        self.stop_button.setObjectName("SecondaryButton")
        self.stop_button.clicked.connect(self._process_service.stop)
        controls_layout.addWidget(self.stop_button)

        self.browser_button = QPushButton("在浏览器打开")
        self.browser_button.setObjectName("SecondaryButton")
        self.browser_button.clicked.connect(self._process_service.open_in_browser)
        controls_layout.addWidget(self.browser_button)

        root_layout.addLayout(controls_layout)

        cards_layout = QGridLayout()
        cards_layout.setHorizontalSpacing(14)
        cards_layout.setVerticalSpacing(14)

        self.backend_card = StatusCard("FaceFusion 服务", "离线", "等待启动")
        self.cpu_card = StatusCard("CPU", "--", "等待采集")
        self.memory_card = StatusCard("内存", "--", "等待采集")
        self.gpu_card = StatusCard("GPU", "--", "无可用数据")

        cards_layout.addWidget(self.backend_card, 0, 0)
        cards_layout.addWidget(self.cpu_card, 0, 1)
        cards_layout.addWidget(self.memory_card, 1, 0)
        cards_layout.addWidget(self.gpu_card, 1, 1)
        root_layout.addLayout(cards_layout)

        self.log_panel = LogPanel("运行日志")
        root_layout.addWidget(self.log_panel, 1)

        self._process_service.log_received.connect(self.log_panel.append_text)
        self._process_service.process_state_changed.connect(self._apply_process_state)

        self._refresh_timer = QTimer(self)
        self._refresh_timer.setInterval(1000)
        self._refresh_timer.timeout.connect(self._refresh_cards)
        self._refresh_timer.start()

        self._refresh_cards()
        self._apply_process_state("已停止")

    def _apply_process_state(self, state_text: str) -> None:
        ready = self._process_service.is_responding()
        detail = f"后端状态：{state_text}"
        if ready:
            detail += f" / WebUI 已就绪 {self._process_service.url}"

        self.status_label.setText(detail)
        self.start_button.setEnabled(not self._process_service.is_running())
        self.stop_button.setEnabled(self._process_service.is_running())
        self.browser_button.setEnabled(self._process_service.is_running())

    def _refresh_cards(self) -> None:
        snapshot = self._telemetry_service.read_snapshot()
        backend_ready = self._process_service.is_responding()

        backend_value = "在线" if backend_ready else ("启动中" if self._process_service.is_running() else "离线")
        backend_detail = self._process_service.url if self._process_service.is_running() else "尚未启动进程"
        self.backend_card.update_content(backend_value, backend_detail)

        self.cpu_card.update_content(
            f"{snapshot.cpu_percent:.0f}%",
            "系统整体 CPU 占用",
        )
        self.memory_card.update_content(
            f"{snapshot.memory_percent:.0f}%",
            f"{snapshot.memory_used_gb:.1f} / {snapshot.memory_total_gb:.1f} GB",
        )

        if snapshot.gpu_percent is None:
            self.gpu_card.update_content("未检测", "未发现 nvidia-smi，已降级为仅显示 CPU / 内存")
        else:
            self.gpu_card.update_content(
                f"{snapshot.gpu_percent:.0f}%",
                f"{snapshot.gpu_memory_used_mb} / {snapshot.gpu_memory_total_mb} MB · 显存 {snapshot.gpu_memory_percent:.0f}%",
            )

        state_text = "运行中" if self._process_service.is_running() else "已停止"
        if not self._process_service.is_running():
            state_text = "已停止"
        elif backend_ready:
            state_text = "运行中"
        else:
            state_text = "启动中"
        self._apply_process_state(state_text)
