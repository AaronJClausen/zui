const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");
const zui_glyphs = @import("zui_glyphs");
const DemandedProducer = @import("../shared.zig").DemandedProducer;

/// The service's output as the rate sampler last measured it.
pub const Rate = struct {
    lines_per_second: f32 = 0,
    sample: u64 = 0,
    /// Lines the stream accepted and refused since the tour started.
    delivered: u32 = 0,
    refused: u32 = 0,
};

/// Published every 33 ms while the screen reads it.
pub const RateSource = zui_async.Latest(Rate);

pub const Level = enum(u8) {
    debug,
    info,
    warn,
    @"error",

    fn tag(level: Level) []const u8 {
        return switch (level) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .@"error" => "ERROR",
        };
    }
};

pub const Line = struct {
    bytes: [96]u8 = undefined,
    len: u8 = 0,
    level: Level = .info,
    sequence: u32 = 0,
    /// Since the service started.
    milliseconds: u32 = 0,

    pub fn text(line: *const Line) []const u8 {
        return line.bytes[0..line.len];
    }

    fn init(level: Level, sequence: u32, milliseconds: u32, comptime format: []const u8, arguments: anytype) Line {
        var line: Line = .{ .level = level, .sequence = sequence, .milliseconds = milliseconds };
        const written: []const u8 = std.fmt.bufPrint(&line.bytes, format, arguments) catch line.bytes[0..];
        line.len = @intCast(written.len);
        return line;
    }
};

/// The service's steady output and a burst publish at once, hence `.many`.
pub const LineSource = zui_async.Stream(Line, .{ .capacity = 256, .producers = .many });

const kept_capacity = 4096;
const rate_history_length = 120;
const burst_size = 10_000;
const rate_period_milliseconds = 33;

const ids = zui.ids(.{
    "log_tail.list",
    "log_tail.filter",
    "log_tail.follow",
    "log_tail.jump",
    "log_tail.burst",
    "log_tail.clear",
    "log_tail.rate",
    "log_tail.side",
});

/// What the producers and the screen share: the service's pace, which the
/// screen sets, and what the stream took and refused, which they count.
const Counters = struct {
    lines_per_second: std.atomic.Value(u32) = .init(400),
    next_sequence: std.atomic.Value(u32) = .init(1),
    delivered: std.atomic.Value(u32) = .init(0),
    refused: std.atomic.Value(u32) = .init(0),
    burst_delivered: std.atomic.Value(u32) = .init(0),
    burst_refused: std.atomic.Value(u32) = .init(0),
    burst_running: std.atomic.Value(bool) = .init(false),
    started_at_milliseconds: i64 = 0,

    fn publish(counters: *Counters, source: *LineSource, waker: zui.Waker, line: Line) bool {
        const wake = source.publish(line) catch {
            _ = counters.refused.fetchAdd(1, .monotonic);
            return false;
        };
        _ = counters.delivered.fetchAdd(1, .monotonic);
        waker.wakeIf(wake);
        return true;
    }

    fn millisecondsNow(counters: *const Counters, io: std.Io) u32 {
        return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).toMilliseconds() - counters.started_at_milliseconds));
    }
};

const Endpoint = struct { method: []const u8, path: []const u8 };

const endpoints = [_]Endpoint{
    .{ .method = "GET", .path = "/api/orders" },
    .{ .method = "GET", .path = "/api/customers" },
    .{ .method = "POST", .path = "/api/orders" },
    .{ .method = "GET", .path = "/api/inventory" },
    .{ .method = "PUT", .path = "/api/carts" },
};

fn serviceLine(random: std.Random, sequence: u32, milliseconds: u32) Line {
    const roll = random.uintLessThan(u32, 100);
    const endpoint = endpoints[random.uintLessThan(u32, endpoints.len)];
    const id = random.intRangeAtMost(u32, 1000, 99999);
    if (roll < 30) return .init(.debug, sequence, milliseconds, "cache hit key=customer:{d} ttl={d}s", .{ id, random.intRangeAtMost(u32, 5, 300) });
    if (roll < 85) return .init(.info, sequence, milliseconds, "{s} {s}/{d} 200 {d}ms", .{ endpoint.method, endpoint.path, id, random.intRangeAtMost(u32, 2, 90) });
    if (roll < 95) return .init(.warn, sequence, milliseconds, "slow query orders_by_customer took {d}ms (customer {d})", .{ random.intRangeAtMost(u32, 400, 2500), id });
    return .init(.@"error", sequence, milliseconds, "{s} {s}/{d} 502 upstream payments timed out after 3000ms", .{ endpoint.method, endpoint.path, id });
}

