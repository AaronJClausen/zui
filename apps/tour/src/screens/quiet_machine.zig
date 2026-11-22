const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");
const shared = @import("../shared.zig");

/// The sensor's newest reading, published only when it changes.
pub const Reading = struct {
    celsius: f32 = 0,
    /// Which sample of the sensor this is, counting those that did not change.
    sample: u32 = 0,
};

/// The quiet machine's sensor, which wakes the UI only on a new value.
pub const ReadingSource = zui_async.Latest(Reading);

const FrameReason = @FieldType(shared.Perf.Sample, "reason");
const frame_reason_count = std.enums.values(FrameReason).len;
const game_loop_hertz = 60;
const countdown_period_seconds = 30;
const ticker_period_seconds = 4;

const ticker_messages = [_][]const u8{
    "Backups verified on all four volumes",
    "Queue depth nominal: 3 jobs waiting",
    "Certificate renewal scheduled for Friday",
    "Replica lag 12 ms, within budget",
    "Nightly report delivered to 8 recipients",
    "Cache hit rate 97.4% over the last hour",
};

/// The sensor's counts, shared between its producer and the page.
const SensorCounts = struct {
    samples_taken: std.atomic.Value(u32) = .init(0),
    publishes: std.atomic.Value(u32) = .init(0),
};

/// Samples a slowly drifting temperature at irregular intervals, and
/// publishes it only when its tenth of a degree changed.
fn produceReadings(io: std.Io, producer: *shared.DemandedProducer, sources: *shared.Sources, waker: zui.Waker, counts: *SensorCounts) std.Io.Cancelable!void {
    var prng: std.Random.DefaultPrng = .init(0x5E50_12AD);
    const random = prng.random();
    var celsius: f32 = 21.4;
    var published_tenths: i32 = std.math.minInt(i32);
    while (producer.keepGoing()) {
        const sample = counts.samples_taken.fetchAdd(1, .monotonic) + 1;
        if (random.uintLessThan(u32, 3) == 0) celsius += (random.float(f32) - 0.5) * 0.4;
        celsius = std.math.clamp(celsius, 18, 26);
        const tenths: i32 = @intFromFloat(@round(celsius * 10));
        if (tenths != published_tenths) {
            published_tenths = tenths;
            _ = counts.publishes.fetchAdd(1, .monotonic);
            waker.wakeIf(sources.quiet_reading.publish(.{ .celsius = @as(f32, @floatFromInt(tenths)) / 10, .sample = sample }));
        }
        const gap_milliseconds = 700 + random.uintLessThan(u32, 1800);
        try io.sleep(.fromMilliseconds(gap_milliseconds), .awake);
    }
}

