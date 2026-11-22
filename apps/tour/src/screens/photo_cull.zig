const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

/// One photo of the shoot, as its made-up decode produces it: a landscape
/// of a sky, a sun and two hills, all derived from its number.
pub const Photo = struct {
    sky_top: zui.Color,
    sky_bottom: zui.Color,
    sun: zui.Color,
    far_hill: zui.Color,
    near_hill: zui.Color,
    /// Fractions of the photo's height and width.
    horizon: f32,
    sun_across: f32,
    sun_down: f32,
    sun_size: f32,
    hill_curve: f32,
};

pub const PhotoError = error{
    /// The photo scrolled away before its decode finished.
    Canceled,
    /// The `Io` had no thread to spare, and decoding inline would block the UI.
    NoThreadAvailable,
};

pub const photo_count = 5000;

/// Enough slots for a screenful plus what waits to be released after a
/// fast scroll.
pub const PhotoLoads = zui_async.KeyedLoads(u32, PhotoError!Photo, .{ .capacity = 512, .unread_frames_before_release = 20, .Progress = f32 });

/// What became of every decode since the tour started.
pub const PhotoOutcomes = struct {
    loaded: u32 = 0,
    abandoned: u32 = 0,
};

/// The counts come through a source rather than straight from the
/// decoders, so a recorded frame carries them and replays the same.
pub const PhotoOutcomesSource = zui_async.Latest(PhotoOutcomes);

/// `Latest.publish` takes one producer at a time; counting and publishing
/// under one lock also keeps a stale count from landing last.
const OutcomeTally = struct {
    mutex: std.Io.Mutex = .init,
    outcomes: PhotoOutcomes = .{},

    fn count(self: *OutcomeTally, io: std.Io, source: *PhotoOutcomesSource, waker: zui.Waker, result: PhotoError!Photo) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (result) |_| {
            self.outcomes.loaded += 1;
        } else |err| switch (err) {
            error.Canceled => self.outcomes.abandoned += 1,
            error.NoThreadAvailable => return,
        }
        waker.wakeIf(source.publish(self.outcomes));
    }
};

fn runDecode(outcome_tally: *OutcomeTally, io: std.Io, outcomes: *PhotoOutcomesSource, waker: zui.Waker, load: PhotoLoads.Load) void {
    const result = decodePhoto(io, load);
    outcome_tally.count(io, outcomes, waker, result);
    load.finish(result);
}

fn randomFor(index: u32) std.Random.DefaultPrng {
    return .init(@as(u64, index) *% 0x9E3779B97F4A7C15 +% 11);
}

/// A slow, made-up decode: sleeps in steps, reporting progress and stopping
/// early once nobody shows the photo, then derives the picture from its
/// number.
fn decodePhoto(io: std.Io, load: PhotoLoads.Load) PhotoError!Photo {
    var prng = randomFor(load.key);
    const random = prng.random();
    const total_milliseconds = random.intRangeAtMost(u32, 120, 600);
    const step_milliseconds = 30;
    var elapsed_milliseconds: u32 = 0;
    while (elapsed_milliseconds < total_milliseconds) {
        if (load.abandoned()) return error.Canceled;
        const step = @min(step_milliseconds, total_milliseconds - elapsed_milliseconds);
        io.sleep(.fromMilliseconds(step), .awake) catch return error.Canceled;
        elapsed_milliseconds += step;
        load.progress(@as(f32, @floatFromInt(elapsed_milliseconds)) / @as(f32, @floatFromInt(total_milliseconds)));
    }
    return paint(random);
}

