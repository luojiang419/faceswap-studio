"""构建签名应用更新包，并按需发布到魔搭。私钥仅保存在本机 .update-private。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT
sys.path.insert(0, str(ROOT))
from updater.transaction import safe_path, sha256, write_json, read_json


def file_url(repo, relative):
    return f"https://modelscope.cn/api/v1/models/{repo}/repo?" + urllib.parse.urlencode(
        {"Revision": "master", "FilePath": relative})


def keys():
    private = ROOT / ".update-private/signing-key"
    config = read_json(ROOT / "update-config.json")
    if private.exists():
        key = Ed25519PrivateKey.from_private_bytes(private.read_bytes())
    else:
        if config.get("publicKey"):
            raise ValueError("私钥缺失，不能自动替换客户端已信任的公钥")
        private.parent.mkdir(exist_ok=True)
        key = Ed25519PrivateKey.generate()
        with private.open("xb") as stream:
            stream.write(key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()))
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
    if config.get("publicKey") and config["publicKey"] != public:
        raise ValueError("私钥与已配置公钥不匹配")
    config["publicKey"] = public
    write_json(ROOT / "update-config.json", config)
    return key, config


def sources():
    for name in ("VERSION", "update-config.json", "facefusion.py", "facefusion.ico", "launch_faceswap_studio.py", "启动FaceSwap Studio.exe", "FaceSwapStudioUpdater.exe", "scripts/repair_runtime.ps1", "scripts/bootstrap_prepare.py"):
        yield ROOT / name, name
    for directory in ("facefusion", "faceswap studio/bridge", "faceswap studio/runtime/windows_app/current", "faceswap studio/flutter_app/build/web", "updater"):
        for file in sorted((ROOT / directory).rglob("*")):
            if file.is_file() and not any(p in ("__pycache__", ".git") for p in file.parts) and file.suffix not in (".pyc", ".pyo", ".log", ".cs"):
                yield file, file.relative_to(ROOT).as_posix()


def build(notes, min_version):
    key, config = keys()
    release_id = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    config["releaseId"] = release_id
    write_json(ROOT / "update-config.json", config)

    version = (ROOT / "VERSION").read_text("utf-8-sig").strip()
    output = ROOT / "dist/modelscope/updates" / f"{version}-{release_id}"
    if (output / "manifest.json").exists():
        raise ValueError(f"版本已构建，禁止覆盖不可变产物：{output}；请使用已有目录发布或修改正式版本")
    output.mkdir(parents=True, exist_ok=True)
    package = output / f"FaceSwap-Studio-{version}.zip"
    records = []
    with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file, relative in sources():
            safe_path(relative)
            archive.write(file, relative)
            records.append({"path": relative, "size": file.stat().st_size, "sha256": sha256(file)})
    release_path = f"releases/{version}/{release_id}/{package.name}"
    manifest = {"protocol": 1, "product": "faceswap-studio", "platform": "win32-x64", "version": version, "releaseId": release_id,
                "minVersion": min_version, "publishedAt": datetime.now(timezone.utc).isoformat(), "notes": notes,
                "package": {"name": package.name, "url": file_url(config["repository"], release_path),
                            "size": package.stat().st_size, "sha256": sha256(package)}, "files": records}
    payload = json.dumps(manifest, ensure_ascii=False, separators=(",", ":"))
    envelope = {"payload": payload, "signature": key.sign(payload.encode()).hex()}
    write_json(output / "manifest.json", manifest)
    write_json(output / "envelope.json", envelope)
    return output


def read_remote(url):
    request = urllib.request.Request(url, headers={"Range": "bytes=0-"})
    # 与 SHIYIN 发布器一致：匿名、直连回读，避免登录态掩盖公网访问问题。
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=120) as response:
        return response.read()


def publish(output):
    from modelscope.hub.api import HubApi
    from modelscope.hub.errors import HTTPError
    key, config = keys()
    envelope = read_json(output / "envelope.json")
    key.public_key().verify(bytes.fromhex(envelope["signature"]), envelope["payload"].encode())
    manifest = json.loads(envelope["payload"])
    if manifest != read_json(output / "manifest.json"):
        raise ValueError("清单与签名内容不一致")
    package = output / manifest["package"]["name"]
    if package.stat().st_size != manifest["package"]["size"] or sha256(package) != manifest["package"]["sha256"]:
        raise ValueError("待发布包校验失败")
    repo = config["repository"]
    api = HubApi()
    try:
        api.get_model(repo)
    except HTTPError as error:
        if getattr(error.response, "status_code", None) != 404:
            raise
        api.create_model(repo, visibility=5, license="Apache License 2.0", chinese_name="桌面工作台更新")
    remote_path = f"releases/{manifest['version']}/" + (f"{manifest['releaseId']}/" if manifest.get('releaseId') else "") + package.name
    existing = {item["Path"] for item in api.get_model_files(repo, recursive=True) if item["Type"] == "blob"}
    if remote_path in existing:
        if hashlib.sha256(read_remote(file_url(repo, remote_path))).hexdigest() != manifest["package"]["sha256"]:
            raise ValueError("远端已有同名不同内容版本，禁止覆盖")
    else:
        api.upload_file(path_or_fileobj=str(package), path_in_repo=remote_path, repo_id=repo,
                        commit_message=f"release: FaceSwap Studio {manifest['version']}")
    remote = read_remote(file_url(repo, remote_path))
    if len(remote) != manifest["package"]["size"] or hashlib.sha256(remote).hexdigest() != manifest["package"]["sha256"]:
        raise ValueError("魔搭匿名包回读校验失败，未激活更新")
    latest_url = config["manifestUrl"]
    if "public/latest.json" in existing:
        previous = json.loads(read_remote(latest_url))
        key.public_key().verify(bytes.fromhex(previous["signature"]), previous["payload"].encode())
        from updater.transaction import version
        previous_manifest = json.loads(previous["payload"])
        if version(previous_manifest["version"]) > version(manifest["version"]) or (
            version(previous_manifest["version"]) == version(manifest["version"]) and
            previous_manifest.get("releaseId", "00000000000000") > manifest.get("releaseId", "00000000000000")
        ):
            raise ValueError("禁止回退公网最新版本")
    activation = output / "activation"
    (activation / "public").mkdir(parents=True, exist_ok=True)
    (activation / "public/latest.json").write_bytes((output / "envelope.json").read_bytes())
    (activation / "configuration.json").write_text('{"framework":"pytorch","task":"face-generation","pipeline":{"type":"face-generation"}}', "utf-8")
    (activation / "README.md").write_text(
        "---\nlicense: apache-2.0\ntasks:\n- face-generation\n---\n# FaceSwap Studio 桌面更新\n\n"
        "此仓库仅存放 FaceSwap Studio 桌面更新，不包含模型权重或用户数据。\n\n"
        "客户端通过 public/latest.json 验证 Ed25519 签名，下载后校验 SHA-256。\n"
        "已有旧版首次接入请参阅源码仓库 docs/自动更新说明.md。\n", "utf-8")
    api.upload_folder(repo_id=repo, folder_path=str(activation), commit_message=f"activate: FaceSwap Studio {manifest['version']}")
    if json.loads(read_remote(latest_url)) != envelope:
        raise ValueError("魔搭最新入口匿名回读不一致")
    report = {"repository": repo, "version": manifest["version"], "releaseId": manifest.get("releaseId"), "sha256": manifest["package"]["sha256"],
              "size": manifest["package"]["size"], "anonymousVerification": True, "manifestUrl": latest_url}
    write_json(output / "publication.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", default="新增自动检查更新、独立更新器、签名校验及失败回滚。")
    parser.add_argument("--min-version", default="0.1.3")
    parser.add_argument("--init-key", action="store_true")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--snapshot", type=Path, help="复用已构建的不可变版本目录")
    args = parser.parse_args()
    if args.init_key:
        keys()
        print("本机签名密钥已就绪，公钥已写入客户端配置；私钥不进入 Git 与发布包。")
    else:
        output = args.snapshot.resolve(strict=True) if args.snapshot else build(args.notes, args.min_version)
        print(f"更新包：{output}")
        if args.publish:
            publish(output)
