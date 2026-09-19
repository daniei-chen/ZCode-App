#!/usr/bin/env python3
"""tools/iteration/mutate.py — declarative "revert-must-fail" mutation checks.

A regression test only guards a fix if putting the bug back makes it fail. This
harness applies each mutation from a JSON corpus to an export directory (never the
real checkout), runs the named test file, and asserts that:

  * the run exits non-zero,
  * every `expect_fail` substring matches a failing test name, and
  * with `"only": true`, *no other* test in that file fails (the guard is precise).

The original file bytes are restored after each mutation (also on error), and with
--require-green the test file is re-run afterwards and must pass.

Corpus entry:
  {"id": "...", "file": "lib/x.dart", "find": "<exact source text>",
   "replace": "<mutated text>", "test_file": "test/x_test.dart",
   "expect_fail": ["test name substring", ...], "only": true}

`only` semantics: with `"only": true`, **no test other than the ones matched by
`expect_fail` may fail** in that test file — the guard must be precise. Set it to
`false` (or omit) when a mutation legitimately breaks several cases sharing a
fixture; the `expect_fail` substrings are still asserted to appear among failures.

JSON string escaping is the whole point: `\\u0000` in the corpus means the six
characters backslash-u-0-0-0-0 as they appear in Dart source.

Usage:
  python tools/iteration/mutate.py --export /d/tmp/zr/ci_<prefix> \\
      --spec tools/iteration/mutations/iter2.json [--log <evidence.log>] [--require-green]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FAIL_LINE = re.compile(r"^\s*\d\d:\d\d \+\d+(?: -\d+)?: (?P<name>.*?) \[E\]\s*$")


TIMEOUT_S = 900  # per test run; a hung mutation must not stall the whole corpus (iter4 N-3)


def run_tests(export: Path, test_file: str) -> tuple[int, str]:
    flutter = shutil.which("flutter") or "flutter"  # Windows resolves to flutter.bat
    try:
        proc = subprocess.run(
            [flutter, "test", test_file, "--reporter", "expanded"],
            cwd=str(export), capture_output=True, text=True, encoding="utf-8", errors="replace", shell=False,
            timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as exc:
        partial = (exc.stdout or b"") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        return 124, f"{partial}\nTIMEOUT after {TIMEOUT_S}s\n"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def failing_names(output: str) -> list[str]:
    names: list[str] = []
    for line in output.splitlines():
        match = FAIL_LINE.match(line)
        if match:
            names.append(match.group("name").strip())
    return names


def check_mutation(export: Path, spec: dict, require_green: bool, log: list[str]) -> bool:
    mid = spec["id"]
    target = export / spec["file"]
    try:
        original = target.read_bytes()
        text = original.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        log.append(f"[{mid}] ERROR cannot read {spec['file']}: {exc}")
        return False
    # Corpora are written with LF; match against LF-normalised text and write the
    # mutation back with the file's own line endings so CRLF checkouts work too.
    eol = "\r\n" if "\r\n" in text else "\n"
    normalised = text.replace("\r\n", "\n")
    find, replace = spec["find"], spec["replace"]
    count = normalised.count(find)
    if count != 1:
        log.append(f"[{mid}] ERROR find-string occurs {count} times (need exactly 1) in {spec['file']}")
        return False
    mutated = normalised.replace(find, replace, 1)
    if eol != "\n":
        mutated = mutated.replace("\n", eol)
    ok = True
    try:
        target.write_bytes(mutated.encode("utf-8"))
        started = time.time()
        code, output = run_tests(export, spec["test_file"])
        elapsed = time.time() - started
        failed = failing_names(output)
        # iter8 L-23：编译失败 ≠ 通过也 ≠ 被抓住——变异把被测文件改坏了
        # （或语料 find 串落错），必须显式报 ERROR，否则整轮结果全是噪声。
        if "Failed to load" in output or "Compilation failed" in output:
            log.append(
                f"[{mid}] ERROR test file failed to compile under mutation"
            )
            ok = False
        elif code == 0:
            log.append(f"[{mid}] FAIL mutation survived: tests still pass ({elapsed:.0f}s)")
            ok = False
        missing = [name for name in spec.get("expect_fail", []) if not any(name in f for f in failed)]
        if missing:
            log.append(f"[{mid}] FAIL expected failing tests not observed: {missing}")
            ok = False
        if spec.get("only") and len(failed) != len(spec.get("expect_fail", [])):
            log.append(f"[{mid}] FAIL expected exactly {len(spec.get('expect_fail', []))} failing tests, observed {len(failed)}: {failed}")
            ok = False
        if ok:
            log.append(f"[{mid}] PASS exit={code} failing={failed} ({elapsed:.0f}s)")
    finally:
        target.write_bytes(original)
    if ok and require_green:
        code, output = run_tests(export, spec["test_file"])
        if code != 0:
            log.append(f"[{mid}] FAIL restore did not return the suite to green: {failing_names(output)}")
            ok = False
        else:
            log.append(f"[{mid}] restored -> green")
    return ok


TEST_NAME = re.compile(r"""^\s*test\(\s*(['"])(?P<name>.+?)\1\s*,""", re.MULTILINE)


def coverage_report(test_file: Path, specs: list[dict]) -> list[str]:
    """Names of `test('...')` cases in test_file that no corpus entry references.

    A case is covered when an active entry's `expect_fail` substring matches it or an
    `exempt` entry lists a matching substring in `covers`. This turns "every new test
    has a revert-must-fail mutation" (iter4 F-1) from a promise into a check.
    """
    text = test_file.read_text(encoding="utf-8", errors="replace")
    names = [m.group("name") for m in TEST_NAME.finditer(text)]
    rel = test_file.as_posix()
    needles: list[str] = []
    for spec in specs:
        if not spec.get("test_file") or not rel.endswith(spec["test_file"]):
            continue
        needles.extend(spec.get("expect_fail", []))
        needles.extend(spec.get("covers", []))
    return [name for name in names if not any(needle in name for needle in needles)]


def main() -> int:
    global TIMEOUT_S
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--export", type=Path, required=False, help="export directory produced by gates.sh")
    parser.add_argument("--spec", type=Path, required=True, action="append", help="mutation corpus JSON (repeatable)")
    parser.add_argument("--log", type=Path, default=None, help="write the run log here (evidence)")
    parser.add_argument("--require-green", action="store_true", help="re-run each test file after restore and require pass")
    parser.add_argument("--coverage", type=Path, action="append", default=[], help="list test cases in this file not referenced by any corpus entry (repeatable); exit 1 if any")
    parser.add_argument("--timeout-s", type=int, default=TIMEOUT_S, help="per test-run timeout in seconds (a timed-out mutation counts as not caught)")
    args = parser.parse_args()
    TIMEOUT_S = args.timeout_s

    if args.coverage:
        specs_cov: list[dict] = []
        for spec_path in args.spec:
            specs_cov.extend(json.loads(spec_path.read_text(encoding="utf-8")))
        missing_total = 0
        for test_file in args.coverage:
            missing = coverage_report(test_file, specs_cov)
            missing_total += len(missing)
            print(f"{test_file.as_posix()}: {len(missing)} uncovered")
            for name in missing:
                print(f"  - {name}")
        return 1 if missing_total else 0

    if args.export is None or not (args.export / "pubspec.yaml").exists():
        print(f"ERROR: --export must point at a Flutter export (pubspec.yaml missing): {args.export}", file=sys.stderr)
        return 2
    specs: list[dict] = []
    for spec_path in args.spec:
        specs.extend(json.loads(spec_path.read_text(encoding="utf-8")))
    log: list[str] = [f"mutate.py export={args.export} specs={[str(s) for s in args.spec]} @ {time.strftime('%Y-%m-%dT%H:%M:%S')}"]
    ids = [spec["id"] for spec in specs]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        print(f"ERROR: duplicate mutation ids across corpora: {duplicates}", file=sys.stderr)
        return 2
    # Entries with "exempt": true declare, auditable in the corpus itself, that a test
    # has no meaningful revert-must-fail mutation (e.g. a constant-sanity test whose
    # production check lives behind a WebView). They are listed, never counted.
    exempt = [spec for spec in specs if spec.get("exempt")]
    for spec in exempt:
        log.append(f"[{spec['id']}] EXEMPT ({spec.get('test_file', '?')}): {spec.get('reason', 'no reason given')}")
    active = [spec for spec in specs if not spec.get("exempt")]
    results = {spec["id"]: check_mutation(args.export, spec, args.require_green, log) for spec in active}
    passed = sum(1 for v in results.values() if v)
    log.append(f"RESULT: {passed}/{len(results)} mutations caught; {len(exempt)} exempt (declared)")
    text = "\n".join(log) + "\n"
    print(text, end="")
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        args.log.write_text(text, encoding="utf-8", newline="\n")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
