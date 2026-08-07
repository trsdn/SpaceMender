#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild \
  -project SpaceMender.xcodeproj \
  -scheme SpaceMender \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
printf '\nBuilt app: %s\n' "$PWD/build/Build/Products/Debug/SpaceMender.app"
printf '\nBuilt app: %s\n' "$PWD/build/Build/Products/Debug/SpaceMender.app"
