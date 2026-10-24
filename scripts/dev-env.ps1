# 开发环境变量（工具链均位于仓库内 .toolchain，不入库）
# 用法：在 PowerShell 中执行  . .\scripts\dev-env.ps1
$T = Join-Path $PSScriptRoot "..\.toolchain" | Resolve-Path
$env:JAVA_HOME = (Get-ChildItem "$T\jdk" -Directory | Select-Object -First 1).FullName
$env:ANDROID_HOME = "$T\android-sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_AVD_HOME = "$T\avd"
# Gradle 缓存放在 D 盘工具链目录，避免占用 C 盘（约 6GB）
$env:GRADLE_USER_HOME = "$T\gradle"
# 国内镜像（仅开发环境下载依赖用，与 APP 运行时网络无关）
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
$env:PATH = "$T\flutter\bin;$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\emulator;$env:PATH"
Write-Host "MediLens 开发环境已加载：flutter / java / adb / emulator 可用"
