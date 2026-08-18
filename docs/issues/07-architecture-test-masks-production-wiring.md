---
title: "Architecture test wires a shared catalog that production never uses, masking issue #01"
labels: [bug, testing, priority-medium]
---

> **Status: fixed.** `viewModelBuildsEveryServiceFromOneCatalog` now drives a real
> `AppViewModel` with a stateful fixture provider that fails execution unless discovery ran on
> the same instance. Verified to fail (3 assertions) against the pre-fix wiring and pass after
> it. This document is retained as the audit record.

## Summary

`CleanupProviderArchitectureTests` constructs one catalog and injects it into both the scanner
and the executor. Production does the opposite: every service default-constructs its own
catalog. The test therefore validates a wiring that does not ship, and stays green while the
real wiring is broken.

## Evidence

Test wiring — `Tests/CleanupProviderArchitectureTests.swift:8-11`:

```swift
let provider = FixtureProvider()
let catalog  = CleanupProviderCatalog(providers: [provider])
let scanner  = CleanupScanner(catalog: catalog)     // same instance
let executor = CleanupExecutor(catalog: catalog)    // same instance
```

Production wiring — `Sources/ViewModels/AppViewModel.swift:57-62`: each service is
default-constructed, and each default argument calls the **computed** property
`CleanupProviderCatalog.builtIn` (`Sources/Services/CleanupProvider.swift:95-97`), so each
service receives a *different* catalog with *different* provider instances.

The test then asserts the scan-then-clean round trip at lines 18-26 — the exact flow that
issue #01 breaks in production, because the provider instance that discovered state during
scanning is not the instance asked to execute.

## Impact

This is the specific reason the suite reports **119/119 passing** while npm cleanup is broken
for anyone with a non-default cache path. The one test whose stated purpose is to protect the
provider architecture is the one that hides the defect, which makes the green suite actively
misleading.

## Suggested fix

1. Once issue #01 is fixed (a single shared catalog injected into all services), add a test
   that asserts the production invariant directly:

   ```swift
   @Test
   func scannerAndExecutorShareProviderInstances() {
       let viewModel = AppViewModel()
       // assert the scanner's and executor's provider for a given rule id are identical (===)
   }
   ```

2. Add a stateful fixture provider — one that records discovery during `scan` and fails
   `execute` if that discovery is missing — so the scan/execute instance split cannot regress
   silently. This is precisely npm's failure mode
   (`Sources/Services/NpmCacheDiscovery.swift:131`,
   `everDiscoveredRootsByPath` is per-instance).

3. Consider making `CleanupProviderCatalog.builtIn` a `static let` so the test and production
   paths cannot diverge in the first place.
