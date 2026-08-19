---
title: "Two Return presses permanently delete files: destructive default action on both the trigger and the confirmation"
labels: [bug, safety, ux, priority-medium]
---

## Summary

The "Review Cleanup" button and the "Clean Up" button in the confirmation sheet are **both**
bound to `.defaultAction`. Pressing Return twice — a reflex when dismissing a dialog — carries
the user from the overview all the way through permanent deletion without ever reading the
confirmation.

## Evidence

Trigger button, `Sources/Views/OverviewView.swift:94-99`:

```swift
Button("Review Cleanup", role: .destructive) {
    viewModel.requestOverviewCleanup()
}
.buttonStyle(.borderedProminent)
.tint(.red)
.keyboardShortcut(.defaultAction)      // <- Return opens the sheet
```

Confirmation button, `Sources/Views/OverviewView.swift:486-491`:

```swift
Button("Clean Up", role: .destructive, action: confirm)
    .accessibilityLabel("Confirm destructive cleanup")
    .buttonStyle(.borderedProminent)
    .tint(.red)
    .keyboardShortcut(.defaultAction)  // <- Return confirms and deletes
```

## Impact

The confirmation sheet is the app's **only** guard before irreversible deletion. The
repository's own safety documentation treats the frozen-plan confirmation as a core
invariant, yet the keyboard path defeats it entirely: two Return keystrokes and the plan
executes.

This is worse than a normal double-default-button bug because cleanup is not universally
undoable. Providers using `.permanentDelete` (npm cache contents, Homebrew cleanup, Defender
diagnostics) do **not** route through the Trash, so there is nothing to restore.

Apple's HIG is explicit that a destructive action should not be the default button, precisely
to prevent this.

## Reproduction

1. Launch the app and let the overview scan complete.
2. Press <kbd>⌘A</kbd> ("Select all safe items").
3. Press <kbd>Return</kbd> — the confirmation sheet opens.
4. Press <kbd>Return</kbd> again — deletion runs immediately.

The confirmation sheet is on screen for a fraction of a second and is never read.

## Suggested fix

Remove `.keyboardShortcut(.defaultAction)` from at least the confirmation's "Clean Up" button
(`OverviewView.swift:491`), leaving Cancel as the default so Return dismisses safely — the
standard macOS treatment for a destructive confirmation. `Cancel` already has
`.keyboardShortcut(.cancelAction)` at line 485, so Escape keeps working either way.

Ideally drop `.defaultAction` from both buttons and require an explicit click (or a distinct
shortcut such as <kbd>⌘⏎</kbd>) for the destructive step.

## Status

**Fixed.** `.keyboardShortcut(.defaultAction)` was removed from the confirmation's "Clean Up"
button (`OverviewView.swift`). Cancel keeps `.cancelAction`, so on the confirmation sheet
Return no longer deletes and Escape still dismisses.

`.defaultAction` was deliberately **kept** on "Review Cleanup": that button only opens a
reversible review sheet, and breaking the chain at the irreversible step is what matters.
Keyboard efficiency for the harmless step is preserved.

Two regression tests were added in `Tests/DestructiveConfirmationSafetyTests.swift`:

- `destructiveConfirmationIsNotTriggeredByReturn` — verified to **fail against the pre-fix
  code** with `Expectation failed: !((modifiers → ", action: confirm)…` before being kept.
- `cancelRemainsTheEscapeRouteOnTheConfirmation` — pins Escape as the escape route, so the fix
  cannot regress into removing both shortcuts.

### Why the tests assert against source text

SwiftUI keyboard shortcuts are not introspectable at runtime and the project has no UI-test
target, so there is no way to press Return against a real view in a unit test. The tests
therefore locate `OverviewView.swift` via `#filePath` and assert on the button's modifier
chain — the same technique `Tests/ReleaseScriptSafetyTests.swift` already uses to guard a
repository artifact. This is a weaker oracle than a synthetic key event, and is recorded here
so the limitation is not mistaken for full coverage.
