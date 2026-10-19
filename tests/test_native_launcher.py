"""编译后的真实 Windows wrapper：失败不阻塞更新器，双管道不会死锁。"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(os.name != 'nt', reason='Windows launcher')


@pytest.mark.parametrize('code', [0, 7, -1])
def test_native_wrapper_drains_output_and_returns_failure(tmp_path, code):
    exe = tmp_path / '易容 Studio.exe'
    shutil.copy2(ROOT / exe.name, exe)
    runtime = tmp_path / '.venv-win/Scripts'
    runtime.mkdir(parents=True)
    shutil.copy2(sys.executable, runtime / 'python.exe')
    cfg = Path(sys.executable).parent.parent / 'pyvenv.cfg'
    if cfg.is_file():
        shutil.copy2(cfg, runtime.parent / cfg.name)
    else:
        (runtime.parent / 'pyvenv.cfg').write_text(f'home = {sys.base_prefix}\ninclude-system-site-packages = false\n')
    (tmp_path / 'launch_faceswap_studio.py').write_text(
        "import sys\nsys.stderr.write('e' * 200000); sys.stderr.flush()\n"
        f"sys.stdout.write('output complete'); sys.stdout.flush()\nsys.exit({code})\n")
    env = dict(os.environ, FACESWAP_STUDIO_UPDATE_SESSION=str(tmp_path / 'session'))
    result = subprocess.run([str(exe)], cwd=tmp_path, env=env, timeout=20)
    assert result.returncode & 0xffffffff == code & 0xffffffff
    log = (tmp_path / 'faceswap studio/runtime/launcher-wrapper.log').read_text('utf-8-sig')
    assert 'output complete' in log
    assert f'ExitCode={code}' in log
