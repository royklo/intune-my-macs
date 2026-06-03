# Get-IntuneAgentProcessingOrder.ps1

A PowerShell script that lists macOS shell scripts and apps deployed through Microsoft Intune, showing which items are assigned to devices.

## Overview

This script provides a quick inventory of macOS-specific Intune deployments by querying Microsoft Graph for:

- **Device Shell Scripts** - macOS shell scripts with active assignments
- **macOS Apps** - DMG and PKG apps that are assigned to devices

The output is sorted alphabetically by display name, making it easy to see the logical "processing order" of deployments that follow a naming convention.

## Requirements

- **PowerShell 7+** (cross-platform) or Windows PowerShell 5.1
- **Microsoft Graph PowerShell SDK** - `Microsoft.Graph.Authentication` module
- **Permissions**:
  - `DeviceManagementScripts.Read.All` (for shell scripts)
  - `DeviceManagementApps.Read.All` (for apps)

## Usage

### Basic Usage

```powershell
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1
```

Output:

```text
Items returned: 12

 1. [Script] scr-app-002-install-homebrew (Assigned: Yes)
 2. [App] Company Portal (Assigned: Yes)
 3. [App] Microsoft Edge (Assigned: Yes)
 4. [Script] scr-cfg-001-set-timezone (Assigned: Yes)
 5. [Script] scr-cfg-002-configure-dock (Assigned: Yes)
...
```

### Parameters

| Parameter | Type   | Required | Description                                                                           |
| --------- | ------ | -------- | ------------------------------------------------------------------------------------- |
| `-Prefix` | String | No       | Filter results to items whose display name starts with this prefix (case-insensitive) |

### Examples

#### List All Assigned Scripts and Apps

```powershell
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1
```

#### Filter by Naming Prefix

```powershell
# Show only items starting with "scr-" (scripts following naming convention)
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1 -Prefix "scr-"
```

```powershell
# Show only items starting with "app-"
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1 -Prefix "app-"
```

## Output

### Color-Coded Display

The script uses ANSI color codes for easy visual identification:

| Tag        | Color  | Description            |
| ---------- | ------ | ---------------------- |
| `[Script]` | Yellow | macOS shell script     |
| `[App]`    | Green  | macOS app (DMG or PKG) |

### Output Format

```text
{number}. {type} {displayName} (Assigned: {Yes|No})
```

Each line shows:

- **Sequential number** - Position in the sorted list
- **Type tag** - `[Script]` or `[App]`
- **Display name** - Name of the script or app in Intune
- **Assigned status** - Whether the item has active assignments

## How It Works

1. **Connects to Microsoft Graph** with required scopes
2. **Retrieves shell scripts** using `$expand=assignments` to get assignment data in one call
3. **Filters scripts** to only those with at least one assignment
4. **Retrieves macOS apps** (DMG and PKG types) that have `isAssigned = true`
5. **Combines and sorts** all items alphabetically by display name
6. **Applies prefix filter** if `-Prefix` parameter is specified
7. **Displays results** with color-coded type indicators

## Use Cases

### Verify Deployment Order

If you use a naming convention like `scr-001-`, `scr-002-`, etc., this script shows the effective processing order:

```powershell
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1 -Prefix "scr-"
```

### Quick Inventory

Get a fast count and list of all macOS deployments:

```powershell
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1
# Items returned: 47
```

### Audit Assigned Items

Verify that scripts and apps are properly assigned before deployment:

```powershell
# Check if all "scr-mde-" scripts are assigned
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1 -Prefix "scr-mde-"
```

## Authentication

The script automatically connects to Microsoft Graph:

```powershell
Connect-MgGraph -Scopes "DeviceManagementScripts.Read.All,DeviceManagementApps.Read.All" -NoWelcome
```

On first run, you'll be prompted to authenticate. Subsequent runs use cached credentials.

### Pre-authenticate

```powershell
# Connect manually first if needed
Connect-MgGraph -Scopes @(
    'DeviceManagementScripts.Read.All',
    'DeviceManagementApps.Read.All'
)

# Then run the script
pwsh ./tools/Get-IntuneAgentProcessingOrder.ps1
```

## Limitations

- **Only shows assigned items** - Unassigned scripts and apps are filtered out
- **No assignment details** - Shows whether assigned, but not which groups
- **App assignment detection** - Uses `isAssigned` property rather than querying full assignment details
- **macOS only** - Filters to macOS-specific app types (DMG, PKG) and shell scripts

## Troubleshooting

| Issue | Solution |
| ------- | ---------- |
| "Items returned: 0" | No assigned scripts/apps found, or `-Prefix` filter too restrictive |
| Authentication errors | Run `Connect-MgGraph` manually with required scopes |
| Colors not displaying | Terminal may not support ANSI escape codes; output still functional |
| Missing scripts | Only scripts with assignments are returned |

## Related Tools

- [Export-MacOSConfigPolicies.ps1](Export-MacOSConfigPolicies.md) - Export configuration policies
- [Get-MacOSGlobalAssignments.ps1](Get-MacOSGlobalAssignments.md) - Find global assignments
- [Find-DuplicatePayloadSettings.ps1](Find-DuplicatePayloadSettings.md) - Find duplicate settings

## Notes

- Uses Microsoft Graph **beta** endpoint for shell scripts and app filtering
- The "processing order" is alphabetical by display name — actual Intune processing order may vary based on dependencies and assignment timing
- Shell scripts use `$expand=assignments` to minimize API calls
