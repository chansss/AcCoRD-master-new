
## 1) Overview / Problem Formulation（方法总览）

### 1.1 我到底要解决什么问题（研究目标）

把问题说得像小学生能听懂：

- 原来的程序像“拿一串珍珠项链数珠子”：每颗珠子（分子）用一个小盒子装起来，再用绳子（指针）串起来。数的时候要顺着绳子一个个摸过去，手会经常摸空（CPU cache miss），所以慢。
- 我想让它变成“把同类珠子排成整齐的三行”：第一行全是 x 坐标，第二行全是 y 坐标，第三行全是 z 坐标。这样数的时候手一直往前滑（连续内存访问），更快。
- 同时，我还想让系统支持一种新通信行为：一个“主动发射者（Active Actor）”可以依赖另一个“被动观察者（Passive Actor）”的观测结果来决定何时发射、发射多强（Amplify-and-Forward，AF 转发）。

把问题说得像科研评审能核对：

- **性能升级目标**：减少微观扩散（micro diffusion）阶段的内存访问开销与随机数调用开销，降低关键路径（critical path）上的 cache miss 与函数调用开销；在不改变物理模型假设的前提下提升 wall-clock time。
- **功能升级目标**：在离散事件仿真（DES）框架中新增“依赖型主动 Actor（dependent active actor）”，并支持 AF（线性映射）转发，使得释放强度可以由被动观测值驱动，而不仅仅由预置比特/独立调制驱动。
- **评价目标**：同时评价 (a) 性能（运行时间/加速比）与 (b) 结果一致性（输出曲线/计数序列一致或统计一致）。

### 1.2 贡献点如何对应目标（贡献清单）

本文把贡献分为两类，每类都能在代码里找到对应实现：

**A. Proposed Acceleration Method（加速类）**

1. 新的数据布局：`MicroMoleculePool`（SoA：Structure of Arrays）
   - 结构体定义：`src/micro_molecule.h` 的 `struct MicroMoleculePool`。
   - 生命周期挂载到 region：`src/region.c` 初始化 micro region 的 `regionArray[i].molPool`。
2. 批量正态随机数生成：`generateNormalArray`
   - 实现：`src/rand_accord.c`。
3. 观测位置存储结构改造：分子位置从“链表节点逐个复制”变为“X/Y/Z 三数组”
   - 结构体字段：`src/observations.h` 的 `molPosX/molPosY/molPosZ`。
   - 填充与释放：`src/observations.c` 的 `addObservation/emptyListObs`。
4. 受控集成（guarded entry）：SoA 仅在满足严格条件时才接管某些 micro list
   - 开关：环境变量 `ACCORD_USE_SOA_SIMPLE`。
   - 候选过滤：`src/accord.c` 中对 region 与 molecule type 的多条件筛选。

**B. Proposed Functional Extension / New Capability（功能扩展类）**

1. 新增“依赖型主动 Actor”参数与状态
   - 配置字段：`src/actor.h` 的 `actorStructSpec3D` 增加 `dependent*` 字段。
   - 运行态状态：`src/actor.h` 的 `actorActiveStruct3D` 增加 `depPrevCount/depPrevAbove`。
2. 新增 AF（Amplify-and-Forward）线性映射：`strength = gain * obsValue + bias`，并做 clamp（min/max）
   - 触发与映射：`src/accord.c` 在 passive actor 完成一次观测后，驱动 dependent active actor 的 `newReleaseWithStrength`。
3. 配置解析扩展：支持 dependent/AF 参数从 JSON 配置读入并做默认值与合法性校验
   - 解析位置：`src/file_io.c` 的 `loadConfig`。
4. 定时器堆（timer heap）一致性：dependent actor 触发后需要立即更新 heap
   - 调用：`src/accord.c` 里触发后调用 `heapTimerUpdate(...)`（实现在 `src/timer_accord.c`）。

### 1.3 系统输入/输出（Input / Output）

**输入（Input）**

- 配置文件：`config/accord_config_sample*.txt`（JSON）
  - 由 `src/file_io.c:loadConfig(...)` 解析。
- 可执行文件：
  - 新版：`bin/accord_win.exe`
  - 旧版：`bin/accord_win_old.exe`
