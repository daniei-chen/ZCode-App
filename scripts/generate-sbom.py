#!/usr/bin/env python3
"""生成 ZCode App 的 CycloneDX 1.5 SBOM（v1.1.0 / PR19，F22）。

旧版只覆盖 pubspec.lock，输出 119 个 pub PURL、没有依赖图，回答不了"APK 里
有什么、什么许可、由什么构建"。这里合并三层清单：

  1. **Dart/pub**：pubspec.lock 的锁定版本 + pub 缓存里各包 pubspec.yaml 的
     dependencies，构成真实依赖边（根 pubspec.yaml 提供直接依赖）；
  2. **Android release 运行时**：Gradle 解析结果（`scripts/sbom/gradle-inventory.gradle`
     导出的 artifacts/edges），许可从 Gradle 缓存里的 POM `<licenses>` 读取；
  3. **APK 原生库**：`lib/<abi>/*.so` 逐个记录 SHA-256/大小/ABI，让"APK 里到底
     打包了什么二进制"可以逐条核对。

工具链（Python/PyYAML/Gradle/JDK/Flutter/Dart）写进 `metadata.tools`，
回答"由什么构建"；所有清单来源写在组件的 `zcode.inventory` 属性里。

用法：
  python3 scripts/generate-sbom.py --out sbom.json \
      --gradle-inventory build/sbom/gradle-inventory.json \
      --apk build/app/outputs/flutter-apk/ZCode-v1.1.0.apk \
      --flutter-version 3.47.3 --dart-version 3.13.3 --engine-revision <sha>
  python3 scripts/generate-sbom.py --self-test      # 离线正/负例
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - 环境错误应显式失败
    sys.exit("PyYAML is required to generate the SBOM (see scripts/requirements-sbom.txt)")

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_VERSION = "1.5"

# POM 来自依赖仓库/本地缓存，不是本仓库可信输入：解析前先限定大小，
# 并显式拒绝 DTD/内部实体声明（实体扩展会把小文件放大成内存炸弹）。
MAX_POM_BYTES = 512 * 1024
FORBIDDEN_XML_MARKERS = ("<!doctype", "<!entity")

# 保守的 SPDX 识别表：每条规则要求若干片段同时命中（可排除片段全部不出现才
# 算命中），只在正文明确匹配时才给 id，否则一律 NOASSERTION。
# 注意 Dart 官方包的 BSD-3 文本第三条以 "Neither the name of ..." 开头，没有
# "3." 编号，所以不能靠编号判断。
SPDX_RULES: list[tuple[str, list[str], list[str]]] = [
    (
        "Apache-2.0",
        [r"apache\s+(?:software\s+)?license[,:]?\s*version\s*2\.0|apache\.org/licenses/LICENSE-2\.0"],
        [],
    ),
    ("MIT", [r"permission is hereby granted, free of charge"], []),
    (
        "BSD-3-Clause",
        [r"redistribution and use in source and binary forms", r"neither the name of"],
        [],
    ),
    (
        "BSD-2-Clause",
        [r"redistribution and use in source and binary forms", r"this software is provided"],
        [r"neither the name of"],
    ),
    ("ISC", [r"permission to use, copy, modify, and/or distribute this software"], []),
    ("MPL-2.0", [r"mozilla public license version 2\.0"], []),
    ("LGPL-3.0-only", [r"gnu lesser general public license\s*version 3"], []),
    ("GPL-3.0-only", [r"gnu general public license\s*version 3"], [r"lesser"]),
    ("Unlicense", [r"free and unencumbered software released into the public domain"], []),
]

LICENSE_FILE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING")


# ---------------------------------------------------------------- helpers


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def detect_spdx(text: str) -> str | None:
    """从许可证正文猜 SPDX id；匹配不到返回 None（调用方写 NOASSERTION）。"""
    if not text:
        return None
    for spdx, required, forbidden in SPDX_RULES:
        if any(re.search(pattern, text, re.I | re.S) is None for pattern in required):
            continue
        if any(re.search(pattern, text, re.I | re.S) for pattern in forbidden):
            continue
        return spdx
    return None


def license_field(spdx: str | None) -> list[dict]:
    if spdx:
        return [{"license": {"id": spdx}}]
    return [{"license": {"name": "NOASSERTION"}}]


def read_package_license(package_dir: Path) -> tuple[str | None, str | None]:
    """返回 (SPDX id 或 None, 许可证文件名 或 None)。"""
    for name in LICENSE_FILE_NAMES:
        candidate = package_dir / name
        if candidate.is_file():
            try:
                text = candidate.read_text(encoding="utf-8", errors="replace")[:20000]
            except OSError:
                continue
            return detect_spdx(text), name
    return None, None


def parse_pom_xml(path: Path) -> ET.Element | None:
    """安全解析 POM：限长 + 拒绝 DTD/实体声明，失败返回 None。"""
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if not raw or len(raw) > MAX_POM_BYTES:
        return None
    text = raw.decode("utf-8", errors="replace")
    lowered = text[:8192].lower()
    if any(marker in lowered for marker in FORBIDDEN_XML_MARKERS):
        return None
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def maven_cache_dirs(cache: Path) -> dict[str, Path]:
    """Gradle 缓存里 g:a:v → 含 POM 的目录（可能有多份 hash 目录）。"""
    index: dict[str, Path] = {}
    base = cache / "modules-2" / "files-2.1"
    if not base.is_dir():
        return index
    for group_dir in base.iterdir():
        if not group_dir.is_dir():
            continue
        for name_dir in group_dir.iterdir():
            if not name_dir.is_dir():
                continue
            for version_dir in name_dir.iterdir():
                if not version_dir.is_dir():
                    continue
                key = f"{group_dir.name}:{name_dir.name}:{version_dir.name}"
                index[key] = version_dir
    return index


def pom_license(version_dir: Path, name: str, version: str) -> tuple[str | None, str | None]:
    """从 POM 里取 <licenses>；返回 (SPDX id 或原始许可名 或 None, 来源)。"""
    pom = next(iter(sorted(version_dir.rglob(f"{name}-{version}.pom"))), None)
    if pom is None:
        pom = next(iter(sorted(version_dir.rglob("*.pom"))), None)
    if pom is None:
        return None, None
    root = parse_pom_xml(pom)
    if root is None:
        return None, f"unparsable:{pom.name}"
    namespace = root.tag.split("}")[0] + "}" if root.tag.startswith("{") else ""
    for license_node in root.iter(f"{namespace}license"):
        name_node = license_node.find(f"{namespace}name")
        url_node = license_node.find(f"{namespace}url")
        raw = (name_node.text or "").strip() if name_node is not None else ""
        url = (url_node.text or "").strip() if url_node is not None else ""
        spdx = detect_spdx(f"{raw} {url}")
        if spdx:
            return spdx, "pom"
        if raw:
            return raw, "pom"  # 原始许可名（非 SPDX）也如实记录
    return None, pom.name


def purl(kind: str, name: str, version: str, qualifiers: str | None = None) -> str:
    base = f"pkg:{kind}/{name}@{version}"
    return f"{base}?{qualifiers}" if qualifiers else base


# ---------------------------------------------------------------- layer 1: Dart


def load_yaml(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise SystemExit(f"cannot read {path}: {exc}")
    return data if isinstance(data, dict) else {}


def default_pub_cache() -> Path | None:
    env = os.environ.get("PUB_CACHE")
    if env:
        return Path(env)
    candidates = [
        Path.home() / ".pub-cache",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Pub" / "Cache",
    ]
    return next((c for c in candidates if c.is_dir()), None)


def find_package_dir(cache: Path | None, name: str, version: str) -> Path | None:
    if cache is None or not cache.is_dir():
        return None
    for hosted in sorted(cache.glob("hosted/*")):
        candidate = hosted / f"{name}-{version}"
        if candidate.is_dir():
            return candidate
    return None


def dart_layer(lock_path: Path, pubspec_path: Path, cache: Path | None) -> tuple[list[dict], dict[str, list[str]]]:
    lock = load_yaml(lock_path)
    packages = lock.get("packages") or {}
    root_pubspec = load_yaml(pubspec_path) if pubspec_path.is_file() else {}
    direct_main = set((root_pubspec.get("dependencies") or {}).keys())
    direct_dev = set((root_pubspec.get("dev_dependencies") or {}).keys())

    components: list[dict] = []
    edges: dict[str, list[str]] = {}
    for name in sorted(packages):
        info = packages[name] or {}
        version = str(info.get("version", "unknown"))
        scope_hint = str(info.get("dependency", ""))
        component_ref = purl("pub", name, version)
        component: dict = {
            "type": "library",
            "bom-ref": component_ref,
            "name": name,
            "version": version,
            "purl": component_ref,
            # dev 依赖不进 APK：标成 excluded，避免"APK 里有什么"被误读。
            "scope": "excluded" if "dev" in scope_hint else "required",
            "properties": [
                {"name": "zcode.inventory", "value": "pubspec.lock"},
                {"name": "pub.dependency", "value": scope_hint},
                {"name": "pub.source", "value": str(info.get("source", "unknown"))},
            ],
        }
        description = info.get("description") or {}
        if isinstance(description, dict):
            url = description.get("url")
            if url:
                component["externalReferences"] = [{"type": "distribution", "url": str(url)}]
            sha = description.get("sha256")
            if sha:
                component["hashes"] = [{"alg": "SHA-256", "content": str(sha)}]

        package_dir = find_package_dir(cache, name, version)
        if package_dir is not None:
            spdx, file_name = read_package_license(package_dir)
            component["licenses"] = license_field(spdx)
            component["properties"].append(
                {
                    "name": "zcode.license.source",
                    "value": f"pub-cache:{file_name}" if file_name else "pub-cache:no-license-file",
                }
            )
        else:
            component["licenses"] = license_field(None)
            component["properties"].append(
                {"name": "zcode.license.source", "value": "pub-cache-missing"}
            )
        components.append(component)

        # 依赖边：包自己的 pubspec.yaml 里声明的 dependencies（dev 不算）。
        if package_dir is not None:
            child = package_dir / "pubspec.yaml"
            if child.is_file():
                declared = load_yaml(child).get("dependencies") or {}
                targets = [
                    purl("pub", dep, str(((packages.get(dep) or {}).get("version", ""))))
                    for dep in declared
                    if dep in packages and (packages.get(dep) or {}).get("version")
                ]
                if targets:
                    edges[component_ref] = sorted(set(targets))

    root_children = [
        purl("pub", name, str((packages[name] or {}).get("version", "")))
        for name in sorted(direct_main | direct_dev)
        if name in packages and (packages[name] or {}).get("version")
    ]
    edges["\0ROOT"] = sorted(set(root_children))
    return components, edges


# ---------------------------------------------------------------- layer 2: Gradle


def gradle_layer(
    inventory_path: Path, gradle_cache: Path, app_version: str
) -> tuple[list[dict], dict[str, list[str]], dict]:
    try:
        data = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SystemExit(f"cannot read gradle inventory {inventory_path}: {exc}")

    cache_index = maven_cache_dirs(gradle_cache)
    components: list[dict] = []
    refs: dict[str, str] = {}

    def ref_of(group: str, name: str, version: str) -> str:
        key = f"{group}:{name}:{version}"
        if key not in refs:
            refs[key] = purl("maven", f"{group}/{name}", version)
        return refs[key]

    for artifact in data.get("artifacts") or []:
        group = str(artifact.get("group") or "")
        name = str(artifact.get("name") or "")
        version = str(artifact.get("version") or "")
        if not group or not name or not version:
            continue
        component_ref = ref_of(group, name, version)
        component: dict = {
            "type": "library",
            "bom-ref": component_ref,
            "group": group,
            "name": name,
            "version": version,
            "purl": component_ref,
            "scope": "required",
            "properties": [
                {"name": "zcode.inventory", "value": f"gradle:{data.get('configuration', 'runtime')}"},
            ],
        }
        if artifact.get("sha256"):
            component["hashes"] = [{"alg": "SHA-256", "content": str(artifact["sha256"])}]

        version_dir = cache_index.get(f"{group}:{name}:{version}")
        spdx, source = (None, None)
        if version_dir is not None:
            spdx, source = pom_license(version_dir, name, version)
        if spdx and re.fullmatch(r"[A-Za-z0-9.+-]+", spdx):
            component["licenses"] = [{"license": {"id": spdx}}]
        elif spdx:
            component["licenses"] = [{"license": {"name": spdx}}]
        else:
            component["licenses"] = license_field(None)
        component["properties"].append(
            {"name": "zcode.license.source", "value": f"pom:{source}" if source else "pom-unavailable"}
        )
        components.append(component)

    edges: dict[str, list[str]] = {}
    for edge in data.get("edges") or []:
        source = edge.get("from") or {}
        target = edge.get("to") or {}
        if target.get("root"):
            continue
        if source.get("root"):
            source_ref = "\0ROOT"
        elif source.get("group") and source.get("name") and source.get("version"):
            source_ref = ref_of(str(source["group"]), str(source["name"]), str(source["version"]))
        else:
            continue
        if not (target.get("group") and target.get("name") and target.get("version")):
            continue
        target_ref = ref_of(str(target["group"]), str(target["name"]), str(target["version"]))
        edges.setdefault(source_ref, []).append(target_ref)

    return components, edges, {
        "gradle": data.get("gradle"),
        "java": data.get("java"),
        "configuration": data.get("configuration"),
    }


# ---------------------------------------------------------------- layer 3: APK native


def native_layer(apk_path: Path, app_version: str, engine_revision: str | None, app_license: str | None) -> list[dict]:
    components: list[dict] = []
    with zipfile.ZipFile(apk_path) as archive:
        for entry in sorted(archive.namelist()):
            if not entry.startswith("lib/") or not entry.endswith(".so"):
                continue
            parts = entry.split("/")
            if len(parts) < 3:
                continue
            abi = parts[1]
            file_name = parts[-1]
            digest = hashlib.sha256()
            size = 0
            with archive.open(entry) as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
                    size += len(chunk)
            if file_name == "libflutter.so":
                spdx, origin, version = "BSD-3-Clause", "flutter-engine", engine_revision or app_version
            elif file_name == "libapp.so":
                spdx, origin, version = app_license, "repository", app_version
            else:
                spdx, origin, version = None, "unknown", app_version
            component_ref = purl("generic", file_name, version, f"abi={abi}")
            components.append(
                {
                    "type": "library",
                    "bom-ref": component_ref,
                    "name": file_name,
                    "version": version,
                    "purl": component_ref,
                    "scope": "required",
                    "hashes": [{"alg": "SHA-256", "content": digest.hexdigest()}],
                    "licenses": license_field(spdx),
                    "properties": [
                        {"name": "zcode.inventory", "value": "apk:lib"},
                        {"name": "zcode.native.path", "value": entry},
                        {"name": "zcode.native.abi", "value": abi},
                        {"name": "zcode.native.size", "value": str(size)},
                        {"name": "zcode.native.origin", "value": origin},
                    ],
                }
            )
    return components


# ---------------------------------------------------------------- assemble


def build_bom(
    version: str,
    dart: tuple[list[dict], dict[str, list[str]]],
    gradle: tuple[list[dict], dict[str, list[str]], dict],
    native: list[dict],
    apk_path: Path | None,
    tool_versions: dict[str, str | None],
    partial: bool = False,
) -> dict:
    dart_components, dart_edges = dart
    gradle_components, gradle_edges, gradle_meta = gradle

    root_ref = purl("generic", "zcode-app", version, "packaging=apk")
    components = dart_components + gradle_components + native

    seen: dict[str, int] = {}
    for component in components:
        seen[component["bom-ref"]] = seen.get(component["bom-ref"], 0) + 1
    duplicates = sorted(ref for ref, count in seen.items() if count > 1)
    if duplicates:
        raise SystemExit(f"duplicate bom-ref in SBOM: {duplicates[:5]}")

    known = {component["bom-ref"] for component in components}
    dependency_map: dict[str, set[str]] = {component["bom-ref"]: set() for component in components}
    for edges in (dart_edges, gradle_edges):
        for source_ref, targets in edges.items():
            if source_ref == "\0ROOT" or source_ref not in known:
                continue
            for target in targets:
                if target in known:
                    dependency_map[source_ref].add(target)

    root_children: set[str] = set()
    for edges in (dart_edges, gradle_edges):
        for target in edges.get("\0ROOT", []):
            if target in known:
                root_children.add(target)

    dependencies = [{"ref": root_ref, "dependsOn": sorted(root_children)}]
    dependencies.extend(
        {"ref": ref, "dependsOn": sorted(targets)}
        for ref, targets in sorted(dependency_map.items())
    )

    noassertion = sum(
        1
        for component in components
        if any(
            (entry.get("license") or {}).get("name") == "NOASSERTION"
            for entry in component.get("licenses") or []
        )
    )

    root_component: dict = {
        "type": "application",
        "bom-ref": root_ref,
        "name": "ZCode App",
        "version": version,
        "purl": root_ref,
        "licenses": license_field("MIT"),
    }
    if apk_path is not None and apk_path.is_file():
        root_component["hashes"] = [{"alg": "SHA-256", "content": sha256_file(apk_path)}]
        root_component["externalReferences"] = [
            {"type": "distribution", "url": f"https://github.com/daniei-chen/ZCode-App/releases/tag/v{version}"}
        ]

    tools = [
        {
            "type": "application",
            "name": name,
            "version": value,
            "properties": [{"name": "zcode.tool.role", "value": role}],
        }
        for name, value, role in (
            ("python", sys.version.split()[0], "sbom-generator-runtime"),
            ("PyYAML", getattr(yaml, "__version__", "unknown"), "sbom-generator-dependency"),
            ("gradle", gradle_meta.get("gradle"), "android-build"),
            ("jdk", gradle_meta.get("java"), "android-build"),
            ("flutter", tool_versions.get("flutter"), "app-build"),
            ("dart", tool_versions.get("dart"), "app-build"),
            ("flutter-engine", tool_versions.get("engine"), "app-runtime"),
            ("android-gradle-plugin", tool_versions.get("agp"), "android-build"),
        )
        if value
    ]

    return {
        "bomFormat": "CycloneDX",
        "specVersion": SCHEMA_VERSION,
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": root_component,
            "tools": {"components": tools},
            "properties": [
                {"name": "zcode.sbom.generator", "value": "scripts/generate-sbom.py"},
                {"name": "zcode.inventory.dart", "value": str(len(dart_components))},
                {"name": "zcode.inventory.maven", "value": str(len(gradle_components))},
                {"name": "zcode.inventory.native", "value": str(len(native))},
                {"name": "zcode.license.noassertion", "value": str(noassertion)},
                {"name": "zcode.package", "value": "com.zcode.app"},
                {"name": "zcode.sbom.partial", "value": "true" if partial else "false"},
            ],
        },
        "components": components,
        "dependencies": dependencies,
    }


# ---------------------------------------------------------------- self test


def _fixture(root: Path) -> dict[str, Path]:
    """构造离线夹具：pubspec.yaml/lock + pub 缓存 + Gradle 清单/缓存 + 假 APK。"""
    (root / "pubspec.yaml").write_text(
        "name: zremote\nversion: 9.9.9+99\ndependencies:\n  alpha:\n  beta:\n"
        "dev_dependencies:\n  gamma:\n",
        encoding="utf-8",
    )
    (root / "pubspec.lock").write_text(
        "packages:\n"
        "  alpha:\n    dependency: \"direct main\"\n    source: hosted\n    version: \"1.0.0\"\n"
        "  beta:\n    dependency: \"transitive\"\n    source: hosted\n    version: \"2.0.0\"\n"
        "  gamma:\n    dependency: \"direct dev\"\n    source: hosted\n    version: \"3.0.0\"\n"
        "sdks:\n  dart: \">=3.0.0\"\n",
        encoding="utf-8",
    )
    cache = root / "pub-cache" / "hosted" / "pub.dev"
    for name, version, body, license_text in (
        ("alpha", "1.0.0", "dependencies:\n  beta:\n", "MIT License\n\nPermission is hereby granted, free of charge"),
        ("beta", "2.0.0", "dependencies: {}\n", "Apache License, Version 2.0"),
        ("gamma", "3.0.0", "dependencies: {}\n", "unknown proprietary text"),
    ):
        package_dir = cache / f"{name}-{version}"
        package_dir.mkdir(parents=True)
        (package_dir / "pubspec.yaml").write_text(f"name: {name}\n{body}", encoding="utf-8")
        (package_dir / "LICENSE").write_text(license_text, encoding="utf-8")

    inventory = {
        "gradle": "8.14",
        "java": "17.0.20.1",
        "configuration": "releaseRuntimeClasspath",
        "artifacts": [
            {
                "group": "androidx.core",
                "name": "core",
                "version": "1.13.0",
                "file": "core-1.13.0.aar",
                "sha256": "a" * 64,
                "size": 1024,
            },
            {
                "group": "org.example",
                "name": "mystery",
                "version": "0.1.0",
                "file": "mystery-0.1.0.jar",
                "sha256": "b" * 64,
                "size": 2048,
            },
        ],
        "edges": [
            {"from": {"root": True}, "to": {"group": "androidx.core", "name": "core", "version": "1.13.0"}},
            {
                "from": {"group": "androidx.core", "name": "core", "version": "1.13.0"},
                "to": {"group": "org.example", "name": "mystery", "version": "0.1.0"},
            },
        ],
        "unresolvedRequests": [],
        "nonModuleComponents": [],
    }
    inventory_path = root / "gradle-inventory.json"
    inventory_path.write_text(json.dumps(inventory), encoding="utf-8")

    gradle_cache = root / "gradle-cache" / "modules-2" / "files-2.1" / "androidx.core" / "core" / "1.13.0" / "hash"
    gradle_cache.mkdir(parents=True)
    (gradle_cache / "core-1.13.0.pom").write_text(
        "<project><licenses><license>"
        "<name>The Apache Software License, Version 2.0</name>"
        "<url>http://www.apache.org/licenses/LICENSE-2.0.txt</url>"
        "</license></licenses></project>",
        encoding="utf-8",
    )

    apk_path = root / "app.apk"
    with zipfile.ZipFile(apk_path, "w") as archive:
        archive.writestr("lib/arm64-v8a/libapp.so", b"app-native")
        archive.writestr("lib/arm64-v8a/libflutter.so", b"engine-native")
        archive.writestr("assets/flutter_assets/AssetManifest.json", b"{}")
    return {
        "pubspec": root / "pubspec.yaml",
        "lock": root / "pubspec.lock",
        "pub_cache": root / "pub-cache",
        "inventory": inventory_path,
        "gradle_cache": root / "gradle-cache",
        "apk": apk_path,
    }


def _invariants(bom: dict, require_native: bool = True) -> list[str]:
    errors: list[str] = []
    if bom.get("bomFormat") != "CycloneDX" or bom.get("specVersion") != SCHEMA_VERSION:
        errors.append("bomFormat/specVersion 不正确")
    root = (bom.get("metadata") or {}).get("component") or {}
    if not root.get("bom-ref") or not root.get("version"):
        errors.append("metadata.component 缺 bom-ref/version")

    components = bom.get("components") or []
    refs = [c.get("bom-ref") for c in components]
    if len(refs) != len(set(refs)):
        errors.append("bom-ref 有重复")
    known = set(refs) | {root.get("bom-ref")}
    for component in components:
        if not component.get("licenses"):
            errors.append(f"{component.get('name')} 缺 licenses")
            continue
        for entry in component.get("licenses") or []:
            license_body = entry.get("license") or {}
            if not (license_body.get("id") or license_body.get("name")):
                errors.append(f"{component.get('name')} 的 license 条目为空")
    for entry in bom.get("dependencies") or []:
        if entry.get("ref") not in known:
            errors.append(f"dependencies 引用了未知 bom-ref: {entry.get('ref')}")
        for target in entry.get("dependsOn") or []:
            if target not in known:
                errors.append(f"dependsOn 引用了未知 bom-ref: {target}")

    native = [
        c
        for c in components
        if any(p.get("value") == "apk:lib" for p in c.get("properties") or [])
    ]
    if not native and require_native:
        errors.append("没有任何 APK 原生库组件")
    for component in native:
        if not component.get("hashes"):
            errors.append(f"原生库 {component.get('name')} 缺哈希")
    return errors


def run_self_test() -> int:
    cases: list[tuple[str, bool]] = []

    def expect(name: str, condition: bool) -> None:
        cases.append((name, condition))
        print(f"  [{'ok' if condition else 'FAIL'}] {name}")

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        fixture = _fixture(root)
        dart = dart_layer(fixture["lock"], fixture["pubspec"], fixture["pub_cache"])
        gradle = gradle_layer(fixture["inventory"], fixture["gradle_cache"], "9.9.9")
        native = native_layer(fixture["apk"], "9.9.9", "engine-sha", "MIT")
        tool_versions = {"flutter": "3.47.3", "dart": "3.13.3", "engine": "engine-sha"}
        bom = build_bom("9.9.9", dart, gradle, native, fixture["apk"], tool_versions)

        expect("生成的 SBOM 通过内部不变量", not _invariants(bom))

        dart_components = {c["name"]: c for c in dart[0]}
        expect("pub 层识别 MIT", dart_components["alpha"]["licenses"][0]["license"]["id"] == "MIT")
        expect("pub 层识别 Apache-2.0", dart_components["beta"]["licenses"][0]["license"]["id"] == "Apache-2.0")
        expect(
            "许可证不明时写 NOASSERTION（不猜）",
            dart_components["gamma"]["licenses"][0]["license"]["name"] == "NOASSERTION",
        )
        expect("dev 依赖标记为 excluded", dart_components["gamma"]["scope"] == "excluded")
        expect("运行时依赖标记为 required", dart_components["alpha"]["scope"] == "required")
        expect(
            "pub 依赖图包含包间边 alpha→beta",
            dart[1].get(purl("pub", "alpha", "1.0.0")) == [purl("pub", "beta", "2.0.0")],
        )

        gradle_components = {c["name"]: c for c in gradle[0]}
        expect(
            "Maven 许可来自 POM（Apache-2.0）",
            gradle_components["core"]["licenses"][0]["license"]["id"] == "Apache-2.0",
        )
        expect(
            "POM 缺失时写 NOASSERTION 且不猜",
            gradle_components["mystery"]["licenses"][0]["license"]["name"] == "NOASSERTION",
        )
        expect(
            "Gradle 根边被记录（root→core）",
            purl("maven", "androidx.core/core", "1.13.0") in gradle[1].get("\0ROOT", []),
        )

        native_names = sorted(c["name"] for c in native)
        expect("APK 原生库被逐个列出", native_names == ["libapp.so", "libflutter.so"])
        expect(
            "libflutter.so 标注引擎来源",
            any(
                p["value"] == "flutter-engine"
                for c in native
                if c["name"] == "libflutter.so"
                for p in c["properties"]
                if p["name"] == "zcode.native.origin"
            ),
        )

        root_depends = bom["dependencies"][0]
        expect("根组件连到直接依赖", purl("pub", "alpha", "1.0.0") in root_depends["dependsOn"])
        expect(
            "工具链版本写入 metadata.tools",
            len((bom["metadata"].get("tools") or {}).get("components") or []) >= 4,
        )

        # 负例：bom-ref 重复必须被发现
        broken = json.loads(json.dumps(bom))
        broken["components"].append(json.loads(json.dumps(bom["components"][0])))
        expect("重复 bom-ref 被判定为错误", bool(_invariants(broken)))

        # 负例：依赖引用不存在的组件
        broken = json.loads(json.dumps(bom))
        broken["dependencies"].append({"ref": purl("pub", "ghost", "0.0.1"), "dependsOn": []})
        expect("悬空依赖引用被判定为错误", bool(_invariants(broken)))

        # 负例：许可证缺失
        broken = json.loads(json.dumps(bom))
        broken["components"][0].pop("licenses", None)
        expect("缺 licenses 被判定为错误", bool(_invariants(broken)))

        # 负例：POM 里带 DTD/实体声明时必须拒绝解析（防实体扩展）
        hostile_pom = fixture["gradle_cache"].parent / "hostile.pom"
        hostile_pom.write_text(
            "<!DOCTYPE project [<!ENTITY a 'x'>]><project><licenses>"
            "<license><name>&a;</name></license></licenses></project>",
            encoding="utf-8",
        )
        expect("拒绝带 DTD 的 POM", parse_pom_xml(hostile_pom) is None)

        # 跨脚本集成：夹具 SBOM 必须能通过发布校验器（schema + 覆盖 + 许可）,
        # 否则"生成器改字段、校验器没跟上"这类漂移要到发布时才暴露。
        import importlib.util

        checker_path = ROOT / "scripts" / "verify-release-artifacts.py"
        spec = importlib.util.spec_from_file_location("zcode_verify", checker_path)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        fixture_sbom = root / "sbom.json"
        fixture_sbom.write_text(json.dumps(bom), encoding="utf-8")
        fixture_errors = checker.check_sbom(fixture_sbom, "9.9.9")
        expect(
            "夹具 SBOM 通过发布校验器（schema + 三层覆盖 + 许可）",
            not fixture_errors,
        )
        if fixture_errors:
            print(f"        {fixture_errors[:3]}")

        # 负例：缺 native 层在"完整 SBOM"要求下必须报错，但允许显式 partial
        partial_bom = build_bom(
            "9.9.9", dart, gradle, [], None, tool_versions, partial=True
        )
        expect(
            "缺原生层时被判定为错误（发布要求完整三层）",
            any("原生库" in message for message in _invariants(partial_bom)),
        )
        expect(
            "显式 partial 时缺原生层不报错（但带 partial 标记）",
            not _invariants(partial_bom, require_native=False)
            and any(
                p["name"] == "zcode.sbom.partial" and p["value"] == "true"
                for p in partial_bom["metadata"]["properties"]
            ),
        )

        # 离线可重复：同样输入两次结果一致（除时间戳）
        bom_again = build_bom("9.9.9", dart, gradle, native, fixture["apk"], tool_versions)
        stripped = [
            {k: v for k, v in doc["metadata"].items() if k != "timestamp"} for doc in (bom, bom_again)
        ]
        expect("同一输入两次生成结果一致", stripped[0] == stripped[1])

    failed = [name for name, passed in cases if not passed]
    print(f"self-test: {len(cases) - len(failed)}/{len(cases)} passed")
    return 1 if failed else 0


# ---------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="generate a CycloneDX SBOM for ZCode App")
    parser.add_argument("--out", help="output path (default: stdout)")
    parser.add_argument("--pubspec-lock", default=str(ROOT / "pubspec.lock"))
    parser.add_argument("--pubspec", default=str(ROOT / "pubspec.yaml"))
    parser.add_argument("--pub-cache", help="pub cache directory (default: $PUB_CACHE)")
    parser.add_argument("--gradle-inventory", help="JSON from scripts/sbom/gradle-inventory.gradle")
    parser.add_argument("--gradle-cache", default=str(Path.home() / ".gradle" / "caches"))
    parser.add_argument("--apk", help="built APK to inventory native libraries from")
    parser.add_argument("--version", help="app version (default: pubspec.yaml)")
    parser.add_argument("--flutter-version")
    parser.add_argument("--dart-version")
    parser.add_argument("--engine-revision")
    parser.add_argument("--agp-version")
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="允许缺 APK/Gradle 层的部分 SBOM（CI 只扫 Dart 层时用；发布门禁仍要求完整三层）",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()

    lock_path = Path(args.pubspec_lock)
    if not lock_path.is_file():
        print(f"missing pubspec.lock: {lock_path}", file=sys.stderr)
        return 1

    version = args.version
    if not version:
        text = Path(args.pubspec).read_text(encoding="utf-8") if Path(args.pubspec).is_file() else ""
        match = re.search(r"(?m)^version:\s*([0-9][^\s+]*)(?:\+([0-9]+))?", text)
        if not match:
            print("cannot determine version: pass --version", file=sys.stderr)
            return 1
        version = match.group(1)

    pub_cache = Path(args.pub_cache) if args.pub_cache else default_pub_cache()
    if pub_cache is None:
        print("warning: pub cache not found; Dart components will have no licenses", file=sys.stderr)

    dart = dart_layer(lock_path, Path(args.pubspec), pub_cache)
    gradle_components: list[dict] = []
    gradle_edges: dict[str, list[str]] = {}
    gradle_meta: dict = {}
    if args.gradle_inventory:
        gradle_components, gradle_edges, gradle_meta = gradle_layer(
            Path(args.gradle_inventory), Path(args.gradle_cache), version
        )
    native = native_layer(Path(args.apk), version, args.engine_revision, "MIT") if args.apk else []

    bom = build_bom(
        version,
        dart,
        (gradle_components, gradle_edges, gradle_meta),
        native,
        Path(args.apk) if args.apk else None,
        {
            "flutter": args.flutter_version,
            "dart": args.dart_version,
            "engine": args.engine_revision,
            "agp": args.agp_version,
        },
        partial=args.allow_partial,
    )

    errors = _invariants(bom, require_native=not args.allow_partial)
    if errors:
        for message in errors:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1

    text = json.dumps(bom, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        counts = bom["metadata"]["properties"]
        summary = ", ".join(f"{p['name']}={p['value']}" for p in counts if "inventory" in p["name"])
        print(f"SBOM written to {args.out} ({summary})")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
