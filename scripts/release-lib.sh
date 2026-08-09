#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RELEASE_ROOT=${SPACEMENDER_RELEASE_ROOT:-"$REPO_ROOT/release-artifacts"}
DEFAULT_RELEASE_ROOT="$REPO_ROOT/release-artifacts"
RELEASE_ROOT_MARKER="$RELEASE_ROOT/.spacemender-release-root"
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

    if [ "$RELEASE_ROOT" = "$DEFAULT_RELEASE_ROOT" ]; then
        mkdir -p "$RELEASE_ROOT"
        : > "$RELEASE_ROOT_MARKER"
    elif [ ! -f "$RELEASE_ROOT_MARKER" ]; then
        die "custom release root must contain marker file: $RELEASE_ROOT_MARKER"
    fi

    # Never recursively remove the configured root. Only clear artifacts whose
    # names are owned by this release pipeline.
    rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
    rm -f \
        "$PACKAGE_PATH" \
        "$RELEASE_ROOT/ExportOptions.plist" \
        "$RELEASE_ROOT/SpaceMender-notarization.zip"
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