- 随机数种子：运行时第二个命令行参数（例如 `...exe config.txt 1`），或配置内 `"Random Number Seed"`。
- 可选环境变量：`ACCORD_USE_SOA_SIMPLE`
  - 存在则尝试启用 SoA-simple；不存在则完全不走 SoA 路径。

**输出（Output）**

- 结果文本：`results/<Output Filename>_SEED<seed>.txt`
- 汇总 JSON：`results/<Output Filename>_SEED<seed>_summary.txt`
  - 由 `src/file_io.c:initializeOutput(...)` 打印与创建。
- 本项目为批处理收集提供两个目录：
  - `matlab_new/`：运行新版 exe 复制来的结果
  - `matlab_old/`：运行旧版 exe 复制来的结果
  - 脚本：`run_new.bat` / `run_old.bat`

### 1.4 关键假设与范围（Scope / Assumptions）

这部分是“减少质疑”的关键：我明确说清楚哪些覆盖、哪些不覆盖。

**(A) 性能升级（SoA）覆盖范围**

- 本项目实现的是 **SoA-simple**：只覆盖一小类“非常干净”的微观扩散场景。
- SoA-simple 的启用是**显式 opt-in**（环境变量开关），并且有多条 guard 条件（见 `src/accord.c`）。
- **不覆盖**：
  - 分子跨 region 迁移的 SoA 化（当前 SoA-simple 遇到 region transition 会直接报错退出）
  - micro/meso hybrid 接口的 SoA 化
  - 含化学反应（尤其是会创建/销毁分子的反应）的 SoA 化
  - 含 surface/membrane 交互的 SoA 化

之所以这样“严格限制”，不是“我不想开”，而是因为当前 SoA 实现只写到了“原地更新坐标”的阶段；跨区迁移/反应会引入复杂的“增删/搬运/一致性维护”问题，贸然默认开启会造成崩溃或数值错误。

**(B) 功能升级（dependent + AF）覆盖范围**

- 覆盖：active actor 依赖 passive actor 的“当前一次观测计数”来触发发射；支持阈值触发、增量阈值触发；支持 AF 线性映射强度并 clamp。
- 不覆盖：
  - 多级链路的自动拓扑推导（目前是配置指定 dependentPassiveActorID）
  - 连续时间控制理论意义上的放大器噪声模型（AF 只是一个线性映射，不建模噪声）

---

## 2) Baseline System（基线与原始流程）

### 2.1 基线系统整体流程（主循环 / 事件调度）

把 DES（离散事件仿真）讲得像小学生能理解：

- 我们有一个“闹钟堆”（heap），里面装了很多闹钟：
  - 每个 actor 一个闹钟（它下一次要行动的时间）
  - 一个 meso 闹钟（下一次介观反应发生的时间）
  - 一个 micro 闹钟（下一次微观扩散步的时间）
- 每一轮都去看“最早响的闹钟是谁”，然后执行对应动作，把那个闹钟拨到下一次响的时间，再放回堆里。

对应代码位置：

- 主循环：`src/accord.c` 的 `while(timerArray[heapTimer[0]].nextTime <= spec.TIME_FINAL)`。
- timer heap 的维护：`src/timer_accord.c:heapTimerBuild/heapTimerUpdate(...)`。

### 2.2 一张“总流程图”的简化伪代码（Baseline Pseudocode）

下面伪代码对应 `src/accord.c` 的主循环结构（省略大量细节）：

```text
loadConfig()
initialize regions / subvolumes / reactions
initialize actors (active/passive)
initialize timers + build timer-heap

while (minTimerTime <= TIME_FINAL):
    t = minTimerTime
    id = minTimerId

    if id is an Actor:
        if actor is Active:
            if next action is "new release":
                create release object (schedules emissions)
            else:
                fire an emission (place molecules)
            update that actor's nextTime

        else actor is Passive:
            count molecules in actor space (micro: scan lists, meso: sample by fraction)
            (optionally) record positions
            append observation to observation list
            update that passive actor's nextTime

    else if id is MICRO timer:
        execute micro-step:
            zeroth-order reactions (create molecules)
            micro diffusion + flow + boundary handling
            first/second order reactions (if any)
        update micro timer nextTime = t + DT_MICRO

    else if id is MESO timer:
        execute next meso event (reaction/diffusion between subvolumes)
        update meso timer to next meso event time

    heapTimerUpdate(...)  // keep heap valid

write output files
```

