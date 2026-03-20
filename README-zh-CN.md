# Swift Sequential Executor

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fshensven%2Fswift-sequential-executor%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/shensven/swift-sequential-executor)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fshensven%2Fswift-sequential-executor%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/shensven/swift-sequential-executor)

[English](README.md)｜简体中文

一个用于协调定时任务与立即执行请求的串行异步执行器。

## 为什么不直接用 Timer

[`Timer.scheduledTimer(...)`](https://developer.apple.com/documentation/foundation/timer/scheduledtimer(withtimeinterval:repeats:block:)) 适合“过一会儿再触发一次回调”这类需求。但当回调内部需要执行异步任务时，调用方往往还需要自己处理可能会遇到的并发协调问题。

## SequentialExecutor 适合这些场景

- 想定时执行异步任务，但前一次没结束时不要重叠
- 想在定时等待过程中，随时插入一次立即执行
- 想在立即执行前，先取消并等前一个任务真正结束
- 想把开始、结束、取消、失败这些事件稳定地交给日志、监控或 UI

> [!TIP]
> 核心接口只聚焦在 `execute`、`eventHandler`、`events()`、`updatePolicy(_:)` 和 `runNow()`
>
> 其他细节都被封装在内部 ;-)

## 环境要求

| 平台 | Swift 版本 | 安装方式 | 状态 |
| --- | --- | --- | --- |
| macOS 13.0+<br>iOS 16.0+<br>tvOS 16.0+<br>watchOS 9.0+<br>visionOS 1.0+ | Swift 6.0+ / Xcode 16.0+ | Swift Package Manager | [![Apple Tests](https://github.com/shensven/swift-sequential-executor/actions/workflows/tests-apple.yml/badge.svg)](https://github.com/shensven/swift-sequential-executor/actions/workflows/tests-apple.yml) |
| Linux | Swift 6.0+ | Swift Package Manager | [![Linux Tests](https://github.com/shensven/swift-sequential-executor/actions/workflows/tests-linux.yml/badge.svg)](https://github.com/shensven/swift-sequential-executor/actions/workflows/tests-linux.yml) |

## 安装

### Swift Package Manager

只要你的 Swift 包或 Xcode 工程已经建立好，就可以把 `swift-sequential-executor` 添加到 `Package.swift` 的 `dependencies`，或者加到 Xcode 的包依赖列表里。

下面示例使用已经发布的 `1.0.0` 版本：

```swift
dependencies: [
    .package(url: "https://github.com/shensven/swift-sequential-executor.git", from: "1.0.0")
]
```

然后在 target 中依赖 `SequentialExecutor` 这个产物：

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SequentialExecutor", package: "swift-sequential-executor")
        ]
    )
]
```

## 快速开始

```swift
import Foundation
import SequentialExecutor

let executor = SequentialExecutor(
    execute: { context in
        print("triggered by \(context.source)")
        try await Task.sleep(for: .seconds(2))
    },
    eventHandler: { event in
        print(event.kind)
    }
)

await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))
await executor.runNow()

```

这段代码可以放在任意异步上下文中运行，例如应用启动流程、异步测试，或者一个 `Task` 里。每次执行开始时，执行器都会把当前的 `ExecutionContext` 传给 `execute` 闭包；`updatePolicy(_:)` 用来开启固定间隔调度，`runNow()` 用来发起一次立即执行。

如果你不需要让初始化器里的 `execute` 参数接收上下文值，也可以使用一个更简洁的便利初始化器：

```swift
let executor = SequentialExecutor {
    try await Task.sleep(for: .seconds(2))
}
```

注意：如果事件处理本身比较重，或者更希望以异步流的方式消费事件，也可以通过 `events()` 订阅：

```swift
let executor = SequentialExecutor {
    try await Task.sleep(for: .seconds(2))
}

let eventTask = Task {
    for await event in await executor.events() {
        print(event.kind)
    }
}

