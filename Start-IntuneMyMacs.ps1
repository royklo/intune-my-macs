#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Version 7
<#
.SYNOPSIS
    Native macOS GUI frontend for mainScript.ps1 — Intune My Macs.
.DESCRIPTION
    Presents a SwiftDialog-based GUI to configure and launch the Intune My Macs
    deployment. Walk through sign-in settings, choose a policy prefix, select
    which individual manifests to deploy, then launch.

    Requires SwiftDialog to be installed:
      brew install swiftdialog/swiftdialog/dialog
      https://github.com/swiftDialog/swiftDialog/releases
.EXAMPLE
    pwsh ./Start-IntuneMyMacs.ps1
#>

$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$repoRoot   = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$mainScript = Join-Path $repoRoot 'mainScript.ps1'
$mainDialogLogoPreferredPath = Join-Path $repoRoot 'resources/Intune_256_Color.png'
$mainDialogLogoPngPath = Join-Path $repoRoot 'resources/intune-logo.png'
$mainDialogLogoJpgPath = Join-Path $repoRoot 'resources/intune-logo.jpg'
$mainDialogBackgroundPath = Join-Path $repoRoot 'resources/wallpaper.png'
$mdeOnboardingManifestPath = Join-Path $repoRoot 'mde/cfg-mde-001-onboarding.mobileconfig'

if (-not (Test-Path $mainScript)) {
    Write-Error "mainScript.ps1 not found at: $mainScript"
    exit 1
}

# ── SwiftDialog detection ─────────────────────────────────────────────────────
$dialogBin = $null
foreach ($candidate in @(
    '/usr/local/bin/dialog',
    '/opt/homebrew/bin/dialog',
    '/Applications/Dialog.app/Contents/MacOS/dialog'
)) {
    if (Test-Path $candidate) { $dialogBin = $candidate; break }
}

if (-not $dialogBin) {
    Write-Host @'

╔═══════════════════════════════════════════════════════════════╗
║   SwiftDialog not found — required for the GUI frontend       ║
╠═══════════════════════════════════════════════════════════════╣
║   Install via Homebrew:                                       ║
║     brew install swiftdialog/swiftdialog/dialog               ║
║                                                               ║
║   Or download from:                                           ║
║     https://github.com/swiftDialog/swiftDialog/releases       ║
║                                                               ║
║   After installing, re-run this script.                       ║
╚═══════════════════════════════════════════════════════════════╝

'@ -ForegroundColor Yellow
    exit 1
}

