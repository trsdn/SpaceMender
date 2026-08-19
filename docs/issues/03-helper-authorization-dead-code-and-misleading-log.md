---
title: "Helper client-authorization policy is dead code and the acceptance log claims validation it never performs"
labels: [bug, security-hygiene, priority-medium]
---

## Summary

`DefenderClientAuthorizationPolicy` and its `DefenderCodeSignatureChecking` protocol have
**no production implementation or call site** — they are referenced only by tests. Meanwhile
the XPC listener delegate accepts every connection unconditionally while logging that it
validated the client's audit token.

## Scope note (important)

Client authentication **is** actually enforced, just somewhere else:
`HelperSources/DefenderHelperMain.swift:16` calls
`listener.setConnectionCodeSigningRequirement(requirement)`, and Foundation rejects
non-conforming peers before the delegate is consulted. **This is not an open root daemon.**

The defect is that the code reads as though a hand-rolled authorization path exists and runs,
when it does not. That is a maintenance hazard on the most security-sensitive component in
the app, and a test that provides false assurance.

## Evidence

`HelperSources/DefenderHelperListenerDelegate.swift:17-26` — unconditional accept, with a log
line asserting validation that this function never performs:

```swift
func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: DefenderHelperXPCProtocol.self)
    newConnection.exportedObject = serviceFactory()
    newConnection.resume()
    logger.info("Accepted client after audit-token code-signing validation")   // <- not done here
    return true
}
```

`Sources/PrivilegedHelperShared/DefenderClientAuthorization.swift:11-21` — never called in
production:

```swift
func authorizes(auditToken: Data) -> Bool { ... }
```

Repository-wide search for `DefenderClientAuthorizationPolicy` returns only the declaration
and `Tests/DefenderPrivilegedHelperSecurityTests.swift:158,165`. There is no conforming type
for `DefenderCodeSignatureChecking` outside the test file's `FixedSignatureChecker`.

`Tests/DefenderPrivilegedHelperSecurityTests.swift:156-170` (`unauthorizedClientFailsClosed`)
passes a hardcoded `FixedSignatureChecker(result: false)` into an unused struct. It exercises
no shipping code path, so it would stay green even if real authentication were removed
entirely.

## Impact

- A future maintainer reading the delegate reasonably concludes authentication is handled
  there, and may "simplify" `DefenderHelperMain` — silently removing the only real check on a
  **root-privileged** daemon.
- The log line is actively misleading during incident review.
- `unauthorizedClientFailsClosed` reports security coverage that does not exist.

## Suggested fix

1. Delete `DefenderClientAuthorizationPolicy` and `DefenderCodeSignatureChecking`, or wire
   them in as a genuine second check using the connection's `auditToken`.
2. Correct the log message to state what actually happened, e.g.
   `"Accepted client admitted by listener code-signing requirement"`.
3. Replace `unauthorizedClientFailsClosed` with a test that asserts the real invariant: that
   `DefenderHelperMain` exits when `SpaceMenderAuthorizedClientRequirement` is missing or
   empty (`HelperSources/DefenderHelperMain.swift:8-13`), which is the actual fail-closed
   behaviour worth protecting.
4. Add a comment at the delegate pointing to where enforcement really lives.

## Status

**Fixed** — `Sources/PrivilegedHelperShared/DefenderClientAuthorization.swift` (both
`DefenderClientAuthorizationPolicy` and `DefenderCodeSignatureChecking`) is deleted, the log line
no longer claims a validation the delegate never performs, and both the delegate and
`DefenderHelperMain` now point at where enforcement actually happens.

### The test that had to be replaced

`unauthorizedClientFailsClosed` exercised only the dead policy type. It passed reliably while the
helper's real defence went entirely unchecked — worse than having no test, because it advertised
security coverage that did not exist. Deleting it without replacement was not acceptable either.

Three tests now assert the **real** invariant instead:

| Test | Guards |
| --- | --- |
| `helperRefusesToRunWithoutAClientRequirement` | the requirement is handed to the listener, and a missing/empty one is fatal |
| `declaredClientRequirementIsNarrowEnoughToBeWorthEnforcing` | the requirement is Apple-anchored, names this app, and pins the team OU |
| `listenerDelegateDoesNotClaimValidationItNeverPerforms` | the misleading log and the dead policy do not come back |

`HelperSources` is a separate build target that the test bundle cannot link against, so the first
and third assert against source text — the same technique already used by
`Tests/ReleaseScriptSafetyTests.swift`. The second parses the real
`Configuration/DefenderHelper-Info.plist`.

### Verification

- Red-proofed by restoring the misleading log line:
  `✘ listenerDelegateDoesNotClaimValidationItNeverPerforms() failed … Expectation failed`.
- The helper target was force-relinked to confirm nothing depended on the deleted file; its
  binary shrank from 298,632 to 293,688 bytes.
- Full suite: 145 tests, all green.
