# SpaceMender

SpaceMender is a native SwiftUI utility for macOS 14 and newer. It scans
specific developer, browser, application-log, and Microsoft Defender
locations, lets you review every candidate, and performs only the cleanup you
confirm. Discovery never changes disk contents.

The app has three native macOS destinations:

- **Overview** scans all providers concurrently, shows independent provider
  failures and warnings, and supports item, provider, and **Select All Safe**
  selection.
- **Cleanup locations** provides a focused scan and exact selection for one
  provider.
- **History** shows path-free local outcome and size summaries for recent
  overview cleanups.

Every new scan starts with nothing selected. Before an overview cleanup,
SpaceMender freezes the current selections into a confirmation plan grouped by
Move to Trash, permanent cache deletion, vendor command, and privileged
helper.

## Supported providers

| Provider | Scope | Retention | Cleanup policy |
|---|---|---:|---|
| Defender diagnostics | Root-owned ZIP archives in `/Library/Application Support/Microsoft/Defender/wdavdiag` | 7/30/90 days; default 30 | Permanent deletion through the authenticated helper only |
| Unavailable simulators | Devices reported unavailable by `xcrun simctl` | None | `simctl delete` for the selected UDIDs |
| Xcode DerivedData | Child projects under `~/Library/Developer/Xcode/DerivedData` | 7/30/90 days; default 30 | Permanent deletion |
| npm caches | `_cacache` and `_npx` below discovered npm cache roots | None | Permanent contents deletion; roots remain |
| SwiftPM cache | `~/Library/Caches/org.swift.swiftpm` | None | Permanent contents deletion; root remains |
| Playwright cache | `~/Library/Caches/ms-playwright` | None | Permanent contents deletion; root remains |
| Copilot cache | `~/Library/Caches/github-copilot-sdk` and `~/Library/Caches/copilot` | None | Permanent contents deletion; roots remain |
| Browser caches | Edge and Chrome profile cache folders under their user cache roots | None | Permanent contents deletion; profile cache roots remain |
| Stale updater downloads | Squirrel/Sparkle staging folders directly under `~/Library/Caches` whose names end in `.ShipIt` or `-updater` | None | Move to Trash |
| Old user logs | Files below `~/Library/Logs` | 7/30/90 days; default 30 | Move to Trash |
| Homebrew cleanup | Apple Silicon, Intel, or configured `HOMEBREW_PREFIX` installation | None | Homebrew-supported `brew cleanup` command |

npm discovery checks Homebrew, system-installer, nvm, and Volta executables and
asks each installation for its configured cache. Browser cleanup does not scan
`Library/Application Support` and explicitly rejects names associated with
cookies, history, sessions, saved passwords, extensions, and profile data.

Retention is independent per provider during the running app session.
Retention choices are not currently persisted across app launches. Fixed-cache
and vendor-state providers do not expose an age control.

See [Using SpaceMender](docs/user-guide.md) for consequences, estimates,
permissions, recovery, and troubleshooting.

## Selection and safety

**Select All Safe** is intentionally narrower than “select everything.” It
includes only candidates whose provider marks them regenerable or
Trash-recoverable and which, at scan time, have no provider availability,
running-app, or validation conflict. Defender archives and unavailable
simulators therefore require deliberate selection. A provider-level selection
selects all currently displayed candidates for that provider; execution still
revalidates every item.

Immediately before cleanup, providers verify the provider identity, policy,
fixed canonical root, expected resource type, modification state, and
filesystem resource identity where available. Symlinks, path escapes, missing
or changed resources, unreadable items, and running-app conflicts fail closed
as skipped or failed outcomes. Cache providers preserve the validated cache
root and delete only validated contents. Selection is exact: SpaceMender does
not broaden a plan because another item later becomes eligible.

Xcode must be closed before DerivedData cleanup. DerivedData age uses a bounded
activity heuristic: the newest modification date among the project directory
and its immediate `Build` and `Index*` children. Simulator cleanup is blocked
when simulator devices are booted, booting, shutting down, or being created.
Edge, Chrome, and their matching helper processes must be closed before browser
cleanup.

Microsoft Defender health is a separate, read-only `mdatp health` check with a
hard timeout. It reports Defender real-time-protection health only. Diagnostic
archive cleanup neither fixes nor depends on that health result.

## Estimates and outcomes

Scan sizes are approximate allocated-byte estimates, not a promise about a
volume’s free-space change. Hidden cache contents that a provider will remove
are included. Homebrew is shown as **unknown** when its dry-run output cannot
be parsed reliably.

After cleanup:

- **Permanently reclaimed** counts estimated bytes for items successfully
  permanently deleted or cleaned by a vendor operation.
- **Moved to Trash** is reported separately because those bytes remain on the
  volume until Trash is emptied.
