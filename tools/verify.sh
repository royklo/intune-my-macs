#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# verify.sh — one-command local validation loop for intune-my-macs.
#
# Validates that every committed artifact is well-formed so a change can be
# checked locally before pushing:
#   * JSON policies parse (UTF-8 BOM tolerated, as in Intune/Graph exports)
#   * XML manifests parse
#   * .mobileconfig profiles are valid property lists
#   * PowerShell scripts are syntactically valid (if pwsh is available)
#   * Shell scripts pass shellcheck (advisory; if shellcheck is available)
#
# Hard failures (non-zero exit): malformed JSON / XML / mobileconfig, or a
# PowerShell parse error. Shellcheck findings are reported but do not fail the
# run. For deeper, semantic checks (manifest ReferenceId uniqueness, Settings
# Catalog 0-based IDs, doc regeneration) see .github/prompts/ship.prompt.md.

set -uo pipefail

# Resolve repo root from this script's location so it runs from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Directories to ignore while scanning.
PRUNE=(-path './.git' -o -path './.venv' -o -path './.oss-compliance' -o -path './node_modules')

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

find_files() { # $1 = -name pattern
  find . \( "${PRUNE[@]}" \) -prune -o -type f -name "$1" -print
}

# --- JSON ------------------------------------------------------------------
# Use utf-8-sig so a UTF-8 BOM (common in Intune/Graph policy exports) is
# tolerated, matching how PowerShell's ConvertFrom-Json reads these files.
note "Validating JSON…"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8-sig"))' "$f" >/dev/null 2>&1; then
    ok "$f"
  else
    bad "$f (invalid JSON)"
  fi
done < <(find_files '*.json')

# --- XML manifests ---------------------------------------------------------
note "Validating XML…"
if command -v xmllint >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if xmllint --noout "$f" >/dev/null 2>&1; then
      ok "$f"
    else
      bad "$f (malformed XML)"
    fi
  done < <(find_files '*.xml')
else
  note "  (xmllint not found — skipping XML validation)"
fi

# --- mobileconfig (property lists) ----------------------------------------
note "Validating .mobileconfig…"
if command -v plutil >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if plutil -lint "$f" >/dev/null 2>&1; then
      ok "$f"
    else
      bad "$f (invalid property list)"
    fi
  done < <(find_files '*.mobileconfig')
else
  note "  (plutil not found — skipping mobileconfig validation)"
fi

# --- PowerShell syntax -----------------------------------------------------
note "Validating PowerShell syntax…"
if command -v pwsh >/dev/null 2>&1; then
  ps_errors="$(pwsh -NoProfile -Command '
    $bad = 0
    Get-ChildItem -Recurse -Filter *.ps1 -File |
      Where-Object { $_.FullName -notmatch "/(\.git|\.venv|\.oss-compliance|node_modules)/" } |
      ForEach-Object {
        $tok = $null; $err = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tok, [ref]$err) | Out-Null
        if ($err.Count -gt 0) { Write-Output $_.FullName; $bad++ }
      }
    exit $bad
  ' 2>/dev/null)"
  ps_rc=$?
  if [ "$ps_rc" -eq 0 ]; then
    ok "all .ps1 files parse"
  else
    while IFS= read -r f; do [ -n "$f" ] && bad "$f (PowerShell parse error)"; done <<< "$ps_errors"
  fi
else
  note "  (pwsh not found — skipping PowerShell validation)"
fi

# --- Shellcheck (advisory) -------------------------------------------------
note "Linting shell scripts (advisory)…"
if command -v shellcheck >/dev/null 2>&1; then
  sh_warned=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! shellcheck -S warning "$f" >/dev/null 2>&1; then
      printf '  warn %s\n' "$f"
      sh_warned=$((sh_warned + 1))
    fi
  done < <(find . \( "${PRUNE[@]}" \) -prune -o -type f \( -name '*.sh' -o -name '*.zsh' \) -print)
  [ "$sh_warned" -eq 0 ] && ok "no shellcheck warnings" || note "  ($sh_warned script(s) have shellcheck warnings — advisory only)"
else
  note "  (shellcheck not found — skipping shell lint)"
fi

# --- Context integrity (golden guard) -------------------------------------
note "Checking agent-context integrity…"
if [ -x "$REPO_ROOT/tools/check-context.sh" ]; then
  if ctx_out="$("$REPO_ROOT/tools/check-context.sh" 2>&1)"; then
    ok "agent context is consistent"
  else
    printf '%s\n' "$ctx_out" | sed 's/^/  /'
    bad "agent-context check failed (see above)"
  fi
else
  note "  (tools/check-context.sh not found — skipping)"
fi

# --- Result ----------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
  note "verify: PASS"
  exit 0
else
  note "verify: FAIL ($fail problem(s))"
  exit 1
fi
