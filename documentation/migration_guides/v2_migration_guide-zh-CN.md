## SequentialExecutor v2 迁移指南

[English](v2_migration_guide.md)｜简体中文

2.0 是破坏性版本。固定延迟调度与“最新请求胜出”的轮替行为与 1.x 相同；变化的是由谁驱动
执行器，以及你要写的名字。下面按差异逐项说明，每项给出你的代码要怎么改。

### 最低 Swift 版本

包需要 Swift 6.1 或更高（Xcode 16.3）。升级工具链；如果你的包 `swift-tools-version`
低于 6.1，一并提高。

### 运行方式的差异

1.x 里 `updatePolicy(_:)` 会启动循环并由执行器维持。2.0 里在你从自己持有的任务中调用
`run()` 之前什么都不会运行，取消那个任务即停止一切。给每个执行器加一处 `run()` 调用，
并删掉为 1.x 写的收尾代码。

改前：
```swift
await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))
```

改后：
```swift
let run = Task { await executor.run() }   // SwiftUI 里写 .task { await executor.run() }
await executor.updatePolicy(.interval(.seconds(5)))
// 之后
run.cancel()
```

`runNow()` 同样需要这个 run。没有时它返回 `.notRunning`、不执行任何工作，所以只在 run
活动期间调用它。

### 策略的差异

`Policy` 变为两个 case 的枚举，`Policy.runLoop` 与 `Policy.RunLoop` 已移除。

改前：
```swift
await executor.updatePolicy(.init())
await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))

switch policy.runLoop {
case .disabled: ...
case let .interval(duration): ...
}
```

改后：
```swift
await executor.updatePolicy(.paused)
await executor.updatePolicy(.interval(.seconds(5)))

switch policy {
case .paused: ...
case let .interval(duration): ...
}
```

### 事件的差异

标识从 `UUID` 改为 `UInt`。循环事件改为 run 事件，等待事件去掉标识，`waitFailed` 已移除。

| 1.x | 2.0 |
| --- | --- |
| `.loopStarted(loopID:)` | `.runStarted(runID:)` |
| `.loopStopped(loopID:reason:)`、`.loopExited(loopID:)` | `.runEnded(runID:)` |
| `.waitStarted(loopID:interval:)` | `.waitStarted(interval:)` |
| `.waitCancelled(loopID:)`、`.intervalElapsed(loopID:)` | `.waitCancelled`、`.intervalElapsed` |
| `.waitFailed(loopID:error:)` | 已移除，去掉这个分支 |
| `ExecutionSource.scheduledLoop(loopID:)` | `ExecutionSource.scheduled` |
| `LoopStopReason` | 已移除 |

改前：
```swift
case let .loopStarted(loopID):
    log("loop \(loopID.uuidString.suffix(8))")
case let .executionStarted(executionID, .scheduledLoop):
    log("execution \(executionID.uuidString.suffix(8))")
```

改后：
```swift
case let .runStarted(runID):
    log("run \(runID)")
case let .executionStarted(executionID, .scheduled):
    log("execution \(executionID)")
```

### RunNowResult 的差异

`RunNowResult` 新增 `.notRunning(requestID:)`，穷举的 `switch` 要补这个分支。

执行器请求取消之后 `execute` 抛出的错误现在记为 `.cancelled`，不再是 `.failed`；由取消
请求决定结果。

改前：
```swift
switch await executor.runNow() {
case .finished, .cancelled, .failed, .superseded: ...
}
```

改后：
```swift
switch await executor.runNow() {
case .finished, .cancelled, .failed, .superseded: ...
case .notRunning: ...
}
```

### 事件流的差异

`events()` 仍可编译。`events(bufferingPolicy:)` 的参数类型改为
`AsyncStream<Event>.Continuation.BufferingPolicy`，`EventBufferingPolicy` 已移除。调用写法
不变，只有显式写过 `EventBufferingPolicy` 的代码要去掉这个名字。

改前：
```swift
let policy: SequentialExecutor.EventBufferingPolicy = .bufferingNewest(1)
let stream = await executor.events(bufferingPolicy: policy)
```

改后：
```swift
let stream = await executor.events(bufferingPolicy: .bufferingNewest(1))
```

### 移除的初始化器

`Event` 和 `ExecutionContext` 不再有公开初始化器。如果你在自己的代码里构造过它们，改为
读取执行器交给你的值。
