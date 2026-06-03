#!/bin/bash
#set -x

############################################################################################
## IMM - Install Company Portal (PKG)
##
## Version: 1.1.0
##
## Summary
## - Downloads and installs Microsoft Company Portal on macOS using a signed PKG.
## - Installs Microsoft Auto Update (MAU) first to ensure update channel is available.
## - If Company Portal is already installed and autoUpdate=true, exits without changes.
## - Otherwise performs an update check via HTTP Last-Modified and a local meta file, then installs/updates.
## - Optionally terminates running Company Portal process before install when configured.
## - Updates Octory status when Octory is installed and running.
## - Implements automatic retry logic for download failures with detailed error diagnostics.
## - Detailed logging written to /Library/Logs/Microsoft/IntuneScripts/installCompanyPortal/Company Portal.log
##
## Inputs (variables)
## - weburl: Download URL for the Company Portal PKG
## - mauurl: Download URL for the Microsoft Auto Update PKG
## - appname, app, processpath, terminateprocess, autoUpdate
##
## Artifacts (outputs)
## - Log: /Library/Logs/Microsoft/IntuneScripts/installCompanyPortal/Company Portal.log
## - Meta: /Library/Logs/Microsoft/IntuneScripts/installCompanyPortal/Company Portal.meta (Last-Modified)
##
## Requirements
## - macOS 11 or later
## - Root privileges
## - Built-ins: curl, installer, rsync
##
## Exit codes
## - 0: Success (installed or no action required)
## - 1: Failure (unsupported package type)
## - 6-56+: curl-specific error codes (DNS, network, SSL, timeout, etc.)
##
## Usage
## - Run as root via Intune device script or your management workflow.
############################################################################################

## Copyright (c) 2020 Microsoft Corp. All rights reserved.
## Scripts are not supported under any Microsoft standard support program or service. The scripts are provided AS IS without warranty of any kind.
## Microsoft disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a
## particular purpose. The entire risk arising out of the use or performance of the scripts and documentation remains with you. In no event shall
## Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever
## (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary
## loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility
## of such damages.

# User Defined variables
mauurl="https://go.microsoft.com/fwlink/?linkid=830196"                         # URL to fetch latest MAU
weburl="https://go.microsoft.com/fwlink/?linkid=853070"                         # What is the Azure Blob Storage URL?
appname="Company Portal"                                                        # The name of our App deployment script (also used for Octory monitor)
app="Company Portal.app"                                                        # The actual name of our App once installed
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/installCompanyPortal"      # The location of our logs and last updated data
processpath="/Applications/Company Portal.app/Contents/MacOS/Company Portal"    # The process name of the App we are installing
terminateprocess="true"                                                         # Do we want to terminate the running process? If false we'll wait until its not running
autoUpdate="true"                                                               # Application updates itself, if already installed we should exit

# Generated variables
tempdir=$(mktemp -d)
log="$logandmetadir/$appname.log"                                               # The location of the script log file
metafile="$logandmetadir/$appname.meta"                                         # The location of our meta file (for updates)

# Helpers

cleanup() {
    if [[ -d "$tempdir" ]]; then
        rm -rf "$tempdir"
    fi
}
trap cleanup EXIT