/// The service: writes lines at the pace the screen sets, in a batch every
/// 10 ms, while the screen reads them.
fn produceService(io: std.Io, producer: *DemandedProducer, counters: *Counters, source: *LineSource, waker: zui.Waker) std.Io.Cancelable!void {
    var prng: std.Random.DefaultPrng = .init(0x5EED_1065);
    const random = prng.random();
    const tick_milliseconds = 10;
    var owed: f32 = 0;
    while (producer.keepGoing()) {
        owed += @as(f32, @floatFromInt(counters.lines_per_second.load(.monotonic))) * tick_milliseconds / 1000;
        const milliseconds = counters.millisecondsNow(io);
        while (owed >= 1) : (owed -= 1) {
            const sequence = counters.next_sequence.fetchAdd(1, .monotonic);
            _ = counters.publish(source, waker, serviceLine(random, sequence, milliseconds));
        }
        try io.sleep(.fromMilliseconds(tick_milliseconds), .awake);
    }
}

/// Samples the delivered count every 33 ms and publishes the rate over
/// the last second, while the screen reads it.
fn sampleRate(io: std.Io, producer: *DemandedProducer, counters: *Counters, source: *RateSource, waker: zui.Waker) std.Io.Cancelable!void {
    const window = 1000 / rate_period_milliseconds;
    var delivered_at: [window]u32 = @splat(counters.delivered.load(.monotonic));
    var sample: u64 = 0;
    var slot: usize = 0;
    while (producer.keepGoing()) {
        sample += 1;
        slot = (slot + 1) % window;
        const delivered = counters.delivered.load(.monotonic);
        const oldest = delivered_at[slot];
        delivered_at[slot] = delivered;
        const covered_periods: f32 = @floatFromInt(@min(sample, window));
        const covered_seconds = covered_periods * rate_period_milliseconds / 1000;
        waker.wakeIf(source.publish(.{
            .lines_per_second = @as(f32, @floatFromInt(delivered -% oldest)) / covered_seconds,
            .sample = sample,
            .delivered = delivered,
            .refused = counters.refused.load(.monotonic),
        }));
        try io.sleep(.fromMilliseconds(rate_period_milliseconds), .awake);
    }
}

