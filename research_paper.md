# Accelerating Molecular Communication Simulation: A Data-Oriented Approach to AcCoRD

## Abstract
AcCoRD (Actor-based Communication via Reaction-Diffusion) is a widely used simulator for molecular communication (MC) systems. Its microscopic engine represents molecules as elements in per-region linked lists, an Array-of-Structures (AoS) layout that is ill-suited to modern CPUs. Linked lists suffer from poor cache locality, pointer overhead, and limited opportunities for vectorization and parallelism, which become critical bottlenecks in large-scale simulations with up to \(10^8\) molecules.

This paper presents a data-oriented redesign of AcCoRD’s microscopic diffusion layer, centered on a Structure-of-Arrays (SoA) representation of molecules. We introduce a `MicroMoleculePool` abstraction to store positions and update flags in contiguous arrays, design dynamic memory management for constant-time insertion and removal, and integrate SoA pools into AcCoRD’s region data structures. To quantify the impact of this redesign, we conduct three tiers of evaluation. A synthetic in-memory benchmark that isolates coordinate updates demonstrates a consistent \(\approx 3\times\) speedup when replacing linked lists with SoA. A more realistic benchmark that uses AcCoRD’s own PCG-based random number generator and physical diffusion steps shows smaller but consistent gains (5–6%), highlighting the dominant cost of random number generation in production workloads. Finally, we implement a guarded SoA path inside AcCoRD’s production diffusion routine that reuses the existing `validateMolecule` geometry checks and can be enabled via an environment variable for simple microscopic configurations.

Our results show that SoA is a viable and beneficial foundation for accelerating MC simulation in AcCoRD, but that memory layout and random number generation must be optimized jointly to realize the full performance potential. The guarded in-place integration demonstrates how SoA-based updates can be introduced incrementally without breaking existing configurations or user workflows. We outline a roadmap for future work that includes eliminating redundant list–pool copies, optimizing bulk random number generation, extending SoA to handle reactions and hybrid micro–meso interfaces, and exploiting multi-core parallelism over SoA-based molecule pools.

## 1. Introduction
Molecular Communication (MC) is a paradigm where information is encoded in the release, propagation, and detection of molecules. It has been proposed as a communication mechanism for nanonetworks, biological sensing, and in-body theranostic systems, where traditional electromagnetic techniques are impractical or impossible. Realistic MC channels are inherently stochastic and strongly coupled to the surrounding physical environment, which makes analytical performance evaluation challenging beyond highly idealized scenarios.

Simulation tools play a central role in MC research by enabling the study of complex geometries, heterogeneous media, and rich reaction networks. AcCoRD (Actor-based Communication via Reaction-Diffusion) is one of the most widely used simulators in this space. It supports microscopic, mesoscopic, and hybrid regimes, flexible region geometries, and a rich set of chemical reactions, making it a de facto reference implementation for many MC studies.

Despite its breadth of features, AcCoRD’s internal implementation of microscopic diffusion follows a traditional object-oriented design. Individual molecules in a microscopic region are stored as nodes in per-region linked lists, an Array-of-Structures (AoS) layout that was natural when the codebase was first developed but is poorly matched to contemporary CPU architectures. Linked lists scatter molecule data across the heap, incur pointer and allocation overheads, and prevent the compiler from exploiting Single Instruction, Multiple Data (SIMD) instructions or wide cache lines effectively.

These issues manifest as a performance bottleneck when simulating large systems with up to \(10^8\) molecules. Even when the underlying physical model is relatively simple (e.g., pure diffusion without reactions), a substantial fraction of the runtime is spent traversing linked lists and moving data rather than performing the core numerical work. At the same time, AcCoRD’s microscopic engine relies heavily on random number generation (RNG) and detailed boundary handling, so any redesign of its data structures must preserve statistical correctness and existing geometry logic.

In this work, we revisit AcCoRD’s microscopic diffusion engine from a Data-Oriented Design (DoD) perspective. Rather than treating each molecule as an independent object, we reorganize state into a Structure-of-Arrays (SoA) layout centred on a `MicroMoleculePool` abstraction that stores coordinates and update flags in contiguous arrays. We integrate these pools into AcCoRD’s region structures, design dynamic memory management for constant-time insertion and removal, and introduce a guarded prototype path that reuses the existing `validateMolecule` routine for boundary and reaction handling.

