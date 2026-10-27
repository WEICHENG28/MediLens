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
    # 在背景启动后端，输出写入记录文件；失败时直接显示错误，而不是让新窗口一闪而过、脚本空等
    $LogOut = Join-Path $Root "backend\backend.log"
    $LogErr = Join-Path $Root "backend\backend.err.log"
    $VenvPy = Join-Path $Root "backend\.venv\Scripts\python.exe"
    # 每次都确认依赖齐全（已安装时几秒完成；代码更新新增依赖时会自动补装）
    Write-Host "检查后端依赖（首次约 1–2 分钟）..."
    python (Join-Path $Root "scripts\run_backend.py") --install --check-only
    if ($LASTEXITCODE -ne 0) { Write-Host "后端依赖安装失败，请查看上方错误" -ForegroundColor Red; exit 1 }
    Write-Host "启动后端（背景运行，记录：backend\backend.log）..."
    # 直接以虚拟环境中的 uvicorn 启动：只有一个进程，结束时不会留下孤儿进程
    $proc = Start-Process $VenvPy -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000" `
        -WorkingDirectory (Join-Path $Root "backend") -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
    for ($i = 0; $i -lt 45 -and -not $backendOk; $i++) {
        Start-Sleep 2
        if ($proc.HasExited) { break }
        try { $backendOk = (Invoke-RestMethod http://127.0.0.1:8000/api/v1/health -TimeoutSec 3).status -eq "ok" } catch {}
        if (-not $backendOk -and $i -eq 10) { Write-Host "  后端仍在启动中（首次需安装依赖，可能要 1–2 分钟）..." }
    }
    if (-not $backendOk) {
        Write-Host "`n后端启动失败，最后的记录如下：" -ForegroundColor Red
        Get-Content $LogOut, $LogErr -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
        Write-Host "`n可手动执行查看完整错误：python scripts\run_backend.py" -ForegroundColor Yellow
        if (-not $proc.HasExited) { taskkill /T /F /PID $proc.Id 2>&1 | Out-Null }
        exit 1
    }
    Write-Host "后端已在背景运行。演示结束后关闭：taskkill /T /F /PID $($proc.Id)（或重启电脑）"
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
# -d 允许版本回退（模拟器上可能装过版本号较大的单架构版 APK）；仍失败则卸载重装
$out = (adb install -r -d $Apk 2>&1) -join " "
if ($out -notmatch "Success") {
    Write-Host "覆盖安装失败（$out），改为卸载后重新安装（本机记录会被清除）..." -ForegroundColor Yellow
    adb uninstall $AppId 2>&1 | Out-Null
    $out = (adb install $Apk 2>&1) -join " "
    if ($out -notmatch "Success") { Write-Host "安装失败：$out" -ForegroundColor Red; exit 1 }
}
Write-Host "已安装" -ForegroundColor Green

# 4. 打开
Step "4/4 打开 MediLens"
adb shell am force-stop $AppId | Out-Null
adb shell am start -n "$AppId/.MainActivity" | Out-Null
Write-Host "`n已在模拟器中打开 MediLens。演示路线见 docs\MVP2_测试与演示指南.md" -ForegroundColor Green
