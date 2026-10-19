"""真实 WinForms 生命周期：成功自动退出，100% 进度不能代替执行器成功。"""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(os.name != 'nt', reason='Windows updater')


@pytest.fixture(scope='module')
def native_updater(tmp_path_factory):
    build = tmp_path_factory.mktemp('native-updater')
    brand = build / 'InstallerBrand.generated.cs'
    subprocess.run([
        'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        str(ROOT / 'scripts/export_installer_brand.ps1'), '-OutputPath', str(brand),
    ], cwd=ROOT, check=True, capture_output=True, timeout=30)
    compiler = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    binary = build / 'UpdaterLifecycleSmoke.exe'
    references = ('System', 'System.Core', 'System.Drawing', 'System.Windows.Forms',
                  'Accessibility', 'System.Web.Extensions', 'System.IO.Compression',
                  'System.IO.Compression.FileSystem')
    subprocess.run([
        str(compiler), '/nologo', '/target:exe', '/main:UpdaterLifecycleSmoke',
        '/out:' + str(binary),
        *['/r:' + name + '.dll' for name in references],
        str(ROOT / 'updater/FaceSwapStudioUpdater.cs'),
        str(ROOT / 'updater/StudioUpdateSurface.cs'),
        str(ROOT / 'updater/InstallationIntegration.cs'), str(brand),
        str(ROOT / 'tests/native/UpdaterLifecycleSmoke.cs'),
    ], cwd=ROOT, check=True, capture_output=True, timeout=30)
    return binary


@pytest.mark.parametrize(('mode', 'code'), [
    ('legacy', 0), ('now', 0), ('startup', 0), ('later', 0),
    ('legacy', 1), ('now', 1), ('startup', 1), ('later', 1), ('now', 2),
])
def test_updater_window_lifecycle(native_updater, tmp_path, mode, code):
    (tmp_path / 'prompt.json').write_text(json.dumps({
        'root': str(tmp_path), 'current_version': '0.1.3', 'latest_version': '0.1.3',
        'notes': '隔离测试，不修改正式安装。',
    }), encoding='utf-8')
    worker = (
        'import json, time\nfrom pathlib import Path\n'
        'print(json.dumps({"message": "checking", "progress": 100}), flush=True)\n'
        'time.sleep(1)\n'
        'Path("worker-finished").touch()\n'
        f'raise SystemExit({code})\n'
    )
    for name in ('offer.py', 'transaction.py'):
        (tmp_path / name).write_text(worker, encoding='utf-8')
    result = subprocess.run([
        str(native_updater), mode, str(tmp_path), sys.executable, str(code),
    ], cwd=ROOT, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert f'PASS {mode} exit={code}' in result.stdout
