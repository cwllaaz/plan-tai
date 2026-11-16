param(
    [int]$ProcessId = 0,
    [string]$ProcessName = 'jihuatai',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$Double = 0,
    [int]$Right = 0
)

# Click a point given in PHYSICAL pixels relative to the top-left of the window,
# matching what scripts/screenshot.ps1 (PrintWindow) captures.
# SetProcessDPIAware is required: without it SetCursorPos coordinates are
# virtualized at 150% scaling and every click lands 1.5x too far.

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinClick {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public const uint DOWN = 0x0002, UP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
}
"@

[WinClick]::SetProcessDPIAware() | Out-Null

if ($ProcessId -gt 0) {
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
} else {
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if (-not $proc) { Write-Output 'no window'; exit 1 }

$h = $proc.MainWindowHandle
[WinClick]::ShowWindow($h, 9) | Out-Null
[WinClick]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300

$r = New-Object WinClick+RECT
[WinClick]::GetWindowRect($h, [ref]$r) | Out-Null
$sx = $r.Left + $X
$sy = $r.Top + $Y
[WinClick]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 150
if ($Right -eq 1) {
    [WinClick]::mouse_event([WinClick]::RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    [WinClick]::mouse_event([WinClick]::RIGHTUP, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [WinClick]::mouse_event([WinClick]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
    [WinClick]::mouse_event([WinClick]::UP, 0, 0, 0, [UIntPtr]::Zero)
    if ($Double -eq 1) {
        Start-Sleep -Milliseconds 90
        [WinClick]::mouse_event([WinClick]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
        [WinClick]::mouse_event([WinClick]::UP, 0, 0, 0, [UIntPtr]::Zero)
    }
}
Write-Output "clicked window($X,$Y) screen($sx,$sy) rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
