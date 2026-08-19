---
title: "Tool-failure warnings are self-referential and hide the only actionable text behind a copy-to-clipboard link"
labels: [bug, ux, priority-medium]
---

## Summary

When an external tool fails, the warning shown to the user instructs them to *"Review this
category's warning"* — while **being** that warning. The text that would actually explain the
failure is placed in `technicalDetails`, which is never displayed; it can only be copied to the
clipboard and pasted somewhere else.

## Evidence

`Sources/Models/UserFacingError.swift:118-130`:

```swift
private static func toolFailure(
    operation: Operation,
    categoryName: String,
    details: String
) -> UserFacingError {
    UserFacingError(
        message: operation == .scan
            ? String(localized: "\(categoryName) couldn’t be scanned.")
            : String(localized: "The cleanup tool couldn’t complete \(categoryName)."),
        recoverySuggestion: String(localized: "Review this category’s warning, quit affected apps, then rescan and try again."),
        technicalDetails: bounded(details)   // <- the only text with real information
    )
}
```

`message + recoverySuggestion` are concatenated into the category warning, so the rendered
string at `Sources/Views/OverviewView.swift:134-141` reads:

> **Warning:** Homebrew cleanup couldn't be scanned. Review this category's warning, quit
> affected apps, then rescan and try again.

`technicalDetails` is rendered only as a link at `Sources/Views/OverviewView.swift:142-148`:

```swift
if let details = provider.technicalDetails, !details.isEmpty {
    Button("Copy Technical Details") { copy(details) }
        .buttonStyle(.link)
}
```

There is no code path that displays `technicalDetails` on screen. Clicking the link and
inspecting the clipboard yields the text the user needed all along:

```
Exit status: 1
Error: $HOME must be set to run brew.
```

## Impact

Three separate problems compound:

1. **The advice is circular.** "Review this category's warning" is printed *inside* the
   category's warning. It refers the user to itself.
2. **The advice is wrong.** "Quit affected apps" is generic boilerplate applied to every tool
   failure. No app was holding anything open — the process failed for an unrelated reason. It
   sends the user to do irrelevant work.
3. **The real cause is unreachable without a clipboard round-trip.** A user must notice a link
   labelled "Copy Technical Details", click it, then paste into another application to read one
   line of text. Most users will never do this, and will conclude the app is simply broken.

This is not hypothetical: it is exactly what made issue
[#10](10-child-processes-launched-with-empty-environment.md) hard to diagnose. The app knew the
precise cause (`$HOME must be set to run brew`), captured it correctly, and then declined to
show it.

## Suggested fix

Display the technical details inline instead of hiding them behind a copy action — a
`DisclosureGroup` ("Show details") or a monospaced caption under the warning keeps the summary
clean while making the cause reachable in one click, with the copy button retained for filing
reports.

Additionally, stop asserting a cause the app has not established. Replace the fixed
`recoverySuggestion` at `Sources/Models/UserFacingError.swift:127` with either a neutral
suggestion ("Rescan to try again.") or one selected from the actual failure — the common
recoverable case (a file held open by a running app) can be detected rather than assumed, and
`RunningApplicationChecking` is already injected into every
`ExternalCommandCleanupProvider` for precisely that purpose.

## Related

`Sources/Views/ContentView.swift:279-285` renders the same copy-only pattern for cleanup
outcomes and needs the same treatment.

## Status

**Fixed.** Three changes, all three complaints addressed:

1. **Details are on screen.** `OverviewView` and `ContentView` now render `technicalDetails`
   inline in a `DisclosureGroup("Details")` with selectable monospaced text. The copy button is
   kept inside it for filing reports, but is no longer the only way to read the text.
2. **Alerts carry the details too.** An alert cannot host a disclosure control, so
   `UserFacingError.detailedAlertMessage` appends the technical details to the message and
   `ContentView`'s alert uses it. `alertMessage` is unchanged, which keeps the existing
   invariant that raw tool output never appears in a *category warning* summary.
3. **The suggestion no longer refers to itself or invents a cause.** The text is now
   *"The tool’s own message is in the details below. Resolve it, then rescan."* — accurate in
   both surfaces, since both now show the details.

### Verification

`Tests/FailureVisibilityTests.swift`, all verified to **fail against the pre-fix code**:

- `toolFailureSuggestionDoesNotReferToItself` —
  `Expectation failed: !((suggestion → "Review this category’s warning, quit affected apps, …").localizedCaseInsensitiveContains("this category’s warning") → true)`
- `toolFailureMakesTheToolsOwnMessageReadable` — details missing from `detailedAlertMessage`.
- `technicalDetailsAreRenderedOnScreenAndNotOnlyCopied` — no inline rendering in either view.

Confirmed in the running app by provoking a **real** tool failure: the app was launched with
`HOMEBREW_PREFIX` pointing at a stub `brew` that exits 1. No system state was modified. The
overview showed

> Homebrew cleanup — **Scan failed**
> Warning: Homebrew cleanup couldn’t be scanned. The tool’s own message is in the details
> below. Resolve it, then rescan.
> ▸ Details → `Exit status: 1  Error: Cask 'ghostty' is not installed. Cannot compute cleanup.`

The cause is now readable in one click instead of requiring a clipboard round-trip.

### Existing tests that changed

Three tests asserted on the exact old sentence:

- `UserFacingErrorTests.commandFailureKeepsRawOutputOutOfPrimaryMessage` asserted
  `recoverySuggestion?.contains("rescan")`. Rather than weaken it, the new copy keeps the app's
  established verb, so the assertion still holds unchanged.
- `CleanupProviderArchitectureTests` and `CleanupExecutorTests` asserted
  `message.contains("rescan and try again")` — the full marketing sentence. These were loosened
  to `contains("rescan")` with a comment stating the contract: a failed outcome must carry
  recovery guidance, but the exact wording is not the contract. They still fail if the guidance
  disappears.
