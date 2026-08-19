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
