param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$paths = Ensure-StudioDirectories -RepoRoot $repoRoot
Initialize-FaceFusionEnvironment -RepoRoot $repoRoot

$command = Join-Path $PSScriptRoot "facefusion.ps1"
$args = @(
    "run",
    "--open-browser",
    "--ui-layouts", "default",
    "--ui-workflow", "instant_runner",
    "--jobs-path", $paths.JobsPath,
    "--temp-path", $paths.TempPath,
    "--output-path", $paths.OutputPath,
    "--execution-device-ids", "0",
    "--execution-providers", "cuda",
    "--download-providers", "huggingface",
    "--download-scope", "lite"
)

if ($ExtraArgs) {
    $args += $ExtraArgs
}

& $command @args
exit $LASTEXITCODE
