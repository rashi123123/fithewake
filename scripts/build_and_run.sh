#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in
  --build)
    exec xcodebuild -project FitheWake.xcodeproj -scheme FitheWake -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  run|--logs|--debug) ;;
  *) echo 'Usage: ./scripts/build_and_run.sh [--build|--logs|--debug]' >&2; exit 2 ;;
esac
mkdir -p .cache
xcrun devicectl list devices --json-output .cache/devices.json >/dev/null
DEVICE_ID="${FITHEWAKE_DEVICE_ID:-}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(python3 - <<'PY'
import json, sys
with open('.cache/devices.json') as f:
    devices = json.load(f)['result']['devices']
physical = []
for d in devices:
    props = d.get('properties', {})
    hardware = props.get('hardware', d.get('hardwareProperties', {}))
    connection = props.get('connection', d.get('connectionProperties', {}))
    if hardware.get('reality') == 'physical' and connection.get('state', connection.get('tunnelState')) == 'connected':
        physical.append(hardware.get('udid', d['identifier']))
if len(physical) != 1:
    sys.exit('Connect and unlock one iPhone, trust this Mac, and enable Developer Mode. Alternatively set FITHEWAKE_DEVICE_ID explicitly.')
print(physical[0])
PY
)"
fi
# Signing comes from Config/Local.xcconfig (see Config/Signing.xcconfig).
xcodebuild -project FitheWake.xcodeproj -scheme FitheWake -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
APP="$ROOT_DIR/DerivedData/Build/Products/Debug-iphoneos/FitheWake.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
LAUNCH_ARGS=(--device "$DEVICE_ID" --terminate-existing)
[[ "$MODE" != '--logs' ]] || LAUNCH_ARGS+=(--console)
[[ "$MODE" != '--debug' ]] || LAUNCH_ARGS+=(--start-stopped)
xcrun devicectl device process launch "${LAUNCH_ARGS[@]}" "$BUNDLE_ID"
