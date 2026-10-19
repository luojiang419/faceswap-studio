"""调用安装器自身控件离屏渲染维护状态，不做桌面输入或屏幕捕获。"""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    output = ROOT / 'build/installer-maintenance'
    output.mkdir(exist_ok=True)
    executable = output / 'Preview.exe'
    command = ['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe',
               '/nologo', '/target:winexe', '/main:BootstrapPreview', '/out:' + str(executable),
               '/win32manifest:' + str(ROOT / 'installer/bootstrap/app.manifest')]
    command += ['/reference:' + name + '.dll' for name in (
        'System.Windows.Forms', 'System.Drawing', 'Accessibility', 'System.Web.Extensions',
        'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Management')]
    command += ['/resource:' + str(ROOT / name) + ',' + resource for name, resource in (
        ('installer/assets/app-mark.png', 'app-mark.png'), ('facefusion.ico', 'installer.ico'),
        ('installer/assets/disk-local-256.png', 'disk-local.png'))]
    command += [str(ROOT / 'installer/bootstrap' / name) for name in (
        'Program.cs', 'Installation.cs', 'Components.cs', 'DiskCard.cs', 'Maintenance.cs', 'Preview.cs')]
    subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([str(executable), str(args.manifest.resolve()), str(output / 'preview'), '--maintenance-only'],
                   cwd=ROOT, check=True, creationflags=subprocess.CREATE_NO_WINDOW)


if __name__ == '__main__':
    main()
