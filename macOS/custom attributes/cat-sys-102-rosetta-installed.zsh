#!/usr/bin/env zsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Custom Attribute: Rosetta 2 installed (true/false)
#
# Returns "true" if Rosetta 2 is installed and working on this Mac,
# otherwise "false". On Intel Macs the question does not apply, so the
# result is always "false" — Intel hardware runs x86_64 natively and does
# not use Rosetta.
#
# Detection runs an x86_64 binary through `arch` as a functional test.
# This exercises the Rosetta runtime directly, so the result is truthful
# regardless of whether the on-demand `oahd` daemon happens to be running.

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
    echo "false"
    exit 0
fi

if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    echo "true"
else
    echo "false"
fi
