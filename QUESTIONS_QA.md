# Q&A for `questions.txt`

Format requirement: each section contains the original question text first, then the answer.

---

## Q1

**问题原文**

> 就是我们的这些模拟器到底模拟了是什么

**回答**

AcCoRD 是一个面向“分子通信（Molecular Communication）”的随机反应-扩散（advection-reaction-diffusion）仿真器，核心是统计某些位置（接收端/被动 actor）处的分子观测量（count / 位置等）。它支持：

- **Microscopic（微观）**：跟踪每个分子的随机运动（离散时间步）。
- **Mesoscopic（介观）**：在子体积（subvolume）里只跟踪分子数量（连续时间/SSA 风格事件）。
- **Hybrid（混合）**：微观与介观在同一环境中耦合，局部用不同精度模型。

参考官方描述：[README_NO.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/README_NO.md#L8-L24)

---

## Q2

**问题原文**

> 还有是咱们从list改为pool 他的容量是怎么算的 我再这几个文档里没有找到描述

**回答**

当前实现里 **pool 的初始容量不是“算出来”的**，而是直接给了一个常量（在初始化 region 的时候）。随后容量按需扩容：

- **扩容策略**：`capacity *= 2`（翻倍扩容）。
- **删除策略**：`swap-and-pop`（用最后一个元素覆盖被删位置，再 `count--`），因此分子顺序会改变。

代码位置：

- 初始容量（初始化时传入）：[region.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/region.c#L1250-L1274)（`pool_init(..., 1000)`）
- 扩容/删除细节：[micro_molecule.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.h#L187-L246)

---

## Q3

**问题原文**

> 1触发层和转发层它特指的是 在我们的project中如何体现2 就是我们一直跑的都是默认，需要跑其他的模拟 3.他那个种子的信息在哪里查看呢 4 还有是咱们从list改为pool 他的容量是怎么算的 5. 10的 567次方的分子数量是如何修改的？

**回答**

1) **触发层 / 转发层在项目中的体现**

- “触发层”对应代码中的 `Dependent Trigger Mode / Value / Rising Edge` 等参数，决定“何时触发依赖 actor 的释放”。
- “转发层（AF Mapping）”对应 `Dependent Relay Mode / Gain / Bias / Min/Max Strength`，决定“触发后释放强度是多少”。

具体触发与映射逻辑在：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L772-L947)。

2) **一直跑默认，如何跑其他模拟**

你现在运行的是 `config` 目录下的 sample 配置。要跑其他模拟，本质是：

- 换配置文件（`config/*.txt`），或
- 修改配置里的 region/actor/reaction 参数（如开启 surface、chem reactions、meso/hybrid 等）。

3) **seed 信息在哪里看**

seed 来自两部分：

- 配置文件内 `"Random Number Seed"`（例如 sample 里常见是 1）
- 命令行第三个参数是 `seed offset`（如 `... config.txt 1`），会在加载配置时叠加使用

运行时控制台会打印 “using seed offset X”，输出文件名也会带 `SEEDx`。示例见：[README.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/README.md) 和运行输出。

4) **list->pool 容量**：见 Q2。

5) **“10^5/10^6/10^7 分子数量”怎么改**

仓库里出现的 `10^5/10^6/10^7` 有两种含义来源：

- **基准测试（benchmark_test.c）**里，直接用 `sizes[] = {100000, 1000000, 10000000}` 控制分子数量（用于测 traversal / diffusion 核心的性能）：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L155-L167)
- **真实仿真配置**里，通常通过 active actor 的 `"Modulation Strength"`（或相关 release 参数）控制每次释放分子数，例如：[accord_config_sample_point_diffusion.txt](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/config/accord_config_sample_point_diffusion.txt#L61-L85)

---

## Q4

**问题原文**

> 用 SoA 重构微观扩散内核 Structure-of-Arrays（SoA） 形式（例如 x[], y[], z[], needUpdate[]），把分子属性放到连续数组中，改为批量循环更新，从而：  
> …  
> 在遍历主导的合成基准中体现出明显上限收益。 这些结果都是怎么跑出来的  我们采用 guarded integration（受保护接入）：先检查 region/配置是否满足 SoA 快路径的前提条件 这个条件具体是什么

**回答**

1) **这些 SoA/合成基准结果怎么跑出来的**

仓库里提供了对应的基准程序 `benchmark_test.c`，它包含两段 benchmark：

- 合成基准：linked list (AoS) vs SoA 的简单遍历更新
- “更真实”的扩散基准：使用 AcCoRD 的 RNG 与 diffusion 更新逻辑

代码入口：`main()`： [benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L155-L260)

2) **guarded integration（SoA simple 快路径）的具体条件**

当前 SoA simple 快路径是通过环境变量 `ACCORD_USE_SOA_SIMPLE` 打开，并且只在**非常严格的配置集合**下启用（确保不改变物理逻辑、避免复杂分支）：

- 只允许 **唯一一个**满足条件的（region, molType）组合（否则禁用）
- 该 region 必须是 microscopic (`bMicro`)
- 该 region 必须 **没有**化学反应（`numChemRxn == 0`）
- 该 region 不能与 mesoscopic region 相邻（`bHasMesoNeigh == false`）
- 该 region 不能有 surface（`surfaceType == NO_SURFACE`）
- 该 molType 不能启用 APMC 反应（`numApmcRxn[type] == 0`）
- 必须不存在 hybrid interface（`MAX_HYBRID_DIST <= 0`）
- `molPool != NULL`

初始化阶段的判定在：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L260-L305)  
运行阶段的再次校验在：[micro_molecule.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.c#L387-L416)

---

## Q5

**问题原文**

> 触发层（Trigger）…（绝对阈值触发 / 上升沿 / 增量阈值触发）… 2.2 转发层（Relay / AF Mapping）… 定义“触发后释放多少”…

**回答**

在本仓库实现里，“触发层/转发层”对应 **Dependent Active Actor** 的一组参数与逻辑（即 active actor 的行为依赖某个 passive actor 的观测值）：

- Trigger（什么时候触发）：
  - `Dependent Trigger Mode`：0 = 绝对阈值；1 = 增量阈值
  - `Dependent Trigger Value`：阈值（count 或 count 增量）
  - `Dependent Trigger on Rising Edge?`：只在从未达阈值→达阈值的上升沿触发
- Relay/AF Mapping（触发后释放多少）：
  - `Dependent Relay Mode`：0 = 原始 release（不映射）；1 = 用 obsValue 做线性映射；2 = 用“增量 obsValue”做线性映射（允许负增量）
  - `Dependent Relay Gain/Bias/Min Strength/Max Strength`：线性映射与 clamp

配置文件读取默认值与字段名见：[file_io.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/file_io.c#L2087-L2218)  
触发执行逻辑见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L772-L947)

---

## Q6

**问题原文**

> 定义“触发后释放多少”，将观测值映射为释放强度：10 / 5 / 10 / 6 / 10 / 7 … 到底代表什么：每次释放的分子数、系统内同时存在的分子数、还是 某个窗口累计释放量？

**回答**

在当前代码实现中，**strength 的物理含义是：一次 release 事件中“释放的分子数量（或等价强度）”**，对应 `newReleaseWithStrength(..., strength)` 的入参。它不是“系统内同时存在的分子数”，也不是“窗口累计释放量”（后者属于上层统计口径）。

证据：

- `strength` 是由 `obsValue` 经 `gain/bias/min/max` 计算后直接传给 `newReleaseWithStrength`：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L819-L842)
- actor 结构体里也明确了 `modStrength` 等 release 强度概念：[actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L168-L179)

