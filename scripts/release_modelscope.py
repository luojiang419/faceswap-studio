"""构建签名应用更新包，并按需发布到魔搭。私钥仅保存在本机 .update-private。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT
sys.path.insert(0, str(ROOT))
from updater.transaction import safe_path, sha256, write_json, read_json
from updater.preflight import run_preflight


def validate_package(package, python=None):
    """验证 ZIP 中的实际代码，不以开发目录通过代替发布包通过。"""
    with tempfile.TemporaryDirectory(prefix='faceswap-release-') as directory:
        stage = Path(directory)
        with zipfile.ZipFile(package) as archive:
            for entry in archive.infolist():
                target = stage / safe_path(entry.filename)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
        required = ('VERSION', 'update-config.json', 'launch_faceswap_studio.py',
                    'FaceSwapStudioUpdater.exe', 'updater/preflight.py',
                    'faceswap studio/runtime/windows_app/current/faceswap_studio.exe',
                    'faceswap studio/runtime/windows_app/current/flutter_windows.dll',
                    'faceswap studio/runtime/windows_app/current/data/app.so',
                    'faceswap studio/runtime/windows_app/current/data/icudtl.dat')
        for name in required:
            if not (stage / name).is_file() or not (stage / name).stat().st_size:
                raise ValueError('更新包缺少必要文件：' + name)
        if not any((stage / name).is_file() and (stage / name).stat().st_size for name in ('易容 Studio.exe', '启动FaceSwap Studio.exe')):
            raise ValueError('更新包缺少必要文件：桌面启动入口')
        return run_preflight(stage, python=python)


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
    for name in ("VERSION", "update-config.json", "facefusion.py", "facefusion.ico", "launch_faceswap_studio.py", "易容 Studio.exe", "FaceSwapStudioUpdater.exe", "scripts/repair_runtime.ps1", "scripts/bootstrap_prepare.py"):
        yield ROOT / name, name
    for directory in ("facefusion", "faceswap studio/bridge", "faceswap studio/runtime/windows_app/current", "faceswap studio/flutter_app/build/web", "updater"):
        for file in sorted((ROOT / directory).rglob("*")):
            if file.is_file() and not any(p in ("__pycache__", ".git") for p in file.parts) and file.suffix not in (".pyc", ".pyo", ".log", ".cs"):
                yield file, file.relative_to(ROOT).as_posix()


def build(notes, min_version, legacy_entry=False):
    run_preflight(ROOT)
    subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    str(ROOT / 'scripts/build_launcher.ps1')], cwd=ROOT, check=True)
    key, config = keys()
    release_id = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    config["releaseId"] = release_id
    write_json(ROOT / "update-config.json", config)

    version = (ROOT / "VERSION").read_text("utf-8-sig").strip()
    output = ROOT / "dist/modelscope/updates" / f"{version}-{release_id}"
    if (output / "manifest.json").exists():
        raise ValueError(f"版本已构建，禁止覆盖不可变产物：{output}；请使用已有目录发布或修改正式版本")
    output.mkdir(parents=True, exist_ok=True)
    package = output / f"易容-Studio-{version}.zip"
    records = []
    with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file, relative in sources():
            if legacy_entry and relative == '易容 Studio.exe':
                relative = '启动FaceSwap Studio.exe'
            safe_path(relative)
            archive.write(file, relative)
            records.append({"path": relative, "size": file.stat().st_size, "sha256": sha256(file)})
    validation = validate_package(package)
    write_json(output / 'preflight.json', validation)
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


def bind_installer(output, installer_directory):
    """将同一基准的维护入口绑定到签名更新，旧用户升级后也获得新卸载/维护程序。"""
    key, config = keys()
    manifest = read_json(output / 'manifest.json')
    bootstrap = read_json(installer_directory / 'bootstrap-manifest.json')
    plan = read_json(installer_directory / 'publication-plan.json')
    if bootstrap['appVersion'] != manifest['version'] or bootstrap['appReleaseId'] != manifest['releaseId']:
        raise ValueError('安装器与应用更新不是同一个基准')
    installer = Path(plan['installer'])
    manifest['installer'] = {'name': installer.name, 'size': installer.stat().st_size, 'sha256': sha256(installer),
                             'url': file_url(config['repository'], plan['prefix'] + '/' + installer.name)}
    payload = json.dumps(manifest, ensure_ascii=False, separators=(',', ':'))
    write_json(output / 'manifest.json', manifest)
    write_json(output / 'envelope.json', {'payload': payload, 'signature': key.sign(payload.encode()).hex()})


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
    # 校验签名和哈希后、连接远端前验包，包括复用 --snapshot 的发布。
    validation_python = ROOT / '.venv-win/Scripts/python.exe'
    validate_package(package, python=validation_python if validation_python.is_file() else None)
    repo = config["repository"]
    api = HubApi()
    try:
        api.get_model(repo)
    except HTTPError as error:
        if getattr(error.response, "status_code", None) != 404:
            raise
        api.create_model(repo, visibility=5, license="Apache License 2.0", chinese_name="桌面工作台更新")
    remote_path = f"releases/{manifest['version']}/" + (f"{manifest['releaseId']}/" if manifest.get('releaseId') else "") + package.name
    remote_records = api.get_model_files(repo, recursive=True)
    existing = {item["Path"] for item in remote_records if item["Type"] == "blob"}
    from build_lightweight import publish_asset
    proof = publish_asset(package, remote_path)
    installer = manifest.get('installer')
    if installer:
        installer_path = urllib.parse.parse_qs(urllib.parse.urlsplit(installer['url']).query)['FilePath'][0]
        if file_url(repo, installer_path) != installer['url']:
            raise ValueError('基准安装器不属于当前分发仓库')
        record = next((item for item in remote_records if item['Path'] == installer_path), None)
        if not record or record.get('Sha256') != installer['sha256'] or record.get('Size') != installer['size']:
            raise ValueError('基准安装器尚未发布或与签名清单不一致，未激活更新')
        from build_lightweight import verify_public_access
        verify_public_access(installer['url'], installer['size'])
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
    installer_link = f"[下载易容 Studio 基准安装器]({installer['url']})\n\n" if installer else ''
    (activation / "README.md").write_text(
        "---\nlicense: other\ntasks:\n- face-generation\n---\n# 易容 Studio 桌面更新\n\n"
        + installer_link +
        "新用户运行基准安装器完成安装，启动后自动检查最新应用更新，并可使用检查修复和独立更新器。\n\n"
        "旧用户可运行新基准安装器检查并更新已有受管理安装，保留作品、人物形象、配置和自定义模型。已支持签名更新且运行环境兼容的 0.1.3 版本，也可在软件内手动检查更新一次；完成后，后续版本会直接弹出独立更新器，选择现在更新或下次启动更新。\n\n"
        "此仓库存放 易容 Studio 桌面更新、运行包及内置可选模型镜像，不包含用户数据。\n\n"
        "客户端通过 public/latest.json 验证 Ed25519 签名，下载后校验 SHA-256。优先使用已验证的魔搭模型；尚无镜像的权重标记外网下载，自动使用系统代理。模型各自沿用上游许可，来源与许可见 models/facefusion-3.9.0-v1/catalog.json，不能将全部模型视为 Apache 授权。\n"
        "应用更新只下载应用文件，不重复下载未变的 Python、模型和运行环境。\n", "utf-8")
    api.upload_folder(repo_id=repo, folder_path=str(activation), commit_message=f"activate: 易容 Studio {manifest['version']}")
    if json.loads(read_remote(latest_url)) != envelope:
        raise ValueError("魔搭最新入口匿名回读不一致")
    report = {"repository": repo, "version": manifest["version"], "releaseId": manifest.get("releaseId"), "sha256": manifest["package"]["sha256"],
              "size": manifest["package"]["size"], "anonymousVerification": True, "manifestUrl": latest_url,
              "remoteMetadataVerified": proof['remoteMetadataVerified'], "anonymousFullVerified": proof['anonymousFullVerified']}
    write_json(output / "publication.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", default="新增自动检查更新、独立更新器、签名校验及失败回滚。")
    parser.add_argument("--min-version", default="0.1.3")
    parser.add_argument("--init-key", action="store_true")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--legacy-entry", action="store_true", help="为旧客户端生成兼容原启动入口白名单的过渡更新包")
    parser.add_argument("--bind-installer", type=Path, help="将同一发行的基准安装器绑定为旧用户的新维护入口")
    parser.add_argument("--snapshot", type=Path, help="复用已构建的不可变版本目录")
    args = parser.parse_args()
    if args.init_key:
        keys()
        print("本机签名密钥已就绪，公钥已写入客户端配置；私钥不进入 Git 与发布包。")
    else:
        output = args.snapshot.resolve(strict=True) if args.snapshot else build(args.notes, args.min_version, legacy_entry=args.legacy_entry)
        if args.bind_installer:
            bind_installer(output, args.bind_installer.resolve(strict=True))
        print(f"更新包：{output}")
        if args.publish:
            publish(output)
