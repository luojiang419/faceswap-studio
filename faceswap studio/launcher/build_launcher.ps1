[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$launcherSource = Join-Path $PSScriptRoot 'FaceSwapStudioLauncher.cs'
$iconPath = Join-Path $repoRoot 'facefusion.ico'
$outputExe = Join-Path $repoRoot '启动FaceSwap Studio.exe'
$cscExe = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $cscExe)) {
    throw "未找到 csc.exe: $cscExe"
}

if (-not (Test-Path -LiteralPath $launcherSource)) {
    throw "未找到启动器源码: $launcherSource"
}

if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "未找到图标文件: $iconPath"
}

& $cscExe `
    /nologo `
    /target:winexe `
    /optimize+ `
    /win32icon:$iconPath `
    /out:$outputExe `
    /reference:System.dll `
    /reference:System.Windows.Forms.dll `
    $launcherSource

if (-not (Test-Path -LiteralPath $outputExe)) {
    throw "启动器编译失败，未生成输出文件: $outputExe"
}

Write-Output $outputExe
