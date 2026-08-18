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