updateMAU () {
    #################################################################################################################
    #################################################################################################################
    ##  This function downloads and installs the latest Microsoft Auto Update (MAU) tool 
    ##
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Starting downlading of [MAU]"

    cd "$tempdir"
    curl -o "$tempdir/mau.pkg" --connect-timeout 30 --retry 5 --retry-delay 60 -L "$mauurl"
    curlExitCode=$?
    
    # Retry once if curl failed
    if [[ $curlExitCode != 0 ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | First download attempt failed with exit code [$curlExitCode], retrying once more..."
        sleep 5
        curl -o "$tempdir/mau.pkg" --connect-timeout 30 --retry 5 --retry-delay 60 -L "$mauurl"
        curlExitCode=$?
    fi
    
    if [[ $curlExitCode == 0 ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Downloaded [$mauurl] to [$tempdir/mau.pkg]"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Starting installation of latest MAU"
        installer -pkg "$tempdir/mau.pkg" -target /
        if [ "$?" = "0" ]; then
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | MAU Installed"
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Cleaning Up"
            rm -rf "$tempdir/mau.pkg"
        else
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to install [MAU]"
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Cleaning Up"
            rm -rf "$tempdir/mau.pkg"
        fi
    else
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to download [MAU] from [$mauurl]"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | curl exit code: [$curlExitCode]"
        case $curlExitCode in
            6)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Could not resolve host. Check DNS settings." ;;
            7)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Failed to connect to host. Check network connectivity." ;;
            28) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Operation timeout. Check network speed/stability." ;;
            35) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: SSL connect error. Check system date/time and certificates." ;;
            56) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Failure receiving network data. Network connection was interrupted." ;;
            *)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: curl failed with exit code $curlExitCode. Check network/proxy settings." ;;
        esac
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Troubleshooting: Verify network connectivity, proxy settings, and firewall rules."
        exit $curlExitCode
    fi
}

# function to delay script if the specified process is running
waitForProcess () {
    #################################################################################################################
    #################################################################################################################
    ##  Function to pause while a specified process is running
    ##  $1 = name of process to check for; $2 = delay; $3 = terminate true/false
    processName=$1
    fixedDelay=$2
    terminate=$3

    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Waiting for other [$processName] processes to end"
    while ps aux | grep "$processName" | grep -v grep &>/dev/null; do
        if [[ $terminate == "true" ]]; then
            pid=$(pgrep -f "$processName" | head -n1)
            if [[ -n "$pid" ]]; then
                echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | + [$appname] running, terminating [$processName] at pid [$pid]..."
                kill -9 $pid 2>/dev/null || true
            fi
            return
        fi
        if [[ ! $fixedDelay ]]; then
            delay=$(( $RANDOM % 50 + 10 ))
        else
            delay=$fixedDelay
        fi
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") |  + Another instance of $processName is running, waiting [$delay] seconds"
        sleep $delay
    done
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | No instances of [$processName] found, safe to proceed"
}

# Update the last modified date for this app
fetchLastModifiedDate() {
    if [[ ! -d "$logandmetadir" ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Creating [$logandmetadir] to store metadata"
        mkdir -p "$logandmetadir"
    fi
    lastmodified=$(curl -sIL "$weburl" | grep -i "last-modified" | awk '{$1=""; print $0}' | awk '{ sub(/^[ \t]+/, ""); print }' | tr -d '\r')
    if [[ $1 == "update" ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Writing last modified date [$lastmodified] to [$metafile]"
        echo "$lastmodified" > "$metafile"
    fi
}

# Download PKG
downloadApp () {
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Starting downlading of [$appname]"
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Downloading $appname [$weburl]"

    cd "$tempdir"
    curl -o "CompanyPortal-Installer.pkg" --connect-timeout 30 --retry 5 --retry-delay 60 -L -J "$weburl"
    curlExitCode=$?
    
    # Retry once if curl failed
    if [[ $curlExitCode != 0 ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | First download attempt failed with exit code [$curlExitCode], retrying once more..."
        sleep 5
        curl -o "CompanyPortal-Installer.pkg" --connect-timeout 30 --retry 5 --retry-delay 60 -L -J "$weburl"
        curlExitCode=$?
    fi
    
    if [[ $curlExitCode == 0 ]]; then
        tempfile="CompanyPortal-Installer.pkg"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Found downloaded tempfile [$tempfile]"
        case $tempfile in
            *.pkg|*.PKG|*.mpkg|*.MPKG)
                packageType="PKG"
                ;;
            *)
                echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Expected a PKG, but downloaded an unsupported type [$tempfile]"
                exit 1
                ;;
        esac
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Downloaded [$app] to [$tempfile]"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Detected install type as [$packageType]"
    else
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to download [$appname] from [$weburl]"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | curl exit code: [$curlExitCode]"
        case $curlExitCode in
            6)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Could not resolve host. Check DNS settings." ;;
            7)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Failed to connect to host. Check network connectivity." ;;
            22) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: HTTP error (404/403). Check if download URL is valid." ;;
            28) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Operation timeout. Check network speed/stability." ;;
            35) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: SSL connect error. Check system date/time and certificates." ;;
            56) echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: Failure receiving network data. Network connection was interrupted." ;;
            *)  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Error: curl failed with exit code $curlExitCode. Check network/proxy settings." ;;
        esac
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Troubleshooting: Verify network connectivity, proxy settings, and firewall rules."
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | You can test manually with: curl -v \"$weburl\""
        updateOctory failed
        exit $curlExitCode
    fi
}

