# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# verify.ps1 — one-command local validation loop for intune-my-macs.
#
# Validates that every committed artifact is well-formed so a change can be
# checked locally before pushing:
#   * JSON policies parse (UTF-8 BOM tolerated, as in Intune/Graph exports)
#   * XML manifests parse
#   * .mobileconfig profiles are valid property lists (plutil when available,
#     otherwise an XML well-formedness check)
#   * PowerShell scripts are syntactically valid
#   * Shell scripts pass shellcheck (advisory; when shellcheck is available)
#   * Agent context stays internally consistent (scripts/check-context.ps1)
#
# Hard failures (non-zero exit): malformed JSON / XML / mobileconfig, a
# PowerShell parse error, or a context-integrity failure. Shellcheck findings
# are reported but do not fail the run. For deeper, semantic checks (manifest
# ReferenceId uniqueness, Settings Catalog 0-based IDs, doc regeneration) see
# .github/prompts/ship.prompt.md.
#
# Cross-platform: runs under PowerShell 7+ on macOS, Linux, and Windows.
# External linters (plutil, shellcheck) are used only when present and are
# skipped gracefully otherwise.

#Requires -Version 7.0
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Resolve repo root from this script's location so it runs from any cwd.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $RepoRoot

$script:fail = 0
function Write-Note { param([string]$Message) Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host "  ok   $Message" }
function Write-Fail { param([string]$Message) Write-Host "  FAIL $Message"; $script:fail++ }

# Directories to ignore while scanning.
$PruneRegex = '[\\/](?:\.git|\.venv|\.oss-compliance|node_modules)[\\/]'

function Get-Artifact {
    param([Parameter(Mandatory)][string[]]$Include)
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Include $Include -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $PruneRegex }
}

function Get-RelPath {
    param([Parameter(Mandatory)][string]$FullName)
    './' + ([System.IO.Path]::GetRelativePath($RepoRoot, $FullName) -replace '\\', '/')
}

# --- JSON ------------------------------------------------------------------
# ReadAllText auto-detects and strips a UTF-8 BOM (common in Intune/Graph
# policy exports), matching how PowerShell's ConvertFrom-Json reads these.
Write-Note 'Validating JSON…'
foreach ($file in Get-Artifact '*.json') {
    $rel = Get-RelPath $file.FullName
    try {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty document' }
        $null = $text | ConvertFrom-Json -ErrorAction Stop
        Write-Ok $rel
    } catch {
        Write-Fail "$rel (invalid JSON)"
    }
}

# --- XML manifests ---------------------------------------------------------
Write-Note 'Validating XML…'
foreach ($file in Get-Artifact '*.xml') {
    $rel = Get-RelPath $file.FullName
    try {
        (New-Object System.Xml.XmlDocument).Load($file.FullName)
        Write-Ok $rel
    } catch {
        Write-Fail "$rel (malformed XML)"
    }
}

# --- mobileconfig (property lists) ----------------------------------------
Write-Note 'Validating .mobileconfig…'
$hasPlutil = [bool](Get-Command plutil -ErrorAction SilentlyContinue)
foreach ($file in Get-Artifact '*.mobileconfig') {
    $rel = Get-RelPath $file.FullName
    if ($hasPlutil) {
        & plutil -lint $file.FullName *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok $rel } else { Write-Fail "$rel (invalid property list)" }
    } else {
        # plutil is macOS-only; a .mobileconfig is an XML plist, so fall back
        # to an XML well-formedness check on other platforms (e.g. CI).
        try { (New-Object System.Xml.XmlDocument).Load($file.FullName); Write-Ok "$rel (xml-checked; plutil unavailable)" }
        catch { Write-Fail "$rel (invalid property list)" }
    }
}

# --- PowerShell syntax -----------------------------------------------------
Write-Note 'Validating PowerShell syntax…'
$psFail = 0
foreach ($file in Get-Artifact '*.ps1') {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Write-Fail ('{0} (PowerShell parse error)' -f (Get-RelPath $file.FullName))
        $psFail++
    }
}
if ($psFail -eq 0) { Write-Ok 'all .ps1 files parse' }

# --- Shellcheck (advisory) -------------------------------------------------
Write-Note 'Linting shell scripts (advisory)…'
if (Get-Command shellcheck -ErrorAction SilentlyContinue) {
    $warned = 0
    foreach ($file in Get-Artifact @('*.sh', '*.zsh')) {
        & shellcheck -S warning $file.FullName *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host ('  warn {0}' -f (Get-RelPath $file.FullName)); $warned++ }
    }
    if ($warned -eq 0) { Write-Ok 'no shellcheck warnings' }
    else { Write-Note "  ($warned script(s) have shellcheck warnings — advisory only)" }
} else {
    Write-Note '  (shellcheck not found — skipping shell lint)'
}

# --- Context integrity (golden guard) -------------------------------------
Write-Note 'Checking agent-context integrity…'
$ctxScript = Join-Path $PSScriptRoot 'check-context.ps1'
if (Test-Path -LiteralPath $ctxScript) {
    $ctxOut = & pwsh -NoProfile -File $ctxScript 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'agent context is consistent'
    } else {
        $ctxOut | ForEach-Object { Write-Host "  $_" }
        Write-Fail 'agent-context check failed (see above)'
    }
} else {
    Write-Note '  (scripts/check-context.ps1 not found — skipping)'
}

# --- Result ----------------------------------------------------------------
Write-Host ''
if ($script:fail -eq 0) {
    Write-Note 'verify: PASS'
    exit 0
} else {
    Write-Note "verify: FAIL ($($script:fail) problem(s))"
    exit 1
}
