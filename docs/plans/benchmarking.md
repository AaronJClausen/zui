# Plan: benchmarks that can be trusted

A plan to make zui's measurements less noisy and less biased, and to make
them comparable across operating systems and hardware. It is separate
from `ROADMAP.md`: the steps here are numbered B1 to B8 within this plan
only.

Written against `db4ea4d`.

## Picking up from here

B1, B2, B3, B5 and B6 are done; B4 and B7 are built and wait on a
measurement each. The
reference machine now boots bare-metal Linux with turbo off and the
`performance` governor; its noise bands are calibrated for that setup.
Each step's **Status** line below says what it measured and what is
left. Resume in this order:

1. **B7's *Done when***: boot Windows on the reference machine, run
   `zig build bench -- --core 19 --results-dir <dir>` at the same commit
   there and here, into one directory both installs can reach, and run
   `zig build bench-report -- <dir>`.
2. **B4's *Done when*** needs the cycles band compared with the time band
   while the clock moves: with turbo off the two measure the same thing.
   Ask the owner before turning turbo back on
   (`/sys/devices/system/cpu/intel_pstate/no_turbo`), then run
   `bench-compare -- --calibrate` and `-- --calibrate --metric cycles`
   and compare the saved bands.
3. **Optional:** B4 slice 2 (`rdpmc`, see B4's status); B7 slice 2's
   macOS counters through kperf; B8 is a decision for when hardware
   exists.

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
widest 11.5% and 7.9%). Windows reports the base clock (3696 MHz) as
the current one, so the clock reading cannot show boosting there.

Done with turbo **off**, on the same i9-10900K booted into bare-metal
Linux (`intel_pstate/no_turbo` 1, `performance` governor on every core,
SMT on, no isolated cores, `randomize_va_space` 2). `HEAD HEAD` at
`f099fd1`, 10 rounds each: the 95% intervals averaged 1.74% wide pinned
to logical CPU 19 with `--require-quiet` (median 0.80%, widest 7.3%), and
10.65% with `--no-pin` (median 5.25%, widest 78.7%). Neither called a
change. Pinned, the clock read 3699 to 3700 MHz across every run.

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

**Status:** slices 1 and 3 built; the *Done when* waits on a run with
turbo on. `bench/counters.zig` opens one group of five events (cycles,
instructions, branch misses, L1D read misses, `CACHE_MISSES` for the last
level), user mode only, and refuses multiplexed counts. `bench
--counters` starts the group before each phase, stops and reads it after,
and keeps each event's fewest per frame; the times are taken inside the
counted span, so reading the counters stays out of them. The counts go
into the JSON as `"<scenario>, <event>"` and `"<scenario>, declare,
<event>"`, and `bench-compare --metric cycles|instructions` compares
those keys alone (nanoseconds stay the default, and ignore them). On
other platforms `--counters` names the alternatives.

Measured on the i9-10900K under Linux: the box tree's declaration ran
440,424 instructions a frame (Callgrind: 437,628, for a different CPU
model) in 216,504 cycles, 58.5 µs at 3.7 GHz against 58.7 µs timed.
`--calibrate --metric cycles` at `45f48f4` (100 rounds, 3 layouts, turbo
off) called nothing; its intervals reached a mean 0.41% and median 0.20%
from no change, against 0.29% and 0.20% for nanoseconds (64 rounds, one
layout). With the clock fixed, cycles and nanoseconds are one
measurement, so this cannot show the gain the *Done when* asks for.

Slice 2 (`rdpmc`) matters less than planned: user-mode counting leaves
the `ioctl` calls' kernel time out of the counts, the times are taken
inside the counted span, and each frame already gets its own minimum.

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

**Status:** done, with a constructed case in place of T4's. Slice 1:
`ZUI_BENCH_LAYOUT_SEED` moves the stack down by 0 to 63 steps of 64 bytes
(an `inline else` over buffer sizes, the scenario called through
`@call(.never_inline, ...)`), and starts each frames scenario's `Context`
at a multiple of 128 bytes (the cache line `initBuffer` needs) inside an
allocation 4 KiB larger. Slice 2: the spike worked. A module-level
`comptime { asm (".text\n.skip N"); }` moved every function in the
executable, zui's included, by exactly `N` (`nm`: +0x30 for 48, +0x410
for 1040); `-Dbench-layout-seed` picks `N` from 0 to 4080 in steps of 16.
Slice 3: `bench-compare --layouts <k>` (3) chooses fresh layouts per
comparison; when both sides advertise `code-layout`, each side is built
once per layout, all builds at once (a benchmark build is 47 s, almost
all of it on one thread). The rounds take turns with the layouts, on
Linux with a random 0 to 4 KiB of environment padding as well, and the
bootstrap resamples layouts and then rounds. The report names each
layout's seed and padding.