# ── Helper: run SwiftDialog from a hashtable spec, return parsed JSON ─────────
# Height must be passed as a CLI arg — SwiftDialog ignores it inside the JSON file.
function Invoke-Dialog {
    param(
        [hashtable]$Spec,
        [int]$Height = 0
    )

    # Remove height from spec so the CLI arg is the sole source of truth
    $Spec.Remove('height')

    $tmp = [System.IO.Path]::GetTempFileName() + '.json'
    try {
        $Spec | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8NoBOM
        $dialogArgs = [System.Collections.Generic.List[string]]::new()
        $dialogArgs.AddRange([string[]]@('--jsonfile', $tmp, '--json', '--moveable'))
        if ($Height -gt 0) { $dialogArgs.AddRange([string[]]@('--height', $Height)) }
        $raw = & $dialogBin @dialogArgs 2>$null
        if ($raw) { return $raw | ConvertFrom-Json -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    return $null
}

# ── Small alert dialog ────────────────────────────────────────────────────────
function Show-Alert {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon   = 'SF=exclamationmark.triangle.fill',
        [string]$Button = 'OK'
    )
    & $dialogBin `
        --title       $Title `
        --message     $Message `
        --icon        $Icon `
        --button1text $Button `
        --moveable `
        --small 2>$null | Out-Null
}

function Convert-DialogToSettingsState {
    param([object]$DialogResult)

    $rawPrefix      = $DialogResult.'Policy Prefix'
    $rawTenantId    = $DialogResult.'Tenant ID'
    $rawAssignGroup = $DialogResult.'Assign to Entra Group'

    return [PSCustomObject]@{
        Prefix                 = if ([string]::IsNullOrWhiteSpace($rawPrefix)) { '[intune-my-macs]' } else { $rawPrefix.Trim() }
        TenantId               = if ($rawTenantId) { $rawTenantId.Trim() } else { '' }
        AssignGroup            = if ($rawAssignGroup) { $rawAssignGroup.Trim() } else { '' }
        IncludeMde             = [bool]$DialogResult.'Include Microsoft Defender for Endpoint (MDE) content'
        ApplyChanges           = [bool]$DialogResult.'Apply changes  (unchecked = dry-run preview)'
        RemoveAll              = [bool]$DialogResult.'Remove all existing Intune objects with this prefix'
    }
}

function New-SettingsState {
    param(
        [string]$Prefix = '[intune-my-macs]',
        [string]$TenantId = '',
        [string]$AssignGroup = '',
        [bool]$IncludeMde = $false,
        [bool]$ApplyChanges = $false,
        [bool]$RemoveAll = $false
    )

    return [PSCustomObject]@{
        Prefix       = if ([string]::IsNullOrWhiteSpace($Prefix)) { '[intune-my-macs]' } else { $Prefix.Trim() }
        TenantId     = if ($TenantId) { $TenantId.Trim() } else { '' }
        AssignGroup  = if ($AssignGroup) { $AssignGroup.Trim() } else { '' }
        IncludeMde   = $IncludeMde
        ApplyChanges = $ApplyChanges
        RemoveAll    = $RemoveAll
    }
}

function Test-MdeSelection {
    param([Parameter(Mandatory)] [object]$Settings)

    if (-not $Settings.IncludeMde) {
        return $true
    }

    if (Test-Path -LiteralPath $mdeOnboardingManifestPath) {
        return $true
    }

    $Settings.IncludeMde = $false
    Show-Alert -Title 'MDE File Missing' `
        -Message "The MDE onboarding file was not found:`n`n$mdeOnboardingManifestPath`n`nThe MDE option has been unchecked. Add the file and try again if you want to include MDE content." `
        -Icon 'SF=exclamationmark.triangle.fill'
    return $false
}

function Invoke-NativeManifestPicker {
    param(
        [Parameter(Mandatory)] [string[]]$Items,
        [string]$Title = 'Select Manifests to Deploy',
        [string]$Prompt = 'Choose the manifests to deploy.',
        [string[]]$SelectedItems = @()
    )

    $inputPath = [System.IO.Path]::GetTempFileName() + '.json'
    $jxaPath = [System.IO.Path]::GetTempFileName() + '.js'
    $stderrPath = [System.IO.Path]::GetTempFileName() + '.err'

    $payload = @{
        title = $Title
        prompt = $Prompt
        items = @($Items)
        selectedItems = @($SelectedItems)
    }

    $jxaCode = @'
ObjC.import('Foundation');

function readPayload(path) {
    const fm = $.NSFileManager.defaultManager;
    const data = fm.contentsAtPath($(path));
    const parsed = $.NSJSONSerialization.JSONObjectWithDataOptionsError(data, 0, null);
    return ObjC.deepUnwrap(parsed);
}

function run(argv) {
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;

    const payload = readPayload(argv[0]);
    const allItems = payload.items || [];
    const selectedItems = (payload.selectedItems && payload.selectedItems.length > 0) ? payload.selectedItems.slice() : allItems.slice();

    const chosen = app.chooseFromList(allItems, {
        withTitle: payload.title,
        withPrompt: payload.prompt + ' This list scrolls automatically when needed. Command-click toggles a single manifest on or off; Shift-click selects a range.',
        defaultItems: selectedItems,
        multipleSelectionsAllowed: true,
        emptySelectionAllowed: true,
        okButtonName: 'Next →',
        cancelButtonName: '← Back to Settings'
    });

    if (chosen === false) {
        console.log(JSON.stringify({ Action: 'Back', SelectedLabels: [] }));
        return;
    }

    console.log(JSON.stringify({ Action: 'Next', SelectedLabels: chosen }));
}
'@

    try {
        $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $inputPath -Encoding utf8NoBOM
        Set-Content -Path $jxaPath -Value $jxaCode -Encoding utf8NoBOM
        $raw = & osascript -l JavaScript $jxaPath $inputPath 2>&1
        $outputText = (($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()

        if (-not $outputText) {
            throw 'Manifest picker failed: The built-in JXA manifest picker exited before returning data.'
        }

        try {
            return $outputText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Manifest picker failed: $outputText"
        }
    } finally {
        Remove-Item $inputPath -ErrorAction SilentlyContinue
        Remove-Item $jxaPath -ErrorAction SilentlyContinue
        Remove-Item $stderrPath -ErrorAction SilentlyContinue
    }
}

# ── Discover manifests (mirrors Get-DistributedManifests in mainScript.ps1) ───
function Get-GuiManifests {
    param(
        [string]$BasePath,
        [bool]  $IncludeMde = $false
    )

    $xmlFiles = Get-ChildItem -Path $BasePath -Recurse -Filter *.xml -File -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $c = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                $c -match '<MacIntuneManifest'
            } catch { $false }
        }

    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($file in $xmlFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $xdoc    = [System.Xml.Linq.XDocument]::Parse($content)
            $root    = $xdoc.Root
            if (-not $root) { continue }

            $lookup = @{}
            foreach ($el in $root.Elements()) { $lookup[$el.Name.LocalName] = $el.Value }

            $type     = $lookup['Type']
            $name     = $lookup['Name']
            $filePath = $lookup['SourceFile']
            $desc     = $lookup['Description']
            $category = $lookup['Category']

            if (-not $type -or -not $name) { continue }
            if ($filePath -match '(^|/)exports/') { continue }
            if (-not $IncludeMde -and $filePath -match '(^|/)mde/') { continue }

            $items.Add([PSCustomObject]@{
                type        = $type
                name        = $name
                description = $desc
                category    = $category
                filePath    = $filePath
            })
        } catch { <# skip unparseable manifests #> }
    }

    return , $items.ToArray()
}

# ── Phase 1: Settings dialog ──────────────────────────────────────────────────
function Show-SettingsDialog {
    param(
        [object]$Defaults = $(New-SettingsState)
    )

    $iconPath = if (Test-Path $mainDialogLogoPreferredPath) {
        $mainDialogLogoPreferredPath
    } elseif (Test-Path $mainDialogLogoPngPath) {
        $mainDialogLogoPngPath
    } elseif (Test-Path $mainDialogLogoJpgPath) {
        $mainDialogLogoJpgPath
    } else {
        'SF=laptopcomputer.and.iphone'
    }
    $spec = @{
        title       = 'Intune My Macs'
        message     = "Set your prefix and options, then continue to manifest selection."
        messagealignment = 'left'
        icon        = $iconPath
        iconsize    = 80
        buttonstyle = 'stack'
        button1text = 'Connect  →'
        button2text = 'Cancel'
        textfield  = @(
            @{ title = 'Policy Prefix';         name = 'Policy Prefix';         value = $Defaults.Prefix;      prompt = 'e.g. [POC]' }
            @{ title = 'Tenant ID';             name = 'Tenant ID';             value = $Defaults.TenantId;    prompt = 'Optional — leave blank for default' }
            @{ title = 'Assign to Entra Group'; name = 'Assign to Entra Group'; value = $Defaults.AssignGroup; prompt = 'Optional — Entra group display name' }
        )
        checkbox    = @(
            @{ label = 'Include Microsoft Defender for Endpoint (MDE) content'; checked = $Defaults.IncludeMde }
            @{ label = 'Apply changes  (unchecked = dry-run preview)';          checked = $Defaults.ApplyChanges }
            @{ label = 'Remove all existing Intune objects with this prefix'; checked = $Defaults.RemoveAll }
        )
    }
    return Invoke-Dialog -Spec $spec -Height 840
}

# ── Phase 2: Manifest selection dialog ───────────────────────────────────────
function Show-ManifestDialog {
    param([array]$Manifests)

    if (-not $Manifests -or $Manifests.Count -eq 0) {
        Show-Alert -Title 'No Manifests Found' `
            -Message 'No XML manifests were discovered in the repository.' `
            -Icon 'SF=exclamationmark.triangle'
        exit 1
    }

    $typeOrder = @('Policy', 'CustomConfig', 'Compliance', 'Script', 'CustomAttribute', 'Package', 'EnrollmentRestriction')

    $orderedManifests = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($type in $typeOrder) {
        $Manifests | Where-Object { $_.type -eq $type } | Sort-Object name | ForEach-Object { $orderedManifests.Add($_) }
    }
    $Manifests | Where-Object { $_.type -notin $typeOrder } | Sort-Object name | ForEach-Object { $orderedManifests.Add($_) }

    $labels = [System.Collections.Generic.List[string]]::new()
    $labelMap = @{}
    for ($i = 0; $i -lt $orderedManifests.Count; $i++) {
        $manifest = $orderedManifests[$i]
        $label = ('{0:D3}. [{1}] {2}' -f ($i + 1), $manifest.type, $manifest.name)
        $labels.Add($label)
        $labelMap[$label] = $manifest
    }

    $script:manifestLabelMap = $labelMap

    return Invoke-NativeManifestPicker `
        -Items $labels `
        -Title 'Select Manifests to Deploy' `
        -Prompt "Choose the manifests to deploy.`n`nThe list scrolls automatically when needed." `
        -SelectedItems $labels
}

# ── Map dialog checkbox results back to manifest objects ──────────────────────
function Get-SelectedManifests {
    param(
        [array]  $AllManifests,
        [object] $DialogResult
    )

    $selected = [System.Collections.Generic.List[PSCustomObject]]::new()
    $selectedLabels = @($DialogResult.SelectedLabels)
    if (-not $selectedLabels -or $selectedLabels.Count -eq 0) { return , @() }

    foreach ($label in $selectedLabels) {
        if ($script:manifestLabelMap.ContainsKey($label)) {
            $selected.Add($script:manifestLabelMap[$label])
        }
    }

    return , $selected.ToArray()
}

# ── Build the CLI argument list for mainScript.ps1 ───────────────────────────
function Build-CliArgs {
    param(
        [Parameter(Mandatory)] [object] $Settings,
        [array]  $SelectedManifests,
        [array]  $AllManifests
    )

    $cliArgs = [System.Collections.Generic.List[string]]::new()

    if (-not $Settings.RemoveAll -and $SelectedManifests) {
        $neededTypes = $SelectedManifests | Select-Object -ExpandProperty type | Sort-Object -Unique

        if ('Policy'                -in $neededTypes -or 'CustomConfig' -in $neededTypes) { $cliArgs.Add('--config') }
        if ('Compliance'            -in $neededTypes) { $cliArgs.Add('--compliance') }
        if ('Script'                -in $neededTypes) { $cliArgs.Add('--scripts') }
        if ('CustomAttribute'       -in $neededTypes) { $cliArgs.Add('--custom-attributes') }
        if ('Package'               -in $neededTypes) { $cliArgs.Add('--apps') }
        if ('EnrollmentRestriction' -in $neededTypes) { $cliArgs.Add('--enrollment') }
    }

    if ($Settings.IncludeMde)             { $cliArgs.Add('--mde') }
    if ($Settings.ApplyChanges)           { $cliArgs.Add('--apply') }
    if ($Settings.RemoveAll)              { $cliArgs.Add('--remove-all') }
    if ($Settings.RemoveAll)              { $cliArgs.Add('--skip-terminal-verification') }

    if (-not [string]::IsNullOrWhiteSpace($Settings.Prefix)) {
        $cliArgs.Add('--prefix'); $cliArgs.Add($Settings.Prefix)
    }
    if (-not [string]::IsNullOrWhiteSpace($Settings.TenantId)) {
        $cliArgs.Add('--tenant-id'); $cliArgs.Add($Settings.TenantId)
    }
    if (-not $Settings.RemoveAll -and -not [string]::IsNullOrWhiteSpace($Settings.AssignGroup)) {
        $cliArgs.Add('--assign-group'); $cliArgs.Add($Settings.AssignGroup)
    }

    if (-not $Settings.RemoveAll -and $SelectedManifests -and $AllManifests -and $SelectedManifests.Count -lt $AllManifests.Count) {
        $nameList = ($SelectedManifests | Select-Object -ExpandProperty name) -join ','
        $cliArgs.Add('--names')
        $cliArgs.Add($nameList)
    }

    return $cliArgs.ToArray()
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN FLOW
# ══════════════════════════════════════════════════════════════════════════════

# ── Phase 1: Settings ─────────────────────────────────────────────────────────
$settings = $null
$settingsDefaults = New-SettingsState

:settingsLoop while ($true) {
    $s = Show-SettingsDialog -Defaults $settingsDefaults
    if (-not $s -or $s.TerminalButton -in @('Cancel', 'button2')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }

    $settings = Convert-DialogToSettingsState -DialogResult $s
    $settingsDefaults = New-SettingsState -Prefix $settings.Prefix -TenantId $settings.TenantId -AssignGroup $settings.AssignGroup -IncludeMde $settings.IncludeMde -ApplyChanges $settings.ApplyChanges -RemoveAll $settings.RemoveAll

    if (-not (Test-MdeSelection -Settings $settingsDefaults)) {
        $settings = $settingsDefaults
        continue
    }

    $settings = $settingsDefaults

    break settingsLoop
}

if ($settings.RemoveAll) {
    :cleanupConfirmLoop while ($true) {
        $removeModeLabel = if ($settings.ApplyChanges) {
            '🟢 **APPLY** — matching Intune objects will be deleted'
        } else {
            '🟡 **DRY-RUN** — no deletions will be performed'
        }
        $removeTenantLine = if ($settings.TenantId) { "`n**Tenant ID:** $($settings.TenantId)" } else { '' }
        $removeMsg = "**Mode:** $removeModeLabel`n**Prefix:** $($settings.Prefix)$removeTenantLine`n`nThis will run mainScript.ps1 with `--remove-all` and scan Intune for objects using the configured prefix."
        $removeSpec = @{
            title       = 'Confirm Cleanup Mode'
            message     = $removeMsg
            icon        = 'SF=trash'
            button1text = if ($settings.ApplyChanges) { 'Remove Matching Objects' } else { 'Preview Matching Objects' }
            button2text = '← Back to Settings'
        }
        $removeConfirm = Invoke-Dialog -Spec $removeSpec
        if (-not $removeConfirm -or $removeConfirm.TerminalButton -in @('Cancel')) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            exit 0
        }
        if ($removeConfirm.TerminalButton -eq 'button2') {
            while ($true) {
                $s3 = Show-SettingsDialog -Defaults $settingsDefaults
                if (-not $s3 -or $s3.TerminalButton -in @('Cancel', 'button2')) {
                    Write-Host 'Cancelled.' -ForegroundColor Yellow
                    exit 0
                }
                $settingsDefaults = Convert-DialogToSettingsState -DialogResult $s3
                if (-not (Test-MdeSelection -Settings $settingsDefaults)) {
                    continue
                }
                $settings = $settingsDefaults
                if (-not $settings.RemoveAll) { break cleanupConfirmLoop }
                continue cleanupConfirmLoop
            }
            continue cleanupConfirmLoop
        }

        $cliArgs = Build-CliArgs -Settings $settings -SelectedManifests @() -AllManifests @()

        Write-Host ''
        Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Cyan
        Write-Host '  Intune My Macs — Launching Cleanup'              -ForegroundColor Cyan
        Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Cyan
        Write-Host "  pwsh mainScript.ps1 $($cliArgs -join ' ')" -ForegroundColor DarkGray
        Write-Host ''

        & pwsh -File $mainScript @cliArgs
        $exitCode = $LASTEXITCODE

        Write-Host ''
        if ($exitCode -eq 0) {
            Write-Host '✓ Cleanup run finished successfully.' -ForegroundColor Green
            & $dialogBin `
                --title       'Cleanup Complete' `
                --message     'The cleanup run finished successfully. Review the terminal output for details.' `
                --icon        'SF=checkmark.circle.fill' `
                --button1text 'Done' `
                --moveable `
                --small 2>$null | Out-Null
        } else {
            Write-Host "✗ Cleanup exited with code $exitCode." -ForegroundColor Red
            Show-Alert -Title 'Cleanup Finished' `
                -Message "Cleanup completed with exit code $exitCode.`n`nReview the terminal output for details." `
                -Icon 'SF=xmark.circle.fill'
        }
        return
    }
}

# ── Discover manifests ────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'Discovering manifests in repository...' -ForegroundColor Cyan
$allManifests = Get-GuiManifests -BasePath $repoRoot -IncludeMde $settings.IncludeMde
Write-Host "Found $($allManifests.Count) manifests." -ForegroundColor Green

if ($allManifests.Count -eq 0) {
    Show-Alert -Title 'No Manifests Found' `
        -Message 'No XML manifests were found in the repository. Ensure the repo is complete.' `
        -Icon 'SF=exclamationmark.triangle'
    exit 1
}

# ── Phase 2 + Confirmation loop ───────────────────────────────────────────────
$selected = $null

:manifestLoop while ($true) {
    $mr = Show-ManifestDialog -Manifests $allManifests

    # Back → return to settings
    if (-not $mr -or $mr.Action -eq 'Back') {
        # Re-run from settings
        :innerSettings while ($true) {
            $s2 = Show-SettingsDialog -Defaults $settingsDefaults
            if (-not $s2 -or $s2.TerminalButton -in @('Cancel', 'button2')) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                exit 0
            }
            $settingsDefaults = Convert-DialogToSettingsState -DialogResult $s2
            if (-not (Test-MdeSelection -Settings $settingsDefaults)) {
                continue
            }
            $settings = $settingsDefaults
            if ($settings.RemoveAll) {
                Show-Alert -Title 'Mode Change Needed' -Message 'Remove-all mode must be started from Settings. Re-run the launcher and choose cleanup mode there.' -Icon 'SF=arrow.uturn.backward.circle'
                continue
            }
            break innerSettings
        }
        # Re-discover in case MDE toggle changed
        Write-Host 'Re-discovering manifests...' -ForegroundColor Cyan
        $allManifests = Get-GuiManifests -BasePath $repoRoot -IncludeMde $settings.IncludeMde
        Write-Host "Found $($allManifests.Count) manifests." -ForegroundColor Green
        continue manifestLoop
    }

    # Cancelled
    if ($mr.Action -eq 'Cancel') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }

    $selected = Get-SelectedManifests -AllManifests $allManifests -DialogResult $mr

    if ($selected.Count -eq 0) {
        Show-Alert -Title 'Nothing Selected' `
            -Message 'No manifests were selected. Please check at least one manifest to continue.' `
            -Icon 'SF=exclamationmark.triangle'
        continue manifestLoop
    }

    # ── Confirmation dialog ───────────────────────────────────────────────────
    $modeLabel  = if ($settings.ApplyChanges) {
        '🟢 **APPLY** — changes will be pushed to Intune'
    } else {
        '🟡 **DRY-RUN** — no changes will be made (preview only)'
    }
    $tenantLine = if ($settings.TenantId)    { "`n**Tenant ID:** $($settings.TenantId)"       } else { '' }
    $groupLine  = if ($settings.AssignGroup) { "`n**Assign group:** $($settings.AssignGroup)" } else { '' }
    $flags = @()
    if ($settings.IncludeMde) { $flags += 'MDE included' }
    $flagsLine = if ($flags.Count -gt 0) { "`n**Extra flags:** $($flags -join ', ')" } else { '' }

    $manifestList = ($selected | Select-Object -ExpandProperty name | ForEach-Object { "  • $_" }) -join "`n"

    $confirmMsg = "**Mode:** $modeLabel`n**Prefix:** $($settings.Prefix)$tenantLine$groupLine$flagsLine`n`n**Manifests selected:** $($selected.Count) of $($allManifests.Count)`n`n$manifestList"

    $confirmSpec = @{
        title       = 'Confirm Deployment'
        message     = $confirmMsg
        icon        = if ($settings.ApplyChanges) { 'SF=arrow.up.circle.fill' } else { 'SF=eye.fill' }
        button1text = if ($settings.ApplyChanges) { 'Deploy to Intune' } else { 'Start Dry-Run Preview' }
        button2text = '← Back to Selection'
    }

    $cr = Invoke-Dialog -Spec $confirmSpec

    if (-not $cr -or $cr.TerminalButton -in @('Cancel')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }
    if ($cr.TerminalButton -eq 'button2') {
        continue manifestLoop   # back to manifest selection
    }

    break manifestLoop  # button1 — proceed
}

# ── Build args and launch mainScript.ps1 ─────────────────────────────────────
$cliArgs = Build-CliArgs `
    -Settings          $settings `
    -SelectedManifests $selected `
    -AllManifests      $allManifests

Write-Host ''
Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  Intune My Macs — Launching Deployment'            -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  pwsh mainScript.ps1 $($cliArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ''

& pwsh -File $mainScript @cliArgs
$exitCode = $LASTEXITCODE

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host '✓ Deployment finished successfully.' -ForegroundColor Green
    & $dialogBin `
        --title       'Deployment Complete' `
        --message     'The deployment finished successfully. Review the terminal output for details.' `
        --icon        'SF=checkmark.circle.fill' `
        --button1text 'Done' `
        --small 2>$null | Out-Null
} else {
    Write-Host "✗ Deployment exited with code $exitCode." -ForegroundColor Red
    Show-Alert -Title 'Deployment Finished' `
        -Message "Deployment completed with exit code $exitCode.`n`nReview the terminal output for details." `
        -Icon 'SF=xmark.circle.fill'
}
