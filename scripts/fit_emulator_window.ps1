# 把 Android 模拟器窗口移到屏幕右侧并缩放到屏幕可容纳的大小（窗口跑到屏幕外时使用）
# 用法：powershell -ExecutionPolicy Bypass -File scripts\fit_emulator_window.ps1

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class EmuWin {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
Add-Type -AssemblyName System.Windows.Forms
[EmuWin]::SetProcessDPIAware() | Out-Null

$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea   # 不含任务栏的可用区域（物理像素）
$proc = Get-Process -Name "qemu-system-x86_64*" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Host "没有找到正在运行的模拟器窗口"; exit 1 }

# 手机屏幕比例 1080x2400；窗口高度取可用高度的 92%，宽度按比例计算
$h = [int]($work.Height * 0.92)
$w = [int]($h * 1080 / 2400)
$x = $work.Right - $w - 120          # 右侧留出工具栏位置
$y = $work.Top + [int](($work.Height - $h) / 2)
[EmuWin]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null       # 9 = 还原（若被最小化）
[EmuWin]::SetWindowPos($proc.MainWindowHandle, [IntPtr]::Zero, $x, $y, $w, $h, 0x0040) | Out-Null   # 0x0040 = 显示窗口
[EmuWin]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null   # 拉到最前面
$r = New-Object EmuWin+RECT
[EmuWin]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
Write-Host "模拟器窗口已调整到屏幕右侧：左上角 ($($r.Left), $($r.Top))，大小 $($r.Right - $r.Left) x $($r.Bottom - $r.Top)；屏幕可用区域 $($work.Width) x $($work.Height)"