至于你写的 “10^5 / 10^6 / 10^7”，在本仓库中最明确的落点是 benchmark 里的 molecules 规模（见 Q3）。如果在论文/实验里它被用作 “每次 emission 的释放量”，那需要在配置或脚本里明确写为 `modStrength`/`strength` 的具体取值与单位。

---

## Q7

**问题原文**

> 你们如何保证 SoA 快路径与 legacy 路径在“正确性”上等价？是 bitwise 一致还是统计一致？给出明确标准与证据。

**回答**

就当前仓库的实现现状而言：

- **bitwise 一致无法保证**：因为数据结构从 linked list → pool（swap-and-pop / 遍历顺序变化），会改变 RNG 调用顺序与事件/输出顺序，从而导致轨迹不同，即便 seed 相同也可能出现差异。
- 更合理、也更可写进论文的标准是：**统计一致（statistical equivalence）**，例如对关键观测指标（receiver counts、BER、到达统计）做多次 Monte Carlo 后均值/分布一致（可用 KS test、置信区间重叠、均值相对误差阈值等）。

仓库里目前提供的是 **old/new 输出对比与匹配率脚本**（你之前生成的 `benchmark_summary.txt` 体系），它属于“工程验收”层面的对照；若要做论文级“统计一致”，需要补充更严格的统计检验与多 seed、多重复的实验设计（仓库内尚未提供现成脚本）。

---

## Q8

**问题原文**

> guarded entry 的 兼容性检查具体检查哪些条件？逐条列出，并解释每条的必要性。

**回答**

当前 guarded entry（SoA simple）检查条件在初始化阶段和运行阶段都实现了，核心动机是：避免 SoA simple 在需要“跨 region/混合/反应/表面”等复杂逻辑时改变行为或遗漏处理。

逐条条件与必要性（对应 [accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L260-L305)）：

- `region.spec.bMicro == true`：SoA simple 只实现微观 diffusion 更新。
- `region.numChemRxn == 0`：避免反应逻辑依赖 list 结构/逐分子反应扫描导致语义变化。
- `region.bHasMesoNeigh == false`：避免 micro/meso 交界处的过渡、吸收等逻辑漏掉。
- `region.molPool != NULL`：必须有 pool 数据结构作为存储。
- `region.spec.surfaceType == NO_SURFACE`：避免 surface 反射/吸收/吸附/解吸等复杂边界处理。
- `region.numApmcRxn[type] == 0`：避免 APMC（a priori Monte Carlo）表面反应路径。
- `spec.MAX_HYBRID_DIST <= 0`：避免 hybrid interface 的间接进入/退出 meso 的路径追踪。
- **唯一性约束**（只能有一个 region/type 命中）：避免多个 region/type 同时启用导致全局状态与 addMolecule hook 复杂化，当前实现只支持一个。

---

## Q9

**问题原文**

> 当配置不兼容回退时，SoA 池里已有分子如何处理？会不会 重复更新/漏更新？

**回答**

对 SoA simple 而言，当前实现的“回退”语义是：**只有在初始化就不满足条件时，根本不会启用 SoA simple**（`gSoaSimpleEnabled=false`），因此不存在“运行中回退但池里已有分子”的路径。

证据：SoA simple 是否启用只在初始化时由 `ACCORD_USE_SOA_SIMPLE` 和条件扫描决定：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L260-L305)。

如果未来要支持“运行中动态回退”，那必须显式处理 pool 与 list 的状态迁移，否则确实可能出现“池里有分子但 list 为空”的漏更新风险。当前仓库没有实现这种动态回退机制。

---

## Q10

**问题原文**

> 真实扩散端到端仅 5–6% 提升：你们的 profiling 证据是什么？瓶颈到底在 RNG、验证、边界处理还是调度？

**回答**

仓库里目前能直接复现/支持的证据是：

- `benchmark_test.c` 里的“真实扩散 benchmark”使用了 AcCoRD RNG (`generateNormal`) 与 diffusion 更新的近似流程，可用于说明“diffuse 更新本身的上限收益”。见：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L168-L260)

但 **完整端到端 profiling 报告（热点函数占比、工具、截图/数据）在仓库中没有被固化保存**。如果要回答质疑并写进论文，建议补充：

- Windows：VS Profiler / WPA；Linux：`perf`/`gprof`/`callgrind`
- 报告热点：RNG、diffusion validation（边界/region 检查）、heap 调度、内存分配、I/O

---

## Q11

**问题原文**

> SoA 结构是否真的支持 SIMD/批处理？你们做了还是没做？没做的原因是什么？

**回答**

SoA 数据布局（`x[]/y[]/z[]/bNeedUpdate[]`）本身确实更利于 SIMD/批处理（连续内存、减少指针追逐），但 **当前仓库并没有显式引入 SIMD 指令或向量化 RNG**。也就是说：结构“具备潜力”，但实现层面仍主要依赖编译器自动向量化（不保证）。

数据结构定义见：[micro_molecule.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.h#L143-L163)。

---

## Q12

**问题原文**

> Dependent Actor 的“立即触发”在离散事件仿真里是什么意思：同一事件内执行还是插入新事件？时间戳如何定义？

**回答**

当前实现是：**在 passive actor 的 observation 事件执行过程中，立即触发 dependent active actor 的释放逻辑**，不额外插入一个“同一时刻的新事件”。触发时使用的时间戳就是该 passive observation 的 `nextTime`（当前事件时间）。

证据：触发逻辑紧跟在 `addObservation(...)` 之后，在同一段事件处理中直接调用 `newRelease`/`newReleaseWithStrength`，并更新 timer heap：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L757-L949)。

---

## Q13

**问题原文**

> prevCount 何时更新（每次观测后/每次触发后/每个符号后）？不同策略会导致完全不同的触发频率。

**回答**

按代码现实现：

