# ``SequentialExecutor``

A lightweight executor for running async tasks one at a time, on schedule or on demand.

## Overview

`SequentialExecutor` is useful when you need to run an async task repeatedly without letting it overlap with the previous run.

`SequentialExecutor` provides these guarantees:

- Only one async task runs at a time
- Scheduled tasks run with a fixed delay and can also be triggered immediately
- When a new task needs to take over, the current task exits through cooperative cancellation
- Cancelling the task that called ``SequentialExecutor/run()`` ends waiting and any in-flight execution

The most commonly used APIs are `init(execute:eventHandler:)`, ``SequentialExecutor/run()``,
``SequentialExecutor/updatePolicy(_:)``, and ``SequentialExecutor/runNow()``.

### Quick Example

```swift
import Foundation
import SequentialExecutor

let executor = SequentialExecutor {
    try await Task.sleep(for: .seconds(2))
}

let run = Task {
    await executor.run()
}

await executor.updatePolicy(.interval(.seconds(5)))
// await executor.runNow()
```

``SequentialExecutor/run()`` drives the executor until the task that called it is
cancelled. Setting an interval waits for one full interval before the first
execution, then starts each later wait after the previous execution exits. To trigger
a run immediately, call ``SequentialExecutor/runNow()``.

``SequentialExecutor/runNow()`` returns a ``SequentialExecutor/RunNowResult``
after the requested execution exits, or as soon as a newer request supersedes it
before it starts. Without an active run it returns
``SequentialExecutor/RunNowResult/notRunning(requestID:)`` immediately. Errors thrown
by `execute` are returned as ``SequentialExecutor/RunNowResult/failed(_:_:)`` and are
also reported as ``SequentialExecutor/Event/Kind/executionFailed(executionID:source:error:)``
events.

The outcome of a started execution is decided by whether the executor requested its
cancellation, not by whether `execute` happened to finish its work:

- ``SequentialExecutor/RunNowResult/finished(_:)`` means `execute` returned normally
  and no cancellation was requested.
- ``SequentialExecutor/RunNowResult/cancelled(_:)`` means the executor requested
  cancellation before `execute` returned, or `execute` threw `CancellationError`. An
  error thrown after a cancellation request is not reported.
- ``SequentialExecutor/RunNowResult/failed(_:_:)`` means `execute` threw a
  non-cancellation error while no cancellation was requested.
- ``SequentialExecutor/RunNowResult/superseded(requestID:byRequestID:)`` means a
  newer request replaced it before it started.
- ``SequentialExecutor/RunNowResult/notRunning(requestID:)`` means no run was active
  when the request was made, or the run ended before the request started.

Cancelling the caller's task does not withdraw a submitted request. The execution
belongs to the run; only a newer ``SequentialExecutor/runNow()`` request or the end of
the run stops it, and that cancellation remains cooperative.

### Ownership and Lifetime

``SequentialExecutor/run()`` is the only thing that waits or executes. Waiting and
executing happen in tasks that `run()` owns and always awaits, so nothing outlives it.
In SwiftUI, call `run()` from a `.task` modifier so the run lives exactly as long as
the view, and keep the executor in the model that owns the scheduling policy.

Only one run is active at a time; a call made while another run is active waits for
it to end before starting. The ``SequentialExecutor/Policy`` only controls waiting:
``SequentialExecutor/Policy/paused`` keeps the run idle until the policy changes or
`runNow()` is called, and ``SequentialExecutor/Policy/interval(_:)`` waits for the
fixed delay between executions. Changing the policy never cancels an execution that
has already started.

The `execute` closure must cooperate with cancellation, either by throwing
`CancellationError` or by returning early; a non-cooperative API or unstructured child
task can delay handoff to a newer immediate request.

Independent tasks calling ``SequentialExecutor/updatePolicy(_:)`` race in actor
arrival order, which need not match task creation order. Give policy updates one
owner or serialize them at the call site.

### Scheduling Semantics

The scheduled loop uses fixed-delay rather than fixed-rate semantics:

```text
wait interval → execute → wait interval → execute
```

Pausing cancels an active wait but does not cancel an execution that has already
started. Changing the interval restarts an active wait; when an execution is already
running, the new delay applies after it exits.

### Observing Events

The optional ``SequentialExecutor/EventHandler`` observes events synchronously
on the executor's coordination path. Keep it lightweight. Use
``SequentialExecutor/events(bufferingPolicy:)`` for asynchronous or actor-isolated processing.

An event stream receives only events emitted after its subscription is created;
it does not replay earlier events. The default stream uses an unbounded buffer.
``SequentialExecutor/events(bufferingPolicy:)`` supports bounded buffering,
which may drop events without a separate notification.

### Event Ordering

For one `executionID`, ``SequentialExecutor/Event/Kind/executionStarted(executionID:source:)``
is always emitted before that execution's finished, cancelled, or failed event.
After ``SequentialExecutor/Event/Kind/requested(requestID:)``, no scheduled execution
starts until that request has settled; the next `executionStarted` belongs either to
that request or to a newer ``SequentialExecutor/runNow()`` request that superseded it.

``SequentialExecutor/Event/Kind/runStarted(runID:)`` precedes every wait and execution
event of a run, and ``SequentialExecutor/Event/Kind/runEnded(runID:)`` is the last
event of a run. Runs never overlap, so events of different runs never interleave.

Request, run, and execution identifiers come from one increasing counter per
executor, so no two of them share a number and a larger identifier was issued later.

## Topics

### Running

- ``SequentialExecutor/init(execute:eventHandler:)-9rdi0``
- ``SequentialExecutor/init(execute:eventHandler:)-82nqe``
- ``SequentialExecutor/run()``
- ``SequentialExecutor/updatePolicy(_:)``
- ``SequentialExecutor/runNow()``

### Observing

- ``SequentialExecutor/events(bufferingPolicy:)``
- ``SequentialExecutor/EventHandler``
- ``SequentialExecutor/Event``

### Values

- ``SequentialExecutor/Policy``
- ``SequentialExecutor/RunNowResult``
- ``SequentialExecutor/ExecutionContext``
- ``SequentialExecutor/ExecutionSource``
