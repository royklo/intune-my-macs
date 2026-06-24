#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#set -x

############################################################################################
##
## Script to rename a Mac based on device type and serial number
##
############################################################################################

## Copyright (c) 2021 Microsoft Corp. All rights reserved.
## Scripts are not supported under any Microsoft standard support program or service. The scripts are provided AS IS without warranty of any kind.
## Microsoft disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a
## particular purpose. The entire risk arising out of the use or performance of the scripts and documentation remains with you. In no event shall
## Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever
## (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary
## loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility
## of such damages.

## Define variables
appname="DeviceRename"
logandmetadir="/Library/Logs/Microsoft/IntuneScripts/$appname"
log="$logandmetadir/$appname.log"
CorporatePrefix="ADE"
PersonalPrefix="BYO"
ABMOnly="false"
EnforceBYOD="false"

## Country code source
## --------------------
## By default this script derives the two-letter country code from the device's
## public IP using an external DNS lookup (myip.opendns.com) and an external
## geolocation API (ipapi.co). This dependency is FRAGILE and may produce a wrong
## or empty value on:
##   - Air-gapped or proxy-only networks (no direct egress to ipapi.co)
##   - VPN / split-tunnel / hair-pinned egress (IP geolocates to the VPN exit, not the user)
##   - Carrier-grade NAT or misleading egress IPs
## If the lookup fails, the country segment of the name is simply omitted.
##
## MDM-variable alternative (recommended for managed fleets):
## Set CountryOverride below to a fixed two-letter code (e.g. "GB", "US", "DE")
## to skip the network lookup entirely. You can also template this value per
## region by deploying region-specific copies of the script, or replace it with
## a value your management tooling injects at deploy time. When CountryOverride
## is non-empty the external IP/geolocation calls are NOT made.
CountryOverride=""

## Check if the log directory has been created
if [ -d "$logandmetadir" ]; then
    ## Already created
    echo "# $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Log directory already exists - $logandmetadir"
else
    ## Creating Metadirectory
    echo "# $(date -u "+%Y-%m-%d %H:%M:%S UTC") | creating log directory - $logandmetadir"
    mkdir -p "$logandmetadir"
    firstrun="true"
fi

# start logging
exec &> >(tee -a "$log")

# Begin Script Body
echo ""
echo "##############################################################"
echo "# $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Starting $appname"
echo "############################################################"
echo "Writing log output to [$log]"
echo ""

echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Checking if renaming is necessary"

SerialNum=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}' | cut -d ':' -f2- | xargs)
if [ "$?" = "0" ]; then
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Serial detected as $SerialNum"
else
   echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Unable to determine serial number"
   exit 1
fi


CurrentNameCheck=$(scutil --get ComputerName)
if [ "$?" = "0" ]; then
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Current computername detected as $CurrentNameCheck"
else
   echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Unable to determine current name"
   exit 1
fi


echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Old Name: $CurrentNameCheck"
ModelName=$(system_profiler SPHardwareDataType | awk '/Model Name:/ {print}' | cut -d ':' -f2- | xargs)
if [ "$?" = "0" ]; then
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Retrieved model name: $ModelName"
else
   echo "$(date -u "+%Y-%m-%d %H:%M:%S UTC") | Unable to determine modelname"
   exit 1
fi


profiles status -type enrollment | grep "Enrolled via DEP: Yes"
if [ "$?" = "0" ]; then
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | This device is enrolled by ABM"
  OwnerPrefix=$CorporatePrefix
elif [ "$ABMOnly" = "false" ]; then
  if [[ "$firstrun" = "true" || "$EnforceBYOD" = "true" ]]; then
    echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | This device is enrolled manually, assuming BYOD scenario."
    OwnerPrefix=$PersonalPrefix
  else
    echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | This device was enrolled manually. Device name will not be enforced after initial change."
    exit 0
  fi
else
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | This device is not enrolled by ABM, device name will not be changed."
  exit 0
fi


## What is our public IP
## NOTE: This block depends on outbound access to myip.opendns.com (DNS) and
## ipapi.co (HTTPS). It is unreliable on air-gapped, proxied, or VPN/hair-pinned
## networks and may geolocate to the wrong country. Set CountryOverride at the
## top of this script to bypass the lookup. If neither the override nor the
## lookup yields a value, the country segment is omitted from the device name.
if [[ -n "$CountryOverride" ]]; then
  Country="$CountryOverride"
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Using CountryOverride value: $Country (skipping IP geolocation)"
else
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Looking up public IP (external dependency: myip.opendns.com + ipapi.co)"
  myip=$(dig +short myip.opendns.com @resolver1.opendns.com)
  Country=$(curl -s -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36 Edg/116.0.1938.69' https://ipapi.co/$myip/country)
fi


echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Generating four characters code based on retrieved model name $ModelName"

case "$ModelName" in
  "MacBook Air"*) ModelCode="MBA";;
  "MacBook Pro"*) ModelCode="MBP";;
  "MacBook"*) ModelCode="MB";;
  "iMac"*) ModelCode="IMAC";;
  "Mac Pro"*) ModelCode="PRO";;
  "Mac mini"*) ModelCode="MINI";;
  "Mac Studio"*) ModelCode="MS";;
  "Apple Virtual Machine"*) ModelCode="VM";;
  *) ModelCode=$(echo "$ModelName" | tr -d ' ' | cut -c1-4);;
esac

echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | OwnerPrefix variable set to $OwnerPrefix"
echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | ModelCode variable set to $ModelCode"
echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Retrieved serial number: $SerialNum"
echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Detected country as: $Country"
echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Building the new name..."

NewName=""

if [[ -n "$OwnerPrefix" ]]; then
    NewName+="$OwnerPrefix"
fi

if [[ -n "$ModelCode" && ! "$ModelCode" == *"error"* ]]; then
    if [[ -n "$NewName" ]]; then
      NewName+="-$ModelCode"
    else
      NewName+="$ModelCode"
    fi
fi

if [[ -n "$SerialNum" && ! "$SerialNum" == *"error"* ]]; then
    if [[ -n "$NewName" ]]; then
      NewName+="-$SerialNum"
    else
      NewName+="$SerialNum"
    fi
fi

if [[ -n "$Country" && ! "$Country" == *"error"* ]]; then
    if [[ -n "$NewName" ]]; then
      NewName+="-$Country"
    fi
fi

echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Generated Name: $NewName"


if [[ "$CurrentNameCheck" == "$NewName" ]]
  then
  echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Rename not required already set to [$CurrentNameCheck]"
  exit 0
fi

#Setting ComputerName
scutil --set ComputerName "$NewName"
if [ "$?" = "0" ]; then
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Computername changed from $CurrentNameCheck to $NewName"
else
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to rename the device from $CurrentNameCheck to $NewName"
   exit 1
fi

#Setting HostName
scutil --set HostName "$NewName"
if [ "$?" = "0" ]; then
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | HostName changed from $CurrentNameCheck to $NewName"
else
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to rename the device from $CurrentNameCheck to $NewName"
   exit 1
fi

#Setting LocalHostName
scutil --set LocalHostName "$NewName"
if [ "$?" = "0" ]; then
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | LocalHostName changed from $CurrentNameCheck to $NewName"
else
   echo " $(date -u "+%Y-%m-%d %H:%M:%S UTC") | Failed to rename the device from $CurrentNameCheck to $NewName"
   exit 1
fi