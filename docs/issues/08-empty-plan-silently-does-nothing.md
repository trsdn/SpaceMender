---
title: "\"Review Cleanup\" silently does nothing when the frozen plan resolves to zero items"
labels: [bug, ux, priority-low]
---

## Summary

`requestOverviewCleanup()` returns without any feedback when the freshly built plan contains
no items. The button is enabled, the user clicks it, and nothing happens — no sheet, no
message, no state change.

## Evidence

`Sources/ViewModels/AppViewModel.swift:330-340`:

```swift
Task {
    let plan = await overviewScanner.makeCleanupPlan(
        selections: selections,
        snapshot: snapshot
    )
    guard !plan.items.isEmpty else {
        return                      // <- silent; no error, no sheet, no user-visible change
    }
    frozenOverviewPlan = plan
    showingOverviewConfirmation = true
}
```

The button's enabled state is driven by `canCleanOverview`
(`Sources/ViewModels/AppViewModel.swift:134`), which only checks that the *selection* is
non-empty:

```swift
!overviewSelectedItemIDs.isEmpty && !isScanning && !isCleaning
```

So the button is legitimately enabled while `makeCleanupPlan` can still return an empty plan —
the selection and the re-validated plan are computed at different times against different
state.

## Impact

The user has selected items and pressed the primary action. Getting no response at all is
indistinguishable from a frozen or broken app, and there is no way to tell whether the
selection was rejected, the files disappeared, or the click was simply not registered.

This is reachable whenever selected items stop qualifying between selection and confirmation:
another process deletes or rewrites the cache (`npm install`, an Xcode build touching
DerivedData), or every selected item fails re-validation.

## Suggested fix

Surface the outcome instead of swallowing it:

```swift
guard !plan.items.isEmpty else {
    presentedError = .emptyPlan   // or a non-error informational banner
    return
}
```

A message such as *"The selected items are no longer available — they may have changed since
the last scan. Rescan to refresh."*, ideally with an automatic rescan, tells the user what
happened and what to do next.

Note the sibling guard at `Sources/ViewModels/AppViewModel.swift:344-345`
(`performOverviewCleanup`) has the same silent-return shape and deserves the same treatment.

## Status

**Fixed.** Both silent returns now present `UserFacingError.emptyPlan`:

> **There was nothing left to clean.**
> The selected items were removed or changed since the last scan. Scan again to see what is
> there now.

- `requestOverviewCleanup` — the primary case: a selection that resolves to an empty plan used
  to return without a word, so the button looked dead.
- `performOverviewCleanup` — the defensive twin. It additionally closes the confirmation sheet,
  since leaving it open after a no-op strands the user on a dead dialog.

**Note on the suggested fix in this report:** `UserFacingError` is a `struct`, not an `enum`, so
the shorthand `presentedError = .emptyPlan` does not compile as written. It works here because a
static factory `UserFacingError.emptyPlan` was added for exactly that call site.

### Verification

`Tests/FailureVisibilityTests.swift`, both verified to **fail against the pre-fix code**:

- `emptyPlanIsReportedInsteadOfSilentlyDoingNothing` —
  `Expectation failed: (viewModel.errorMessage → nil) != nil`
- `confirmingAnEmptyFrozenPlanClosesTheSheetAndReports` — same, plus
  `Expectation failed: !((viewModel).showingOverviewConfirmation → true → true)`

The first drives the real `AppViewModel` through a scanner stub whose `makeCleanupPlan` returns
an empty plan — the shape of items that disappear between the scan and the moment the plan is
frozen.