/// Ten thousand lines in a quarter of a second, more than a frame drains,
/// then one line saying how many the stream refused.
fn flood(io: std.Io, counters: *Counters, source: *LineSource, waker: zui.Waker) void {
    defer counters.burst_running.store(false, .release);
    var prng: std.Random.DefaultPrng = .init(0xB0057);
    const random = prng.random();
    const batches = 100;
    var refused: u32 = 0;
    for (0..batches) |_| {
        const milliseconds = counters.millisecondsNow(io);
        for (0..burst_size / batches) |_| {
            const sequence = counters.next_sequence.fetchAdd(1, .monotonic);
            if (counters.publish(source, waker, serviceLine(random, sequence, milliseconds))) {
                _ = counters.burst_delivered.fetchAdd(1, .monotonic);
            } else {
                refused += 1;
                _ = counters.burst_refused.fetchAdd(1, .monotonic);
            }
        }
        io.sleep(.fromMicroseconds(2500), .awake) catch return;
    }
    if (refused == 0) return;
    const sequence = counters.next_sequence.fetchAdd(1, .monotonic);
    const notice: Line = .init(.warn, sequence, counters.millisecondsNow(io), "log_tail: {d} lines dropped, the stream was full", .{refused});
    for (0..200) |_| {
        if (counters.publish(source, waker, notice)) return;
        io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
}

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const LogTail = struct {
            tasks: std.Io.Group = .init,
            service: DemandedProducer = .{},
            rate_sampler: DemandedProducer = .{},
            counters: Counters = .{},
            clock_started: bool = false,

            kept: [kept_capacity]Line = undefined,
            /// The slot the oldest kept line is in.
            oldest: usize = 0,
            kept_count: usize = 0,
            per_level: std.EnumArray(Level, u32) = .initFill(0),
            received: u64 = 0,
            received_this_frame: u32 = 0,

            /// Slots of the kept lines the filter lets through, oldest first.
            matches: [kept_capacity]u16 = undefined,
            match_count: usize = 0,
            matches_stale: bool = true,
            shown_levels: std.EnumSet(Level) = .initFull(),
            filter_bytes: [64]u8 = undefined,
            filter_len: usize = 0,

            following: bool = true,
            arrived_while_held: u32 = 0,
            rate_history: [rate_history_length]f32 = @splat(0),
            rate_newest: usize = 0,
            pace: u32 = 400,

            pub fn declare(self: *LogTail, ui: *Ui, shell: *const Shell) void {
                self.receive(ui);
                const rate = ui.source(.log_rate);
                if (rate.changed()) if (rate.get()) |reading| {
                    self.rate_newest = (self.rate_newest + 1) % rate_history_length;
                    self.rate_history[self.rate_newest] = reading.lines_per_second;
                };

                shell.label(ui, .body, "Follow a service writing hundreds of lines a second, and bursts of thousands, without the UI falling behind.");
                self.toolbar(ui, shell);
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                self.logView(ui, shell);
                self.sidePanel(ui, shell, rate.get() orelse Rate{});
            }

            fn receive(self: *LogTail, ui: *Ui) void {
                var lines = ui.source(.log_lines).items();
                self.received_this_frame = 0;
                while (lines.next()) |line| {
                    self.keep(line.*);
                    self.received_this_frame += 1;
                }
                if (self.received_this_frame == 0) return;
                self.received += self.received_this_frame;
                self.matches_stale = true;
                if (!self.following) self.arrived_while_held +|= self.received_this_frame;
            }

            fn keep(self: *LogTail, line: Line) void {
                if (self.kept_count == kept_capacity) {
                    self.per_level.getPtr(self.kept[self.oldest].level).* -= 1;
                    self.kept[self.oldest] = line;
                    self.oldest = (self.oldest + 1) % kept_capacity;
                } else {
                    self.kept[(self.oldest + self.kept_count) % kept_capacity] = line;
                    self.kept_count += 1;
                }
                self.per_level.getPtr(line.level).* += 1;
            }

            fn filter(self: *const LogTail) []const u8 {
                return self.filter_bytes[0..self.filter_len];
            }

            fn refreshMatches(self: *LogTail) void {
                self.match_count = 0;
                const needle = self.filter();
                for (0..self.kept_count) |age| {
                    const slot = (self.oldest + age) % kept_capacity;
                    const line = &self.kept[slot];
                    if (!self.shown_levels.contains(line.level)) continue;
                    if (needle.len != 0 and std.ascii.findIgnoreCase(line.text(), needle) == null) continue;
                    self.matches[self.match_count] = @intCast(slot);
                    self.match_count += 1;
                }
                self.matches_stale = false;
            }

            /// The first match at or after `sequence`, so a held view stays
            /// on the line it showed while older lines leave the ring.
            fn matchIndexOf(self: *const LogTail, sequence: u32) usize {
                var low: usize = 0;
                var high = self.match_count;
                while (low < high) {
                    const middle = (low + high) / 2;
                    if (self.kept[self.matches[middle]].sequence < sequence) low = middle + 1 else high = middle;
                }
                return low;
            }

            fn toolbar(self: *LogTail, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                for (std.enums.values(Level)) |level| self.levelToggle(ui, shell, level);
                var filter_text: kit.zui_widgets.EditableText = .{ .buffer = &self.filter_bytes, .len = self.filter_len };
                if (widgets.textField(ui, ids.@"log_tail.filter", &filter_text, .{ .placeholder = "Filter, e.g. 502 or orders", .label = "Filter", .width = .fixed(240) }).changed) self.matches_stale = true;
                self.filter_len = filter_text.len;
                shell.spacer(ui);
                if (widgets.button(ui, ids.@"log_tail.follow", if (self.following) "Pause" else "Resume", .{ .variant = .secondary })) {
                    if (self.following) self.hold() else self.follow();
                }
                const burst_running = self.counters.burst_running.load(.acquire);
                if (widgets.button(ui, ids.@"log_tail.burst", "Burst 10,000", .{ .disabled = burst_running })) self.startBurst(shell);
                if (widgets.button(ui, ids.@"log_tail.clear", "Clear", .{ .variant = .secondary })) self.clear();
            }

            fn levelToggle(self: *LogTail, ui: *Ui, shell: *const Shell, level: Level) void {
                const colors = shell.colors;
                const id: zui.Id = .indexed("log_tail.level", @intFromEnum(level));
                if (ui.clicked(id)) {
                    self.shown_levels.toggle(level);
                    self.matches_stale = true;
                }
                const shown = self.shown_levels.contains(level);
                const emphasis = levelEmphasis(level);
                const state = ui.widgetState(id);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .semantics = .{ .role = .toggle, .label = level.tag(), .state = .{ .checked = shown } },
                    .layout = .{ .sizing = .{ .height = .fitBetween(shell.tokens.target_floors.get(.pointer), std.math.inf(f32)) }, .padding = .symmetric(10, 5), .child_gap = 8, .child_alignment = .{ .y = .center } },
                    .decoration = .{
                        .background = if (shown) emphasis.container(colors) else if (state == .hovered) colors.get(.secondary_container) else colors.get(.surface),
                        .border = .{ .color = if (ui.focused(id)) colors.get(.focus) else if (shown) emphasis.fill(colors) else colors.get(.outline_muted), .widths = .all(1) },
                        .corner_radius = .all(12),
                    },
                });
                defer ui.close();
                shell.labelColored(ui, .caption, if (shown) emphasis.onContainer(colors) else colors.get(.on_surface_muted), std.mem.trimEnd(u8, level.tag(), " "));
                shell.printColored(ui, .caption, if (shown) emphasis.onContainer(colors) else colors.get(.on_surface_muted), "{d}", .{self.per_level.get(level)});
            }

            fn hold(self: *LogTail) void {
                self.following = false;
                self.arrived_while_held = 0;
            }

            fn follow(self: *LogTail) void {
                self.following = true;
                self.arrived_while_held = 0;
            }

            fn clear(self: *LogTail) void {
                self.kept_count = 0;
                self.oldest = 0;
                self.per_level = .initFill(0);
                self.matches_stale = true;
            }

            fn startBurst(self: *LogTail, shell: *const Shell) void {
                self.startClock(shell.io);
                self.counters.burst_delivered.store(0, .monotonic);
                self.counters.burst_refused.store(0, .monotonic);
                self.counters.burst_running.store(true, .release);
                self.tasks.concurrent(shell.io, flood, .{ shell.io, &self.counters, &shell.sources.log_lines, shell.waker }) catch self.counters.burst_running.store(false, .release);
            }

            /// A terminal's rows are whole cells, so a row there is one cell tall.
            fn rowHeight(ui: *Ui, shell: *const Shell) f32 {
                return switch (comptime zui_glyphs.placementOf(kit.Renderer)) {
                    .cells => |cell| cell[1],
                    .pixel_grid => @round(ui.measureText("M", monoStyle(shell, shell.colors.get(.on_surface)))[1] + 6),
                };
            }

            fn logView(self: *LogTail, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                const list_id = ids.@"log_tail.list";
                const row_height = rowHeight(ui, shell);
                const viewport = ui.rectOf(list_id) orelse zui.Rect{ .width = 800, .height = 560 };
                const previous_offset = ui.scrollOffset(list_id)[1];
                const anchor_index: usize = @intFromFloat(@max(0, @floor(previous_offset / row_height)));
                const anchor_sequence: ?u32 = if (anchor_index < self.match_count) self.kept[self.matches[anchor_index]].sequence else null;
                const previous_bottom = @max(0, @as(f32, @floatFromInt(self.match_count)) * row_height - viewport.height);

                if (ui.manipulation(list_id) != null) {
                    if (previous_offset >= previous_bottom - 1) self.follow() else if (self.following) self.hold();
                }
                if (self.matches_stale) self.refreshMatches();

                const content_height = @as(f32, @floatFromInt(self.match_count)) * row_height;
                const bottom = @max(0, content_height - viewport.height);
                var offset = previous_offset;
                if (self.following) {
                    offset = bottom;
                } else if (anchor_sequence) |sequence| {
                    offset = @as(f32, @floatFromInt(self.matchIndexOf(sequence))) * row_height + (previous_offset - @as(f32, @floatFromInt(anchor_index)) * row_height);
                }
                offset = std.math.clamp(offset, 0, bottom);
                ui.setScrollOffset(list_id, .{ 0, offset });

                const first: usize = @intFromFloat(@floor(offset / row_height));
                const last: usize = @min(self.match_count, @as(usize, @intFromFloat(@ceil((offset + viewport.height) / row_height))) + 1);

                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
                    .decoration = .{ .background = colors.get(.surface_sunken), .corner_radius = .all(8) },
                });
                defer ui.close();
                {
                    ui.open(.{
                        .id = list_id,
                        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
                        .scroll = .{},
                        .semantics = .{ .role = .scroll_area, .label = "Log" },
                    });
                    defer ui.close();
                    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first)) * row_height) } } });
                    for (first..last) |index| self.row(ui, shell, &self.kept[self.matches[index]], row_height);
                    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(self.match_count - last)) * row_height) } } });
                    if (self.match_count == 0) {
                        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(16) } });
                        shell.labelColored(ui, .body, colors.get(.on_surface_muted), if (self.kept_count == 0) "Waiting for the service's first line..." else "No line matches the filter.");
                        ui.close();
                    }
                }
                self.statusBar(ui, shell, first, last);
            }

            fn row(self: *LogTail, ui: *Ui, shell: *const Shell, line: *const Line, row_height: f32) void {
                const colors = shell.colors;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(row_height) }, .padding = .symmetric(12, 0), .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                const seconds = line.milliseconds / 1000;
                var time_buffer: [16]u8 = undefined;
                const time = std.fmt.bufPrint(&time_buffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ 9 + seconds / 3600, seconds / 60 % 60, seconds % 60, line.milliseconds % 1000 }) catch "";
                ui.text(time, monoStyle(shell, colors.get(.on_surface_muted)));
                ui.text(line.level.tag(), monoStyle(shell, levelEmphasis(line.level).text(colors)));
                const message_color = if (line.level == .@"error") colors.get(.on_danger_container) else colors.get(.on_surface);
                const needle = self.filter();
                const found = if (needle.len == 0) null else std.ascii.findIgnoreCase(line.text(), needle);
                const message = line.text();
                if (found) |start| {
                    ui.open(.{ .layout = .{ .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    if (start != 0) ui.text(message[0..start], monoStyle(shell, message_color));
                    ui.open(.{ .decoration = .{ .background = colors.get(.warning_container), .corner_radius = .all(2) } });
                    ui.text(message[start..][0..needle.len], monoStyle(shell, colors.get(.on_surface)));
                    ui.close();
                    if (start + needle.len < message.len) ui.text(message[start + needle.len ..], monoStyle(shell, message_color));
                } else ui.text(message, monoStyle(shell, message_color));
            }

            fn statusBar(self: *LogTail, ui: *Ui, shell: *const Shell, first: usize, last: usize) void {
                const colors = shell.colors;
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(12, 6), .child_gap = 12, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = colors.get(.surface_raised), .corner_radius = .{ .bottom_left = 8, .bottom_right = 8 } },
                });
                defer ui.close();
                if (self.following) {
                    shell.labelColored(ui, .caption, colors.get(.on_success_container), "Following the newest line");
                } else {
                    shell.printColored(ui, .caption, colors.get(.on_warning_container), "Held: {d} new lines below", .{self.arrived_while_held});
                }
                shell.spacer(ui);
                shell.printColored(ui, .caption, colors.get(.on_surface_muted), "lines {d}-{d} of {d} shown", .{ @min(first + 1, last), last, self.match_count });
                if (!self.following and shell.widgets.button(ui, ids.@"log_tail.jump", "Jump to latest", .{})) self.follow();
            }

            fn sidePanel(self: *LogTail, ui: *Ui, shell: *const Shell, rate: Rate) void {
                const colors = shell.colors;
                ui.open(.{
                    .id = ids.@"log_tail.side",
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300), .height = .grow }, .child_gap = 12 },
                    .scroll = .{},
                });
                defer ui.close();
                {
                    shell.openCard(ui, "Rate", .{ .width = .grow });
                    defer ui.close();
                    shell.printColored(ui, .title, colors.get(.on_surface_accent), "{d:.0} lines/s", .{rate.lines_per_second});
                    self.rateChart(ui, shell);
                    shell.label(ui, .caption, "Sampled every 33 ms through a Latest source: the UI shows the newest sample and skips any it missed.");
                    shell.widgets.labeledRow(ui, "Service pace");
                    _ = shell.widgets.slider(ui, ids.@"log_tail.rate", &self.pace, .{ .min = 0, .max = 4000, .step = 50, .label = "Service pace" });
                    ui.close();
                    self.counters.lines_per_second.store(self.pace, .monotonic);
                    shell.printColored(ui, .caption, colors.get(.on_surface_muted), "{d} lines/s asked of the service", .{self.pace});
                }
                {
                    shell.openCard(ui, "Stream", .{ .width = .grow });
                    defer ui.close();
                    statRow(ui, shell, "received this frame", self.received_this_frame, colors.get(.on_surface));
                    statRow(ui, shell, "received in all", self.received, colors.get(.on_surface));
                    statRow(ui, shell, "kept in the ring", self.kept_count, colors.get(.on_surface));
                    statRow(ui, shell, "refused by the stream", rate.refused, if (rate.refused == 0) colors.get(.on_success_container) else colors.get(.on_danger_container));
                    shell.label(ui, .caption, "The stream holds 256 lines between frames. The ring keeps the newest 4,096; only the rows in view are declared.");
                }
                {
                    shell.openCard(ui, "Last burst", .{ .width = .grow });
                    defer ui.close();
                    const delivered = self.counters.burst_delivered.load(.monotonic);
                    const refused = self.counters.burst_refused.load(.monotonic);
                    if (delivered + refused == 0) {
                        shell.label(ui, .caption, "Burst sends 10,000 lines in a quarter of a second, more than the stream holds between frames.");
                    } else {
                        statRow(ui, shell, "sent", delivered + refused, colors.get(.on_surface));
                        statRow(ui, shell, "delivered", delivered, colors.get(.on_success_container));
                        statRow(ui, shell, "dropped, stream full", refused, if (refused == 0) colors.get(.on_success_container) else colors.get(.on_danger_container));
                        shell.meter(ui, @as(f32, @floatFromInt(delivered)) / @as(f32, @floatFromInt(delivered + refused)), colors.get(.success), 6);
                    }
                }
                shell.printColored(ui, .caption, colors.get(.on_surface_muted), "framesSinceRead(.log_lines) = {d}", .{ui.framesSinceRead(.log_lines)});
            }

            fn rateChart(self: *LogTail, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                var tallest: f32 = 100;
                for (self.rate_history) |value| tallest = @max(tallest, value);
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(64) }, .padding = .all(4), .child_alignment = .{ .y = .end } },
                    .decoration = .{ .background = colors.get(.surface_sunken), .corner_radius = .all(6) },
                    .clip = .both,
                });
                defer ui.close();
                for (0..rate_history_length) |age| {
                    const value = self.rate_history[(self.rate_newest + 1 + age) % rate_history_length];
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .growWeighted(1), .height = .percent(std.math.clamp(value / tallest, 0.02, 1)) } },
                        .decoration = .{ .background = colors.get(.accent) },
                    });
                }
            }

            fn startClock(self: *LogTail, io: std.Io) void {
                if (self.clock_started) return;
                self.clock_started = true;
                self.counters.started_at_milliseconds = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            }

            /// Starts the service and the rate sampler while the screen reads
            /// their sources, and lets them stop once it does not.
            pub fn afterFrame(self: *LogTail, ui: *const Ui, shell: *const Shell) void {
                const unread_frames_before_stopping = 2;
                if (ui.framesSinceRead(.log_lines) <= unread_frames_before_stopping) {
                    self.startClock(shell.io);
                    if (self.service.demand()) self.tasks.concurrent(shell.io, produceService, .{ shell.io, &self.service, &self.counters, &shell.sources.log_lines, shell.waker }) catch {
                        self.service.release();
                        _ = self.service.keepGoing();
                    };
                } else self.service.release();

                if (ui.framesSinceRead(.log_rate) <= unread_frames_before_stopping) {
                    if (self.rate_sampler.demand()) self.tasks.concurrent(shell.io, sampleRate, .{ shell.io, &self.rate_sampler, &self.counters, &shell.sources.log_rate, shell.waker }) catch {
                        self.rate_sampler.release();
                        _ = self.rate_sampler.keepGoing();
                    };
                } else self.rate_sampler.release();
            }

            pub fn deinit(self: *LogTail, io: std.Io) void {
                self.tasks.cancel(io);
            }
        };

        fn monoStyle(shell: *const Shell, color: zui.Color) Ui.TextStyle {
            return .{ .size = 13 * shell.text_scale, .font = shell.fonts.mono, .color = color, .wrap = .none };
        }

        fn levelEmphasis(level: Level) kit.Emphasis {
            return switch (level) {
                .debug => .neutral,
                .info => .accent,
                .warn => .warning,
                .@"error" => .danger,
            };
        }

        fn statRow(ui: *Ui, shell: *const Shell, name: []const u8, value: anytype, color: zui.Color) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
            defer ui.close();
            shell.label(ui, .caption, name);
            shell.spacer(ui);
            shell.printColored(ui, .caption, color, "{d}", .{value});
        }
    };
}
