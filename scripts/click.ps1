param(
    [int]$X,
    [int]$Y,
    [int]$Double = 0,
    [string]$ProcessName = 'jihuatai'
)

Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class UiClick {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public const uint DOWN = 0x0002, UP = 0x0004;
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Output 'no window'; exit 1 }
$h = $proc.MainWindowHandle
[UiClick]::SetForegroundWindow($h) | Out-Null
$r = New-Object UiClick+RECT
[UiClick]::GetWindowRect($h, [ref]$r) | Out-Null
$sx = $r.Left + $X
$sy = $r.Top + $Y
[UiClick]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 150
[UiClick]::mouse_event([UiClick]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
[UiClick]::mouse_event([UiClick]::UP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
if ($Double -eq 1) {
    [UiClick]::mouse_event([UiClick]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
    [UiClick]::mouse_event([UiClick]::UP, 0, 0, 0, [UIntPtr]::Zero)
}
Write-Output "clicked screen($sx,$sy) window($($r.Left),$($r.Top))"
