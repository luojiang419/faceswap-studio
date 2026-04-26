def build_stylesheet(theme: str) -> str:
    if theme == "light":
        return """
        QWidget {
            background: #eef2f6;
            color: #1e293b;
            font-family: "Microsoft YaHei UI";
            font-size: 13px;
        }
        QMainWindow {
            background: #e7ecf2;
        }
        QFrame#SidebarPanel {
            background: rgba(255, 255, 255, 0.82);
            border: 1px solid rgba(148, 163, 184, 0.28);
            border-radius: 22px;
        }
        QFrame#GlassCard {
            background: rgba(255, 255, 255, 0.84);
            border: 1px solid rgba(148, 163, 184, 0.24);
            border-radius: 20px;
        }
        QLabel#WindowTitle {
            font-size: 24px;
            font-weight: 700;
        }
        QLabel#SectionTitle {
            font-size: 18px;
            font-weight: 700;
        }
        QLabel#MutedText {
            color: #475569;
        }
        QLabel#CardTitle {
            color: #475569;
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
        }
        QLabel#CardValue {
            font-size: 30px;
            font-weight: 700;
            color: #0f172a;
        }
        QPushButton#NavButton {
            text-align: left;
            padding: 12px 14px;
            border-radius: 14px;
            border: 1px solid transparent;
            background: transparent;
        }
        QPushButton#NavButton:hover {
            background: rgba(14, 165, 233, 0.08);
            border: 1px solid rgba(14, 165, 233, 0.2);
        }
        QPushButton#NavButton:checked {
            background: rgba(14, 165, 233, 0.14);
            border: 1px solid rgba(14, 165, 233, 0.32);
            color: #0f172a;
        }
        QPushButton#PrimaryButton {
            background: #0ea5e9;
            border: 0;
            border-radius: 14px;
            color: white;
            font-weight: 700;
            padding: 12px 18px;
        }
        QPushButton#PrimaryButton:hover {
            background: #0284c7;
        }
        QPushButton#SecondaryButton {
            background: rgba(255, 255, 255, 0.72);
            border: 1px solid rgba(148, 163, 184, 0.28);
            border-radius: 14px;
            padding: 12px 18px;
        }
        QPushButton#SecondaryButton:hover {
            background: rgba(255, 255, 255, 0.94);
        }
        QPlainTextEdit {
            background: rgba(248, 250, 252, 0.96);
            border: 1px solid rgba(148, 163, 184, 0.22);
            border-radius: 16px;
            padding: 10px;
            selection-background-color: #0ea5e9;
        }
        QLineEdit, QComboBox, QSpinBox {
            background: rgba(255, 255, 255, 0.92);
            border: 1px solid rgba(148, 163, 184, 0.24);
            border-radius: 12px;
            padding: 10px 12px;
        }
        QTabWidget::pane {
            border: 0;
        }
        QTabBar::tab {
            background: rgba(255, 255, 255, 0.7);
            padding: 10px 18px;
            margin-right: 6px;
            border-radius: 12px;
        }
        QTabBar::tab:selected {
            background: rgba(14, 165, 233, 0.12);
        }
        """
    return """
    QWidget {
        background: #11161d;
        color: #e5edf7;
        font-family: "Microsoft YaHei UI";
        font-size: 13px;
    }
    QMainWindow {
        background: #0d1218;
    }
    QFrame#SidebarPanel {
        background: rgba(18, 24, 33, 0.86);
        border: 1px solid rgba(148, 163, 184, 0.12);
        border-radius: 22px;
    }
    QFrame#GlassCard {
        background: rgba(20, 26, 35, 0.82);
        border: 1px solid rgba(148, 163, 184, 0.1);
        border-radius: 20px;
    }
    QLabel#WindowTitle {
        font-size: 24px;
        font-weight: 700;
    }
    QLabel#SectionTitle {
        font-size: 18px;
        font-weight: 700;
    }
    QLabel#MutedText {
        color: #94a3b8;
    }
    QLabel#CardTitle {
        color: #8ba0b8;
        font-size: 12px;
        font-weight: 600;
        text-transform: uppercase;
    }
    QLabel#CardValue {
        font-size: 30px;
        font-weight: 700;
        color: #f8fafc;
    }
    QPushButton#NavButton {
        text-align: left;
        padding: 12px 14px;
        border-radius: 14px;
        border: 1px solid transparent;
        background: transparent;
    }
    QPushButton#NavButton:hover {
        background: rgba(56, 189, 248, 0.1);
        border: 1px solid rgba(56, 189, 248, 0.22);
    }
    QPushButton#NavButton:checked {
        background: rgba(56, 189, 248, 0.16);
        border: 1px solid rgba(56, 189, 248, 0.34);
        color: white;
    }
    QPushButton#PrimaryButton {
        background: #18b4d8;
        border: 0;
        border-radius: 14px;
        color: #041319;
        font-weight: 700;
        padding: 12px 18px;
    }
    QPushButton#PrimaryButton:hover {
        background: #38d2f6;
    }
    QPushButton#SecondaryButton {
        background: rgba(30, 41, 59, 0.64);
        border: 1px solid rgba(148, 163, 184, 0.12);
        border-radius: 14px;
        padding: 12px 18px;
    }
    QPushButton#SecondaryButton:hover {
        background: rgba(51, 65, 85, 0.72);
    }
    QPlainTextEdit {
        background: rgba(8, 12, 18, 0.96);
        border: 1px solid rgba(148, 163, 184, 0.1);
        border-radius: 16px;
        padding: 10px;
        selection-background-color: #18b4d8;
    }
    QLineEdit, QComboBox, QSpinBox {
        background: rgba(15, 23, 33, 0.92);
        border: 1px solid rgba(148, 163, 184, 0.12);
        border-radius: 12px;
        padding: 10px 12px;
    }
    QTabWidget::pane {
        border: 0;
    }
    QTabBar::tab {
        background: rgba(30, 41, 59, 0.62);
        padding: 10px 18px;
        margin-right: 6px;
        border-radius: 12px;
    }
    QTabBar::tab:selected {
        background: rgba(56, 189, 248, 0.14);
    }
    """
