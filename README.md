# 🚀 Intune my Macs

> ⚠️ **Proof of Concept — not for production use.** This repository is published as sample code to help teams evaluate and learn Microsoft Intune for macOS. The configurations and scripts are **not a hardened baseline**, are provided **as-is without warranty or support**, and must be reviewed, tested, and adapted before being deployed to managed devices. See [SUPPORT.md](SUPPORT.md) and [SECURITY.md](SECURITY.md).

Automate a Microsoft Intune macOS proof-of-concept in minutes: policies, compliance, scripts, PKG apps, and optional Microsoft Defender for Endpoint (MDE) are deployed from a single script.

---

## Quick Start (≈5 min)

### 1. Install prerequisites
**macOS**
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask powershell
```

**Optional macOS GUI launcher**
```bash
brew install swiftdialog/swiftdialog/dialog
```

**Windows**
```powershell
winget install Microsoft.PowerShell
```

> PowerShell modules (Microsoft Graph SDK) are installed automatically the first time you run the script — no manual `Install-Module` required.

### 2. Prepare your tenant.
- **MDM Authority:** determines how you manage your devices (cannot be none). [Learn how](https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/mdm-authority-set).
- **APNS certificate:** Required for any macOS enrollment. [Learn how](https://learn.microsoft.com/mem/intune/enrollment/apple-mdm-push-certificate-get).
- **Permissions:** Use an Intune Administrator (or equivalent) or grant `DeviceManagementConfiguration.ReadWrite.All`, `DeviceManagementApps.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementScripts.ReadWrite.All`, `DeviceManagementServiceConfig.ReadWrite.All`, `Group.Read.All`.
- **Optional MDE:** Download your org-specific onboarding file before using `--mde` (see [`mde/README.md`](mde/README.md) for detailed steps).

### 3. Clone and run
```bash
git clone https://github.com/microsoft/intune-my-macs.git
```

**macOS GUI launcher**
```bash
cd intune-my-macs
pwsh ./Start-IntuneMyMacs.ps1
```

`Start-IntuneMyMacs.ps1` is a native macOS SwiftDialog frontend for `mainScript.ps1`. It lets you set the policy prefix, optional tenant ID, optional Entra assignment group, include MDE content, choose dry-run versus `--apply`, run `--remove-all`, and select individual manifests before launching the underlying deployment.

**PowerShell CLI preview (dry-run)**
```bash
cd intune-my-macs
pwsh ./mainScript.ps1 --assign-group "Intune Mac Pilot"
```

**PowerShell CLI apply**
```bash
cd intune-my-macs
pwsh ./mainScript.ps1 --assign-group "Intune Mac Pilot" --apply
```

> The script defaults to **dry-run mode**. Nothing is created until you add `--apply`.

> `Start-IntuneMyMacs.ps1` is macOS-only because it depends on SwiftDialog. On Windows, use `mainScript.ps1` directly.

### 4. Common flags
| Flag | Purpose |
|------|---------|
| `--apps`, `--config`, `--compliance`, `--scripts`, `--custom-attributes`, `--enrollment` | Limit the import scope to specific artifact types |
| `--assign-group "Name"` | Assign every created object to an Entra group |
| `--prefix "[custom]"` | Override the default naming prefix |
| `--mde` | Include the `mde/` content (requires onboarding file) |
| `--remove-all` | Delete previously created objects that use the current prefix |
| `--tenant-id "GUID"` | Specify the Entra tenant ID for Microsoft Graph connection |
| `--apply` | Actually create/update/delete Intune objects (otherwise it's a preview) |

### Multi-tenant example

To deploy into a specific tenant, pass the `--tenant-id` flag:

```bash
pwsh ./mainScript.ps1 --tenant-id "12345678-1234-1234-1234-123456789012" --assign-group "Intune Mac Pilot" --apply
```

---

## What gets deployed
- **Security & configuration policies:** FileVault, Firewall, Gatekeeper, guest restrictions, login window, screen saver, managed login items, NTP, Office, Declarative Device Management, and more.
- **Compliance & scripts:** macOS compliance policy, enrollment restrictions, device scripts (Company Portal install, Dock customization, Escrow Buddy, etc.).
- **Applications:** [Swift Dialog](https://github.com/swiftDialog/swiftDialog), Office 365, Teams, M365 Copilot, [Intune Log Watch](https://github.com/gilburns/IntuneLogWatch).
- **Custom attributes:** Hardware compatibility checks and other helpers.
- **Optional MDE:** Defender installer (see `mde/README.md`).

For the full artifact catalog and settings, see `INTUNE-MY-MACS-DOCUMENTATION.md` or generate a fresh Word doc with `tools/Generate-ConfigurationDocumentation.py`.

---

## Platform SSO value reference (numeric → UI name)

The Entra Platform SSO policy (`configurations/entra/pol-idp-001-platform-sso.json`) stores its choices as **numbers**, but the Intune Settings Catalog UI shows **names**. Use this table to map between them:

| Setting | Shipped value | Settings Catalog UI name | Other options |
| --- | --- | --- | --- |
| `com.apple.extensiblesso_platformsso_authenticationmethod` | `1` | UserSecureEnclaveKey | `0` = Password, `2` = SmartCard |
| `com.apple.extensiblesso_authenticationmethod` (deprecated, macOS 13) | `1` | UserSecureEnclaveKey | `0` = Password |
| `com.apple.extensiblesso_platformsso_userauthorizationmode` | `1` | Admin | `0` = Standard, `2` = Groups |
| `com.apple.extensiblesso_type` | `1` | Redirect | `0` = Credential |

> At least one **Admin** user is required on a device before **Standard** authorization mode can be used. See [Configure Platform SSO for macOS](https://learn.microsoft.com/intune/device-configuration/settings-catalog/configure-platform-sso-macos).

---

## Learn more
- [`INTUNE-MY-MACS-DOCUMENTATION.md`](INTUNE-MY-MACS-DOCUMENTATION.md) – overview of every artifact.
- [`mde/README.md`](mde/README.md) – Defender prerequisites and onboarding steps.
- [`tools/README.md`](tools/README.md) – Utilities such as documentation export, duplicate payload detection, and processing-order reports.

---

## ⛔ Do NOT use Dynamic Device Groups for assignment

> **NOT SUPPORTED — Dynamic device groups must not be used for policy assignment with this project.**

Dynamic device groups (e.g. rules based on `device.deviceOSType` or `device.deviceManufacturer`) introduce unpredictable delays during enrollment. Entra ID must first register the device, then evaluate the dynamic membership rule, and then Intune must check in — this chain means **policies may not arrive until well after the user reaches the desktop**, defeating "Await Configuration Done" and skipping critical policies like FileVault and passcode requirements.

**Instead, use one of these supported approaches:**

| Approach | How |
|----------|-----|
| **Assignment filters (recommended)** | Assign to **All Users** or **All Devices** and add a device assignment filter using `(device.enrollmentProfileName -eq "Your macOS Enrollment Profile")`. This ensures policies apply **before first sign-in**. |
| **Static groups** | Create a static (assigned-membership) Entra security group and add devices manually or via automation. |

Assignment filters are evaluated at policy delivery time with no group-evaluation delay, making them the most reliable option for enrollment-time policy targeting.

---

## Troubleshooting at a glance
- **`Connect-MgGraph` not recognized:** The Microsoft Graph SDK installs automatically on first run. If it fails, install manually: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.
- **Auth or permission errors:** Re-run `pwsh ./mainScript.ps1` after confirming the Graph permissions above; modules auto-install per user.
- **Devices not receiving policies:** Verify APNS, device enrollment, and group membership, then force a device sync.

---

## Recent changes

See [CHANGELOG.md](CHANGELOG.md) for the full history and the list of [contributors](CHANGELOG.md#contributors).

---

Built with ❤️ by the **Microsoft Intune Customer Experience Engineering team**

## Trademarks

This project may contain trademarks or logos for projects, products, or services. 
Authorized use of Microsoft trademarks or logos is subject to and must follow 
Microsoft's Trademark & Brand Guidelines.