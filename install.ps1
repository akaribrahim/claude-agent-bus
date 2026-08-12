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

# PATH is not the only place this machine has ever had a Python, and on a
# locked-down one it is not a place at all. Measured on Windows 10 on
# 2026-08-12: `py` missing, and both `python` and `python3` resolving to the
# Microsoft Store alias in WindowsApps, which answers `Python bulunamadı` and
# exits 9009. The real interpreter was an embeddable zip under the user's
# profile — unpacked by hand because org policy refused the MSI with 1625 — and
# nothing on PATH pointed at it. This script gave up there, so the documented
# Windows install was dead on that machine and every install had to be done by
# calling `bin/agentbus install` by hand.
#
# But its absolute path was already written down, twice, by whoever did that:
# in the `agentbus.cmd` shim, and in the `command` of every hook in a
# python-wired hooks.json. Those are the only pointers on such a machine, and
# each one is a path that was proven to work at the moment it was recorded. So
# look there before giving up — and still run the same version check, because a
# recorded path can be stale, a leftover from an interpreter since deleted.
function Find-RecordedPython {
    $files = @()
    $shim = Join-Path $env:USERPROFILE '.local\bin\agentbus.cmd'
    if (Test-Path -LiteralPath $shim) { $files += $shim }
    foreach ($dir in @((Join-Path $here 'hooks'),
                       (Join-Path $env:USERPROFILE '.claude\plugins\cache'))) {
        if (Test-Path -LiteralPath $dir) {
            $files += @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'hooks.json' `
                          -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.FullName })
        }
    }
    $found = @()
    foreach ($f in $files) {
        try { $text = [IO.File]::ReadAllText($f) } catch { continue }
        # JSON escapes its separators, so `C:\\Users\\…` has to become a path
        # again before anything can be matched out of it.
        $text = $text.Replace('\\', '\')
        foreach ($m in [regex]::Matches($text, '[A-Za-z]:[\\/][^"\r\n]*?python[0-9.]*\.exe')) {
            if ($found -notcontains $m.Value) { $found += $m.Value }
        }
    }
    foreach ($path in $found) {
        if ((Test-Path -LiteralPath $path) -and (Test-Python $path $null)) { return $path }
    }
    return $null
}

if (-not $py) {
    $py = Find-RecordedPython
    if ($py) {
        Write-Host "agent-bus: no Python on PATH; using the one a previous install recorded:"
        Write-Host "  $py"
    }
}

if (-not $py) {
    Write-Error ("agent-bus: no Python 3.8+ on PATH, and none recorded by an earlier " +
                 "install. Install it from python.org (tick 'Add to PATH'), or if you " +
                 "already have one somewhere, run it directly once:`n" +
                 "  <your-python.exe> `"$engine`" install`n" +
                 "After that this script can find it by itself.")
    exit 1
}

$callArgs = @()
if ($pyPrefix) { $callArgs += $pyPrefix }
$callArgs += @($engine, 'install') + $args
& $py @callArgs
