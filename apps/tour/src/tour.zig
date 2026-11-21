//! The tour's frame: a header, a rail of screens, the screen itself, and a
//! performance strip that is always on screen.

const std = @import("std");
const zui = @import("zui");
const zui_showcase = @import("zui_showcase");
const shared = @import("shared.zig");
const Screen = shared.Screen;
const Perf = shared.Perf;

const rail_width = 236;

const ids = zui.ids(.{
    "root",
    "header",
    "zoom_out",
    "zoom_reset",
    "zoom_in",
    "theme",
    "live",
    "heartbeat",
    "inspector_toggle",
    "rail",
    "stage",
    "strip",
    "inspector",
    "inspector_title",
    "inspector_close",
});

/// The id of the area every screen lays out in.
pub const stage_id = ids.stage;
/// The id of the tour's outermost element.
pub const root_id = ids.root;

/// The tour's state and its declaration of a frame, through `kit`, a
/// `Kit`. Whoever runs it hands it the frames: `zui_tour.App` through
/// `zui_app`, or a test or a worker that begins and ends them itself.
pub fn Tour(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;

    const Screens = struct {
        welcome: ScreenOf(.welcome, "Welcome", @import("screens/welcome.zig")),
        layout_lab: ScreenOf(.layout_lab, "LayoutLab", @import("screens/layout_lab.zig")),
        box_storm: ScreenOf(.box_storm, "BoxStorm", @import("screens/box_storm.zig")),
        gallery: ScreenOf(.gallery, "Gallery", @import("screens/gallery.zig")),
        mission_control: ScreenOf(.mission_control, "MissionControl", @import("screens/mission_control.zig")),
        window_manager: ScreenOf(.window_manager, "WindowManager", @import("screens/window_manager.zig")),
        robot_workshop: ScreenOf(.robot_workshop, "RobotWorkshop", @import("screens/robot_workshop.zig")),
        pixel_pad: ScreenOf(.pixel_pad, "PixelPad", @import("screens/pixel_pad.zig")),
        typography: ScreenOf(.typography, "Typography", @import("screens/typography.zig")),
        light_and_depth: ScreenOf(.light_and_depth, "LightAndDepth", @import("screens/light_and_depth.zig")),
        transforms: ScreenOf(.transforms, "Transforms", @import("screens/transforms.zig")),
        materials: ScreenOf(.materials, "Materials", @import("screens/materials.zig")),
        classic: zui_showcase.Showcase(Ui),

        /// `void` for a screen the renderer is not offered, so it costs nothing.
        fn ScreenOf(comptime screen: Screen, comptime name: []const u8, comptime file: type) type {
            return if (kit.offers(screen)) @field(file.Using(kit), name) else void;
        }
    };

    return struct {
        const Self = @This();

        io: std.Io,
        sources: shared.Sources = .{},
        screens: Screens,
        current: Screen = .welcome,
        requested_screen: ?Screen = null,
        perf: Perf = .{},
        environment_changes: shared.EnvironmentQueue = .{},
        wakes: std.atomic.Value(u32) = .init(0),
        /// The host's waker, which a producer's wake is passed on to.
        host_waker: ?zui.Waker = null,
        started_at: zui.Instant,
        fonts: kit.Fonts,

        zoom: f32 = 1,
        /// Refreshes the strip once a second through `requestFrameAt`, so an
        /// idle tour still shows its counters moving.
        heartbeat: bool = true,
        /// Declares a frame at every display refresh, to watch the costs live.
        live: bool = false,
        inspector_open: bool = false,
        inspector_position: [2]f32 = .{ 760, 90 },
        /// `zui_debug`'s panel over the tour, which F12 toggles.
        zui_debug_open: bool = false,
        zui_debug_inspector: kit.Inspector = if (kit.Inspector == void) {} else .{},
        /// Advances to the next screen every this many zui frames, for smoke tests.
        cycle_every: ?u32 = null,
        frames_on_screen: u32 = 0,

        /// `fonts` are the ids `kit.Text.init` gave the tour's typefaces.
        pub fn init(tour: *Self, io: std.Io, started_at: zui.Instant, fonts: kit.Fonts) void {
            tour.* = .{ .io = io, .started_at = started_at, .fonts = fonts, .screens = undefined };
            inline for (@typeInfo(Screens).@"struct".fields) |field| {
                if (field.type != void) @field(tour.screens, field.name) = if (comptime std.mem.eql(u8, field.name, "classic")) .{
                    .title = "zui + " ++ kit.renderer_name,
                    .widgets = .{ .theme = .{ .text = .{ .size = 16, .color = .rgb(0xe8e8f0) } } },
                } else .{};
                if (comptime hasHook(field.type, "init")) @field(tour.screens, field.name).init();
            }
            tour.environment_changes.push(.{ .theme = .dark });
        }

        /// Stops every producer, so the sources outlive them.
        pub fn deinit(tour: *Self) void {
            inline for (@typeInfo(Screens).@"struct".fields) |field| {
                if (comptime hasHook(field.type, "deinit")) @field(tour.screens, field.name).deinit(tour.io);
            }
        }

        /// Shows `screen`, or the welcome screen if this renderer is not offered it.
        pub fn show(tour: *Self, screen: Screen) void {
            tour.current = if (std.mem.indexOfScalar(Screen, kit.offered_screens, screen) != null) screen else .welcome;
            tour.frames_on_screen = 0;
        }

        pub fn waker(tour: *Self) zui.Waker {
            return .{ .context = tour, .wakeFn = countWake };
        }

        /// Counts each wake, and passes it on to the host, which sleeps
        /// between frames; a headless test has none to wake.
        fn countWake(context: *anyopaque) void {
            const tour: *Self = @ptrCast(@alignCast(context));
            _ = tour.wakes.fetchAdd(1, .monotonic);
            if (tour.host_waker) |host_waker| host_waker.wake();
        }

        fn shell(tour: *Self, ui: *const Ui) Shell {
            const seconds: f64 = ui.now().secondsSince(tour.started_at);
            return .init(ui, tour.io, seconds, tour.fonts, &tour.perf, &tour.sources, tour.waker(), &tour.environment_changes, &tour.requested_screen);
        }

        pub fn declare(tour: *Self, ui: *Ui) void {
            var frame_shell = tour.shell(ui);
            tour.handleShortcuts(ui);

            ui.open(.{ .id = ids.root, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = frame_shell.palette.background } });
            tour.header(ui, &frame_shell);
            {
                ui.open(.{ .layout = .{ .sizing = .grow_both } });
                defer ui.close();
                tour.rail(ui, &frame_shell);
                // Scrolling, not just clipping: a scrolled axis does not pass its
                // content's minimum size up, so a screen too wide for a small
                // window scrolls instead of pushing the header off screen. Not
                // vertically: along a scrolled main axis zui never shrinks
                // children, so the screens' own scroll containers would stop
                // fitting the window.
                ui.open(.{
                    .id = ids.stage,
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 12 },
                    .scroll = .{ .horizontal = true, .vertical = false },
                });
                tour.declareScreen(ui, &frame_shell);
                ui.close();
            }
            tour.strip(ui, &frame_shell);
            ui.close();
            if (tour.inspector_open) tour.inspector(ui, &frame_shell);
            if (kit.Inspector != void and tour.zui_debug_open) tour.zui_debug_inspector.declare(ui);

            if (tour.live) ui.requestFrame();
            if (tour.heartbeat) {
                const next_second = @floor(frame_shell.seconds) + 1;
                ui.requestFrameAt(tour.started_at.addSeconds(next_second));
            }
            tour.advanceCycle();
            if (tour.requested_screen) |screen| {
                tour.show(screen);
                tour.requested_screen = null;
                ui.requestFrame();
            }
        }

        /// Copies what `zui_debug`'s panel shows out of `frame`, while it is open.
        pub fn observe(tour: *Self, ui: *const Ui, frame: *const Ui.Frame) void {
            if (kit.Inspector == void or !tour.zui_debug_open) return;
            tour.zui_debug_inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
        }

        /// The loaders: start what this frame asked for, stop what it stopped reading.
        pub fn afterFrame(tour: *Self, ui: *const Ui) void {
            const frame_shell = tour.shell(ui);
            inline for (@typeInfo(Screens).@"struct".fields) |field| {
                if (comptime hasHook(field.type, "afterFrame")) @field(tour.screens, field.name).afterFrame(ui, &frame_shell);
            }
        }

        fn advanceCycle(tour: *Self) void {
            const cycle_every = tour.cycle_every orelse return;
            tour.live = true;
            tour.frames_on_screen += 1;
            if (tour.frames_on_screen < cycle_every) return;
            tour.requested_screen = offeredAfter(tour.current, 1);
        }

        /// The screen `steps` places further along the rail, wrapping around.
        fn offeredAfter(screen: Screen, steps: isize) Screen {
            const count: isize = @intCast(kit.offered_screens.len);
            const position: isize = @intCast(kit.positionOf(screen));
            return kit.offered_screens[@intCast(@mod(position + steps, count))];
        }

        fn declareScreen(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            switch (tour.current) {
                .classic => tour.screens.classic.declare(ui),
                inline else => |screen| if (comptime kit.offers(screen)) @field(tour.screens, @tagName(screen)).declare(ui, frame_shell) else unreachable,
            }
        }

        fn handleShortcuts(tour: *Self, ui: *Ui) void {
            const control: zui.Modifiers = .{ .control = true };
            const digit_keys = [_]zui.Key{ .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9, .digit_0 };
            for (digit_keys[0..@min(digit_keys.len, kit.offered_screens.len)], kit.offered_screens[0..@min(digit_keys.len, kit.offered_screens.len)]) |key, screen| {
                if (ui.chordPressed(.{ .key = key, .modifiers = control })) tour.requested_screen = screen;
            }
            if (ui.chordPressed(.{ .key = .page_down, .modifiers = control })) tour.requested_screen = offeredAfter(tour.current, 1);
            if (ui.chordPressed(.{ .key = .page_up, .modifiers = control })) tour.requested_screen = offeredAfter(tour.current, -1);
            if (ui.chordPressed(.{ .key = .equals, .modifiers = control })) tour.setZoom(tour.zoom + 0.1);
            if (ui.chordPressed(.{ .key = .minus, .modifiers = control })) tour.setZoom(tour.zoom - 0.1);
            if (ui.chordPressed(.{ .key = .i, .modifiers = control })) tour.inspector_open = !tour.inspector_open;
            if (ui.chordPressed(.{ .key = .l, .modifiers = control })) tour.live = !tour.live;
            if (kit.Inspector != void and ui.chordPressed(.{ .key = .f12 })) {
                tour.zui_debug_open = !tour.zui_debug_open;
                // The panel stays empty until a frame it observed is followed by another.
                ui.requestFrame();
            }
        }

        fn setZoom(tour: *Self, zoom: f32) void {
            tour.zoom = std.math.clamp(@round(zoom * 10) / 10, 0.5, 2);
        }

        fn header(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const palette = frame_shell.palette;
            const widgets = frame_shell.widgets;
            const info = kit.info(tour.current);
            ui.open(.{
                .id = ids.header,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(60) }, .padding = .symmetric(16, 0), .child_gap = 14, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .{ .bottom = 1 } } },
            });
            defer ui.close();

            ui.open(.{
                .layout = .{ .padding = .symmetric(10, 6) },
                .decoration = .{ .background = palette.accent, .corner_radius = .{ .top_left = 12, .bottom_right = 12, .top_right = 3, .bottom_left = 3 } },
            });
            ui.text("zui", .{ .size = 26, .font = frame_shell.fonts.bold, .letter_spacing = 1, .color = palette.on_accent });
            ui.close();
            {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
                defer ui.close();
                frame_shell.label(ui, .heading, info.title);
                frame_shell.label(ui, .caption, info.tagline);
            }

            if (widgets.button(ui, ids.zoom_out, "-", .{})) tour.setZoom(tour.zoom - 0.1);
            var zoom_buffer: [16]u8 = undefined;
            if (widgets.button(ui, ids.zoom_reset, std.fmt.bufPrint(&zoom_buffer, "{d:.0}%", .{tour.zoom * 100}) catch "zoom", .{})) tour.zoom = 1;
            if (widgets.button(ui, ids.zoom_in, "+", .{})) tour.setZoom(tour.zoom + 0.1);
            const dark = ui.environment().theme == .dark;
            if (widgets.button(ui, ids.theme, if (dark) "Light" else "Dark", .{})) frame_shell.changeEnvironment(.{ .theme = if (dark) .light else .dark });
            _ = widgets.checkbox(ui, ids.live, "Live", &tour.live, .{});
            _ = widgets.checkbox(ui, ids.heartbeat, "1 Hz", &tour.heartbeat, .{});
            _ = widgets.checkbox(ui, ids.inspector_toggle, "Inspector", &tour.inspector_open, .{});
        }

        fn rail(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const palette = frame_shell.palette;
            ui.open(.{
                .id = ids.rail,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(rail_width), .height = .grow }, .padding = .all(10), .child_gap = 4 },
                .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .{ .right = 1 } } },
                .scroll = .{},
            });
            defer ui.close();

            for (kit.offered_screens, 0..) |screen, index| {
                const id: zui.Id = .indexed("rail_item", index);
                const selected = tour.current == screen;
                const state = ui.widgetState(id);
                const info = kit.info(screen);
                const swatch = shared.hueColor(info.hue, 0.55, 0.95);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .{ .left = 8, .right = 6 }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                    .decoration = .{
                        .background = if (selected) palette.hovered else if (state == .hovered or state == .pressed) palette.raised else null,
                        .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else if (selected) .{ .color = swatch, .widths = .{ .left = 3 } } else null,
                        .corner_radius = .all(6),
                    },
                });
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .fixed(22), .height = .fixed(22) }, .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{ .background = if (selected) swatch else palette.sunken, .corner_radius = .all(11) },
                });
                if (kit.shortcutDigit(screen)) |digit| frame_shell.printColored(ui, .caption, if (selected) palette.on_accent else palette.muted, "{d}", .{digit});
                ui.close();
                ui.text(info.title, .{ .size = 15 * frame_shell.text_scale, .font = if (selected) frame_shell.fonts.bold else frame_shell.fonts.body, .color = if (selected) palette.text else palette.muted, .wrap = .none });
                ui.close();
                if (ui.clicked(id)) tour.requested_screen = screen;
            }
            frame_shell.spacer(ui);
            frame_shell.label(ui, .tiny, "Ctrl+1..0  jump to a screen");
            frame_shell.label(ui, .tiny, "Ctrl+PgUp/PgDn  prev/next");
            frame_shell.label(ui, .tiny, "Ctrl+= / Ctrl+-  zoom");
            frame_shell.label(ui, .tiny, "Ctrl+I  frame inspector");
            if (kit.Inspector != void) frame_shell.label(ui, .tiny, "F12  zui_debug inspector");
            frame_shell.label(ui, .tiny, "Ctrl+L  live mode");
            frame_shell.label(ui, .tiny, "Tab  move focus");
        }

        fn strip(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const palette = frame_shell.palette;
            const perf = &tour.perf;
            const latest = perf.latest();
            ui.open(.{
                .id = ids.strip,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(78) }, .padding = .symmetric(14, 8), .child_gap = 18, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = palette.sunken, .border = .{ .color = palette.border, .widths = .{ .top = 1 } } },
            });
            defer ui.close();

            sparkline(ui, frame_shell, perf, 56);
            {
                ui.open(.{ .id = .of("strip.stats"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 6 }, .scroll = .{ .horizontal = true, .vertical = false } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    stat(ui, frame_shell, "zui frames", "{d}", .{perf.zui_frames}, palette.accent);
                    stat(ui, frame_shell, "last second", "{d} frames", .{perf.frames_last_second}, palette.text);
                    stat(ui, frame_shell, "producer wakes", "{d}", .{perf.wakes}, palette.good);
                    stat(ui, frame_shell, "this frame because", "{s}", .{latest.reason.describe()}, palette.warn);
                    switch (perf.next_frame) {
                        .immediately => stat(ui, frame_shell, "next", "immediately", .{}, palette.bad),
                        .at => stat(ui, frame_shell, "next", "in {d:.2} s", .{perf.next_frame_seconds}, palette.warn),
                        .on_event => stat(ui, frame_shell, "next", "on input (sleeping)", .{}, palette.good),
                    }
                }
                {
                    ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    stat(ui, frame_shell, "beginFrame", "{d:.1} us", .{latest.begin_frame_us}, palette.text);
                    stat(ui, frame_shell, "declare", "{d:.1} us", .{latest.declare_us}, palette.text);
                    stat(ui, frame_shell, "layout+emit", "{d:.1} us", .{latest.end_frame_us}, palette.text);
                    stat(ui, frame_shell, kit.renderer_name ++ " submit", "{d:.0} us", .{perf.submit_us}, palette.text);
                    stat(ui, frame_shell, "elements", "{d}", .{latest.elements}, palette.text);
                    stat(ui, frame_shell, "commands", "{d}", .{latest.commands}, palette.text);
                    stat(ui, frame_shell, "texts measured", "{d}", .{latest.measure_calls}, if (latest.measure_calls == 0) palette.good else palette.warn);
                }
            }
        }

        fn inspector(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const palette = frame_shell.palette;
            const perf = &tour.perf;
            const viewport = ui.viewport();
            tour.inspector_position[0] = std.math.clamp(tour.inspector_position[0], 0, @max(0, viewport[0] - 120));
            tour.inspector_position[1] = std.math.clamp(tour.inspector_position[1], 0, @max(0, viewport[1] - 40));
            ui.open(.{
                .id = ids.inspector,
                .interactive = true,
                .floating = .{ .attach_to = .root, .offset = tour.inspector_position, .z = 500 },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360) } },
                .decoration = .{ .background = palette.surface, .border = .{ .color = palette.accent, .widths = .all(2) }, .corner_radius = .all(10) },
            });
            defer ui.close();
            const dragging = kit.drag(ui, ids.inspector_title, &tour.inspector_position);
            {
                ui.open(.{
                    .id = ids.inspector_title,
                    .interactive = true,
                    .cursor = if (dragging) .grabbing else .grab,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(34) }, .padding = .symmetric(12, 0), .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = palette.accent, .corner_radius = .{ .top_left = 8, .top_right = 8 } },
                });
                defer ui.close();
                frame_shell.labelColored(ui, .body, palette.on_accent, "Frame inspector");
                frame_shell.spacer(ui);
                ui.open(.{
                    .id = ids.inspector_close,
                    .interactive = true,
                    .cursor = .pointer,
                    .layout = .{ .padding = .symmetric(8, 2) },
                    .decoration = .{ .background = if (ui.hovered(ids.inspector_close)) palette.on_accent.mix(palette.accent, 0.7) else null, .corner_radius = .all(4) },
                });
                frame_shell.labelColored(ui, .body, palette.on_accent, "x");
                ui.close();
                if (ui.clicked(ids.inspector_close)) tour.inspector_open = false;
            }

            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(12), .child_gap = 8 } });
            defer ui.close();

            const summary = perf.summarize();
            frame_shell.label(ui, .caption, "LAST 120 ZUI FRAMES (begin + declare + layout)");
            frame_shell.print(ui, .body, "min {d:.0}  avg {d:.0}  p95 {d:.0}  max {d:.0} us", .{ summary.minimum, summary.average, summary.p95, summary.maximum });
            sparkline(ui, frame_shell, perf, 70);

            const latest = perf.latest();
            const total = @max(latest.totalMicroseconds(), 0.001);
            frame_shell.label(ui, .caption, "WHERE THE LAST FRAME WENT");
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(14) } }, .decoration = .{ .corner_radius = .all(4) } });
                defer ui.close();
                const parts = [_]struct { f32, zui.Color }{
                    .{ latest.begin_frame_us, shared.hueColor(0.55, 0.6, 0.9) },
                    .{ latest.declare_us, shared.hueColor(0.3, 0.6, 0.85) },
                    .{ latest.end_frame_us, shared.hueColor(0.08, 0.7, 0.95) },
                };
                for (parts) |part| ui.box(.{ .layout = .{ .sizing = .{ .width = .growWeighted(@max(part[0] / total, 0.0001)), .height = .grow } }, .decoration = .{ .background = part[1] } });
            }
            frame_shell.printColored(ui, .caption, palette.muted, "begin {d:.0}%  declare {d:.0}%  layout+emit {d:.0}%", .{ 100 * latest.begin_frame_us / total, 100 * latest.declare_us / total, 100 * latest.end_frame_us / total });

            frame_shell.divider(ui);
            frame_shell.label(ui, .caption, "LIMITS: WHAT THE FRAME NEEDED");
            const limit_rows = [_]struct { zui.Limit, []const u8 }{
                .{ .max_elements, "elements" },
                .{ .max_depth, "depth" },
                .{ .max_text_bytes, "text bytes" },
                .{ .max_render_commands, "commands" },
            };
            for (limit_rows) |row| {
                const needed = perf.diagnostics.needed.get(row[0]);
                const limit = limitValue(row[0]);
                const fraction = @as(f32, @floatFromInt(needed)) / @as(f32, @floatFromInt(limit));
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) } } });
                frame_shell.label(ui, .caption, row[1]);
                ui.close();
                frame_shell.meter(ui, fraction, if (fraction > 0.9) palette.bad else if (fraction > 0.6) palette.warn else palette.good, 8);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) }, .child_alignment = .{ .x = .end } } });
                frame_shell.print(ui, .caption, "{d}/{d}", .{ needed, limit });
                ui.close();
                ui.close();
            }

            frame_shell.divider(ui);
            frame_shell.label(ui, .caption, "DIAGNOSTICS");
            const diagnostics = perf.diagnostics;
            if (diagnostics.ok()) {
                frame_shell.labelColored(ui, .body, palette.good, "ok: nothing dropped or refused");
            } else {
                frame_shell.printColored(ui, .body, palette.bad, "{d} limits exceeded, {d} duplicate ids", .{ diagnostics.exceeded.count(), diagnostics.duplicate_ids });
                if (diagnostics.refused_publishes != 0) frame_shell.printColored(ui, .body, palette.bad, "{d} publishes refused, first by .{s}", .{ diagnostics.refused_publishes, diagnostics.first_refusing_source });
            }
            frame_shell.print(ui, .caption, "texts measured since start: {d}", .{perf.measure_calls_total});
            frame_shell.print(ui, .caption, "producer wakes: {d}   dropped input: {d}", .{ perf.wakes, perf.dropped_input_events });
            frame_shell.print(ui, .caption, "layer overflows: {d}   glyph atlas overflows: {d}", .{ perf.layer_overflows, perf.glyph_overflows });

            frame_shell.divider(ui);
            frame_shell.label(ui, .caption, "ENVIRONMENT, AS THE HOST REPORTS IT");
            const environment = ui.environment();
            frame_shell.print(ui, .caption, "theme .{t}  contrast .{t}  reduced motion {}", .{ environment.theme, environment.contrast, environment.reduced_motion });
            frame_shell.print(ui, .caption, "text scale {d:.2}  window focused {}  zoom {d:.1}", .{ environment.text_scale, environment.window_focused, tour.zoom });
        }

        fn limitValue(limit: zui.Limit) u32 {
            return switch (limit) {
                inline else => |tag| @intCast(@field(Ui.limits, @tagName(tag))),
            };
        }

        fn stat(ui: *Ui, frame_shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype, color: zui.Color) void {
            ui.open(.{ .layout = .{ .child_gap = 5, .child_alignment = .{ .y = .center } } });
            frame_shell.label(ui, .tiny, name);
            frame_shell.printColored(ui, .caption, color, format, arguments);
            ui.close();
        }

        /// One bar per zui frame, scaled to the tallest: green under 0.5 ms, red over 4 ms.
        fn sparkline(ui: *Ui, frame_shell: *const Shell, perf: *const Perf, height: f32) void {
            const palette = frame_shell.palette;
            var tallest: f32 = 50;
            for (perf.history) |sample| tallest = @max(tallest, sample.totalMicroseconds());
            ui.open(.{
                .layout = .{ .sizing = .{ .height = .fixed(height) }, .padding = .all(3), .child_gap = 1, .child_alignment = .{ .y = .end } },
                .decoration = .{ .background = palette.background, .corner_radius = .all(4) },
            });
            defer ui.close();
            for (0..Perf.history_length) |age| {
                const total = perf.sampleAt(age).totalMicroseconds();
                const color = if (total < 500) palette.good else if (total < 4000) palette.warn else palette.bad;
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(@max(1, (height - 6) * total / tallest)) } },
                    .decoration = .{ .background = color },
                });
            }
        }
    };
}

fn hasHook(comptime ScreenState: type, comptime name: []const u8) bool {
    return @typeInfo(ScreenState) == .@"struct" and @hasDecl(ScreenState, name);
}
