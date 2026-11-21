# 01-measure: Measure

Stage 1 of SPEC.md §21: instruction counts in CI, with simulated cache
and branch misses; the tracer contract; comparisons of two commits
pinned, one scenario at a time in a shuffled order, over several code and
memory layouts, judged by confidence intervals against a calibrated noise
band; hardware counters; results that record their machine.

**Done when:** counts repeat exactly between runners; an off tracer
leaves them unchanged; a commit compared with itself calls nothing, and a
change that only moves code is not called.

**Status.** Done. `01-measure:01-bench-compare` and
`01-measure:02-startup-benchmarks` landed in release 0.6, before stage 1
was named; `01-measure:03-instruction-counts-in-ci` and
`01-measure:04-tracer-contract` were stage 1. The rest came after stage 7:
`08-effects:01-gradients-shadows-glow`'s first slice (`80db29e`, on
`wip/g1-gradients-shadows-and-glow`) passed every test but ran 5.5% more
instructions in the box tree's declaration and 7.7% more in the wide
tree's, scenes that draw no effect. Rather than build stage 8 on that,
the work turned to the measurements and the code under it: benchmarks
that could judge a change of a few percent (`01-measure:05-pinned-runs`
to `01-measure:11-across-systems-and-hardware`, planned in
`docs/plans/benchmarking.md` as B1 to B8) and the data-oriented design
audit's findings (`06-text-and-layout:14-layer-sort` to
`06-text-and-layout:20-text-commands-point-at-style`). With these done,
stage 8 resumed.

## Items

| Item | Status |
|---|---|
| `01-measure:01-bench-compare` `zig build bench-compare -- <ref>` | done |
| `01-measure:02-startup-benchmarks` Startup benchmarks | done |
| `01-measure:03-instruction-counts-in-ci` Instruction counts in CI | done |
| `01-measure:04-tracer-contract` The tracer contract | done |
| `01-measure:05-pinned-runs` Pinned runs, with the machine's state recorded | done |
| `01-measure:06-confidence-intervals` Confidence intervals and a measured noise floor | done |
| `01-measure:07-shuffled-scenarios` Each scenario on its own, in a shuffled order | done |
| `01-measure:08-hardware-counters` Hardware counters per phase | done |
| `01-measure:09-layout-as-random-factor` Code and memory layout as a random factor | done |
| `01-measure:10-simulated-misses` Simulated cache and branch misses in `counts` | done |
| `01-measure:11-across-systems-and-hardware` Measuring across operating systems and hardware | done |

---

## 01-measure:01-bench-compare — `zig build bench-compare -- <ref>`

Builds both commits, alternates them locally, and reports the median
ratio and its spread (SPEC.md §20.3). `zig build bench-compare --
946405e~1 946405e` reports the box tree's declaration −26.4% (middle half
−27.5% to −26.1%) and calls it faster: the `depth: u16` store-forwarding
stall, which left the instruction count unchanged. A commit compared with
itself calls nothing faster or slower. `01-measure:05-pinned-runs` to `01-measure:09-layout-as-random-factor` replaced how it judges a
change; the alternation of each commit's own benchmarks remains.

## 01-measure:02-startup-benchmarks — Startup benchmarks

`init`, `initBuffer` and first-frame scenarios, in `--json` and
`--compare`. With the library at `a6d8e34`, the fastest samples were:

| Scenario | Fastest |
|---|---|
| `init`, default config (4.63 MiB) | 74.6 µs |
| `initBuffer`, default config | 10.0 µs |
| first frame, Documents view | 30.3 µs (steady: 9.9 µs) |
| first frame, 1,000 texts | 230.0 µs |

The demo's cold start moved to `03-contracts:05-zui-app`, because the demo is the raylib renderer's.

## 01-measure:03-instruction-counts-in-ci — Instruction counts in CI

`zig build counts` runs each single-threaded scenario of `core/bench/` in a
fresh process under Callgrind, collecting only `beginFrame` with
declaration, or only `endFrame`, over 10 frames after 4 of warm-up. The
executable is always built for x86-64-v3 Linux without libc, so every
machine runs the same instructions. CI counts the parent commit with its
own scenarios, then this one, and fails on more than 2% growth.

