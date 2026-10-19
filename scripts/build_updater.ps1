param(
    [switch]$Clean
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$distDir = Join-Path $repoRoot "dist"
$buildDir = Join-Path $repoRoot "build\updater"
$sourcePath = Join-Path $repoRoot "updater\FaceSwapStudioUpdater.cs"
$iconPath = Join-Path $repoRoot "facefusion.ico"
$outputPath = Join-Path $distDir "FaceSwapStudioUpdater.exe"

$cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$cscExe = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cscExe) {
    throw "Unable to find csc.exe required to build the updater."
}

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Updater source not found: $sourcePath"
}

Ensure-Directory -Path $distDir | Out-Null
Ensure-Directory -Path $buildDir | Out-Null
$brandSource = Join-Path $buildDir "InstallerBrand.generated.cs"
& (Join-Path $PSScriptRoot "export_installer_brand.ps1") -OutputPath $brandSource

if ($Clean) {
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
}

$compilerArgs = @(
    "/nologo",
    "/target:winexe",
    "/main:UpdateWindow",
    "/platform:x64",
    "/optimize+",
    "/out:$outputPath",
    "/win32icon:$iconPath",
    "/win32manifest:$(Join-Path $repoRoot 'installer\bootstrap\app.manifest')",
    "/resource:$(Join-Path $repoRoot 'installer\assets\app-mark.png'),app-mark.png",
    "/r:System.dll",
    "/r:System.Core.dll",
    "/r:System.Windows.Forms.dll",
    "/r:System.Drawing.dll",
    "/r:Accessibility.dll",
    "/r:System.IO.Compression.dll",
    "/r:System.IO.Compression.FileSystem.dll",
    "/r:System.Web.Extensions.dll",
    $sourcePath,
    (Join-Path $repoRoot "updater\StudioUpdateSurface.cs"),
    $brandSource
)

Push-Location $repoRoot
try {
    & $cscExe @compilerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Updater build failed."
    }
}
finally {
    Pop-Location
}

Copy-Item -LiteralPath $outputPath -Destination (Join-Path $repoRoot "FaceSwapStudioUpdater.exe") -Force
Write-Host "Updater rebuilt: $outputPath"
