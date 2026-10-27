## SequentialExecutor v2 Migration Guide

English｜[简体中文](v2_migration_guide-zh-CN.md)

Version 2.0 is a breaking release. Fixed-delay scheduling and latest-request-wins
handoff behave as they did in 1.x; what changes is who drives the executor and the
names you write. The rest of this guide is a series of differences and what to change
in your code for each.

### Minimum Swift version

The package requires Swift 6.1 or later (Xcode 16.3). Update your toolchain and, for
a package, raise `swift-tools-version` if it is below 6.1.

### Running differences

In 1.x, `updatePolicy(_:)` started the loop and the executor kept it alive. In 2.0
nothing runs until you call `run()` from a task you own, and cancelling that task
stops everything. Add one `run()` call per executor and remove any teardown you
wrote for 1.x.

Before:
```swift
await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))
```

After:
```swift
let run = Task { await executor.run() }   // in SwiftUI: .task { await executor.run() }
await executor.updatePolicy(.interval(.seconds(5)))
// later
run.cancel()
```

`runNow()` needs that run as well. Without one it returns `.notRunning` without
executing anything, so call it only while a run is active.

### Policy differences

`Policy` is an enum with two cases. `Policy.runLoop` and `Policy.RunLoop` are gone.

Before:
```swift
await executor.updatePolicy(.init())
await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))

switch policy.runLoop {
case .disabled: ...
case let .interval(duration): ...
}
```

After:
```swift
await executor.updatePolicy(.paused)
await executor.updatePolicy(.interval(.seconds(5)))

switch policy {
case .paused: ...
case let .interval(duration): ...
}
```

### Event differences

Identifiers are `UInt` instead of `UUID`. Loop events become run events, wait events
lose their identifier, and `waitFailed` is removed.

| 1.x | 2.0 |
| --- | --- |
| `.loopStarted(loopID:)` | `.runStarted(runID:)` |
| `.loopStopped(loopID:reason:)`, `.loopExited(loopID:)` | `.runEnded(runID:)` |
| `.waitStarted(loopID:interval:)` | `.waitStarted(interval:)` |
| `.waitCancelled(loopID:)`, `.intervalElapsed(loopID:)` | `.waitCancelled`, `.intervalElapsed` |
| `.waitFailed(loopID:error:)` | Removed; delete the case |
| `ExecutionSource.scheduledLoop(loopID:)` | `ExecutionSource.scheduled` |
| `LoopStopReason` | Removed |

Before:
```swift
case let .loopStarted(loopID):
    log("loop \(loopID.uuidString.suffix(8))")
case let .executionStarted(executionID, .scheduledLoop):
    log("execution \(executionID.uuidString.suffix(8))")
```

After:
```swift
case let .runStarted(runID):
    log("run \(runID)")
case let .executionStarted(executionID, .scheduled):
    log("execution \(executionID)")
```

### RunNowResult differences

`RunNowResult` gains `.notRunning(requestID:)`, so an exhaustive `switch` needs the
new case.

An error thrown by `execute` after the executor requested cancellation is now
reported as `.cancelled` rather than `.failed`; a cancellation request decides the
outcome.

Before:
```swift
switch await executor.runNow() {
case .finished, .cancelled, .failed, .superseded: ...
}
```

After:
```swift
switch await executor.runNow() {
case .finished, .cancelled, .failed, .superseded: ...
case .notRunning: ...
}
```

### Event stream differences

`events()` still compiles. `events(bufferingPolicy:)` takes
`AsyncStream<Event>.Continuation.BufferingPolicy` instead of the removed
`EventBufferingPolicy`. The call reads the same; only code that named
`EventBufferingPolicy` explicitly needs to drop that name.

Before:
```swift
let policy: SequentialExecutor.EventBufferingPolicy = .bufferingNewest(1)
let stream = await executor.events(bufferingPolicy: policy)
```

After:
```swift
let stream = await executor.events(bufferingPolicy: .bufferingNewest(1))
```

### Removed initializers

`Event` and `ExecutionContext` no longer have public initializers. If you constructed
them in your own code, read the values the executor hands you instead.
