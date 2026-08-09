#!/bin/sh

set -eu
. "$(dirname "$0")/release-lib.sh"

mode=signed
[ "${1:-}" = "--unsigned" ] && mode=unsigned
[ "$#" -le 1 ] || die "usage: $0 [--unsigned]"

require_tool xcodegen
require_tool xcodebuild
require_tool ditto
prepare_release_root
cd "$REPO_ROOT"
xcodegen generate

if [ "$mode" = unsigned ]; then
    xcodebuild \
        -project SpaceMender.xcodeproj \
        -scheme SpaceMender \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        archive
    ditto "$ARCHIVE_PATH/Products/Applications/SpaceMender.app" "$APP_PATH"
    printf 'Unsigned archive app exported to %s\n' "$APP_PATH"
    exit 0
fi

TEAM_ID=$(team_id)
IDENTITY=$(signing_identity)
xcodebuild \
    -project SpaceMender.xcodeproj \
    -scheme SpaceMender \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    "SPACEMENDER_TEAM_ID=$TEAM_ID" \
    "DEVELOPMENT_TEAM=$TEAM_ID" \
    "SPACEMENDER_SIGNING_IDENTITY=$IDENTITY" \
    "CODE_SIGN_IDENTITY=$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    archive

EXPORT_OPTIONS="$RELEASE_ROOT/ExportOptions.plist"
cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$IDENTITY</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

printf 'Developer ID archive exported to %s\n' "$APP_PATH"
