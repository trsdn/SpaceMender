# SpaceMender — code audit, issue backlog

Findings from an audit of the current `main` line. Each file in this directory is written as a
ready-to-file GitHub issue: front-matter title and labels, then summary, evidence with exact
`file:line` citations, impact, reproduction, and a suggested fix.

## How these map to GitHub issues

Each file in this directory is written as a ready-to-file GitHub issue and maps 1:1 onto one —
the front matter carries the title and labels, and the body is the issue body. They are kept in
the repository as well so the audit travels with the code and stays reviewable in a diff.

## Backlog

| # | Severity | Status | Issue |
|---|----------|--------|-------|
| [01](01-provider-catalog-rebuilt-per-access.md) | **High** | **Fixed** | `CleanupProviderCatalog.builtIn` is a computed property, so five independent catalogs are built and the provider that scans is never the provider that executes |
| [10](10-child-processes-launched-with-empty-environment.md) | **High** | **Fixed** | Every external command runs with a completely empty environment, permanently breaking the Homebrew provider |
| [12](12-sizes-stop-counting-at-first-symlink.md) | **High** | **Fixed** | Reported sizes stop counting at the first symlink inside a scanned tree — the Playwright cache showed 206,5 MB of an actual 564,7 MB |
| [02](02-symlinked-roots-scan-empty-silently.md) | Medium | **Fixed** | Relocated (symlinked) cache roots scan as empty with no warning |
| [03](03-helper-authorization-dead-code-and-misleading-log.md) | Medium | **Fixed** | Helper client-authorization policy is dead code; the accept log claims validation it never performs |
| [04](04-blocking-main-thread-io-at-launch.md) | Medium | **Fixed** | Launch performs blocking disk I/O on the main thread — the unbounded filesystem probe is now deferred to the async discovery path |
| [05](05-double-return-confirms-permanent-deletion.md) | Medium | **Fixed** | Two Return presses permanently delete files — `.defaultAction` on both the trigger and the confirmation |
| [06](06-sizes-under-report-package-contents.md) | Medium | **Fixed** | Reported sizes exclude app-bundle contents that cleanup actually deletes |
| [07](07-architecture-test-masks-production-wiring.md) | Medium | **Fixed** | The architecture test wires a shared catalog production never uses, masking #01 |
| [11](11-tool-failure-warning-is-self-referential.md) | Medium | **Fixed** | Tool-failure warnings are self-referential and hide the only actionable text behind a copy-to-clipboard link |
| [08](08-empty-plan-silently-does-nothing.md) | Low | **Fixed** | "Review Cleanup" silently no-ops when the frozen plan resolves to zero items |
| [09](09-xpc-calls-have-no-timeout.md) | Low | **Fixed** | XPC calls to the privileged helper have no timeout and can hang cleanup indefinitely |

**#01, #07, and #10 are fixed.** `AppViewModel`
now constructs a single `CleanupProviderCatalog` and injects it into the scanner, executor,
overview scanner, and overview cleanup executor, and derives `rules` from it. The new
`viewModelBuildsEveryServiceFromOneCatalog` test drives a real `AppViewModel` with a stateful
fixture provider that fails execution unless discovery ran on the same instance — it was
verified to fail against the pre-fix wiring before being kept.

That also cut launch-time catalog construction from five to one, which reduces #04 without
resolving it: the remaining construction is still synchronous and still on the main thread.

**#10 was found by looking at the running UI, not by reading code.** Homebrew cleanup reported
"Scan failed" on every scan. `ProcessRunner` assigned `Process.environment = nil`, which on
Darwin launches the child with an *empty* environment rather than an inherited one, so `brew`
died with `$HOME must be set to run brew`. `simctl`, `npm`, and `mdatp` were spawned the same
way. One line fixed all four; Homebrew now scans as `1 item · 104.2 MB · Available`.

Remaining suggested order: **#05 → #11 → #06 → #02**. #05 is a two-character deletion that
removes a route to irreversible data loss; #11 is what made #10 take hours instead of minutes to
diagnose, and will do the same to the next tool failure; #06 makes every reported number honest;
#02 stops silently misleading developers who relocate their caches.

## The headline: a green suite is not a working app

The test suite passes **122/122**. It passed **119/119** while the app shipped a high-severity
correctness bug in its core provider architecture (#01) *and* a provider that had never once
worked (#10).

Both share a cause: the suite substitutes a fixture at exactly the seam where production is
broken. #07 explains it for #01 — the one test whose stated purpose is to protect the provider
architecture injects a shared catalog into the scanner and executor, which is the opposite of
what production does. #10 is the same shape: every provider test injects a fixture command
runner, so no test ever spawned a real process through the real `CommandRunner`, and
`ProcessRunnerTests` exercised real processes but never asserted anything about the child's
environment.

The lesson is not "write more tests". It is that a test which replaces the component under
suspicion validates a wiring that does not ship.

Every finding here was verified against the real call path, not inferred from reading code.
Where verification changed the conclusion, the issue reflects the verified result.

## What was checked and found *not* to be a problem

Recorded so nobody re-audits these:

- **Decimal commas in an English UI are correct.** Sizes render as `2,23 GB` and `638,1 MB`
  alongside English interface text. This machine is set to `AppleLocale = de_DE` with
  `AppleLanguages = (de-DE)`; the app ships no German localization, so text falls back to its
  development language while `ByteCountFormatter` formats numbers per the user's region. That
  is standard macOS behaviour — number format follows Region, text follows Language. Not a bug.
  Shipping actual localizations is a feature request, not a defect.

- **"Zero KB" is `ByteCountFormatter`'s documented default.** It comes from
  `allowsNonnumericFormatting`, which defaults to `true`. Reads oddly next to "0 items", and
  setting that flag to `false` would render "0 KB", but this is Apple's default rather than an
  application defect. Cosmetic only.

- **Xcode DerivedData reporting 0 items is correct.** `~/Library/Developer/Xcode/DerivedData`
  genuinely contains zero entries (12K, all of it the directory itself) on this machine. The
  provider is right; there is nothing to clean.

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
- Tests: `xcodebuild -project SpaceMender.xcodeproj -scheme SpaceMender -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` — 122 tests, 20 suites, all passing (119 before the #01/#07 and #10 fixes added three)
- UI verified by reading the live accessibility tree of the running app and driving it
  (scan, expand category, activate the copy-details link, inspect the clipboard). #10 and #11
  were found this way and would not have been found by reading code alone.
- Note: on this machine `npm config get cache` returns the default `~/.npm`, which is why
  issue #01's npm symptom is latent locally. It affects users with Homebrew, nvm, Volta, or an
  explicit `npm config set cache`.
