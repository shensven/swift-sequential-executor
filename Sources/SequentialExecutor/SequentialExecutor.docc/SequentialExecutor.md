# ``SequentialExecutor``

一个按顺序执行异步任务的执行器。

## Overview

`SequentialExecutor` 保证同一时间只运行一个执行任务。
你可以通过 `runNow()` 触发立即执行，也可以通过策略控制循环执行。