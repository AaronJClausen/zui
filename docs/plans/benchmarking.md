# Plan: benchmarks that can be trusted

A plan to make zui's measurements less noisy and less biased, and to make
them comparable across operating systems and hardware. It is separate
from `ROADMAP.md`: the steps here are numbered B1 to B8 within this plan
only.

Written against `db4ea4d`.

## Picking up from here

B1, B2, B3 and B6 are committed (`3fb9f8e`, `4294abe`, and B6's own
commit). Each step's **Status** line below says what it measured and what
is left. Resume in this order:

1. **B5, slice 1** (`ZUI_BENCH_LAYOUT_SEED`). Ideas from the last
   session: shift the stack with `switch (@as(u6, @truncate(seed)))
   { inline else => |step| ... }` over a `[step * 64]u8` buffer passed
   to `doNotOptimizeAway`, calling the scenarios through
   `@call(.never_inline, ...)`; start each `Context` with `initBuffer`
   at a seed-chosen multiple of 64 bytes inside one allocation of
   `required_bytes + 4096` from the counting allocator; in
   `bench-compare`, pass the seed and (on Linux) a padding variable
   through `std.process.run`'s `environ_map`, copied from
   `init.environ_map`. Advertise a `layout-seed` capability. The B2
   bootstrap already resamples in two stages (`groups`), one group per
   layout.
2. **B5, slice 2 spike:** a module-level `comptime { asm (".text\n.skip
   N"); }` in `bench.zig`, from a `-Dbench-layout-seed` build option,
   should shift every function after it by `N` rounded to 16 bytes,
   since LLVM emits module assembly first. Check it by printing
   `@intFromPtr(&SomeUi.endFrame) & 0xfff` for two seeds.
3. **B4** (`bench/counters.zig`, Linux `perf_event_open`): can now be
   built and verified here, since the reference machine also boots
   bare-metal Linux (`perf_event_paranoid` is 2, enough for user-mode
   counting in its own process).
4. **B7**: extend `Machine` with OS version, CPU vendor, caches, target
   and commit; `--results-dir`; `bench-report`. Windows plus a Linux
   container counts as two operating systems for its *Done when*.
5. **B1's turbo-off check** needs the owner's permission to run
   `powercfg ... PROCTHROTTLEMAX 99` on Windows, or to write 1 to
   `/sys/devices/system/cpu/intel_pstate/no_turbo` on Linux (and to set
   it back).

Working notes:
- `bench-compare` writes its progress to stderr, which `zig build` does
  not keep once the step succeeds; the report says which mode ran.
- Noise bands live in `.zig-cache/bench-compare/noise-floor.json`, keyed
  by `Machine.fingerprint()`; the reference machine has bands from
  `468ffc8` (pinned to logical CPU 19, turbo on).
- Run measurements one at a time and compile nothing while one runs.
- Shell heredocs mangle `\n` in Zig string literals on this machine; edit
  Zig files with the Edit or Write tools.

## Where things stand

| Tool | Measures | Defends against noise by |
|---|---|---|
| `zig build bench` (`bench/bench.zig`) | wall-clock time of 15 scenarios, split into declaration and `endFrame`, plus startup and first frames; 20 warm-up frames, then 400 timed | taking each scenario's fastest frame; `doNotOptimizeAway`; failing on any allocation after `init` |
| `zig build bench-compare` (`bench/compare.zig`) | two commits, each built in its own worktree and run with its own `zig build bench` | throwing away a warm-up run; rounds that alternate which side goes first (ABBA); the median of paired head/base ratios; calling a change only when the middle half of those ratios is more than 2% from no change |
| `zig build counts` (`bench/counts.zig`) | instructions per frame under Callgrind, collected only during the phase | one fixed CPU model (x86-64-v3, no libc), so the counts are the same on every machine; CI fails on more than 2% growth |

What it already gets right:
- **Fastest frame as the estimator:** Chen, Revels and Edelman found the
  minimum the most reproducible estimator.
- **Paired ratios with alternation:** the approach Kalibera and Jones
  recommend.
- **An A/A check:** `bench-compare -- HEAD HEAD` gives the noise floor.
- **Gating CI on instruction counts, never on time.**

Where error still gets in:
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

Out of scope: changing the budgets in SPEC.md §20.2. Stating them in
cycles is to be revisited later.

## The steps