At `cd534f4` the counts were identical in a local Docker container
(i9-10900K) and in two runs of the CI job. Instructions per frame:

| Scenario | Declaration | `endFrame` |
|---|---|---|
| 4,096 boxes, depth 8 | 766,377 | 1,561,476 |
| 1,000 texts, warm cache | 137,324 | 2,350,337 |
| 1,000 texts, cold cache | 137,326 | 2,344,117 |
| depth 64 | 15,966 | 25,011 |
| 4,000 children of one parent | 471,656 | 1,086,532 |
| documents view | 38,317 | 97,371 |

Warm and cold text cost nearly the same in `endFrame` because the
benchmark's glyph-table measurement costs about as much as a cache probe.
A change anywhere in the executable can still move a count by a few
instructions, by moving the constant data a scenario copies: the
documents view's declaration moved by 5 when only the report's printing
changed.

## 01-measure:04-tracer-contract — The tracer contract

`Features.Tracer`: a zone per layout pass, per emission step and per
`beginFrame` step, through `zuiBegin` and `zuiEnd`, and nothing analyzed
when it is `void`; `zui.TraceZone` and five compile-error tests; a
recording tracer in `core/src/tests/support.zig`, and a test that one frame
produces every zone, each nested in `begin_frame` or `end_frame`;
`zui_tracy`, with Tracy as a lazy dependency linked by
`-Dzui-tracy=true`, tested with Tracy's client on all three systems (in a
MinGW build Tracy's callstacks are off: with them the process exits with
code 9 after Tracy shuts down); the profiling guide, in README.md's
*Profiling*.

`zig build counts` without a tracer was identical to the instruction in
every scenario, against `994a631`, in a local Docker container.

The trace of the demo was captured headlessly: the raylib renderer's demo built
with `-Dzui-tracy=true` and run with `TRACY_NO_EXIT=1`, Tracy 0.14.1's
`tracy-capture` saving the trace and `tracy-csvexport` listing its
zones. In the thumbnail grid's 36 frames, each of the 14 zones other than
`sort_layers` appears 36 times; in the documents view, whose tooltip floats,
`sort_layers` appears in the 2 frames that showed it. Every zone of
`zui.TraceZone` appears.

## 01-measure:05-pinned-runs — Pinned runs, with the machine's state recorded

**Plan.** `bench --core <n>` pins to one core at a raised priority and
`--machine-json` records the machine; `bench-compare` builds unpinned,
then pins itself, records the state before every run, and warns when it
changes. **Done when:** a commit compared with itself, pinned and with
turbo off, is narrower than unpinned.

`core/bench/machine.zig` reads the power plan, `PROCTHROTTLEMAX`,
`PERFBOOSTMODE` and the clock on Windows, and the governor, turbo, the
core's siblings and `randomize_va_space` on Linux. `--require-quiet`
refuses to run with turbo on or another governor. README's *Quieting the
machine* gives the setup. On the i9-10900K under bare-metal Linux with
turbo off, `f099fd1` against itself over 10 rounds: intervals 1.74% wide
on average pinned (median 0.80%), against 10.65% unpinned (median
5.25%, widest 78.7%); the clock read 3699 to 3700 MHz pinned. Windows
reports the base clock as the current one, so it cannot show boosting.

**Spec.** §20.3.

## 01-measure:06-confidence-intervals — Confidence intervals and a measured noise floor

**Grounding.** `01-measure:01-bench-compare`'s middle half of 10 ratios is no confidence interval,
and its 2% threshold was set by hand once.

**Plan.** A bootstrap interval of the median ratio, a noise band
measured per machine, rounds until the interval is narrow enough.
**Done when:** a commit compared with itself gives intervals that all
contain zero, and `01-measure:01-bench-compare`'s store-forwarding stall is still called faster.

