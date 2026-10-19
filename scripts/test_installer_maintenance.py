"""编译并运行原生维护引擎回归；只操作本轮隔离测试目录。"""
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/installer-maintenance'


def main():
    OUTPUT.mkdir(exist_ok=True)
    executable = OUTPUT / 'MaintenanceTests.exe'
    command = ['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe',
               '/nologo', '/target:exe', '/main:MaintenanceTests', '/out:' + str(executable),
               '/win32manifest:' + str(ROOT / 'installer/bootstrap/app.manifest')]
    command += ['/reference:' + name + '.dll' for name in (
        'System.Windows.Forms', 'System.Drawing', 'Accessibility', 'System.Web.Extensions',
        'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Management')]
    command += [str(ROOT / 'installer/bootstrap' / name) for name in (
        'Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs', 'Maintenance.cs', 'MaintenanceTests.cs')]
    subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([str(executable), str(OUTPUT / ('tests-' + uuid.uuid4().hex[:8]))],
                   cwd=ROOT, check=True)
    for entry, source in (('BootstrapTests', 'Tests.cs'), ('InstallationTests', 'InstallationTests.cs')):
        regression = OUTPUT / (entry + '.exe')
        options = [argument for argument in command[1:] if argument.startswith('/')
                   and not argument.startswith(('/main:', '/out:'))]
        existing = [command[0], *options, '/main:' + entry, '/out:' + str(regression)]
        existing += [str(ROOT / 'installer/bootstrap' / name) for name in (
            'Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs', 'Maintenance.cs', source)]
        subprocess.run(existing, cwd=ROOT, check=True)
        subprocess.run([str(regression)], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