- Changed, failed, and cancelled items do not count as reclaimed.

## Privacy and permissions

SpaceMender has no network feature and performs discovery and history storage
locally. History contains timestamp, provider ID/name, aggregate outcome,
item count, permanently reclaimed bytes, and moved-to-Trash bytes. It stores no
candidate paths, filenames, or file contents and retains at most 100 entries in
`~/Library/Application Support/SpaceMender/cleanup-history.json`.

The app is intentionally outside App Sandbox so it can inspect its documented
user cache and log roots. It receives no broad filesystem entitlement. Normal
providers run as the current user and can act only where that user has access.
Unreadable locations fail independently; SpaceMender does not request Full
Disk Access as a substitute for a provider’s fixed scope.

Only root-owned Defender archive deletion crosses a privilege boundary. The
separately signed `SMAppService` helper accepts archive identities, never an
arbitrary path, executable, argument list, or shell command. Unsigned local
builds remain scan-only for Defender cleanup.

See the [security model](docs/privileged-helper-security.md) and
[architecture/provider contract](docs/architecture-and-provider-contract.md).

## Exclusions and limitations

SpaceMender never targets Defender definitions, quarantine data, engine
databases, Docker volumes, device backups, broad system caches, APFS snapshots,
broad `/private/var` content, browser profiles, cookies, history, passwords,
sessions, or extensions.

Revalidation reduces but cannot eliminate filesystem time-of-check/time-of-use
races. Estimates can differ from later filesystem accounting. There is no
automatic scheduler, cloud sync, duplicate finder, general disk visualizer, or
guarantee that deleting caches improves performance. Permanently removed cache
contents are recoverable only by the owning tool rebuilding or downloading
them; SpaceMender has no undo for permanent and vendor-command cleanup.

## Build, test, and development

Requirements:

- macOS 14 or newer
- Xcode with the macOS 14 SDK and Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

`project.yml` is canonical; do not hand-edit the generated project.

```bash
xcodegen generate
./scripts/build-app.sh
open build/Build/Products/Debug/SpaceMender.app
```

For iterative development:

```bash
xcodegen generate
open SpaceMender.xcodeproj
```

Run the test suite:

```bash
xcodebuild \
  -project SpaceMender.xcodeproj \
  -scheme SpaceMender \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Tests use fixtures and isolated roots. The normal suite does not delete from
the production Defender directory or exercise real Service Management
approval.

## Direct-download build and release

An unsigned archive/structure/ZIP exercise is available without credentials:

```bash
./scripts/package-release.sh --dry-run
```

For Developer ID distribution, first create a keychain profile outside the
repository:

```bash
xcrun notarytool store-credentials spacemender-notary
```

Then provide configuration through the environment:

```bash
export SPACEMENDER_TEAM_ID=ABCDE12345
export SPACEMENDER_SIGNING_IDENTITY="Developer ID Application"
export SPACEMENDER_NOTARY_PROFILE=spacemender-notary
./scripts/package-release.sh
```

The scripts archive, export, sign the helper and app with hardened runtime,
verify identifiers and designated requirements, submit the app with
`notarytool`, staple, run Gatekeeper assessment, and create
`release-artifacts/SpaceMender.zip`. `--skip-notarization` performs a signed
local pipeline without submission and must not be published as notarized.
Credentials remain in the keychain; only the profile name is passed to the
script. `Configuration/Release.env.example` contains non-secret examples.

These commands describe the release pipeline; this repository does **not**
assert that any existing artifact has actually passed Apple notarization. A
release may be called notarized only when the submission, stapler validation,
and Gatekeeper evidence for that exact artifact have been recorded.

Follow the [release checklist](docs/release-checklist.md) and
[release security and operations guide](docs/release-security-and-operations.md).

## Install, upgrade, and uninstall

For a verified direct-download release:

1. Expand `SpaceMender.zip`, move `SpaceMender.app` to `/Applications`, and
   launch it through Finder.
2. User-owned providers need no helper. For Defender deletion, open
   **SpaceMender → Settings → Microsoft Defender helper**, choose **Install
   Helper**, and approve SpaceMender in **System Settings → General → Login
   Items** when macOS requests it.
3. To upgrade, replace the app with the newer signed build, then choose
   **Upgrade Helper**. Refresh until status is **Installed and enabled**.
4. Before uninstalling, choose **Remove Helper** and confirm **Not installed**.
   Quit SpaceMender and move the app to Trash.
5. Optionally remove
   `~/Library/Application Support/SpaceMender/cleanup-history.json` (or its
   containing `SpaceMender` directory) to erase local history.

If the app was removed before the helper, reinstall the same or a newer
properly signed release, remove the helper in Settings, and then delete the app
again. Full recovery and troubleshooting steps are in the
[user guide](docs/user-guide.md).