| Step | Covers | Waits for | Needs |
|---|---|---|---|
| B1 | pinned runs, with the machine state recorded | | |
| B2 | confidence intervals and a measured noise floor; `bench --compare` removed | | |
| B3 | shuffled scenario order | B1 | |
| B4 | hardware counters per phase | B1 | Linux on bare metal for most of it |
| B5 | code and memory layout as a random factor | B2 | Linux for the environment padding |
| B6 | simulated cache and branch misses in `counts` | | |
| B7 | measuring across operating systems and hardware | B1, B4 | each platform it covers |
| B8 | a dedicated benchmark machine | B1 to B5 | hardware; a decision |

Suggested order: B1 and B2, then B3, then B5, with B4, B6 and B7 when
there is room. Each step is then measured with the improvements before
it. Each step is one commit, or a few, that leaves every check green.

### B1. Pinned runs, with the machine state recorded

**Where:** `bench/bench.zig`, a new `bench/machine.zig`,
`bench/compare.zig`, `README.md` and SPEC.md §20.3.

1. **Slice 1, `bench`.**
   - `--core <n>` pins the benchmark thread to one core and raises its
     priority: `SetThreadAffinityMask` and `SetPriorityClass` on
     Windows, `sched_setaffinity` and `setpriority` on Linux.
   - `--machine-json <path>` records the machine state:
     - Windows: the power plan, the processor cap (`PROCTHROTTLEMAX`), the
       clock speed (`CallNtPowerInformation`) and the CPU model.
     - Linux: the governor, `intel_pstate/no_turbo` or `cpufreq/boost`,
       the core's sibling from `thread_siblings_list`,
       `randomize_va_space`, and the CPU model.
   - The times JSON stays the same flat map, because `bench-compare`
     still has to read what older commits write.
2. **Slice 2, `bench-compare`.**
   - Build both sides first, without pinning. Then pin itself before the
     measured rounds.
   - Affinity is inherited, so older commits' benchmarks are pinned too.
     On Windows the priority class is not inherited, so only commits from
     B1 on raise their own.
   - Warn when the two sides' machine states differ.
   - `--require-quiet` fails when turbo is on or the governor is not
     `performance`.
3. **`README.md`:** a machine-setup recipe.
   - Windows: the High Performance plan, and
     `powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 99`
     to turn off Turbo Boost.
   - Linux: `cpupower frequency-set -g performance`, `no_turbo`,
     `isolcpus` or `cset shield`, the sibling taken offline, and
     `setarch -R`.

**Done when:** `bench-compare -- HEAD HEAD`, pinned and with turbo off,
has a narrower middle half than the same check unpinned. Both are
recorded in the commit message, and the report shows each side's machine
state.

**Status:** built, with B2. `bench/machine.zig` pins, raises the
priority and reads the machine state on Windows and Linux; `bench-compare`
pins itself to the highest-numbered logical CPU after building, records
the state before every run, and warns when it changes. Measured with turbo
**on** (10 rounds each, `HEAD HEAD` at `468ffc8`): the middle halves
averaged 2.74% wide unpinned and 2.50% pinned (medians 2.5% and 2.1%,
widest 11.5% and 7.9%). Waiting on the same check with turbo off
(`PROCTHROTTLEMAX 99`), which changes this machine's power plan. Windows
reports the base clock (3696 MHz) as the current one, so the clock
reading cannot show boosting there.

### B2. Confidence intervals and a measured noise floor

**Where:** `bench/compare.zig`, `bench/bench.zig`, `README.md` and
SPEC.md §20.3.

1. **Slice 1.**
   - Replace the middle half with a bootstrap 95% confidence interval of
     the median ratio: a fixed seed and 10,000 resamples. Once B5 lands,
     resample layouts first and then rounds within them.
   - Call a change only when the whole interval lies outside the noise
     band.
2. **Slice 2.**
   - `bench-compare --calibrate` runs a commit against itself and saves
     each scenario's noise band, keyed by a fingerprint of the machine
     from B1, to `.zig-cache/bench-compare/noise-floor.json`.
   - Ordinary runs read that file, and fall back to 2% without it.
   - Sequential rounds: keep going until the interval is narrower than a
     target, or the time budget is spent.
3. **Slice 3.**
   - `bench` reports p95 next to the minimum and the median.
   - `bench` warns when a scenario's times look like two clusters: a gap
     in the sorted samples much larger than the spread around it.
   - **Remove `bench --compare`** in favour of `bench-compare`. `--json`
     stays, because `bench-compare` reads it.

**Done when:** a commit compared with itself reports intervals that all
contain zero, and the store-forwarding stall R2 found (`946405e~1` to
`946405e`) is still called faster.

