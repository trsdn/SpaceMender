# SpaceMender

SpaceMender is a native SwiftUI macOS utility for finding and removing stale
application diagnostics and other reclaimable files.

Built-in cleanup rules cover:

- Microsoft Defender diagnostic archives (with Defender's own real-time
  protection health shown separately, so a cleanup can never be mistaken for
  having fixed a Defender health problem)
- Unavailable Xcode simulators
- Xcode DerivedData
- npm and npx caches, discovered from whichever npm installations are present
  (Homebrew, the system installer, nvm, Volta)
- SwiftPM, Playwright, and Copilot developer caches as three distinct,
  independently selectable categories
- Microsoft Edge and Google Chrome caches, with each browser profile as its own
  candidate
- Old user application logs
- Homebrew cleanup, discovered at Apple Silicon, Intel, or a configured
  `HOMEBREW_PREFIX` location

SpaceMender previews matching items and their allocated disk space before
cleanup. It uses vendor-supported commands for simulators and Homebrew, and a
separately signed Service Management helper for root-owned Defender files.

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

Microsoft Defender's own health (its real-time-protection "event provider") is
read separately through Defender's unprivileged `mdatp` tool under a hard
timeout, purely for display. It never gates or is gated by diagnostic archive
cleanup, and cleanup never resets or implies anything about it.

Xcode DerivedData activity uses a bounded heuristic rather than a full
recursive scan: the newest modification date among a project's DerivedData
folder and its *immediate* `Build` and `Index*` subdirectories only. Cleanup is
blocked outright while Xcode is running.

Browser cache cleanup enumerates each profile folder under
`~/Library/Caches/Microsoft Edge` and `~/Library/Caches/Google/Chrome` as an
independent candidate. As defense in depth beyond those directories never
containing browser profile data, an explicit name denylist also blocks
selecting or deleting anything named like cookies, history, sessions, saved
passwords, extensions, or other profile data, at any nesting depth, and fails
the whole candidate closed rather than deleting around a match.

Retention age (7/30/90 days) is tracked independently per provider and starts
at that provider's own declared default — 30 days for Defender diagnostics,
DerivedData, and user logs — so switching categories never leaks one
provider's chosen age into another. Cache-root and vendor-command providers
have no age control at all.
