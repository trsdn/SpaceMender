---
title: "App launch performs blocking disk and launchd I/O on the main thread"
labels: [bug, performance, priority-medium]
---

## Summary

Constructing `CleanupProviderCatalog.builtIn` runs synchronous filesystem and launchd queries.
Because `AppViewModel` is `@MainActor` and is created as a `@StateObject` during the first
render, all of this executes on the main thread before the window can draw. Issue #01
multiplies the cost by building the catalog **five separate times**.

## Evidence

Blocking work performed inside catalog construction:

1. **Directory enumeration** — `Sources/Services/NpmCacheDiscovery.swift:53-56`, in the
   `NpmEnvironmentCacheRootDiscoverer` convenience initializer:

   ```swift
   if let versionDirectories = try? fileManager.contentsOfDirectory(
       at: nvmNodeVersions,
       includingPropertiesForKeys: nil
   ) {
   ```

2. **launchd service query** — `Sources/Services/DefenderPrivilegedHelperClient.swift:41-44`:

   ```swift
   init(service: SMAppService = .daemon(plistName: DefenderHelperConstants.launchDaemonPlistName)) {
       self.service = service
       availabilityStorage = Self.mapServiceStatus(service.status)   // synchronous XPC to launchd
   }
   ```

Both run as **default-argument expressions** of `CleanupProviderCatalog.builtIn(...)`
(`Sources/Services/CleanupProvider.swift:99-155`), so they are evaluated eagerly at each
construction site.

Call chain, all on the main actor:

```
SpaceMenderApp -> ContentView
  @StateObject private var viewModel = AppViewModel()          // @MainActor
    AppViewModel.init  ->  Sources/ViewModels/AppViewModel.swift:57-61
      CleanupScanner()          -> .builtIn(...) factory        (catalog 1)
      CleanupExecutor()         -> .builtIn(...) factory        (catalog 2)
      OverviewScanCoordinator() -> .builtIn computed property   (catalog 3)
      OverviewCleanupExecutor() -> .builtIn computed property   (catalog 4)
    rules = CleanupRule.builtIn                                 (catalog 5)
```

## Impact

`SMAppService.status` is an interprocess query to launchd, and `contentsOfDirectory` hits the
disk. Neither is bounded. On a cold start, a busy launchd, or an `NVM_DIR` on a slow or
network volume, the app shows a beachball or a blank window before first paint — with the
penalty paid **five times over** rather than once.

This is latency the user experiences as "the app is broken/hung" at exactly the moment of
first impression.

## Suggested fix

1. Fix issue #01 first — a single shared catalog immediately removes 80% of this cost.
2. Move discovery off the main actor: keep initializers pure (assign stored properties only)
   and perform the `contentsOfDirectory` / `SMAppService.status` probes lazily in the existing
   `async` discovery path, which already runs off the main actor.
3. `DefenderPrivilegedHelperClient` already exposes `refreshAvailability()` for this exact
   purpose — seed `availabilityStorage` with `.notInstalled` and let the async refresh
   populate it, instead of blocking in `init`.

## Status

**Fixed** — the unbounded filesystem probe is gone from the launch path.
`NpmEnvironmentCacheRootDiscoverer`'s initializers now only store values; the nvm version
enumeration happens inside `discoverCacheRoots()`, which already runs off the main actor.

### The report's premise was right, but its cost estimate was not

The report says the app "shows a beachball or a blank window before first paint". Before
changing anything, the actual cost was measured on this machine — with `~/.nvm` present and
holding two node versions, so the probe did real work:

| Measured operation | Cold first call | Median |
| --- | --- | --- |
| `CleanupProviderCatalog.builtIn()` (the whole production path) | **1.48 ms** | **0.70 ms** |
| `homeDirectoryForCurrentUser` | 1.3–2.0 ms | — |
| nvm `contentsOfDirectory` probe | 0.73 ms | 0.03 ms |
| `SMAppService.daemon(...).status` | 0.43–0.57 ms | 0.15 ms |

Nobody perceives 1.5 ms. So this was **not** fixed as a speed optimisation, and claiming a
visible startup win would be dishonest. It was fixed because `contentsOfDirectory` has **no
bounded latency**: on a network home directory, a stalled volume, or a contended login it can
block for seconds, and it did so before the first window was drawn. The fix removes a tail-risk,
not a measurable average cost.

### It was also a correctness bug the report did not mention

The candidate executable list was captured **once, in the initializer**, and the catalog is
built once per app launch (since #01). A node version installed while SpaceMender was running
therefore stayed invisible until the app was restarted. Rebuilding the list per discovery pass
fixes that, and `eachDiscoveryPassRebuildsTheCandidateList` guards it.

### What was deliberately *not* changed

Suggestion 3 — seeding `DefenderPrivilegedHelperClient.availabilityStorage` with
`.notInstalled` and letting `refreshAvailability()` fill it in — was **rejected**, because it
trades a correctness bug for 0.15 ms:

`PrivilegedOperationProvider.rule` (`Sources/Services/CleanupProvider.swift:266`) reads
`cachedAvailability` **synchronously** to decide what the sidebar renders. Seeding it with
`.notInstalled` would make the app briefly claim the helper is not installed on a machine where
it is, and the user could see that flash before the async refresh corrected it. `SMAppService`
is also a launchd query, not disk I/O, so it does not carry the same "stalled volume" tail risk
that motivated the npm change.

Honest caveat: `.status` was measured only on a machine where the helper is **not** registered,
which takes the fast `.notFound` path. With the helper registered, the launchd round trip is
likely slower, and its tail latency under login contention is unbounded. That case could not be
measured here, so this decision should be revisited if the helper ever becomes standard —
ideally by making the sidebar model an explicit `.unknown` state rather than by guessing.

Suggestion 1 (fix #01 first) was already done in the #01 fix; the catalog is now built once.

### Verification

- `Tests/LaunchInitializerPurityTests.swift` — 4 tests. They use a `FileManager` subclass that
  records every `contentsOfDirectory` call, so the assertion is "no enumeration happened",
  not "it was fast" — a timing assertion would be flaky and could not tell a quick probe apart
  from no probe.
- Red-proofed behaviourally: the eager probe was restored inside the convenience initializer
  while the new API was left in place, producing genuine expectation failures
  (`directoryListings → [file:///…/versions/node/]).isEmpty → false`), not compile errors.
- The existing `candidateExecutables:` initializer signature was kept unchanged, so all
  pre-existing npm tests still exercise the same surface.
