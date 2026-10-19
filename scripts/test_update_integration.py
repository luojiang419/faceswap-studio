"""在隔离目录和隔离 HKCU 键验证更新完成后的安装入口迁移。"""
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
output=ROOT/'build/update-integration'
output.mkdir(exist_ok=True)
binary=output/'IntegrationTests.exe'
command=['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe','/nologo','/target:exe',
         '/main:InstallationIntegrationTests','/out:'+str(binary),'/r:System.dll','/r:System.Core.dll','/r:System.Web.Extensions.dll',
         str(ROOT/'updater/InstallationIntegration.cs'),str(ROOT/'updater/InstallationIntegrationTests.cs')]
subprocess.run(command,cwd=ROOT,check=True)
subprocess.run([str(binary),str(output/uuid.uuid4().hex)],cwd=ROOT,check=True)