`core/bench/statistics.zig` holds the bootstrap (a fixed seed, 10,000
resamples, two-stage for `01-measure:09-layout-as-random-factor`'s layouts) and a test for two clusters of
frames, which `bench` warns about, beside each phase's p95.
`bench-compare --calibrate` compares a commit with itself and saves each
time's band by machine fingerprint; without one, a band is 2%. A change
is called only when its whole interval lies beyond its band. Rounds
continue until each interval is under `--target-width` (1%) or
`--time-budget` (420 s) is spent. `bench --compare` is removed.

`--calibrate` at `468ffc8` (61 rounds, turbo on, pinned) called nothing,
with bands of 0.5% to 0.9%; 29 of 30 intervals contained zero. `946405e~1`
to `946405e` is still called faster: the box tree's declaration −27.4%
(−27.5% to −27.4%). On Windows the 0.1 µs clock keeps small scenes'
intervals in whole steps, so rounds there rarely stop early.

**Spec.** §20.3.

## 01-measure:07-shuffled-scenarios — Each scenario on its own, in a shuffled order

**Plan.** `bench --scenario <name>` and `--order-seed <n>`, and
`bench-compare` running one scenario at a time from each side's
installed benchmark, in a new order every round. **Done when:** a commit
compared with itself calls nothing.

`bench --list-scenarios` names each scenario as compared, reported or
startup; startup scenarios always run last, since their page faults are
part of what they time. `zig build bench-install` installs the
benchmark. When both sides support it, each round runs one scenario at a
time, alternating which side goes first; an older base keeps the
whole-run alternation. `4294abe` against itself (100 rounds, turbo on,
pinned) called nothing. The report still lists times in the first
round's order, not the table's.

**Spec.** §20.3.

## 01-measure:08-hardware-counters — Hardware counters per phase

**Plan.** Cycles, instructions, branch misses, L1D read misses and
last-level misses for each phase, through `perf_event_open`. **Done
when:** on bare-metal Linux, cycles compared with themselves give a noise
band well under nanoseconds'.

`bench --counters` opens one group of the five events, user mode only,
refuses multiplexed counts, and keeps each event's fewest per frame
under keys beside the times; `bench-compare --metric
cycles|instructions` compares them. The box tree's declaration: 440,424
instructions in 216,504 cycles, 58.5 µs at 3.7 GHz against 58.7 µs
timed.

Closed by the owner without the gain the *Done when* expected. With
turbo off, cycles and nanoseconds are one measurement. With turbo on
(`abd12ce` against itself, 100 rounds over 3 layouts), the intervals
reached a median 0.30% from no change in both: each time is a pinned
run's fastest frame, which runs at the top clock either way. The counters
stay for explaining a change, since instructions against cycles tells
more work from more waiting, and nanoseconds stay the default.

Not built: reading the counters through `rdpmc`, which matters less than
planned, since user-mode counting already leaves the `ioctl`s out.

**Spec.** §20.3.

## 01-measure:09-layout-as-random-factor — Code and memory layout as a random factor

**Grounding.** In `06-text-and-layout:06-line-break-segmentation`, warm text ran the same instructions as `c5b0401`,
with the same simulated misses, and measured +7.8%: Mytkowicz et al.'s
layout bias, which one build per commit treats as the truth.

**Plan.** Seeds that move the stack, the `Context`'s memory and the
code, with the rounds taking turns over several. **Done when:** a change
that only moves code is reported as within noise.

`ZUI_BENCH_LAYOUT_SEED` moves the stack down by up to 4 KiB in steps of
64 bytes and starts each `Context` at a multiple of 128 bytes inside an
allocation 4 KiB larger. `-Dbench-layout-seed` moves every function by
up to 4080 bytes in steps of 16, through module assembly LLVM emits
before any function (`nm`: exactly +48 and +1040 bytes). `bench-compare
--layouts <k>` (3) picks fresh seeds per comparison, builds each side
once per layout, all builds at once, and on Linux adds 0 to 4 KiB of
environment padding; the bootstrap resamples layouts, then rounds.

`06-text-and-layout:06-line-break-segmentation`'s variant was never committed, so the case was built: a commit that
only pads the code by 864 bytes. Run directly, four code shifts moved
static-styled boxes from 103.9 to 107.8 µs, against 1.3% between repeats.
With `--layouts 1`, `bench-compare` called eight changes, static-styled
boxes +2.6% (+2.5% to +2.7%); with 3 layouts it called none (−1.0%, −2.7%
to +2.7%), in 364 s with twelve builds. A commit against itself over 3
layouts calls nothing, its intervals 0.52% wide on average. The price is
honest width: in the layout-sensitive scenes, a real change under about
2% is no longer called.

**Spec.** §20.3.

## 01-measure:10-simulated-misses — Simulated cache and branch misses in `counts`

**Grounding.** Instruction counts cannot see a change to memory layout,
which is most of what the audit proposed.

**Plan.** Callgrind's cache and branch simulation under a fixed cache
geometry, its misses informational. **Done when:** two CI runs give
identical miss counts, and the job stays within 10 minutes.

`counts` runs Callgrind with `--cache-sim=yes --branch-sim=yes` and a
fixed 32 KiB 8-way I1 and D1 and an 8 MiB 16-way LL, so the misses do not
depend on the host. Each `"<scene>, <phase>"` instruction key gains
`I1 misses`, `D1 misses`, `LL misses` and `branch misses`; only the
instructions fail `--compare`. Every instruction count moved by 7 to 13
a frame (at most −0.06%).

The first two CI runs agreed on every count but 21 of 30 D1 misses, by up
to 0.8%: the simulated cache sees real addresses, and the environment and
the executable's path are copied onto the initial stack. Each child now
runs as `./zui-counts` from its own directory with an empty environment
(`9d0ddac`), and two CI runs then agreed on all 150 counts, in 2.5 to 5
minutes. This machine still differs from CI on 15 D1 counts by a few
misses, through Valgrind's version and its preload path; CI only ever
compares with CI.

**Spec.** §20.3.

## 01-measure:11-across-systems-and-hardware — Measuring across operating systems and hardware

**Grounding.** A result in a commit message records neither the OS, the
CPU nor the power settings it came from, so results from two machines
cannot be set side by side.

**Plan.** Each result keeps the machine it came from, and a report sets
machines side by side, each normalized to its own box tree, to show how
each platform's costs differ rather than which CPU is faster.

**Done when:** one commit's results from two operating systems, or two
CPU architectures, appear side by side in `bench-report`.

Built in `fe4f48e`. `Machine` records the OS and its version, the CPU
vendor, the physical cores, the L1d, L2 and L3 sizes, the target and CPU
model built for, and the commit, on Linux, Windows and macOS; the commit
and the clock stay out of the fingerprint. `bench --results-dir <dir>`
writes `<dir>/<fingerprint>/<commit>.json`, and
`zig build bench-report -- <dir> [<commit>]` names the five scenarios
whose relative cost differs most. README's *Comparing machines* gives the
recipe, cross-built executables included.

Both halves ran at `be96e84` on the reference machine, pinned to core 19,
into `cross-os-files/source/repos/AaronJClausen/zui/bench-results` on the
shared data drive: bare-metal Linux 7.2.15 with turbo off and the
`performance` governor (`3b27f9488f36046b`), and Windows 11 10.0.26300
on the High performance plan, boost mode 3, turbo on (`38f4bf8363de7681`),
neither allocating after `init`. The box tree laid out in 110.1 µs and
83.7 µs. Over each machine's own box tree, every scenario's frame,
declaration and read agree within 4%, but the documents view's
declaration (1.16×) and `depth 64`'s (1.14×), scenes of a few
microseconds where the Windows clock's 0.1 µs steps count. Startup is
where the two operating systems differ: the documents view's first
frame costs 0.56× the box tree on Windows and 0.15× on Linux (3.69×),
`init` 0.70× and 1.01× (1.44×), the first frame of 1,000 texts 3.38× and
2.55× (1.32×). Each touches memory for the first time, which Windows
pays for more. `--counters` builds for ARM Linux but is unverified there;
macOS's counters through kperf are not written.

**Spec.** §20.3.
