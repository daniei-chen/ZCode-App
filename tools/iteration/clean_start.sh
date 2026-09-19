#!/usr/bin/env bash
# tools/iteration/clean_start.sh — "别人拿到仓库能不能跑起来" 冷启动门（W-012）。
#
# 与 gates.sh 的区别：gates.sh 信任工作树的生成物（lib/l10n/*.dart 是
# gitignore 的），本脚本在全新导出里从 arb **重新生成**它们，并与工作树
# 逐字节比对——arb 与生成物漂移（改了文案忘了重新生成）在这里现形。
#
# Usage: tools/iteration/clean_start.sh <prefix>
# 产物：docs/continuous-iteration/evidence/<prefix>-cleanstart.log
# Exit 1 on any failure (pub get / gen-l10n drift / analyze / test)。
# 单一写者：全部输出走主 shell 的块重定向（iter11 F-2/F-4——管道子 shell
# 会吞 FAILED、多写者会互踩日志）。
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <prefix>" >&2
  exit 2
fi
PREFIX="$1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORT_BASE="${ZR_EXPORT_BASE:-/d/tmp/zr}"
EXP="$EXPORT_BASE/clean_${PREFIX}"
EV="$REPO/docs/continuous-iteration/evidence"
LOG="$EV/$PREFIX-cleanstart.log"
mkdir -p "$EV"
FAILED=0
now() { date +%s; }
t0=$(now)

{
  echo "== clean_start prefix=$PREFIX repo=$REPO =="
  echo "[$(date -Iseconds)] 1/5 fresh export (HEAD + working-tree overlay)"

  rm -rf "$EXP" && mkdir -p "$EXP"
  ( cd "$REPO" && git archive HEAD | tar -x -C "$EXP" ) || { echo "export FAILED"; FAILED=1; }
  if [ $FAILED = 0 ]; then
    ( cd "$REPO" && { git diff --name-only HEAD -z; git ls-files --others --exclude-standard -z; } 2>/dev/null \
      | while IFS= read -r -d '' f; do
          [ -f "$f" ] || continue
          mkdir -p "$EXP/$(dirname "$f")" && cp "$f" "$EXP/$f"
        done )
    ( cd "$REPO" && git diff --name-only HEAD -z --diff-filter=D 2>/dev/null | while IFS= read -r -d '' f; do rm -f "$EXP/$f"; done )
    echo "[$(date -Iseconds)] export ok ($(( $(now) - t0 ))s)"

    echo "[$(date -Iseconds)] 2/5 pub get"
    ( cd "$EXP" && flutter pub get ) || FAILED=1
  fi

  if [ $FAILED = 0 ]; then
    echo "[$(date -Iseconds)] 3/5 gen-l10n + drift check (arb ↔ 生成物)"
    ( cd "$EXP" && flutter gen-l10n ) || FAILED=1
    if [ $FAILED = 0 ]; then
      for f in app_localizations.dart app_localizations_zh.dart; do
        if ! diff -q --strip-trailing-cr "$EXP/lib/l10n/$f" "$REPO/lib/l10n/$f"; then
          echo "l10n DRIFT: lib/l10n/$f differs (arb changed without regenerating, or stale copy)"
          FAILED=1
        fi
      done
      [ $FAILED = 0 ] && echo "l10n drift check: clean"
    fi
  fi

  if [ $FAILED = 0 ]; then
    echo "[$(date -Iseconds)] 4/5 analyze"
    ( cd "$EXP" && flutter analyze ) || FAILED=1
  fi

  if [ $FAILED = 0 ]; then
    echo "[$(date -Iseconds)] 5/5 test (full)"
    ( cd "$EXP" && flutter test --reporter expanded ) || FAILED=1
  fi

  echo "[$(date -Iseconds)] clean_start exit=$FAILED (wall $(( $(now) - t0 ))s)"
} > "$LOG" 2>&1
cat "$LOG"
exit $FAILED
