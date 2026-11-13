# Plan: benchmarks that can be trusted

Why zui's benchmarks were rebuilt after stage 7, and the research behind
it. The plan's steps, B1 to B8, are now items in `ROADMAP.md`, where
their measurements are recorded:

| Step | Item | What it became |
|---|---|---|
| B1 | R3 | pinned runs, with the machine's state recorded |
| B2 | R4 | bootstrap confidence intervals and a calibrated noise band |
| B3 | R5 | each scenario on its own, in a shuffled order |
| B4 | R6 | hardware counters per phase |
| B5 | R7 | code and memory layout as a random factor |
| B6 | R8 | simulated cache and branch misses in `counts` |
| B7 | R9 | results comparable across operating systems and hardware |
| B8 | R10 | a dedicated benchmark machine, under *Later* |

## Where things stood at `db4ea4d`

| Tool | Measures | Defends against noise by |
|---|---|---|
| `zig build bench` (`bench/bench.zig`) | wall-clock time of 15 scenarios, split into declaration and `endFrame`, plus startup and first frames; 20 warm-up frames, then 400 timed | taking each scenario's fastest frame; `doNotOptimizeAway`; failing on any allocation after `init` |
| `zig build bench-compare` (`bench/compare.zig`) | two commits, each built in its own worktree and run with its own `zig build bench` | throwing away a warm-up run; rounds that alternate which side goes first (ABBA); the median of paired head/base ratios; calling a change only when the middle half of those ratios is more than 2% from no change |
| `zig build counts` (`bench/counts.zig`) | instructions per frame under Callgrind, collected only during the phase | one fixed CPU model (x86-64-v3, no libc), so the counts are the same on every machine; CI fails on more than 2% growth |

What it already got right:
- **Fastest frame as the estimator:** Chen, Revels and Edelman found the
  minimum the most reproducible estimator.
- **Paired ratios with alternation:** the approach Kalibera and Jones
  recommend.
- **An A/A check:** `bench-compare -- HEAD HEAD` gives the noise floor.
- **Gating CI on instruction counts, never on time.**

Where error still got in:
1. **The machine is not controlled.** Nothing sets affinity, priority,
   the power plan or turbo. The reference i9-10900K boosts based on its
   temperature. `ROADMAP.md` already records the symptoms: warm text
   drifting to 101.7 µs on the same instructions, a slow first run after
   each build, and a machine slower than when `a6d8e34` was measured.
2. **Layout bias is seen but not handled.** In T4, warm text ran the very
   same instructions as `c5b0401`, with the same simulated cache and
   branch behaviour, and still measured +7.8%. Aligning one function
   moved another scenario by 2.8%. This is the effect Mytkowicz et al.
   measured: link order and environment size moved results by up to about
   8%. `bench-compare` measures one layout per commit and treats it as
   the truth.
3. **Nothing sits between instructions and nanoseconds.** Instruction
   counts cannot show memory or vectorization changes, which are exactly
   what the data-oriented design audit proposes. Wall-clock time can show
   them, but noisily. Hardware counters fill the gap, and core cycles do
   not depend on clock speed.
4. **The statistics are thin.**
   - With 10 rounds, the "middle half" is roughly the 3rd to 8th of 10
     ratios. It is not a confidence interval.
   - The 2% threshold was calibrated by hand, once.
   - `bench --compare` judges one run against a 10% tolerance.
   - Scenarios always run in the same order.
   - Most scenes repeat identical frames, which trains the branch
     predictor.
   - The Windows clock has 0.1 µs resolution, which is 0.7% of a 15 µs
     declaration.
5. **Results do not say where they came from.** A number in a commit
   message or `ROADMAP.md` does not record the OS, CPU, clock speed or
   power settings it was taken under. That makes measurements from
   different machines impossible to compare or learn from.

## Goals

- A commit compared with itself calls nothing faster or slower, with a
  noise band small enough to see a 1% change in the main scenarios.
- A change whose only effect is code layout is reported as within noise.
- Each result records the machine it came from, so results from Windows,
  Linux and macOS, and from x86-64 and ARM, can be set side by side. Each
  platform's costs can then guide how zui meets that platform's needs.
- Memory and vectorization work is measured by what it changes: cycles
  and misses, not only instructions.
- Every command, test and CI job still finishes within 10 minutes.

Out of scope: changing the budgets in SPEC.md §20.2. After the audit the
owner moved them to benchmarking mode, each scaled by 1.25 (`b09976c`);
stating them in cycles is still to be revisited.

## Sources

- [Google Benchmark: Reducing Variance](https://chromium.googlesource.com/external/github.com/google/benchmark/+/7d8c59a/docs/reducing_variance.md)
- [LLVM: Benchmarking tips](https://llvm.googlesource.com/llvm/+/refs/heads/master/docs/Benchmarking.rst)
- [Mytkowicz et al., Producing Wrong Data Without Doing Anything Obviously Wrong! (ASPLOS 2009)](https://huang.isis.vanderbilt.edu/cs8395/readings/producing-wrong-data.pdf)
- [Curtsinger and Berger, STABILIZER: Statistically Sound Performance Evaluation (ASPLOS 2013)](https://people.cs.umass.edu/~emery/pubs/stabilizer-asplos13.pdf)
- [Chen, Revels and Edelman, Robust benchmarking in noisy environments](https://arxiv.org/pdf/1608.04295)
- [Kalibera and Jones, Rigorous Benchmarking in Reasonable Time](https://kar.kent.ac.uk/id/document/3127886), and [Quantifying Performance Changes with Effect Size Confidence Intervals](https://pdf.arxiv.org/pdf/2007.10899)
- [poop](https://raw.githubusercontent.com/andrewrk/poop/main/README.md), and [its macOS fork](https://codeberg.org/kubkon/poop)
- [CodSpeed: CPU simulation and regression causes](https://codspeed.io/docs/instruments/cpu/regression-causes)
- [Hardware counters under WSL2 and Hyper-V](https://github.com/rr-debugger/rr/issues/2506), and [Microsoft: Hyper-V performance monitoring hardware](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/performance-monitoring-hardware)
