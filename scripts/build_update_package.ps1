param(
    [string]$FromManifest,
    [string]$FromVersion,
    [string]$ToVersion,
    [switch]$SkipInstallerBuild
)

. (Join-Path $PSScriptRoot "common.ps1")

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = [Uri](([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = [Uri]([System.IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Get-FileManifest {
    param([string]$Root)

    $files = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object {
            $relative = Get-RelativePath -Root $Root -Path $_.FullName
            $relative -notmatch '(^|\\)runtime\\.*\.log$'
        } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = (Get-RelativePath -Root $Root -Path $_.FullName).Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            $files.Add([pscustomobject]@{
                path = $relative
                size = $_.Length
                sha256 = $hash
            })
        }
    return $files
}

function Read-JsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$repoRoot = Get-RepoRoot
if (-not $ToVersion) {
    $ToVersion = Get-AppVersion -RepoRoot $repoRoot
}
if (-not $FromVersion) {
    $FromVersion = "0.0.0"
}

if (-not $SkipInstallerBuild) {
    & (Join-Path $PSScriptRoot "build_installer.ps1") -SkipFlutterBuild -SkipInnoBuild
    if ($LASTEXITCODE -ne 0) {
        throw "Installer staging failed."
    }
}

$stageRoot = Join-Path $repoRoot "build\installer\app"
$releaseDir = Join-Path $repoRoot "dist\updates\$ToVersion"
$manifestPath = Join-Path $releaseDir "files-$ToVersion.json"
$deltaManifestPath = Join-Path $releaseDir "delta-$FromVersion-to-$ToVersion.json"
$deltaZipPath = Join-Path $releaseDir "FaceSwapStudio-$FromVersion-to-$ToVersion.delta.zip"
$updateManifestPath = Join-Path $releaseDir "update-manifest.json"

Ensure-Directory -Path $releaseDir | Out-Null

$currentFiles = Get-FileManifest -Root $stageRoot
$previous = Read-JsonFile -Path $FromManifest
$previousByPath = @{}
if ($previous -and $previous.files) {
    foreach ($file in $previous.files) {
        $previousByPath[$file.path] = $file
    }
}

$currentByPath = @{}
foreach ($file in $currentFiles) {
    $currentByPath[$file.path] = $file
}

$changedFiles = New-Object System.Collections.Generic.List[object]
foreach ($file in $currentFiles) {
    $previousFile = $previousByPath[$file.path]
    if (-not $previousFile -or $previousFile.sha256 -ne $file.sha256) {
        $changedFiles.Add($file)
    }
}

$deletedFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in $previousByPath.Keys) {
    if (-not $currentByPath.ContainsKey($path)) {
        $deletedFiles.Add($path)
    }
}

$fileManifest = [pscustomobject]@{
    schema_version = 1
    app_name = "FaceSwap Studio"
    version = $ToVersion
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    files = $currentFiles
}
$fileManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$deltaManifest = [pscustomobject]@{
    schema_version = 1
    app_name = "FaceSwap Studio"
    from_version = $FromVersion
    to_version = $ToVersion
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    files = $changedFiles
    deleted_files = @($deletedFiles)
}
$deltaManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $deltaManifestPath -Encoding UTF8

Remove-Item -LiteralPath $deltaZipPath -Force -ErrorAction SilentlyContinue
$tempDeltaRoot = Join-Path $releaseDir "delta-temp"
Remove-Item -LiteralPath $tempDeltaRoot -Recurse -Force -ErrorAction SilentlyContinue
Ensure-Directory -Path (Join-Path $tempDeltaRoot "files") | Out-Null
Copy-Item -LiteralPath $deltaManifestPath -Destination (Join-Path $tempDeltaRoot "delta-manifest.json") -Force

foreach ($file in $changedFiles) {
    $source = Join-Path $stageRoot ($file.path.Replace('/', '\'))
    $target = Join-Path (Join-Path $tempDeltaRoot "files") ($file.path.Replace('/', '\'))
    Ensure-Directory -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}

[System.IO.Compression.ZipFile]::CreateFromDirectory($tempDeltaRoot, $deltaZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath $tempDeltaRoot -Recurse -Force

$installerAsset = "FaceSwapStudioSetup-$ToVersion.exe"
$installerSource = Join-Path $repoRoot "dist\installer\FaceSwapStudioSetup.exe"
$installerHash = $null
$installerSize = 0
if (Test-Path -LiteralPath $installerSource) {
    $installerHash = (Get-FileHash -LiteralPath $installerSource -Algorithm SHA256).Hash
    $installerSize = (Get-Item -LiteralPath $installerSource).Length
}

$deltaHash = (Get-FileHash -LiteralPath $deltaZipPath -Algorithm SHA256).Hash
$deltaSize = (Get-Item -LiteralPath $deltaZipPath).Length
$fileManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$fileManifestSize = (Get-Item -LiteralPath $manifestPath).Length

$updateManifest = [pscustomobject]@{
    schema_version = 1
    app_name = "FaceSwap Studio"
    version = $ToVersion
    minimum_delta_version = $FromVersion
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    full_package = [pscustomobject]@{
        asset_name = $installerAsset
        sha256 = $installerHash
        size = $installerSize
    }
    file_manifest = [pscustomobject]@{
        asset_name = "files-$ToVersion.json"
        sha256 = $fileManifestHash
        size = $fileManifestSize
    }
    delta_packages = @(
        [pscustomobject]@{
            from_version = $FromVersion
            to_version = $ToVersion
            asset_name = [System.IO.Path]::GetFileName($deltaZipPath)
            sha256 = $deltaHash
            size = $deltaSize
            changed_count = $changedFiles.Count
            deleted_count = $deletedFiles.Count
        }
    )
    notes = "FaceSwap Studio $ToVersion"
}
$updateManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $updateManifestPath -Encoding UTF8

Write-Host "Update package complete: $releaseDir"
Write-Host "Delta: $deltaZipPath"
Write-Host "Manifest: $updateManifestPath"
