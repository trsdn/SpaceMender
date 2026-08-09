# Release checklist

## Configure

- [ ] Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- [ ] Move relevant entries from `CHANGELOG.md` Unreleased to the version.
- [ ] Confirm `main` is clean and all generated project changes are tracked.
- [ ] Set `SPACEMENDER_TEAM_ID` and, if needed,
      `SPACEMENDER_SIGNING_IDENTITY`.
- [ ] Set `SPACEMENDER_NOTARY_PROFILE` to a `notarytool` keychain profile.
      Never place Apple IDs, passwords, private keys, or profile contents in
      the repository or CI logs.

## Build and automated verification

- [ ] Run all Debug tests:
      `xcodebuild -project SpaceMender.xcodeproj -scheme SpaceMender
      -configuration Debug -derivedDataPath build test`.
- [ ] Run an unsigned local Release exercise:
      `./scripts/package-release.sh --dry-run`.
- [ ] Run the signed and notarized pipeline:
      `./scripts/package-release.sh`.
- [ ] Preserve the `notarytool` submission result in release records.
- [ ] Confirm both designated requirements use the expected identifiers and
      team, both signatures have hardened runtime, stapler validates, and
      `spctl` reports an accepted Developer ID origin.
- [ ] Expand the final ZIP and rerun
      `scripts/verify-release.sh --require-notarization SpaceMender.app`.

## Clean-user or test-machine exercise

Do this with the exact final artifact on macOS 14 or newer, not from Xcode.

1. Remove any previous SpaceMender app and helper using the old app's Settings.
2. Download/copy the ZIP, expand it, move the app to `/Applications`, and
   launch it through Finder. Confirm Gatekeeper opens it without an override.
3. Confirm the first scan starts with nothing selected and user-owned providers
   work without administrator authorization.
4. Open SpaceMender Settings and choose **Install Helper**. Approve SpaceMender
   under System Settings → General → Login Items when requested.
5. Refresh helper status and confirm it becomes **Installed and enabled**.
   Confirm Defender cleanup remains scan-only before approval and becomes
   available only after the authenticated XPC status handshake.
6. Exercise one isolated, disposable Defender diagnostic candidate. Confirm
   the fixed-root/type/age/resource checks and per-item result.
7. Install the next signed build over the current app, choose **Upgrade
   Helper**, and confirm scans and helper cleanup still work.
8. Choose **Remove Helper**, confirm **Not installed**, and verify no
   `app.spacemender.SpaceMender.DefenderHelper` daemon remains registered.
9. Quit and remove the app. Confirm ordinary scans/history left no privileged
   process behind.

Record macOS version, hardware, app version/build, signing team, helper status
transitions, and pass/fail evidence. A local unsigned dry run does not satisfy
this exercise.

## Publish

- [ ] Attach only the final `SpaceMender.zip` and checksums to the release.
- [ ] Publish the versioned changelog and known limitations.
- [ ] Retain rollback artifact and helper-removal instructions.
