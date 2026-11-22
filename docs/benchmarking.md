# Benchmarking and profiling

`zig build bench` times every scenario, `zig build counts` counts its
instructions under Callgrind, which no machine's noise can move, and
`zig build bench-compare -- <base>` judges a change in time between two
commits on one machine; [development.md](development.md#the-roots-steps)
lists their flags. This page is how to get numbers worth trusting out of
them.

## Profiling

This section is for an application built on zui: how to see where its
frames go, and why it wakes when it should sleep. Every frame passes
through one tracer, `Config.features.Tracer`, which zui calls at the
start and end of each step of `beginFrame` and `endFrame`. Tracy is one
tracer, `zui_debug`'s inspector times zones with another, and an
application can write its own.

### Tracing into Tracy

Take the option from your own build and pass it to the zui dependency,
leaving it `null` when it was not given, and give the same option to
every other zui package you depend on, such as a renderer or a host, so
that they all build one `zui` module:

```zig
// build.zig
const tracy = b.option(bool, "zui-tracy", "Trace zui's zones into Tracy");
const zui = b.dependency("zui", .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy });
exe.root_module.addImport("zui", zui.module("zui"));
exe.root_module.addImport("zui_tracy", zui.module("zui_tracy"));
const zui_raylib = zui.builder.dependency("zui_raylib", .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy });
```

Name `zui_tracy.Tracer` in the `Config`, and mark each frame once it is
presented:

```zig
const zui_tracy = @import("zui_tracy");

const Ui = zui.Context(.{ .Text = Fonts, .features = .{ .Tracer = zui_tracy.Tracer } });

while (host.zuiPoll(.main, &builder)) {
    ui.beginFrame(&builder.record());
    declare(&ui);
    const frame = ui.endFrame();
    try renderer.zuiSubmit(host.zuiSurface(.main), frame);
    ui.release(frame);
    zui_tracy.frameMark();
    host.zuiWait(ui.nextFrame());
}
```

An application run by `zui_app` calls `zui_tracy.frameMark()` from its
`zuiLoader`, which runs after each frame. Built without
`-Dzui-tracy=true`, `zui_tracy.Tracer` is `void` and `frameMark` does
nothing, so the same code traces nothing and Tracy is never fetched.

Build with `zig build -Dzui-tracy=true`. On a Linux whose own C runtime
Zig's linker cannot read
(`fatal linker error: unhandled relocation type R_X86_64_PC64`), add
`-Dtarget=x86_64-linux-gnu`, which links against the glibc Zig ships.
Then run the application and connect Tracy's profiler. Its version must
match the client zui links, which is Tracy 0.14.1.

Without the profiler's window, Tracy's command-line tools record and
read a trace. Run the application with `TRACY_NO_EXIT=1`, so that it
waits at exit until the capture has everything, and in another shell:

```sh
TRACY_NO_EXIT=1 ./zig-out/bin/app &
tracy-capture -o app.tracy        # -s 10 stops after 10 seconds
tracy-csvexport app.tracy         # each zone's count, total, mean, minimum and maximum
```

`zig build tour -Dzui-tracy=true`, run from `renderers/raylib/`, is the
tour traced this way.

These are the zones zui emits, the `zui.TraceZone` values. The steps
nest in `begin_frame` and `end_frame`:

| Zone | Covers |
|---|---|
| `begin_frame` | all of `beginFrame` |
| `wait_for_frame` | waiting for a frame the renderer has released, when every frame in flight is still held |
| `evict_state` | dropping the state of elements no longer declared |
| `apply_events` | applying the record's input events |
| `swap_sources` | taking what each source published; only when `Sources` has a field |
| `relay` | handing the record to a relay listener, such as a session being recorded; only while one is attached |
| `end_frame` | all of `endFrame` |
| `measure_text` | measuring, through the text contract, text that is in no cache |
| `fit_widths` | each element's width from its content, children first |
| `distribute_widths` | growing and shrinking children to their parent's width |
| `wrap_text` | breaking text into lines at its final width |
| `fit_heights` | each element's height from its content, children first |
| `distribute_heights` | growing and shrinking children to their parent's height |
| `position` | placing each element |
| `emit` | writing the render commands, lowering what the renderer does not draw |
| `sort_layers` | ordering the commands by layer; only when a frame draws outside layer 0 |

The application's own declaration is no zone: in Tracy it is the gap
between `begin_frame` and `end_frame`. A frame that is slow in
`measure_text` is measuring new text, one slow in `wait_for_frame` is
waiting on the renderer, and one whose gap is wide is slow in the
application.

### The application's own zones

The tracer contract carries only `zui.TraceZone`, and `zui_tracy` has no
zone of the application's. With `-Dzui-tracy=true`, though, Tracy's
client is linked into the program, so the application can call Tracy's C
API itself. Gate it on `zui_tracy.enabled`, and a build without Tracy
neither references nor links it:

```zig
const AppZone = struct {
    const SourceLocation = extern struct { name: ?[*:0]const u8, function: [*:0]const u8, file: [*:0]const u8, line: u32, color: u32 };
    const Context = extern struct { id: u32, active: i32 };
    extern fn ___tracy_emit_zone_begin(location: *const SourceLocation, active: i32) Context;
    extern fn ___tracy_emit_zone_end(context: Context) void;

    context: if (zui_tracy.enabled) Context else void,

    /// Tracy identifies a zone by the address of its location, so each
    /// call site keeps one static location.
    fn begin(comptime name: [:0]const u8, comptime site: std.builtin.SourceLocation) AppZone {
        if (!zui_tracy.enabled) return .{ .context = {} };
        const Static = struct {
            const location: SourceLocation = .{ .name = name, .function = site.fn_name, .file = site.file, .line = site.line, .color = 0 };
        };
        return .{ .context = ___tracy_emit_zone_begin(&Static.location, 1) };
    }

    fn end(zone: AppZone) void {
        if (zui_tracy.enabled) ___tracy_emit_zone_end(zone.context);
    }
};

fn declareInbox(ui: *Ui, inbox: *const Inbox) void {
    const zone = AppZone.begin("declare inbox", @src());
    defer zone.end();
    // ...
}
```

The two structs are Tracy's `___tracy_source_location_data` and
`TracyCZoneCtx` as zui builds Tracy, without `TRACY_ON_DEMAND`.

### A tracer of your own

A tracer is a struct with two plain functions. `zuiBegin` takes the zone
at comptime and returns a span of any type; `zuiEnd` takes exactly that
span. There is no tracer value: both are called on the thread running
the frame, zones nest, and whatever the tracer keeps lives in its
container's variables. A mistake in either signature is a compile error
naming it. With `Tracer = void`, the default, no tracing code is
analyzed at all.

This one logs each frame that takes longer than its budget, from the
start of `beginFrame` to the end of `endFrame`, declaration included:

```zig
const SlowFrameLog = struct {
    /// Set before the first frame; until then nothing is timed.
    pub var clock: ?std.Io = null;
    pub var budget_nanoseconds: u64 = 4 * std.time.ns_per_ms;
    threadlocal var frame_started_at: ?std.Io.Timestamp = null;

    pub fn zuiBegin(comptime zone: zui.TraceZone) zui.TraceZone {
        if (zone == .begin_frame) {
            if (clock) |io| frame_started_at = std.Io.Timestamp.now(io, .awake);
        }
        return zone;
    }

    pub fn zuiEnd(zone: zui.TraceZone) void {
        if (zone != .end_frame) return;
        const io = clock orelse return;
        const started_at = frame_started_at orelse return;
        const elapsed: u64 = @intCast(started_at.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
        if (elapsed > budget_nanoseconds) {
            std.log.warn("slow frame: {d:.2} ms", .{@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms});
        }
    }
};

const Ui = zui.Context(.{ .Text = Fonts, .features = .{ .Tracer = SlowFrameLog } });

// before the first frame:
SlowFrameLog.clock = io;
```

### The inspector and its zone timer

`zui_debug.Inspector(Ui)` is a panel the application declares over its
own UI. It lists the last frame's diagnostics (each limit exceeded and
what the frame needed, the first element dropped, duplicate ids, an
unbalanced tree, refused publishes), the fallbacks in effect, the time
each zone took, the element tree, and the layout and decoration of the
element under the pointer. Its context needs a `Config.Text`, which
draws the panel.

