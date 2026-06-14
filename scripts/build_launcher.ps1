param(
    [switch]$Clean
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$distDir = Join-Path $repoRoot "dist"
$buildDir = Join-Path $repoRoot "build\launcher"
$sourcePath = Join-Path $repoRoot "launcher\FaceSwapStudioLauncher.cs"
$iconPath = Join-Path $repoRoot "facefusion.ico"
$launcherFileName = ([string][char]0x542F) + ([string][char]0x52A8) + "FaceSwap Studio.exe"
$builtLauncher = Join-Path $distDir $launcherFileName
$rootLauncher = Join-Path $repoRoot $launcherFileName

$cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$cscExe = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cscExe) {
    throw "Unable to find csc.exe required to build the native launcher."
}

if (-not (Test-Path $sourcePath)) {
    throw "Launcher source not found: $sourcePath"
}

Ensure-Directory -Path $distDir | Out-Null
Ensure-Directory -Path $buildDir | Out-Null

if ($Clean) {
    Remove-Item -LiteralPath $builtLauncher -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $rootLauncher -Force -ErrorAction SilentlyContinue
}

$compilerArgs = @(
    "/nologo",
    "/target:winexe",
    "/platform:x64",
    "/optimize+",
    "/out:$builtLauncher",
    "/win32icon:$iconPath",
    "/r:System.dll",
    "/r:System.Core.dll",
    "/r:System.Windows.Forms.dll",
    "/r:System.Drawing.dll",
    $sourcePath
)

Push-Location $repoRoot
try {
    & $cscExe @compilerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher build failed."
    }
}
finally {
    Pop-Location
}

Copy-Item -LiteralPath $builtLauncher -Destination $rootLauncher -Force
Write-Host "Launcher rebuilt: $rootLauncher"