/// Whether the page was declared in the previous frames, kept under its id
/// so that it is evicted, and the visit starts over, once the page is left.
const VisitMarker = struct { visiting: bool };

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        const ids = struct {
            const visit: zui.Id = .of("quiet_machine.visit");
            const game_loop: zui.Id = .of("quiet_machine.game_loop");
            const reasons: zui.Id = .of("quiet_machine.reasons");
            const next_frame: zui.Id = .of("quiet_machine.next_frame");
        };

        /// A busy page that declares a frame only when something on it changes, counting them against a game loop.
        pub const QuietMachine = struct {
            tasks: std.Io.Group = .init,
            producer: shared.DemandedProducer = .{},
            sensor_counts: SensorCounts = .{},

            visit_started_at_seconds: f64 = 0,
            frames_declared_this_visit: u64 = 0,
            reasons_this_visit: [frame_reason_count]u32 = @splat(0),
            last_tallied_zui_frame: u64 = 0,
            game_loop: bool = false,
            sensor_changes_seen: u64 = 0,

            /// Declares the page into the tour's stage.
            pub fn declare(self: *QuietMachine, ui: *Ui, shell: *const Shell) void {
                self.followVisit(ui, shell);
                self.requestOnlyWhatChanges(ui, shell);
                const reading = ui.source(.quiet_reading);
                if (reading.changed()) self.sensor_changes_seen += 1;

                self.claimCard(ui, shell);
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
                    defer ui.close();
                    self.clockTile(ui, shell);
                    self.sensorTile(ui, shell, reading.get());
                    self.countdownTile(ui, shell);
                    self.tickerTile(ui, shell);
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    self.reasonsCard(ui, shell);
                    self.nextFrameCard(ui, shell);
                }
            }

            fn followVisit(self: *QuietMachine, ui: *Ui, shell: *const Shell) void {
                const marker = ui.state(ids.visit, VisitMarker);
                if (!marker.visiting) {
                    marker.visiting = true;
                    self.visit_started_at_seconds = shell.seconds;
                    self.frames_declared_this_visit = 0;
                    self.reasons_this_visit = @splat(0);
                    self.last_tallied_zui_frame = shell.perf.zui_frames;
                    self.sensor_changes_seen = 0;
                }
                self.frames_declared_this_visit += 1;
                if (shell.perf.zui_frames != self.last_tallied_zui_frame) {
                    self.last_tallied_zui_frame = shell.perf.zui_frames;
                    self.reasons_this_visit[@intFromEnum(shell.perf.latest().reason)] += 1;
                }
            }

            /// The next whole second, for the clock and everything that
            /// changes with it; the game loop asks for every refresh.
            fn requestOnlyWhatChanges(self: *const QuietMachine, ui: *Ui, shell: *const Shell) void {
                if (self.game_loop) {
                    ui.requestFrame();
                    return;
                }
                const until_next_second = @floor(shell.seconds) + 1 - shell.seconds;
                ui.requestFrameAt(ui.now().addSeconds(until_next_second));
            }

            fn secondsOnScreen(self: *const QuietMachine, shell: *const Shell) f64 {
                return @max(0, shell.seconds - self.visit_started_at_seconds);
            }

            fn claimCard(self: *QuietMachine, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                const seconds_on_screen = self.secondsOnScreen(shell);
                const game_loop_frames: u64 = @intFromFloat(@floor(seconds_on_screen * game_loop_hertz));
                const fraction: f32 = if (game_loop_frames == 0) 1 else @floatCast(@min(1, @as(f64, @floatFromInt(self.frames_declared_this_visit)) / @as(f64, @floatFromInt(game_loop_frames))));

                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(24), .child_gap = 10 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.spectacle.mix(palette.border, 0.6), .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                shell.labelColored(ui, .caption, palette.spectacle, "THE UI DID NOTHING IT DIDN'T HAVE TO");
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 16, .child_alignment = .{ .y = .end } } });
                    defer ui.close();
                    shell.printColored(ui, .hero, palette.spectacle, "{d}", .{self.frames_declared_this_visit});
                    {
                        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2, .padding = .{ .bottom = 8 } } });
                        defer ui.close();
                        var duration: [32]u8 = undefined;
                        shell.print(ui, .heading, "frames declared in {s} on screen", .{formatDuration(&duration, seconds_on_screen)});
                        const times_as_many = 1 / @max(fraction, 0.0001);
                        if (times_as_many < 1.5) {
                            shell.printColored(ui, .body, palette.muted, "A 60 Hz loop would have drawn {d} frames by now.", .{game_loop_frames});
                        } else {
                            shell.printColored(ui, .body, palette.muted, "A 60 Hz loop would have drawn {d} frames by now, {d:.0}x as many.", .{ game_loop_frames, times_as_many });
                        }
                    }
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) } } });
                    shell.label(ui, .caption, "zui");
                    ui.close();
                    shell.meter(ui, fraction, palette.spectacle, 10);
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) } } });
                    shell.label(ui, .caption, "60 Hz loop");
                    ui.close();
                    shell.meter(ui, 1, palette.faint, 10);
                }
                shell.labelColored(ui, .caption, palette.muted, "Each frame below is declared because something changed: a second passed, the sensor moved, or you touched the page. In between, the process sleeps.");
            }

            fn openTile(shell: *const Shell, ui: *Ui, title: []const u8) void {
                shell.openCard(ui, "", .{ .width = .grow, .height = .grow });
                shell.label(ui, .caption, title);
            }

            fn tileFooter(shell: *const Shell, ui: *Ui, content: []const u8) void {
                shell.labelColored(ui, .tiny, shell.palette.faint, content);
            }

            fn clockTile(self: *const QuietMachine, ui: *Ui, shell: *const Shell) void {
                _ = self;
                openTile(shell, ui, "CLOCK");
                defer ui.close();
                const whole: u64 = @intFromFloat(@max(0, @floor(shell.seconds)));
                shell.printColored(ui, .title, shell.palette.text, "{d:0>2}:{d:0>2}:{d:0>2}", .{ whole / 3600, (whole / 60) % 60, whole % 60 });
                tileFooter(shell, ui, "requestFrameAt the next second");
            }

            fn sensorTile(self: *const QuietMachine, ui: *Ui, shell: *const Shell, reading: ?Reading) void {
                openTile(shell, ui, "SENSOR");
                defer ui.close();
                if (reading) |current| {
                    shell.printColored(ui, .title, shell.palette.good, "{d:.1} C", .{current.celsius});
                } else {
                    shell.printColored(ui, .title, shell.palette.faint, "--.- C", .{});
                }
                const samples = self.sensor_counts.samples_taken.load(.monotonic);
                const publishes = self.sensor_counts.publishes.load(.monotonic);
                shell.print(ui, .tiny, "{d} samples, {d} changes woke the UI", .{ samples, publishes });
            }

            fn countdownTile(self: *const QuietMachine, ui: *Ui, shell: *const Shell) void {
                _ = self;
                openTile(shell, ui, "NEXT SYNC");
                defer ui.close();
                const whole: u64 = @intFromFloat(@max(0, @floor(shell.seconds)));
                const remaining = countdown_period_seconds - whole % countdown_period_seconds;
                shell.printColored(ui, .title, shell.palette.warn, "0:{d:0>2}", .{remaining});
                shell.meter(ui, @as(f32, @floatFromInt(remaining)) / countdown_period_seconds, shell.palette.warn, 4);
            }

            fn tickerTile(self: *const QuietMachine, ui: *Ui, shell: *const Shell) void {
                _ = self;
                shell.openCard(ui, "", .{ .width = .growWeighted(2), .height = .grow });
                defer ui.close();
                shell.label(ui, .caption, "STATUS");
                const whole: u64 = @intFromFloat(@max(0, @floor(shell.seconds)));
                const message_index: usize = @intCast((whole / ticker_period_seconds) % ticker_messages.len);
                shell.label(ui, .heading, ticker_messages[message_index]);
                tileFooter(shell, ui, "a new message every 4 s, on the clock's frame");
            }

            fn reasonsCard(self: *const QuietMachine, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                shell.openScrollingCard(ui, ids.reasons, "Why each frame was declared", .{ .width = .grow, .height = .grow });
                defer ui.close();
                shell.label(ui, .caption, "THIS VISIT");
                for (0..frame_reason_count) |reason_index| {
                    const reason: FrameReason = @enumFromInt(reason_index);
                    const count = self.reasons_this_visit[reason_index];
                    const total = @max(1, sum(&self.reasons_this_visit));
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200) } } });
                    shell.labelColored(ui, .caption, if (count == 0) palette.faint else palette.text, reason.describe());
                    ui.close();
                    shell.meter(ui, @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(total)), reasonColor(palette, reason), 6);
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(48) }, .child_alignment = .{ .x = .end } } });
                    shell.print(ui, .caption, "{d}", .{count});
                    ui.close();
                }
                shell.divider(ui);
                shell.label(ui, .caption, "THE LAST 24 FRAMES, NEWEST FIRST");
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 3 } });
                defer ui.close();
                const shown = @min(24, shell.perf.recorded);
                for (0..shown) |age| {
                    const sample = shell.perf.sampleAt(shared.Perf.history_length - 1 - age);
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .fixed(14), .height = .fixed(14) } },
                        .decoration = .{ .background = reasonColor(palette, sample.reason), .corner_radius = .all(3) },
                    });
                }
                if (shown == 0) shell.labelColored(ui, .caption, palette.faint, "no frames timed yet");
            }

            fn reasonColor(palette: shared.Palette, reason: FrameReason) zui.Color {
                return switch (reason) {
                    .first, .resize => palette.muted,
                    .input => palette.accent,
                    .requested => palette.bad,
                    .timer => palette.spectacle,
                    .source => palette.good,
                };
            }

            fn nextFrameCard(self: *QuietMachine, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                shell.openScrollingCard(ui, ids.next_frame, "What zui will do next", .{ .width = .grow, .height = .grow });
                defer ui.close();
                switch (shell.perf.next_frame) {
                    .immediately => {
                        shell.labelColored(ui, .title, palette.bad, "Draw again at once");
                        shell.labelColored(ui, .caption, palette.muted, "nextFrame() = .immediately: something asked for every refresh.");
                    },
                    .at => {
                        shell.printColored(ui, .title, palette.spectacle, "Sleep {d:.2} s", .{shell.perf.next_frame_seconds});
                        shell.labelColored(ui, .caption, palette.muted, "nextFrame() = .at, the next whole second. A sensor change or your input wakes it sooner.");
                    },
                    .on_event => {
                        shell.labelColored(ui, .title, palette.good, "Sleep until input");
                        shell.labelColored(ui, .caption, palette.muted, "nextFrame() = .on_event: nothing is due.");
                    },
                }
                shell.print(ui, .body, "{d} frames in the last second", .{shell.perf.frames_last_second});
                shell.print(ui, .caption, "{d} sensor values arrived while you watched", .{self.sensor_changes_seen});
                shell.divider(ui);
                shell.label(ui, .caption, "THE WHOLE TRICK");
                codeBlock(ui, shell, &.{
                    "ui.requestFrameAt(next_second);",
                    "waker.wakeIf(sensor.publish(reading));",
                    "// nothing else asks for a frame",
                });
                shell.divider(ui);
                _ = shell.widgets.checkbox(ui, ids.game_loop, "Compare with a game loop", &self.game_loop, .{});
                shell.labelColored(ui, .caption, palette.muted, if (self.game_loop)
                    "Now every refresh asks for a frame, as a game loop does. Watch the counter above race."
                else
                    "Turn it on to ask for a frame at every refresh, as a game loop does.");
            }

            fn codeBlock(ui: *Ui, shell: *const Shell, lines: []const []const u8) void {
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(12), .child_gap = 4 },
                    .decoration = .{ .background = shell.palette.sunken, .corner_radius = .all(6) },
                });
                defer ui.close();
                for (lines) |line| ui.text(line, .{ .size = 13 * shell.text_scale, .font = shell.fonts.mono, .color = if (std.mem.startsWith(u8, line, "//")) shell.palette.faint else shell.palette.text });
            }

            fn sum(counts: []const u32) u32 {
                var total: u32 = 0;
                for (counts) |count| total += count;
                return total;
            }

            fn formatDuration(buffer: []u8, seconds: f64) []const u8 {
                const whole: u64 = @intFromFloat(@max(0, @floor(seconds)));
                if (whole < 60) return std.fmt.bufPrint(buffer, "{d} s", .{whole}) catch "";
                return std.fmt.bufPrint(buffer, "{d} min {d} s", .{ whole / 60, whole % 60 }) catch "";
            }

            /// Runs the sensor while the page reads it, and stops it once
            /// the page is left.
            pub fn afterFrame(self: *QuietMachine, ui: *const Ui, shell: *const Shell) void {
                const unread_frames_before_stopping = 2;
                if (ui.framesSinceRead(.quiet_reading) <= unread_frames_before_stopping) {
                    if (self.producer.demand()) self.tasks.concurrent(shell.io, produceReadings, .{ shell.io, &self.producer, shell.sources, shell.waker, &self.sensor_counts }) catch {
                        self.producer.release();
                        _ = self.producer.keepGoing();
                    };
                } else self.producer.release();
            }

            /// Cancels the sensor, so the source outlives it.
            pub fn deinit(self: *QuietMachine, io: std.Io) void {
                self.tasks.cancel(io);
            }
        };
    };
}
