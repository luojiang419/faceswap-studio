param(
    [ValidateSet("lite", "full")]
    [string]$Scope = "lite"
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
Initialize-FaceFusionEnvironment -RepoRoot $repoRoot

$command = Join-Path $PSScriptRoot "facefusion.ps1"
& $command force-download --download-providers huggingface --download-scope $Scope --log-level info
exit $LASTEXITCODE
