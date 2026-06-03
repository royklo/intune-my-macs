<#!
.SYNOPSIS
Lists every macOS Intune object (configuration, compliance, scripts, custom attributes, apps) assigned to All Devices or All Users.

.DESCRIPTION
Queries Microsoft Graph (beta) for:
  * Settings Catalog configurationPolicies (platforms includes macOS)
  * Classic deviceConfigurations (odata type starts with #microsoft.graph.macOS) — includes macOSCustomConfiguration
  * deviceCompliancePolicies (#microsoft.graph.macOSCompliancePolicy)
  * deviceShellScripts (macOS-only endpoint)
  * deviceCustomAttributeShellScripts (macOS-only endpoint)
  * mobileApps with any #microsoft.graph.macOS* type (PKG, LOB, DMG, Office, Edge, Defender, MDATP)
For each object, retrieves its assignments and flags whether it is targeted to:
  - All Devices (allDevicesAssignmentTarget)
  - All Users (allLicensedUsersAssignmentTarget)
Outputs a table and (optionally) JSON/CSV.

.PARAMETER OutputJson
Also emit raw JSON array to stdout (after table).

.PARAMETER CsvPath
Optional path to write CSV export of results.

.EXAMPLE
./Get-MacOSGlobalAssignments.ps1

.EXAMPLE
./Get-MacOSGlobalAssignments.ps1 -OutputJson -CsvPath ./mac-global.csv

.NOTES
Requires Microsoft.Graph.Authentication (Connect-MgGraph) and sufficient Intune permissions (DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All).
#>

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

param(
    [switch]$OutputJson,
    [string]$CsvPath,
    [switch]$Unassign,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Ensure-GraphConnection {
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        Write-Error "Microsoft Graph PowerShell SDK not installed. Install-Module Microsoft.Graph -Scope CurrentUser"
        exit 1
    }
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if (-not $ctx) { throw 'No context' }
    } catch {
        Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
        Connect-MgGraph -Scopes @(
            'DeviceManagementConfiguration.Read.All',
            'DeviceManagementApps.Read.All'
        ) | Out-Null
    }
}

function Invoke-GraphAllPages {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [hashtable]$Headers,
        [int]$PageSize = 100
    )
    $results = @()
    $next = "$Uri`?`$top=$PageSize"
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers
        if ($resp.value) { $results += $resp.value }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

function Get-AssignmentsForObject {
    param(
        [string]$Uri # full assignments URI
    )
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri
        return $resp.value
    } catch {
        Write-Warning "Failed to query assignments: $Uri : $($_.Exception.Message)"
        return @()
    }
}

Ensure-GraphConnection

$betaBase = 'https://graph.microsoft.com/beta'

Write-Host 'Collecting configurationPolicies (settings catalog macOS)...' -ForegroundColor Cyan
$configPolicies = Invoke-GraphAllPages -Uri "$betaBase/deviceManagement/configurationPolicies" | Where-Object { $_.platforms -match 'macOS' }

Write-Host 'Collecting classic deviceConfigurations (macOS types)...' -ForegroundColor Cyan
$deviceConfigs = Invoke-GraphAllPages -Uri "$betaBase/deviceManagement/deviceConfigurations" | Where-Object { $_.'@odata.type' -like '#microsoft.graph.macOS*' }

Write-Host 'Collecting deviceCompliancePolicies (macOS)...' -ForegroundColor Cyan
$compliancePolicies = Invoke-GraphAllPages -Uri "$betaBase/deviceManagement/deviceCompliancePolicies" | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.macOSCompliancePolicy' }

Write-Host 'Collecting deviceShellScripts (macOS shell scripts)...' -ForegroundColor Cyan
# /assignments sub-endpoint 400s on some tenants — prefer $expand=assignments on the list.
try {
    $shellScriptsResponse = Invoke-MgGraphRequest -Method GET -Uri "$betaBase/deviceManagement/deviceShellScripts?`$top=999&`$expand=assignments"
    $deviceShellScripts = $shellScriptsResponse.value
} catch {
    Write-Warning "Failed expanded retrieval of deviceShellScripts: $($_.Exception.Message). Falling back to basic list (assignments may be incomplete)."
    $deviceShellScripts = Invoke-GraphAllPages -Uri "$betaBase/deviceManagement/deviceShellScripts"
}

Write-Host 'Collecting deviceCustomAttributeShellScripts (macOS)...' -ForegroundColor Cyan
# Same /assignments quirk as deviceShellScripts — use $expand.
try {
    $customAttrResponse = Invoke-MgGraphRequest -Method GET -Uri "$betaBase/deviceManagement/deviceCustomAttributeShellScripts?`$top=999&`$expand=assignments"
    $customAttrScripts = $customAttrResponse.value
} catch {
    Write-Warning "Failed expanded retrieval of deviceCustomAttributeShellScripts: $($_.Exception.Message). Falling back to basic list (assignments may be incomplete)."
    $customAttrScripts = Invoke-GraphAllPages -Uri "$betaBase/deviceManagement/deviceCustomAttributeShellScripts"
}

