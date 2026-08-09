#!/bin/sh

set -eu
. "$(dirname "$0")/release-lib.sh"

APP=${1:-"$APP_PATH"}
[ -d "$APP" ] || die "app not found: $APP"
require_tool codesign

IDENTITY=$(signing_identity)
HELPER="$APP/Contents/MacOS/SpaceMenderDefenderHelper"
[ -f "$HELPER" ] || die "embedded helper not found: $HELPER"

codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --entitlements "$REPO_ROOT/Configuration/DefenderHelper.entitlements" "$HELPER"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --entitlements "$REPO_ROOT/Configuration/SpaceMender.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Signed app and helper with %s\n' "$IDENTITY"
