#!/bin/zsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

############################################################################################
##
## Swift Dialog - App Installation Monitor
## 
## VER 2.1.0
##
## Purpose: Waits for Swift Dialog availability, then monitors for app installations
##          (via app bundle or package receipt) and updates Swift Dialog UI in real-time.
##          Does NOT install apps.
##
## Note: Uses zsh for macOS associative array support (bash 3.2 doesn't support them)
##
############################################################################################

# Define variables
logDir="/Library/Logs/Microsoft/IntuneScripts/Swift Dialog"
DIALOG_BIN="/usr/local/bin/dialog"
DIALOG_CMD="/var/tmp/dialog.log"
MONITOR_TIMEOUT_MINUTES=60
POLL_INTERVAL_SECONDS=2
DIALOG_WAIT_MINUTES=20
DESKTOP_TIMEOUT_MINUTES=15
SLEEP_SECONDS=5

# Placeholder icon shown next to each app until its .app bundle lands on disk.
# SwiftDialog SF Symbol syntax: any symbol from Apple's SF Symbols library.
# arrow.down.circle reads as "queued for download / install".
PLACEHOLDER_ICON="SF=arrow.down.circle"

# Microsoft logo - embedded base64 to ensure icon is available without external dependencies
# To replace this icon, convert your image to base64 with:
#   base64 -i /path/to/image.png | tr -d '\n'
# Then paste the output as the MSFT_ICON value below
MSFT_ICON="iVBORw0KGgoAAAANSUhEUgAAAOEAAADhCAMAAAAJbSJIAAAAhFBMVEXz8/PzUyWBvAYFpvD/ugjz9fb19Pbz+fr39fr69vPy9foAofD/tgDzRQB9ugAAo/Df6dCv0Xjz2dPzTBfzl4PznImz04CAx/H60oHS5vJ5xPH60Hn16dIAnvDz7u3z4t7n7dzzNADzkXurz3BwtQDzvrLM36zf6/Os2PL336z07d/7z3RN8WfWAAABg0lEQVR4nO3cyVLCYBCFURwCkXlygDBFUBTf//3cSGIVf5WrDi7O9wJdp3p/Wy1JkvSrLLzqVDu8FHAzjW57JrZ34+hSH5yWg9jK187PrXx/GMZ2GF9+MZsObmKbzSvhZHgb25CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCwUWE5i21QC/fB86Xp/dLt/DG4t/MGbf7+FNxkl9jZzTrR1TvCeXjJIWFJkv7uIbzqVDe8LAE8Lp+D+zgTu5/FS2zFKUFcrEex9ZaV8Ksf3Sol7N3FNqqFRf8+NkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQsJmhetebOtr75dmi+iO1anTKrrNJbDRsvCuDJQk6Z/1DSzvYqEfRCNJAAAAAElFTkSuQmCC"

# Define apps to monitor: "DisplayName|AppBundlePath|PackageReceiptID"
# Detection succeeds if EITHER the app bundle exists OR the package receipt is found
APPS_TO_MONITOR=(
    "Company Portal|/Applications/Company Portal.app|com.microsoft.CompanyPortalMac"
    "Microsoft Edge|/Applications/Microsoft Edge.app|com.microsoft.edgemac"
    "Microsoft 365 Copilot|/Applications/Microsoft 365 Copilot.app|com.microsoft.m365copilot"
    "Windows App|/Applications/Windows App.app|com.microsoft.rdc.macos"
    "Microsoft Excel|/Applications/Microsoft Excel.app|com.microsoft.package.Microsoft_Excel.app"
    "Microsoft OneNote|/Applications/Microsoft OneNote.app|com.microsoft.package.Microsoft_OneNote.app"
    "Microsoft Outlook|/Applications/Microsoft Outlook.app|com.microsoft.package.Microsoft_Outlook.app"
    "Microsoft PowerPoint|/Applications/Microsoft PowerPoint.app|com.microsoft.package.Microsoft_PowerPoint.app"
    "Microsoft Word|/Applications/Microsoft Word.app|com.microsoft.package.Microsoft_Word.app"
    "Microsoft Teams|/Applications/Microsoft Teams.app|com.microsoft.teams2"
    "Microsoft OneDrive|/Applications/OneDrive.app|com.microsoft.OneDrive"
)

# Create log directory and decode Microsoft logo BEFORE logging starts
mkdir -p "$logDir"

# Logging function using UTC timestamps for consistency across timezone changes
log() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') | $1"
}

# Start Logging
exec > >(tee -a "$logDir/onboarding.log") 2>&1


log "=========================================="
log "Swift Dialog App Installation Monitor"
log "=========================================="