- `depCount` 是**本次 passive observation**对指定 `MolID` 的观测 count。
- `prevCount` 存在 `actorActiveArray[curActive].depPrevCount`。

更新策略：

- **增量阈值模式**（`Dependent Trigger Mode = 1`）：每次观测后都会执行 `depPrevCount = depCount`（无论触发与否）。见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L804-L851)
- **绝对阈值模式**（`Dependent Trigger Mode = 0`）：每次观测后同样会更新 `depPrevCount = depCount`，用于 relayMode=2 时的增量计算。见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L852-L947)

因此它既不是“每个 symbol 后”，也不是“仅触发后”，而是 **每次观测事件后**。

---

## Q14

**问题原文**

> AF 映射得到的 strength 是整数还是实数？如何取整？取整会不会引入偏差？

**回答**

当前实现里 `strength` 是 `double`（实数），由 `gain * obsValue + bias` 计算，并经过 min/max clamp 后传入 `newReleaseWithStrength(...)`。

证据：strength 的类型与计算：[actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L132-L136)、[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L819-L842)。

至于“最终释放分子数是否取整”，取决于 `newReleaseWithStrength` 内部如何将 `double` 映射为释放数量（该函数实现需要进一步在源码中定位并在论文里明确写出）。仓库里目前没有把这一点在文档层说明清楚，建议补充成：round/floor/随机取整，并讨论偏差。

---

## Q15

**问题原文**

> dependentRelayMode=2 允许负增量，物理意义是什么？clamp 会不会系统性抹掉弱信号？

**回答**

实现含义：

- `dependentRelayMode=2` 时，`obsValue = depCount - prevCount`，因此当观测下降时 `obsValue` 为负。见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L822-L832)
- 随后 `strength = gain*obsValue + bias`，再通过 `min/max` clamp 截断。见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L833-L842)

物理解释上，它更像是“基于增量的放大/抑制（AF-like）映射”，负增量意味着“信号变弱”。如果 `minStrength` 设为 0，则负增量会被截断成 0（等价于不释放），确实可能抹掉弱信号，这是映射策略设计的一部分，需要在论文中明确写出并给出理由。

---

## Q16

**问题原文**

> 参数 gain/bias/min/max 的单位/含义是什么？如何与观测计数匹配（数量级、尺度）？

**回答**

从代码角度，这四个参数只参与线性映射：

`strength = gain * obsValue + bias`，然后 clamp 到 `[minStrength, maxStrength]`。

单位推导：

- `obsValue` 是“分子计数”（count）或“计数增量”
- 因此 `gain` 的单位是 “(release strength unit) / count”
- `bias/min/max` 的单位与 `strength` 相同

代码位置：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L833-L842)、字段定义：[actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L132-L136)。

---

## Q17

**问题原文**

> 多 actor 同时触发时，执行顺序是否确定？是否依赖容器遍历顺序而引入非确定性？

**回答**

在原版 AcCoRD 的设计里，“同一时刻 act 的 actors”顺序可能不是确定的，README 里明确指出：同一时刻 act 的 actors 可能按 timer heap 排序导致“随机顺序”。见：[README_NO.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/README_NO.md#L53-L54)。

对本仓库新增的 dependent trigger 来说：

- 它是在某个 passive observation 事件中遍历 `NUM_ACTORS_ACTIVE` 顺序触发（for 循环顺序是确定的），见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L772-L947)
- 但如果多个 passive observations 或 actor events 在同一时间戳竞争，仍可能受 heap 排序影响。

---

## Q18

**问题原文**

> 你们 baseline 是否真的是“原版 AcCoRD v1.0”？编译器、优化级别、宏定义完全一致吗？

**回答**

