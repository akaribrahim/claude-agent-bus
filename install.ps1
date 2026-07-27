# agent-bus installer for Windows PowerShell.
# Finds a Python and hands over to `agentbus install`, which does the real work
# so that both platforms make the same decisions in the same code. Safe to re-run.
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'bin\agentbus'

function Test-Python($exe, $prefix) {
    try {
        $args = @()
        if ($prefix) { $args += $prefix }
        $args += @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)')
        & $exe @args 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$py = $null; $pyPrefix = $null
foreach ($cand in @(@('py', '-3'), @('python', $null), @('python3', $null))) {
    $exe = $cand[0]; $prefix = $cand[1]
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        if (Test-Python $exe $prefix) { $py = $exe; $pyPrefix = $prefix; break }
    }
}

if (-not $py) {
    Write-Error "agent-bus: no Python 3.8+ found. Install it from python.org (tick 'Add to PATH') and re-run."
    exit 1
}

$callArgs = @()
if ($pyPrefix) { $callArgs += $pyPrefix }
$callArgs += @($engine, 'install') + $args
& $py @callArgs