fn paint(random: std.Random) Photo {
    const hour = random.float(f32);
    const sky_hue = 0.52 + 0.12 * random.float(f32) - 0.45 * @max(0, hour - 0.7);
    const land_hue = 0.22 + 0.15 * random.float(f32);
    const daylight = 0.35 + 0.55 * (1 - @abs(hour - 0.45));
    return .{
        .sky_top = hueColor(sky_hue, 0.55, daylight * 0.8),
        .sky_bottom = hueColor(sky_hue - 0.5 * hour * hour, 0.35 + 0.3 * hour, @min(1, daylight + 0.15)),
        .sun = hueColor(0.1 + 0.05 * (1 - hour), 0.25 + 0.5 * hour, 1),
        .far_hill = hueColor(land_hue + 0.08, 0.3, daylight * 0.55),
        .near_hill = hueColor(land_hue, 0.55, daylight * 0.4),
        .horizon = 0.5 + 0.2 * random.float(f32),
        .sun_across = 0.08 + 0.7 * random.float(f32),
        .sun_down = 0.15 + 0.45 * random.float(f32),
        .sun_size = 0.1 + 0.1 * random.float(f32),
        .hill_curve = 0.3 + 0.7 * random.float(f32),
    };
}

fn hueColor(hue: f32, saturation: f32, value: f32) zui.Color {
    const wrapped = hue - @floor(hue);
    const sector = wrapped * 6;
    const chroma = value * saturation;
    const secondary = chroma * (1 - @abs(@mod(sector, 2) - 1));
    const lightness_offset = value - chroma;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(@min(sector, 5.999)))) {
        0 => .{ chroma, secondary, 0 },
        1 => .{ secondary, chroma, 0 },
        2 => .{ 0, chroma, secondary },
        3 => .{ 0, secondary, chroma },
        4 => .{ secondary, 0, chroma },
        else => .{ chroma, 0, secondary },
    };
    return .{
        .r = @intFromFloat((rgb[0] + lightness_offset) * 255),
        .g = @intFromFloat((rgb[1] + lightness_offset) * 255),
        .b = @intFromFloat((rgb[2] + lightness_offset) * 255),
    };
}

/// What the camera wrote beside each photo, which needs no decode.
const Exposure = struct {
    shutter_denominator: u32,
    aperture: f32,
    iso: u32,
    focal_millimeters: u32,

    fn of(index: u32) Exposure {
        var prng: std.Random.DefaultPrng = .init(@as(u64, index) *% 0xD1B54A32D192ED03 +% 5);
        const random = prng.random();
        const shutters = [_]u32{ 60, 125, 250, 500, 1000, 2000 };
        const apertures = [_]f32{ 1.8, 2.8, 4, 5.6, 8, 11 };
        const isos = [_]u32{ 100, 200, 400, 800, 1600 };
        const focals = [_]u32{ 24, 35, 50, 85, 135 };
        return .{
            .shutter_denominator = shutters[random.uintLessThan(usize, shutters.len)],
            .aperture = apertures[random.uintLessThan(usize, apertures.len)],
            .iso = isos[random.uintLessThan(usize, isos.len)],
            .focal_millimeters = focals[random.uintLessThan(usize, focals.len)],
        };
    }
};

const Verdict = enum(u8) { unsorted, picked, rejected };

const PhotoDrag = struct { index: u32 };

/// The last verdicts given, newest last, so Ctrl+Z takes them back in
/// order; the oldest falls off once it is full.
const UndoRing = struct {
    const capacity = 64;

    const Change = struct { index: u32, before: Verdict };

    changes: [capacity]Change = undefined,
    newest: usize = capacity - 1,
    len: usize = 0,

    fn push(self: *UndoRing, change: Change) void {
        self.newest = (self.newest + 1) % capacity;
        self.changes[self.newest] = change;
        self.len = @min(self.len + 1, capacity);
    }

    fn pop(self: *UndoRing) ?Change {
        if (self.len == 0) return null;
        const change = self.changes[self.newest];
        self.newest = (self.newest + capacity - 1) % capacity;
        self.len -= 1;
        return change;
    }
};

const ids = zui.ids(.{
    "photo_cull.grid",
    "photo_cull.track",
    "photo_cull.side",
    "photo_cull.picks",
    "photo_cull.rejects",
    "photo_cull.ghost",
    "photo_cull.undo",
    "photo_cull.top",
    "photo_cull.next_unsorted",
});