Zone times come from `zui_debug.ZoneTimer(Inner)`, a tracer that times
each zone and passes it on to `Inner`: `zui_tracy.Tracer` to trace into
Tracy as well, a tracer of your own, or `void`. Without it, the panel
says the frame is untimed.

```zig
const zui_debug = @import("zui_debug");

const Timer = zui_debug.ZoneTimer(zui_tracy.Tracer);
const Ui = zui.Context(.{ .Text = Fonts, .features = .{ .Tracer = Timer } });
const Inspector = zui_debug.Inspector(Ui);

Timer.useClock(io); // before the first frame; nothing is timed without it

// The inspector holds a row per element the context can hold, so it
// lives with the application's state, not on the stack.
const inspector = try gpa.create(Inspector);
inspector.* = .{};

ui.beginFrame(&builder.record());
declare(&ui);
if (ui.chordPressed(.{ .key = .f12 })) {
    inspector_open = !inspector_open;
    ui.requestFrame(); // the panel shows a frame it observed in the frame after
}
if (inspector_open) inspector.declare(&ui); // last, so it floats over the rest
const frame = ui.endFrame();
if (inspector_open) inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
```

Under `zui_app`, `observe` goes in the application's `zuiObserve` hook,
and `Timer.frameTimes()` gives the same times to code of your own after
each `endFrame`. The panel shows each zone's time in the last frame, and
its mean and peak over the last 60 frames.

