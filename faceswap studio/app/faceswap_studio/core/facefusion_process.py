from __future__ import annotations

from pathlib import Path
import sys
from urllib.error import URLError
from urllib.request import urlopen

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtCore import QUrl

from faceswap_studio.config.models import AppPaths, AppSettings


class FaceFusionProcess(QObject):
    log_received = Signal(str)
    process_state_changed = Signal(str)

    def __init__(self, paths: AppPaths, settings: AppSettings, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._paths = paths
        self._settings = settings
        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._process.readyReadStandardOutput.connect(self._read_output)
        self._process.stateChanged.connect(self._handle_state_changed)
        self._process.finished.connect(self._handle_finished)

    @property
    def url(self) -> str:
        return f"http://{self._settings.facefusion_host}:{self._settings.facefusion_port}"

    def is_running(self) -> bool:
        return self._process.state() != QProcess.ProcessState.NotRunning

    def is_responding(self) -> bool:
        if not self.is_running():
            return False
        try:
            with urlopen(self.url, timeout=0.5):
                return True
        except (URLError, TimeoutError, OSError):
            return False

    def start(self) -> None:
        if self.is_running():
            self.log_received.emit("[studio] FaceFusion 已在运行。")
            return

        command = [
            "facefusion.py",
            "run",
            "--ui-layouts",
            "default",
            "--jobs-path",
            str(self._paths.jobs_dir),
            "--temp-path",
            str(self._paths.temp_dir),
            "--output-path",
            self._settings.default_output_dir or str(self._paths.output_dir),
        ]

        environment = QProcessEnvironment.systemEnvironment()
        environment.insert("FACEFUSION_UI_HOST", self._settings.facefusion_host)
        environment.insert("FACEFUSION_UI_PORT", str(self._settings.facefusion_port))
        self._process.setProcessEnvironment(environment)
        self._process.setWorkingDirectory(str(self._paths.repo_root))
        self._process.start(sys.executable, command)
        self.log_received.emit(
            f"[studio] 正在启动 FaceFusion，监听地址 {self.url}，工作目录 {self._paths.repo_root}"
        )

    def stop(self) -> None:
        if not self.is_running():
            self.log_received.emit("[studio] FaceFusion 当前未运行。")
            return

        self.log_received.emit("[studio] 正在停止 FaceFusion...")
        self._process.terminate()
        QTimer.singleShot(5000, self._kill_if_needed)

    def open_in_browser(self) -> None:
        QDesktopServices.openUrl(QUrl(self.url))

    def _kill_if_needed(self) -> None:
        if self.is_running():
            self.log_received.emit("[studio] 终止等待超时，改为强制结束进程。")
            self._process.kill()

    def _read_output(self) -> None:
        chunk = bytes(self._process.readAllStandardOutput()).decode("utf-8", errors="replace")
        if not chunk:
            return
        for line in chunk.splitlines():
            text = line.rstrip()
            if text:
                self.log_received.emit(text)

    def _handle_state_changed(self, state: QProcess.ProcessState) -> None:
        mapping = {
            QProcess.ProcessState.NotRunning: "已停止",
            QProcess.ProcessState.Starting: "启动中",
            QProcess.ProcessState.Running: "运行中",
        }
        self.process_state_changed.emit(mapping.get(state, "未知"))

    def _handle_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        status_text = "正常退出" if exit_status == QProcess.ExitStatus.NormalExit else "异常退出"
        self.log_received.emit(f"[studio] FaceFusion 进程结束，退出码 {exit_code}，状态：{status_text}")
        self.process_state_changed.emit("已停止")