await executor.runNow()
eventTask.cancel()
```

如果你想调试更完整的运行行为，可以继续查看[示例应用](#示例应用)。

## 行为概览

从高层来看，`SequentialExecutor` 的运行行为可以先抓住 3 个要点：

- 任意时刻只会有一个执行真正处于运行中
- `runNow()` 会发起一次立即执行，但不会粗暴打断一个已经在运行的任务
- 一次立即执行结束后，调度循环是否恢复，要看当前策略是否仍然保持启用

如果你现在只关心怎样把它接入到项目里，读到这里通常已经足够；如果你还想进一步理解完整的运行时模型，可以继续看下面的状态和执行流程。

<details>
<summary>状态模型</summary>

从可见的运行时状态来看，执行器可以用 4 个状态来描述：

- `Idle`：调度循环已关闭，当前没有任务在执行
- `Waiting`：调度循环已开启，正在等待下一个间隔到来
- `ScheduledExecution`：因为间隔到期而启动的一次执行
- `ImmediateExecution`：因为 `runNow()` 请求立即执行而启动的一次执行

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle: 循环已关闭<br/>当前没有执行中的任务

    Idle --> Waiting: updatePolicy(interval)
    Waiting: 定时循环等待中

    Waiting --> ScheduledExecution: intervalElapsed
    ScheduledExecution: execute(context)<br/>source = scheduledLoop
    ScheduledExecution --> Waiting: executionFinished / Cancelled / Failed

    Idle --> ImmediateExecution: runNow()
    Waiting --> ImmediateExecution: runNow()<br/>先停止循环
    ScheduledExecution --> ImmediateExecution: runNow()<br/>先取消当前执行

    ImmediateExecution: execute(context)<br/>source = runNow
    ImmediateExecution --> Waiting: executionFinished / Cancelled / Failed<br/>策略仍为固定间隔模式
    ImmediateExecution --> Idle: executionFinished / Cancelled / Failed<br/>策略已禁用

    Waiting --> Idle: updatePolicy(disabled)
    Waiting --> Waiting: updatePolicy(new interval)<br/>重新开始等待
```

</details>

<details>
<summary>替换执行流程</summary>

`runNow()` 不会并行叠加执行。它会协调一次替换执行；如果当前已经有任务在运行，就先等待取消协作完成。

更具体地说：

- 如果当前正处于等待下一个间隔的状态，那么这次等待会先被取消
- 如果当前已经有任务在执行，执行器会先请求取消该任务，并等待它返回
- 只有前一次执行真正结束后，替代执行才会开始
- 如果在这段取消协调尚未完成时又连续到来多个 `runNow()` 调用，较早的待处理请求会让位给最新的那个请求
- 每一次立即执行请求仍然都会被单独记录下来，但并不是每个请求都一定会真正启动一次执行
- 如果当前任务没有正确配合 cancellation，替代执行的开始时间就可能被延后
- 这次立即执行结束后，只有在当前策略仍然允许的前提下，调度循环才会恢复等待

下面这张时序图描述的是固定间隔策略已经生效时的一条代表性路径：

```mermaid
sequenceDiagram
    participant Caller as 调用方
    participant Executor as 执行器
    participant Observer as 事件观察者

    Caller->>Executor: updatePolicy(interval)
    Executor-->>Observer: policyUpdated
    Executor-->>Observer: loopStarted
    Executor-->>Observer: waitStarted

    Caller->>Executor: runNow()
    Executor-->>Observer: requested
    Executor-->>Observer: loopStopped(runNowRequested)
    Executor-->>Observer: waitCancelled
    Executor-->>Observer: executionStarted(source: runNow)
    Note over Executor: await execute(context)

    alt execute 正常返回
        Executor-->>Observer: executionFinished
    else execute 抛出错误
        Executor-->>Observer: executionFailed
    else execute 被取消
        Executor-->>Observer: executionCancelled
    end

    opt 策略仍为固定间隔模式
        Executor-->>Observer: loopStarted
        Executor-->>Observer: waitStarted
    end
```

</details>

## 示例应用

仓库里包含一个 SwiftUI 示例应用，位置在 [`Examples/SequentialExecutorExample`](Examples/SequentialExecutorExample)。

你可以用它调试和观察 `SequentialExecutor` 的运行时行为，包括调度循环变化、立即执行、取消协调，以及生命周期事件的发出顺序。这个示例会把可见状态保持为事件驱动，方便直接检查等待与执行的时间线变化。

## API 细节

这一节只作为公开 API 和生命周期类型的参考索引使用。

### 初始化器