Write-Host 'Collecting macOS mobileApps (all macOS app types)...' -ForegroundColor Cyan
$mobileApps = Invoke-GraphAllPages -Uri "$betaBase/deviceAppManagement/mobileApps" | Where-Object { $_.'@odata.type' -like '#microsoft.graph.macOS*' }

$rows = @()

# Settings catalog policies assignments
foreach ($p in $configPolicies) {
    $assignments = Get-AssignmentsForObject -Uri "$betaBase/deviceManagement/configurationPolicies/$($p.id)/assignments"
    $isAllDevices = $assignments.target.'@odata.type' -contains '#microsoft.graph.allDevicesAssignmentTarget'
    $isAllUsers   = $assignments.target.'@odata.type' -contains '#microsoft.graph.allLicensedUsersAssignmentTarget'
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type        = 'SettingsCatalogPolicy'
            Name        = $p.name
            Id          = $p.id
            AllDevices  = $isAllDevices
            AllUsers    = $isAllUsers
            Intent      = ''
            Platforms   = ($p.platforms -join ',')
        }
    }
}

# Classic / custom device configurations
foreach ($c in $deviceConfigs) {
    $assignments = Get-AssignmentsForObject -Uri "$betaBase/deviceManagement/deviceConfigurations/$($c.id)/assignments"
    $isAllDevices = $false; $isAllUsers = $false
    foreach ($a in $assignments) {
        $t = $a.target.'@odata.type'
        if ($t -eq '#microsoft.graph.allDevicesAssignmentTarget') { $isAllDevices = $true }
        if ($t -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') { $isAllUsers = $true }
    }
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type       = 'DeviceConfiguration'
            Name       = $c.displayName
            Id         = $c.id
            AllDevices = $isAllDevices
            AllUsers   = $isAllUsers
            Intent     = ''
            Platforms  = 'macOS'
        }
    }
}

# Compliance policies
foreach ($cp in $compliancePolicies) {
    $assignments = Get-AssignmentsForObject -Uri "$betaBase/deviceManagement/deviceCompliancePolicies/$($cp.id)/assignments"
    $isAllDevices = $false; $isAllUsers = $false
    foreach ($a in $assignments) {
        $t = $a.target.'@odata.type'
        if ($t -eq '#microsoft.graph.allDevicesAssignmentTarget') { $isAllDevices = $true }
        if ($t -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') { $isAllUsers = $true }
    }
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type       = 'CompliancePolicy'
            Name       = $cp.displayName
            Id         = $cp.id
            AllDevices = $isAllDevices
            AllUsers   = $isAllUsers
            Intent     = ''
            Platforms  = 'macOS'
        }
    }
}

# Shell scripts (assignments already expanded when possible)
foreach ($s in $deviceShellScripts) {
    # Invoke-MgGraphRequest returns a Hashtable; direct access on the key
    # works and yields $null when absent.
    $expandedAssignments = if ($s.assignments) { $s.assignments } else {
        try { (Invoke-MgGraphRequest -Method GET -Uri "$betaBase/deviceManagement/deviceShellScripts/$($s.id)/assignments").value }
        catch { @() }
    }
    $isAllDevices = $false; $isAllUsers = $false
    foreach ($a in $expandedAssignments) {
        $t = $a.target.'@odata.type'
        if ($t -eq '#microsoft.graph.allDevicesAssignmentTarget') { $isAllDevices = $true }
        if ($t -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') { $isAllUsers = $true }
    }
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type       = 'ShellScript'
            Name       = $s.displayName
            Id         = $s.id
            AllDevices = $isAllDevices
            AllUsers   = $isAllUsers
            Intent     = ''
            Platforms  = 'macOS'
        }
    }
}

# Custom attribute shell scripts (assignments already expanded when possible)
foreach ($ca in $customAttrScripts) {
    $expandedAssignments = if ($ca.assignments) { $ca.assignments } else {
        try { (Invoke-MgGraphRequest -Method GET -Uri "$betaBase/deviceManagement/deviceCustomAttributeShellScripts/$($ca.id)/assignments").value }
        catch { @() }
    }
    $isAllDevices = $false; $isAllUsers = $false
    foreach ($a in $expandedAssignments) {
        $t = $a.target.'@odata.type'
        if ($t -eq '#microsoft.graph.allDevicesAssignmentTarget') { $isAllDevices = $true }
        if ($t -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') { $isAllUsers = $true }
    }
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type       = 'CustomAttribute'
            Name       = $ca.displayName
            Id         = $ca.id
            AllDevices = $isAllDevices
            AllUsers   = $isAllUsers
            Intent     = ''
            Platforms  = 'macOS'
        }
    }
}