从仓库文档可见，当前仓库基于 AcCoRD v1.4.2（README_NO 写的是 v1.4.2），不是 v1.0：[README_NO.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/README_NO.md#L5-L6)。

关于“公平对比”的工程建议（写论文时需要明确）：

- old/new 必须使用相同编译器与相同优化选项（如 `/O2` 或 `-O3`）
- 相同宏定义、相同依赖库版本
- 相同配置文件、相同 seed、相同 repeat 次数

仓库目前通过你生成的脚本实现了“同环境、同配置、同 seed offset”的自动化对比（速度与输出对比），但“baseline=哪个版本、编译参数细节”需要在论文中手动写清楚。

---

## Q19

**问题原文**

> SoA 引入后内存占用变化多少？10^7 分子时是否触发分页/内存带宽瓶颈？

**回答**

从数据结构角度粗略估算（仅微观分子主数组，不含额外索引/反应/边界数据）：

- SoA：`x/y/z` 三个 `double[]` + `bool[]`  
  约 `3*8 + 1 ≈ 25 bytes/molecule`，加上对齐与分配开销
- AoS(list)：每个 node 还包含 `next` 指针与 malloc 元数据，通常远大于 SoA（并且碎片化更严重）

10^7 分子下，SoA 主数组量级约 250MB+（还没算其他结构），是否分页取决于机器内存与并发占用。仓库目前没有自动输出内存统计的工具，建议补充运行时内存峰值记录（Windows 可用 Performance Monitor / WPA，Linux 用 `/usr/bin/time -v` 或 `smem`）。

结构定义见：[micro_molecule.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.h#L143-L163)。

---

## Q20

**问题原文**

> 你们的实验能否复现：配置文件、seed、Monte Carlo 次数、统计指标定义是否全部写清？

**回答**

就当前仓库交付物而言，可复现性依赖三类材料是否齐全：

- 配置文件：`config/*.txt`（sample 已提供）
- seed：配置 `"Random Number Seed"` + 命令行 `seed offset`
- Monte Carlo 次数：配置 `"Number of Repeats"`

示例配置：`accord_config_sample_point_diffusion.txt` 里就包含 `"Number of Repeats"`、`"Random Number Seed"` 等字段：[accord_config_sample_point_diffusion.txt](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/config/accord_config_sample_point_diffusion.txt#L15-L29)

如果要达到论文级复现，需要在论文/附录中明确：

- 每个实验用的具体配置文件名（或贴出关键参数）
- seed 与 repeat 数
- 统计指标的计算方式（均值/方差/置信区间/检验方法）

---

## Q21

**问题原文**

> SoA 到底包含哪些数组字段？仅 x/y/z/needUpdate 还是还包括 moleculeType、regionId、valid、state？

**回答**

当前仓库的 `MicroMoleculePool` 只包含：

- `double* x, y, z`
- `bool* bNeedUpdate`
- `size_t count, capacity`

并不包含 `moleculeType/regionId/valid/state` 等字段。这意味着 SoA pool 的粒度设计是“一个 pool 对应一个 region + 一个 molType”的数据集，而不是把所有类型混在一个 pool 里。

定义见：[micro_molecule.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.h#L143-L163)

---

## Q22

**问题原文**

> needUpdate 的语义是什么：本 step 更新标记？边界处理后复检标记？由谁置位、何时清零？

**回答**

`bNeedUpdate`（legacy list）/`pool->bNeedUpdate[i]`（SoA）在代码里的语义是：

- 表示该分子在当前 micro 时间步内是否“仍需要被更新/验证”（用于避免分子在跨 region 移动时被更新多次）
- 每个 micro step 开始，会把需要处理的分子标记成 `true`
- 一旦该分子被处理（扩散/边界/反应检查完），就会置为 `false`

对 list 的置位逻辑见：[micro_molecule.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.c#L419-L444)  
对 SoA pool 的更新循环可见 `diffuseMolecules_pool`/`diffuseMolecules_pool_simple` 内部逻辑（同文件）。

---

## Q23

**问题原文**

> SoA 池的粒度是什么：每 region 一个池？全局池？每分子类型一个池？为什么这样设计？

**回答**

从结构与初始化调用方式来看，当前设计是：**每个 microscopic region 维护一个 `molPool`（内部用于某一个 molType 的 SoA simple 路径；以及 benchmark 中可人为构造）**。

在 guarded entry（SoA simple）模式下，进一步要求“全模型只能有一个 region+molType 命中”，因此实现上把 `gSoaSimplePool` 指向该 region 的 `molPool`，并把 `gSoaSimpleList` 指向对应的 `microMolList[region][type]` 以 hook `addMolecule`。

关键代码：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L260-L305)。

---

## Q24

**问题原文**

> 分子增删如何实现：swap-and-pop、free-list、还是 compact？

**回答**

SoA pool 的删除是 **swap-and-pop**：

- 删除 index 位置时，用最后一个元素覆盖它，然后 `count--`。

代码见：[micro_molecule.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.h#L232-L245)

---

## Q25

**问题原文**

> 删除/交换会改变分子顺序：这会不会影响 RNG 调用顺序、触发顺序、统计输出顺序？

**回答**

会。swap-and-pop 改变遍历顺序，从而：

- 可能改变 RNG 调用顺序（尤其是逐分子生成随机步长时）
- 可能改变同一时间戳下某些处理顺序（如果逻辑依赖遍历次序）
- 可能改变输出中 position 的排列顺序（你前面看到 crowding 的差异就是典型例子）

因此更适合用“统计一致”而不是 bitwise 一致来定义正确性（见 Q7）。

---

## Q26

**问题原文**

> 你们 baseline 是否真的是“原版 AcCoRD v1.0”？编译器、优化级别、宏定义完全一致吗？

**回答**

见 Q18（仓库基于 v1.4.2；公平对比需要在论文写清楚编译与环境）。

---

## Q27

**问题原文**

> 你们 baseline 是否真的是“原版 AcCoRD v1.0”？…（重复）

**回答**

同 Q18。

---

## Q28

**问题原文**

> Dependent Actor 是否支持更复杂策略（DF、非线性、阈值映射、多分子类型联合编码）？尤其是我们的的判断条件，比如eligibility trigger  capacity 退回 这些必须得在论文中明确 以及

**回答**

就当前仓库实现而言：

- **Trigger** 支持两种模式：绝对阈值与增量阈值（`Dependent Trigger Mode` 0/1）。
- **Relay/Mapping** 支持三种模式：0（不映射，沿用原 release）、1（线性映射）、2（增量线性映射，允许负值）。并支持 `gain/bias/min/max` 的 clamp。
- **多分子类型联合触发/编码**：当前实现只支持一个 `Dependent Molecule Type`，不支持“多类型联合条件”。
- **非线性映射/DF 等复杂策略**：当前实现是线性的（gain/bias），不包含非线性函数族或 DF 策略。
- 你提到的 `eligibility trigger / capacity / fallback` 术语在当前源码与配置字段中没有直接出现；如果论文里需要这些概念，建议明确把它们映射到现有字段（例如 max action、triggerMode、min/max strength、SoA guarded entry 条件与回退语义）。

相关字段定义： [actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L124-L137)  
配置读取： [file_io.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/file_io.c#L2112-L2218)  
运行逻辑： [accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L772-L947)

---

## Q29

**问题原文**

> 你们的核心研究问题是什么：性能工程、功能扩展、还是两者兼顾？主目标如何排序？

**回答**

从仓库两份文档的定位来看，目标是“两者兼顾，但分阶段有侧重”：

- `research_paper.md`：主线是 **性能工程/数据布局（SoA）**，并讨论 guarded integration 与 benchmark 证据：[research_paper.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/research_paper.md#L6-L24)
- `update.md`：主线是 **功能扩展（Dependent Actor + AF relay）**，并强调事件调度正确性与可复现实验：[update.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/update.md#L1-L21)

如果写论文建议排序：先明确“性能工程（SoA/pool）”是贡献 1/2，再把“Dependent Actor/AF relay”作为贡献 3（系统功能补齐）。

---

## Q30

**问题原文**

> “更快”的指标是什么：wall-clock、每 step 时间、每分子更新时间、还是吞吐（molecules/s）？

**回答**

仓库里实际出现并可复现的“更快”指标有两类：

- **benchmark_test.c**：测的是 CPU 时间（`clock()`），并给出不同分子数下的 SoA vs list 耗时与 speedup：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L155-L167)
- **AcCoRD 正式可执行文件输出**：控制台打印 `Simulation ran in X seconds`，对应一次仿真的 wall-clock（包含调度、验证、I/O 等）。你们的批跑脚本抓取的就是这个指标。

论文里建议明确：主报告用 wall-clock（最接近用户体验），同时补充 micro-benchmark 的“per step / per molecule”来解释归因。

---

## Q31

**问题原文**

> “正确性”的定义是什么：轨迹一致、统计一致、还是通信层指标一致？

**回答**

结合本项目的性质（随机仿真 + 数据结构与遍历顺序会改变 RNG 调用顺序），更可行的定义是分层的：

- **轨迹 bitwise 一致**：通常做不到（见 Q7/Q25）。
- **统计一致**：对核心输出（receiver count 曲线、分布、BER 等）做多次重复后，均值/分布在可接受阈值内一致（推荐作为论文标准）。
- **通信指标一致**：如果论文核心是分子通信链路/中继，那么以通信层指标为主（BER、到达概率、ISI 等）。

---

## Q32

**问题原文**

> 你们贡献 1/2/3 的边界如何划分？guarded entry 属于性能还是正确性？

**回答**

按 `research_paper.md` 的“contributions are threefold”描述，可划分为：

1) SoA/pool 数据结构与内存管理（性能基础）  
2) benchmark 证据链（合成基准 + 真实扩散基准，解释 RNG 主导）  
3) guarded integration（在生产扩散循环里可控启用 SoA 的工程接入）

guarded entry 更偏向 **工程接入策略（性能工程的一部分）**，但它的“严格条件 + 可回退”也承担了“正确性风险控制”的角色，因此论文里可以表述为：性能贡献中的“安全接入机制”。

参考：[research_paper.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/research_paper.md#L19-L24)

---

## Q33

**问题原文**

> 你们的改动对 AcCoRD 其他模块（mesoscopic、reactions、surfaces）有没有副作用？

**回答**

从 guarded SoA simple 的条件设计来看，它刻意避开了会影响语义的模块：

- 有 reactions / surfaces / hybrid / meso neighbor 的场景：SoA simple 不启用（见 Q8）。
- Dependent Actor/AF relay 只在 passive observation 后新增逻辑，不改变 mesoscopic/reaction/surface 的实现路径。

因此在“条件满足时”副作用应该被限制在很小范围；在“条件不满足时”则回到 legacy 路径。

---

## Q34

**问题原文**

> 10^5/10^6/10^7 的“带入方式”（结果强相关）… 是 每次 emission 的释放量还是 系统内初始分子数？

**回答**

在本仓库中，明确出现 `10^5/10^6/10^7` 的地方是基准程序 `benchmark_test.c`，它们表示“参与更新的分子数量 N”（内存中分子条目数），不是 emission strength：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L155-L167)。

如果你们论文实验里也使用了 `10^5/10^6/10^7`，需要在实验设置里明确它到底对应：

- `N_release`：每次 emission 的释放分子数（配置里通常是 `"Modulation Strength"` 或被 strength override 覆盖）
- `N_initial`：系统初始分子数（可通过在 `t=0` 的 release 预注入实现，或用配置/代码初始化）

---

## Q35

**问题原文**

> 如果是每次释放量：是通过哪个参数设置（modStrength / strength）？随机释放是否关闭？

**回答**

如果把 `10^k` 作为“每次释放量”：

- 在 independent active actor 配置里，对应 `"Modulation Strength"`（以及 modulation scheme 决定其具体含义），字段定义见：[actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L168-L179)
- 在 dependent/AF 模式下，如果启用映射（`dependentRelayMode != 0`），释放量来自 `strength`（`gain/bias/clamp` 计算后传入 `newReleaseWithStrength`）：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L819-L842)

随机释放是否关闭取决于 active actor 的 `bNumReleaseRand / bTimeReleaseRand` 等配置字段（在 actor spec 里定义，配置解析在 `file_io.c`）。

---

## Q36

**问题原文**

> seed 如何设置？old/new 是否同 seed？若 RNG 调用顺序改变，如何解释不一致？

**回答**

- seed 设置：配置 `"Random Number Seed"` + 命令行 seed offset（见 Q3/Q20）。
- old/new 同 seed：你们的批跑脚本可以确保同一 config + 同一 seed offset 运行。
- 即便同 seed，若数据结构/遍历顺序改变导致 RNG 调用顺序变化，轨迹可能不同。这是随机仿真的常见现象，应当用“统计一致”解释（见 Q7/Q31）。

---

## Q37

**问题原文**

> Actors that act at the same time will do so in a random order… 是否依赖容器遍历顺序而引入非确定性？

**回答**

原版 README 已明确：同一时间 act 的 actor 顺序可能依赖 timer heap 的排列，属于设计特性：[README_NO.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/README_NO.md#L53-L54)。

本项目新增的 dependent trigger 是在 passive observation 事件中按 `for(curActive=0; curActive<NUM_ACTORS_ACTIVE; curActive++)` 顺序扫描，因此“同一次被动观测触发多个 dependent actors”的顺序是确定的，但跨事件的并发仍可能受 heap 排序影响（见 Q17）。

---

## Q38

**问题原文**

> 触发检查是每次 passive observation 都检查？还是按某个间隔检查？

**回答**

当前实现是：**每次 passive observation 事件执行完观测后都会检查 dependent actors**。证据：触发逻辑紧跟在 `addObservation(...)` 之后：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L757-L947)。

检查间隔由 passive actor 的 `actionInterval`/调度决定（不是单独的 trigger sampling interval）。

---

## Q39

**问题原文**

> dependentRelayMode=0 调用原始 newRelease：newRelease 与 strength 的接口如何一致？旧逻辑是否绕过了强度映射？

**回答**

`dependentRelayMode=0` 的语义就是“保持旧行为，不做 AF 映射”，因此会直接调用 `newRelease(...)`。只有 `dependentRelayMode != 0` 时才走 `newReleaseWithStrength(..., strength)`。

逻辑分支在：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L811-L842)。

---

## Q40

**问题原文**

> 你们提供的 old/new 可执行文件如何保证同环境公平对比？README 是否写清：运行命令、配置文件、seed、输出路径、统计脚本？

**回答**

工程上“公平对比”的最低要求是：

- 同一台机器 / 同一 OS
- 同一配置文件 / 同一 seed offset / 同一 repeats

仓库里现在已经有你们生成的批跑脚本（根目录）用于同配置同 seed 跑两套 exe，并输出汇总文件 `benchmark_summary.txt`（速度表 + 正确率表）。

如果要在 README/论文中写清，建议补充：

- 命令行示例（`bin/accord_win.exe config/... 1`）
- 输出路径规则（`results/...`）
- 统计脚本如何运行（`run_all_samples.bat`）

---

## Q41

**问题原文**

> 2. 实验设置与 10^5/10^6/10^7 的“带入方式”（结果强相关）  
> …  
> 如果是每次 emission 的释放量还是 系统内初始分子数？如果两者都有，分别在哪张图？  
> 如果是每次释放量：是通过哪个参数设置（modStrength / strength）？随机释放是否关闭？  
> 如果是系统内分子数：是如何初始化的（t=0 注入？预生成池？逐步释放累积到该规模？）  
> 这三个数量级下，仿真时长/step 数是否相同？如果不同，如何保证可比性？  
> 是否控制了分子类型数量、region 数量、边界类型一致？否则 N 增大同时也改变了其他复杂度。  
> 统计结果是单次运行还是多次 Monte Carlo 平均？方差/置信区间是否报告？  
> 输出指标是什么：运行时间、加速比、观测曲线、误码率、到达计数？每个指标如何计算？  
> 触发/AF 实验里，obsValue 的窗口是多长？窗口长度改变会显著改变 depCount 的尺度。你们是否固定？  
> seed 如何设置？old/new 是否同 seed？若 RNG 调用顺序改变，如何解释不一致？

**回答**

这组问题的关键是：把“规模参数 N”与“统计口径”写成可复现的实验协议。结合当前仓库，可按下面方式在论文/报告里写清：

1) `10^5/10^6/10^7` 到底是什么

- 如果你指的是 **benchmark**：它就是“内存中更新的分子条目数 N”（见 `benchmark_test.c` 的 `sizes[]`）：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L155-L167)
- 如果你指的是 **真实仿真**：必须明确它是 `N_release`（每次释放量）还是 `N_initial`（初始系统分子数）。