# Decode embedded Microsoft logo to /var/tmp (accessible without permissions issues)
MSFT_ICON_FILE="/var/tmp/logo.png"
if [[ -f "$MSFT_ICON_FILE" ]]; then
    log "Icon file exists at $MSFT_ICON_FILE, deleting..."
    rm -f "$MSFT_ICON_FILE"
fi
echo "$MSFT_ICON" | base64 --decode > "$MSFT_ICON_FILE"
log "Icon file created at $MSFT_ICON_FILE"

# Check if we've run before
if [[ -f "$logDir/onboardingComplete" ]]; then
    log "Onboarding already completed. Exiting."
    exit 0
fi

############################################################################################
## PHASE 1: Wait for Desktop
############################################################################################

WaitForDesktop() {
    local timeout_epoch=$(( $(date +%s) + (DESKTOP_TIMEOUT_MINUTES * 60) ))
    
    log "PHASE 1 | Waiting for desktop (Dock process)..."
    
    while true; do
        # Check if Dock is running (indicates desktop is loaded)
        if pgrep -x "Dock" >/dev/null 2>&1; then
            # Also verify Finder is running
            if pgrep -x "Finder" >/dev/null 2>&1; then
                log "PHASE 1 | Desktop ready (Dock and Finder running)"
                sleep 2
                return 0
            fi
        fi
        
        # Check timeout
        if [[ $(date +%s) -ge $timeout_epoch ]]; then
            log "PHASE 1 | Timeout waiting for desktop after ${DESKTOP_TIMEOUT_MINUTES} minutes"
            return 1
        fi
        
        sleep $SLEEP_SECONDS
    done
}

if ! WaitForDesktop; then
    log "ERROR | Failed to detect desktop, exiting"
    exit 1
fi

############################################################################################
## PHASE 2: Wait for Swift Dialog Binary
############################################################################################

WaitForDialog() {
    local end_epoch=$(( $(date +%s) + (DIALOG_WAIT_MINUTES * 60) ))
    
    log "PHASE 2 | Waiting for $DIALOG_BIN (timeout ${DIALOG_WAIT_MINUTES}m)"
    
    while true; do
        if [[ -x "$DIALOG_BIN" ]]; then
            log "PHASE 2 | Found executable: $DIALOG_BIN"
            return 0
        fi
        
        if [[ $(date +%s) -ge $end_epoch ]]; then
            log "PHASE 2 | Timeout after ${DIALOG_WAIT_MINUTES} minutes waiting for $DIALOG_BIN"
            return 1
        fi
        
        sleep $POLL_INTERVAL_SECONDS
    done
}

if ! WaitForDialog; then
    log "ERROR | Swift Dialog not available, exiting"
    exit 1
fi

############################################################################################
## PHASE 3: Launch Dialog and Monitor App Installations
############################################################################################

log "PHASE 3 | Starting app installation monitoring"

