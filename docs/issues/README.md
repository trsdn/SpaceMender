# SpaceMender — code audit, issue backlog

Findings from an audit of the current `main` line. Each file in this directory is written as a
ready-to-file GitHub issue: front-matter title and labels, then summary, evidence with exact
`file:line` citations, impact, reproduction, and a suggested fix.

## Why these are files and not GitHub issues

This repository has **no configured git remote**, in either the worktree or the main checkout,
and `trsdn/SpaceMender` returns 404 on the GitHub API (both unauthenticated and authenticated).
There was nowhere to file them. Creating and pushing a public repository was not something to
do unilaterally.

Once a remote exists, each file maps 1:1 onto an issue — the front matter carries the title and
labels.

## Backlog

| # | Severity | Issue |
|---|----------|-------|
| [01](01-provider-catalog-rebuilt-per-access.md) | **High** | `CleanupProviderCatalog.builtIn` is a computed property, so five independent catalogs are built and the provider that scans is never the provider that executes |
| [02](02-symlinked-roots-scan-empty-silently.md) | Medium | Relocated (symlinked) cache roots scan as empty with no warning |
| [03](03-helper-authorization-dead-code-and-misleading-log.md) | Medium | Helper client-authorization policy is dead code; the accept log claims validation it never performs |
| [04](04-blocking-main-thread-io-at-launch.md) | Medium | Launch performs blocking disk and launchd I/O on the main thread, five times over |
| [05](05-double-return-confirms-permanent-deletion.md) | Medium | Two Return presses permanently delete files — `.defaultAction` on both the trigger and the confirmation |
| [06](06-sizes-under-report-package-contents.md) | Medium | Reported sizes exclude app-bundle contents that cleanup actually deletes |
| [07](07-architecture-test-masks-production-wiring.md) | Medium | The architecture test wires a shared catalog production never uses, masking #01 |
| [08](08-empty-plan-silently-does-nothing.md) | Low | "Review Cleanup" silently no-ops when the frozen plan resolves to zero items |
| [09](09-xpc-calls-have-no-timeout.md) | Low | XPC calls to the privileged helper have no timeout and can hang cleanup indefinitely |

Suggested order of work: **#01 → #07 → #04**. They are one causal chain — the computed catalog
is the defect, the architecture test is why it survived, and the duplicated construction is why
launch is slow. Fixing #01 is a small wiring change that improves all three.

## The headline: a green suite is not a working app

The test suite passes **119/119**. The app still has a high-severity correctness bug in its core
provider architecture. Issue #07 explains exactly why: the one test whose stated purpose is to
protect that architecture injects a shared catalog into the scanner and executor, which is the
opposite of what production does. The test validates a wiring that does not ship.

Every finding here was verified against the real call path, not inferred from reading code.
Where verification changed the conclusion, the issue reflects the verified result.

## What was checked and found *not* to be a problem

Recorded so nobody re-audits these:

- **Privileged helper authentication is sound.** `DefenderHelperListenerDelegate` returning
  `true` unconditionally looks alarming, but `HelperSources/DefenderHelperMain.swift:16` calls
  `listener.setConnectionCodeSigningRequirement(...)`, which Foundation enforces against the
  peer's audit token *before* the delegate runs. This is not an open root daemon. Issue #03 is
  about dead code and a misleading log line, **not** a vulnerability.

- **Symlinked declared roots cannot escape containment.** An initially promising "symlink
  escape" did not survive testing. `FileManager.contentsOfDirectory` and `enumerator` refuse to
  traverse a symlink-to-directory used as the root URL — they fail with `NSCocoaErrorDomain 256`
  / POSIX 20 `ENOTDIR` and yield zero children. The behaviour fails closed. The real defect is
  that it fails closed *silently*, which is what issue #02 documents.

  (Testing note: `/tmp` is itself a symlink to `/private/tmp` on macOS. Symlink experiments must
  use a fully-resolved base path or the results are confounded — the first attempt at this test
  was invalid for exactly that reason.)

- **An unsigned local build's helper requirement embedding `subject.OU = ""` is intended.**
  `SPACEMENDER_TEAM_ID` defaults to `""` in `project.yml:16`, so Debug builds embed a
  requirement no certificate can satisfy and the helper rejects the app. This is documented
  behaviour ("unsigned local builds remain scan-only for Defender cleanup") and
  `scripts/verify-release.sh:53-55` fails the release build if a signed app's team ID is
  missing from the embedded requirement. Not filed.

- **`scanOverview`'s early return at `AppViewModel.swift:229-231` does not leak `isScanning`.**
  It skips `isScanning = false`, unlike the equivalent guard in `scan()` at `:188-190`, but the
  only site that cancels `overviewScanTask` is `scanOverview` itself, which immediately sets
  `isScanning = true` again. Harmless today; worth aligning with `scan()` if another cancel site
  is ever added.

## Verification environment

- macOS 26.6.1, Apple Silicon
- Build: `./scripts/build-app.sh` — succeeded
- Tests: `xcodebuild -project SpaceMender.xcodeproj -scheme SpaceMender -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` — 119 tests, 20 suites, all passing
- Note: on this machine `npm config get cache` returns the default `~/.npm`, which is why
  issue #01's npm symptom is latent locally. It affects users with Homebrew, nvm, Volta, or an
  explicit `npm config set cache`.