2) 如果是每次 emission 的释放量（`N_release`）

- independent active actor：配置里主要通过 `"Modulation Strength"` 控制（例子见 point diffusion sample）：[accord_config_sample_point_diffusion.txt](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/config/accord_config_sample_point_diffusion.txt#L61-L85)
- dependent/AF：触发后通过 `strength = gain*obsValue + bias` 计算，并传入 `newReleaseWithStrength`（即“本次释放量由 strength 决定”）：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L819-L842)

3) 如果是系统内初始分子数（`N_initial`）

当前仓库的 sample 配置通常不直接写“初始总分子数”，而是通过“在 t=0 的 release 注入”或“在前若干次 emission 中累计注入”实现等效初始规模。要写论文建议明确：是否在 `t=0` 一次性释放，还是通过多次 emission 堆到该规模。

4) 可比性（时长/步数/复杂度控制）

- benchmark：步数固定 `NUM_STEPS=100`（可比性天然成立）：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L9-L10)
- 真实仿真：建议固定 `Final Time`、`Micro Time Step`、region/边界/分子类型数，避免 N 增大同时引入额外复杂度变化。

5) Monte Carlo 与方差

仿真重复次数由配置 `"Number of Repeats"` 决定（sample 里常见 10）：[accord_config_sample_point_diffusion.txt](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/config/accord_config_sample_point_diffusion.txt#L15-L29)

论文建议至少报告均值 + 方差/置信区间，而不是只给单次运行。

6) obsValue 的“窗口”问题

