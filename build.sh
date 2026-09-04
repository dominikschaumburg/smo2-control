#!/bin/zsh
# Build the signed .iq store package for every device in manifest.xml.
#
# Usage:  ./build.sh
#         CIQ_SDK=/path/to/sdk ./build.sh

set -e

SDK="${CIQ_SDK:-$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/bin/SmO2Control.iq"

if [ ! -x "$SDK/bin/monkeyc" ]; then
    echo "error: Connect IQ SDK not found at $SDK" >&2
    echo "       set CIQ_SDK to your SDK directory" >&2
    exit 1
fi

if [ ! -f "$DIR/developer_key" ]; then
    echo "error: developer_key missing in $DIR" >&2
    exit 1
fi

mkdir -p "$DIR/bin"

echo "Building .iq for all devices..."
"$SDK/bin/monkeyc" \
    -f "$DIR/monkey.jungle" \
    -o "$OUT" \
    -e \
    -y "$DIR/developer_key" \
    --typecheck 3

echo "Done -> $OUT"