const thumbnail_width = 128;
const thumbnail_height = 96;
const caption_height = 22;
const tile_gap = 8;
const tile_pitch = thumbnail_height + caption_height + tile_gap;
const side_width = 300;
const loupe_height = 201;

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const PhotoCull = struct {
            tasks: std.Io.Group = .init,
            outcome_tally: OutcomeTally = .{},
            decodes_started: u32 = 0,

            verdicts: [photo_count]Verdict = @splat(.unsorted),
            picked: u32 = 0,
            rejected: u32 = 0,
            undo: UndoRing = .{},
            selected: u32 = 0,
            columns: u32 = 1,
            /// Set when the keyboard moves the selection, so the grid
            /// scrolls it into view once.
            reveal_selected: bool = false,

            pub fn declare(self: *PhotoCull, ui: *Ui, shell: *const Shell) void {
                self.handleKeys(ui);
                const photos = ui.source(.photos);

                self.intro(ui, shell);
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();

                var on_screen: std.EnumArray(std.meta.Tag(PhotoLoads.Status), u32) = .initFill(0);
                var dragged: ?u32 = null;
                const visible_rows = self.grid(ui, shell, photos, &on_screen, &dragged);
                self.sidePanel(ui, shell, photos, on_screen, visible_rows);
                if (dragged) |index| dragGhost(ui, shell, index, photos.get(index));
            }

            fn intro(self: *PhotoCull, ui: *Ui, shell: *const Shell) void {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
                shell.label(ui, .body, "Triage 5,000 photos from a shoot without waiting on disk.");
                shell.label(ui, .caption, "Arrows move  ·  P pick  ·  X reject  ·  U clear  ·  Ctrl+Z undo  ·  or drag a photo onto a bin");
                ui.close();
                if (shell.widgets.button(ui, ids.@"photo_cull.next_unsorted", "Next unsorted", .{})) self.selectNextUnsorted();
                if (shell.widgets.button(ui, ids.@"photo_cull.undo", "Undo", .{ .disabled = self.undo.len == 0 })) self.undoLast();
                if (shell.widgets.button(ui, ids.@"photo_cull.top", "Top", .{})) {
                    self.selected = 0;
                    ui.setScrollOffset(ids.@"photo_cull.grid", .{ 0, 0 });
                }
            }

            fn handleKeys(self: *PhotoCull, ui: *Ui) void {
                const last = photo_count - 1;
                for (ui.keyEvents()) |key_event| {
                    if (key_event.modifiers.control) {
                        if (key_event.key == .z and !key_event.modifiers.shift and !key_event.modifiers.alt) self.undoLast();
                        continue;
                    }
                    if (key_event.modifiers.alt or key_event.modifiers.super) continue;
                    const before = self.selected;
                    switch (key_event.key) {
                        .left => self.selected -|= 1,
                        .right => self.selected = @min(last, self.selected + 1),
                        .up => self.selected -|= self.columns,
                        .down => self.selected = @min(last, self.selected + self.columns),
                        .home => self.selected = 0,
                        .end => self.selected = last,
                        .p => self.judge(self.selected, .picked),
                        .x => self.judge(self.selected, .rejected),
                        .u => self.judge(self.selected, .unsorted),
                        else => {},
                    }
                    if (self.selected != before) self.reveal_selected = true;
                }
            }

            fn judge(self: *PhotoCull, index: u32, verdict: Verdict) void {
                const before = self.verdicts[index];
                if (before == verdict) return;
                self.undo.push(.{ .index = index, .before = before });
                self.setVerdict(index, verdict);
            }

            fn undoLast(self: *PhotoCull) void {
                const change = self.undo.pop() orelse return;
                self.setVerdict(change.index, change.before);
                self.selected = change.index;
                self.reveal_selected = true;
            }

            fn setVerdict(self: *PhotoCull, index: u32, verdict: Verdict) void {
                switch (self.verdicts[index]) {
                    .picked => self.picked -= 1,
                    .rejected => self.rejected -= 1,
                    .unsorted => {},
                }
                switch (verdict) {
                    .picked => self.picked += 1,
                    .rejected => self.rejected += 1,
                    .unsorted => {},
                }
                self.verdicts[index] = verdict;
            }

            fn selectNextUnsorted(self: *PhotoCull) void {
                for (1..photo_count) |step| {
                    const index: u32 = @intCast((self.selected + step) % photo_count);
                    if (self.verdicts[index] == .unsorted) {
                        self.selected = index;
                        self.reveal_selected = true;
                        return;
                    }
                }
            }

            const RowRange = struct { first: u32, last: u32, total: u32 };

            fn grid(self: *PhotoCull, ui: *Ui, shell: *const Shell, photos: anytype, on_screen: anytype, dragged: *?u32) RowRange {
                const palette = shell.palette;
                const grid_id = ids.@"photo_cull.grid";
                const viewport = ui.rectOf(grid_id) orelse zui.Rect{ .width = 840, .height = 600 };
                self.columns = @max(1, @as(u32, @intFromFloat((viewport.width - tile_gap) / (thumbnail_width + tile_gap))));
                const columns = self.columns;
                const total_rows = (photo_count + columns - 1) / columns;
                const content_height = @as(f32, @floatFromInt(total_rows)) * tile_pitch + tile_gap;

                if (self.reveal_selected) {
                    self.reveal_selected = false;
                    const row_top = @as(f32, @floatFromInt(self.selected / columns)) * tile_pitch;
                    var offset = ui.scrollOffset(grid_id);
                    if (row_top < offset[1]) offset[1] = row_top;
                    if (row_top + tile_pitch + tile_gap > offset[1] + viewport.height) offset[1] = row_top + tile_pitch + tile_gap - viewport.height;
                    ui.setScrollOffset(grid_id, offset);
                }
                const offset = ui.scrollOffset(grid_id)[1];
                const first_row: u32 = @intFromFloat(@max(0, @floor(offset / tile_pitch) - 1));
                const last_row: u32 = @min(total_rows, @as(u32, @intFromFloat(@max(0, @ceil((offset + viewport.height) / tile_pitch)))) + 1);

                ui.open(.{
                    .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 4 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                {
                    ui.open(.{
                        .id = grid_id,
                        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .{ .left = tile_gap, .top = tile_gap } },
                        .scroll = .{},
                        .semantics = .{ .role = .list_box, .label = "Photos" },
                    });
                    defer ui.close();
                    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first_row)) * tile_pitch) } } });
                    for (first_row..last_row) |row| {
                        ui.open(.{ .layout = .{ .sizing = .{ .height = .fixed(tile_pitch) }, .child_gap = tile_gap } });
                        defer ui.close();
                        const first_index = row * columns;
                        for (first_index..@min(first_index + columns, photo_count)) |index_usize| {
                            const index: u32 = @intCast(index_usize);
                            const status = photos.get(index);
                            on_screen.getPtr(std.meta.activeTag(status)).* += 1;
                            if (self.tile(ui, shell, index, status)) dragged.* = index;
                        }
                    }
                    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(total_rows - last_row)) * tile_pitch) } } });
                }
                scrollTrack(ui, shell, offset, viewport.height, content_height);
                return .{ .first = first_row, .last = last_row, .total = total_rows };
            }

            /// Returns whether a pointer is dragging the photo.
            fn tile(self: *PhotoCull, ui: *Ui, shell: *const Shell, index: u32, status: PhotoLoads.Status) bool {
                const palette = shell.palette;
                const id: zui.Id = .indexed("photo_cull.photo", index);
                const verdict = self.verdicts[index];
                const is_selected = index == self.selected;
                if (ui.clicked(id)) self.selected = index;
                const is_dragged = ui.dragging(id) != null;
                if (is_dragged) ui.startDrag(id, PhotoDrag{ .index = index });

                const ring: ?zui.Color = if (is_selected) palette.accent else switch (verdict) {
                    .picked => palette.good,
                    .rejected => palette.bad,
                    .unsorted => if (ui.hovered(id)) palette.faint else null,
                };
                var name_buffer: [16]u8 = undefined;
                ui.open(.{
                    .id = id,
                    .interactive = true,
                    .cursor = if (is_dragged) .grabbing else .pointer,
                    .gestures = .{ .drag = true },
                    .semantics = .{ .role = .option, .label = photoName(&name_buffer, index), .state = .{ .selected = is_selected } },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(thumbnail_width), .height = .fixed(thumbnail_height + caption_height) }, .child_gap = 2 },
                });
                defer ui.close();
                {
                    ui.open(.{
                        .layout = .{ .sizing = .{ .width = .fixed(thumbnail_width), .height = .fixed(thumbnail_height) }, .padding = .all(if (ring != null) 2 else 0) },
                        .decoration = .{ .background = ring, .corner_radius = .all(6) },
                    });
                    defer ui.close();
                    const inner_width: f32 = if (ring != null) thumbnail_width - 4 else thumbnail_width;
                    const inner_height: f32 = if (ring != null) thumbnail_height - 4 else thumbnail_height;
                    picture(ui, shell, status, .{ inner_width, inner_height }, 4);
                    if (verdict == .rejected) {
                        var veil = palette.background;
                        veil.a = 170;
                        ui.box(.{
                            .floating = .{ .offset = .{ 2, 2 }, .clip = .target, .capture = false },
                            .layout = .{ .sizing = .{ .width = .fixed(inner_width), .height = .fixed(inner_height) } },
                            .decoration = .{ .background = veil, .corner_radius = .all(4) },
                        });
                    }
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(caption_height) }, .padding = .{ .left = 2, .right = 2 }, .child_gap = 4, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.labelColored(ui, .tiny, if (is_selected) palette.text else palette.muted, photoName(&name_buffer, index));
                    shell.spacer(ui);
                    switch (verdict) {
                        .picked => shell.labelColored(ui, .tiny, palette.good, "PICK"),
                        .rejected => shell.labelColored(ui, .tiny, palette.bad, "REJECT"),
                        .unsorted => {},
                    }
                }
                return is_dragged;
            }

            fn sidePanel(self: *PhotoCull, ui: *Ui, shell: *const Shell, photos: anytype, on_screen: anytype, rows: RowRange) void {
                const palette = shell.palette;
                ui.open(.{
                    .id = ids.@"photo_cull.side",
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(side_width), .height = .grow }, .child_gap = 12 },
                    .scroll = .{},
                });
                defer ui.close();

                {
                    shell.openCard(ui, "", .{ .width = .grow });
                    defer ui.close();
                    var name_buffer: [16]u8 = undefined;
                    const status = photos.get(self.selected);
                    picture(ui, shell, status, .{ side_width - 34, loupe_height }, 6);
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    shell.label(ui, .heading, photoName(&name_buffer, self.selected));
                    shell.spacer(ui);
                    switch (self.verdicts[self.selected]) {
                        .picked => shell.chip(ui, "Picked", palette.good),
                        .rejected => shell.chip(ui, "Rejected", palette.bad),
                        .unsorted => shell.chip(ui, "Unsorted", palette.muted),
                    }
                    ui.close();
                    const exposure: Exposure = .of(self.selected);
                    shell.printColored(ui, .caption, palette.muted, "1/{d} s  ·  f/{d:.1}  ·  ISO {d}  ·  {d} mm", .{ exposure.shutter_denominator, exposure.aperture, exposure.iso, exposure.focal_millimeters });
                }

                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
                    defer ui.close();
                    self.bin(ui, shell, ids.@"photo_cull.picks", "Picks", self.picked, .picked, palette.good);
                    self.bin(ui, shell, ids.@"photo_cull.rejects", "Rejects", self.rejected, .rejected, palette.bad);
                }
                const sorted = self.picked + self.rejected;
                shell.printColored(ui, .caption, palette.muted, "{d} of {d} sorted, {d} to go", .{ sorted, photo_count, photo_count - sorted });
                shell.meter(ui, @as(f32, @floatFromInt(sorted)) / photo_count, palette.accent, 6);

                {
                    shell.openCard(ui, "Decoding", .{ .width = .grow });
                    defer ui.close();
                    shell.print(ui, .caption, "Rows {d}-{d} of {d} declared, {d} photos of {d}", .{ rows.first + 1, rows.last, rows.total, (rows.last - rows.first) * self.columns, photo_count });
                    legendRow(ui, shell, "ready", on_screen.get(.ready), palette.good);
                    legendRow(ui, shell, "decoding", on_screen.get(.running), palette.accent);
                    legendRow(ui, shell, "waiting for a thread", on_screen.get(.idle), palette.muted);
                    shell.divider(ui);
                    const outcomes = ui.source(.photo_outcomes).get() orelse PhotoOutcomes{};
                    legendRow(ui, shell, "decodes started", self.decodes_started, palette.text);
                    legendRow(ui, shell, "finished", outcomes.loaded, palette.good);
                    legendRow(ui, shell, "cancelled, scrolled away", outcomes.abandoned, palette.warn);
                }
            }

            fn bin(self: *PhotoCull, ui: *Ui, shell: *const Shell, id: zui.Id, name: []const u8, count: u32, verdict: Verdict, color: zui.Color) void {
                const palette = shell.palette;
                if (ui.dropped(id, PhotoDrag)) |drop| {
                    self.judge(drop.index, verdict);
                    self.selected = drop.index;
                }
                const hovering = ui.draggedOver(id, PhotoDrag) != null;
                ui.open(.{
                    .id = id,
                    .interactive = true,
                    .semantics = .{ .role = .group, .label = name },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow, .height = .fixed(76) }, .padding = .all(10), .child_gap = 2, .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{
                        .background = if (hovering) color.mix(palette.surface, 0.7) else palette.surface,
                        .border = .{ .color = if (hovering) color else palette.border, .widths = .all(if (hovering) 2 else 1) },
                        .corner_radius = .all(8),
                    },
                });
                defer ui.close();
                shell.printColored(ui, .title, color, "{d}", .{count});
                shell.labelColored(ui, .caption, if (hovering) color else palette.muted, if (hovering) "drop to file" else name);
            }

            /// The decoder. Runs after every frame, on whichever screen, so
            /// decodes finish and release even once the screen is left.
            pub fn afterFrame(self: *PhotoCull, _: *const Ui, shell: *const Shell) void {
                var to_start = shell.sources.photos.toStart(shell.waker);
                while (to_start.next()) |load| {
                    self.decodes_started += 1;
                    self.tasks.concurrent(shell.io, runDecode, .{ &self.outcome_tally, shell.io, &shell.sources.photo_outcomes, shell.waker, load }) catch load.finish(error.NoThreadAvailable);
                }
            }

            pub fn deinit(self: *PhotoCull, io: std.Io) void {
                self.tasks.cancel(io);
            }
        };

        fn photoName(buffer: *[16]u8, index: u32) []const u8 {
            return std.fmt.bufPrint(buffer, "DSC_{d:0>4}", .{index + 1}) catch "DSC";
        }

        /// The photo once decoded, and a placeholder of its size until then.
        fn picture(ui: *Ui, shell: *const Shell, status: PhotoLoads.Status, size: [2]f32, radius: f32) void {
            const palette = shell.palette;
            switch (status) {
                .ready => |photo| landscape(ui, photo, size, radius),
                .idle, .running => {
                    const progress = if (status == .running) status.running else 0;
                    ui.open(placeholderOf(shell, size, radius));
                    defer ui.close();
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(size[0] * 0.6) } } });
                    shell.meter(ui, progress, palette.accent, 4);
                    ui.close();
                },
                .failed, .canceled => {
                    ui.open(placeholderOf(shell, size, radius));
                    defer ui.close();
                    shell.labelColored(ui, .tiny, palette.faint, "not decoded");
                },
            }
        }

        fn placeholderOf(shell: *const Shell, size: [2]f32, radius: f32) Ui.Element {
            return .{
                .layout = .{ .sizing = .{ .width = .fixed(size[0]), .height = .fixed(size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = shell.palette.sunken, .corner_radius = .all(radius) },
            };
        }

        fn landscape(ui: *Ui, photo: Photo, size: [2]f32, radius: f32) void {
            const width = size[0];
            const height = size[1];
            const sun_diameter = @round(width * photo.sun_size);
            const horizon = @round(height * photo.horizon);
            const sky: Ui.Effects = .{ .gradient = .{ .from = photo.sky_top, .to = photo.sky_bottom, .angle = std.math.pi / 2.0 } };
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(width), .height = .fixed(height) } },
                .decoration = .{ .background = photo.sky_top.mix(photo.sky_bottom, 0.5), .corner_radius = .all(radius) },
                .effects = &sky,
                .clip = .both,
            });
            defer ui.close();
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(horizon) }, .padding = .{ .left = @round(width * photo.sun_across), .top = @round(horizon * photo.sun_down) } } });
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(sun_diameter), .height = .fixed(sun_diameter) } }, .decoration = .{ .background = photo.sun, .corner_radius = .all(sun_diameter / 2) } });
            ui.close();
            const ground_height = height - horizon;
            const curve = ground_height * 2 * photo.hill_curve;
            ui.box(.{
                .floating = .{ .offset = .{ -width * 0.2, horizon - ground_height * 0.35 }, .clip = .target, .capture = false },
                .layout = .{ .sizing = .{ .width = .fixed(width * 0.9), .height = .fixed(ground_height * 1.35) } },
                .decoration = .{ .background = photo.far_hill, .corner_radius = .{ .top_left = curve, .top_right = curve * 0.8 } },
            });
            ui.box(.{
                .floating = .{ .offset = .{ width * 0.3, horizon + ground_height * 0.2 }, .clip = .target, .capture = false },
                .layout = .{ .sizing = .{ .width = .fixed(width * 0.9), .height = .fixed(ground_height * 0.8) } },
                .decoration = .{ .background = photo.near_hill, .corner_radius = .{ .top_left = curve * 0.7, .top_right = curve } },
            });
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } }, .decoration = .{ .background = photo.near_hill.mix(photo.far_hill, 0.5) } });
        }

        fn dragGhost(ui: *Ui, shell: *const Shell, index: u32, status: PhotoLoads.Status) void {
            const palette = shell.palette;
            const pointer = ui.primaryPointer() orelse return;
            var name_buffer: [16]u8 = undefined;
            ui.open(.{
                .id = ids.@"photo_cull.ghost",
                .floating = .{ .attach_to = .root, .offset = .{ pointer.position[0] + 14, pointer.position[1] + 14 }, .z = 400, .capture = false },
                .layout = .{ .direction = .top_to_bottom, .padding = .all(6), .child_gap = 4 },
                .decoration = .{ .background = palette.raised, .border = .{ .color = palette.accent, .widths = .all(1) }, .corner_radius = .all(8) },
            });
            defer ui.close();
            picture(ui, shell, status, .{ 96, 72 }, 4);
            shell.label(ui, .tiny, photoName(&name_buffer, index));
        }

        /// A scrollbar zui does not draw for you: the thumb follows the
        /// offset, and pressing or dragging on the track sets it.
        fn scrollTrack(ui: *Ui, shell: *const Shell, offset: f32, visible_height: f32, content_height: f32) void {
            const palette = shell.palette;
            const track_id = ids.@"photo_cull.track";
            const maximum_offset = @max(1, content_height - visible_height);
            const track_height = (ui.rectOf(track_id) orelse zui.Rect{ .height = visible_height }).height;
            const thumb_height = std.math.clamp(track_height * visible_height / content_height, 24, track_height);
            const thumb_top = (track_height - thumb_height) * std.math.clamp(offset / maximum_offset, 0, 1);
            if (ui.pressed(track_id)) if (ui.pointerLocal(track_id)) |local| {
                const fraction = std.math.clamp((local[1] - thumb_height / 2) / @max(1, track_height - thumb_height), 0, 1);
                ui.setScrollOffset(ids.@"photo_cull.grid", .{ 0, fraction * maximum_offset });
            };
            ui.open(.{
                .id = track_id,
                .interactive = true,
                .cursor = .resize_vertical,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(10), .height = .grow } },
                .decoration = .{ .background = palette.sunken, .corner_radius = .all(5) },
            });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(thumb_top) } } });
            ui.box(.{
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(thumb_height) } },
                .decoration = .{ .background = if (ui.hovered(track_id) or ui.pressed(track_id)) palette.accent else palette.faint, .corner_radius = .all(5) },
            });
        }

        fn legendRow(ui: *Ui, shell: *const Shell, name: []const u8, count: u32, color: zui.Color) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = color, .corner_radius = .all(4) } });
            shell.label(ui, .caption, name);
            shell.spacer(ui);
            shell.printColored(ui, .caption, color, "{d}", .{count});
        }
    };
}