当前 dependent actor 的 `depCount` 取的是 **该次 passive observation 的瞬时观测计数**（不是滑动窗口积分），见触发代码：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L792-L803)。

如果论文里需要“窗口累计观测”，那属于模型扩展点，需要在实现与配置里额外引入窗口长度与累计方式。

7) seed 与不一致解释

见 Q36：同 seed 也可能因 RNG 调用顺序变化出现轨迹差异，应以统计一致作为标准（Q7/Q31）。

---

## Q42

**问题原文**

> 3. SoA 数据结构与内存语义（贡献 1 的细节漏洞）  
> SoA 到底包含哪些数组字段？仅 x/y/z/needUpdate 还是还包括 moleculeType、regionId、valid、state？  
> needUpdate 的语义是什么：本 step 更新标记？边界处理后复检标记？由谁置位、何时清零？  
> SoA 池的粒度是什么：每 region 一个池？全局池？每分子类型一个池？为什么这样设计？  
> 分子增删如何实现：swap-and-pop、free-list、还是 compact？  
> 删除/交换会改变分子顺序：这会不会影响 RNG 调用顺序、触发顺序、统计输出顺序？  
> 外部是否存储分子索引/引用？如果 swap 导致索引变化，如何避免悬挂引用？  
> SoA 是否有容量预分配策略？10^7 分子是否反复扩容造成额外开销？  
> SoA 的内存对齐/缓存行利用是否考虑？有没有定量证据（L1/L2 miss、带宽）？  
> SoA 是否引入额外拷贝（AoS→SoA 或 SoA→AoS）？何时发生？成本是否计入？

**回答**

这组问题大部分在源码层可以直接回答：

- 字段范围：当前 `MicroMoleculePool` 只包含 `x/y/z/bNeedUpdate/count/capacity`（不含 moleculeType/regionId 等），见 Q21。
- `needUpdate` 语义：见 Q22。
- 粒度：SoA simple 模式下只支持一个 region+molType 命中（全局唯一），见 Q23 与 Q8。
- 增删：swap-and-pop，见 Q24。
- 顺序影响：会影响 RNG/输出顺序，见 Q25。
- 外部索引/引用：当前仓库没有对外暴露“分子索引句柄”作为稳定引用的机制，因此 swap 引起的索引变化不会产生“悬挂引用”问题（因为本就不支持稳定索引）。
- 容量预分配：初始化时给定初始容量（当前 region 初始化中是 1000），不够则翻倍扩容（Q2）。10^7 规模下如果从 1000 开始确实会经历多次扩容，论文里可建议在大规模实验前按预估 N 直接初始化更大容量。
- 内存对齐/缓存行与硬件计数器证据：仓库未提供硬件计数器数据（需要 `perf`/WPA 等补充）。
- 额外拷贝：当前 guarded SoA simple 的实现路径是“pool 作为 primary storage”，并且 passive observation 针对 pool 有专门扫描函数 `recordMoleculesPool(...)`，因此不会要求每步做 list↔pool 拷贝。证据见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L672-L689)。

---

## Q43

**问题原文**

> 4. guarded entry + fallback 的定义是否充分（贡献 2）  
> “配置兼容性检查”具体检查哪些条件？请逐条列出…  
> 哪些条件是“物理正确性必须”，哪些只是“性能不划算”？你们有没有混用？  
> guard 判断是在 diffuseMolecules 的哪个层级做（每 step 一次、每 region 一次、每分子类型一次）？  
> 兼容性判断是否可能误判？有没有针对每条 guard 条件设计反例测试？  
> fallback 后，SoA 中的分子是否迁回 legacy？还是继续留在 SoA 但不更新？如何避免重复/漏更新？  
> 是否存在“部分兼容”的情况（某些 region 兼容、某些不兼容）？策略是局部启用还是全局禁用？  
> guard 的开销多大？当大多数配置不兼容时，guard 开销会不会抵消收益？  
> “向后兼容”具体指哪些接口/配置文件格式/输出格式不变？有无破坏性更改？

**回答**

