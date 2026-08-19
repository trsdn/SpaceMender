---
title: "XPC calls to the privileged helper have no timeout and can hang cleanup indefinitely"
labels: [bug, robustness, priority-low]
---

## Summary

`DefenderPrivilegedHelperClient.call(...)` awaits a continuation that is resumed only by the
helper's reply, an interruption, or an invalidation. If the helper accepts the connection and
then never replies — deadlock, an unhandled error before the reply block runs, or a stall
inside a long `remove` — the `await` never returns and the UI stays in its in-progress state
forever.

## Evidence

`Sources/Services/DefenderPrivilegedHelperClient.swift:103-127`:

```swift
connection.interruptionHandler = { gate.resume(throwing: .connectionInterrupted) }
connection.invalidationHandler  = { gate.resume(throwing: .connectionInvalidated) }
connection.resume()
...
return try await withCheckedThrowingContinuation { continuation in
    gate.install(continuation)
    operation(proxy) { data in ... }        // <- only resumption path on success
}
```

The two handlers cover the connection *dying*. They do not cover a live connection that never
answers. There is no `Task.timeout`, no watchdog, and no deadline anywhere in this file.

## Impact

- `remove(candidates:)` is awaited on the cleanup path, so a stalled helper leaves the app
  showing "Cleaning…" indefinitely with no cancel affordance.
- `refreshAvailability()` awaits `status(reply:)`, so a stalled helper can also pin the
  Defender health state permanently at its previous value.

Severity is low because the helper is first-party and small — but it runs as **root**, and
root daemons are exactly where a stall should be assumed possible rather than designed out by
optimism.

## Suggested fix

Race the continuation against a deadline and fail closed:

```swift
return try await withThrowingTaskGroup(of: Response.self) { group in
    group.addTask { try await withCheckedThrowingContinuation { ... } }
    group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw DefenderHelperClientError.timedOut
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
}
```

`XPCReplyGate` already guarantees single-resumption, so an added timeout path cannot
double-resume the continuation. `connection.invalidate()` in the existing `defer` (line 110)
will tear the connection down on the timeout path.

A `.timedOut` case should be added to `DefenderHelperClientError` and surfaced as a normal
user-facing failure rather than a hang.

## Status

**Fixed** — every XPC call now runs under a deadline (30 s by default, injectable for tests).
`DefenderHelperClientError.timedOut` was added, and `call` arms the timeout via
`DefenderPrivilegedHelperClient.armTimeout(on:after:)` and cancels it once the call settles.

### Correction to this report

The suggested `withThrowingTaskGroup` approach **would not have worked**. A task group only
returns once *every* child has finished, and a task suspended inside
`withCheckedThrowingContinuation` ignores cancellation entirely. Racing the continuation against
a sleeping sibling therefore deadlocks: the timeout fires, `cancelAll()` has no effect on the
suspended child, and the group waits forever — swapping a hang for a different hang.

This was not theory. The first version of the regression test used exactly that pattern and hung
the test run for over 10 minutes until it was killed.

The working approach resumes the **gate** instead. `XPCReplyGate` already guarantees a single
resumption across the reply, interruption, invalidation and proxy-error paths, so a timeout is
simply a fifth racer: whoever arrives first wins, the rest are ignored, and the continuation is
unblocked immediately.

### Verification

- `Tests/XPCTimeoutTests.swift` — 5 tests: an unanswered call fails instead of hanging, a timely
  reply is undisturbed, a late reply cannot double-resume (which would trap), cancellation stops
  the timer, and the production `call` path really arms it.
- The tests carry their own rescue watchdog, so a future regression makes the suite **fail in
  ~10 s rather than hang**. A hanging CI is worse than a red one.
- Red-proofed behaviourally (API kept, arming removed and the timeout body neutered):

  ```
  ✘ aCallThatNeverRepliesFailsInsteadOfHangingForever() failed after 5.106 seconds
    Expectation failed: expected error ".timedOut" of type DefenderHelperClientError,
    but "WatchdogExpired()" was thrown instead
  ```

  That message is the proof: without the fix, only the test's own rescue ever unblocked the call.

**Not verified in the running app:** the privileged helper is not installed on this machine, so
the XPC path cannot be exercised end-to-end. The app was rebuilt, relaunched and re-inspected to
confirm no regression, but the timeout itself is proven at the unit level only.
