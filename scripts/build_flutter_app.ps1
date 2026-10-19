param(
    [switch]$InstallSdk
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$flutterProject = Join-Path $repoRoot "faceswap studio\flutter_app"
$flutterBuildRoot = Join-Path $flutterProject "build\windows"
$flutterWebBuildRoot = Join-Path $flutterProject "build\web"
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
    & $flutterExe config --enable-web
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enable Web support in Flutter."
    }

    & $flutterExe pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed."
    }

    $resolvedFlutterBuildRoot = [System.IO.Path]::GetFullPath($flutterBuildRoot)
    $resolvedProjectBuildRoot = [System.IO.Path]::GetFullPath((Join-Path $flutterProject "build"))
    if (-not $resolvedFlutterBuildRoot.StartsWith($resolvedProjectBuildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected Flutter build path: $resolvedFlutterBuildRoot"
    }
    if (Test-Path -LiteralPath $flutterBuildRoot) {
        Remove-Item -LiteralPath $flutterBuildRoot -Recurse -Force
    }
    $resolvedFlutterWebBuildRoot = [System.IO.Path]::GetFullPath($flutterWebBuildRoot)
    if (-not $resolvedFlutterWebBuildRoot.StartsWith($resolvedProjectBuildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected Flutter web build path: $resolvedFlutterWebBuildRoot"
    }
    if (Test-Path -LiteralPath $flutterWebBuildRoot) {
        Remove-Item -LiteralPath $flutterWebBuildRoot -Recurse -Force
    }

    & $flutterExe build web --release --target "lib\web_main.dart" --base-href "/studio/"
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build web failed."
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
$pythonExe = Join-Path $repoRoot ".venv-win\Scripts\python.exe"
& $pythonExe (Join-Path $PSScriptRoot "deploy_flutter_app.py") --root $repoRoot --source $builtAppRoot
if ($LASTEXITCODE -ne 0) {
    throw "Frontend deployment cancelled; the previous deployment was preserved."
}
Write-Host "Flutter desktop app deployed to $deploymentRoot"
