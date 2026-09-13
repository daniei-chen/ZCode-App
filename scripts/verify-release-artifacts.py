#!/usr/bin/env python3
"""发布资产校验（v1.1.0 / PR18*）：manifest schema、digest 一致性、attestation 交叉核对。

用法：
  python3 scripts/verify-release-artifacts.py --dir <目录> --version <x.y.z> [--attestation-json <file>]
  python3 scripts/verify-release-artifacts.py --self-test

`--dir` 必须包含：
  ZCode-v<version>.apk / ZCode-v<version>.apk.sha256 /
  ZCode-v<version>.sbom.cyclonedx.json / release-manifest.json

校验（任一失败 → 非零退出）：
  1. release-manifest.json 符合 scripts/release-manifest.schema.json（受支持子集）；
  2. manifest.version == --version；apk.fileName == 期望文件名；
  3. 重新计算的 APK SHA-256 == sidecar == manifest.apk.sha256（大小写不敏感）；
  4. manifest 声明的 SBOM 文件存在；
  5. 传入 --attestation-json 时：attestation 主题名与 sha256 必须与 APK 一致。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent / "release-manifest.schema.json"


# ---------------------------------------------------------------- schema subset


def validate(instance: object, schema: dict, path: str = "$") -> list[str]:
    """校验 JSON Schema 的受支持子集；返回错误列表（空 = 通过）。"""
    errors: list[str] = []
    expected = schema.get("type")
    if expected:
        checks = {
            "object": isinstance(instance, dict),
            "array": isinstance(instance, list),
            "string": isinstance(instance, str),
            "integer": isinstance(instance, int) and not isinstance(instance, bool),
            "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
            "boolean": isinstance(instance, bool),
        }
        if expected in checks and not checks[expected]:
            return [f"{path}: expected {expected}, got {type(instance).__name__}"]

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: value not in enum")

    if isinstance(instance, str):
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            errors.append(f"{path}: does not match pattern {schema['pattern']}")
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: shorter than {schema['minLength']}")

    if isinstance(instance, int) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: below minimum {schema['minimum']}")

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: fewer than {schema['minItems']} items")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, value in enumerate(instance):
                errors.extend(validate(value, item_schema, f"{path}[{index}]"))

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if key in properties:
                errors.extend(validate(value, properties[key], f"{path}.{key}"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unexpected property {key!r}")
    return errors


# ---------------------------------------------------------------- helpers


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sidecar_digest(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text:
        return None
    token = text.split()[0]
    return token if re.fullmatch(r"[0-9A-Fa-f]{64}", token) else None


def attestation_subjects(data: object) -> list[dict]:
    """从 `gh attestation verify --format json` 输出提取 in-toto subjects。"""
    entries = data if isinstance(data, list) else [data]
    subjects: list[dict] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        statement = (entry.get("verificationResult") or {}).get("statement")
        if not isinstance(statement, dict):
            envelope = ((entry.get("attestation") or {}).get("bundle") or {}).get("dsseEnvelope") or {}
            payload = envelope.get("payload")
            if isinstance(payload, str) and payload:
                try:
                    statement = json.loads(base64.b64decode(payload).decode("utf-8"))
                except (ValueError, TypeError):
                    statement = None
        if isinstance(statement, dict):
            for subject in statement.get("subject") or []:
                if isinstance(subject, dict):
                    subjects.append(subject)
    return subjects


# ---------------------------------------------------------------- checks


def check_dir(directory: Path, version: str, attestation: Path | None = None) -> list[str]:
    errors: list[str] = []
    apk_name = f"ZCode-v{version}.apk"
    apk_path = directory / apk_name
    sidecar_path = directory / f"{apk_name}.sha256"
    manifest_path = directory / "release-manifest.json"

    if not apk_path.is_file():
        errors.append(f"apk not found: {apk_path}")
        return errors
    if not manifest_path.is_file():
        errors.append(f"manifest not found: {manifest_path}")
        return errors

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return [f"release-manifest.json is not valid JSON: {exc}"]

    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"cannot load schema {SCHEMA_PATH}: {exc}"]

    schema_errors = validate(manifest, schema)
    errors.extend(f"manifest schema: {message}" for message in schema_errors)
    if schema_errors:
        return errors

    if manifest.get("version") != version:
        errors.append(f"manifest.version {manifest.get('version')!r} != expected {version!r}")
    if ((manifest.get("apk") or {}).get("fileName")) != apk_name:
        errors.append(f"manifest.apk.fileName != {apk_name}")

    actual = sha256_file(apk_path)
    declared = str(((manifest.get("apk") or {}).get("sha256")) or "").lower()
    if actual != declared:
        errors.append(f"apk sha256 mismatch: computed {actual} != manifest {declared}")

    sidecar = sidecar_digest(sidecar_path)
    if sidecar is None:
        errors.append(f"missing or malformed sidecar: {sidecar_path}")
    elif sidecar.lower() != actual:
        errors.append(f"sidecar sha256 mismatch: {sidecar.lower()} != computed {actual}")

    sbom = manifest.get("sbom")
    if isinstance(sbom, str) and sbom and not (directory / sbom).is_file():
        errors.append(f"declared sbom missing on disk: {sbom}")

    if attestation is not None:
        try:
            data = json.loads(attestation.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            errors.append(f"cannot read attestation json: {exc}")
        else:
            subjects = attestation_subjects(data)
            if not subjects:
                errors.append("attestation contains no in-toto subjects")
            else:
                matching = [
                    s
                    for s in subjects
                    if s.get("name") == apk_name
                    and str(((s.get("digest") or {}).get("sha256")) or "").lower() == actual
                ]
                if not matching:
                    names = ", ".join(str(s.get("name")) for s in subjects)
                    errors.append(
                        f"attestation subject does not match {apk_name} @ {actual} (subjects: {names})"
                    )
    return errors


# ---------------------------------------------------------------- self test


def _write_fixture(root: Path, version: str = "9.9.9") -> Path:
    apk = root / f"ZCode-v{version}.apk"
    apk.write_bytes(b"fake-apk-bytes" * 256)
    digest = sha256_file(apk)
    (root / f"ZCode-v{version}.apk.sha256").write_text(
        f"{digest}  ZCode-v{version}.apk\n", encoding="utf-8"
    )
    (root / f"ZCode-v{version}.sbom.cyclonedx.json").write_text("{}\n", encoding="utf-8")
    manifest = {
        "app": "ZCode App",
        "package": "com.zcode.app",
        "version": version,
        "versionCode": 11,
        "commit": "0" * 40,
        "abi": ["arm64-v8a"],
        "apk": {
            "fileName": f"ZCode-v{version}.apk",
            "sha256": digest.upper(),
            "signerSha256": "a" * 64,
        },
        "toolchain": {"flutter": "3.47.3", "dart": "3.13.3", "java": "17"},
        "generatedAt": "2026-09-13T00:00:00Z",
        "sbom": f"ZCode-v{version}.sbom.cyclonedx.json",
    }
    (root / "release-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return root


def _attestation_fixture(path: Path, apk_name: str, digest: str) -> None:
    payload = {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": [{"name": apk_name, "digest": {"sha256": digest}}],
        "predicate": {},
    }
    entry = {
        "verificationResult": {"statement": payload},
        "attestation": {},
    }
    path.write_text(json.dumps([entry]), encoding="utf-8")


def run_self_test() -> int:
    cases: list[tuple[str, bool]] = []

    def expect(name: str, errors: list[str], should_fail: bool) -> None:
        passed = bool(errors) == should_fail
        cases.append((name, passed))
        status = "ok" if passed else "FAIL"
        detail = "" if passed else f" errors={errors}"
        print(f"  [{status}] {name}{detail}")

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        version = "9.9.9"
        _write_fixture(root, version)
        base_errors = check_dir(root, version)
        expect("valid fixture passes", base_errors, should_fail=False)

        # sidecar 被篡改
        tampered = root / "tampered-sidecar"
        shutil.copytree(root, tampered)
        (tampered / f"ZCode-v{version}.apk.sha256").write_text(
            f"{'b' * 64}  ZCode-v{version}.apk\n", encoding="utf-8"
        )
        expect("tampered sidecar fails", check_dir(tampered, version), should_fail=True)

        # manifest digest 被篡改
        tampered = root / "tampered-manifest"
        shutil.copytree(root, tampered)
        data = json.loads((tampered / "release-manifest.json").read_text(encoding="utf-8"))
        data["apk"]["sha256"] = "C" * 64
        (tampered / "release-manifest.json").write_text(json.dumps(data), encoding="utf-8")
        expect("tampered manifest digest fails", check_dir(tampered, version), should_fail=True)

        # 缺必需字段
        tampered = root / "missing-field"
        shutil.copytree(root, tampered)
        data = json.loads((tampered / "release-manifest.json").read_text(encoding="utf-8"))
        del data["commit"]
        (tampered / "release-manifest.json").write_text(json.dumps(data), encoding="utf-8")
        expect("missing commit fails", check_dir(tampered, version), should_fail=True)

        # versionCode 类型错误
        tampered = root / "bad-versioncode"
        shutil.copytree(root, tampered)
        data = json.loads((tampered / "release-manifest.json").read_text(encoding="utf-8"))
        data["versionCode"] = "11"
        (tampered / "release-manifest.json").write_text(json.dumps(data), encoding="utf-8")
        expect("string versionCode fails", check_dir(tampered, version), should_fail=True)

        # APK 缺失
        tampered = root / "missing-apk"
        shutil.copytree(root, tampered)
        (tampered / f"ZCode-v{version}.apk").unlink()
        expect("missing apk fails", check_dir(tampered, version), should_fail=True)

        # attestation 匹配 / 不匹配
        digest = sha256_file(root / f"ZCode-v{version}.apk")
        good = root / "attestation-good.json"
        _attestation_fixture(good, f"ZCode-v{version}.apk", digest)
        expect(
            "matching attestation passes",
            check_dir(root, version, attestation=good),
            should_fail=False,
        )
        bad = root / "attestation-bad.json"
        _attestation_fixture(bad, f"ZCode-v{version}.apk", "d" * 64)
        expect(
            "mismatched attestation fails",
            check_dir(root, version, attestation=bad),
            should_fail=True,
        )

    failed = [name for name, passed in cases if not passed]
    print(f"self-test: {len(cases) - len(failed)}/{len(cases)} passed")
    return 1 if failed else 0


# ---------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="verify release artifacts and digests")
    parser.add_argument("--dir", help="directory containing the release assets")
    parser.add_argument("--version", help="expected version, e.g. 1.1.0")
    parser.add_argument("--attestation-json", help="output of `gh attestation verify --format json`")
    parser.add_argument("--self-test", action="store_true", help="run built-in positive/negative cases")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    if not args.dir or not args.version:
        parser.error("--dir and --version are required (or use --self-test)")
    directory = Path(args.dir)
    if not directory.is_dir():
        print(f"not a directory: {directory}", file=sys.stderr)
        return 1
    attestation = Path(args.attestation_json) if args.attestation_json else None
    errors = check_dir(directory, args.version, attestation=attestation)
    if errors:
        for message in errors:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1
    print(
        f"OK: {directory} — manifest schema, version, sidecar and digests consistent"
        + (", attestation subject verified" if attestation else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