# Check if we need to update or not
updateCheck() {
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Checking if we need to install or update [$appname]"
    if [ -d "/Applications/$app" ]; then
        if [[ $autoUpdate == "true" ]]; then
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | [$appname] is already installed and handles updates itself, exiting"
            exit 0
        fi
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | [$appname] already installed, let's see if we need to update"
        fetchLastModifiedDate
        if [[ -d "$logandmetadir" ]]; then
            if [ -f "$metafile" ]; then
                previouslastmodifieddate=$(cat "$metafile")
                if [[ "$previouslastmodifieddate" != "$lastmodified" ]]; then
                    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Update found, previous [$previouslastmodifieddate] and current [$lastmodified]"
                    update="update"
                else
                    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | No update between previous [$previouslastmodifieddate] and current [$lastmodified]"
                    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Exiting, nothing to do"
                    exit 0
                fi
            else
                echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Meta file [$metafile] not found"
                echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Unable to determine if update required, updating [$appname] anyway"
            fi
        fi
    else
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | [$appname] not installed, need to download and install"
    fi
}

## Install PKG Function (PKG-only path)
installPKG () {
    waitForProcess "$processpath" "300" "$terminateprocess"
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Installing $appname"
    updateOctory installing

    if [[ -d "/Applications/$app" ]]; then
        rm -rf "/Applications/$app"
    fi

    installer -pkg "$tempfile" -target /Applications
    if [ "$?" = "0" ]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | $appname Installed"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Cleaning Up"
        rm -rf "$tempdir"
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Application [$appname] succesfully installed"
        fetchLastModifiedDate update
        updateOctory installed
        exit 0
    else
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to install $appname"
        rm -rf "$tempdir"
        updateOctory failed
        exit 1
    fi
}

updateOctory () {
    #################################################################################################################
    #################################################################################################################
    ##  Update Octory status (if required)
    if [[ -a "/Library/Application Support/Octory" ]]; then
        if [[ $(ps aux | grep -i "Octory" | grep -v grep) ]]; then
            echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Updating Octory monitor for [$appname] to [$1]"
            /usr/local/bin/octo-notifier monitor "$appname" --state $1 >/dev/null
        fi
    fi
}

startLog() {
    if [[ ! -d "$logandmetadir" ]]; then
        echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Creating [$logandmetadir] to store logs"
        mkdir -p "$logandmetadir"
    fi
    exec > >(tee -a "$log") 2>&1
}

# delay until the user has finished setup assistant.
waitForDesktop () {
  until ps aux | grep /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -v grep &>/dev/null; do
    delay=$(( $RANDOM % 50 + 10 ))
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") |  + Dock not running, waiting [$delay] seconds"
    sleep $delay
  done
  echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Dock is here, lets carry on"
}

###################################################################################
###################################################################################
## Begin Script Body
###################################################################################
###################################################################################

startLog

echo ""
echo "##############################################################"
echo "# $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Logging install of [$appname] to [$log]"
echo "############################################################"
echo ""

updateCheck
waitForDesktop

downloadApp
updateMAU

# PKG only
if [[ $packageType == "PKG" ]]; then
    installPKG
else
    echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Unsupported package type [$packageType]"
    exit 1
fi