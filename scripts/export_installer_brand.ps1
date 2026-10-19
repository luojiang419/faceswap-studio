param([Parameter(Mandatory = $true)][string]$OutputPath)

$repoRoot = Split-Path -Parent $PSScriptRoot
$program = [IO.File]::ReadAllText((Join-Path $repoRoot 'installer/bootstrap/Program.cs'), [Text.Encoding]::UTF8)
$layout = [IO.File]::ReadAllText((Join-Path $repoRoot 'installer/bootstrap/DiskCard.cs'), [Text.Encoding]::UTF8)
$start = $program.IndexOf('    public enum ButtonGlyph')
$end = $program.IndexOf('    public sealed class Launcher : Form', $start)
$layoutStart = $layout.IndexOf('    public sealed class PreparationTextLayout')
$layoutEnd = $layout.IndexOf('    public sealed class GlowSwitch', $layoutStart)
if ($start -lt 0 -or $end -le $start -or $layoutStart -lt 0 -or $layoutEnd -le $layoutStart) {
    throw 'Installer UI source boundaries changed; update the shared UI export before building.'
}
$controls = $program.Substring($start, $end - $start).Replace('Launcher.Round(', 'StudioUpdateSurface.Round(')
$textLayout = $layout.Substring($layoutStart, $layoutEnd - $layoutStart)
$source = "using System;`nusing System.Diagnostics;`nusing System.Drawing;`nusing System.Drawing.Drawing2D;`nusing System.Windows.Forms;`nnamespace FaceSwapBootstrap {`n" + $textLayout + $controls + "`n}`n"
$resolved = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolved)) | Out-Null
[IO.File]::WriteAllText($resolved, $source, (New-Object Text.UTF8Encoding($true)))