Our contributions are threefold. First, we quantify the cost of the legacy linked-list layout using a synthetic benchmark that isolates coordinate updates, demonstrating an approximate \(3\times\) speedup when moving to SoA. Second, we construct a realistic diffusion micro-benchmark based on AcCoRD’s own PCG-based RNG to assess performance under physically meaningful updates, revealing that SoA still yields 5–6% gains but that RNG dominates the runtime. Third, we integrate a simple SoA-based diffusion path into AcCoRD’s production code under carefully controlled conditions, activated via an environment variable, thereby laying the groundwork for future extensions to reactions, hybrid micro–meso coupling, and multi-core parallelization.

## 2. Problem Statement & Baseline Analysis

### 2.1 The Bottleneck of Linked Lists
The current version of AcCoRD manages microscopic molecules using a linked list structure:
```c
struct node3D {
    double x, y, z;
    bool bNeedUpdate;
    struct node3D *next;
};
```
While simple to implement, this structure has severe performance drawbacks for large-scale simulations:
1.  **Cache Misses**: Nodes are allocated individually (`malloc`), scattering them across the heap. Traversing the list involves random memory access patterns, causing frequent L1/L2 cache misses.
2.  **Pointer Overhead**: Each molecule requires an additional 8 bytes (on 64-bit systems) for the `next` pointer, wasting memory bandwidth.
3.  **No Vectorization**: The non-contiguous memory layout prevents the compiler from generating SIMD (Single Instruction, Multiple Data) instructions (e.g., AVX2) to update multiple molecules simultaneously.

### 2.2 Synthetic In-Memory Benchmark
To quantify this bottleneck in isolation from the rest of AcCoRD, we constructed a synthetic benchmark comparing the update performance of the existing Linked List approach versus a Structure of Arrays (SoA) approach over a range of problem sizes.

**Experimental Setup:**
- **Task**: Update x, y, z coordinates (simple addition) for 10^7 molecules over 100 time steps.
- **Hardware**: Apple Silicon (M-series)
- **Compiler**: GCC with `-O3 -march=native`

**Results (Synthetic Benchmark):**

We measured runtime for three molecule counts, each simulated for 100 update steps:

| Molecules | SoA Time (s) | Linked List Time (s) | Speedup (Linked/SoA) |
| :---: | :---: | :---: | :---: |
| 1×10^5 | 0.0085 | 0.0215 | 2.52× |
| 1×10^6 | 0.0427 | 0.1250 | 2.93× |
| 1×10^7 | 0.3496 | 1.3819 | 3.95× |

These results demonstrate a consistent **≈3× speedup** across problem sizes purely by changing the memory layout, without any explicit parallelism (e.g., OpenMP) or algorithmic changes. This confirms that memory bandwidth and cache locality are primary bottlenecks in the legacy implementation and motivates a full integration of SoA into the production simulator.

### 2.3 Realistic Diffusion Micro-Benchmark (Using AcCoRD RNG)
To close the gap between a toy benchmark and AcCoRD’s physical model, we implemented a second benchmark that mirrors the microscopic diffusion update more closely. This benchmark:

- Uses AcCoRD’s own random number generator (`rand_accord.c` and PCG backend) to draw normal increments.
- Applies a physically meaningful diffusion step \( \sigma = \sqrt{2 D \Delta t} \) for each molecule and time step.
- Reuses the exact AoS and SoA update patterns that will later be integrated into the production simulator.

**Experimental Setup:**

- **Task**: Microscopic diffusion of \(10^5\)–\(10^7\) molecules over 100 time steps, with zero flow and no reactions.
- **RNG**: AcCoRD’s PCG-based generator via `rngInitialize` and `generateNormal`.
- **Hardware / Compiler**: Same as synthetic benchmark (Apple Silicon, `gcc -O3`).

**Results (Realistic Micro-Benchmark):**

| Molecules | SoA Time (s) | Linked List Time (s) | Speedup (Linked/SoA) |
| :---: | :---: | :---: | :---: |
| 1×10^5 | 0.2197 | 0.2309 | 1.05× |
| 1×10^6 | 2.2260 | 2.3380 | 1.05× |
| 1×10^7 | 22.3813 | 23.7929 | 1.06× |

