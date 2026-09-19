#!/usr/bin/env bash
# tools/iteration/fingerprint.sh — code-domain checkpoint fingerprint.
#
# `git diff HEAD -- <paths>` alone misses *untracked* new files, which is exactly
# what a batch usually adds (iter3 L-16). The fingerprint therefore hashes:
#   1. the tracked diff against HEAD over the code domain, and
#   2. every untracked, non-ignored file under the code domain: path + content hash.
# Output: sha256:<hex>. Deterministic for a given working tree.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
PATHS=(lib test android scripts pubspec.yaml pubspec.lock .github integration_test tools)
{
  git diff HEAD -- "${PATHS[@]}"
  echo "--- untracked ---"
  git ls-files --others --exclude-standard -z -- "${PATHS[@]}" | sort -z | while IFS= read -r -d '' f; do
    printf '%s %s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
} | sha256sum | { read -r hex _; echo "sha256:$hex"; }
