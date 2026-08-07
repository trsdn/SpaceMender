# SpaceMender

SpaceMender is a native SwiftUI macOS utility for finding and removing stale
application diagnostics and other reclaimable files.

Built-in cleanup rules cover:

- Microsoft Defender diagnostic archives
- Unavailable Xcode simulators
- Xcode DerivedData
- npm and npx caches
- SwiftPM, Playwright, and Copilot developer caches
- Microsoft Edge and Google browser caches
- Old user application logs
- Homebrew cleanup

SpaceMender previews matching items and their allocated disk space before
cleanup. It uses vendor-supported commands for simulators and Homebrew, and the
standard macOS administrator authorization dialog for root-owned Defender files.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/Build/Products/Debug/SpaceMender.app
```

To develop in Xcode:

```bash
xcodegen generate
open SpaceMender.xcodeproj
```

`project.yml` is the canonical project definition. Regenerate
`SpaceMender.xcodeproj` after changing targets or build settings rather than
editing the generated project directly.

The project defines Debug and Release configurations. Unsigned local builds can
set `CODE_SIGNING_ALLOWED=NO`; the Release configuration reserves the Developer
ID Application identity for later distribution signing work.

## Safety

Cleanup rules use fixed locations, restricted file types, or vendor-supported
commands. SpaceMender never deletes Defender definitions, quarantine data,
engine databases, Docker volumes, device backups, system caches, or APFS
snapshots.
