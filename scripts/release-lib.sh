#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RELEASE_ROOT=${SPACEMENDER_RELEASE_ROOT:-"$REPO_ROOT/release-artifacts"}
ARCHIVE_PATH="$RELEASE_ROOT/SpaceMender.xcarchive"
EXPORT_PATH="$RELEASE_ROOT/export"
APP_PATH="$EXPORT_PATH/SpaceMender.app"
PACKAGE_PATH="$RELEASE_ROOT/SpaceMender.zip"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

prepare_release_root() {
    case "$RELEASE_ROOT" in
        /|"$REPO_ROOT") die "refusing to clear unsafe release root: $RELEASE_ROOT" ;;
    esac
    rm -rf "$RELEASE_ROOT"
    mkdir -p "$EXPORT_PATH"
}

team_id() {
    value=${SPACEMENDER_TEAM_ID:-${DEVELOPMENT_TEAM:-}}
    [ -n "$value" ] || die "set SPACEMENDER_TEAM_ID (or DEVELOPMENT_TEAM)"
    printf '%s\n' "$value"
}

signing_identity() {
    printf '%s\n' "${SPACEMENDER_SIGNING_IDENTITY:-Developer ID Application}"
}
