param(
    [ValidateSet("cuda", "cpu", "default", "directml", "openvino", "qnn")]
    [string]$Backend = "cuda",
    [switch]$ForceReinstall
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$venvRoot = Join-Path $repoRoot ".venv-win"
$venvPython = Join-Path $venvRoot "Scripts\python.exe"

if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host "Creating virtual environment at $venvRoot"
    Push-Location $repoRoot
    try {
        python -m venv $venvRoot
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $venvPython)) {
    throw "Failed to create the virtual environment at $venvRoot"
}

Initialize-FaceFusionEnvironment -RepoRoot $repoRoot
Initialize-PythonPackageMirrors

Write-Host "Upgrading packaging tools"
& $venvPython -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade pip tooling."
}

$installArgs = @("install.py", "--onnxruntime", $Backend, "--skip-conda")
if ($ForceReinstall) {
    $installArgs += "--force-reinstall"
}

Write-Host "Installing FaceFusion core dependencies ($Backend)"
Push-Location $repoRoot
try {
    & $venvPython @installArgs
    if ($LASTEXITCODE -ne 0) {
        throw "FaceFusion dependency installation failed."
    }
}
finally {
    Pop-Location
}

$pipExe = Get-VenvPip -RequireInstalled

Write-Host "Installing bridge and packaging dependencies"
& $pipExe install -r (Join-Path $repoRoot "faceswap studio\bridge\requirements.txt") pyinstaller
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install bridge or packaging dependencies."
}

$validationCode = @"
import cv2
import fastapi
import gradio
import numpy
import onnx
import onnxruntime as ort
import psutil
import scipy
import tqdm
import uvicorn
if hasattr(ort, "preload_dlls"):
    ort.preload_dlls(directory = "")
print(ort.get_available_providers())
"@

& $venvPython -c $validationCode
if ($LASTEXITCODE -ne 0) {
    throw "Dependency validation failed after installation."
}

Ensure-StudioDirectories -RepoRoot $repoRoot | Out-Null

Write-Host "Installation complete."
