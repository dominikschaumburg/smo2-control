#!/bin/zsh
# Build for one device and run it in the Connect IQ simulator.
#
# Usage:  ./simulate.sh [device]        # default: fr970
#         CIQ_SDK=/path/to/sdk ./simulate.sh fenix847mm
#
# Note on SmO2 data: the simulator's FIT playback cannot feed a generic ANT
# channel. To see live SmO2 you need SimulANT+ with an ANT USB stick,
# broadcasting the Muscle Oxygen profile. Without it the field correctly shows
# SEARCH — that is not a bug.

set -e

SDK="${CIQ_SDK:-$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-fr970}"
PRG="$DIR/bin/SmO2Control_$DEVICE.prg"

GARMIN="${TMPDIR}com.garmin.connectiq/GARMIN"
GARMIN_SETTINGS="$GARMIN/Settings"
APP_UC="SMO2CONTROL_$(echo "$DEVICE" | tr '[:lower:]' '[:upper:]')"

if [ ! -x "$SDK/bin/monkeyc" ]; then
    echo "error: Connect IQ SDK not found at $SDK" >&2
    exit 1
fi

mkdir -p "$DIR/bin"

echo "Building for $DEVICE..."
"$SDK/bin/monkeyc" \
    -f "$DIR/monkey.jungle" \
    -o "$PRG" \
    -d "$DEVICE" \
    -y "$DIR/developer_key" \
    --typecheck 3

# Reset stored property values so the simulator falls back to the
# properties.xml defaults instead of whatever a previous run left behind.
if [ -d "$GARMIN_SETTINGS" ]; then
    rm -f "$GARMIN_SETTINGS/$APP_UC-settings.chk"
    rm -f "$GARMIN/APPS/SETTINGS/$APP_UC.SET"
    if [ -f "$DIR/SmO2Control-settings.json" ]; then
        cp "$DIR/SmO2Control-settings.json" "$GARMIN_SETTINGS/$APP_UC-settings.json"
    fi
    echo "Settings synced, stored props reset."
fi

if ! pgrep -qf "ConnectIQ.app"; then
    echo "Launching simulator..."
    open "$SDK/bin/ConnectIQ.app"
    sleep 6
fi

echo "Running on $DEVICE..."
"$SDK/bin/monkeydo" "$PRG" "$DEVICE"
