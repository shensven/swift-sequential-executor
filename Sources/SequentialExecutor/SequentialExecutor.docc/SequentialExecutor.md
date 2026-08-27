# ``SequentialExecutor``

A lightweight executor for running async tasks one at a time, on schedule or on demand.

## Overview

`SequentialExecutor` is useful when you need to run an async task repeatedly without letting it overlap with the previous run.

`SequentialExecutor` provides these guarantees:

- Only one async task runs at a time
- Scheduled tasks run with a fixed delay and can also be triggered immediately
- When a new task needs to take over, the current task exits through cooperative cancellation

The most commonly used APIs are `init(execute:eventHandler:)`,
``SequentialExecutor/updatePolicy(_:)``, and ``SequentialExecutor/runNow()``.

### Quick Example

```swift
import Foundation
import SequentialExecutor

let executor = SequentialExecutor {
    try await Task.sleep(for: .seconds(2))
}

await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))
// await executor.runNow()
```

If you only need scheduled execution, updating the policy is enough. Scheduling
waits for one full interval before the first execution, then starts each later
wait after the previous execution exits. If you also need to trigger a run
immediately, call ``SequentialExecutor/runNow()``.

``SequentialExecutor/runNow()`` returns a ``SequentialExecutor/RunNowResult``
after the selected immediate execution exits, or as soon as a newer request
supersedes it before execution starts. Errors thrown by `execute` are returned
as ``SequentialExecutor/RunNowResult/failed(_:_:)`` and are also reported as
``SequentialExecutor/Event/Kind/executionFailed(executionID:source:error:)`` events.

The result distinguishes requests that started from those replaced before starting:

- ``SequentialExecutor/RunNowResult/finished(_:)`` means the request completed successfully.
- ``SequentialExecutor/RunNowResult/cancelled(_:)`` means it started and ended
  through cancellation.
- ``SequentialExecutor/RunNowResult/failed(_:_:)`` means it started and threw a
  non-cancellation error.
- ``SequentialExecutor/RunNowResult/superseded(requestID:byRequestID:)`` means a
  newer request replaced it before it started.

Cancelling the caller's task does not withdraw a submitted request. A newer
``SequentialExecutor/runNow()`` request asks the current execution to cancel,
and that cancellation remains cooperative.

### Ownership and Lifetime

Use `SequentialExecutor` when a long-lived service or model owns a fixed-delay
schedule and also needs latest-request-wins immediate execution. A view-scoped
loop that should end automatically when a SwiftUI view disappears is often
simpler as a structured `.task(id:)` loop using `Clock.sleep(for:)`.

The executor intentionally owns accepted work independently of the caller.
Cancelling a `.task` or `.refreshable` caller does not withdraw an accepted
``SequentialExecutor/runNow()`` request. The `execute` closure must cooperate
with cancellation; a non-cooperative API or unstructured child task can delay
handoff to a newer immediate request.

Independent tasks calling ``SequentialExecutor/updatePolicy(_:)`` race in actor
arrival order, which need not match task creation order. Give policy updates one
owner or serialize them at the call site.

### Scheduling Semantics

The scheduled loop uses fixed-delay rather than fixed-rate semantics:

```text
wait interval → execute → wait interval → execute
```

Disabling scheduling cancels an active wait but does not cancel an execution that
has already started. Changing the interval restarts an active wait; when an
execution is already running, the new delay applies after it exits.

### Observing Events

The optional ``SequentialExecutor/EventHandler`` observes events synchronously
on the executor's coordination path. Keep it lightweight. Use
``SequentialExecutor/events()`` for asynchronous or actor-isolated processing.

An event stream receives only events emitted after its subscription is created;
it does not replay earlier events. The default stream uses an unbounded buffer.
``SequentialExecutor/events(bufferingPolicy:)`` supports bounded buffering,
which may drop events without a separate notification.

Correlate loop lifecycle events by `loopID`. Events belonging to one loop are
ordered, but events from different loops may interleave—for example, an old loop
may exit after its replacement starts.