The tour does this: `zig build tour -- --zui-debug`, from
`renderers/raylib/` or `hosts/native/`, opens the panel at the start,
and F12 toggles it. Build it with `-Dzui-tracy=true` and its zone timer
passes every zone on to Tracy too.

### Why an application does not idle, or a frame is slow

Each frame returns `Diagnostics` and leaves a `NextFrame`. A frame past
a limit keeps what fit and says so in `frame.diagnostics`, and
`ui.nextFrame()` (`ui.nextFrame(&sources)` with sources) says when the
next frame is due: `.immediately`, `.at` an instant, or `.on_event`,
when the loop sleeps until input. An application that never reaches
`.on_event` while nothing changes never idles.

```zig
fn reportFrame(ui: *const Ui, frame: *const Ui.Frame) void {
    const diagnostics = frame.diagnostics;
    if (!diagnostics.ok()) {
        var exceeded = diagnostics.exceeded.iterator();
        while (exceeded.next()) |limit| {
            std.log.warn("limits.{t}: the frame needed {d}", .{ limit, diagnostics.needed.get(limit) });
        }
        if (diagnostics.duplicate_ids != 0) std.log.warn("{d} duplicate ids", .{diagnostics.duplicate_ids});
    }
    switch (ui.nextFrame()) {
        .immediately => std.log.info("a frame was requested, so the loop does not sleep", .{}),
        .at => |deadline| std.log.info("next frame in {d:.3} s", .{deadline.secondsSince(ui.now())}),
        .on_event => {},
    }
}
```

`.immediately` comes from a `ui.requestFrame()` in the frame just
declared, or a source holding something not yet taken: an animation that
asks for every frame, or a producer that publishes faster than it needs
to. `.at` comes from the earliest `ui.requestFrameAt`, such as a caret's
blink. `zui_app` logs each limit exceeded, the first time it happens in
a run, through `Options.notify`.

To measure idling, do what the tour's `--measure-idle` does: after a few
seconds of warm-up, read the process's CPU time (`getrusage` on Linux
and macOS, `GetProcessTimes` on Windows) at a frame asked for with
`ui.requestFrameAt`, again ten seconds later, and count the frames
between. An idle application declares no frame in that time, and zui's
budget for it is 0% CPU. Run from `renderers/raylib/` or
`hosts/native/`, `zig build tour -- --measure-idle` prints the tour's.

### Measuring a change

A profile shows where time goes; whether a change made a frame faster
needs a measurement that the machine's noise cannot fake:

- pin the process to one core (`taskset -c 2` on Linux,
  `start /affinity 4` on Windows) and keep other work off it;
- fix the CPU frequency, as [the next section](#quieting-the-machine)
  describes;
- run the two builds alternately, A, B, A, B, many times, never all of
  one and then all of the other, and compare the medians of the same
  measure, such as `ZoneTimer`'s frame times over the same input;
- compare the zones, not only the whole frame, to see where a change
  lands.

A change to zui itself is measured with zui's own steps:
`zig build bench-compare -- <base>` alternates two commits, pinned to
the highest-numbered logical CPU or the one `--core` names, and judges
each scenario's change against the machine's noise, and
`zig build counts` counts instructions under Callgrind, which no noise
can move. [development.md](development.md#the-roots-steps) lists their
flags, and the sections below how to trust their numbers.

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

The first line picks the High Performance plan. A maximum processor
state of 99% keeps the clock at or below its base frequency, which turns
Turbo Boost off. `PROCTHROTTLEMAX 100` turns it back on.

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

Then run `zig build bench-compare -- --calibrate` once, so comparisons
on this setup are judged against its own noise.

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
