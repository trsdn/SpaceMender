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
a separately signed Service Management helper for root-owned Defender files.

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

The privileged helper is embedded as a separate executable and managed through
`SMAppService`. A real install/approval/upgrade/removal exercise requires both
products to be signed with the same configured Developer ID team. Unsigned
builds deliberately remain scan-only; the normal test suite validates the XPC
contract, authorization policy, and deletion safeguards in-process against
temporary roots only.

## Safety

Cleanup rules use fixed locations, restricted file types, or vendor-supported
commands. SpaceMender never deletes Defender definitions, quarantine data,
engine databases, Docker volumes, device backups, system caches, or APFS
snapshots.

Defender cleanup accepts only archive identities (filename, scan timestamps,
modification time, and filesystem resource identity), not paths or commands.
The helper independently revalidates the fixed Defender root, canonical
location, regular non-symlink ZIP type, root ownership, age, and exact resource
identity immediately before descriptor-relative unlinking. See
[`docs/privileged-helper-security.md`](docs/privileged-helper-security.md).
