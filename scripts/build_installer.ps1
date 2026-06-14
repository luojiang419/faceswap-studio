param(
    [switch]$SkipFlutterBuild,
    [switch]$SkipLauncherBuild,
    [switch]$SkipUpdaterBuild,
    [switch]$SkipInnoBuild
)

. (Join-Path $PSScriptRoot "common.ps1")

function Copy-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source directory not found: $Source"
    }

    Ensure-Directory -Path $Destination | Out-Null
    $robocopyArgs = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    if ($ExcludeDirectories.Count -gt 0) {
        $robocopyArgs += "/XD"
        $robocopyArgs += $ExcludeDirectories
    }
    if ($ExcludeFiles.Count -gt 0) {
        $robocopyArgs += "/XF"
        $robocopyArgs += $ExcludeFiles
    }

    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed from $Source to $Destination with exit code $LASTEXITCODE"
    }
}

function Copy-FileToDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source file not found: $Source"
    }
    Ensure-Directory -Path $Destination | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Resolve-PythonHomeFromVenv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PyvenvPath
    )

    if (-not (Test-Path -LiteralPath $PyvenvPath)) {
        throw "pyvenv.cfg not found: $PyvenvPath"
    }

    $homeLine = Get-Content -LiteralPath $PyvenvPath |
        Where-Object { $_ -match '^\s*home\s*=' } |
        Select-Object -First 1
    if (-not $homeLine) {
        throw "Unable to resolve Python home from $PyvenvPath"
    }

    $pythonHome = ($homeLine -split '=', 2)[1].Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $pythonHome "python.exe"))) {
        throw "Python home in pyvenv.cfg is not usable: $pythonHome"
    }
    return (Resolve-Path -LiteralPath $pythonHome).Path
}

$repoRoot = Get-RepoRoot
$stageRoot = Join-Path $repoRoot "build\installer\app"
$installerOutput = Join-Path $repoRoot "dist\installer"
$flutterDeployment = Join-Path $repoRoot "faceswap studio\runtime\windows_app\current"
$launcherFileName = ([string][char]0x542F) + ([string][char]0x52A8) + "FaceSwap Studio.exe"
$launcherExe = Join-Path $repoRoot $launcherFileName
$updaterExe = Join-Path $repoRoot "dist\FaceSwapStudioUpdater.exe"
$appVersion = Get-AppVersion -RepoRoot $repoRoot
$isccCandidates = @(
    "iscc",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)

if (-not $SkipFlutterBuild) {
    & (Join-Path $PSScriptRoot "build_flutter_app.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter build failed."
    }
}
elseif (-not (Test-Path -LiteralPath (Join-Path $flutterDeployment "faceswap_studio.exe"))) {
    throw "Flutter deployment was not found. Rerun without -SkipFlutterBuild."
}

if (-not $SkipLauncherBuild) {
    & (Join-Path $PSScriptRoot "build_launcher.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher build failed."
    }
}
elseif (-not (Test-Path -LiteralPath $launcherExe)) {
    throw "Launcher was not found. Rerun without -SkipLauncherBuild."
}

if (-not $SkipUpdaterBuild) {
    & (Join-Path $PSScriptRoot "build_updater.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Updater build failed."
    }
}
elseif (-not (Test-Path -LiteralPath $updaterExe)) {
    throw "Updater was not found. Rerun without -SkipUpdaterBuild."
}

$resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
$resolvedBuildRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "build\installer"))
if (-not $resolvedStage.StartsWith($resolvedBuildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected staging path: $resolvedStage"
}
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
Ensure-Directory -Path $stageRoot | Out-Null
Ensure-Directory -Path $installerOutput | Out-Null

$excludeFiles = @("*.pyc", "*.pyo", "*.log")
Copy-Directory -Source (Join-Path $repoRoot "facefusion") -Destination (Join-Path $stageRoot "facefusion") -ExcludeDirectories @("__pycache__") -ExcludeFiles $excludeFiles
Copy-Directory -Source (Join-Path $repoRoot "faceswap studio\bridge") -Destination (Join-Path $stageRoot "faceswap studio\bridge") -ExcludeDirectories @("__pycache__") -ExcludeFiles $excludeFiles
Copy-Directory -Source $flutterDeployment -Destination (Join-Path $stageRoot "faceswap studio\runtime\windows_app\current") -ExcludeFiles $excludeFiles
Copy-Directory -Source (Join-Path $repoRoot ".runtime\ffmpeg") -Destination (Join-Path $stageRoot ".runtime\ffmpeg") -ExcludeFiles $excludeFiles
Copy-Directory -Source (Join-Path $repoRoot ".venv-win") -Destination (Join-Path $stageRoot ".venv-win") -ExcludeDirectories @("__pycache__") -ExcludeFiles $excludeFiles

$pythonHome = Resolve-PythonHomeFromVenv -PyvenvPath (Join-Path $repoRoot ".venv-win\pyvenv.cfg")
Copy-Directory -Source $pythonHome -Destination (Join-Path $stageRoot ".python") -ExcludeDirectories @("__pycache__", "site-packages") -ExcludeFiles $excludeFiles

foreach ($file in @(
    "VERSION",
    "facefusion.py",
    "facefusion.ini",
    "facefusion.ico",
    "launch_faceswap_studio.py",
    "LICENSE.md",
    "README.md",
    "requirements.txt"
)) {
    Copy-FileToDirectory -Source (Join-Path $repoRoot $file) -Destination $stageRoot
}
Copy-FileToDirectory -Source $launcherExe -Destination $stageRoot
Copy-FileToDirectory -Source $updaterExe -Destination $stageRoot

Ensure-Directory -Path (Join-Path $stageRoot "scripts") | Out-Null
foreach ($file in @("common.ps1", "facefusion.ps1", "repair_runtime.ps1")) {
    Copy-FileToDirectory -Source (Join-Path $repoRoot "scripts\$file") -Destination (Join-Path $stageRoot "scripts")
}

Ensure-Directory -Path (Join-Path $stageRoot ".assets\models") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\jobs\drafted") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\jobs\queued") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\jobs\completed") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\jobs\failed") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\cache\temp") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\output\img") | Out-Null
Ensure-Directory -Path (Join-Path $stageRoot "faceswap studio\data\output\video") | Out-Null

& (Join-Path $stageRoot "scripts\repair_runtime.ps1") -Root $stageRoot
if ($LASTEXITCODE -ne 0) {
    throw "Staged runtime repair failed."
}

if ($SkipInnoBuild) {
    Write-Host "Installer staging complete: $stageRoot"
    return
}

$isccExe = $null
foreach ($candidate in $isccCandidates) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
        $isccExe = $command.Source
        break
    }
    if (Test-Path -LiteralPath $candidate) {
        $isccExe = $candidate
        break
    }
}
if (-not $isccExe) {
    throw "Inno Setup compiler was not found. Install Inno Setup 6 or add ISCC.exe to PATH."
}

$issPath = Join-Path $repoRoot "installer\FaceSwapStudio.iss"
& $isccExe "/DAppVersion=$appVersion" $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed."
}

Write-Host "Installer build complete: $installerOutput"