### 2.3 基线数据结构与关键路径（瓶颈在哪里）

**基线微观分子存储（AoS 链表）**

- 微观分子在每个 `(region, molType)` 下用链表存储：`NodeMol3D`。
- 遍历扩散时需要“指针追逐”（next 指针），导致内存访问不连续，cache miss 多。
- 关键函数：`src/micro_molecule.c:diffuseMolecules(...)`（扫描所有 region/type 的链表，逐个分子更新坐标并做合法性检查）。

**基线观测存储**

- 被动 actor 每次观测会把计数与（可选）位置写入观测链表。
- 观测节点会复制位置数据；如果位置用链表表示，会产生额外复制与遍历开销。
- 本项目把位置改成 X/Y/Z 三数组（见第 3 节）。

**基线调度开销**

- timer heap 更新需要维护最小堆性质：`heapTimerUpdate(...)`。
- 在新功能（dependent actor）引入后，触发会改变某些 timer 的 nextTime，因此必须及时更新堆。

### 2.4 对比对象说明（我在比较什么）

本项目对比两个可执行文件：

- 新：`bin/accord_win.exe`（通过 `src/build_accord_opt_win.bat` 可用 `gcc ... -O3` 构建）
- 旧：`bin/accord_win_old.exe`（仓库里保留的旧版二进制）

比较时必须保证：

- 使用相同配置文件（同一个 `config/*.txt`）
- 使用相同 seed（例如命令行第二参 `1`）
- 输出文件按同名规则生成（`Output Filename` + `_SEED1`）

---

## 3) Proposed Method(s)（提出的方法与设计）

本节按统一模板写两类贡献：加速方法与功能扩展方法。

---

### Proposed Acceleration Method（加速方法）

#### 3.1 Design Rationale（动机与直觉）

**小学生版直觉**

- 链表像“散落一地的小纸条，用订书钉连着”，你每次要读一张纸条，就得先找到订书钉位置，绕来绕去，很慢。
- 数组像“一本书”，你从第一页翻到最后一页，手指一直往前滑，很快。

**科研版直觉（为什么理论上会更快）**

- CPU 访问内存有多级缓存（L1/L2/L3）。连续访问数组能让硬件预取（prefetch）有效工作，减少 cache miss。
- SoA 使得同一字段连续：例如连续读取 `x[i]`，比从 `struct {x,y,z,...}` 的链表节点里零散取 `x` 更适合向量化（SIMD）。
- 对扩散这种“对所有分子做相似操作”的内核，性能通常受内存带宽与分支预测影响；SoA 减少指针追逐，理论上减少分支与随机访问。

#### 3.2 Data Structures / Interfaces（数据结构与接口）

**3.2.1 新增/替换的数据结构**

1) `MicroMoleculePool`（SoA 容器）

- 定义位置：`src/micro_molecule.h` 的 `struct MicroMoleculePool`。
- 字段语义（把它当成“很多分子的一摞坐标表”）：
  - `x/y/z`：第 i 个分子的坐标
  - `bNeedUpdate[i]`：对应基线里每个分子节点的 `bNeedUpdate`
  - `count/capacity`：动态数组大小
- 关键接口（都在 `src/micro_molecule.h` 的 inline 函数里）：
  - `pool_init`：分配数组并设定容量
  - `pool_add_molecule`：追加一个分子（必要时扩容）
  - `pool_remove_molecule`：删除一个分子（用末尾元素覆盖洞）
  - `pool_free`：释放内存

2) region 挂载 `molPool`

- 结构体字段：`src/region.h` 的 `struct region` 增加 `struct MicroMoleculePool * molPool;`。
- 初始化：`src/region.c` 在 `initializeRegionArray(...)` 的尾部，对 micro region 分配 `molPool` 并 `pool_init(...)`。

3) 观测位置：`molPosX/Y/Z`

- 字段：`src/observations.h` 的 `struct observation_list3D` 增加 `double ** molPosX/m
  olPosY/molPosZ`。
- 赋值与释放：`src/observations.c:addObservation/emptyListObs`。

**3.2.2 与旧模块的接口契约（过渡阶段最关键）**

