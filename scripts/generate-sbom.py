#!/usr/bin/env python3
"""从 pubspec.lock 生成最小 CycloneDX 1.5 SBOM（v1.4.0 A）。

覆盖 Dart 依赖（含 Flutter 插件，它们本身是 pub 依赖）；原生/系统级工具链
（Flutter SDK、JDK）在 release-manifest.json 中记录版本。

用法：python3 scripts/generate-sbom.py > sbom.cyclonedx.json
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - 环境错误应显式失败
    sys.exit("PyYAML is required to generate the SBOM")

ROOT = Path(__file__).resolve().parent.parent


def pubspec_version() -> str:
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*(\S+)", text)
    return match.group(1) if match else "unknown"


def main() -> None:
    lock = yaml.safe_load((ROOT / "pubspec.lock").read_text(encoding="utf-8"))
    packages = lock.get("packages", {})

    components = []
    for name in sorted(packages):
        info = packages[name] or {}
        version = str(info.get("version", "unknown"))
        source = str(info.get("source", "unknown"))
        component = {
            "type": "library",
            "name": name,
            "version": version,
            "purl": f"pkg:pub/{name}@{version}",
            "properties": [
                {"name": "pub.source", "value": source},
                {"name": "pub.dependency", "value": str(info.get("dependency", ""))},
            ],
        }
        description = info.get("description") or {}
        if isinstance(description, dict):
            url = description.get("url")
            if url:
                component["externalReferences"] = [
                    {"type": "distribution", "url": str(url)}
                ]
            sha = description.get("sha256")
            if sha:
                component["hashes"] = [
                    {"alg": "SHA-256", "content": str(sha)}
                ]
        components.append(component)

    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "application",
                "name": "ZCode App",
                "version": pubspec_version(),
            },
        },
        "components": components,
    }
    json.dump(bom, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
