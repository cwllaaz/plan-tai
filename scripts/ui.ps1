param(
    [string]$ProcessName = 'jihuatai',
    [string]$Out,
    [int]$ClickX = -1,
    [int]$ClickY = -1,
    [int]$Double = 0,
    [int]$Width = 0,
    [int]$Height = 0
)

Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class UiTool {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public const uint DOWN = 0x0002, UP = 0x0004;

    public static bool Capture(IntPtr hwnd, string path) {
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return false;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                bool ok = PrintWindow(hwnd, hdc, 2);
                g.ReleaseHdc(hdc);
                if (!ok) return false;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
"@

[UiTool]::SetProcessDPIAware() | Out-Null
$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Output 'no window'; exit 1 }
$h = $proc.MainWindowHandle

# 固定窗口到 (0,0)，保证截图与点击共用一个坐标系。
$flags = 0x0001 -bor 0x0040
if ($Width -gt 0 -and $Height -gt 0) { $flags = 0x0040 }
[UiTool]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $Width, $Height, $flags) | Out-Null
[UiTool]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700

if ($Out) {
    $ok = [UiTool]::Capture($h, $Out)
    Write-Output "capture=$ok out=$Out"
}

if ($ClickX -ge 0 -and $ClickY -ge 0) {
    [UiTool]::SetCursorPos($ClickX, $ClickY) | Out-Null
    Start-Sleep -Milliseconds 200
    [UiTool]::mouse_event([UiTool]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
    [UiTool]::mouse_event([UiTool]::UP, 0, 0, 0, [UIntPtr]::Zero)
    if ($Double -eq 1) {
        Start-Sleep -Milliseconds 90
        [UiTool]::mouse_event([UiTool]::DOWN, 0, 0, 0, [UIntPtr]::Zero)
        [UiTool]::mouse_event([UiTool]::UP, 0, 0, 0, [UIntPtr]::Zero)
    }
    Write-Output "clicked ($ClickX,$ClickY) double=$Double"
}
