# AcCoRD 功能更新报告：依赖 Actor 与 Amplify-and-Forward (AF) 中继扩展

## 摘要
在既有工作中，我的论文（[research_paper.md](file:///Users/faner/Documents/AcCoRD-master/research_paper.md)）主要聚焦于 AcCoRD 微观扩散层的性能优化与数据布局改造。本更新报告基于老师的反馈意见，面向“系统功能与可复现实验”方向补齐 AcCoRD 的一项通信机制能力：支持由被动观测驱动的依赖型主动 Actor（dependent active actor），并将其扩展为可配置的 Amplify-and-Forward（AF）中继模式，使被动观测值能够连续映射为释放强度（release strength），而非仅支持阈值触发的离散释放。同时，为保证该功能在事件调度上正确执行，并在 macOS/Windows 环境下可编译运行，我们补充修复了计时器堆更新与平台相关头文件引用问题。最后使用仓库自带配置样例完成构建与端到端运行验证。

## 1. 引言
分子通信（Molecular Communication, MC）中继是连接远距离或遮挡链路的重要机制。与传统“检测-再生”（Decode-and-Forward, DF）不同，Amplify-and-Forward（AF）中继强调对观测信号的直接放大/衰减并转发，在系统建模中通常表现为“观测值 → 连续释放强度”的映射。

老师的主要意见可以概括为三点：
1. 依赖型主动 Actor 的触发机制需要从“仅阈值触发”扩展到“可根据观测强度连续调制释放强度”，以支持 AF 中继建模。
2. 新增机制必须与 AcCoRD 的离散事件调度（timer heap）一致，避免出现触发后计时器堆未更新导致的错误事件顺序。
3. 改动需可在 macOS 等非 Windows 环境下顺利编译运行，避免平台相关依赖引发构建失败。

本报告对上述意见给出对应的设计、实现与验证。

## 2. 背景：AcCoRD 的 Actor、观测与事件调度
AcCoRD 将系统中的行为主体抽象为 Actor：主动 Actor 改变环境（释放分子），被动 Actor 观测环境（统计分子计数/位置）。其主循环基于最小堆维护的计时器集合（timer heap）推进事件，Actor 的下一次动作时间通过 `timerArray[].nextTime` 驱动。

依赖型主动 Actor 的核心语义为：其动作由某个被动 Actor 的观测结果触发。实现上，它需要在被动 Actor 完成观测并写入 `curMolObs` 后，判断是否触发某些主动 Actor 的释放事件，并将这些主动 Actor 的“下一事件时间”写回 timer heap。

## 3. 设计：AF 中继的参数化与触发模式
为支持 AF 中继，我们将“依赖触发”拆分为两层可配置逻辑：

### 3.1 触发层（Trigger）
保留原有阈值触发语义，并补充“增量阈值”模式以匹配“累计增长触发”的需求：
- `dependentTriggerMode = 0`：基于阈值 `dependentTriggerValue` 判断 `depCount >= dependentTriggerValue`，并可选上升沿触发（`bDependentRisingEdge`）。
- `dependentTriggerMode = 1`：基于增量阈值判断 `depCount >= prevCount + dependentTriggerValue`，其中 `prevCount` 为上一次观测计数。

### 3.2 转发层（Relay / AF Mapping）
将被动观测值 `obsValue` 映射为主动释放强度 `strength`：
\[
strength = gain \cdot obsValue + bias
\]
并提供强度边界约束：
\[
strength \leftarrow clamp(strength, minStrength, maxStrength)
\]

为便于复现实验与覆盖不同论文设定，支持以下 relay 模式：
- `dependentRelayMode = 0`：保持旧行为，不做强度映射，仍调用原始 `newRelease`。
- `dependentRelayMode = 1`：使用绝对观测计数 `obsValue = depCount` 做线性映射。
- `dependentRelayMode = 2`：使用观测增量 `obsValue = depCount - prevCount` 做线性映射（允许出现负值，随后由 clamp 约束）。

对应新增配置参数为：
`Dependent Relay Mode / Gain / Bias / Min Strength / Max Strength`。

## 4. 实现：数据结构、释放路径与调度修复

### 4.1 Actor Spec 扩展
在 `actorStructSpec3D` 中增加 AF 参数字段，用于从配置读入并在运行时访问：
- 代码位置：[actor.h](file:///Users/faner/Documents/AcCoRD-master/src/actor.h#L127-L137)

### 4.2 新增释放路径：按强度覆盖的 release 生成
原有 `newRelease(...)` 会根据调制方案与比特序列推导释放强度。AF 中继需要“直接使用映射后的强度”，因此新增：
- `newReleaseWithStrength(const actorStruct3D*, actorActiveStruct3D*, double curTime, double strengthOverride)`
- 代码位置：[actor.c](file:///Users/faner/Documents/AcCoRD-master/src/actor.c#L1183-L1277)

该函数在保留现有 release list / emission 机制的前提下，将 `strengthOverride` 作为本次 release 的强度，并调用 `findNextEmission(...)` 更新下一次发射事件，确保与既有调度逻辑兼容。

### 4.3 依赖触发集成与 timer heap 更新
依赖触发逻辑集成于被动 Actor 观测完成后的分支：对所有主动 Actor 扫描，筛选出 `dependentPassiveActorID` 指向当前被动 Actor 的依赖 Actor，并按 Trigger/Relay 配置决定是否释放。

实现点包括：
- 根据 `dependentTriggerMode` 与 `bDependentRisingEdge` 判定触发条件。
- 若 `dependentRelayMode == 0` 调用 `newRelease(...)`，否则计算 `strength` 并调用 `newReleaseWithStrength(...)`。
- 每次触发后，将依赖 Actor 的 `timerArray[depActorID].nextTime` 更新为其 `nextEmissionTime`，并立刻调用 `heapTimerUpdate(...)` 维护最小堆有序性。

代码位置：[accord.c](file:///Users/faner/Documents/AcCoRD-master/src/accord.c#L772-L947)

### 4.4 修复：updateTimer 的 nextTime 写入语义
为避免“计时器值更新但堆结构未能反映/值无效”的问题，`updateTimer(...)` 保持单一职责：仅写入 `timerArray[curTimer].nextTime = tCur`，并要求调用者在修改后立刻调用 `heapTimerUpdate(...)`。
- 代码位置：[timer_accord.c](file:///Users/faner/Documents/AcCoRD-master/src/timer_accord.c#L118-L130)

### 4.5 修复：跨平台头文件 direct.h 的条件包含
在 macOS 环境下不存在 `<direct.h>`，为保证跨平台构建，将其包裹于 `_WIN32` 条件编译：
- 代码位置：[file_io.h](file:///Users/faner/Documents/AcCoRD-master/src/file_io.h#L120-L128)

### 4.6 配置解析：AF 参数读入与默认值
在配置加载中增加对 AF 参数的解析，包含合法性检查与默认值策略（如：未定义则 relayMode=0，gain 默认 1，maxStrength 默认 INFINITY）：
- 代码位置：[file_io.c](file:///Users/faner/Documents/AcCoRD-master/src/file_io.c#L2163-L2239)

## 5. 实验与验证

### 5.1 构建验证
使用仓库内脚本完成构建（脚本基于 `src/` 目录调用编译器与源文件列表）：
- 脚本位置：[build_accord_opt_dub](file:///Users/faner/Documents/AcCoRD-master/src/build_accord_opt_dub)
- 实际执行（在 `src/` 目录）：`bash build_accord_opt_dub`

### 5.2 端到端运行验证
使用样例配置运行可执行文件，确认程序能完成初始化、仿真与结果写出：
- 配置文件：[accord_config_sample.txt](file:///Users/faner/Documents/AcCoRD-master/config/accord_config_sample.txt#L73-L101)
- 输出文件示例：[accord_sample_SEED1.txt](file:///Users/faner/Documents/AcCoRD-master/results/accord_sample_SEED1.txt)
- 汇总信息：[accord_sample_SEED1_summary.txt](file:///Users/faner/Documents/AcCoRD-master/results/accord_sample_SEED1_summary.txt)
- 实际执行（在 `src/` 目录）：`../bin/accord_dub.out ../config/accord_config_sample.txt`

该样例中设置了一个被动观测 Actor 与一个依赖型主动 Actor。依赖 Actor 采用 `Dependent Relay Mode = 1`（按绝对计数映射），因此当被动观测计数首次上升到阈值以上时，依赖 Actor 会触发释放，并将释放强度设置为 `gain * depCount + bias`，随后观测计数会反映出释放后的变化。以本次运行的输出为例（见 [accord_sample_SEED1.txt](file:///Users/faner/Documents/AcCoRD-master/results/accord_sample_SEED1.txt) 的计数序列开头）：
- 初始主动 Actor 释放后，被动观测计数首先为 `2`
- 依赖 Actor 在首次观测触发时取 `depCount = 2`，样例设置 `gain = 1, bias = 0`，得到 `strength = 2`
- 依赖 Actor 释放后，下一次观测计数上升到 `4`，随后在该短时仿真窗口内保持为 `4`

## 6. 讨论与局限
1. 当前 AF 映射是“在触发时刻依据被动观测值生成一次 release”，其时间粒度由被动 Actor 的观测间隔决定；若需要连续时间的 AF（每次观测都转发一次、或在观测窗口内持续转发），可在保持相同参数化的前提下扩展触发规则。
2. 强度为浮点数，若映射得到负值，当前实现通过 `minStrength` 进行下限钳制以避免无意义释放。
3. `newReleaseWithStrength(...)` 采用“强度覆盖”语义，不再依赖调制比特推导强度，因此在 AF 模式下，“调制方案”主要用于复用既有 release/ emission 管线，而不是用于强度计算。

## 7. 结论
根据老师的反馈，本次更新在不破坏 AcCoRD 原有行为的前提下：
1. 为依赖型主动 Actor 增加了 AF 中继所需的参数化能力；
2. 打通了“观测值 → 强度映射 → 覆盖式释放 → 下一次发射调度”的完整链路；
3. 修复了与事件堆维护和跨平台构建相关的关键问题；
4. 使用仓库样例配置完成了构建与端到端运行验证。

该功能补齐使得 AcCoRD 更适合用于包含中继节点的分子通信链路建模，并为后续更复杂的转发策略（如非线性映射、噪声放大、能量约束等）提供了直接扩展点。
