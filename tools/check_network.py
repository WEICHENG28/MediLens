"""中国大陆网络合规检查（开发工具）。

1. 扫描 APP 与后端源码中的 URL/域名，与允许清单比对；命中禁止清单则失败。
2. （可选）检查已构建的 APK：是否包含 Google Play 服务 / Firebase 类，是否引用禁止域名。

用法：python tools/check_network.py [--apk app/build/app/outputs/flutter-apk/app-debug.apk]
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 运行时允许访问的域名（含用途）
ALLOWED = {
    "10.0.2.2": "开发：模拟器访问开发机后端",
    "127.0.0.1": "开发：本机后端",
    "localhost": "开发：本机后端",
    "api.deepseek.com": "后端→DeepSeek 大模型（国内）",
    "dashscope.aliyuncs.com": "后端→通义千问（国内）",
    "maas.aliyuncs.com": "后端→阿里云百炼工作空间地址（国内）",
    "open.bigmodel.cn": "后端→智谱大模型（国内）",
}

# 禁止：境外服务 / Google / OpenAI / 境外 CDN
FORBIDDEN = [
    r"googleapis\.com", r"gstatic\.com", r"google-analytics", r"firebase", r"fcm\.", r"googletagmanager",
    r"api\.openai\.com", r"openai\.com", r"jsdelivr", r"unpkg\.com", r"cdnjs\.cloudflare", r"fonts\.google",
    r"accounts\.google", r"crashlytics",
]

SCAN_DIRS = ["app/lib", "app/android/app/src/main", "app/ios/Runner", "backend/app"]
SCAN_EXT = {".dart", ".py", ".yaml", ".xml", ".kt", ".kts", ".plist", ".swift", ".json"}
URL_RE = re.compile(r"https?://([A-Za-z0-9.\-{}]+)")

# 源码注释中出现的文档地址（非运行时请求），允许出现
DOC_HOSTS = {"api-docs.deepseek.com", "help.aliyun.com", "docs.bigmodel.cn", "d.android.com", "flutter.dev",
             "developer.android.com",
             # XML 命名空间 / plist DTD 标识符，不会产生网络请求
             "schemas.android.com", "www.apple.com"}


def scan_sources() -> tuple[dict[str, set[str]], list[str]]:
    hosts: dict[str, set[str]] = {}
    problems: list[str] = []
    for d in SCAN_DIRS:
        for f in (ROOT / d).rglob("*"):
            if f.suffix not in SCAN_EXT or not f.is_file():
                continue
            text = f.read_text(encoding="utf-8", errors="ignore")
            rel = str(f.relative_to(ROOT))
            for pat in FORBIDDEN:
                for m in re.finditer(pat, text, re.I):
                    problems.append(f"{rel}: 命中禁止项「{m.group(0)}」")
            for m in URL_RE.finditer(text):
                host = re.sub(r"^.*}", "", m.group(1)).strip(".")
                hosts.setdefault(host, set()).add(rel)
    for host, files in hosts.items():
        if host in DOC_HOSTS:
            continue
        if not any(host == a or host.endswith("." + a) or host.endswith(a) for a in ALLOWED):
            problems.append(f"未登记的域名 {host}（{', '.join(sorted(files))}）")
    return hosts, problems


# APK 中已核实「不是网络请求」的字符串（来源与说明）
APK_KNOWN = [
    (rb"type\.googleapis\.com/(google\.crypto\.tink[A-Za-z.]*)?", "protobuf 类型 URL 前缀 / Google Tink 加密库类型标识（flutter_secure_storage 用于本机加密），只是标识符，不发起网络请求"),
    (rb"https://developers\.google\.com/tink", "Tink 错误信息中的文档链接，不发起网络请求"),
    (rb"cloud\.google\.com/kms", "Tink 错误信息中的文档链接，不发起网络请求"),
    (rb"groups\.google\.com", "Guava 注释链接，不发起网络请求"),
]


def scan_apk(apk: Path) -> list[str]:
    problems = []
    debug = "debug" in apk.name
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        dex = b"".join(z.read(n) for n in names if n.endswith(".dex"))
    print(f"APK 检查：{apk.name}，dex 共 {len(dex) // 1024} KB，文件 {len(names)} 个")
    cleaned = dex
    for pat, why in APK_KNOWN:
        if re.search(pat, cleaned):
            print(f"  · 已核实非网络：{why}")
            cleaned = re.sub(pat, b"", cleaned)
    if b"com/google/android/gms" in dex or b"com/google/firebase" in dex:
        problems.append("APK 包含 Google Play 服务 / Firebase 类")
    if b"com/google/android/play/core" in dex:
        print("  · Play Core 类型引用：来自 Flutter 引擎的延迟组件（deferred components）支持，本应用未使用该功能，"
              "相关类未打包，运行时不会调用")
    if b"www.google-analytics.com" in dex:
        msg = "androidx.test:runner 的使用统计地址（集成测试依赖）"
        if debug:
            print(f"  · 调试包包含 {msg}；仅调试/测试构建存在，正式包须不含（请用 release APK 复核）")
            cleaned = cleaned.replace(b"www.google-analytics.com", b"")
        else:
            problems.append(f"正式包包含 {msg}")
    for pat in FORBIDDEN:
        if re.search(pat.encode(), cleaned, re.I):
            problems.append(f"APK 代码中出现禁止项 {pat}")
    return problems


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk")
    args = ap.parse_args()
    hosts, problems = scan_sources()
    print("源码中出现的域名：")
    for h in sorted(hosts):
        tag = "文档链接" if h in DOC_HOSTS else next((v for k, v in ALLOWED.items() if h.endswith(k)), "未登记")
        print(f"  {h:40s} {tag}")
    if args.apk:
        problems += scan_apk(ROOT / args.apk)
    if problems:
        print("\n发现问题：")
        for p in problems:
            print("  ✗", p)
        return 1
    print("\n✓ 未发现境外服务依赖或未登记域名")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