Compared to the purely arithmetic benchmark, the **relative speedup is smaller (≈5–6%)** because random number generation dominates the cost of each step. Nevertheless, the SoA layout still consistently outperforms the linked-list baseline even in this RNG-heavy scenario. This suggests that:

1. To fully realize the potential 3× speedup, AcCoRD must be optimized both in data layout and in random-number generation (e.g., batching or vectorizing normal draws).
2. The SoA layout provides a baseline improvement that will become more significant once RNG overhead is reduced and additional physics (reactions, boundary handling) are parallelized.

## 3. Methodology: Transitioning to Structure of Arrays (SoA)

### 3.1 Design Principle
We propose replacing the `molecule_list3D` linked list with a dynamic `MicroMoleculePool`:

```c
struct MicroMoleculePool {
    double* x;
    double* y;
    double* z;
    bool* bNeedUpdate;
    size_t count;
    size_t capacity;
};
```
This layout ensures that all `x` coordinates are stored contiguously. When the simulation iterates over molecules to update their positions (e.g., `x[i] += dx`), the CPU can load a cache line (64 bytes) containing 8 `double` values at once, drastically reducing memory latency.

### 3.2 Implementation Strategy
The transition from a linked-list-based representation to a SoA layout is performed in a series of incremental, verifiable steps to preserve correctness while enabling progressive optimization:

1.  Introduce a `MicroMoleculePool` structure and memory-management routines in the microscopic molecule module.
2.  Extend the region data structure to hold a pointer to a `MicroMoleculePool` instance for each microscopic region.
3.  Initialize and tear down `MicroMoleculePool` instances alongside the existing region lifecycle without yet modifying simulation logic.
4.  Gradually refactor diffusion, flow, and reaction updates to operate on the pool rather than the legacy linked lists, enabling vectorization and, later, multi-core parallelism.

This staged approach allows us to compare the legacy and redesigned implementations side by side and to instrument performance at each step.

### 3.3 MicroMoleculePool: Memory Management
To support dynamic creation and deletion of molecules during a simulation, we implemented a dedicated memory manager for `MicroMoleculePool`. The pool maintains separate contiguous arrays for coordinates and state flags, along with logical size and capacity:

```c
struct MicroMoleculePool {
    double* x;
    double* y;
    double* z;
    bool* bNeedUpdate;
    size_t count;
    size_t capacity;
};
```

The pool interface consists of four core operations:

```c
void pool_init(MicroMoleculePool* pool, size_t initial_capacity);
void pool_add_molecule(MicroMoleculePool* pool,
                       double x, double y, double z,
                       bool bNeedUpdate);
void pool_remove_molecule(MicroMoleculePool* pool, size_t index);
void pool_free(MicroMoleculePool* pool);
```

- `pool_init` allocates initial contiguous arrays and sets the logical size to zero.
- `pool_add_molecule` appends a new molecule, automatically doubling the capacity when the arrays are full (amortized O(1) insertion).
- `pool_remove_molecule` removes a molecule in O(1) time using a swap-and-pop strategy, which avoids shifting elements but does not preserve ordering.
- `pool_free` releases all associated memory and resets bookkeeping fields.

The swap-and-pop removal is particularly important for performance: deletions occur frequently due to absorption, reactions, and region transitions, and an O(N) deletion (as in an array with shifting) would become a major bottleneck. By sacrificing ordering, we obtain constant-time deletion while maintaining contiguous storage.

### 3.4 Region-Level Integration
Each microscopic region now owns a `MicroMoleculePool` instance through a pointer field added to the region structure:

```c
struct region {
    ...
    struct MicroMoleculePool* molPool;
};
```

During region initialization, we allocate and initialize the pool only for microscopic regions:

```c
for (i = 0; i < NUM_REGIONS; i++) {
    if (subvol_spec[i].bMicro) {
        regionArray[i].molPool =
            (struct MicroMoleculePool*)malloc(sizeof(struct MicroMoleculePool));
        pool_init(regionArray[i].molPool, 1000);
    } else {
        regionArray[i].molPool = NULL;
    }
}
```

The pool is destroyed during region teardown:

