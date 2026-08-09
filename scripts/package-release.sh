#!/bin/sh

set -eu
. "$(dirname "$0")/release-lib.sh"

mode=signed
case "${1:-}" in
    --dry-run) mode=dry-run ;;
    --skip-notarization) mode=skip-notarization ;;
    "") ;;
    *) die "usage: $0 [--dry-run|--skip-notarization]" ;;
esac

require_tool ditto
require_tool unzip

if [ "$mode" = dry-run ]; then
    "$REPO_ROOT/scripts/archive-release.sh" --unsigned
    "$REPO_ROOT/scripts/verify-release.sh" --allow-unsigned "$APP_PATH"
else
    "$REPO_ROOT/scripts/archive-release.sh"
    "$REPO_ROOT/scripts/sign-release.sh" "$APP_PATH"
    "$REPO_ROOT/scripts/verify-release.sh" "$APP_PATH"
    if [ "$mode" = signed ]; then
        "$REPO_ROOT/scripts/notarize-release.sh" "$APP_PATH"
        "$REPO_ROOT/scripts/verify-release.sh" --require-notarization "$APP_PATH"
    fi
fi

rm -f "$PACKAGE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PACKAGE_PATH"
unzip -tq "$PACKAGE_PATH"
printf 'Release package created at %s\n' "$PACKAGE_PATH"
