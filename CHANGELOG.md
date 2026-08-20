# Changelog

All notable changes to SpaceMender are recorded here.

## [Unreleased]

### Added

- **Stale updater downloads** cleanup location. Auto-updating apps stage
  downloaded releases under `~/Library/Caches` and several frameworks leave
  them behind; SpaceMender now offers immediate children ending in `.ShipIt`
  or `-updater`, moved to Trash rather than deleted permanently because the
  folder can hold an update that has been downloaded but not yet applied.
- MIT license, contribution guide, code of conduct, security policy, issue and
  pull request templates, and Dependabot configuration.
- Continuous integration that builds and runs the full suite on macOS,
  regenerating the Xcode project from `project.yml` so that a file missing from
  the committed project is still compiled rather than skipped silently.
- Secret scanning, and a CI check that rejects personal home directory paths in
  tracked files.
- Developer ID archive, signing, notarization, stapling, verification, and ZIP
  packaging automation.
- Hardened-runtime release validation for the app and Defender helper.
- In-app helper install, upgrade, approval-status, and removal controls.
- Release checklist and clean-machine verification guidance.
- Complete product, provider, selection, retention, accounting, privacy,
  permission, installation, recovery, troubleshooting, architecture, security,
  contribution, and direct-download release documentation.

### Fixed

- Reported sizes stopped counting at the first symbolic link inside a scanned
  tree, so the Playwright cache displayed 206.5 MB of an actual 564.7 MB. The
  app under-promised the space cleanup would actually free.
- Reported sizes excluded application bundle contents that cleanup deletes.
- A single `CleanupProviderCatalog` is now built once and injected, so the
  provider that scans is the provider that executes. Previously five
  independent catalogs were constructed.
- External commands inherit the parent environment. They were launched with a
  completely empty one, which permanently broke the Homebrew provider.
- Relocated (symlinked) cache roots no longer scan as empty without a warning.
- Two Return presses could permanently delete files, because the default action
  was set on both the trigger and its confirmation.
- Tool-failure warnings no longer refer to themselves, and surface the
  actionable text directly instead of hiding it behind a copy link.
- "Review Cleanup" reports an empty plan instead of silently doing nothing.
- XPC calls to the privileged helper time out instead of hanging cleanup
  indefinitely.
- Launch no longer performs an unbounded filesystem probe on the main thread.

### Removed

- Dead helper client-authorization policy code, and an accept log that claimed
  validation it never performed.

### Clarified

- Release automation is documented without asserting that an existing artifact
  has passed Apple notarization.
- Provider retention is independent during a running session but is not yet
  persisted across app launches.
- The architecture test wired a shared catalog that production never used,
  masking the catalog defect above; it now exercises the production wiring.
- `docs/issues/` records both the audit backlog and the cache locations that
  were measured and deliberately left uncovered, with the reason for each.

## [0.1.0] - TBD

Initial direct-download release.