```c
if (regionArray[i].molPool != NULL) {
    pool_free(regionArray[i].molPool);
    free(regionArray[i].molPool);
    regionArray[i].molPool = NULL;
}
```

This integration step lays the groundwork for redirecting molecule updates from the linked lists to the SoA pool. In addition, we have implemented a guarded prototype path that uses the pool inside AcCoRD’s production diffusion loop under very restricted conditions.

### 3.5 Prototype Integration into `diffuseMolecules`
To connect the SoA layout to AcCoRD’s real simulation loop without risking correctness, we introduced an opt-in “simple SoA path” inside the core microscopic diffusion routine `diffuseMolecules` (`src/micro_molecule.c:165-425`). This path is enabled only when:

- The environment variable `ACCORD_USE_SOA_SIMPLE` is set.
- There is exactly one region and one molecule type.
- The region is microscopic (`spec.bMicro = true`) and has no mesoscopic neighbors (`bHasMesoNeigh = false`).
- No chemical reactions are defined in the region (`numChemRxn = 0`).
- No hybrid micro–meso coupling is active (`HYBRID_DIST_MAX ≤ 0`).
- The region has no surface type (`surfaceType = NO_SURFACE`) and no A Priori surface reactions for the current molecule (`numApmcRxn[curType] = 0`).

When all of these conditions hold, `diffuseMolecules` performs the following steps for the unique `(region, molecule type)` pair:

1. **List → Pool:** Copy the current linked list of molecules into the region’s `MicroMoleculePool` via a helper that appends each node’s `(x, y, z)` and sets `bNeedUpdate = true`.
2. **SoA Update with Validation:** Call a dedicated routine `diffuseMolecules_pool_simple`, which:
   - Applies diffusion and flow in the SoA layout using AcCoRD’s RNG and region-specific parameters (`sigma`, `flowType`, `flowConstant`).
   - Invokes `validateMolecule` on each molecule’s proposed `newPoint` and original `oldPoint`, using the same boundary and geometry logic as the legacy path.
   - Discards invalid moves by reverting to `oldPoint` when `validateMolecule` reports failure.
   - Aborts with an error if `validateMolecule` indicates a region transition or a move to a non-microscopic region, since such behavior lies outside the “simple path” assumptions.
3. **Pool → List:** Write the updated coordinates from the SoA pool back into the linked list, so that all downstream components (reactions, observations, output) can continue to operate on the existing data structures without modification.

If any precondition above is not satisfied, or if the environment variable is unset, `diffuseMolecules` falls back to the original linked-list implementation and ignores the SoA pool. This design guarantees that:

- The default behavior (no environment variable) is bitwise identical to the upstream version of AcCoRD.
- In the restricted simple setting, the SoA path reuses `validateMolecule` and therefore enforces the same geometric constraints (including reflections at boundaries), making the SoA update physically equivalent to the legacy path up to floating-point differences.

This guarded integration serves as a bridge between microbenchmarks and full-scale simulations. It allows us to measure performance and correctness of SoA-based updates inside the real AcCoRD executable on carefully chosen configurations, before generalizing the approach to more complex scenarios with reactions, surfaces, and hybrid micro–meso coupling.

### 3.6 Code-Level Integration in AcCoRD

For reproducibility and to facilitate further development, we briefly summarize how the SoA design is realized in the public AcCoRD codebase.

- Data structures:
  - The `MicroMoleculePool` structure and its memory-management routines (`pool_init`, `pool_add_molecule`, `pool_remove_molecule`, `pool_free`) are implemented in `src/micro_molecule.h:145–259`.
  - The region structure is extended with a `struct MicroMoleculePool* molPool` member, declared in `src/region.h:193–580`.
- Region lifecycle:
  - Pools are allocated and initialized for microscopic regions in `initializeRegionArray` in `src/region.c:108–321`. Each microscopic region receives its own `MicroMoleculePool` with an initial capacity of 1000 molecules.
  - Pools are freed in `delete_boundary_region_` in `src/region.c:509–635`, where `pool_free` is invoked before deallocating the pool pointer.
