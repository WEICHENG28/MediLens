# 生成组员套件：把已构建好的 release APK、一键启动程序与说明放到一个文件夹，并写入 SHA256 校验清单。
# 先在 app 目录用 .env 的服务器地址与口令构建（口令只进 APK，不写入任何文本文件）：
#   flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64 --dart-define=API_BASE_URL=... --dart-define=API_TOKEN=...
# 用法：powershell -ExecutionPolicy Bypass -File tools\team_kit\make_team_kit.ps1 -Out D:\MediLens_组员套件 [-Extras 旧套件里中文输入法的文件夹]
param([Parameter(Mandatory = $true)][string]$Out, [string]$Extras)
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Apks = Join-Path $Root 'app\build\app\outputs\flutter-apk'
if (Test-Path $Out) { throw "$Out 已存在；请先改名备份旧套件，避免覆盖。" }
New-Item -ItemType Directory -Path $Out | Out-Null

Copy-Item (Join-Path $Apks 'app-arm64-v8a-release.apk') (Join-Path $Out 'MediLens-手机版.apk')
Copy-Item (Join-Path $Apks 'app-x86_64-release.apk') (Join-Path $Out 'MediLens-模拟器版.apk')
Copy-Item (Join-Path $PSScriptRoot 'start_medilens.ps1') $Out
Copy-Item (Join-Path $PSScriptRoot '一键启动MediLens.cmd') $Out
$guide = Get-Content (Join-Path $PSScriptRoot '【先看我】组员安装与使用.md') -Raw -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $Out '【先看我】组员安装与使用.md'), $guide.Replace('{DATE}', (Get-Date -Format 'yyyy-MM-dd')), [Text.UTF8Encoding]::new($false))
Copy-Item (Join-Path $Root 'docs\MediLens成果与技术说明（组员版）.md') $Out
if ($Extras -and (Test-Path $Extras)) { Copy-Item $Extras (Join-Path $Out (Split-Path $Extras -Leaf)) -Recurse }

$lines = foreach ($name in 'MediLens-手机版.apk', 'MediLens-模拟器版.apk') {
    "$((Get-FileHash (Join-Path $Out $name) -Algorithm SHA256).Hash.ToLower())  $name"
}
[IO.File]::WriteAllLines((Join-Path $Out 'SHA256SUMS.txt'), $lines, [Text.UTF8Encoding]::new($false))
Write-Host "组员套件已生成：$Out" -ForegroundColor Green
