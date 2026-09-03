import importlib.util
import json
from pathlib import Path


LAUNCHER_PATH = Path(__file__).resolve().parents[1] / 'launch_faceswap_studio.py'
LAUNCHER_SPEC = importlib.util.spec_from_file_location('faceswap_studio_launcher_updates', LAUNCHER_PATH)
assert LAUNCHER_SPEC is not None
assert LAUNCHER_SPEC.loader is not None
LAUNCHER_MODULE = importlib.util.module_from_spec(LAUNCHER_SPEC)
LAUNCHER_SPEC.loader.exec_module(LAUNCHER_MODULE)


def create_repo(tmp_path : Path) -> tuple[Path, Path, Path]:
	repo_root = tmp_path / 'repo'
	studio_root = repo_root / 'faceswap studio'
	localappdata = tmp_path / 'localappdata'
	studio_root.mkdir(parents = True, exist_ok = True)
	(repo_root / 'VERSION').write_text('0.1.1', encoding = 'utf-8')
	(repo_root / '启动FaceSwap Studio.exe').write_bytes(b'launcher')
	(repo_root / 'FaceSwapStudioUpdater.exe').write_bytes(b'updater')
	return repo_root, studio_root, localappdata


def write_pending_marker(repo_root : Path, localappdata : Path, version : str, package_path : Path, root_path : Path | None = None) -> Path:
	marker_path = localappdata / 'FaceSwap Studio' / 'updates' / 'pending-update.json'
	marker_path.parent.mkdir(parents = True, exist_ok = True)
	marker_path.write_text(json.dumps({
		'version': version,
		'package_path': str(package_path),
		'restart_path': str(repo_root / '启动FaceSwap Studio.exe'),
		'root_path': str(root_path or repo_root),
		'scheduled_at': '2026-06-27T10:10:00'
	}, ensure_ascii = False), encoding = 'utf-8')
	return marker_path


def test_launch_pending_update_starts_updater(monkeypatch, tmp_path : Path) -> None:
	repo_root, studio_root, localappdata = create_repo(tmp_path)
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	package_path = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'delta.zip'
	package_path.parent.mkdir(parents = True, exist_ok = True)
	package_path.write_bytes(b'delta')
	marker_path = write_pending_marker(repo_root, localappdata, '0.1.2', package_path)
	captured : dict[str, object] = {}

	def fake_popen(args, creationflags = 0):
		captured['args'] = args
		captured['creationflags'] = creationflags
		return object()

	monkeypatch.setattr(LAUNCHER_MODULE.subprocess, 'Popen', fake_popen)

	assert LAUNCHER_MODULE.launch_pending_update(repo_root, studio_root) is True
	assert marker_path.exists() is False
	assert (localappdata / 'FaceSwap Studio' / 'updates' / 'runner' / 'FaceSwapStudioUpdater.exe').exists() is True
	assert '--package' in captured['args'][-1]
	assert str(package_path) in captured['args'][-1]


def test_launch_pending_update_clears_marker_when_package_missing(monkeypatch, tmp_path : Path) -> None:
	repo_root, studio_root, localappdata = create_repo(tmp_path)
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	missing_package = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'missing.zip'
	marker_path = write_pending_marker(repo_root, localappdata, '0.1.2', missing_package)

	assert LAUNCHER_MODULE.launch_pending_update(repo_root, studio_root) is False
	assert marker_path.exists() is False


def test_launch_pending_update_clears_marker_when_root_mismatches(monkeypatch, tmp_path : Path) -> None:
	repo_root, studio_root, localappdata = create_repo(tmp_path)
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	package_path = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.2' / 'delta.zip'
	package_path.parent.mkdir(parents = True, exist_ok = True)
	package_path.write_bytes(b'delta')
	marker_path = write_pending_marker(repo_root, localappdata, '0.1.2', package_path, root_path = tmp_path / 'other-repo')

	assert LAUNCHER_MODULE.launch_pending_update(repo_root, studio_root) is False
	assert marker_path.exists() is False


def test_launch_pending_update_clears_marker_when_version_is_not_newer(monkeypatch, tmp_path : Path) -> None:
	repo_root, studio_root, localappdata = create_repo(tmp_path)
	monkeypatch.setenv('LOCALAPPDATA', str(localappdata))
	package_path = localappdata / 'FaceSwap Studio' / 'updates' / '0.1.1' / 'delta.zip'
	package_path.parent.mkdir(parents = True, exist_ok = True)
	package_path.write_bytes(b'delta')
	marker_path = write_pending_marker(repo_root, localappdata, '0.1.1', package_path)

	assert LAUNCHER_MODULE.launch_pending_update(repo_root, studio_root) is False
	assert marker_path.exists() is False