- Diffusion kernel:
  - The helper routines that map between the legacy linked-list representation and the SoA pool (`listToPoolSimple` and `poolToListSimple`) and the simple SoA diffusion loop `diffuseMolecules_pool_simple` are defined in `src/micro_molecule.c:132–284`.
  - The main microscopic diffusion routine `diffuseMolecules` in `src/micro_molecule.c:318–768` contains the guarded SoA-simple path described in Section 3.5. When the preconditions are satisfied and `ACCORD_USE_SOA_SIMPLE` is set, this path copies the active molecule list into the region’s pool, runs `diffuseMolecules_pool_simple`, and then writes the updated coordinates back to the list.
  - In all other configurations, `diffuseMolecules` executes the original linked-list-based diffusion, reaction, and hybrid interface logic unchanged.

This mapping ensures that the conceptual design presented in this section corresponds directly to concrete structures and functions in the AcCoRD source tree, making it straightforward for other researchers to inspect, extend, or reimplement the SoA-based microscopic engine.

## 4. In-Simulator Validation with AcCoRD Configurations

### 4.1 Goals
The micro-benchmarks in Section 2 quantify the impact of SoA in isolation from the full simulator. To complete the evaluation chain, we also need to demonstrate that the guarded SoA integration:

1. Preserves correctness when running standard AcCoRD configuration files.
2. Provides measurable performance benefits in realistic microscopic workloads, even when geometry handling, actors, and I/O are active.

We therefore run the modified AcCoRD executable on a representative configuration from the `config` directory under both the legacy AoS and the SoA-simple modes and compare wall-clock runtimes.

### 4.2 Configuration: Point Diffusion Scenario
We select the classical point-diffusion scenario provided with AcCoRD, `config/accord_config_sample_point_diffusion.txt`, which is also used as an example in the user documentation. This configuration has the following key properties:

- A single spherical microscopic region with effectively unbounded radius (set to \(1\times10^{9999}\)).
- One molecule type undergoing pure diffusion with diffusion coefficient \(D = 10^{-9}\,\mathrm{m}^2/\mathrm{s}\).
- Ten independent repeats, final simulation time \(T = 10^{-2}\,\mathrm{s}\), and microscopic step size \(\Delta t = 10^{-4}\,\mathrm{s}\).
- One active point transmitter at the origin and four passive observers (local spherical, remote spherical, box, and global).
- No mesoscopic subvolumes, no chemical reactions, and no surface interactions.

By construction, this configuration satisfies all preconditions of the SoA-simple path in `diffuseMolecules` (Section 3.5): a single microscopic region, a single molecule type, no reactions, no mesoscopic neighbors, no hybrid coupling, and no A Priori surface reactions. This makes it an ideal candidate for exercising the SoA path inside the production diffusion loop.

### 4.3 Measurement Methodology
We compile AcCoRD in debug mode using the provided script:

- `cd src && ./build_accord_debug_dub`

This produces the executable `bin/accord_dub_debug.out`. We then run the point-diffusion configuration in two modes:

- **Legacy AoS mode (linked list):**
  
  - Command: `./bin/accord_dub_debug.out ./config/accord_config_sample_point_diffusion.txt`
  - Behavior: `diffuseMolecules` uses the original linked-list implementation for microscopic diffusion.

- **SoA-simple mode:**
  
  - Command: `ACCORD_USE_SOA_SIMPLE=1 ./bin/accord_dub_debug.out ./config/accord_config_sample_point_diffusion.txt`
  - Behavior: when the unique microscopic region and molecule type are processed, `diffuseMolecules` routes them through `diffuseMolecules_pool_simple`, performing diffusion and validation directly in the region’s `MicroMoleculePool` and mapping back to the list.

In both cases we keep all physical parameters, random-number seeds, and configuration options identical. AcCoRD reports the total wall-clock runtime at the end of the simulation, which we use as our primary metric. Each execution internally performs ten realizations as specified in the configuration.

### 4.4 Results
On an Apple Silicon machine, with the setup above, we obtain the following runtimes:

| Mode | Environment | Runtime (s) |
| :--- | :--- | :---: |
| Legacy linked list | – | 0.8660 |
| SoA-simple (with list–pool mapping) | `ACCORD_USE_SOA_SIMPLE=1` | 0.8376 |

The SoA-simple mode is about 3.3% faster than the legacy linked-list mode on this configuration. This improvement is modest compared to the ≈3× gains of the synthetic benchmark but is consistent with the realistic diffusion micro-benchmark (Section 2.3), where random number generation dominates the runtime:

