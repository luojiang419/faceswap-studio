param(
    [string]$Version,
    [string]$Repository = "luojiang419/faceswap-studio",
    [switch]$Prerelease
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
if (-not $Version) {
    $Version = Get-AppVersion -RepoRoot $repoRoot
}

$releaseDir = Join-Path $repoRoot "dist\updates\$Version"
$installer = Join-Path $repoRoot "dist\installer\FaceSwapStudioSetup.exe"
$installerAsset = Join-Path $releaseDir "FaceSwapStudioSetup-$Version.exe"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) was not found."
}
if (-not (Test-Path -LiteralPath $releaseDir)) {
    throw "Update package directory not found: $releaseDir"
}
if (-not (Test-Path -LiteralPath $installer)) {
    throw "Installer not found: $installer"
}

Copy-Item -LiteralPath $installer -Destination $installerAsset -Force

$assets = @(
    $installerAsset,
    (Join-Path $releaseDir "update-manifest.json"),
    (Join-Path $releaseDir "files-$Version.json")
)
$assets += Get-ChildItem -LiteralPath $releaseDir -Filter "*.delta.zip" -File | ForEach-Object { $_.FullName }

$tag = "v$Version"
$releaseArgs = @("release", "create", $tag, "--repo", $Repository, "--title", "FaceSwap Studio $Version", "--notes", "FaceSwap Studio $Version")
if ($Prerelease) {
    $releaseArgs += "--prerelease"
}

$releaseExists = $false
try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & gh release view $tag --repo $Repository *> $null
    if ($LASTEXITCODE -eq 0) {
        $releaseExists = $true
    }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if (-not $releaseExists) {
    & gh @releaseArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed."
    }
}
else {
    Write-Host "Release already exists: $Repository $tag"
}

& gh release upload $tag @assets --repo $Repository --clobber
if ($LASTEXITCODE -ne 0) {
    throw "gh release upload failed."
}

Write-Host "Release published: $Repository $tag"
