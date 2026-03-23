# ``SequentialExecutor``

A lightweight executor for running async tasks one at a time, on schedule or on demand.

## Overview

`SequentialExecutor` is useful when you need to run an async task repeatedly without letting it overlap with the previous run.

It has 3 core behaviors:

- Only one async task runs at a time
- Tasks can run on a fixed interval or be triggered immediately
- When a new task needs to take over, the current task exits through cooperative cancellation

The most commonly used APIs are ``init(execute:eventHandler:)``, ``updatePolicy(_:)``, and ``runNow()``.

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

If you only need scheduled execution, updating the policy is enough. If you also need to trigger a run immediately, call ``runNow()``.