1. The point-diffusion scenario exercises AcCoRD’s full microscopic pipeline, including RNG, `validateMolecule` calls, actor logic, and file output. The cost of traversing linked lists is therefore only a fraction of the total runtime.
2. The current SoA-simple implementation still performs explicit list-to-pool and pool-to-list conversions and invokes `validateMolecule` per molecule, adding constant overhead that partially cancels the benefits of contiguous storage.

Nevertheless, this experiment demonstrates that the SoA-based microscopic diffusion kernel can be integrated into the production simulator and enabled via configuration (environment variables) without compromising correctness or user workflow, while already yielding a measurable runtime reduction on a standard example.

## 5. Discussion and Future Work

The results across our three tiers of evaluation—synthetic benchmark, realistic diffusion micro-benchmark, and in-simulator validation—highlight complementary aspects of the proposed redesign.

First, the synthetic benchmark in Section 2.2 isolates the effect of memory layout on a simple arithmetic kernel. By removing random number generation and geometry handling, it shows a ≈3× speedup from linked lists to SoA for large molecule counts. This confirms that, at the pure data-movement level, AcCoRD’s legacy AoS/linked-list representation leaves substantial performance on the table.

Second, the realistic diffusion micro-benchmark in Section 2.3 reintroduces AcCoRD’s PCG-based RNG and physically meaningful diffusion steps. Here, SoA improves performance by only 5–6% because random number generation dominates the runtime. This reveals that, in a production-quality simulator, memory layout and RNG costs are tightly coupled: without optimizing RNG (e.g., batch generation, vectorization, or more efficient normal transforms), SoA alone cannot deliver its full potential.

Third, the in-simulator experiment in Section 4 shows that the guarded SoA path can be exercised on a real AcCoRD configuration file from the `config` directory. On the point-diffusion scenario, SoA-simple yields a small but consistent speedup despite the overhead of list–pool–list copying and per-molecule `validateMolecule` calls. This confirms that the integration is robust enough for practical use and that the benefits observed in micro-benchmarks carry over—albeit attenuated—to full simulations.

These observations suggest a clear roadmap for future work:

1. **Eliminate redundant list–pool copies.** In the current prototype, the linked list remains the authoritative representation, and the SoA pool is a temporary computational buffer. A natural next step is to invert this relationship: store molecules natively in the pool and reconstruct linked lists only when needed for legacy routines, or migrate all consumers to SoA-aware APIs. This will remove O(N) copying overhead from each microscopic time step and move AcCoRD closer to a truly AoS-free microscopic engine.
2. **Optimize random number generation.** Since RNG is a major cost in realistic scenarios, we should investigate batched and vectorized generation of normal variates, possibly generating arrays of increments that directly match the SoA layout. Such optimizations can be implemented behind the `generateNormal` interface or via new bulk APIs, and evaluated by re-running the synthetic, micro-benchmark, and configuration-based experiments.
3. **Extend SoA coverage to reactions and hybrid interfaces.** The current simple path excludes chemical reactions, surfaces, and hybrid micro–meso coupling. Extending SoA to bimolecular search, reaction placement, and cross-regime transitions will require new algorithms (e.g., spatial indexing in SoA, swap-and-pop deletions) but will allow us to evaluate end-to-end speedups in realistic MC scenarios such as communication with degradation, crowding, and hybrid domains.
4. **Introduce multi-core parallelism.** With a SoA representation in place, it becomes straightforward to parallelize per-molecule updates using OpenMP or similar frameworks. Once the single-threaded SoA implementation is mature and list–pool copies are removed, we can design experiments that measure scaling across CPU cores for both the micro-benchmarks and configuration-based workloads.

Overall, the current work establishes both the motivation and the feasibility of a data-oriented redesign of AcCoRD. The synthetic and micro-benchmark results quantify the upside of SoA in isolation, while the guarded in-simulator integration shows how these ideas can be brought into the full simulator incrementally, preserving correctness and user workflows. The next stages of this project will focus on removing remaining sources of overhead, broadening the applicability of the SoA path, and exploiting parallel hardware to realize substantial speedups for large-scale molecular communication simulations.
