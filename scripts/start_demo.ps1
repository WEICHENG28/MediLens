# MediLens 一键演示：启动后端 → 启动模拟器 → 安装并打开 APP
# 用法（在 PowerShell 中，于仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File scripts\start_demo.ps1
# 可选参数：-Rebuild  重新构建 APK（修改过代码后使用）

param([switch]$Rebuild)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "dev-env.ps1")
$Apk = Join-Path $Root "app\build\app\outputs\flutter-apk\app-debug.apk"
$AppId = "cn.medilens.medilens"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# 1. 后端
Step "1/4 检查后端（http://127.0.0.1:8000）"
$backendOk = $false
try { $backendOk = (Invoke-RestMethod http://127.0.0.1:8000/api/v1/health -TimeoutSec 3).status -eq "ok" } catch {}
if (-not $backendOk) {
    Write-Host "启动后端（新窗口，演示期间请勿关闭）..."
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "Set-Location '$Root'; python scripts\run_backend.py" | Out-Null
    for ($i = 0; $i -lt 60 -and -not $backendOk; $i++) {
        Start-Sleep 2
        try { $backendOk = (Invoke-RestMethod http://127.0.0.1:8000/api/v1/health -TimeoutSec 3).status -eq "ok" } catch {}
    }
    if (-not $backendOk) { throw "后端启动失败，请查看后端窗口的错误信息" }
}
Write-Host "后端正常" -ForegroundColor Green

# 2. 模拟器
Step "2/4 检查 Android 模拟器"
$devices = (adb devices) -match "emulator-\d+\s+device"
if (-not $devices) {
    Write-Host "启动模拟器 MediLens_API35（首次约 1 分钟）..."
    # 模拟器自带的文字控制台窗口最小化，避免挡住画面
    Start-Process emulator -ArgumentList "-avd", "MediLens_API35", "-no-snapshot-save", "-no-boot-anim" -WindowStyle Minimized | Out-Null
    adb wait-for-device | Out-Null
}
for ($i = 0; $i -lt 90; $i++) {
    if ((adb shell getprop sys.boot_completed 2>$null) -match "1") { break }
    Start-Sleep 2
}
# 窗口大小按本机屏幕自动调整（手机分辨率比屏幕高，否则窗口会跑出屏幕上方）
Start-Sleep 3
& (Join-Path $PSScriptRoot "fit_emulator_window.ps1")
Write-Host "模拟器已就绪" -ForegroundColor Green

# 3. APK
Step "3/4 安装 APP"
if ($Rebuild -or -not (Test-Path $Apk)) {
    Write-Host "构建 APK（约 2–5 分钟）..."
    Push-Location (Join-Path $Root "app")
    flutter build apk --debug
    Pop-Location
}
adb install -r $Apk | Out-Null
Write-Host "已安装" -ForegroundColor Green

# 4. 打开
Step "4/4 打开 MediLens"
adb shell am force-stop $AppId | Out-Null
adb shell am start -n "$AppId/.MainActivity" | Out-Null
Write-Host "`n已在模拟器中打开 MediLens。演示路线见 docs\MVP2_测试与演示指南.md" -ForegroundColor Green
