#!/bin/sh
# Installs the DimHidden updater as a LaunchAgent on the maintainer's Mac. Rerun after changing the updater.
set -eu
cd "$(dirname "$0")"
LABEL=com.johann.DimHidden.updater
SUPPORT="$HOME/Library/Application Support/DimHidden"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$SUPPORT" "$HOME/Library/Logs/DimHidden" "$HOME/Library/LaunchAgents"
cp dimhidden_updater.py "$SUPPORT/dimhidden_updater.py"

/usr/bin/python3 - "$AGENT" "$SUPPORT/dimhidden_updater.py" <<'PY'
import os, plistlib, sys
home = os.path.expanduser("~")
plistlib.dump({
    "Label": "com.johann.DimHidden.updater",
    "ProgramArguments": ["/usr/bin/python3", sys.argv[2]],
    "RunAtLoad": True,
    "StartInterval": 3600,
    # New errors and crashes get reported as soon as they happen, not on the next hourly run.
    "WatchPaths": [f"{home}/Library/Logs/DimHidden", f"{home}/Library/Logs/DiagnosticReports"],
    "ThrottleInterval": 300,
    "ProcessType": "Background",
    "LowPriorityIO": True,
    "StandardOutPath": f"{home}/Library/Logs/DimHidden-updater.log",
    "StandardErrorPath": f"{home}/Library/Logs/DimHidden-updater.log",
}, open(sys.argv[1], "wb"))
PY

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed $LABEL. Log: ~/Library/Logs/DimHidden-updater.log"
