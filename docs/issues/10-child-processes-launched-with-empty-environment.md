---
title: "Every external command runs with a completely empty environment, permanently breaking the Homebrew provider"
labels: [bug, priority-high, regression-risk]
---

## Summary

`ProcessRunner` assigned `Process.environment = nil` whenever a caller did not supply an
explicit environment. On Darwin this does **not** inherit the parent's environment — it
launches the child with an entirely empty one: no `HOME`, no `PATH`, no `USER`.

Every external tool SpaceMender shells out to was affected. The user-visible symptom was the
Homebrew provider reporting **"Scan failed"** on every scan, forever.

## Evidence

`Sources/Services/ProcessRunner.swift:8-28` (before the fix):

```swift
func run(
    executable: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,   // <- callers rely on nil meaning "inherit"
    ...
) async throws -> ProcessResult {
    ...
    process.environment = environment       // <- nil here means EMPTY, not inherited
```

`Sources/Services/CommandRunner.swift:16-20` — the shared runner every provider uses never
passes an environment, so it always took the `nil` path:

```swift
func run(executable: URL, arguments: [String]) async throws -> CommandResult {
    let result = try await processRunner.run(
        executable: executable,
        arguments: arguments          // <- no environment argument
    )
```

### Proof that `nil` means empty, not inherited

A minimal Foundation program compiled with the same toolchain:

```swift
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.environment = nil
// ... capture stdout ...
```

```
parent HOME = /Users/example
environment = nil        -> <<HOME ABSENT>>   [child env var count: 0]
environment = inherited  -> HOME=/Users/example   [child env var count: 70]
```

`/usr/bin/env` produced **0 bytes** with exit status 0 — the child environment really is empty.

### Proof that this is what the user sees

1. Launch the app, press **Scan All**.
2. Homebrew cleanup reports `Scan failed`, `0 items · Zero KB`.
3. Click **"Copy technical details for Homebrew cleanup"**; the clipboard contains:

```
Exit status: 1
Error: $HOME must be set to run brew.
```

4. `env -u HOME brew cleanup --dry-run` reproduces that exact string, while
   `brew cleanup --dry-run` on its own exits 0 in ~1.4s and prints
   `This operation would free approximately 104.2MB of disk space.`

## Impact

Homebrew cleanup was **100% broken** — never once functional in the shipping wiring, for every
user, on every scan. On this machine that silently hid 104.2 MB of reclaimable space, which is
the app's entire reason to exist.

The same empty environment was handed to `simctl`, `npm config get cache`, and `mdatp`
(`Sources/Services/DefenderHealthMonitor.swift:36-45` uses `ProcessRunner` directly and was
equally affected). Those tools happen to tolerate a missing `HOME` better than `brew` does, so
they degraded quietly instead of failing loudly — arguably worse, because
`NpmCacheDiscovery` falling back to a default cache path produces a *wrong* answer rather than
an error.

Note the irony at `Sources/Services/CleanupProvider.swift:588-591`: a comment already warns
that "GUI apps do not inherit a login shell's `PATH`" and resolves `brew` by absolute path to
compensate. The environment handed to the child process was overlooked.

## Suggested fix

Make `nil` mean what every call site already assumed. In `ProcessRunner.run`:

```swift
process.environment = environment ?? ProcessInfo.processInfo.environment
```

Fixing it at the root repairs `brew`, `simctl`, `npm`, and `mdatp` in one change, and preserves
the ability to pass an explicit environment for tests and sandboxed invocations.

## Status

**Fixed.** Two regression tests were added to `Tests/ProcessRunnerTests.swift`:

- `inheritsParentEnvironmentWhenNoneIsSpecified` — verified to **fail against the pre-fix code**
  with `Expectation failed: (result.standardOutput.text → "") == (parentHome → "/Users/example")`
  before being kept.
- `usesExplicitEnvironmentWhenSpecified` — pins the override path so the fix cannot regress into
  unconditionally merging the parent environment.

Verified end to end in the running app: Homebrew cleanup now reports
**`1 item · 104,2 MB · Available`**, matching `brew cleanup --dry-run` exactly.

## Why the test suite never caught this

Every provider test injects a fixture command runner (`FixedOutputCommandRunner`,
`RecordingCommandRunner`, `ScannerCommandRunner`), so no test ever spawned a real process
through the real `CommandRunner`. `Tests/ProcessRunnerTests.swift` did exercise a real process,
but only asserted on output draining, truncation, and timeouts — never on the child's
environment. The one seam where production and tests diverge is exactly where the bug lived.
