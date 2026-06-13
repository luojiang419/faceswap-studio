param(
    [switch]$InstallSdk
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$flutterProject = Join-Path $repoRoot "faceswap studio\flutter_app"
$deploymentRoot = Join-Path $repoRoot "faceswap studio\runtime\windows_app\current"

Use-FlutterMirrors

if ($InstallSdk) {
    $sdkRoot = Join-Path $repoRoot ".tools\flutter"
    Ensure-Directory -Path (Split-Path -Parent $sdkRoot) | Out-Null
    if (-not (Test-Path -LiteralPath $sdkRoot)) {
        Write-Host "Cloning Flutter SDK to $sdkRoot"
        git clone --branch stable --depth 1 https://github.com/flutter/flutter.git $sdkRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone Flutter SDK."
        }
    }
    $flutterExe = Join-Path $sdkRoot "bin\flutter.bat"
}
else {
    $flutterExe = Get-FlutterExecutable -RepoRoot $repoRoot
}

if (-not $flutterExe) {
    throw "Flutter SDK was not found. Install Flutter or rerun with -InstallSdk."
}

Push-Location $flutterProject
try {
    & $flutterExe config --enable-windows-desktop
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enable Windows desktop support in Flutter."
    }

    & $flutterExe pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed."
    }

    & $flutterExe build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows failed."
    }
}
finally {
    Pop-Location
}

$builtAppRoot = Join-Path $flutterProject "build\windows\x64\runner\Release"
Ensure-Directory -Path $deploymentRoot | Out-Null
Copy-Item -Path (Join-Path $builtAppRoot "*") -Destination $deploymentRoot -Recurse -Force
Write-Host "Flutter desktop app deployed to $deploymentRoot"