**Status:** done, with one exception. `bench/statistics.zig` holds the
bootstrap (two-stage, ready for B5's layouts) and the cluster test, with
tests run by `zig build test`. `--calibrate` against `468ffc8` (61
sequential rounds, turbo on, pinned) called nothing, and saved bands of
0.5% (the floor) to 0.9%; 29 of 30 intervals contain zero, and warm
text's layout lay at −0.4% to −0.1%, inside its band but not around zero.
`946405e~1` to `946405e` (100 rounds, the cap) is still called faster:
box tree declaration −27.4% (−27.5% to −27.4%), warm and cold text
declarations −7.0%, depth 64's declaration −20%. Sequential rounds rarely
stop early on Windows: the 0.1 µs clock keeps the small scenes' intervals
in whole steps, so most runs end at the time budget or the cap.

### B3. Shuffled scenario order

**Where:** `bench/bench.zig`, `bench/compare.zig`.

- `bench` gains:
  - `--list-scenarios`;
  - `--scenario <name>`, which can be repeated;
  - `--order-seed <n>`, which shuffles the scenario order.
- `bench-compare` checks whether each side supports these: an older side
  exits with `UnknownArgument`. When both do, each round uses a new seed
  and alternates base and head per scenario. Otherwise it keeps the
  whole-run alternation.
- Startup scenarios stay last, because their page-fault timing depends on
  memory the process has never touched.

**Done when:** a commit compared with itself calls nothing faster or
slower, and the README says that full benefit needs a base from B3 on.

**Status:** done (`4294abe`). Each side's benchmark is installed with
`zig build bench-install`; `bench --list-scenarios` prints
`name<TAB>compared|reported|startup`. `bench-compare -- HEAD HEAD` at
`4294abe`, one scenario at a time (100 rounds, the cap; turbo on,
pinned, against the bands from `468ffc8`) called nothing. Four intervals
do not contain zero but lie inside their bands: static-styled boxes
−1.4% to −0.1%, new strings −0.2% to −0.1%, first frame of 1000 texts
+0.1% to +0.3%, warm text +0.0% to +0.1%. One small flaw left: the
report lists times in the first round's shuffled order, not the
scenario table's.

### B4. Hardware counters per phase

**Where:** a new `bench/counters.zig`, `bench/bench.zig`,
`bench/compare.zig`, SPEC.md §20.3 and `ARCHITECTURE.md` §6 (a
"hardware counters" row).

1. **Slice 1, Linux, through `read`.**
   - `--counters` opens one `perf_event_open` group, user mode only:
     cycles, instructions, branch misses, L1D read misses and last-level
     cache misses.
   - The group is switched on and off around each phase, as `counts`
     toggles Callgrind.
   - A run is refused if the kernel had to share the counters
     (`time_running < time_enabled`). Cycles and instructions are fixed
     counters on Intel, which leaves the three others for the
     programmable ones.
   - The numbers are written as new keys in the same JSON (for example
     `"box tree, cycles"`), so a base without them shows as "only in
     head".
   - On a platform without support, `--counters` stops with an error that
     names the alternatives for that platform.
2. **Slice 2, through `rdpmc`.** Read the counters through the mmap page,
   so each frame gets its own minimum without about a microsecond of
   overhead around a 15 µs phase.
3. **Slice 3.** `bench-compare --metric cycles|instructions|ns`, with
   nanoseconds the default.

The counters need bare-metal Linux: WSL2, Docker on Windows and GitHub's
hosted runners do not expose them. Slice 1 can be written and
type-checked on Windows (`zig build check -Dtarget=x86_64-linux`), but it
can only be verified once a Linux install exists.

**Done when:** on bare-metal Linux, a commit compared with itself on
cycles has a noise band well under its band in nanoseconds, with both
recorded.

### B5. Code and memory layout as a random factor

**Where:** `bench/bench.zig`, `bench/compare.zig`, `build.zig`.

1. **Slice 1, stack and heap.**
   - `bench` reads a `ZUI_BENCH_LAYOUT_SEED` environment variable.
   - From the seed, it shifts the stack by 0 to 4 KiB, through a runtime
     switch over fixed-size stack buffers.
   - It also starts each `Context` at a seed-chosen multiple of 64 bytes
     inside an `initBuffer` buffer.
   - On Linux, `bench-compare` also pads the environment to a random
     length, which shifts the initial stack the way Mytkowicz measured.
     This works for older commits too. On Windows the environment is not
     on the stack, so the padding does nothing there.
2. **Slice 2, code layout: a spike first.**
   - Try a `-Dbench-layout-seed` build option that inserts a padding
     function, or varies the alignment of the hot functions.
   - Confirm with `nm` or a map file that the hot functions really move
     between seeds.
   - If Zig gives no reliable control over where code goes, ship slice 1
     alone and record why here.
3. **Slice 3.**
   - `bench-compare --layouts <k>` builds every variant in parallel
     before any measurement.
   - It reports the change across layouts and rounds, using B2's
     resampling.

**Time limit:** `bench-compare` already runs about 2 × (rounds + 1)
benchmarks after 2 builds, and K layouts multiply the builds. The
defaults (perhaps 3 layouts × 6 rounds) are chosen by timing them, and
the tool stops at a time budget, so a comparison stays within 10 minutes.

**Done when:** the T4 case, warm text at `c5b0401` (+7.8% on the same
instructions), is reported as within noise.

### B6. Simulated cache and branch misses in `counts`

**Where:** `bench/counts.zig`, `.github/workflows/ci.yml`.

- Run Callgrind with `--cache-sim=yes --branch-sim=yes`.
- Fix the cache geometry with `--I1`, `--D1` and `--LL`. Otherwise
  Valgrind uses the host's caches, and the counts would differ between
  machines.
- Parse Callgrind's `Events` line together with its `Collected` line.
- The instruction keys stay exactly as they are, so CI gating does not
  change. The misses go in new keys, and are informational only: the
  model is simple, so they show direction, not cost.

**Done when:** two CI runs give identical miss counts, and the job still
finishes within 10 minutes. It has to be timed, because the simulation
slows Callgrind down.

**Status:** done. Callgrind runs with `--cache-sim=yes --branch-sim=yes`
and a fixed 32 KiB 8-way I1 and D1 and an 8 MiB 16-way LL (`-v` confirms
Valgrind uses them, despite its warning that it found the host's L3).
Each `"<scene>, <phase>"` instruction key gets four informational keys:
`I1 misses`, `D1 misses`, `LL misses` and `branch misses`. Callgrind
leaves trailing zeros off its `Collected` line, so missing values read as
zero. Measured on bare-metal Linux (i9-10900K, Valgrind 3.25.1): two runs
wrote byte-identical JSON; a run takes about 8 s once built. Against
`main` without the simulation, every instruction count moved by 7 to 13
per frame (at most −0.06%), well inside the 2% gate. Two CI runs have
yet to be compared.

### B7. Measuring across operating systems and hardware

The aim is insight, not a single number: to see how each platform's
costs differ, and so how zui can meet each platform's needs.

**Where:** `bench/bench.zig`, `bench/machine.zig`, `bench/counters.zig`,
a new `bench/report.zig`, `build.zig` and `README.md`.

1. **Slice 1, a machine fingerprint in every result.**
   - `--machine-json` (B1) also records the OS and version, the CPU
     vendor, model and core count, the cache sizes, the Zig target triple
     and the CPU model it was built for, and the commit.
   - `bench --results-dir <dir>` writes the times and the machine state
     together, as `<dir>/<machine fingerprint>/<commit>.json`.
2. **Slice 2, counters on more platforms.**
   - Linux on x86-64 and on ARM, through `perf_event_open` (B4).
   - macOS on Apple silicon, through `kperf` and `kperfdata`, as the macOS
     fork of `poop` does. It needs `sudo`.
   - Windows: no public user-mode API for counters. Record the time and
     the clock speed. For deeper looks, document a recipe for Windows
     Performance Recorder with counter sources (`wpr -pmcsources`), VTune
     or uProf.
3. **Slice 3, `zig build bench-report -- <dir>`.**
   - Sets each machine's results side by side for one commit.
   - Normalizes each machine's results to its own box tree, so the
     comparison is about each scenario's relative cost, not about which
     CPU is faster.
   - Flags scenarios whose relative cost differs most between platforms,
     for example the tooltip-first grid's layer sort, or the
     cold-text-in-parallel scaling across core counts.
4. **Slice 4, cross-built benchmarks.**
   - `zig build bench -Dtarget=<triple>` already builds for another
     target. Document running the cross-built executable on another
     machine and copying its results directory back.

**Done when:** one commit's results from at least two operating systems,
or two CPU architectures, appear side by side in `bench-report`.

### B8. A dedicated benchmark machine

Wall-clock times could gate CI only on a self-hosted, bare-metal runner
set up as B1 describes, as CodSpeed also concludes. Until then, CI keeps
today's policy: it reports times and gates on instruction counts. This is
an open decision, to be taken once hardware is available.

## Documents to update along the way

- **SPEC.md §20.3:** each new option, and the removal of
  `bench --compare`. The budgets in §20.2 do not change.
- **README.md:** the *Development* table, and the machine-setup recipe.
- **ARCHITECTURE.md §6:** a hardware counters row (B4).
- **This plan:** a **Status** line on each step as it lands, with what
  it measured.

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