为了避免“全项目一次性大手术”，我采用了“过渡期双轨制”：

- 绝大多数旧代码仍以 `ListMol3D`（链表指针）为接口。
- SoA 只在极小范围内接管某些 `(region, molType)` 的链表入口，接管方式是：
  - 运行时维护映射表：`gSoaSimplePools[]` 与 `gSoaSimpleLists[]`（定义在 `src/micro_molecule.c`，声明在 `src/micro_molecule.h`）
  - 当旧代码调用 `addMolecule(&microMolList[r][t], ...)` 时，函数内部通过指针比较把“新增分子”重定向到 pool（见 `src/micro_molecule.c:addMolecule(...)`）。

这套契约的核心原则是：

- **如果没有显式开启 SoA**（环境变量缺失），系统行为与基线完全一致。
- **如果开启 SoA**，也只对满足 guard 条件的列表接管；其它列表仍走链表。

#### 3.3 Algorithm / Control Flow（算法与流程）

**3.3.1 SoA-simple 的启用流程（Guarded Entry）**

启用开关与候选筛选在 `src/accord.c`：

1) 必须设置环境变量：

```c
const char* soaEnv = getenv("ACCORD_USE_SOA_SIMPLE");
if(soaEnv != NULL) { ... }
```

2) 只有满足多条条件的 micro region 才会被加入候选（伪代码化）：

```text
for each region r:
    require r is micro
    require r has no chemical reactions
    require r has no meso neighbor (not hybrid boundary)
    require r has a valid molPool
    require r is not a surface/membrane region

    for each molType t:
        require no a-priori surface reaction applies to (r,t)
        require MAX_HYBRID_DIST == 0
        mark (r,t) as SoA-simple candidate
```

这一步的目的不是“刁难”，而是保证 SoA-simple 内核永远不会遇到：

- 跨 region 迁移
- micro/meso 交换
- surface/membrane 反应
- 会创建/销毁分子的化学反应

**3.3.2 SoA-simple 扩散内核伪代码**

SoA-simple 的核心在 `src/micro_molecule.c:diffuseMolecules_pool_simple(...)`，它做的事情可以写成：

```text
if pool empty: return
if this molType has neither diffusion nor flow: return

if diffusion enabled:
    generate dx[0..N-1], dy[0..N-1], dz[0..N-1] ~ Normal(0, sigma)

for i in 0..N-1:
    old = (x[i], y[i], z[i])
    new = old
    if diffusion: new += (dx[i], dy[i], dz[i])
    if flow:      new += flowConstant

    ok = validateMolecule(new, old, ...)  // 复用基线几何/边界合法性检查
    if not ok:
        new = old   // 回滚

    if newRegion != curRegion:
        ERROR + exit  // SoA-simple 不支持跨区

    write back x[i],y[i],z[i]
```

**3.3.3 批量 RNG 的数学依据（sigma 从哪里来）**

微观扩散使用布朗运动模型。对 3D 的每个坐标分量：

- 连续形式：ΔX ~ Normal(0, 2DΔt)
- 离散实现：每个坐标加一个正态随机变量：

```math
\sigma = \sqrt{2 D \Delta t}, \quad
\Delta x \sim \mathcal{N}(0, \sigma^2)
```

这里 `D` 是扩散系数（Diffusion Coefficient），`Δt` 是微观时间步长。

基线实现是每个坐标都调用一次 `generateNormal(...)`；本项目增加了 `generateNormalArray(...)`（`src/rand_accord.c`），一次批量生成数组，减少函数调用与状态分支开销。

#### 3.4 Complexity & Trade-offs（复杂度与代价）

**时间复杂度（单个 micro 扩散步）**

- 基线链表：`O(N)`，但常数项大（指针追逐、cache miss、函数调用多）。
- SoA-simple：`O(N)`，常数项理论更小（连续内存、批量 RNG）。

**空间开销**

- SoA-simple 需要为每个 pool 存 `x/y/z/bNeedUpdate` 四个数组，空间约 `O(N)`。
- SoA-simple 在当前实现里还会在每步分配 `dx/dy/dz`（长度 N），额外 `O(N)` 临时空间。

#### 3.5 Correctness / Compatibility（正确性与兼容性）

**必须保持的不变量（invariants）**