| 参数 | 作用 | 回调内容 |
| --- | --- | --- |
| `execute` | 真正执行业务工作的闭包。`SequentialExecutor` 每次启动一次执行时，都会带着当前执行上下文调用它一次。 | 一个 `context` 参数，包含当前执行的元数据，例如 `executionID` 和 `source`。 |
| `eventHandler` | 生命周期事件观察器。它会按顺序接收执行事件，方便你做日志、监控或同步外部状态。这个回调会在执行器的协调路径上同步调用，因此应该保持轻量且非阻塞。 | 一个 `event` 参数。它的顶层字段只有 `emittedAt` 和 `kind`；像 `executionID`、`source` 这类执行相关元数据，会出现在对应 `event.kind` case 的关联值中。 |

### 事件观察

`SequentialExecutor` 会通过两种观察 API 暴露同一套生命周期 `Event`。两者的区别主要在交付方式，而不是事件内容。

| API | 交付方式 | 更适合 | 需要注意 |
| --- | --- | --- | --- |
| `eventHandler` | 初始化时配置的同步回调 | 需要一个固定、轻量，并且希望在协调路径上立即收到事件的观察者 | 不要在这里做重活。磁盘 I/O、网络请求、主线程切换或复杂日志处理都会直接拖慢执行器；更合适的做法是把重操作转交给其他 `Task` 或队列。 |
| `events(bufferingPolicy:)` | 可通过 `for await` 消费的 `AsyncStream<Event>` | 需要异步消费、动态订阅，或者希望每个消费者自行选择 buffering 行为 | 慢消费者仍然可能因为事件缓冲策略的设置而积压事件或丢失事件。 |

### 调度策略

这里列出的是 `SequentialExecutor.Policy` 的公开配置方式。

| API | 含义 | 说明 |
| --- | --- | --- |
| `Policy(runLoop: .disabled)` | 关闭调度循环，不会再启动基于固定间隔的执行。 | 通过 `updatePolicy(_:)` 应用。 |
| `Policy(runLoop: .interval(duration))` | 开启调度循环，并在每次执行之间等待 `duration`。 | 通过 `updatePolicy(_:)` 应用，且 `duration` 必须大于 0。 |

### 执行上下文

这里列出的是 `SequentialExecutor.ExecutionContext` 的字段索引。

| 字段 | 含义 |
| --- | --- |
| `executionID` | 当前这次执行的唯一标识。它会和对应的执行生命周期事件保持一致。 |
| `source` | 触发这次执行的来源：要么是 `runNow(requestID:)`，要么是 `scheduledLoop(loopID:)`。 |

### 事件枚举

这里列出的是 `SequentialExecutor.Event.Kind` 的 case 索引。

| `event.kind` | 含义 |
| --- | --- |
| `requested(requestID:)` | 通过 `runNow()` 发起了一次立即执行请求。 |
| `executionStarted(executionID:source:)` | 一次执行已经开始，且即将进入 `execute(context)`。 |
| `executionFinished(executionID:source:)` | 一次执行成功完成。 |
| `executionCancelled(executionID:source:)` | 一次执行被取消。 |
| `executionFailed(executionID:source:error:)` | 一次执行因错误失败。 |
| `policyUpdated(previous:new:)` | 执行器的策略配置已更新。 |
| `loopStarted(loopID:)` | 一个新的调度循环已经启动。 |
| `loopStopped(loopID:reason:)` | 当前调度循环被请求停止。 |
| `loopExited(loopID:)` | 当前调度循环已经完全退出。 |
| `waitStarted(loopID:interval:)` | 调度循环开始等待下一个间隔。 |
| `waitCancelled(loopID:)` | 当前等待被取消。 |
| `waitFailed(loopID:error:)` | 当前等待因错误失败。 |
| `intervalElapsed(loopID:)` | 配置的间隔已到期，调度循环可以继续安排执行。 |

### 循环停止原因

这里列出的是 `SequentialExecutor.LoopStopReason` 的 case 索引。

| `reason` | 含义 |
| --- | --- |
| `runNowRequested` | 调度循环因为 `runNow()` 发起立即执行而被停止。 |
| `policyDisabled` | 调度循环因为当前策略关闭了定时执行而被停止。 |
| `policyUpdated` | 调度循环因为策略变更，需要从干净状态重新启动调度而被停止。 |
