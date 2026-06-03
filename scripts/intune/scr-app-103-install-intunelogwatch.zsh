#!/bin/zsh
#
# Intune shell script: downloads the latest Intune Log Watch release DMG and installs
# IntuneLogWatch.app into /Applications. Intended to run as root via Intune shell scripts.

set -euo pipefail

# Configurable variables
APP_NAME="IntuneLogWatch.app"
DMG_NAME="IntuneLogWatch.dmg"
DOWNLOAD_DIR="/tmp"
INSTALL_DIR="/Applications"
GITHUB_RELEASES_API="https://api.github.com/repos/gilburns/IntuneLogWatch/releases/latest"

# Runtime state
MOUNT_POINT=""

log() {
	echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

cleanup() {
	if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
		log "Detaching $MOUNT_POINT"
		hdiutil detach "$MOUNT_POINT" -quiet || true
		rmdir "$MOUNT_POINT" 2>/dev/null || true
	fi
	if [[ -f "$DOWNLOAD_DIR/$DMG_NAME" ]]; then
		log "Removing $DOWNLOAD_DIR/$DMG_NAME"
		rm -f "$DOWNLOAD_DIR/$DMG_NAME"
	fi
}
trap cleanup EXIT

log "Resolving latest Intune Log Watch DMG URL from GitHub..."
DMG_URL="$(curl -s "$GITHUB_RELEASES_API" \
	| grep browser_download_url \
	| grep '.dmg"' \
	| cut -d '"' -f 4)"

if [[ -z "$DMG_URL" ]]; then
	log "ERROR: Could not determine DMG download URL from GitHub."
	exit 1
fi

log "Downloading DMG from: $DMG_URL"
curl -L -o "$DOWNLOAD_DIR/$DMG_NAME" "$DMG_URL"

log "Mounting DMG..."
MOUNT_POINT="$(mktemp -d /tmp/ilw.XXXXXX)"
if ! hdiutil attach "$DOWNLOAD_DIR/$DMG_NAME" -nobrowse -quiet -mountpoint "$MOUNT_POINT"; then
	log "ERROR: Failed to mount DMG."
	exit 1
fi

log "Copying $APP_NAME to $INSTALL_DIR..."
if [[ -d "$INSTALL_DIR/$APP_NAME" ]]; then
	log "Existing copy found, removing $INSTALL_DIR/$APP_NAME"
	rm -rf "$INSTALL_DIR/$APP_NAME"
fi

if [[ -d "$MOUNT_POINT/$APP_NAME" ]]; then
	SOURCE_APP="$MOUNT_POINT/$APP_NAME"
else
	SOURCE_APP="$(find "$MOUNT_POINT" -maxdepth 2 -type d -name "$APP_NAME" 2>/dev/null | head -n 1)"
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
	log "ERROR: Could not find $APP_NAME in the mounted DMG."
	exit 1
fi

ditto --noextattr --noqtn "$SOURCE_APP" "$INSTALL_DIR/$APP_NAME"

log "Intune Log Watch installed to $INSTALL_DIR/$APP_NAME"