# Function to check if an app is installed
check_app_installed() {
    local app_bundle="$1"
    local pkg_receipt="$2"
    
    # Check app bundle exists
    if [[ -d "$app_bundle" ]]; then
        return 0
    fi
    
    # Check package receipt
    if pkgutil --pkg-info "$pkg_receipt" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Function to update dialog list item.
# Optional 4th arg swaps the row's icon (e.g. placeholder -> real app bundle on detection).
update_dialog_item() {
    local item_name="$1"
    local item_status="$2"
    local status_text="$3"
    local item_icon="${4:-}"
    if [[ -n "$item_icon" ]]; then
        echo "listitem: title: $item_name, icon: $item_icon" >> "$DIALOG_CMD"
    fi
    echo "listitem: title: $item_name, status: $item_status, statustext: $status_text" >> "$DIALOG_CMD"
}

# Function to update dialog progress
update_dialog_progress() {
    local progress="$1"
    echo "progress: $progress" >> "$DIALOG_CMD"
}

# Function to update dialog progress text
update_dialog_progress_text() {
    local text="$1"
    echo "progresstext: $text" >> "$DIALOG_CMD"
}

# Initialize command file
rm -f "$DIALOG_CMD"
touch "$DIALOG_CMD"

# Build list item arguments array.
# If the app bundle already exists (e.g. a prior run installed it), use its real icon
# straight away; otherwise show the placeholder until Intune lands the bundle.
# status=wait gives each row an animated spinner so the list feels alive while we wait.
LISTITEM_ARGS=()
for app_entry in "${APPS_TO_MONITOR[@]}"; do
    app_name="${app_entry%%|*}"
    remainder="${app_entry#*|}"
    app_bundle="${remainder%%|*}"
    if [[ -d "$app_bundle" ]]; then
        list_icon="$app_bundle"
    else
        list_icon="$PLACEHOLDER_ICON"
    fi
    LISTITEM_ARGS+=("--listitem" "${app_name},icon=${list_icon},status=wait,statustext=Waiting...")
done

# Launch Swift Dialog
log "PHASE 3 | Launching Swift Dialog..."
killall Dialog 2>/dev/null

/usr/local/bin/dialog \
    --title "Setting Up Your Mac" \
    --message "Please wait while we configure your device with the required applications. This process runs automatically in the background." \
    --icon "$MSFT_ICON_FILE" \
    --iconsize 120 \
    --width 800 \
    --height 800 \
    --progress ${#APPS_TO_MONITOR[@]} \
    --progresstext "Monitoring for application installations..." \
    "${LISTITEM_ARGS[@]}" \
    --blurscreen \
    --ontop \
    --commandfile "$DIALOG_CMD" &

DIALOG_PID=$!
sleep 2

if ! ps -p $DIALOG_PID >/dev/null 2>&1; then
    log "ERROR | Failed to launch Swift Dialog"
    exit 1
fi
log "PHASE 3 | Swift Dialog launched (PID: $DIALOG_PID)"

# Initialize tracking associative array (zsh syntax)
typeset -A app_status
for app_entry in "${APPS_TO_MONITOR[@]}"; do
    app_name="${app_entry%%|*}"
    app_status[$app_name]="pending"
done

# Calculate timeout
end_epoch=$(( $(date +%s) + (MONITOR_TIMEOUT_MINUTES * 60) ))
apps_installed=0
total_apps=${#APPS_TO_MONITOR[@]}

log "PHASE 3 | Starting app monitoring (timeout: ${MONITOR_TIMEOUT_MINUTES}m, interval: ${POLL_INTERVAL_SECONDS}s)"
log "PHASE 3 | Monitoring ${total_apps} applications..."

# Main monitoring loop
while true; do
    # Check each app
    for app_entry in "${APPS_TO_MONITOR[@]}"; do
        app_name="${app_entry%%|*}"
        remainder="${app_entry#*|}"
        app_bundle="${remainder%%|*}"
        pkg_receipt="${remainder#*|}"
        
        if [[ "${app_status[$app_name]}" == "installed" ]]; then
            continue
        fi
        
        if check_app_installed "$app_bundle" "$pkg_receipt"; then
            log "PHASE 3 | DETECTED: $app_name"
            app_status[$app_name]="installed"
            ((apps_installed++))
            # Swap the placeholder for the real app icon now that the bundle exists.
            update_dialog_item "$app_name" "success" "Installed" "$app_bundle"
            update_dialog_progress "$apps_installed"
            update_dialog_progress_text "$apps_installed of $total_apps applications installed"
        fi
    done
    
    # Check if all apps are installed
    if [[ $apps_installed -ge $total_apps ]]; then
        log "PHASE 3 | All applications detected!"
        break
    fi
    
    # Check timeout
    now=$(date +%s)
    if [[ $now -ge $end_epoch ]]; then
        log "PHASE 3 | Timeout reached after ${MONITOR_TIMEOUT_MINUTES} minutes"
        # Mark remaining apps as timed out
        for app_entry in "${APPS_TO_MONITOR[@]}"; do
            app_name="${app_entry%%|*}"
            if [[ "${app_status[$app_name]}" != "installed" ]]; then
                log "PHASE 3 | TIMEOUT: $app_name not detected"
                update_dialog_item "$app_name" "error" "Not detected"
            fi
        done
        break
    fi
    
    sleep $POLL_INTERVAL_SECONDS
done

############################################################################################
## PHASE 4: Finalize
############################################################################################

log "PHASE 4 | Finalizing..."
sleep 2

if [[ $apps_installed -ge $total_apps ]]; then
    update_dialog_progress_text "Setup complete! All applications installed."
    echo "button1text: Continue" >> "$DIALOG_CMD"
    echo "button1: enable" >> "$DIALOG_CMD"
    log "PHASE 4 | SUCCESS: All $total_apps applications installed"
else
    update_dialog_progress_text "Setup complete. $apps_installed of $total_apps applications installed."
    echo "button1text: Continue" >> "$DIALOG_CMD"
    echo "button1: enable" >> "$DIALOG_CMD"
    log "PHASE 4 | PARTIAL: $apps_installed of $total_apps applications installed"
fi

# Wait for user to dismiss dialog (with timeout)
log "PHASE 4 | Waiting for user to dismiss dialog..."
wait $DIALOG_PID 2>/dev/null

# Mark onboarding complete
sudo touch "$logDir/onboardingComplete"
log "PHASE 4 | Onboarding complete flag written"

# Cleanup
rm -f "$DIALOG_CMD"

log "Script finished"
exit 0
