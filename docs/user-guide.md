# Using SpaceMender

## Scan and select

SpaceMender opens on Overview and starts an all-provider scan. Providers run
independently, so an unavailable tool or unreadable location does not discard
successful results from other providers. **Scan All** (Command-R) cancels any
older overview scan and starts again. Every new overview or focused provider
scan clears its selection.

You can select individual candidates or all candidates displayed for one
provider. **Select All Safe** replaces the current overview selection with
only candidates that are regenerable or Trash-recoverable and currently pass
provider validation, availability, and running-app checks. It deliberately
excludes Defender archives and unavailable simulators because neither is
declared regenerable or Trash-recoverable.

Retention controls appear only for Defender diagnostics, DerivedData, and user
logs. Their default is 30 days, with 7/30/90-day choices. Values are kept
separately per provider while SpaceMender is running, but the current
implementation resets them on the next app launch.

## Review and cleanup

**Review Cleanup** creates an immutable plan from the selected item identities.
The confirmation sheet groups consequences:

- **Move to Trash:** old user logs. Recoverable until Trash is emptied.
- **Permanent cache deletion:** regenerable DerivedData and validated npm,
  SwiftPM, Playwright, Copilot, Edge, and Chrome cache contents.
- **Vendor command:** selected simulator UDIDs through `xcrun simctl delete`
  and Homebrew through `brew cleanup`.
- **Privileged helper:** selected Defender diagnostic ZIP identities only.

Cleanup reports each item as cleaned, moved to Trash, skipped because it
changed, failed, or cancelled. A cleanup attempt is followed by a fresh scan,
including after partial failure. Cancellation is cooperative: already
completed operations are not rolled back, while remaining cancellable work is
reported accurately.

## Provider-specific behavior

### Microsoft Defender

Scanning finds regular ZIP archives under the fixed Defender diagnostics root
that meet the selected age. Cleanup remains scan-only unless the signed helper
is installed, approved, protocol-compatible, and able to authenticate the app.
The helper independently checks root ownership, file type, canonical root,
symlink status, age, modification time, and device/inode identity before
descriptor-relative removal.

The Defender health banner is separate. It runs
`/usr/local/bin/mdatp health --field healthy` as the current user under a hard
timeout. An unhealthy or unavailable health check does not change archive
eligibility, and deleting archives does not repair Defender.

### Xcode

Unavailable simulator discovery uses JSON from `simctl`; cleanup re-lists
device state and passes only selected, still-unavailable UDIDs to
`simctl delete`. Any booted, booting, shutting-down, or creating device blocks
the operation.

DerivedData is permanent and can make the next build/index slower. Quit Xcode,
rescan, and then clean. Age is based on the newest timestamp among the project
directory and immediate `Build` and `Index*` directories; deeper artifacts are
not recursively inspected for activity.

### Developer and browser caches

npm cache roots come from discovered npm executables and their current
configuration. SwiftPM, Playwright, and Copilot caches remain separate
providers. Cleanup removes validated contents but preserves each root.
Dependent tools will download or regenerate data later.

Edge and Chrome candidates are per cache profile under `~/Library/Caches`.
Quit the browser and matching helper processes, then rescan. SpaceMender does
not enter browser `Application Support` profile storage and rejects sensitive
profile-data names even inside a cache candidate.

### Stale updater downloads

Auto-updating apps stage a downloaded release in `~/Library/Caches` before
installing it, and several frameworks leave the staged copy behind after the
update completes. SpaceMender offers only immediate children of that directory
whose names end in `.ShipIt` (Squirrel) or `-updater`, which are naming
conventions rather than arbitrary matches, and it never descends into any other
cache directory. Because the folder can also hold an update that has been
downloaded but not yet applied, these items move to Trash rather than being
deleted permanently, and the affected app should be quit first. The worst case
is that the app downloads the update again.

### User logs and Homebrew
Selected old user logs move to Trash. Unreadable, open, changed, or
unverifiable files are skipped individually. Recent logs remain outside the
age cutoff.

Homebrew discovery checks `/opt/homebrew`, `/usr/local`, and
`HOMEBREW_PREFIX`. SpaceMender previews with `brew cleanup --dry-run` and
executes `brew cleanup`. It summarizes warnings and displays an unknown size
instead of guessing when output is not reliably parseable.

## Estimates, history, and recovery

Preview values are approximate allocated bytes at scan time. They can differ
from Finder, `du`, APFS accounting, purgeable space, or the final free-space
delta. Successful permanent/vendor cleanup and moved-to-Trash bytes are
reported separately; Trash does not free those bytes until emptied.

Overview history stores up to 100 path-free records at:

```text
~/Library/Application Support/SpaceMender/cleanup-history.json
```

It contains provider and aggregate outcome metadata only. Delete that file to
clear history while the app is not writing it.

Use **Open Trash in Finder** after a cleanup to recover logs. Permanent cache
deletion has no SpaceMender undo; rerun the owning tool to rebuild or download
its cache. Simulator and Homebrew recovery depends on their vendor tooling or
your own backup.

## Helper lifecycle

The helper embedded in a release is managed by `SMAppService`.

1. Open **SpaceMender → Settings → Microsoft Defender helper**.
2. Choose **Install Helper**.
3. If status is **Waiting for approval**, approve SpaceMender in **System
   Settings → General → Login Items**, then choose **Refresh**.
4. After replacing the app with a newer signed version, choose **Upgrade
   Helper** and refresh the status.
5. Before removing the app, choose **Remove Helper** and wait for **Not
   installed**.

Unsigned/ad-hoc local builds cannot establish the production Developer ID
trust relationship and remain scan-only. If an installed helper is stranded,
reinstall the same or newer properly signed app and use **Remove Helper**.
Do not manually delete launch-daemon files while the service is registered.

## Troubleshooting

### A provider is unavailable or scan fails

- Confirm its root/tool exists and is readable by the current user.
- Quit the affected app and rescan.
- For npm or Homebrew, confirm the executable is present in a supported
  location or configuration.
- Copy optional technical details from the error UI when filing a report.
- Do not grant broad permissions merely to force a provider to scan.

### Cleanup says an item changed

This is a safety result, not data loss. The item was missing, newer, replaced,
reidentified, outside its root, symlinked, or otherwise different from the
scan. Rescan and review the new candidate.

### Browser, Xcode, simulator, or tool is reported running

Quit the main app and related helper/processes, wait for shutdown, and rescan.
SpaceMender does not offer a bypass for running-app protection.

### Defender remains scan-only

- Open Settings and check helper status.
- Approve it in Login Items if requested.
- Choose **Upgrade Helper** after an app update.
- Choose **Refresh** and rescan.
- An authenticated-protocol failure remains closed; reinstall a matching
  signed app/helper rather than bypassing authentication.

### Gatekeeper rejects a download

Do not bypass Gatekeeper for an unknown artifact. Obtain the release again
from its trusted distribution location and verify that release records show
successful notarization, stapling, Gatekeeper assessment, and checksum for the
exact ZIP. A local `--dry-run` or `--skip-notarization` artifact is not a
notarized release.

### Uninstall or recovery

Remove the helper first, quit the app, delete the app, and optionally delete
the history file. If Trash was emptied or a permanent/vendor cleanup ran,
restore from backup or use the owning vendor’s rebuild/reinstall workflow.
