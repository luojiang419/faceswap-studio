Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-VenvPython {
    param(
        [switch]$RequireInstalled
    )

    $pythonPath = Join-Path (Get-RepoRoot) ".venv-win\Scripts\python.exe"
    if (Test-Path -LiteralPath $pythonPath) {
        return (Resolve-Path -LiteralPath $pythonPath).Path
    }
    if ($RequireInstalled) {
        throw "Virtual environment was not found at $pythonPath. Run scripts/install_facefusion.ps1 first."
    }
    return $null
}

function Get-VenvPip {
    param(
        [switch]$RequireInstalled
    )

    $pipPath = Join-Path (Get-RepoRoot) ".venv-win\Scripts\pip.exe"
    if (Test-Path -LiteralPath $pipPath) {
        return (Resolve-Path -LiteralPath $pipPath).Path
    }
    if ($RequireInstalled) {
        throw "pip was not found in the virtual environment. Run scripts/install_facefusion.ps1 first."
    }
    return $null
}

function Get-StudioPaths {
    param(
        [string]$RepoRoot = (Get-RepoRoot)
    )

    $studioRoot = Join-Path $RepoRoot "faceswap studio"
    return [pscustomobject]@{
        StudioRoot = $studioRoot
        JobsPath   = Join-Path $studioRoot "data\jobs"
        TempPath   = Join-Path $studioRoot "data\cache\temp"
        OutputPath = Join-Path $studioRoot "data\output"
    }
}

function Ensure-StudioDirectories {
    param(
        [string]$RepoRoot = (Get-RepoRoot)
    )

    $paths = Get-StudioPaths -RepoRoot $RepoRoot
    foreach ($directory in @(
        $paths.JobsPath,
        $paths.TempPath,
        (Join-Path $paths.OutputPath "img"),
        (Join-Path $paths.OutputPath "video")
    )) {
        Ensure-Directory -Path $directory | Out-Null
    }
    return $paths
}

function Initialize-FaceFusionEnvironment {
    param(
        [string]$RepoRoot = (Get-RepoRoot)
    )

    if (-not $env:FACEFUSION_HUGGINGFACE_MIRRORS) {
        $env:FACEFUSION_HUGGINGFACE_MIRRORS = "https://hf-mirror.com"
    }
    if (-not $env:FACEFUSION_GITHUB_MIRRORS) {
        $env:FACEFUSION_GITHUB_MIRRORS = "https://github.com"
    }
    $env:FACEFUSION_DISABLE_PROXY = "1"
    $env:NO_PROXY = "*"
    $env:no_proxy = "*"

    foreach ($proxyVar in @(
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy"
    )) {
        if (Test-Path "Env:$proxyVar") {
            Remove-Item "Env:$proxyVar" -ErrorAction SilentlyContinue
        }
    }

    $pathEntries = New-Object System.Collections.Generic.List[string]
    $pathEntries.Add("C:\Windows\System32")

    $venvPython = Get-VenvPython
    if ($venvPython) {
        $pathEntries.Add((Split-Path -Parent $venvPython))
    }

    $bundledFfmpegRoot = Join-Path $RepoRoot ".runtime\ffmpeg"
    if (Test-Path -LiteralPath $bundledFfmpegRoot) {
        $pathEntries.Add($bundledFfmpegRoot)
        $bundledFfmpegExe = Join-Path $bundledFfmpegRoot "ffmpeg.exe"
        if (Test-Path -LiteralPath $bundledFfmpegExe) {
            $env:FACEFUSION_FFMPEG_PATH = $bundledFfmpegExe
        }
    }
    elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
        $env:FACEFUSION_FFMPEG_PATH = (Get-Command ffmpeg).Source
    }

    if (Test-Path -LiteralPath "C:\Windows\System32\curl.exe") {
        $env:FACEFUSION_CURL_PATH = "C:\Windows\System32\curl.exe"
    }

    $existingPath = $env:PATH
    $mergedEntries = @()
    foreach ($entry in $pathEntries) {
        if ($entry -and $mergedEntries -notcontains $entry) {
            $mergedEntries += $entry
        }
    }
    if ($existingPath) {
        $mergedEntries += $existingPath
    }
    $env:PATH = [string]::Join([IO.Path]::PathSeparator, $mergedEntries)
}

function Initialize-PythonPackageMirrors {
    if (-not $env:PIP_INDEX_URL) {
        $env:PIP_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"
    }
    if (-not $env:PIP_TRUSTED_HOST) {
        $env:PIP_TRUSTED_HOST = "pypi.tuna.tsinghua.edu.cn"
    }
    $env:PIP_NO_PROXY = "*"
}

function Get-FlutterExecutable {
    param(
        [string]$RepoRoot = (Get-RepoRoot)
    )

    $candidates = @()

    if ($env:FLUTTER_ROOT) {
        $candidates += (Join-Path $env:FLUTTER_ROOT "bin\flutter.bat")
    }

    $candidates += (Join-Path $RepoRoot ".tools\flutter\bin\flutter.bat")
    $candidates += "D:\flutter\bin\flutter.bat"

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        return $flutterCommand.Source
    }
    return $null
}

function Use-FlutterMirrors {
    $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
    $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
}
