#!/bin/sh

set -eu
. "$(dirname "$0")/release-lib.sh"

allow_unsigned=false
require_notarization=false
APP="$APP_PATH"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-unsigned) allow_unsigned=true ;;
        --require-notarization) require_notarization=true ;;
        *) APP=$1 ;;
    esac
    shift
done

[ -d "$APP" ] || die "app not found: $APP"
require_tool plutil
require_tool codesign

HELPER="$APP/Contents/MacOS/SpaceMenderDefenderHelper"
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/app.spacemender.SpaceMender.DefenderHelper.plist"
[ -x "$APP/Contents/MacOS/SpaceMender" ] || die "main executable is missing"
[ -x "$HELPER" ] || die "privileged helper is missing or not executable"
[ -f "$DAEMON_PLIST" ] || die "SMAppService launch daemon plist is missing"
plutil -lint "$DAEMON_PLIST" >/dev/null

LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST")
PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$DAEMON_PLIST")
MACH_SERVICE=$(/usr/libexec/PlistBuddy \
    -c 'Print :MachServices:app.spacemender.SpaceMender.DefenderHelper' "$DAEMON_PLIST")
[ "$LABEL" = "app.spacemender.SpaceMender.DefenderHelper" ] || die "unexpected daemon label"
[ "$PROGRAM" = "Contents/MacOS/SpaceMenderDefenderHelper" ] || die "unexpected BundleProgram"
[ "$MACH_SERVICE" = true ] || die "expected helper Mach service is not enabled"

if codesign --verify --strict "$APP" >/dev/null 2>&1; then
    codesign --verify --deep --strict --verbose=2 "$APP"
    APP_DETAILS=$(codesign -d --verbose=4 "$APP" 2>&1)
    HELPER_DETAILS=$(codesign -d --verbose=4 "$HELPER" 2>&1)
    printf '%s\n' "$APP_DETAILS" | grep -q 'flags=.*runtime' || die "app lacks hardened runtime"
    printf '%s\n' "$HELPER_DETAILS" | grep -q 'flags=.*runtime' || die "helper lacks hardened runtime"
    printf '%s\n' "$APP_DETAILS" | grep -q 'Identifier=app.spacemender.SpaceMender' \
        || die "unexpected app signing identifier"
    printf '%s\n' "$HELPER_DETAILS" \
        | grep -q 'Identifier=app.spacemender.SpaceMender.DefenderHelper' \
        || die "unexpected helper signing identifier"
    APP_TEAM=$(printf '%s\n' "$APP_DETAILS" | sed -n 's/^TeamIdentifier=//p')
    HELPER_TEAM=$(printf '%s\n' "$HELPER_DETAILS" | sed -n 's/^TeamIdentifier=//p')
    [ -n "$APP_TEAM" ] || die "app signature has no Developer ID team"
    [ "$APP_TEAM" = "$HELPER_TEAM" ] || die "app and helper signing teams differ"
    strings "$HELPER" | grep -F \
        "anchor apple generic and identifier \"app.spacemender.SpaceMender\" and certificate leaf[subject.OU] = \"$APP_TEAM\"" \
        >/dev/null || die "helper authorized-client requirement does not match the signed app team"
    printf 'App designated requirement:\n'
    codesign -d -r- "$APP" 2>&1
    printf 'Helper designated requirement:\n'
    codesign -d -r- "$HELPER" 2>&1
    if [ "$require_notarization" = true ]; then
        spctl --assess --type execute --verbose=4 "$APP"
    else
        printf 'Gatekeeper assessment deferred until notarization is required.\n'
    fi
else
    [ "$allow_unsigned" = true ] || die "app is not validly signed"
    printf 'Unsigned validation: signing, hardened runtime, and Gatekeeper checks skipped.\n'
fi

if [ "$require_notarization" = true ]; then
    xcrun stapler validate "$APP"
fi

printf 'Release structure verification passed for %s\n' "$APP"
