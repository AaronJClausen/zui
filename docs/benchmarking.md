# Benchmarking and profiling

`zig build bench` times every scenario, `zig build counts` counts its
instructions under Callgrind, which no machine's noise can move, and
`zig build bench-compare -- <base>` judges a change in time between two
commits on one machine; [development.md](development.md#the-roots-steps)
lists their flags. This page is how to get numbers worth trusting out of
them.

## Profiling

Set `.features = .{ .Tracer = zui_tracy.Tracer }` in the `Config`, call
`zui_tracy.frameMark()` after each presented frame, build with
`-Dzui-tracy=true`, and connect Tracy's profiler of the same version
(0.14.1). Every step of `beginFrame` and `endFrame` is a zone.
The tour does all of this with `zig build tour -Dzui-tracy=true`, run
from `renderers/raylib/`. Without the profiler's window, Tracy's
`tracy-capture -o tour.tracy` saves a trace (run the tour with
`TRACY_NO_EXIT=1` so it waits for the capture to finish) and
`tracy-csvexport tour.tracy` lists its zones.

To keep noise out of a profile or a timing:
- pin the process to one core (`taskset -c 2` on Linux, `start /affinity 4`
  on Windows) and keep other work off it; `bench-compare` pins itself to
  the highest-numbered logical CPU, or the one `--core` names;
- fix the CPU frequency, as the next section describes;
- compare two builds by alternating them, never one after the other, as
  `zig build bench-compare` does; and prefer `zig build counts`, which no
  machine's noise can move.

## Quieting the machine

A CPU that boosts its clock with its temperature times the same code
differently from one minute to the next. `bench-compare` records the
machine's state before every run, shows it in its report, warns when it
changed during the comparison, and with `--require-quiet` refuses to run
while turbo is on or the Linux governor is not `performance`.

On Windows, from an administrator prompt:

```bat
powercfg /setactive SCHEME_MIN
powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 99
powercfg /setactive scheme_current
```

The first line picks the High Performance plan. A maximum processor state
of 99% keeps the clock at or below its base frequency, which turns Turbo
Boost off. `PROCTHROTTLEMAX 100` turns it back on.

On Linux:

```sh
sudo cpupower frequency-set -g performance
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo   # AMD: echo 0 > .../cpufreq/boost
# keep other work off the measuring core: isolcpus=3 on the kernel command line, or
sudo cset shield --cpu 3 --kthread on
# take its hyperthread sibling offline (thread_siblings_list names it)
cat /sys/devices/system/cpu/cpu3/topology/thread_siblings_list
echo 0 | sudo tee /sys/devices/system/cpu/cpu13/online
# run without address randomization
setarch -R zig build bench-compare -- main --core 3 --require-quiet
```

Then run `zig build bench-compare -- --calibrate` once, so comparisons on
this setup are judged against its own noise.

## Comparing machines

Times from two machines are never compared directly, but what each
scenario costs relative to the others can be. On each machine, keep a
run in one shared directory:

```sh
zig build bench -- --core 3 --results-dir ~/zui-results            # also --counters on Linux
zig build bench-install -Dtarget=aarch64-linux                      # or build for another machine,
./zui-bench --core 3 --results-dir results --commit 45f48f4         # copy zig-out/bin/zui-bench there, run it, copy results/ back
zig build bench-report -- ~/zui-results
```

Each result lands in `<dir>/<machine fingerprint>/<commit>.json`, with
the OS and its version, the CPU, its cores and caches, the target the
benchmark was built for, and the power settings. `bench-report` divides
each machine's times by its own box tree's and lists the scenarios whose
relative cost differs most between machines.

Hardware counters come from `perf_event_open` on Linux, on x86-64 and
ARM alike, but only on bare metal: WSL2, Docker on Windows and GitHub's
hosted runners hide them. Windows has no public user-mode API for them:
Windows Performance Recorder can record them into a trace, from an
administrator prompt (`wpr -pmcsources` lists the counters a profile can
name), and Intel VTune and AMD uProf read them too. `bench` then records
the time and the clock speed alone.

On macOS, they come from the private kperf framework and need `sudo`, as
the macOS fork of poop reads them; `--counters` does not read them yet.
