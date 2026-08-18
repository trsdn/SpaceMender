---
title: "Provider catalog is rebuilt on every access, so the instance that scans is never the instance that executes"
labels: [bug, architecture, priority-high]
---

## Summary

`CleanupProviderCatalog.builtIn` is a **computed** property. Every access constructs a
brand-new catalog with brand-new provider instances. `AppViewModel` builds **five**
independent catalogs, so a provider object that discovered items during a scan is never
the object asked to validate or execute them.

## Evidence

`Sources/Services/CleanupProvider.swift:95-97`

```swift
static var builtIn: CleanupProviderCatalog {
    builtIn()          // factory call -> all new provider instances
}
```

`Sources/ViewModels/AppViewModel.swift:55-62` — four services, each default-constructing its
own catalog:

```swift
init(
    result: CleanupScanResult? = nil,
    scanner: any CleanupScanning = CleanupScanner(),                  // catalog #1
    cleaner: any CleanupExecuting = CleanupExecutor(),                // catalog #2
    defenderHealthMonitor: any DefenderHealthMonitoring = MDATPHealthMonitor(),
    overviewScanner: any OverviewScanning = OverviewScanCoordinator(),// catalog #3
    overviewCleaner: any OverviewCleanupExecuting = OverviewCleanupExecutor(), // catalog #4
    historyStore: any CleanupHistoryStoring = CleanupHistoryStore()
) {
```

- #1 `Sources/Services/CleanupScanner.swift:21` — calls the `.builtIn(...)` **factory** directly.
- #2 `Sources/Services/CleanupExecutor.swift:54` — calls the `.builtIn(...)` **factory** directly.
- #3 `Sources/Services/OverviewCoordinator.swift:26` — `catalog: CleanupProviderCatalog = .builtIn`.
- #4 `Sources/Services/OverviewCoordinator.swift:227` — `catalog: CleanupProviderCatalog = .builtIn`.

plus `Sources/ViewModels/AppViewModel.swift:40`:

```swift
@Published private(set) var rules = CleanupRule.builtIn   // catalog #5
```

(`CleanupRule.builtIn` is itself `CleanupProviderCatalog.builtIn.rules`, `Sources/Models/CleanupRule.swift:361-363`.)

## Impact

This is only latent for stateless providers. It actively breaks `NpmCacheCleanupProvider`,
which keeps discovery results in **instance** memory and validates/executes against them:

- `Sources/Services/NpmCacheDiscovery.swift:131` — `everDiscoveredRootsByPath` is per-instance state.
- `Sources/Services/NpmCacheDiscovery.swift:157-160` — `validationRule` is built from that registry.
- `Sources/Services/NpmCacheDiscovery.swift:206-212` — `validate` and `execute` both use `validationRule`.

The executing instance never ran `discover()`, so its registry is empty, `makeRule` falls
back to `baseRule`, and the rule's locations collapse to the hardcoded defaults
(`Sources/Models/CleanupRule.swift:164-167`):

```
~/.npm/_cacache
~/.npm/_npx
```

Validation uses `.exactRoot`, which requires the item URL to equal a declared location
(`Sources/Services/CleanupProvider.swift:1145-1154`). A discovered non-default cache root
therefore never matches.

**User-visible result:** npm cleanup silently fails for every user whose npm cache is not
at `~/.npm` — precisely the Homebrew / nvm / Volta / `npm config set cache` users that
`NpmEnvironmentCacheRootDiscoverer` exists to support. It fails *closed* (no wrong deletion),
so this is a broken feature rather than data loss.

## Reproduction

```bash
npm config set cache ~/some/other/npm-cache
# populate it, then scan + select npm caches in SpaceMender and run cleanup
# -> items are discovered by the scan but fail validation at execute time
```

On a machine where the cache is at the default `~/.npm`, the fallback happens to match the
discovered path and the bug is invisible. That is why it has gone unnoticed.

## Suggested fix

Construct the catalog **once** and inject the same instance everywhere:

```swift
// one shared catalog for the whole app
let catalog = CleanupProviderCatalog.builtIn()

CleanupScanner(catalog: catalog)
CleanupExecutor(catalog: catalog)
OverviewScanCoordinator(catalog: catalog)
OverviewCleanupExecutor(catalog: catalog)
```

All four types already provide a secondary `init(catalog:)`
(`CleanupScanner.swift:28`, `CleanupExecutor.swift:62`, `OverviewCoordinator.swift:26` and
`:227`), so this is a wiring change, not a redesign.

Note that changing `static var builtIn` to a stored `static let` is **not sufficient on its
own**: `CleanupScanner` and `CleanupExecutor` invoke the `.builtIn(...)` *factory* directly
rather than reading the computed property, so they would still mint fresh providers. The
injection above is the actual fix; removing the computed convenience afterwards just stops the
sharp edge from being reintroduced.

See also #07 — the architecture test injects a shared catalog and therefore cannot catch this.
