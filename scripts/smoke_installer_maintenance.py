"""用最终正式 EXE 对真实完整运行包执行只读检查、损坏恢复和复检。"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('distribution', type=Path)
    args = parser.parse_args()
    distribution = args.distribution.resolve(strict=True)
    manifest_path = distribution / 'bootstrap-manifest.json'
    manifest = json.loads(manifest_path.read_text('utf-8'))
    installer = distribution / 'FaceSwap安装器.exe'
    package = distribution / manifest['package']['name']
    output = ROOT / 'build/installer-maintenance' / ('real-' + uuid.uuid4().hex[:8])
    output.mkdir()
    target = output / '中文 真实维护安装'
    helper = output / 'MaintenanceSmoke.exe'
    command = ['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe', '/nologo',
               '/target:exe', '/main:MaintenanceSmoke', '/out:' + str(helper),
               '/win32manifest:' + str(ROOT / 'installer/bootstrap/app.manifest')]
    command += ['/reference:' + name + '.dll' for name in (
        'System.Windows.Forms', 'System.Drawing', 'Accessibility', 'System.Web.Extensions',
        'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Management')]
    command += [str(ROOT / 'installer/bootstrap' / name) for name in (
        'Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs', 'Maintenance.cs', 'MaintenanceSmoke.cs')]
    subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([str(helper), str(manifest_path), str(package), str(installer), str(target)],
                   cwd=ROOT, check=True)

    def run(name, repair=False, expected=0):
        report = output / (name + '.json')
        code = subprocess.run([str(installer), '--repair-root' if repair else '--inspect-root', str(target),
                               '--report', str(report), '--package', str(package)], cwd=ROOT,
                              creationflags=subprocess.CREATE_NO_WINDOW).returncode
        result = json.loads(report.read_text('utf-8-sig'))
        assert code == expected, result
        print(name + ': ' + json.dumps(result, ensure_ascii=False), flush=True)
        return result

    before = {p.relative_to(target).as_posix(): p.stat().st_mtime_ns for p in target.rglob('*') if p.is_file()}
    pristine = run('healthy-before')
    assert pristine['status'] == 'healthy' and not pristine['repaired']
    after = {p.relative_to(target).as_posix(): p.stat().st_mtime_ns for p in target.rglob('*') if p.is_file()}
    assert before == after, '正常检查写入了安装目录'
    # 所有修改都在本轮隔离安装内；实际 EXE 必须在目标 Python 缺失时仍能修复。
    (target / '.venv-win/Scripts/python.exe').unlink()
    bridge = target / 'faceswap studio/bridge/app_server.py'
    original = bridge.read_bytes()
    bridge.write_bytes(b'#' + original[1:])
    assert bridge.read_bytes() != original
    model = next(p for p in (target / '.assets/models').glob('*.hash'))
    model.write_text('00000000', encoding='ascii')
    sentinels = {
        'faceswap studio/data/output/保留作品.txt': b'personal-work',
        'faceswap studio/config/settings.json': b'{"theme":"dark"}',
        '.assets/models/custom-user-model.onnx': b'personal-model',
        'facefusion.ini': (target / 'facefusion.ini').read_bytes() + b'\n# personal preference\n',
    }
    for name, data in sentinels.items():
        file = target / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(data)
    damaged = run('damage-detected', expected=2)
    assert damaged['status'] == 'damaged' and len(damaged['issues']) >= 3
    repaired = run('repaired', repair=True)
    assert repaired['status'] == 'repaired' and repaired['repaired']
    assert all((target / name).read_bytes() == data for name, data in sentinels.items())
    assert bridge.read_bytes() == original
    healthy = run('healthy-after')
    assert healthy['status'] == 'healthy'
    receipt = {'ok': True, 'releaseId': manifest['releaseId'], 'installer': str(installer),
               'installerSha256': hashlib.file_digest(installer.open('rb'), 'sha256').hexdigest(),
               'isolatedRoot': str(target), 'actualInstallerCLI': True, 'realPythonAndModels': True,
               'healthyCheckReadOnly': True, 'missingPythonRestored': True,
               'sameSizeCorruptionRestored': True, 'modelHashRestored': True,
               'personalDataPreserved': True, 'postRepairRecheck': True,
               'noActualFirstInstallHandshakeClaimed': True}
    (output / 'result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    (ROOT / 'build/installer-maintenance/real-validation.json').write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(receipt, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
