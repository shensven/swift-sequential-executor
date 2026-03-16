# Swift Sequential Executor

[English](README.md)｜简体中文

## Why?

Apple 的 [`Timer.scheduledTimer(...)`](<https://developer.apple.com/documentation/foundation/timer/scheduledtimer(withtimeinterval:repeats:block:)>) 文档描述的是：它会把 timer 加到当前线程的 run loop 上。而在 Apple 的 [Run Loop 指南](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html) 里也明确提到，timer 并不是实时机制；它是否按时触发，取决于 run loop 是否正在运行、是否处于正确的 mode、以及当时是否有机会处理回调。

当需求只是“过一会儿再回调我一次”时，这没有问题。真正的痛点出现在你需要协调异步任务执行时：

- 它只负责把回调调度到 run loop 上，但并不知道上一次异步任务是否已经结束
- `repeats: true` 只表示 timer 会继续触发，并不等于任务会串行执行；重叠执行和重入控制仍然要你自己处理
- 当定时触发和手动触发同时存在时，`Timer` 本身并没有提供等待、抢占或取消的协调模型

## `SequentialExecutor` 闪亮登场！

- 任务按顺序运行，不会重叠，同一时刻只会执行一个任务
- 只有一个调度循环，开启、关闭和间隔变化都通过 `updatePolicy(_:)` 明确控制
- `executeNow()` 会打断当前等待，必要时取消当前正在执行的任务，让新的请求优先开始
- `eventHandler` 会收到带 `emittedAt`、`executionID` 和 `source` 的有序事件回调

> [!TIP]
> 核心接口只聚焦在 `execute`、`eventHandler`、`updatePolicy(_:)` 和 `executeNow()`
>
> 其他细节都被封装在内部 ;-)

## Installation

### Swift Package Manager

只要你的 Swift package 或 Xcode 工程已经建立好，就可以把 `swift-sequential-executor` 添加到 `Package.swift` 的 `dependencies`，或者加到 Xcode 的 package dependency 列表里。

这个仓库目前还没有发布版本 tag，所以下面的示例先使用 `branch: "main"`：

```swift
dependencies: [
    .package(url: "https://github.com/shensven/swift-sequential-executor.git", branch: "main")
]
```

然后在 target 中依赖 `SequentialExecutor` 这个 product：

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

## Quick Start

```swift
import SequentialExecutor

let executor = SequentialExecutor(
    execute: { context in
        print("run", context.executionID, context.source)
        try await Task.sleep(for: .seconds(1))
    },
    eventHandler: { event in
        print(event.emittedAt, event.kind)
    }
)

await executor.updatePolicy(.init(runLoop: .interval(.seconds(5))))
await executor.executeNow()
```

## 行为说明

### 状态模型

从可见的运行时状态来看，executor 可以用 4 个状态来描述：

- `Idle`：调度循环已关闭，当前没有任务在执行
- `Waiting`：调度循环已开启，正在等待下一个 interval 到来
- `ScheduledExecution`：因为 interval 到期而启动的一次执行
- `ImmediateExecution`：因为 `executeNow()` 请求立即执行而启动的一次执行

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle: loop 已关闭<br/>当前没有 execution

    Idle --> Waiting: updatePolicy(interval)
    Waiting: scheduled loop 等待中

    Waiting --> ScheduledExecution: intervalElapsed
    ScheduledExecution: execute(context)<br/>source = scheduledLoop
    ScheduledExecution --> Waiting: executionFinished / Cancelled / Failed

    Idle --> ImmediateExecution: executeNow()
    Waiting --> ImmediateExecution: executeNow()<br/>先停止 loop
    ScheduledExecution --> ImmediateExecution: executeNow()<br/>先取消当前 execution

    ImmediateExecution: execute(context)<br/>source = executeNow
    ImmediateExecution --> Waiting: executionFinished / Cancelled / Failed<br/>policy 仍为 interval
    ImmediateExecution --> Idle: executionFinished / Cancelled / Failed<br/>policy 已禁用

    Waiting --> Idle: updatePolicy(disabled)
    Waiting --> Waiting: updatePolicy(new interval)<br/>重新开始 loop wait
```

### 抢占流程

`executeNow()` 是这个类型最关键的协调语义。它不会并行叠加执行，而是先抢占当前调度状态，再启动一份新的立即执行。

更具体地说：

- 如果当前正处于等待下一个 interval 的状态，那么这次等待会先被取消
- 如果当前已经有任务在执行，那么这次执行会先被取消
- 随后才会启动新的立即执行，而且只会启动一次
- 这次立即执行结束后，只有在当前 policy 仍然允许的前提下，调度循环才会恢复等待

下面这张时序图描述的是 interval policy 已经生效时的一条代表性路径：

```mermaid
sequenceDiagram
    participant Caller as 调用方
    participant Executor as 执行器
    participant Observer as eventHandler 观察者

    Caller->>Executor: updatePolicy(interval)
    Executor-->>Observer: policyUpdated
    Executor-->>Observer: loopStarted
    Executor-->>Observer: waitStarted

    Caller->>Executor: executeNow()
    Executor-->>Observer: requested
    Executor-->>Observer: loopStopped(executeNowRequested)
    Executor-->>Observer: waitCancelled
    Executor-->>Observer: executionStarted(source: executeNow)
    Note over Executor: await execute(context)

    alt execute 正常返回
        Executor-->>Observer: executionFinished
    else execute 抛出错误
        Executor-->>Observer: executionFailed
    else execute 被取消
        Executor-->>Observer: executionCancelled
    end

    opt policy 仍为 interval
        Executor-->>Observer: loopStarted
        Executor-->>Observer: waitStarted
    end
```

## API 保证

- `execute` 是唯一的工作回调。每次开始的执行都只会进入这个闭包一次。
- `eventHandler` 是唯一的生命周期观察通道。`SequentialExecutor` 会在自身协调路径上，按事件发出顺序同步调用它。
- `updatePolicy(_:)` 只负责修改调度循环策略。
- `executeNow()` 请求一次更高优先级的立即执行，并且可能会先取消当前正在进行中的执行。

这个观察接口的契约有意保持得很窄：

- `eventHandler` 只负责观察，不负责控制。它应该保持轻量且非阻塞。
- 如果观察者把事件再转发到别的 actor、queue 或 UI 线程，后续显示延迟属于观察层，不属于 `SequentialExecutor`。
- `Event.emittedAt` 记录的是 executor 发出事件的时间。
- `ExecutionContext.executionID` 和 `ExecutionContext.source` 会与对应的 `executionStarted`、`executionFinished`、`executionCancelled`、`executionFailed` 事件保持一致。

## 示例应用

仓库里包含一个 SwiftUI Example app，位置在 [`Examples/SequentialExecutorExample`](Examples/SequentialExecutorExample)。

这个 Example 有意把两层状态分开：

- 期望配置（desired configuration）：用户当前选择的 RunLoop 控件值和下一次执行策略
- 运行时状态（runtime state）：`SequentialExecutor` 当前已应用的调度循环策略，以及由事件驱动的等待 / 执行圆环

在 Example 的 `ViewModel` 里，`PreparedExecution` 只是一个本地桥接状态，用来在对应的生命周期事件渲染出来之前，先按 `executionID` 冻结一份执行计划。可见的运行时状态仍然保持事件驱动。
