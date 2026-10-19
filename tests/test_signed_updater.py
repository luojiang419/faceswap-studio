"""真实 ZIP、签名、替换和回滚测试；全部在独立临时目录运行。"""
import importlib.util
import json
from pathlib import Path
import sys
import zipfile

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from updater import transaction as u


def prepare(tmp_path, extra=None):
    root, session = tmp_path / "中文 便携目录", tmp_path / "更新 会话"
    root.mkdir(); session.mkdir()
    (root / "VERSION").write_text("2.0.1")
    files = {"VERSION": b'2.0.2',
             "faceswap studio/bridge/app_server.py": b"new desktop", "facefusion/new.py": b"new module"}
    if extra:
        files.update(extra)
    records = []
    with zipfile.ZipFile(session / "package.zip", "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
            import hashlib
            records.append({"path": name, "size": len(content), "sha256": hashlib.sha256(content).hexdigest()})
    key = Ed25519PrivateKey.generate()
    settings = {"root": str(root), "session": str(session), "currentVersion": "2.0.1", "parentPid": 999999,
                "publicKey": key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()}
    manifest = {"protocol": 1, "product": "faceswap-studio", "platform": "win32-x64", "version": "2.0.2", "minVersion": "0.2.0",
                "package": {"size": (session / "package.zip").stat().st_size, "sha256": u.sha256(session / "package.zip")}, "files": records}
    payload = json.dumps(manifest)
    u.write_json(session / "envelope.json", {"payload": payload, "signature": key.sign(payload.encode()).hex()})
    u.write_json(session / "session.json", settings)
    return root, session, settings


@pytest.mark.parametrize("relative", ["../main.js", "/faceswap studio/bridge/a", "data/config/a", "models/a", "runtime/a", "app/studio_config.json",
    "faceswap studio/bridge/../../data/a", "faceswap studio/bridge/C:/a", "faceswap studio/bridge/NUL.txt", "faceswap studio/bridge/a. ", "resources\\app\\a", "faceswap studio/bridge/./a", "faceswap studio/bridge/.env"])
def test_reject_unsafe_paths(relative):
    with pytest.raises(ValueError):
        u.safe_path(relative)


def test_install_and_rollback_preserves_data(tmp_path):
    root, session, settings = prepare(tmp_path)
    old = root / "faceswap studio/bridge/app_server.py"
    old.parent.mkdir(parents=True); old.write_bytes(b"old desktop")
    data = root / "data/config/studio_config.json"
    data.parent.mkdir(parents=True); data.write_bytes(b"user settings")
    model = root / "models/weights.bin"
    model.parent.mkdir(); model.write_bytes(b"model")
    manifest = u.validate(session, settings)
    u.install(root, session, manifest)
    assert old.read_bytes() == b"new desktop"
    assert (root / "facefusion/new.py").is_file()
    u.rollback(root, session)
    assert old.read_bytes() == b"old desktop"
    assert (root / "VERSION").read_text() == "2.0.1"
    assert not (root / "facefusion/new.py").exists()
    assert data.read_bytes() == b"user settings"
    assert model.read_bytes() == b"model"


def test_write_failure_rolls_back(tmp_path):
    root, session, settings = prepare(tmp_path)
    old = root / "faceswap studio/bridge/app_server.py"
    old.parent.mkdir(parents=True); old.write_bytes(b"old desktop")
    manifest = u.validate(session, settings)
    with pytest.raises(OSError, match="测试注入"):
        u.install(root, session, manifest, fail_after=2)
    assert old.read_bytes() == b"old desktop"
    assert (root / "VERSION").read_text() == "2.0.1"


def test_crash_recovery(tmp_path):
    root, session, settings = prepare(tmp_path)
    old = root / "faceswap studio/bridge/app_server.py"
    old.parent.mkdir(parents=True); old.write_bytes(b"original")
    manifest = u.validate(session, settings)
    u.install(root, session, manifest)
    u.write_json(root / "faceswap studio/data/cache/updates/pending.json", {"session": str(session)})
    u.run(session, recover=True)
    assert old.read_bytes() == b"original"
    assert not (root / "faceswap studio/data/cache/updates/pending.json").exists()


def test_package_tampering(tmp_path):
    _, session, settings = prepare(tmp_path)
    with (session / "package.zip").open("ab") as stream:
        stream.write(b"tampered")
    with pytest.raises(ValueError, match="完整性"):
        u.validate(session, settings)


def test_signature_tampering(tmp_path):
    _, session, settings = prepare(tmp_path)
    envelope = u.read_json(session / "envelope.json")
    envelope["payload"] += " "
    u.write_json(session / "envelope.json", envelope)
    from cryptography.exceptions import InvalidSignature
    with pytest.raises(InvalidSignature):
        u.validate(session, settings)


def test_protected_file_in_signed_package(tmp_path):
    _, session, settings = prepare(tmp_path, {"data/config/studio_config.json": b"forbidden"})
    with pytest.raises(ValueError, match="禁止"):
        u.validate(session, settings)


def test_reject_downgrade(tmp_path):
    _, session, settings = prepare(tmp_path)
    settings["currentVersion"] = "2.0.2"
    with pytest.raises(ValueError, match="相同或更旧"):
        u.validate(session, settings)


def test_reject_junction(tmp_path):
    root, session, settings = prepare(tmp_path)
    external = tmp_path / "用户 外部目录"
    external.mkdir()
    (root / "faceswap studio").mkdir()
    import subprocess
    result = subprocess.run(["cmd", "/c", "mklink", "/J", str(root / "faceswap studio/bridge"), str(external)], capture_output=True)
    assert result.returncode == 0
    with pytest.raises(ValueError):
        u.install(root, session, u.validate(session, settings))
    assert not list(external.iterdir())


def test_failed_restart_restores_and_reopens_old_version(tmp_path, monkeypatch):
    root, session, settings = prepare(tmp_path)
    old = root / "faceswap studio/bridge/app_server.py"
    old.parent.mkdir(parents=True); old.write_bytes(b"working old version")
    monkeypatch.setattr(u, "wait_exit", lambda *args: None)
    monkeypatch.setattr(u, 'preflight_update', lambda *args: None)
    u.write_json(session / 'health-challenge.json', {'token': 'test'})
    restarts = []
    class FailedChild:
        pid = 12345
        def poll(self): return 1
    def restart(root, session, health=True):
        restarts.append(health)
        return FailedChild()
    monkeypatch.setattr(u, "restart", restart)
    with pytest.raises(RuntimeError, match="启动失败"):
        u.run(session)
    assert restarts == [True, False]
    assert old.read_bytes() == b"working old version"
    assert not (root / "faceswap studio/data/cache/updates/pending.json").exists()
    assert u.read_json(session / "journal.json")["status"] == "rolled-back"


def test_success_requires_health_ack(tmp_path, monkeypatch):
    root, session, settings = prepare(tmp_path)
    monkeypatch.setattr(u, "wait_exit", lambda *args: None)
    monkeypatch.setattr(u, 'preflight_update', lambda *args: None)
    monkeypatch.setattr(u, 'HEALTH_STABILITY_SECONDS', 0)
    u.write_json(session / 'health-challenge.json', {'token': 'test'})
    class HealthyChild:
        pid = 12345
        def poll(self): return None
    def restart(root, session, health=True):
        u.write_json(session / "healthy.json", {'ok': True, 'status': 'ready', 'version': '2.0.2',
                     'root': str(root.resolve()), 'pid': 12345, 'token': 'test', 'coreState': 'ready', 'checkedAt': u.time.time()})
        return HealthyChild()
    monkeypatch.setattr(u, "restart", restart)
    u.run(session)
    assert u.read_json(session / "status.json")["status"] == "complete"
    assert u.read_json(session / "journal.json")["status"] == "complete"


def test_failed_rollback_keeps_pending_for_recovery(tmp_path, monkeypatch):
    root, session, settings = prepare(tmp_path)
    monkeypatch.setattr(u, "wait_exit", lambda *args: None)
    monkeypatch.setattr(u, 'preflight_update', lambda *args: None)
    def fail_install(root, session, manifest):
        u.write_json(session / "journal.json", {"status": "installing", "changes": []})
        raise OSError("写入故障")
    def fail_rollback(root, session):
        raise PermissionError("文件仍被锁定")
    monkeypatch.setattr(u, "install", fail_install)
    monkeypatch.setattr(u, "rollback", fail_rollback)
    with pytest.raises(PermissionError):
        u.run(session)
    assert (root / "faceswap studio/data/cache/updates/pending.json").is_file()
