#!/bin/sh

set -eu
. "$(dirname "$0")/release-lib.sh"

APP=${1:-"$APP_PATH"}
[ -d "$APP" ] || die "app not found: $APP"
[ -n "${SPACEMENDER_NOTARY_PROFILE:-}" ] \
    || die "set SPACEMENDER_NOTARY_PROFILE to a notarytool keychain profile"
require_tool xcrun
require_tool ditto

SUBMISSION="$RELEASE_ROOT/SpaceMender-notarization.zip"
rm -f "$SUBMISSION"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" \
    --keychain-profile "$SPACEMENDER_NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$SUBMISSION"
printf 'Notarization accepted and ticket stapled to %s\n' "$APP"
