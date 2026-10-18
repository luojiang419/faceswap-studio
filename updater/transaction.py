"""FaceSwap 独立更新事务。仅使用便携 Python 与已有 cryptography。"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import time
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def write_json(file: Path, value):
    file.parent.mkdir(parents=True, exist_ok=True)
    temporary = file.with_name(file.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, file)


def read_json(file):
    return json.loads(Path(file).read_text("utf-8-sig"))


def sha256(file):
    with Path(file).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def emit(message, progress=0):
    print(json.dumps({"message": message, "progress": progress}, ensure_ascii=True), flush=True)


def safe_path(relative: str) -> str:
    if not isinstance(relative, str) or "\\" in relative or ":" in relative or "\x00" in relative:
        raise ValueError("更新路径非法")
    parts = PurePosixPath(relative).parts
    if not parts or relative != "/".join(parts) or any(
        p in (".", "..") or p.endswith((".", " ")) or
        re.match(r"^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)", p, re.I)
        for p in parts
    ):
        raise ValueError(f"更新路径非法：{relative}")
    allowed = (
        relative.startswith(("facefusion/", "faceswap studio/bridge/", "faceswap studio/runtime/windows_app/current/", "faceswap studio/flutter_app/build/web/", "updater/")) or
        relative in ("VERSION", "update-config.json", "facefusion.py", "facefusion.ico", "launch_faceswap_studio.py", "启动FaceSwap Studio.exe", "FaceSwapStudioUpdater.exe", "scripts/repair_runtime.ps1", "scripts/bootstrap_prepare.py")
    )
    if not allowed or any(p.lower() in (".git", "__pycache__", "node_modules", ".env", ".assets", ".venv-win", ".python") for p in parts):
        raise ValueError(f"更新禁止覆盖此路径：{relative}")
    return relative


def destination(root: Path, relative: str):
    target = root / safe_path(relative)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError("更新路径超出软件目录")
    cursor = target
    while cursor != root:
        if cursor.is_symlink() or cursor.is_junction():
            raise ValueError("更新目标不能是符号链接或目录联接")
        cursor = cursor.parent
    if target.exists() and not target.is_file():
        raise ValueError("更新文件目标已被目录占用")
    return target


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("版本号格式无效")
    return tuple(map(int, value.split(".")))


def validate(session: Path, settings):
    envelope = read_json(session / "envelope.json")
    Ed25519PublicKey.from_public_bytes(bytes.fromhex(settings["publicKey"])).verify(
        bytes.fromhex(envelope["signature"]), envelope["payload"].encode("utf-8"))
    manifest = json.loads(envelope["payload"])
    if (manifest.get("protocol"), manifest.get("product"), manifest.get("platform")) != (
        1, "faceswap-studio", "win32-x64"
    ):
        raise ValueError("更新包不兼容")
    release_id = manifest.get("releaseId", "00000000000000")
    if not re.fullmatch(r"\d{14}", release_id):
        raise ValueError("发布序号无效")
    if version(manifest["version"]) < version(settings["currentVersion"]) or (
        version(manifest["version"]) == version(settings["currentVersion"]) and
        release_id <= settings.get("currentReleaseId", "00000000000000")
    ):
        raise ValueError("拒绝安装相同或更旧的版本")
    if version(settings["currentVersion"]) < version(manifest["minVersion"]):
        raise ValueError("需要先升级完整便携基线")
    package = session / "package.zip"
    meta = manifest["package"]
    if package.stat().st_size != meta["size"] or sha256(package) != meta["sha256"]:
        raise ValueError("更新包完整性校验失败")
    records = manifest["files"]
    if not records or len(records) > 20000:
        raise ValueError("更新文件数量无效")
    names = set()
    total = 0
    for record in records:
        relative = safe_path(record["path"])
        if relative.lower() in names:
            raise ValueError("更新包含重复路径")
        names.add(relative.lower())
        if not isinstance(record["size"], int) or record["size"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
            raise ValueError("更新文件元数据无效")
        total += record["size"]
    if total > 2 * 1024 ** 3:
        raise ValueError("更新解压总量超过限制")
    stage = session / "stage"
    stage.mkdir(exist_ok=True)
    with zipfile.ZipFile(package) as archive:
        entries = archive.infolist()
        if len(entries) != len(records) or {e.filename for e in entries} != {r["path"] for r in records}:
            raise ValueError("压缩包与签名文件清单不一致")
        by_name = {e.filename: e for e in entries}
        for record in records:
            entry = by_name[record["path"]]
            if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size != record["size"]:
                raise ValueError("更新包含链接或文件大小异常")
            target = destination(stage, record["path"])
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            if sha256(target) != record["sha256"]:
                raise ValueError("解压文件哈希校验失败")
    package_json = {"version": (stage / "VERSION").read_text("utf-8-sig").strip()}
    if package_json["version"] != manifest["version"]:
        raise ValueError("应用版本与发布清单不一致")
    if manifest.get("releaseId") and read_json(stage / "update-config.json").get("releaseId") != release_id:
        raise ValueError("应用发布序号与清单不一致")
    return manifest


def alive(pid):
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        handle = kernel.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return ctypes.get_last_error() == 5
        try:
            code = ctypes.c_ulong()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False


def wait_exit(pid, timeout=120):
    deadline = time.monotonic() + timeout
    while alive(pid):
        if time.monotonic() >= deadline:
            raise TimeoutError("软件尚未退出，已取消安装，请关闭软件后重新尝试")
        time.sleep(0.2)


def rollback(root: Path, session: Path):
    journal_path = session / "journal.json"
    if not journal_path.exists():
        return
    journal = read_json(journal_path)
    for change in reversed(journal["changes"]):
        target = destination(root, change["path"])
        if change["existed"]:
            backup = session / "backup" / change["path"]
            if not backup.is_file():
                raise RuntimeError(f"回滚备份缺失：{change['path']}")
            temporary = target.with_name(target.name + ".faceswap-rollback")
            shutil.copy2(backup, temporary)
            os.replace(temporary, target)
        else:
            target.unlink(missing_ok=True)
    journal["status"] = "rolled-back"
    write_json(journal_path, journal)


def install(root: Path, session: Path, manifest, fail_after=None):
    journal = {"status": "installing", "version": manifest["version"], "changes": []}
    for record in manifest["files"]:
        destination(root, record["path"])
    if shutil.disk_usage(root).free < sum(r["size"] for r in manifest["files"]) * 2 + 20 * 1024 ** 2:
        raise OSError("软件所在磁盘空间不足")
    try:
        for index, record in enumerate(manifest["files"]):
            relative = record["path"]
            target = destination(root, relative)
            existed = target.is_file()
            if existed:
                backup = session / "backup" / relative
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup)
            target.parent.mkdir(parents=True, exist_ok=True)
            journal["changes"].append({"path": relative, "existed": existed})
            write_json(session / "journal.json", journal)
            temporary = target.with_name(target.name + ".faceswap-update")
            shutil.copy2(session / "stage" / relative, temporary)
            os.replace(temporary, target)
            emit(f"正在安装 {index + 1}/{len(manifest['files'])}", 30 + int((index + 1) * 55 / len(manifest["files"])))
            if fail_after is not None and index + 1 >= fail_after:
                raise OSError("测试注入写入失败")
        journal["status"] = "awaiting-health"
        write_json(session / "journal.json", journal)
    except BaseException:
        rollback(root, session)
        raise


def preparation_deadline(session, manifest, pid, deadline, limit):
    """只有本次新版进程的近期准备心跳能延长健康检查，有24小时上限。"""
    preparing = session / 'healthy.json.preparing'
    try:
        if preparing.exists() and time.time() - preparing.stat().st_mtime < 45:
            state = read_json(preparing)
            if (state.get('version') == manifest['version'] and state.get('releaseId') == manifest.get('releaseId', '00000000000000')
                    and state.get('pid') == pid and state.get('status') not in ('error', 'cancelled')):
                return min(limit, time.monotonic() + 210)
    except (OSError, ValueError):
        pass
    return deadline


def restart(root, session, health=True):
    env = {k: v for k, v in os.environ.items() if k not in (
        "ELECTRON_RUN_AS_NODE", "FACESWAP_STUDIO_UPDATE_HEALTH_FILE", "FACESWAP_STUDIO_UPDATE_SESSION")}
    if health:
        env["FACESWAP_STUDIO_UPDATE_HEALTH_FILE"] = str(session / "healthy.json")
        env["FACESWAP_STUDIO_UPDATE_SESSION"] = str(session)
    return subprocess.Popen([str(root / "启动FaceSwap Studio.exe")], cwd=root, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run(session: Path, recover=False):
    settings = read_json(session / "session.json")
    root = Path(settings["root"]).resolve(strict=True)
    if str(session) != settings["session"] or not (root / "VERSION").is_file():
        raise ValueError("更新会话或便携目录无效")
    pending = root / "faceswap studio/data/cache/updates/pending.json"
    if recover:
        journal = read_json(session / "journal.json") if (session / "journal.json").exists() else {}
        if journal.get("status") not in ("complete", "rolled-back"):
            rollback(root, session)
        pending.unlink(missing_ok=True)
        return
    emit("正在验证签名与更新文件…", 5)
    manifest = validate(session, settings)
    emit("等待主程序退出…", 20)
    wait_exit(settings["parentPid"])
    write_json(pending, {"session": str(session), "pid": os.getpid()})
    write_json(session / "status.json", {"status": "installing", "version": manifest["version"]})
    try:
        install(root, session, manifest)
        emit("正在重启并检查本地服务…", 90)
        child = restart(root, session)
        deadline = time.monotonic() + 210
        preparation_limit = time.monotonic() + 24 * 3600
        try:
            while time.monotonic() < deadline:
                deadline = preparation_deadline(session, manifest, child.pid, deadline, preparation_limit)
                if (session / "healthy.json").exists():
                    health = read_json(session / "healthy.json")
                    if health.get("version") == manifest["version"] and health.get("releaseId", "00000000000000") == manifest.get("releaseId", "00000000000000"):
                        break
                if child.poll() is not None:
                    raise RuntimeError("新版软件启动失败")
                time.sleep(0.5)
            else:
                raise TimeoutError("新版启动检查超时")
        except BaseException:
            if child.poll() is None:
                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], capture_output=True)
                wait_exit(child.pid, 20)
            raise
        journal = read_json(session / "journal.json")
        journal["status"] = "complete"
        write_json(session / "journal.json", journal)
        write_json(session / "status.json", {"status": "complete", "version": manifest["version"]})
        emit("更新完成，本地服务已就绪。", 100)
    except BaseException as error:
        rollback(root, session)
        write_json(session / "status.json", {"status": "error", "message": str(error)})
        pending.unlink(missing_ok=True)
        restart(root, session, health=False)
        raise
    finally:
        journal_path = session / "journal.json"
        if not journal_path.exists() or read_json(journal_path).get("status") in ("complete", "rolled-back"):
            pending.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    parser.add_argument("--recover", action="store_true")
    args = parser.parse_args()
    try:
        run(args.session.resolve(strict=True), args.recover)
    except BaseException as error:
        emit(f"更新失败：{error}。已保留日志与回滚记录。")
        sys.exit(1)
