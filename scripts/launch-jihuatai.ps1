# JihuaTai launcher
# Picks the newest jihuatai.exe build and starts it.
# Launched by the desktop shortcut through scripts\start-jihuatai.vbs, which keeps
# PowerShell hidden and avoids Explorer's SmartScreen check for unsigned exes.
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI when there is
# no BOM, so non-ASCII comments would corrupt the parser.

$ErrorActionPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$buildExe = Join-Path $root 'build\windows\x64\runner\Release\jihuatai.exe'

# Priority 0 = fresh build output (source of truth), 1 = packaged copy under dist.
$candidates = @(
    [pscustomobject]@{ Path = $buildExe; Priority = 0 }
)

Get-ChildItem (Join-Path $root 'dist') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $candidates = $candidates + [pscustomobject]@{
        Path     = (Join-Path $_.FullName 'jihuatai.exe')
        Priority = 1
    }
}

$found = @()
foreach ($candidate in $candidates) {
    if ($candidate.Path -and (Test-Path -LiteralPath $candidate.Path)) {
        $found = $found + [pscustomobject]@{
            File     = Get-Item -LiteralPath $candidate.Path
            Priority = $candidate.Priority
        }
    }
}

if ($found.Count -eq 0) {
    Add-Type -AssemblyName System.Windows.Forms
    $msg = "jihuatai.exe not found.`n`nBuild it first:`n  cd <repo root>`n  flutter build windows --release"
    [System.Windows.Forms.MessageBox]::Show($msg, 'JihuaTai', 'OK', 'Warning') | Out-Null
    exit 1
}

# Fresh build output wins; among equals, the newest file wins.
$exe = ($found | Sort-Object Priority, @{ Expression = { $_.File.LastWriteTime }; Descending = $true } |
    Select-Object -First 1).File

# Defensive: drop the "downloaded from the internet" marker if present.
Unblock-File -LiteralPath $exe.FullName -ErrorAction SilentlyContinue

# Already running: usually just bring it to the front instead of opening a second
# window. Exception: the exe on disk was rebuilt after that instance started, so
# the running window is an older build - start the new one instead.
$running = Get-Process jihuatai -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1

if ($running -and $exe.LastWriteTime -le $running.StartTime) {
    if (-not ('LauncherWin' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LauncherWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
"@
    }
    [LauncherWin]::ShowWindow($running.MainWindowHandle, 9) | Out-Null
    [LauncherWin]::SetForegroundWindow($running.MainWindowHandle) | Out-Null
    exit 0
}

Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName
