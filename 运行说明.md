## 1. 环境准备（Windows）

- 操作系统：Windows 10 / 11（64 位）。
- 编译器：已安装并加入 `PATH` 的 GCC，推荐：
  - MinGW-w64（如 MSYS2 环境中的 `mingw64` 工具链），或
  - 其它支持 C99 的 gcc 发行版。
- 需要能够在命令行中直接运行 `gcc`、`cmd` 等命令。

源码目录结构的关键部分：

- `src\`：C 源码与构建脚本。
  - `build_accord_debug_win.bat`：Windows 调试版构建脚本。
  - `build_accord_opt_win.bat`：Windows 优化版（发布）构建脚本。
- `config\`：示例配置文件（JSON 格式，扩展名 `.txt`）。
- `bin\`：构建后可执行文件的默认输出目录。
- `results\` 或 `..\results\`：运行时自动创建的结果目录。

下面所有路径都默认以仓库根目录为起点，例如：

```text
AcCoRD-master\
  src\
  config\
  bin\
  ...
```

---

## 2. 编译工程（生成 Windows 可执行文件）

### 2.1 调试版（方便调试、带符号信息）

1. 打开命令行（`cmd` 或 PowerShell），切换到 `src` 目录：

   ```bat
   cd path\to\AcCoRD-master\src
   ```

2. 运行调试版构建脚本 `build_accord_debug_win.bat`：

   ```bat
   build_accord_debug_win.bat
   ```

3. 正常结束后，会在 `bin` 目录下生成调试版可执行文件：

   ```text
   bin\accord_win_debug.exe
   ```

   构建脚本路径：`src\build_accord_debug_win.bat`。

### 2.2 优化版（发布/性能测试推荐）

1. 同样切换到 `src` 目录：

   ```bat
   cd path\to\AcCoRD-master\src
   ```

2. 运行优化版构建脚本 `build_accord_opt_win.bat`：

   ```bat
   build_accord_opt_win.bat
   ```

3. 正常结束后，会在 `bin` 目录下生成优化版可执行文件：

   ```text
   bin\accord_win.exe
   ```

   构建脚本路径：`src\build_accord_opt_win.bat`。

> 建议：
> - 开发/调试时使用 `accord_win_debug.exe`，便于定位问题。
> - 性能实验或正式仿真时优先使用优化过的 `accord_win.exe`。

---

## 3. 运行可执行文件

AcCoRD 的主程序入口在 `src\accord.c` 中，可执行文件的命令行形式统一为：

```text
accord_win.exe [CONFIG_PATH] [SEED]
```

或调试版：

```text
accord_win_debug.exe [CONFIG_PATH] [SEED]
```

含义如下：

- `CONFIG_PATH`（可选）：
  - 仿真配置文件路径，通常位于 `config\` 目录，例如：
    - `config\accord_config_sample_point_diffusion.txt`
    - `config\accord_config_sample_all_shapes_micro.txt`
  - 若 **省略**，则使用源码中默认配置文件：
    - `src\accord.c:96` 定义的 `CONFIG_NAME = "accord_config_sample.txt"`。
- `SEED`（可选）：
  - 随机数种子偏移量（无符号整数），类型为 `uint32_t`。
  - 如果提供该参数，将覆盖配置文件中 `"Simulation Control" -> "Random Number Seed"` 字段（`src\file_io.c:248-265`）。
  - 如果省略，则使用配置文件中指定的种子。

### 3.1 命令行调用示例

以下示例假设当前目录为仓库根目录 `AcCoRD-master\`。

1. 使用优化版，读取点扩散示例配置，使用配置文件中的随机种子：

   ```bat
   bin\accord_win.exe config\accord_config_sample_point_diffusion.txt
   ```

2. 使用优化版，读取复杂全微观示例配置，并显式设置种子偏移为 3：

   ```bat
   bin\accord_win.exe config\accord_config_sample_all_shapes_micro.txt 3
   ```

3. 使用调试版、默认配置文件、默认种子：

   ```bat
   bin\accord_win_debug.exe
   ```

运行时，程序会在控制台输出初始化信息，包括：

- 版本号、版权信息（`src\accord.c:127-131`）。
- 配置加载方式及文件名（`src\accord.c:139-162`）。
- 区域数、子体积数等环境信息。
- 仿真开始时间、结束时间，以及总运行时间（`"Simulation ran in ... seconds"`）。

---

## 4. 启用 SoA 简化路径（可选）

如果需要在 Windows 下测试 SoA 简化路径（`ACCORD_USE_SOA_SIMPLE`），可以通过环境变量开启。

### 4.1 使用 `cmd` 设置环境变量并运行

在 `cmd` 中：

```bat
cd path\to\AcCoRD-master
set ACCORD_USE_SOA_SIMPLE=1
bin\accord_win.exe config\accord_config_sample_point_diffusion.txt 1
```

说明：

- `set ACCORD_USE_SOA_SIMPLE=1` 仅对当前命令行会话生效。
- 程序启动时在 `src\accord.c:261-305` 中读取该环境变量，如果：
  - 存在一个满足一系列约束条件的微观区域和分子类型（单区域、无反应、无混合微–宏接口等），则：
    - 将为该区域/类型启用 SoA 简化 diffusion 路径；
  - 否则自动退回到传统 AoS 链表实现。

若不设置该环境变量，程序默认使用原始 AoS 实现，行为与上游 AcCoRD 一致。

---

## 5. 结果文件位置与命名规则

结果输出逻辑集中在 `src\file_io.c:2670-2779` 的 `initializeOutput` 函数中。

### 5.1 结果目录

程序启动时会按以下顺序寻找/创建结果目录：

1. 如果当前工作目录下存在 `results\` 文件夹，则使用它；
2. 否则如果上一层目录存在 `..\results\`，则使用它；
3. 否则尝试在当前目录下创建 `results\`：
   - Windows 下使用 `_mkdir("results")` 创建；
   - 创建失败会导致程序报错退出。

对绝大多数使用场景，**在仓库根目录下运行可执行文件** 时，仿真结果会写入：

```text
AcCoRD-master\results\
```

### 5.2 输出文件命名

输出文件名由配置文件中的 `"Output Filename"` 和随机数种子共同决定（`src\file_io.c:267-279`）：

- `curSpec->OUTPUT_NAME` 的构造方式为：

  - 若配置文件未指定 `"Output Filename"`：

    ```c
    curSpec->OUTPUT_NAME = "test_SEED<seed>";
    ```

  - 若配置文件指定 `"Output Filename": "accord_sample_point_diffusion"`：

    ```c
    curSpec->OUTPUT_NAME = "accord_sample_point_diffusion_SEED<seed>";
    ```

- 在构造完整路径时，程序会附加扩展名：

  - 结果文件：`<OUTPUT_NAME>.txt`
  - 汇总文件：`<OUTPUT_NAME>_summary.txt`

因此，一个典型的点扩散配置运行（`"Output Filename": "accord_sample_point_diffusion"`，种子 `SEED = 3`）会生成：

```text
results\accord_sample_point_diffusion_SEED3.txt
results\accord_sample_point_diffusion_SEED3_summary.txt
```

---

## 6. 结果文件内容概览

### 6.1 主结果文件：`<OUTPUT_NAME>.txt`

主结果文件包含仿真每个 realization 的详细观测数据，具体格式由内部的输出函数生成，例如：

- `printOneTextRealization`：按 realization 输出被动观测器的时间序列观测值（分子计数等），对应：
  - 被动 actor 的索引；
  - 仿真时间；
  - 每种分子类型的观测数量。
- 不同 realization 通常以块状结构分段，便于后续 Matlab 脚本解析。

对多数分析任务，你可以把这个文件看作“原始观测数据”的载体，配合 `matlab\accordImport.m`、`matlab\accordPlotMaker.m` 等脚本进行可视化与统计分析。

### 6.2 汇总文件：`<OUTPUT_NAME>_summary.txt`

汇总文件是一个便于机器读取的 JSON 风格文本，开头由 `initializeOutput` 写入基础信息（`src\file_io.c:2669-2776`）：

- 使用的配置文件名（`"ConfigFile"`）。
- 随机数种子（`"SEED"`）。
- realization 数量（`"NumRepeat"`）。
- 仿真开始时间（`"StartTime"`）。

随后，在仿真结束和清理阶段，`printTextEnd` 会补充：

- 有效的主动/被动 actor 数量；
- 每个 actor 的最大比特数、最大观测次数；
- 总运行时间（`"Simulation ran in ... seconds"` 中的数值也会写入汇总文件，便于后处理）。

该汇总文件可用作：

- 快速查看当前仿真的总体设置与运行时间；
- Matlab 或 Python 后处理脚本的输入，用来批量整理多次仿真结果。

---

## 7. 从编译到拿到结果的完整示例（Windows）

下面以“点扩散示例 + 优化版可执行文件 + 显式种子 1”为例，给出一个完整流程。

1. 打开 `cmd`，进入源码目录：

   ```bat
   cd path\to\AcCoRD-master\src
   ```

2. 构建优化版可执行文件：

   ```bat
   build_accord_opt_win.bat
   ```

   完成后会看到 `bin\accord_win.exe`。

3. 回到仓库根目录并运行仿真（以种子 1 为例）：

   ```bat
   cd ..
   bin\accord_win.exe config\accord_config_sample_point_diffusion.txt 1
   ```

4. 等待控制台打印结束时间与总运行时间，例如：

   ```text
   Ending simulation at 2025-12-18 12:34:56.
   Simulation ran in 0.81 seconds
   Writing simulation summary file ...
   Memory cleanup ...
   ```

5. 在 `results\` 目录下找到输出文件：

   ```text
   results\accord_sample_point_diffusion_SEED1.txt
   results\accord_sample_point_diffusion_SEED1_summary.txt
   ```

6. 使用 Matlab 或其它工具读取这些文件进行绘图与分析：

   - Matlab 用户可参考 `matlab\accordImport.m`、`matlab\accordPlotMakerWrapper.m` 等脚本；
   - 也可以用 Python 自行解析文本，提取时间序列数据做进一步统计。

至此，从 **Windows 编译** 到 **运行仿真**、再到 **定位结果文件并进行后处理** 的完整流程就打通了。你可以根据自己的实验需求替换配置文件、修改随机数种子，或者启用 `ACCORD_USE_SOA_SIMPLE` 环境变量来对比 AoS 与 SoA 简化路径下的性能与结果。 

