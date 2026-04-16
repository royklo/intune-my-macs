# Swift Dialog - App Installation Monitor

## Overview

This shell script monitors for macOS application installations and displays a real-time progress UI using **Swift Dialog**. It does **not** install applications itself—it only monitors for their presence and updates the UI accordingly.

**Version:** 2.1.0

## Purpose

When deployed via Intune, this script provides visual feedback to users during the device onboarding process by:

1. Waiting for the desktop to be ready (Dock and Finder running)
2. Waiting for Swift Dialog binary to become available
3. Displaying a full-screen Swift Dialog window with a list of expected applications
4. Polling the system for app installations (bundle paths and package receipts)
5. Updating the UI in real-time as each application is detected
6. Showing progress until all apps are installed or a timeout is reached

## Configuration

### Key Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `DESKTOP_TIMEOUT_MINUTES` | 15 | Maximum time to wait for desktop |
| `DIALOG_WAIT_MINUTES` | 20 | Maximum time to wait for Dialog binary |
| `MONITOR_TIMEOUT_MINUTES` | 60 | Maximum time to wait for all apps |
| `POLL_INTERVAL_SECONDS` | 2 | How often to check for new installations |
| `DIALOG_BIN` | `/usr/local/bin/dialog` | Path to Swift Dialog binary |
| `logDir` | `/Library/Logs/Microsoft/IntuneScripts/Swift Dialog` | Log file location |

### Monitored Applications

The script monitors for these Microsoft applications:

| Application | Bundle Path | Package Receipt ID |
| ----------- | ----------- | ------------------ |
| Company Portal | `/Applications/Company Portal.app` | `com.microsoft.CompanyPortalMac` |
| Microsoft Edge | `/Applications/Microsoft Edge.app` | `com.microsoft.edgemac` |
| Microsoft 365 Copilot | `/Applications/Microsoft 365 Copilot.app` | `com.microsoft.m365copilot` |
| Windows App | `/Applications/Windows App.app` | `com.microsoft.rdc.macos` |
| Microsoft Excel | `/Applications/Microsoft Excel.app` | `com.microsoft.package.Microsoft_Excel.app` |
| Microsoft OneNote | `/Applications/Microsoft OneNote.app` | `com.microsoft.package.Microsoft_OneNote.app` |
| Microsoft Outlook | `/Applications/Microsoft Outlook.app` | `com.microsoft.package.Microsoft_Outlook.app` |
| Microsoft PowerPoint | `/Applications/Microsoft PowerPoint.app` | `com.microsoft.package.Microsoft_PowerPoint.app` |
| Microsoft Word | `/Applications/Microsoft Word.app` | `com.microsoft.package.Microsoft_Word.app` |
| Microsoft Teams | `/Applications/Microsoft Teams.app` | `com.microsoft.teams2` |
| Microsoft OneDrive | `/Applications/OneDrive.app` | `com.microsoft.OneDrive` |

## Script Flow

```text
┌─────────────────────────────────────────┐
│  1. Check if onboarding already done    │
│     (exit if /onboardingComplete exists)│
└───────────────┬─────────────────────────┘
                ▼
┌─────────────────────────────────────────┐
│  PHASE 1: Wait for Desktop              │
│     - Wait for Dock and Finder          │
│     - 15-minute timeout                 │
└───────────────┬─────────────────────────┘
                ▼
┌─────────────────────────────────────────┐
│  PHASE 2: Wait for Swift Dialog         │
│     - Check for /usr/local/bin/dialog   │
│     - 20-minute timeout                 │
└───────────────┬─────────────────────────┘
                ▼
┌─────────────────────────────────────────┐
│  PHASE 3: Launch Dialog & Monitor       │
│     - Full screen blur dialog           │
│     - Progress bar with app list        │
│     - Poll for apps every 2 seconds     │
│     - 60-minute timeout                 │
└───────────────┬─────────────────────────┘
                ▼
┌─────────────────────────────────────────┐
│  PHASE 4: Finalize                      │
│     - Show completion message           │
│     - Enable "Continue" button          │
│     - Write onboardingComplete flag     │
│     - Cleanup temp files                │
└─────────────────────────────────────────┘
```

## Detection Logic

An application is considered installed if **either**:

- The application bundle directory exists (e.g., `/Applications/Microsoft Word.app`)
- The package receipt is registered with `pkgutil`

This dual-check approach handles both drag-and-drop installs and PKG-based installations.

## UI Features

- **Blurred fullscreen overlay** - Prevents user interaction during setup
- **Always on top** - Ensures visibility
- **Real-time progress bar** - Shows X of Y apps installed
- **Per-app status indicators**:
  - `pending` - Waiting for installation
  - `success` - Application detected
  - `error` - Timeout reached without detection
- **Embedded Microsoft logo** - No external icon file dependency

## Logging

All output is logged to:

```text
/Library/Logs/Microsoft/IntuneScripts/Swift Dialog/onboarding.log
```

## Dependencies

- **Swift Dialog v2.5.2+** - Must be deployed separately via [app-utl-001-swift-dialog.xml](../../apps/app-utl-001-swift-dialog.xml)
- **zsh** - Required for associative array support (macOS default shell)

## Exit Conditions

| Condition | Behavior |
| --------- | -------- |
| Onboarding already complete | Exits immediately (flag file exists) |
| Desktop timeout | Exits with error code 1 |
| Dialog binary timeout | Exits with error code 1 |
| All apps detected | Shows success, enables Continue button |
| App monitoring timeout | Marks missing apps as errors, enables Continue button |
| Dialog launch failure | Exits with error code 1 |

## Customization

### Changing the Icon

The Microsoft logo is embedded as base64 in the script. To replace it:

```bash
# Convert your image to base64
base64 -i /path/to/image.png | tr -d '\n'
```

Then paste the output as the `MSFT_ICON` value in the script.

### Adding/Removing Monitored Apps

Edit the `APPS_TO_MONITOR` array in the script. Each entry follows this format:

```text
"Display Name|/path/to/App.app|com.package.receipt.id"
```

## Related Files

- [scr-utl-100-dialog-onboarding.xml](scr-utl-100-dialog-onboarding.xml) - Intune deployment configuration
- [app-utl-001-swift-dialog.xml](../../apps/app-utl-001-swift-dialog.xml) - Swift Dialog package deployment
