# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# check-context.ps1 — golden guard for agent context files.
#
# Treats the repo's agent context (AGENTS.md, docs/, copilot-instructions,
# agency.toml, CODEOWNERS) as something that must stay internally consistent,
# so changes that silently rot the context are caught before they ship:
#   * every required context file exists
#   * every repo-relative markdown link in the context resolves
#   * agency.toml's verify command and readiness claims match the repo
#
# Run standalone, or via scripts/verify.ps1 which calls it as a hard check.

#Requires -Version 7.0
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot

$script:fail = 0
function Write-Bad { param([string]$Message) Write-Host "  FAIL $Message"; $script:fail++ }
function Write-Ok  { param([string]$Message) Write-Host "  ok   $Message" }

$ContextFiles = @(
    'AGENTS.md',
    '.github/copilot-instructions.md',
    'docs/conventions.md',
    'docs/architecture.md',
    'docs/testing-patterns.md',
    'agency.toml',
    '.github/CODEOWNERS'
)

# 1. Required context files exist.
Write-Host 'Context files present…'
foreach ($f in $ContextFiles) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $f)) { Write-Ok $f } else { Write-Bad "missing context file: $f" }
}

# 2. Repo-relative markdown links resolve.
Write-Host 'Markdown links resolve…'
$MarkdownFiles = @(
    'AGENTS.md',
    '.github/copilot-instructions.md',
    'docs/conventions.md',
    'docs/architecture.md',
    'docs/testing-patterns.md'
)
foreach ($md in $MarkdownFiles) {
    $mdPath = Join-Path $RepoRoot $md
    if (-not (Test-Path -LiteralPath $mdPath)) { continue }
    $dir = Split-Path -Parent $mdPath
    $content = Get-Content -LiteralPath $mdPath -Raw
    foreach ($match in [regex]::Matches($content, '\]\(([^) ]+)\)')) {
        $link = $match.Groups[1].Value
        if ($link -match '^(https?:|mailto:|#)') { continue }   # external / anchor
        $target = ($link -split '#', 2)[0]                       # strip #anchor
        if ([string]::IsNullOrEmpty($target)) { continue }
        $target = $target -replace '%20', ' '                    # decode encoded spaces
        if ($target.StartsWith('/')) {
            $resolved = Join-Path $RepoRoot ($target.TrimStart('/'))   # leading slash = repo root
        } else {
            $resolved = Join-Path $dir $target
        }
        if (-not (Test-Path -LiteralPath $resolved)) { Write-Bad "$md → broken link: $link" }
    }
}

# 3. agency.toml agrees with the repo.
Write-Host 'agency.toml consistency…'
$agencyPath = Join-Path $RepoRoot 'agency.toml'
if (Test-Path -LiteralPath $agencyPath) {
    $agency = Get-Content -LiteralPath $agencyPath -Raw
    $cmdMatch = [regex]::Match($agency, '(?m)^\s*command\s*=\s*"([^"]+)"')
    if ($cmdMatch.Success) {
        $vcmd = $cmdMatch.Groups[1].Value
        # The command may invoke an interpreter (e.g. `pwsh -File ./scripts/verify.ps1`);
        # resolve the verify script token within it, falling back to the first token.
        $tokens = $vcmd -split '\s+'
        $scriptToken = $tokens | Where-Object { $_ -match '\.(ps1|sh)$' } | Select-Object -First 1
        if (-not $scriptToken) { $scriptToken = $tokens[0] }
        $scriptPath = Join-Path $RepoRoot ($scriptToken -replace '^\./', '')
        if (Test-Path -LiteralPath $scriptPath) {
            Write-Ok "verify command resolves: $vcmd"
        } else {
            Write-Bad "agency.toml verify command does not resolve: '$vcmd'"
        }
    } else {
        Write-Bad 'agency.toml has no verify command'
    }
    if ($agency -match '(?m)^\s*agents-md\s*=\s*true' -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot 'AGENTS.md'))) {
        Write-Bad 'agency.toml claims agents-md but AGENTS.md is missing'
    }
    if ($agency -match '(?m)^\s*copilot-instructions\s*=\s*true' -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot '.github/copilot-instructions.md'))) {
        Write-Bad 'agency.toml claims copilot-instructions but the file is missing'
    }
    if ($agency -match '(?m)^\s*codeowners\s*=\s*true' -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot '.github/CODEOWNERS'))) {
        Write-Bad 'agency.toml claims codeowners but .github/CODEOWNERS is missing'
    }
} else {
    Write-Bad 'agency.toml is missing'
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host 'check-context: PASS'
    exit 0
} else {
    Write-Host "check-context: FAIL ($($script:fail) problem(s))"
    exit 1
}
