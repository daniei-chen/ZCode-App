#!/usr/bin/env python3
"""发布包插件存活门（真机教训的自动化版）。

背景：本地直连 gradle 出过一次"插件被 R8 整批剥掉"的事故（dex 3.0MB vs 4.1MB），
表现为 shared_preferences 缺失 → 安全设置读不到 → 锁屏死锁。

判据选择（两版都被实测修正过）：
* ❌ 在 dex 里按类名找插件 —— release 下 R8 会混淆类名，只有反射/JNI 用到的
  名字（如 `InAppWebViewFlutterPlugin`、`JniPlugin`）才保留，其余会变成
  `x2.g` 这类名字，按名查找必然误报。
* ❌ 用 `usage.txt` 的类名行判断"整类被删" —— usage.txt 的类名行表示"该类有被
  删除的成员"，被保留下来的类（只有部分成员被裁）同样会出现在里面。
* ✅ `mapping.txt`：R8 为**最终产物里存在的每个类**输出映射（改名或原样）。
  被整类删除的类不会有任何映射行。因此"11 个插件类全部出现在 mapping.txt"
  就是"全部活到 dex"的准确判据；同时校验注册表类保持原名（反射查找依赖它）。

用法：python3 scripts/check-plugin-survival.py [--apk <apk>]
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRANT = (
    ROOT
    / "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
)
MAPPING_DIR = ROOT / "build/app/outputs/mapping/release"
REGISTRANT_CLASS = "io.flutter.plugins.GeneratedPluginRegistrant"


def registered_plugins() -> list[str]:
    text = REGISTRANT.read_text(encoding="utf-8")
    found = re.findall(r"getPlugins\(\)\.add\(new ([A-Za-z0-9_.$]+)\(", text)
    return sorted(set(found))


def parse_kept_classes(path: Path) -> dict[str, str]:
    kept: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line[0].isspace():
            continue
        stripped = line.strip()
        if " -> " not in stripped:
            continue
        left, right = stripped.split(" -> ", 1)
        kept[left.strip()] = right.rstrip(":").strip()
    return kept


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", default=None, help="可选：额外报告 APK dex 体积")
    args = parser.parse_args()

    plugins = registered_plugins()
    if len(plugins) < 11:
        print(f"FAIL: 注册表里的插件只有 {len(plugins)} 个（期望 ≥11）")
        return 1

    kept = parse_kept_classes(MAPPING_DIR / "mapping.txt")
    absent = [p for p in plugins if p not in kept]

    print(f"注册插件 {len(plugins)} 个；mapping.txt 里存活 {len(plugins) - len(absent)} 个")
    for plugin in plugins:
        mapped = kept.get(plugin)
        print(f"  [{'kept' if mapped else 'MISSING'}] {plugin} -> {mapped or '—'}")

    registrant_mapped = kept.get(REGISTRANT_CLASS)
    print(f"注册表类：{REGISTRANT_CLASS} -> {registrant_mapped or '—'}")

    if args.apk:
        apk = Path(args.apk)
        with zipfile.ZipFile(apk) as archive:
            dex_bytes = sum(
                archive.getinfo(name).file_size
                for name in archive.namelist()
                if name.endswith(".dex")
            )
        print(f"APK {apk.name}: dex 合计 {dex_bytes} 字节（正常 ≈ 4,341,364；被剥时 ≈ 3.2MB）")

    if absent:
        print("FAIL: 有插件类没有活到最终 dex")
        return 1
    if registrant_mapped != REGISTRANT_CLASS:
        print("FAIL: 注册表类被改名（反射查找会失败，插件全部不会注册）")
        return 1
    print("PASS: 全部插件类都在最终 dex 里，注册表类保持原名")
    return 0


if __name__ == "__main__":
    sys.exit(main())