- 分子必须位于合法空间：不能穿出区域边界、不能穿入非法表面内部。
  - 由 `validateMolecule(...)` 与 `followMolecule(...)` 等基线几何逻辑保证（`src/micro_molecule.c`）。
- 计数守恒（在无反应情况下）：扩散与流动不会凭空创建/删除分子。
- 随机性一致性：同一个 seed 下，若算法不同可能导致随机数消耗顺序变化，因此不保证 bitwise 完全相同，但应保证统计性质一致（均值/方差/分布一致）。

**与旧行为一致性**

- 默认不开环境变量时，SoA 完全不启用（`gSoaSimpleEnabled=false`），因此行为与基线一致。
- 即使开启环境变量，SoA-simple 也只接管极少数组合；其它逻辑仍走基线链表与反应/跨区逻辑。

---

### Proposed Functional Extension / New Capability（功能扩展：Dependent Actor + AF）

#### 3.1 Design Rationale（动机与直觉）

**小学生版直觉**

- 原来系统里，主动 actor 像“按闹钟定时撒糖”：到了时间就撒固定数量的糖（分子）。
- 我新增的功能是：让它变成“看到别人拿到多少糖，再决定自己撒多少糖”。
  - 例如：接收者（passive）数到 100 个分子，转发者（active）就开始撒糖。
  - 甚至撒糖的数量也可以由观测值决定：数到越多就撒越多（AF 放大转发）。

**科研版动机**

- 在分子通信场景中，AF（Amplify-and-Forward）是经典中继策略：中继节点根据观测信号强度决定转发强度。
- 在 AcCoRD 这种 DES 框架里，实现 AF 的关键不是“数学难”，而是“事件调度一致性”：触发时刻如何定义、触发后 timer heap 如何更新，才能保证仿真时间线正确。

#### 3.2 Data Structures / Interfaces（数据结构与接口）

**3.2.1 新增配置字段（actor spec）**

位置：`src/actor.h` 的 `struct actorStructSpec3D` 增加如下字段：

- `dependentPassiveActorID`：依赖哪个 passive actor（common actor id）
- `dependentMolType`：依赖哪种分子类型的观测计数
- `dependentTriggerMode`：触发模式
  - `0`：阈值触发（count >= threshold）
  - `1`：增量阈值触发（count >= prevCount + delta）
- `dependentTriggerValue`：阈值（或增量阈值）
- `bDependentRisingEdge`：是否只在“从未达阈到达阈”的上升沿触发
- `dependentRelayMode`：转发模式
  - `0`：触发后按原逻辑 `newRelease(...)`
  - `1`：AF 映射使用 obsValue = 当前 count
  - `2`：AF 映射使用 obsValue = (count - prevCount)（允许负值）
- `dependentRelayGain / dependentRelayBias`：AF 线性映射参数
- `dependentRelayMinStrength / dependentRelayMaxStrength`：强度 clamp

**3.2.2 运行态状态（active actor）**

位置：`src/actor.h` 的 `struct actorActiveStruct3D` 增加：

- `depPrevCount`：上一轮用于“增量阈值/增量映射”的计数记忆
- `depPrevAbove`：上一轮是否已经“在阈值之上”（用于 rising-edge）

初始化位置：`src/actor.c` 的 `initializeActorActivePassive(...)` 会将它们设为 `0/false`。

**3.2.3 配置解析（file_io）**

位置：`src/file_io.c:loadConfig(...)`。

- 默认值先写入（例如 `dependentPassiveActorID=-1`、`dependentRelayMode=0`、gain=1、bias=0、min=0、max=INFINITY）。
- 当 actor 是 active 且 `bIndependent==false` 时才读取 dependent 字段，否则忽略并提示 warning。

#### 3.3 Algorithm / Control Flow（算法与流程）

**3.3.1 触发时机（在时间线上到底什么时候发生）**

触发逻辑放在 `src/accord.c` 的“被动 actor 完成一次观测之后”，也就是：

1) passive actor 计数 `curMolObs[]` 刚刚算完；
2) 如果需要记录，则 `addObservation(...)` 已把这次观测写入观测链表；
3) 接着遍历所有 active actors，找出依赖当前 passive actor 的 dependent actors；
4) 满足触发条件则立即创建 release（并更新 timer heap）。

这样做的含义是：

