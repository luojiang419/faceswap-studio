param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FaceFusionArgs
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$pythonExe = Get-VenvPython -RequireInstalled

Initialize-FaceFusionEnvironment -RepoRoot $repoRoot
Ensure-StudioDirectories -RepoRoot $repoRoot | Out-Null

$bootstrapCode = @"
import os
import runpy
import sys
try:
    import onnxruntime as ort
    if os.name == "nt" and hasattr(ort, "preload_dlls"):
        ort.preload_dlls(directory = "")
except Exception as exception:
    print(f"[WARN] onnxruntime preload_dlls failed: {exception}", file = sys.stderr)
sys.argv = ["facefusion.py"] + sys.argv[1:]
runpy.run_path("facefusion.py", run_name = "__main__")
"@

Push-Location $repoRoot
try {
    & $pythonExe -c $bootstrapCode @FaceFusionArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
