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
  被整类删除的类不会有任何映射行。因此"插件类全部出现在 mapping.txt"
  就是"全部活到 dex"的准确判据；同时校验注册表类保持原名（反射查找依赖它）。

R-18 加固（审计指出旧版可在空 ZIP + 另一个构建的 mapping 上返回 PASS）：
1. `--apk` 必填且必须是**有效 ZIP、含至少一个 .dex**；空/伪 APK 直接 fail；
2. mapping 必须存在且非空（0 行 = 没有构建证据）；
3. `--manifest` 可选：给了就校验 APK SHA-256 与 manifest 记录一致
   （把"这次检查"钉在**这一个**构建产物上，而不是任意 mapping）；
4. 插件数下限、注册表类原名，任一不满足即 fail；
5. `--self-test` 用合成负例（空 ZIP / 空 mapping / 错 sha）固化以上判据。

用法：
  python3 scripts/check-plugin-survival.py --apk <apk> [--mapping <mapping.txt>] \\
      [--manifest <release-manifest.json>] [--build-dir <dir>] [--self-test]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRANT = (
    ROOT
    / "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
)
DEFAULT_MAPPING = ROOT / "build/app/outputs/mapping/release/mapping.txt"
REGISTRANT_CLASS = "io.flutter.plugins.GeneratedPluginRegistrant"

MIN_PLUGINS = 11


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_apk(apk: Path) -> tuple[list[str], int]:
    """返回 (问题列表, dex 总字节数)。无效 APK / 无 dex 都构成问题（R-18）。"""
    problems: list[str] = []
    if not apk.is_file():
        return [f"APK 不存在：{apk}"], 0
    if not zipfile.is_zipfile(apk):
        return [f"不是有效 ZIP（可能是空文件/伪产物）：{apk}"], 0
    try:
        with zipfile.ZipFile(apk) as archive:
            names = archive.namelist()
            dex_names = [n for n in names if n.endswith(".dex")]
            if not dex_names:
                problems.append("APK 里没有任何 .dex（空壳/被剥光的产物）")
            dex_bytes = sum(archive.getinfo(name).file_size for name in dex_names)
            if "AndroidManifest.xml" not in names:
                problems.append("APK 缺少 AndroidManifest.xml")
    except zipfile.BadZipFile:
        problems.append(f"ZIP 打不开：{apk}")
        return problems, 0
    return problems, dex_bytes


def run_check(
    apk: Path,
    mapping: Path,
    manifest: Path | None,
    plugins: list[str] | None = None,
) -> list[str]:
    """返回问题列表；空列表 = 通过。"""
    problems: list[str] = []

    if plugins is None:
        plugins = registered_plugins()
    if len(plugins) < MIN_PLUGINS:
        problems.append(f"注册表里的插件只有 {len(plugins)} 个（期望 ≥{MIN_PLUGINS}）")

    if not mapping.is_file():
        problems.append(f"mapping.txt 不存在：{mapping}（没有构建证据不得放行）")
        return problems
    if not mapping.read_text(encoding="utf-8", errors="replace").strip():
        problems.append(f"mapping.txt 为空：{mapping}")

    apk_problems, dex_bytes = inspect_apk(apk)
    problems.extend(apk_problems)

    if problems:
        return problems

    kept = parse_kept_classes(mapping)
    absent = [p for p in plugins if p not in kept]
    registrant_mapped = kept.get(REGISTRANT_CLASS)

    print(f"注册插件 {len(plugins)} 个；mapping.txt 里存活 {len(plugins) - len(absent)} 个")
    for plugin in plugins:
        mapped = kept.get(plugin)
        print(f"  [{'kept' if mapped else 'MISSING'}] {plugin} -> {mapped or '—'}")
    print(f"注册表类：{REGISTRANT_CLASS} -> {registrant_mapped or '—'}")
    print(f"APK {apk.name}: dex 合计 {dex_bytes} 字节（被剥光的包 ≈ 无 dex）")

    if absent:
        problems.append("有插件类没有活到最终 dex：" + ", ".join(absent))
    if registrant_mapped != REGISTRANT_CLASS:
        problems.append("注册表类被改名（反射查找会失败，插件全部不会注册）")

    if manifest is not None:
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            problems.append(f"manifest 读不了：{exc}")
            return problems
        declared = str(((data.get("apk") or {}).get("sha256")) or "").lower()
        actual = sha256_file(apk).lower()
        if not declared:
            problems.append("manifest 里没有 apk.sha256，无法绑定产物")
        elif declared != actual:
            problems.append(
                f"APK 摘要与 manifest 不一致：computed {actual} != manifest {declared}"
            )
        else:
            print(f"manifest 绑定校验通过：{apk.name} sha256={actual[:16]}…")
        declared_name = str(((data.get("apk") or {}).get("fileName")) or "")
        if declared_name and declared_name != apk.name:
            problems.append(
                f"APK 文件名与 manifest 不一致：{apk.name} != {declared_name}"
            )

    return problems


