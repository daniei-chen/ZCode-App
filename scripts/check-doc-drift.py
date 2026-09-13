#!/usr/bin/env python3
"""文档与代码防漂移检查（PR24 / F23 + F26）。

审计发现的漂移都是"同一个事实写了两遍"造成的：
  * `pubspec.yaml` 声明 `sdk: ^3.10.4`，`pubspec.lock` 却要求 `dart: >=3.12.0`；
  * README.en / SECURITY / ROADMAP 各自复述"当前版本 vX"，与真实包版本不一致；
  * 文档从没写过支持范围（minSdk 24 = Android 7.0），CI 却只在 API 30/34 上跑。

本脚本把"只能有一处权威来源"的规则固化下来，任何一处手改都会被 CI 拦住：
  1. Dart SDK：pubspec.yaml 的 `sdk` 下界必须等于 pubspec.lock 的 `sdks.dart` 下界；
  2. 支持范围：docs/SUPPORT.md 里写的 Android 版本与 API 级别必须与
     `android/app/build.gradle.kts` 的 `minSdk` 一致；
  3. 版本复述：README/README.en/SECURITY/ROADMAP/COMPLIANCE/SUPPORT 不允许出现
     "当前版本线 vX.Y.Z / 当前为 vX.Y.Z 线"这类硬编码当前版本的说法（应指向 Release）；
  4. 文档齐全且互相可达：SUPPORT/PRIVACY/COMPLIANCE/SECURITY 必须在 README 里有链接；
  5. 脚本行尾：`scripts/**` 与 `.github/**` 的文本文件在索引中必须是 LF
     （Windows 检出过 CRLF 会让 Linux 上的 shell/JS 直接跑不起来）。

用法：
  python3 scripts/check-doc-drift.py
  python3 scripts/check-doc-drift.py --self-test
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# pubspec 的构造：`sdk: ^3.12.0` / `sdk: '>=3.12.0 <4.0.0'` / `sdk: 3.12.0` 都要能读下界。
SDK_CONSTRAINT = re.compile(
    r"environment:\s*\n(?:.*\n)*?\s*sdk:\s*['\"]?(?:[\^~]|>=?|==)?\s*([0-9]+\.[0-9]+\.[0-9]+)"
)
LOCK_DART = re.compile(
    r"(?m)^\s*dart:\s*['\"]?(?:[\^~]|>=?|==)?\s*([0-9]+\.[0-9]+\.[0-9]+)"
)
MIN_SDK = re.compile(r"minSdk\s*=\s*([0-9]+)")
API_IN_SUPPORT = re.compile(r"API\s*([0-9]+)")
ANDROID_IN_SUPPORT = re.compile(r"Android\s*([0-9]+\.[0-9]+)")
CURRENT_VERSION_CLAIM = re.compile(r"当前(?:版本线|为)[^\n。]{0,20}?v?([0-9]+\.[0-9]+\.[0-9]+)")
VERSION_IN_PUBSPEC = re.compile(r"(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)")

# 允许复述"当前版本"的例外（发布说明天然要写版本号）。
VERSION_CLAIM_FILES = (
    "README.md",
    "README.en.md",
    "SECURITY.md",
    "docs/ROADMAP.md",
    "docs/COMPLIANCE.md",
    "docs/SUPPORT.md",
)

LINKED_FROM_README = (
    "docs/SUPPORT.md",
    "docs/PRIVACY.md",
    "docs/COMPLIANCE.md",
    "SECURITY.md",
)

# 必须是 LF 的路径前缀（scripts 与 CI 工作流：Windows CRLF 会让 Linux 侧直接失败）。
LF_REQUIRED_PREFIXES = ("scripts/", ".github/")
LF_REQUIRED_SUFFIXES = (".py", ".sh", ".mjs", ".yml", ".yaml", ".gradle", ".json")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def check_sdk_alignment(root: Path = ROOT) -> list[str]:
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    lock = (root / "pubspec.lock").read_text(encoding="utf-8")
    declared = SDK_CONSTRAINT.search(pubspec)
    locked = LOCK_DART.search(lock)
    if declared is None:
        return ["pubspec.yaml 里找不到 environment.sdk"]
    if locked is None:
        return ["pubspec.lock 里找不到 sdks.dart"]
    if declared.group(1) != locked.group(1):
        return [
            "Dart SDK 下界不一致：pubspec.yaml "
            f"{declared.group(1)} vs pubspec.lock {locked.group(1)}"
            "（改 pubspec 让它与 lock 的实际解析结果一致）"
        ]
    return []


def check_support_range(root: Path = ROOT) -> list[str]:
    gradle = (root / "android/app/build.gradle.kts").read_text(encoding="utf-8")
    support = (root / "docs/SUPPORT.md").read_text(encoding="utf-8")
    min_sdk = MIN_SDK.search(gradle)
    api = API_IN_SUPPORT.search(support)
    version = ANDROID_IN_SUPPORT.search(support)
    if min_sdk is None:
        return ["build.gradle.kts 里找不到 minSdk"]
    if api is None or version is None:
        return ["docs/SUPPORT.md 未写明支持的最低 Android 版本与 API 级别"]
    if api.group(1) != min_sdk.group(1):
        return [
            f"支持范围漂移：SUPPORT.md 写 API {api.group(1)}，构建脚本 minSdk = {min_sdk.group(1)}"
        ]
    return []


def check_version_claims(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for relative in VERSION_CLAIM_FILES:
        path = root / relative
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if CURRENT_VERSION_CLAIM.search(text):
            errors.append(
                f"{relative} 硬编码了当前版本号"
                "（应改为指向 pubspec.yaml / GitHub Release，避免版本漂移）"
            )
    return errors


def check_docs_linked(root: Path = ROOT) -> list[str]:
    readme = (root / "README.md").read_text(encoding="utf-8")
    errors: list[str] = []
    for target in LINKED_FROM_README:
        if not (root / target).is_file():
            errors.append(f"文档缺失：{target}")
            continue
        if Path(target).name not in readme and target not in readme:
            errors.append(f"README.md 没有链接到 {target}")
    return errors


def check_line_endings(root: Path = ROOT) -> list[str]:
    """索引里必须是 LF：用 git ls-files --eol 取证（离线/无 git 时跳过）。"""
    try:
        output = subprocess.run(
            ["git", "ls-files", "--eol"],
            cwd=root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    bad: list[str] = []
    for line in output.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        attributes, path = parts
        if not path.startswith(LF_REQUIRED_PREFIXES) and not path.endswith(
            LF_REQUIRED_SUFFIXES
        ):
            continue
        # `i/crlf` 表示索引里是 CRLF：Linux 侧 checkout 后脚本会带 \r。
        for token in attributes.split():
            if token.startswith("i/") and "crlf" in token:
                bad.append(path)
                break
    return [f"{path} 在索引里是 CRLF（脚本/工作流必须 LF）" for path in sorted(bad)]


def run_all(root: Path = ROOT) -> tuple[list[str], dict[str, int]]:
    checks = {
        "Dart SDK 下界一致": check_sdk_alignment(root),
        "支持范围与 minSdk 一致": check_support_range(root),
        "文档不复述当前版本": check_version_claims(root),
        "文档齐全且 README 可达": check_docs_linked(root),
        "脚本/工作流行尾为 LF": check_line_endings(root),
    }
    errors: list[str] = []
    counts: dict[str, int] = {}
    for name, found in checks.items():
        counts[name] = len(found)
        errors.extend(f"{name}: {message}" for message in found)
    return errors, counts


# ---------------------------------------------------------------- self test


def _fixture(root: Path, *, sdk: str = "3.12.0", min_sdk: str = "24") -> None:
    (root / "docs").mkdir(parents=True, exist_ok=True)
    (root / "android/app").mkdir(parents=True, exist_ok=True)
    (root / "pubspec.yaml").write_text(
        f"name: zremote\nversion: 9.9.9+99\nenvironment:\n  sdk: ^{sdk}\n",
        encoding="utf-8",
    )
    (root / "pubspec.lock").write_text(
        f'sdks:\n  dart: ">={sdk} <4.0.0"\n', encoding="utf-8"
    )
    (root / "android/app/build.gradle.kts").write_text(
        f"android {{\n  defaultConfig {{\n    minSdk = {min_sdk}\n  }}\n}}\n",
        encoding="utf-8",
    )
    (root / "docs/SUPPORT.md").write_text(
        f"# 支持\n\n| 操作系统 | Android 7.0（API {min_sdk}）及以上 |\n",
        encoding="utf-8",
    )
    (root / "README.md").write_text(
        "见 [SUPPORT](docs/SUPPORT.md)、[PRIVACY](docs/PRIVACY.md)、"
        "[COMPLIANCE](docs/COMPLIANCE.md)、[SECURITY](SECURITY.md)\n",
        encoding="utf-8",
    )
    for name in ("docs/PRIVACY.md", "docs/COMPLIANCE.md", "SECURITY.md"):
        (root / name).write_text("# doc\n", encoding="utf-8")
    (root / "docs/ROADMAP.md").write_text(
        "当前版本线：指向 GitHub Release（不复述具体版本号）。\n", encoding="utf-8"
    )


def _self_test() -> int:
    cases: list[tuple[str, bool]] = []

    def expect(name: str, condition: bool) -> None:
        cases.append((name, condition))
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        _fixture(root)
        errors, _ = run_all(root)
        expect("一致的夹具通过全部检查", not errors)
        if errors:
            print(f"        {errors[:3]}")

        # SDK 下界漂移
        broken = Path(raw) / "sdk-drift"
        _fixture(broken)
        (broken / "pubspec.lock").write_text('sdks:\n  dart: ">=3.14.0 <4.0.0"\n', encoding="utf-8")
        errors, _ = run_all(broken)
        expect("SDK 下界不一致被拦下", any("Dart SDK 下界" in e for e in errors))

        # minSdk 与文档不一致
        broken = Path(raw) / "minsdk-drift"
        _fixture(broken, min_sdk="24")
        (broken / "android/app/build.gradle.kts").write_text(
            "defaultConfig {\n  minSdk = 30\n}\n", encoding="utf-8"
        )
        errors, _ = run_all(broken)
        expect("支持范围漂移被拦下", any("支持范围漂移" in e for e in errors))

        # 文档硬编码当前版本
        broken = Path(raw) / "version-claim"
        _fixture(broken)
        (broken / "SECURITY.md").write_text(
            "# 安全策略\n\n- 仅支持最新 Release 版本（当前为 v1.0.8 线）。\n",
            encoding="utf-8",
        )
        errors, _ = run_all(broken)
        expect("硬编码当前版本号被拦下", any("硬编码了当前版本号" in e for e in errors))

        # 缺文档 / README 未链接
        broken = Path(raw) / "missing-doc"
        _fixture(broken)
        (broken / "docs/COMPLIANCE.md").unlink()
        errors, _ = run_all(broken)
        expect("缺失文档被拦下", any("文档缺失" in e for e in errors))

        broken = Path(raw) / "unlinked-doc"
        _fixture(broken)
        (broken / "README.md").write_text("nothing linked here\n", encoding="utf-8")
        errors, _ = run_all(broken)
        expect("README 未链接关键文档被拦下", any("没有链接到" in e for e in errors))

        # 版本正则不应误伤正常句子
        expect(
            "正常描述不会被误判",
            CURRENT_VERSION_CLAIM.search("当前版本线指向 GitHub Release。") is None,
        )

    failed = [name for name, passed in cases if not passed]
    print(f"self-test: {len(cases) - len(failed)}/{len(cases)} passed")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="documentation / code anti-drift checks")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    errors, counts = run_all()
    for name, count in counts.items():
        print(f"  [{'ok' if count == 0 else 'FAIL'}] {name}")
    for message in errors:
        print(f"FAIL: {message}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
