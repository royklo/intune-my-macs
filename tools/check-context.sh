#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# check-context.sh — golden guard for agent context files.
#
# Treats the repo's agent context (AGENTS.md, docs/, copilot-instructions,
# agency.toml, CODEOWNERS) as something that must stay internally consistent,
# so changes that silently rot the context are caught before they ship:
#   * every required context file exists
#   * every repo-relative markdown link in the context resolves
#   * agency.toml's verify command and readiness claims match the repo
#
# Run standalone, or via tools/verify.sh which calls it as a hard check.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail=0
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
ok()  { printf '  ok   %s\n' "$*"; }

# 1. Required context files exist.
echo "Context files present…"
for f in AGENTS.md .github/copilot-instructions.md docs/conventions.md \
         docs/architecture.md docs/testing-patterns.md agency.toml .github/CODEOWNERS; do
  [ -f "$f" ] && ok "$f" || bad "missing context file: $f"
done

# 2. Repo-relative markdown links resolve.
echo "Markdown links resolve…"
for md in AGENTS.md .github/copilot-instructions.md docs/conventions.md \
          docs/architecture.md docs/testing-patterns.md; do
  [ -f "$md" ] || continue
  dir="$(dirname "$md")"
  while IFS= read -r link; do
    case "$link" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    target="${link%%#*}"          # strip #anchor
    [ -z "$target" ] && continue
    target="${target//%20/ }"     # decode encoded spaces
    if [ "${target#/}" != "$target" ]; then
      resolved=".${target}"        # leading slash = repo root
    else
      resolved="$dir/$target"
    fi
    [ -e "$resolved" ] || bad "$md → broken link: $link"
  done < <(grep -oE '\]\([^) ]+\)' "$md" | sed -E 's/^\]\(//; s/\)$//')
done

# 3. agency.toml agrees with the repo.
echo "agency.toml consistency…"
if [ -f agency.toml ]; then
  vcmd="$(grep -E '^command[[:space:]]*=' agency.toml | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
  vscript="${vcmd%% *}"           # first token, e.g. ./tools/verify.sh
  if [ -n "$vscript" ] && [ -x "$vscript" ]; then
    ok "verify command resolves: $vcmd"
  else
    bad "agency.toml verify command does not resolve: '$vcmd'"
  fi
  grep -qE '^agents-md[[:space:]]*=[[:space:]]*true' agency.toml && { [ -f AGENTS.md ] || bad "agency.toml claims agents-md but AGENTS.md is missing"; }
  grep -qE '^copilot-instructions[[:space:]]*=[[:space:]]*true' agency.toml && { [ -f .github/copilot-instructions.md ] || bad "agency.toml claims copilot-instructions but the file is missing"; }
  grep -qE '^codeowners[[:space:]]*=[[:space:]]*true' agency.toml && { [ -f .github/CODEOWNERS ] || bad "agency.toml claims codeowners but .github/CODEOWNERS is missing"; }
else
  bad "agency.toml is missing"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "check-context: PASS"
  exit 0
else
  echo "check-context: FAIL ($fail problem(s))"
  exit 1
fi
