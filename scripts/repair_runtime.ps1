param(
    [string]$Root
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

if (-not $Root) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
else {
    $Root = (Resolve-Path -LiteralPath $Root).Path
}

$pythonRoot = Join-Path $Root ".python"
$pythonExe = Join-Path $pythonRoot "python.exe"
$venvRoot = Join-Path $Root ".venv-win"
$pyvenvPath = Join-Path $venvRoot "pyvenv.cfg"

if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw "Bundled Python was not found: $pythonExe"
}
if (-not (Test-Path -LiteralPath $venvRoot)) {
    throw "Bundled virtual environment was not found: $venvRoot"
}

$pythonVersion = & $pythonExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
if ($LASTEXITCODE -ne 0 -or -not $pythonVersion) {
    throw "Unable to inspect bundled Python version."
}

@"
home = $pythonRoot
include-system-site-packages = false
version = $pythonVersion
executable = $pythonExe
command = $pythonExe -m venv $venvRoot
"@ | Set-Content -LiteralPath $pyvenvPath -Encoding UTF8

$directories = @(
    (Join-Path $Root ".assets\models"),
    (Join-Path $Root "faceswap studio\data\jobs\drafted"),
    (Join-Path $Root "faceswap studio\data\jobs\queued"),
    (Join-Path $Root "faceswap studio\data\jobs\completed"),
    (Join-Path $Root "faceswap studio\data\jobs\failed"),
    (Join-Path $Root "faceswap studio\data\cache\temp"),
    (Join-Path $Root "faceswap studio\data\cache\thumbnails"),
    (Join-Path $Root "faceswap studio\data\favorites"),
    (Join-Path $Root "faceswap studio\data\output\img"),
    (Join-Path $Root "faceswap studio\data\output\video"),
    (Join-Path $Root "faceswap studio\runtime")
)

foreach ($directory in $directories) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

Write-Host "Runtime repaired at $Root"
