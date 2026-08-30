#!/bin/sh
set -eu

module_root=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
if ! command -v pwsh >/dev/null 2>&1; then
    echo "ERROR: PowerShell 7 (pwsh) is required." >&2
    exit 1
fi
exec pwsh -NoLogo -NoProfile -File "$module_root/Build.ps1" "$@"