# macOS Apps
foreach ($app in $mobileApps) {
    $assignments = Get-AssignmentsForObject -Uri "$betaBase/deviceAppManagement/mobileApps/$($app.id)/assignments"
    $isAllDevices = $false; $isAllUsers = $false
    $intents = New-Object System.Collections.Generic.HashSet[string]
    foreach ($a in $assignments) {
        $t = $a.target.'@odata.type'
        if ($t -eq '#microsoft.graph.allDevicesAssignmentTarget') {
            $isAllDevices = $true
            if ($a.intent) { [void]$intents.Add([string]$a.intent) }
        }
        if ($t -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') {
            $isAllUsers = $true
            if ($a.intent) { [void]$intents.Add([string]$a.intent) }
        }
    }
    if ($isAllDevices -or $isAllUsers) {
        $rows += [pscustomobject]@{
            Type       = 'macOSApp'
            Name       = $app.displayName
            Id         = $app.id
            AllDevices = $isAllDevices
            AllUsers   = $isAllUsers
            Intent     = (($intents | Sort-Object) -join ',')
            Platforms  = 'macOS'
        }
    }
}

if (-not $rows) {
    Write-Host 'No macOS objects assigned to All Devices or All Users.' -ForegroundColor Yellow
    return
}

$rows | Sort-Object Type, Name | Format-Table -AutoSize

if ($CsvPath) {
    try {
        $rows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
        Write-Host "CSV written to $CsvPath" -ForegroundColor Green
    } catch { Write-Warning "Failed to write CSV: $($_.Exception.Message)" }
}

if ($OutputJson) {
    $rows | ConvertTo-Json -Depth 4
}

if ($Unassign) {
    Write-Host "\n-- Unassign mode: removing All Devices / All Users assignments --" -ForegroundColor Magenta
    if (-not $Force) {
        $resp = Read-Host "Type YES to continue (this will remove global assignments)"
        if ($resp -ne 'YES') { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    foreach ($item in $rows) {
        switch ($item.Type) {
            'SettingsCatalogPolicy' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceManagement/configurationPolicies/$id/assignments"
                $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{ target = $a.target }
                }
                $body = @{ assignments = $remaining } | ConvertTo-Json -Depth 6
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceManagement/configurationPolicies/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from SettingsCatalogPolicy $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for configurationPolicy $id : $($_.Exception.Message)" }
            }
            'DeviceConfiguration' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceManagement/deviceConfigurations/$id/assignments"
                $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{ target = $a.target }
                }
                $body = @{ assignments = $remaining } | ConvertTo-Json -Depth 6
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceManagement/deviceConfigurations/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from DeviceConfiguration $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for deviceConfiguration $id : $($_.Exception.Message)" }
            }
            'macOSApp' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceAppManagement/mobileApps/$id/assignments"
                $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{
                        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                        intent        = $a.intent
                        target        = $a.target
                    }
                }
                $body = @{ mobileAppAssignments = $remaining } | ConvertTo-Json -Depth 8
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceAppManagement/mobileApps/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from macOSApp $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for macOSApp $id : $($_.Exception.Message)" }
            }
            'ShellScript' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceManagement/deviceShellScripts/$id/assignments"
                $all = @()
                try { $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value } catch { }
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{
                        '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
                        target        = $a.target
                    }
                }
                $body = @{ deviceManagementScriptAssignments = $remaining } | ConvertTo-Json -Depth 6
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceManagement/deviceShellScripts/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from ShellScript $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for ShellScript $id : $($_.Exception.Message)" }
            }
            'CustomAttribute' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceManagement/deviceCustomAttributeShellScripts/$id/assignments"
                $all = @()
                try { $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value } catch { }
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{
                        '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
                        target        = $a.target
                    }
                }
                $body = @{ deviceManagementScriptAssignments = $remaining } | ConvertTo-Json -Depth 6
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceManagement/deviceCustomAttributeShellScripts/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from CustomAttribute $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for CustomAttribute $id : $($_.Exception.Message)" }
            }
            'CompliancePolicy' {
                $id = $item.Id
                $assignUri = "$betaBase/deviceManagement/deviceCompliancePolicies/$id/assignments"
                $all = (Invoke-MgGraphRequest -Method GET -Uri $assignUri).value
                if (-not $all) { continue }
                $remaining = @()
                foreach ($a in $all) {
                    $t = $a.target.'@odata.type'
                    if ($t -in '#microsoft.graph.allDevicesAssignmentTarget','#microsoft.graph.allLicensedUsersAssignmentTarget') { continue }
                    $remaining += @{
                        '@odata.type' = '#microsoft.graph.deviceCompliancePolicyAssignment'
                        target        = $a.target
                    }
                }
                $body = @{ assignments = $remaining } | ConvertTo-Json -Depth 6
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$betaBase/deviceManagement/deviceCompliancePolicies/$id/assign" -Body $body | Out-Null
                    Write-Host "Removed global assignment(s) from CompliancePolicy $id" -ForegroundColor Green
                } catch { Write-Warning "Failed to update assignments for CompliancePolicy $id : $($_.Exception.Message)" }
            }
        }
    }
    Write-Host "Unassign operation complete." -ForegroundColor Magenta
}