- 兼容性检查条件：见 Q8（初始化与运行时都有检查）。
- 哪些是“正确性必须”：涉及 reactions/surfaces/hybrid/meso coupling 的条件更接近“物理语义风险”，因此属于正确性保护。
- 哪些是“性能不划算”：例如“只允许一个 region+molType 命中”更像是当前实现阶段的工程限制（实现成本与复杂度控制），并非物理必须。
- guard 判定层级：初始化阶段全局扫描一次（决定是否启用 `gSoaSimpleEnabled`），运行时在 `diffuseMolecules` 里再次判定是否对该 region/type 走 SoA simple：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L260-L305)，[micro_molecule.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/micro_molecule.c#L387-L416)
- 误判与反例测试：仓库未提供系统化“反例测试集”，建议在论文附录提供每条 guard 的最小反例配置（例如开启 surface、开启 chem rxn、开启 hybrid 等）并展示 SoA 被正确禁用。
- fallback 与分子迁移：当前 SoA simple 不支持“运行中动态回退”，因此不存在“池里已有分子但回退后如何迁回”的路径（见 Q9）。
- 部分兼容：当前设计是全局只允许一个命中，因此策略等价于“局部启用但非常保守”，并且对其他 region/type 始终用 legacy。
- guard 开销：主要是每步在 `diffuseMolecules` 内判断一次布尔条件，开销很小；真正的大头仍是 RNG/validate/调度/I/O（见 Q10/Q45）。
- 向后兼容：在满足条件时仍输出同样格式的结果文件，配置文件字段兼容（新增字段有默认值），这点在 dependent actor 的解析里也体现（未定义则走默认），见：[file_io.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/file_io.c#L2087-L2218)

---

## Q44

**问题原文**

> 5. 正确性验证…  
> 你们验证了哪些 invariant…？  
> old vs new 是否同 seed、同配置、同输出指标？  
> 如果无法 bitwise 一致，用什么统计检验？  
> SoA 与 legacy 在边界处理上是否完全同逻辑？  
> 事件调度是否完全一致？是否引入新的事件类型或改变事件插入时机？  
> 输出文件格式/日志是否一致？  
> 10^7 分子下是否出现数值异常（NaN、越界）？如何检测与处理？

**回答**

当前仓库已经做到/可直接做到的部分：

- old/new 同配置同 seed 跑：你们的批跑脚本已支持（同一个 config + 同一个 seed offset）。
- SoA simple 的边界/几何约束：SoA simple 在 `diffuseMolecules` 内仍复用 `validateMolecule` 相关逻辑（见 `micro_molecule.c` 的 SoA simple 代码段），从而在“启用条件满足时”尽量保持几何处理一致。
- 事件调度：Dependent Actor 的触发是在 passive observation 事件内部立即执行，并通过 `heapTimerUpdate` 写回堆（不会引入新事件类型），见 Q12。

仓库尚未固化、但论文里建议补充的验证项：

- invariant 清单：分子总数守恒（无反应时）、边界吸收/反射率、到达统计一致等
- 统计检验：KS test、置信区间重叠、均值相对误差阈值
- NaN/越界检测：在大规模（10^7）实验时加入运行时检查或离线扫描输出

---

## Q45

**问题原文**

> 6. 性能评估与归因…  
> 合成基准具体测什么？如何保证只测 traversal，不被 RNG/验证/I/O 混入？  
> 真实扩散端到端测的场景配置是什么？  
> 加速比定义是什么：T_old/T_new？是否包含初始化/输出/统计？  
> profiling 用了什么工具/方法？给出热点函数占比…  
> 不同 N 下加速比是否变化？原因是什么（缓存溢出、带宽饱和）？  
> 编译器优化级别是否一致？是否启用 AVX/SSE？

**回答**

- 合成基准：`benchmark_test.c` 的 `benchmark_linked_list` 与 `benchmark_soa` 只做坐标加法更新，基本排除了 RNG/验证/I/O，属于 traversal 上限测试：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L32-L105)
- “更真实”扩散基准：同文件 `diffuseMolecules_pool_bench` 段使用 `generateNormal` 模拟扩散 RNG 成本：[benchmark_test.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/benchmark_test.c#L107-L153)
- 加速比定义：脚本与论文建议统一为 `Speedup = T_old / T_new`，并明确 T 是否包含 I/O、初始化（你们现在抓的 `Simulation ran in ...` 更接近端到端，不含 build/编译）。
- profiling 工具与热点占比：仓库中未保存 profiling 报告，需要补充。
- N 变化下 speedup：合成基准通常随 N 增大更体现 SoA 优势；真实扩散因 RNG/validate 主导，speedup 可能趋于平缓（`research_paper.md` 对此有解释）。
- 编译器/优化/AVX：仓库没有统一写死这些参数，需要在论文/实验脚本中明确并固定。

---

## Q46

**问题原文**

> 7. RNG（随机数）与“统计正确性”风险点…  
> SoA 之后 RNG 调用顺序是否改变？如何确保统计意义正确？  
> RNG 调用次数如何计数？是否考虑批量 RNG / 向量 RNG？  
> 若未来做 SIMD RNG，如何保证可复现？  
> RNG 的开销占比多少？是否下一步优化首选？

**回答**

- RNG 调用顺序：数据结构/遍历顺序改变时可能改变（swap-and-pop、pool 遍历），因此不能期待 bitwise 一致（见 Q25）。
- 统计意义正确：用统计一致作为正确性标准，并在论文中说明“同 seed 但不同路径可能导致轨迹不同，但统计量一致”。
- 调用次数计数：可以在 RNG 封装层（`rand_accord.*`）添加计数器；仓库目前未内置此计数器。
- 批量/向量 RNG：`research_paper.md` 里明确指出 RNG 主导并建议优化（仓库代码层是否已完全实现取决于 `rand_accord` 里是否有 array API；如需论文严谨，建议把实现与实验结果同步）。
- 可复现：跨平台 bitwise 可复现很难（浮点与 RNG 实现差异），论文中一般承诺“同平台同版本可复现”，跨平台用统计一致。

---

## Q47

**问题原文**

> 8. Dependent Actor：触发时机、因果性、并发一致性…  
> passive observation 的事件在调度队列里是什么类型？触发逻辑插在该事件的哪个阶段？  
> “立即触发”是同一事件内执行还是插入新 release event？时间戳如何定义？  
> 多 passive actors 同时触发顺序是否固定？链式触发/循环依赖如何处理？  
> 触发是否受 startTime/numMaxAction 限制？  
> actor 依赖的分子类型如何指定？是否支持多个 molecule types？

**回答**

- 触发插入点：在 passive actor 完成观测并写入 `curMolObs` 后立即执行（同一事件内），见 Q12。
- 时间戳：使用该 passive observation 的事件时间 `timerArray[heapTimer[0]].nextTime`（见 Q12）。
- 多 passive 同时触发：同一时刻事件顺序可能受 heap 排序影响（原版 README 已说明同一时刻 actor 顺序不保证，见 Q17）。
- 链式触发/循环依赖：当前实现只支持 active 依赖 passive（`dependentPassiveActorID`），不会出现 active→active 的链式触发；循环依赖在参数层面也不成立（因为依赖对象是 passive actor id）。
- startTime/maxAction 限制：触发前会检查 startTime 与最大动作次数（`bMaxAction/numMaxAction`），见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L786-L790)
- 依赖分子类型：当前只支持单一 `Dependent Molecule Type`，不支持多类型联合条件，见：[actor.h](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/actor.h#L124-L137)

---

## Q48

**问题原文**

> 9. Trigger Layer：定义细节…  
> depCount 的定义是什么：瞬时计数/窗口累积/到 t 累计？  
> prevCount 的定义是什么？mode=1 里 prevCount 何时更新？  
> mode=0 + rising-edge 使用的 prevCount 是哪个时刻的？  
> “累计增长触发”是否需要 debounce/min interval？

**回答**

- `depCount`：本次 passive observation 对指定 molType 的**瞬时计数**（不是窗口累计），见：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L792-L803)
- `prevCount`：上一次 passive observation 的 depCount（存储在 active actor 的 `depPrevCount` 字段），更新策略见 Q13。
- mode=0 + rising-edge：rising-edge 判断的是 `depCount >= triggerValue` 的布尔值从 false→true 的变化（`depPrevAbove`），同时 `prevCount` 仍用于 relayMode=2 的增量计算：[accord.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/accord.c#L853-L943)
- debounce/min interval：当前实现没有单独的 debounce 机制；如果需要避免噪声导致频繁触发，需要在模型层新增最小触发间隔或窗口平滑，这属于扩展点。

---

## Q49

**问题原文**

> 10. Relay/AF Mapping：strength 的物理含义与数值处理…  
> strength 表示释放分子数还是速率/概率/浓度？  
> strength 若是实数如何处理取整？  
> gain/bias/min/max 默认值与实验值？  
> clamp 是否引入饱和非线性？dependentRelayMode=2 负值物理意义？bias/gain 是否允许为负？

**回答**

- strength 的含义：在当前实现里它作为“本次 release 的强度/等效释放数量”传入 release 管线（见 Q6）。
- 实数取整：`strength` 在触发侧是 `double`，最终如何映射为离散分子数取决于 `newReleaseWithStrength` 的实现，建议在论文明确写出规则（round/floor/随机取整）并讨论偏差（见 Q14）。
- 默认值：配置解析默认值在 `file_io.c` 中给出（relayMode 默认 0，gain 默认 1，bias 默认 0，minStrength 默认 0，maxStrength 默认 INFINITY）：[file_io.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/file_io.c#L2087-L2094)
- clamp：是明确的饱和非线性，会改变线性 AF 假设，论文需要说明饱和区间占比或为何可忽略。
- negative obsValue（mode=2）：见 Q15。
- gain/bias 的取值约束：配置解析中 `Dependent Relay Gain` 被限制为非负（否则回默认 1），bias 没有限制（可为负）：[file_io.c](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/src/file_io.c#L2183-L2199)

---

## Q50

**问题原文**

> 11. 与文献对齐与可复现实验声明…  
> AF 触发/映射与哪篇经典 AF/多跳 MC 模型对应？参数如何映射？  
> 是否复现某篇论文关键曲线？  
> observation window/slotInterval 与文献是否一致？  
> 为什么选择线性映射？是否支持非线性扩展？  
> 中继链路几跳？是否演示随 hop 增加的行为？

**回答**

这部分属于“论文叙事与实验对齐”，仓库代码只能提供“机制已实现”的证据（Trigger/Relay 参数化与执行链路），但不会自动给出“对应哪篇文献”的结论。

建议写法（可直接落地在论文）：

- 明确引用你们对齐的 AF/relay MC 文献（需要你们在论文引用中给出具体论文名/模型方程）
- 把文献中的“观测量→转发强度”映射到代码里的 `gain/bias/min/max` 与 `dependentRelayMode`
- 指定 observation 的时间粒度：由 passive actor 的 act 时间决定；如果文献是窗口积分，需要在模型里实现窗口累计（当前代码是瞬时计数，见 Q48）
- 线性映射的理由：最简单的 AF；非线性映射属于扩展点（当前代码未实现）
- 多跳：当前实现的依赖关系是 active 依赖 passive；要做多跳，需要配置多个 passive+dependent active 组合，形成链路拓扑（代码支持配置多个依赖 actor，但每个依赖对象仍是一个 passive actor id）

---

## Q51

**问题原文**

> 12. 工程交付与复跑…  
> old/new 可执行文件如何保证公平对比？  
> README 是否写清运行命令/配置/seed/输出路径/统计脚本？  
> 是否提供最小可复现案例（MRE）？  
> 新增参数是否有默认值？旧配置不加新字段是否还能跑？  
> 日志/调试开关是否关闭？I/O 是否影响性能测量？

**回答**

- 公平对比：见 Q18/Q40。
- README 清单：当前仓库 README 对原版 AcCoRD 的使用方法有说明（`README.md/README_NO.md`），你们新增的批跑脚本与 dependent actor/AF 参数需要在论文或补充文档中额外写清（`update.md` 已部分覆盖）。
- MRE：仓库里已有 `accord_config_sample.txt`，并在 `update.md` 用它做了 dependent actor 的端到端验证描述：[update.md](file:///c:/Users/65462/Desktop/AcCoRD-master-new-main/update.md#L89-L101)
- 默认值与向后兼容：新增 dependent actor 字段在配置解析里都有默认值/合法性检查，旧配置不加字段仍可跑（见 Q49）。
- I/O 影响：端到端计时会包含写文件与日志打印，性能测量应明确是否包含 I/O，并可通过减少输出或单独 micro-benchmark 隔离 I/O。

---

## Q52

**问题原文**

> 13. 局限性与下一步…  
> SoA 当前覆盖哪些配置？不支持哪些（多 region、多分子类型、反应、表面）？为什么难？  
> 如果加入反应/表面，SoA 需要加哪些字段与流程？guard 条件如何扩展？  
> RNG 是主瓶颈：下一步怎么做？对正确性的影响如何控制？  
> 是否考虑多线程/MPI？

**回答**

- SoA simple 当前覆盖：只覆盖非常简单的 micro-only 场景（单一合格 region+molType、无反应、无表面、无 hybrid/meso 邻居），见 Q8。
- 不支持原因：反应/表面/hybrid/多 region 会引入跨结构访问、邻域查询、事件耦合与顺序敏感逻辑，需要更完整的 SoA 表达（moleculeType、regionId、有效位、邻接索引等）和更复杂的更新/验证流程。
- 扩展 SoA 需要的字段/流程：至少要增加 molecule type、region id、有效位（valid）、可能还需要 reaction state、surface binding state、邻域加速结构等；并且要重新设计“反应匹配/边界交互/跨 region 迁移”的数据流。
- RNG 优化：可以做批量生成（一次生成 dx/dy/dz 数组）、向量化（SIMD）、或减少 `generateNormal` 的调用开销；正确性控制建议以统计一致为标准，并用多 seed+检验方法论证（见 Q7/Q46）。
- 多线程/MPI：当前仿真包含事件堆与全局调度，直接并行化需要分解粒度（例如 SoA pool 的分块并行）并严格处理同步；仓库未实现并行，但 SoA 是必要前置条件之一（数据连续、可切分）。