- dependent actor 的触发时间戳取 `timerArray[heapTimer[0]].nextTime`（也就是这次观测发生的时刻）。
- 这符合“AF 中继在观测后立刻开始转发”的离散事件解释：同一仿真时刻，先观测再触发。

**3.3.2 触发条件与 AF 映射伪代码**

伪代码（对应 `src/accord.c` 的 dependent 分支）：

```text
given dependent actor A depends on passive actor P:
    depCount = P.curMolObs[molType]

    if triggerMode == delta:
        if depCount >= prevCount + triggerValue:
            fire(A)  // 见下
        prevCount = depCount

    else triggerMode == threshold:
        depAbove = (depCount >= triggerValue)
        if risingEdge:
            if depAbove && !prevAbove:
                fire(A)
            prevAbove = depAbove
        else:
            if depAbove:
                fire(A)
            prevAbove = depAbove
        prevCount = depCount

fire(A):
    if relayMode == 0:
        newRelease(A, timeNow)
    else:
        obsValue = (relayMode==2) ? (depCount - prevCount) : depCount
        strength = gain * obsValue + bias
        strength = clamp(strength, minStrength, maxStrength)
        newReleaseWithStrength(A, timeNow, strength)

    // 关键：更新 A 的 timer，并 heapTimerUpdate
```

**3.3.3 为什么必须更新 timer heap（否则会发生什么）**

在 DES 里，堆顶永远必须是“下一件要发生的事”。触发 dependent actor 会改变：

- 该 actor 的下一次发射时间（`nextEmissionTime`）
- 因此 `timerArray[depActorID].nextTime` 也要更新
- 堆里这个元素的位置必须立刻调整，否则堆顶可能仍然是旧的、更晚的事件，导致时间线错误。

因此在触发后，代码调用：

- `heapTimerUpdate(NUM_TIMERS, timerArray, heapTimer, timerArray[depActorID].heapID, ...)`
  - 实现在 `src/timer_accord.c`。

#### 3.4 Correctness / Compatibility（正确性与兼容性）

**不变量**

- 时间不倒流：所有 nextTime 更新必须保证堆顶取出的时间是非递减的。
- 动作计数一致：如果 `bMaxAction`，触发不能超过 `numMaxAction`。
- 观测-触发因果关系：触发必须使用“刚刚完成的那次观测”的值，不能用未来值。

**与旧行为一致性**

- 如果 actor 是 independent（`bIndependent==true`），则完全沿用旧逻辑，不读取 dependent 字段。
- 如果用户不在配置里填写 dependent 字段，默认值不会改变原行为（`dependentPassiveActorID=-1`，触发分支不会命中）。

---

## 4) Experimental Setup（实验设计与复现条件）

本节尽量写成“说明书”，让别人拿到仓库就能复现。

### 4.1 Test Cases / Scenarios（测试场景）

本仓库自带一组样例配置：

- `config/accord_config_sample*.txt`

它们覆盖的维度包括（示例，不穷尽）：

- micro-only / meso-only / hybrid（混合）
- 是否有 flow
- 是否有 surface/membrane 与表面反应
- 分子类型数量、扩散系数差异

### 4.2 Parameters（关键参数口径）

对每次运行，至少要固定：

- 配置文件：`config/*.txt`
- seed：命令行第二参，例如 `1`
- 重复次数：配置中的 `"Number of Repeats"`
- 终止时间：配置中的 `"Final Simulation Time"`
- 微观时间步：配置中的 `"Global Microscopic Time Step"` 或相关字段

### 4.3 Implementation Details（实现与编译）

**Windows 构建（新版本）**

- `src/build_accord_opt_win.bat` 使用 `gcc ... -std=c99 -O3` 生成 `bin/accord_win.exe`。

**SoA 开关（重要）**

- 默认不启用 SoA-simple。
- 若要启用，需要设置环境变量 `ACCORD_USE_SOA_SIMPLE`（存在即可，不要求具体值）。

### 4.4 Hardware/OS（硬件环境）

评审通常要求至少写清楚：

- CPU 型号、核数、主频策略（是否固定频率/关闭睿频）
- 内存容量
- 操作系统版本
- 是否独占机器运行（避免后台任务干扰）

（此处留给实际测机时补齐。）