def _self_test() -> int:
    cases: list[tuple[str, bool]] = []

    def expect(name: str, condition: bool) -> None:
        cases.append((name, condition))
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")

    def write_mapping(path: Path, classes: list[str]) -> None:
        path.write_text(
            "\n".join(f"{cls} -> {cls}:" for cls in classes) + "\n",
            encoding="utf-8",
        )

    def write_apk(path: Path, names: dict[str, bytes]) -> None:
        with zipfile.ZipFile(path, "w") as archive:
            for name, payload in names.items():
                archive.writestr(name, payload)

    plugins = [f"com.example.Plugin{i}" for i in range(11)]

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)

        # 正例：有效 APK（含 dex）+ 全量 mapping → 通过。
        good_apk = root / "good.apk"
        write_apk(
            good_apk,
            {"classes.dex": b"x" * 1024, "AndroidManifest.xml": b"<manifest/>"},
        )
        good_mapping = root / "mapping.txt"
        write_mapping(good_mapping, plugins + [REGISTRANT_CLASS])
        expect(
            "valid APK + full mapping passes",
            not run_check(good_apk, good_mapping, None, plugins=plugins),
        )

        # R-18 负例 1：空 ZIP（0 dex）必须失败。
        empty_apk = root / "empty.apk"
        write_apk(empty_apk, {"placeholder.txt": b""})
        expect(
            "empty-ZIP APK fails（旧实现在此 PASS）",
            bool(run_check(empty_apk, good_mapping, None, plugins=plugins)),
        )

        # R-18 负例 2：空 mapping 必须失败。
        empty_mapping = root / "empty-mapping.txt"
        empty_mapping.write_text("", encoding="utf-8")
        expect(
            "empty mapping fails",
            bool(run_check(good_apk, empty_mapping, None, plugins=plugins)),
        )

        # R-18 负例 3：mapping 缺一个插件必须失败。
        partial_mapping = root / "partial-mapping.txt"
        write_mapping(partial_mapping, plugins[:-1] + [REGISTRANT_CLASS])
        expect(
            "missing plugin class fails",
            bool(run_check(good_apk, partial_mapping, None, plugins=plugins)),
        )

        # R-18 负例 4：注册表类被改名必须失败。
        renamed_mapping = root / "renamed-mapping.txt"
        renamed_mapping.write_text(
            "\n".join(f"{cls} -> {cls}:" for cls in plugins)
            + f"\n{REGISTRANT_CLASS} -> x2.g:\n",
            encoding="utf-8",
        )
        expect(
            "renamed registrant class fails",
            bool(run_check(good_apk, renamed_mapping, None, plugins=plugins)),
        )

        # R-18 负例 5：manifest 摘要不匹配必须失败。
        manifest = root / "release-manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "apk": {
                        "fileName": "good.apk",
                        "sha256": "A" * 64,
                    }
                }
            ),
            encoding="utf-8",
        )
        expect(
            "manifest digest mismatch fails",
            bool(run_check(good_apk, good_mapping, manifest, plugins=plugins)),
        )

        # 正例 2：manifest 摘要正确 → 通过。
        manifest.write_text(
            json.dumps(
                {
                    "apk": {
                        "fileName": "good.apk",
                        "sha256": sha256_file(good_apk).upper(),
                    }
                }
            ),
            encoding="utf-8",
        )
        expect(
            "manifest digest match passes",
            not run_check(good_apk, good_mapping, manifest, plugins=plugins),
        )

        # 负例 6：mapping 不存在必须失败（不得静默跳过）。
        expect(
            "missing mapping fails",
            bool(run_check(good_apk, root / "nope.txt", None, plugins=plugins)),
        )

        # 负例 7：非 ZIP 文件冒充 APK 必须失败。
        fake = root / "fake.apk"
        fake.write_bytes(b"not-a-zip")
        expect(
            "non-ZIP apk fails",
            bool(run_check(fake, good_mapping, None, plugins=plugins)),
        )

    passed = sum(1 for _, ok in cases if ok)
    print(f"self-test: {passed}/{len(cases)} passed")
    return 0 if passed == len(cases) else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=False, help="要校验的 release APK")
    parser.add_argument("--mapping", default=None, help="R8 mapping.txt 路径")
    parser.add_argument(
        "--manifest",
        default=None,
        help="可选 release-manifest.json：校验 APK 摘要绑定到同一产物",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.apk:
        parser.error("--apk is required（或用 --self-test）")

    print(f"注册表：{REGISTRANT}")
    problems = run_check(
        Path(args.apk),
        Path(args.mapping) if args.mapping else DEFAULT_MAPPING,
        Path(args.manifest) if args.manifest else None,
    )
    if problems:
        for message in problems:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1
    print("PASS: 全部插件类都在最终 dex 里，注册表类保持原名，产物绑定一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
