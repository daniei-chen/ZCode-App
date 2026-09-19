#!/usr/bin/env bash
# tools/iteration/gates.sh — run every local gate inside a throwaway export of the
# working tree, never inside the real checkout (DEC-02: `flutter test` rewrites the
# untracked GeneratedPluginRegistrant.java and poisons later release builds).
#
# Usage:
#   tools/iteration/gates.sh <prefix> [--osv] [--build] [--strict-osv] [--strict-state]
#
# Writes docs/continuous-iteration/evidence/<prefix>-<gate>.log for each gate plus
# <prefix>-gates-summary.json (status + wall-clock per gate) for the LESSONS ledger.
# Exit 1 when any required gate (analyze/test/js/docdrift/secrets/selftests) fails.
# OSV network failures are reported as BLOCKED and do not fail the run unless
# --strict-osv is given: a fail-closed refusal is the correct behaviour, not a pass.
# The `state` gate (iteration_state.py --repo-root + gitignore canary) reports WARN
# by default because gates run *before* bookkeeping inside a batch, so a matrix edit
# whose history entry is not yet written would otherwise sink every run; pass
# --strict-state for the checkpoint run, where WARN must become FAIL.
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <prefix> [--osv] [--build] [--strict-osv] [--strict-state]" >&2
  exit 2
fi
PREFIX="$1"; shift
RUN_OSV=0; RUN_BUILD=0; STRICT_OSV=0; STRICT_STATE=0
for arg in "$@"; do
  case "$arg" in
    --osv) RUN_OSV=1 ;;
    --build) RUN_BUILD=1 ;;
    --strict-osv) STRICT_OSV=1 ;;
    --strict-state) STRICT_STATE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORT_BASE="${ZR_EXPORT_BASE:-/d/tmp/zr}"
EXP="$EXPORT_BASE/ci_${PREFIX}"
EV="$REPO/docs/continuous-iteration/evidence"
SBOM="${ZR_SBOM:-/d/tmp/zr/releases/ZCode-v1.0.0.sbom.cyclonedx.json}"
mkdir -p "$EV" "$EXPORT_BASE"

declare -A STATUS WALL
ORDER=()
FAILED=0
now() { date +%s; }
record() { # name status seconds
  STATUS["$1"]="$2"; WALL["$1"]="$3"; ORDER+=("$1")
  printf '  %-12s %-8s %4ss\n' "$1" "$2" "$3"
}

echo "== gates.sh prefix=$PREFIX repo=$REPO export=$EXP =="

# ---- 0. export: HEAD snapshot + working-tree overlay (tracked-modified + untracked, not ignored)
t0=$(now)
rm -rf "$EXP" && mkdir -p "$EXP"
( cd "$REPO" && git archive HEAD | tar -x -C "$EXP" ) || { echo "export: git archive failed" >&2; exit 1; }
( cd "$REPO" && { git diff --name-only HEAD -z; git ls-files --others --exclude-standard -z; } 2>/dev/null \
  | while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      mkdir -p "$EXP/$(dirname "$f")" && cp "$f" "$EXP/$f"
    done )
( cd "$REPO" && git diff --name-only HEAD -z --diff-filter=D 2>/dev/null | while IFS= read -r -d '' f; do rm -f "$EXP/$f"; done )
record export OK $(( $(now) - t0 ))

cd "$EXP" || exit 1

# ---- 1. pub get
t0=$(now)
if flutter pub get > "$EV/$PREFIX-pubget.log" 2>&1; then record pubget PASS $(( $(now) - t0 )); else record pubget FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 2. analyze
t0=$(now)
if flutter analyze > "$EV/$PREFIX-analyze.log" 2>&1; then record analyze PASS $(( $(now) - t0 )); else record analyze FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 3. test (expanded reporter so per-test names land in evidence)
t0=$(now)
if flutter test --reporter expanded > "$EV/$PREFIX-test.log" 2>&1; then
  PASSED=$(grep -oE '\+[0-9]+' "$EV/$PREFIX-test.log" | tail -1 | tr -d '+')
  record test "PASS(${PASSED:-0})" $(( $(now) - t0 ))
else
  FAILS=$(grep -c '\[E\]' "$EV/$PREFIX-test.log" || true)
  record test "FAIL($FAILS)" $(( $(now) - t0 )); FAILED=1
fi

