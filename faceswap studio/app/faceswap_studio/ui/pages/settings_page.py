from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
    QComboBox,
)

from faceswap_studio.config.models import AppPaths, AppSettings
from faceswap_studio.config.settings_service import save_settings


class SettingsPage(QWidget):
    settings_saved = Signal()

    def __init__(self, paths: AppPaths, settings: AppSettings, parent=None) -> None:
        super().__init__(parent)
        self._paths = paths
        self._settings = settings

        root_layout = QVBoxLayout(self)
        root_layout.setContentsMargins(24, 24, 24, 24)
        root_layout.setSpacing(18)

        title = QLabel("设置")
        title.setObjectName("SectionTitle")
        root_layout.addWidget(title)

        form_layout = QFormLayout()
        form_layout.setSpacing(12)

        self.output_edit = QLineEdit(self._settings.default_output_dir or str(self._paths.output_dir))
        browse_button = QPushButton("选择目录")
        browse_button.setObjectName("SecondaryButton")
        browse_button.clicked.connect(self._choose_output_dir)

        output_row = QHBoxLayout()
        output_row.addWidget(self.output_edit, 1)
        output_row.addWidget(browse_button)
        form_layout.addRow("默认输出目录", output_row)

        self.theme_combo = QComboBox()
        self.theme_combo.addItems(["dark", "light"])
        self.theme_combo.setCurrentText(self._settings.theme)
        form_layout.addRow("主题模式", self.theme_combo)

        self.port_spin = QSpinBox()
        self.port_spin.setRange(1024, 65535)
        self.port_spin.setValue(self._settings.facefusion_port)
        form_layout.addRow("FaceFusion 端口", self.port_spin)

        root_layout.addLayout(form_layout)

        save_button = QPushButton("保存设置")
        save_button.setObjectName("PrimaryButton")
        save_button.clicked.connect(self._save)
        root_layout.addWidget(save_button)

        self.status_label = QLabel("修改后保存，新的端口会在下次启动 FaceFusion 时生效。")
        self.status_label.setObjectName("MutedText")
        root_layout.addWidget(self.status_label)
        root_layout.addStretch(1)

    def _choose_output_dir(self) -> None:
        selected = QFileDialog.getExistingDirectory(
            self,
            "选择默认输出目录",
            self.output_edit.text() or str(self._paths.output_dir),
        )
        if selected:
            self.output_edit.setText(selected)

    def _save(self) -> None:
        output_dir = self.output_edit.text().strip() or str(self._paths.output_dir)
        Path(output_dir).mkdir(parents=True, exist_ok=True)

        self._settings.default_output_dir = output_dir
        self._settings.theme = self.theme_combo.currentText()
        self._settings.facefusion_port = self.port_spin.value()
        save_settings(self._paths.settings_file, self._settings)

        self.status_label.setText("设置已保存。若 FaceFusion 已在运行，建议停止后重新启动以应用新端口。")
        self.settings_saved.emit()