T4's case was a variant never committed, and aligning `wrapLines` to 64
bytes, its other case, moved nothing past its band here (new strings
−0.3%). So the case was built: a probe commit that only pads the start
of the code by 864 bytes. Run directly, four code shifts moved
static-styled boxes from 103.9 to 107.8 µs (3.7%), against 1.3% between
repeats. `bench-compare -- main <probe>` with `--layouts 1` called eight
times slower or faster, up to +2.8% (depth 64, 4000 children),
static-styled boxes +2.6% (+2.5% to +2.7%); with the default 3 layouts
it called nothing, static-styled boxes −1.0% (−2.7% to +2.7%), in 364 s
including all twelve builds. A commit compared with itself over 3 layouts
(100 rounds) called nothing either, its intervals 0.52% wide on average.
The cost is honest width: in the layout-sensitive scenarios, a real
change under about 2% is no longer called.

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

**Status:** done (`f099fd1`, `9d0ddac`). Callgrind runs with `--cache-sim=yes --branch-sim=yes`
and a fixed 32 KiB 8-way I1 and D1 and an 8 MiB 16-way LL (`-v` confirms
Valgrind uses them, despite its warning that it found the host's L3).
Each `"<scene>, <phase>"` instruction key gets four informational keys:
`I1 misses`, `D1 misses`, `LL misses` and `branch misses`. Callgrind
leaves trailing zeros off its `Collected` line, so missing values read as
zero. Measured on bare-metal Linux (i9-10900K, Valgrind 3.25.1): two runs
wrote byte-identical JSON; a run takes about 8 s once built. Against
`main` without the simulation, every instruction count moved by 7 to 13
per frame (at most −0.06%), well inside the 2% gate.

The first two CI runs (`f099fd1`, and `75a9ade` by `workflow_dispatch`)
agreed on every instruction, I1, LL and branch count, but 21 of 30 D1
miss counts differed, by up to 0.8% (3% on counts under 40). The
simulated cache sees real addresses, and the environment and the
executable's path are copied onto the initial stack, so their lengths
move every stack address: here, padding the environment moved documents
view's D1 misses from 5025 to 4950. `counts` now runs each child with an
empty environment, as `./zui-counts` from its own directory; a run from a
longer path with 3000 bytes of extra environment then wrote byte-identical
JSON. This is the same effect B5 sets out to randomize for wall-clock
time. With that fix, two CI runs of `9d0ddac` (a push and a
`workflow_dispatch`) agreed on all 150 counts, and the counts job took
2.5 to 5 minutes. This machine (Arch, Valgrind 3.25.1) still differs
from CI (Ubuntu) on 15 D1 counts by a few misses, likely through
Valgrind's version and the path of the preload library it adds to the
environment; CI only ever compares with CI.

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

**Status:** slices 1, 3 and 4 built; the *Done when* waits on a run on
another OS. `Machine` now also records the OS version (`uname`,
`RtlGetVersion`, `kern.osproductversion`), the CPU vendor (CPUID, or
`CPU implementer`), the physical cores and the L1d, L2 and L3 sizes
(sysfs, `GetLogicalProcessorInformation`, `sysctl`), the target triple
and CPU model the reader was built for, and the commit. The commit and
the clock are left out of the fingerprint, which changed with the new
fields, so this setup was calibrated again. On Linux the CPU counts now
come from `/sys/devices/system/cpu/present`, since a pinned process sees
one CPU. `bench --results-dir <dir>` writes
`<dir>/<fingerprint>/<commit>.json` (the commit from git, `-dirty` when
tracked files changed, or `--commit`). `zig build bench-report -- <dir>
[<commit>]` defaults to the commit measured on the most machines,
divides each machine's times by its own box tree's in the same phase,
and lists the five scenarios whose relative cost differs most. README's
*Comparing machines* gives the recipe, cross-built executables included.
Checked only on one machine, pinned against unpinned as two setups: the
first frame of the documents view and `init` moved most (1.31× and
1.28×).

Slice 2 in part: `--counters` builds for ARM Linux (the same
`perf_event_open` group) but is unverified there; macOS through kperf is
not written, and README says so; Windows gets the WPR, VTune and uProf
pointers.

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
