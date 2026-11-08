# MediLens 组员一键启动（Windows）：启动模拟器 → 安装或更新 MediLens → 打开。
# 只用 Windows 自带的 PowerShell，不需要安装 Python、Flutter 或后端。
# 安全：只操作模拟器（不碰实体手机）；覆盖安装、不清除记录；安装前核对 APK 完整性；不读取或保存任何口令。
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppId = 'cn.medilens.medilens'
$Server = 'http://101.6.162.67:8000'

function Say($msg, $color = 'White') { Write-Host $msg -ForegroundColor $color }
function Fail($msg) {
    Say "`n未完成：$msg" Red
    Say '不用担心，什么都没有被删除。可以把这个窗口截图发给负责同学。' Yellow
    Read-Host '按回车关闭'
    exit 1
}

Say '== MediLens 组员一键启动 ==' Cyan

# 1. 找到 Android SDK（Android Studio 默认安装位置，或环境变量）
$sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) | Where-Object { $_ }
$Sdk = $sdkRoots | Where-Object { Test-Path (Join-Path $_ 'platform-tools\adb.exe') } | Select-Object -First 1
if (-not $Sdk) { Fail '没有找到 Android Studio 的模拟器工具。请先按《先看我》第二部分安装 Android Studio 并建立模拟器（只需做一次）。' }
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$Emu = Join-Path $Sdk 'emulator\emulator.exe'
Say "找到 Android SDK：$Sdk" Green

# 2. 核对 APK 完整（防止传输损坏或被替换）
$sums = @{}
foreach ($line in Get-Content (Join-Path $Kit 'SHA256SUMS.txt') -Encoding UTF8) {
    $p = $line -split '  ', 2
    if ($p.Count -eq 2) { $sums[$p[1].Trim()] = $p[0].Trim() }
}
function Check-Apk($name) {
    $path = Join-Path $Kit $name
    if (-not (Test-Path $path)) { Fail "没有找到 $name。请完整解压整个套件，不要只拿出这个脚本。" }
    if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -ne $sums[$name]) { Fail "$name 校验不通过（可能下载不完整），请重新获取套件。" }
    return $path
}

# 3. 启动模拟器（已经开着就直接用）
function Ready-Emulators { & $Adb devices | Select-String '^(emulator-\d+)\s+device' | ForEach-Object { $_.Matches[0].Groups[1].Value } }
& $Adb start-server *> $null
$serials = @(Ready-Emulators)
if ($serials.Count -gt 1) { Fail "开着 $($serials.Count) 个模拟器，请先关掉多余的，只留一个。" }
if ($serials.Count -eq 0) {
    if ($CheckOnly) { Say '目前没有开着的模拟器（只检查，不启动）。' Yellow; exit 0 }
    $avds = @(& $Emu -list-avds 2>$null | Where-Object { $_ -and $_ -notmatch '^INFO' })
    if ($avds.Count -eq 0) { Fail '还没有建立模拟器。请在 Android Studio 的 Device Manager 建立一台（见《先看我》）。' }
    $avd = $avds[0]
    if ($avds.Count -gt 1) {
        Say '有多台模拟器，请选择要用哪一台：'
        for ($i = 0; $i -lt $avds.Count; $i++) { Say "  $($i + 1). $($avds[$i])" }
        $n = Read-Host '输入编号后按回车'
        if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $avds.Count) { Fail '编号不正确。' }
        $avd = $avds[[int]$n - 1]
    }
    Say "正在启动模拟器 $avd（第一次约 1–2 分钟，请稍等）..."
    # 软件绘图：用电脑显卡绘图时模拟器本身容易崩溃（看起来像 APP 闪退）
    Start-Process $Emu -ArgumentList '-avd', $avd, '-gpu', 'swiftshader_indirect', '-no-boot-anim' | Out-Null
    $deadline = (Get-Date).AddMinutes(4)
    while (-not ($serials = @(Ready-Emulators)) -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
    if (-not $serials) { Fail '模拟器启动超时。请在 Android Studio 的 Device Manager 手动按 ▶ 启动，再双击本程序。' }
}
$Serial = $serials[0]
$deadline = (Get-Date).AddMinutes(4)
while (((& $Adb -s $Serial shell getprop sys.boot_completed 2>$null) -join '').Trim() -ne '1') {
    if ((Get-Date) -gt $deadline) { Fail '模拟器还没开完机，请等出现手机桌面后再双击本程序。' }
    Start-Sleep 3
}
Say "模拟器已就绪（$Serial）" Green

# 4. 按模拟器类型选择 APK：一般 Windows 电脑是 x86_64
$abis = ((& $Adb -s $Serial shell getprop ro.product.cpu.abilist) -join '').Trim()
$apkName = if ($abis -match 'x86_64') { 'MediLens-模拟器版.apk' } elseif ($abis -match 'arm64') { 'MediLens-手机版.apk' } else { $null }
if (-not $apkName) { Fail "这台模拟器的类型（$abis）不支持。请建立 x86_64 的模拟器（见《先看我》）。" }
$Apk = Check-Apk $apkName
Say "APK 完整性：通过（$apkName）" Green
if ($CheckOnly) { Say '只检查环境，没有安装或打开。' Yellow; exit 0 }

# 5. 安装（覆盖安装，保留原来的记录）
Say '正在安装或更新 MediLens（约 30 秒）...'
$result = (& $Adb -s $Serial install -r $Apk 2>&1) -join ' '
if ($result -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
    Say "`n模拟器里已有另一位组员打包的 MediLens，签名不同，无法直接更新。" Yellow
    Say '需要先卸载旧版才能安装。注意：卸载会清除旧版里的打卡与报告记录（都是测试数据）。' Yellow
    if ((Read-Host '要卸载旧版并安装新版吗？输入 y 后按回车（其他键取消）') -ne 'y') { Fail '已取消，旧版保持不变。' }
    & $Adb -s $Serial uninstall $AppId *> $null
    $result = (& $Adb -s $Serial install $Apk 2>&1) -join ' '
}
if ($result -notmatch 'Success') { Fail "安装没有成功：$($result.Substring(0, [Math]::Min(300, $result.Length)))" }
Say '安装完成' Green

# 6. 打开 APP，并检查学校服务器
& $Adb -s $Serial shell am start -n "$AppId/.MainActivity" *> $null
Say 'MediLens 已在模拟器中打开。' Green
try {
    $ok = (Invoke-RestMethod "$Server/api/v1/health" -TimeoutSec 6).status -eq 'ok'
} catch { $ok = $false }
if ($ok) { Say '学校服务器：连接正常，可以直接使用（服务器地址和访问口令都已设定好）。' Green }
else { Say '学校服务器：连不上。请确认电脑连着清华校园网（校外请先连学校 VPN）；报告识别、打卡仍可使用，解读与问答需要服务器。' Yellow }
Read-Host "`n按回车关闭这个窗口（模拟器和 MediLens 会继续开着）"