### 4.5 Measurement Protocol（计时与统计）

建议的严谨计时口径：

- 每个 config 运行多次（例如 10 次），取均值与标准差。
- 计时只统计仿真阶段（不含编译与文件复制）。
- 同一 config 的 new/old 使用同一 seed，以减少随机波动。

仓库内已有一个 PowerShell 脚本用于批量运行并解析时间行：

- `run_all_samples.ps1` 会抓取输出中的 `Simulation ran in ...` 行做汇总。

此外我提供了两个“可双击运行”的批处理脚本用于分别跑 new 与 old：

- `run_new.bat`：跑 `bin/accord_win.exe`，结果复制到 `matlab_new/`
- `run_old.bat`：跑 `bin/accord_win_old.exe`，结果复制到 `matlab_old/`

---

## 5) Evaluation Metrics（指标与统计口径）

### 5.1 性能指标（Performance）

最低限度要报告：

- **Wall-clock time**：每个 config 的总运行时间（秒）
- **Speedup**：`speedup = T_old / T_new`

可选加分项（若你有工具/脚本支持）：

- 单位时间吞吐：`molecules / step / second`
- 内存峰值：RSS 或 peak allocation（需要额外工具）

### 5.2 准确度/一致性（Correctness / Consistency）

根据“优化是否改变随机数消耗顺序”，一致性口径可以分两档：

- **bitwise 一致**：输出文件每个数完全相同（最强，但很难保证）
- **统计一致**：输出曲线的均值/方差/置信区间一致（科研更常见，尤其在 RNG 路径变化时）

本项目中：

- dependent actor 功能扩展会改变系统行为（这是“新能力”，不是误差），因此比较时要确保用相同的功能开关与配置。
- SoA 与批量 RNG 可能改变随机数调用顺序，因此不强制 bitwise 一致；建议用统计一致口径，并解释原因（见第 6 节威胁与限制）。

### 5.3 取样与统计（Sampling / Statistics）

建议写清楚：

- 重复运行次数 `n`
- seed 策略（固定 seed / 多 seed）
- 置信区间（例如 95% CI）
- 是否做显著性检验（可选）

---

## 6) Threats to Validity / Limitations（有效性威胁与限制）

### 6.1 内部有效性（Internal Validity）

- **编译器与优化差异**：新旧二进制可能由不同编译器/不同优化参数构建，导致“看起来全部加速”。必须在实验中尽量统一构建链路，否则加速来源会混杂。
- **缓存热度与预热**：第一次运行可能更慢；建议预热或丢弃第一次结果。
- **系统噪声**：后台进程、CPU 频率调度会引入计时波动。

### 6.2 外部有效性（External Validity）

- **SoA-simple 覆盖范围窄**：即使开启 SoA，也只对满足 guard 条件的组合生效；对复杂 config（hybrid、反应、跨区）不会生效或不支持。
- **AF 是线性映射模型**：未建模噪声、非线性放大、饱和等更复杂物理/电路效应。

### 6.3 构造有效性（Construct Validity）

- **“准确度”指标选择**：若只比较某个单点计数，可能掩盖了曲线形状差异；建议比较整条时间序列或关键统计量。
- **“性能”指标选择**：若只给总时间，不区分 micro/meso/actor 的开销来源，很难说明优化点确实命中了瓶颈；若条件允许可加 profiling 证据。

---

## 附：快速定位关键实现（给评审/老师查证用）

- 主循环与 dependent 触发：`src/accord.c`
- SoA-simple 开关与候选筛选：`src/accord.c`（环境变量 `ACCORD_USE_SOA_SIMPLE`）
- SoA 数据结构与 pool 操作：`src/micro_molecule.h`
- SoA-simple 扩散内核与 addMolecule 重定向：`src/micro_molecule.c`
- region 挂载 molPool：`src/region.h` / `src/region.c`
- 批量 RNG：`src/rand_accord.c:generateNormalArray`
- dependent/AF 配置字段：`src/actor.h`
- dependent/AF 配置解析：`src/file_io.c`
- timer heap：`src/timer_accord.c`
- 观测位置三数组：`src/observations.h` / `src/observations.c`
- 批量运行脚本：`run_new.bat` / `run_old.bat` / `run_all_samples.ps1`
- 微基准：`benchmark_test.c`

