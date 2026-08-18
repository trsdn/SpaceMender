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