# ---- 4. injected JS gate
t0=$(now)
if node scripts/check_injected_js.mjs > "$EV/$PREFIX-js.log" 2>&1; then record js PASS $(( $(now) - t0 )); else record js FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 5. doc drift
t0=$(now)
if python scripts/check-doc-drift.py > "$EV/$PREFIX-docdrift.log" 2>&1; then record docdrift PASS $(( $(now) - t0 )); else record docdrift FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 6. secrets (runs against the real repo index, read-only)
t0=$(now)
{
  echo "$PREFIX secret scan @ $(date -Iseconds)"
  cd "$REPO"
  EXT=$(git ls-files | grep -Eic '\.(jks|keystore|p12|pfx|pem)$|key\.properties$' || true)
  echo "tracked secret-ext files: $EXT"
  HITS=$(git grep -nEi '(storePassword|keyPassword|api[_-]?key|secret|token)\s*[:=]\s*["'"'"'][A-Za-z0-9+/=_-]{16,}' -- lib android scripts test tools 2>/dev/null || true)
  RAW=$(printf '%s\n' "$HITS" | grep -c . || true)
  EFFECTIVE=$(printf '%s\n' "$HITS" | grep -vE 'CANARY[-_][A-Za-z0-9]+' | grep -c . || true)
  echo "credential literals (raw): $RAW"
  echo "credential literals (effective, CANARY test tokens excluded): $EFFECTIVE"
  [ -n "$HITS" ] && printf '%s\n' "$HITS" | sed 's/^/  hit: /'
  git check-ignore -v android/key.properties android/local.properties || true
  cd "$EXP"
  if [ "$EXT" = "0" ] && [ "$EFFECTIVE" = "0" ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
} > "$EV/$PREFIX-secrets.log" 2>&1
if grep -q '^RESULT: PASS' "$EV/$PREFIX-secrets.log"; then record secrets PASS $(( $(now) - t0 )); else record secrets FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 7. release-script self-tests
t0=$(now)
{
  echo "date: $(date -Iseconds)"
  echo "## check_injected_js.mjs (gate, no self-test mode) — live run in $PREFIX-js.log"
  ST_FAIL=0
  for s in check-doc-drift.py check-dependency-advisories.py check-plugin-survival.py verify-release-artifacts.py generate-sbom.py; do
    echo "## $s self-test"
    python "scripts/$s" --self-test 2>&1 | tail -1
    ec=${PIPESTATUS[0]}; echo "exit=$ec"; [ "$ec" = "0" ] || ST_FAIL=1
  done
  # tools/iteration 自测（iter13 复核 F-2：--require-tracked 等 10 条 unittest 此前无门禁执行）
  echo "## tools/iteration/test_iteration_state.py"
  python -m unittest discover -s tools/iteration -p "test_*.py" 2>&1 | tail -2
  ec=${PIPESTATUS[0]}; echo "exit=$ec"; [ "$ec" = "0" ] || ST_FAIL=1
  echo "RESULT: $([ $ST_FAIL = 0 ] && echo PASS || echo FAIL)"
} > "$EV/$PREFIX-script-selftests.log" 2>&1
if grep -q '^RESULT: PASS' "$EV/$PREFIX-script-selftests.log"; then record selftests PASS $(( $(now) - t0 )); else record selftests FAIL $(( $(now) - t0 )); FAILED=1; fi

# ---- 7b. state contract + repo cross-checks (runs against the real repo, read-only).
# Added after iter3 F-1: a "valid" result taken before new files landed is worthless,
# so the check runs on every gate pass instead of when someone remembers.
t0=$(now)
STATE_BAD=0
# W-015 启用（iter13 收尾）：检查点运行（--strict-state）同时要求台账引用的
# 证据/报告/决策文件已被 git 跟踪——批次运行不要求（evidence 在门禁期间新写、
# 尚未提交，恒 FAIL 是预期），检查点运行时仓库应已提交，未被跟踪才是真问题。
if [ $STRICT_STATE = 1 ]; then
  STATE_REQ_TRACKED="--require-tracked"
else
  STATE_REQ_TRACKED=""
fi
if ( cd "$REPO" && python tools/iteration/iteration_state.py validate --repo-root . $STATE_REQ_TRACKED docs/continuous-iteration/ITERATION_STATE.json ) > "$EV/$PREFIX-state.log" 2>&1; then
  # iter3 F-2/F-5: a referenced file that .gitignore swallows is "present" locally and
  # absent for everyone else. Canary the classes we have been bitten by.
  if ( cd "$REPO" && git check-ignore -q "docs/continuous-iteration/evidence/$PREFIX-test.log" tools/iteration/gates.sh docs/continuous-iteration/ITERATION_STATE.json 2>/dev/null ); then
    echo "ERROR: a control-plane path is gitignored (evidence log / toolkit / state)" >> "$EV/$PREFIX-state.log"
    STATE_BAD=1
  fi
else
  STATE_BAD=1
fi
if [ $STATE_BAD = 0 ]; then record state PASS $(( $(now) - t0 ))
elif [ $STRICT_STATE = 1 ]; then record state FAIL $(( $(now) - t0 )); FAILED=1
else record state WARN $(( $(now) - t0 )); fi

# ---- 7c. mutation-corpus coverage: every test case in mutations/coverage-files.txt
# must be referenced by a revert-must-fail entry or a declared exemption (iter4 F-1/N-1).
# Static check only (no test runs); the corpus itself runs via mutate.py --export.
t0=$(now)
COV_ARGS=()
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  COV_ARGS+=(--coverage "$line")
done < "$REPO/tools/iteration/mutations/coverage-files.txt"
if [ ${#COV_ARGS[@]} -eq 0 ]; then
  echo "no coverage files listed" > "$EV/$PREFIX-mutcov.log"; record mutcov PASS $(( $(now) - t0 ))
elif ( cd "$REPO" && python tools/iteration/mutate.py "${COV_ARGS[@]}" $(for s in tools/iteration/mutations/iter*.json; do printf -- '--spec %s ' "$s"; done) ) > "$EV/$PREFIX-mutcov.log" 2>&1; then
  record mutcov PASS $(( $(now) - t0 ))
else
  record mutcov FAIL $(( $(now) - t0 )); FAILED=1
fi

# ---- 8. OSV (optional; needs public DNS for api.osv.dev)
if [ $RUN_OSV = 1 ]; then
  t0=$(now)
  if [ ! -f "$SBOM" ]; then
    echo "SBOM not found: $SBOM" > "$EV/$PREFIX-osv.log"; record osv BLOCKED $(( $(now) - t0 ))
  else
    python scripts/check-dependency-advisories.py --sbom "$SBOM" --exceptions scripts/security-exceptions.json --fail-on high > "$EV/$PREFIX-osv.log" 2>&1
    ec=$?; echo "exit=$ec" >> "$EV/$PREFIX-osv.log"
    if [ $ec = 0 ]; then record osv PASS $(( $(now) - t0 ))
    elif grep -qE '不可达|non-public|unreachable|resolved to' "$EV/$PREFIX-osv.log"; then
      record osv BLOCKED $(( $(now) - t0 )); [ $STRICT_OSV = 1 ] && FAILED=1
    else record osv FAIL $(( $(now) - t0 )); FAILED=1; fi
  fi
fi

# ---- 9. debug APK build (optional; never release — signing key is a P0 governance item)
if [ $RUN_BUILD = 1 ]; then
  t0=$(now)
  if flutter build apk --debug > "$EV/$PREFIX-build.log" 2>&1; then
    APK=$(ls build/app/outputs/flutter-apk/app-debug.apk 2>/dev/null)
    if [ -n "$APK" ]; then
      echo "apk: $APK size=$(stat -c %s "$APK") sha256=$(sha256sum "$APK" | cut -c1-16)…" >> "$EV/$PREFIX-build.log"
      record build PASS $(( $(now) - t0 ))
    else record build FAIL $(( $(now) - t0 )); FAILED=1; fi
  else record build FAIL $(( $(now) - t0 )); FAILED=1; fi
fi

# ---- summary
{
  printf '{"prefix":"%s","export":"%s","generated_at":"%s","failed":%s,"gates":{' "$PREFIX" "$EXP" "$(date -Iseconds)" "$FAILED"
  first=1
  for g in "${ORDER[@]}"; do
    [ $first = 1 ] || printf ','
    first=0
    printf '"%s":{"status":"%s","wall_s":%s}' "$g" "${STATUS[$g]}" "${WALL[$g]}"
  done
  printf '}}\n'
} > "$EV/$PREFIX-gates-summary.json"
echo "summary: $EV/$PREFIX-gates-summary.json"

echo "export kept for mutation runs: $EXP"
exit $FAILED
