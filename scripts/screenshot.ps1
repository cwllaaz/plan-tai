param(
    [string]$ProcessName = 'jihuatai',
    [int]$ProcessId = 0,
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\screenshot.png')
)

Add-Type -AssemblyName System.Drawing

if (-not ('Win32Cap' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class Win32Cap {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);

    public static bool Capture(IntPtr hwnd, string path, bool usePrintWindow) {
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return false;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(bmp)) {
                if (usePrintWindow) {
                    IntPtr hdc = g.GetHdc();
                    // 2 = PW_RENDERFULLCONTENT
                    bool ok = PrintWindow(hwnd, hdc, 2);
                    g.ReleaseHdc(hdc);
                    if (!ok) return false;
                } else {
                    g.CopyFromScreen(r.Left, r.Top, 0, 0, bmp.Size);
                }
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
"@
}

[Win32Cap]::SetProcessDPIAware() | Out-Null

if ($ProcessId -gt 0) {
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
} else {
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if (-not $proc) { Write-Output "no window"; exit 1 }
$handle = $proc.MainWindowHandle

$HWND_TOPMOST = [IntPtr]::new(-1)
[Win32Cap]::ShowWindow($handle, 9) | Out-Null
[Win32Cap]::BringWindowToTop($handle) | Out-Null
[Win32Cap]::SetWindowPos($handle, $HWND_TOPMOST, 80, 50, 0, 0, 0x0001 -bor 0x0040) | Out-Null
Start-Sleep -Milliseconds 2500

$ok = [Win32Cap]::Capture($handle, $Out, $true)
Write-Output "printwindow=$ok"
if (-not $ok) {
    [Win32Cap]::Capture($handle, $Out, $false) | Out-Null
    Write-Output "fell back to screen capture"
}
Write-Output "saved $Out"
