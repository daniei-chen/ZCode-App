#!/usr/bin/env python3
"""生成 release-manifest.json：一次发布的可审计事实集合（v1.4.0 B）。

由 release.yml 调用；从环境变量读取事实，不猜测任何值：

必需：
  MANIFEST_VERSION      版本号（不含 v 前缀，如 1.0.9）
  MANIFEST_VERSION_CODE 整数 versionCode
  MANIFEST_COMMIT       触发发布的 commit SHA
  MANIFEST_APK          APK 文件路径（用于计算 sha256）
  MANIFEST_APK_SHA256   APK 的 SHA-256（十六进制大写）
可选：
  MANIFEST_FLUTTER      Flutter 版本
  MANIFEST_DART         Dart 版本
  MANIFEST_JAVA         JDK 主版本（默认 17）
  MANIFEST_SIGNER_SHA256 签名证书 SHA-256（十六进制小写）
  MANIFEST_SBOM         伴随 SBOM 文件名

用法：python3 scripts/generate-release-manifest.py > release-manifest.json
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"{name} is required to generate the release manifest")
    return value


def version_code(raw: str) -> int:
    try:
        return int(raw)
    except ValueError:
        sys.exit(f"MANIFEST_VERSION_CODE must be an integer, got {raw!r}")


def main() -> None:
    manifest = {
        "app": "ZCode App",
        "package": "com.zcode.app",
        "version": required("MANIFEST_VERSION"),
        "versionCode": version_code(required("MANIFEST_VERSION_CODE")),
        "commit": required("MANIFEST_COMMIT"),
        "abi": ["arm64-v8a"],
        "apk": {
            "fileName": os.path.basename(required("MANIFEST_APK")),
            "sha256": required("MANIFEST_APK_SHA256").upper(),
        },
        "toolchain": {
            "flutter": os.environ.get("MANIFEST_FLUTTER", "unknown"),
            "dart": os.environ.get("MANIFEST_DART", "unknown"),
            "java": os.environ.get("MANIFEST_JAVA", "17"),
        },
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    signer = os.environ.get("MANIFEST_SIGNER_SHA256", "").strip().lower()
    if signer:
        manifest["apk"]["signerSha256"] = signer
    sbom = os.environ.get("MANIFEST_SBOM", "").strip()
    if sbom:
        manifest["sbom"] = sbom
    json.dump(manifest, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
