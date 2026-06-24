#!/bin/zsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Install Microsoft Edge (macOS)
#
# Downloads the current Microsoft Edge installer package and installs it.
# Microsoft Edge keeps itself updated via Microsoft AutoUpdate (MAU), so if Edge
# is already present this script exits without touching it.
#
# Deploy via Intune as a shell script, Run as: system.
# Log: /Library/Logs/Microsoft/IntuneScripts/installEdge/Microsoft Edge.log

weburl="https://go.microsoft.com/fwlink/?linkid=2093504"   # Microsoft Edge stable, macOS (universal pkg)
appname="Microsoft Edge"
app="Microsoft Edge.app"
appdir="/Applications"
logdir="/Library/Logs/Microsoft/IntuneScripts/installEdge"
log="$logdir/$appname.log"

logdate() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

# Send all output to the log file (and stdout, so Intune captures it too)
mkdir -p "$logdir"
exec > >(tee -a "$log") 2>&1

echo ""
echo "##############################################################"
echo "# $(logdate) | Installing [$appname]"
echo "##############################################################"
echo ""

# Already installed? MAU handles updates, so there is nothing to do.
if [[ -d "$appdir/$app" ]]; then
    echo "$(logdate) | [$appname] already installed; MAU handles updates. Exiting."
    exit 0
fi

# Don't run during Setup Assistant (would run as _mbsetupuser). Wait for the Dock.
until pgrep -x Dock &>/dev/null; do
    echo "$(logdate) | Dock not running yet, waiting 10s..."
    sleep 10
done

# Work in a self-cleaning temp directory
tempdir=$(mktemp -d)
trap 'rm -rf "$tempdir"' EXIT
pkg="$tempdir/MicrosoftEdge.pkg"

# Download
echo "$(logdate) | Downloading [$appname] from [$weburl]"
if ! curl -fSL --connect-timeout 30 --retry 3 -o "$pkg" "$weburl"; then
    echo "$(logdate) | Download failed"
    exit 1
fi

# Sanity check: the download must be a PKG installer (xar archive)
if [[ "$(file -b "$pkg")" != *"xar archive"* ]]; then
    echo "$(logdate) | Downloaded file is not a PKG installer. Aborting."
    exit 1
fi

# Install
echo "$(logdate) | Installing [$appname]"
if installer -pkg "$pkg" -target /; then
    echo "$(logdate) | [$appname] installed successfully"
    exit 0
else
    echo "$(logdate) | Installation failed"
    exit 1
fi