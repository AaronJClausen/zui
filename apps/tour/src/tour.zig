//! The tour's frame: a header, a rail of screens in sections by lane, the
//! screen itself, and a performance strip that is always on screen.

const std = @import("std");
const zui = @import("zui");
const shared = @import("shared.zig");
const Screen = shared.Screen;
const Perf = shared.Perf;

const rail_width = 236;
const preferences_menu_width = 320;
/// Square at the smallest density's small control, so the zoom row fits
/// beside its label at every density.
const zoom_step_button_width = 28;
/// The menu's settings scroll in no less than this, however short the window.
const preferences_menu_least_room = 120;
/// What the menu leaves free below it: the popover's padding and the
/// window's margin.
const preferences_menu_margin = 32;
/// Between the button and the menu's settings in the frame the menu opens,
/// before they have been placed: the gap, the padding and the menu's title.
const preferences_menu_heading_allowance = 72;

const floating_panel_effects: zui.Effects = .{ .shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 8 }, .blur = 24 } };

const ids = zui.ids(.{
    "root",
    "header",
    "preferences",
    "preferences.menu",
    "preferences.pin",
    "preferences.scroll",
    "zoom_out",
    "zoom_reset",
    "zoom_in",
    "theme",
    "live",
    "heartbeat",
    "inspector_toggle",
    "rail",
    "rail.scroll",
    "rail.screens",
    "stage",
    "strip",
    "inspector",
    "inspector_title",
    "inspector_close",
});

/// The id of the area every screen lays out in.
pub const stage_id = ids.stage;
/// The id of the rail's `navigationList` of screens; its row for a screen
/// is `rail_screens_id.indexedChild("item", RailRows(kit).rowOf(screen))`.
pub const rail_screens_id = ids.@"rail.screens";
/// The id of the tour's outermost element.
pub const root_id = ids.root;
/// The id of the top bar's button that opens the preferences menu.
pub const preferences_button_id = ids.preferences;
/// The id of the preferences menu's `popover`; its panel is
/// `preferences_menu_id.child("panel")`.
pub const preferences_menu_id = ids.@"preferences.menu";
/// The id of the switch that pins the preferences menu open.
pub const preferences_pin_id = ids.@"preferences.pin";
/// The id of the preferences menu's `scrollArea`, which holds its settings.
pub const preferences_settings_id = ids.@"preferences.scroll";

/// The tour's state and its declaration of a frame, through `kit`, a
/// `Kit`. Whoever runs it hands it the frames: `zui_tour.App` through
/// `zui_app`, or a test or a worker that begins and ends them itself.
pub fn Tour(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const rail_rows = RailRows(kit);
    const PreferencesMenu = @import("preferences_menu.zig").Using(kit).PreferencesMenu;

    const Screens = struct {
        overview: ScreenOf(.overview, "Overview", @import("screens/overview.zig")),
        /// Harbor X-ray is this same console with its overlay on, so the
        /// two screens share one state.
        harbor: ScreenOf(.harbor, "Harbor", @import("screens/harbor.zig")),
        photo_cull: ScreenOf(.photo_cull, "PhotoCull", @import("screens/photo_cull.zig")),
        log_tail: ScreenOf(.log_tail, "LogTail", @import("screens/log_tail.zig")),
        kanban: ScreenOf(.kanban, "Kanban", @import("screens/kanban.zig")),
        settings_form: ScreenOf(.settings_form, "SettingsForm", @import("screens/settings_form.zig")),
        field_guide: ScreenOf(.field_guide, "FieldGuide", @import("screens/field_guide.zig")),
        quiet_machine: ScreenOf(.quiet_machine, "QuietMachine", @import("screens/quiet_machine.zig")),
        time_machine: ScreenOf(.time_machine, "TimeMachine", @import("screens/time_machine.zig")),
        break_it: ScreenOf(.break_it, "BreakIt", @import("screens/break_it.zig")),
        gesture_arena: ScreenOf(.gesture_arena, "GestureArena", @import("screens/gesture_arena.zig")),
        light_lab: ScreenOf(.light_lab, "LightLab", @import("screens/light_lab.zig")),
        one_declaration: ScreenOf(.one_declaration, "OneDeclaration", @import("screens/one_declaration.zig")),
        clickable_chaos: ScreenOf(.clickable_chaos, "ClickableChaos", @import("screens/clickable_chaos.zig")),
        cabin_booking: ScreenOf(.cabin_booking, "CabinBooking", @import("screens/cabin_booking.zig")),
        manifest: ScreenOf(.manifest, "Manifest", @import("screens/manifest.zig")),
        preferences: ScreenOf(.preferences, "Preferences", @import("screens/preferences.zig")),

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
        current: Screen = .overview,
        requested_screen: ?Screen = null,
        perf: Perf = .{},
        environment_changes: shared.EnvironmentQueue = .{},
        wakes: std.atomic.Value(u32) = .init(0),
        /// The host's waker, which a producer's wake is passed on to.
        host_waker: ?zui.Waker = null,
        started_at: zui.Instant,
        fonts: kit.Fonts,
        appearance: kit.Appearance = .{},
        preference_choices: kit.PreferenceChoices = .{},
        preferences_menu: PreferencesMenu = .{},

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
                if (field.type != void) @field(tour.screens, field.name) = .{};
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

        /// Shows `screen`, or the overview if this renderer is not offered it.
        pub fn show(tour: *Self, screen: Screen) void {
            tour.current = if (std.mem.indexOfScalar(Screen, kit.offered_screens, screen) != null) screen else .overview;
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
            tour.appearance.follow(kit.preferencesOf(ui.environment(), tour.preference_choices), tour.fonts);
            return .init(ui, tour.io, seconds, tour.fonts, &tour.appearance, &tour.preference_choices, &tour.perf, &tour.sources, tour.waker(), &tour.environment_changes, &tour.requested_screen);
        }

        /// The color the tour's page is drawn on, for a renderer to clear
        /// to; valid once a frame has been declared.
        pub fn background(tour: *const Self) zui.Color {
            return tour.appearance.colors().get(.background);
        }

        pub fn declare(tour: *Self, ui: *Ui) void {
            var frame_shell = tour.shell(ui);
            tour.handleShortcuts(ui);

            ui.open(.{ .id = ids.root, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = frame_shell.colors.get(.background) } });
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

        /// The screen `steps` places further along `kit.offered_screens`, wrapping
        /// around.
        fn offeredAfter(screen: Screen, steps: isize) Screen {
            const count: isize = @intCast(kit.offered_screens.len);
            const position: isize = @intCast(kit.positionOf(screen));
            return kit.offered_screens[@intCast(@mod(position + steps, count))];
        }

        fn declareScreen(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            switch (tour.current) {
                .x_ray => tour.screens.harbor.declareXray(ui, frame_shell),
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
            if (ui.chordPressed(.{ .key = .comma, .modifiers = control })) tour.preferences_menu.open = !tour.preferences_menu.open;
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
            const colors = frame_shell.colors;
            const widgets = frame_shell.widgets;
            const info = kit.info(tour.current);
            ui.open(.{
                .id = ids.header,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(60) }, .padding = .symmetric(20, 0), .child_gap = 12, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = colors.get(.surface), .border = .{ .color = colors.get(.outline_muted), .widths = .{ .bottom = 1 } } },
            });
            defer ui.close();

            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(rail_width - 40) }, .child_gap = 6, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                ui.text("zui", .{ .size = 20 * frame_shell.text_scale, .font = frame_shell.fonts.bold, .color = colors.get(.on_surface) });
                frame_shell.labelColored(ui, .body, colors.get(.on_surface_muted), "tour");
            }
            {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .child_gap = 10, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    frame_shell.label(ui, .heading, info.title);
                    frame_shell.lanePill(ui, info.lane);
                }
                frame_shell.label(ui, .caption, info.tagline);
            }

            _ = widgets.button(ui, ids.preferences, "Preferences", .{ .variant = .secondary });
            tour.preferencesMenu(ui, frame_shell);
        }

        /// The menu below the top bar's button, holding every setting the
        /// tour offers: the view, the preferences the tokens follow, what
        /// asks for frames, and the open screen's own toggles. Unpinned it
        /// keeps Tab inside and closes on Escape or a click outside; pinned
        /// it stays open while the screen beside it takes the pointer.
        fn preferencesMenu(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const widgets = frame_shell.widgets;
            const menu = &tour.preferences_menu;
            const panel = widgets.popover(ui, ids.@"preferences.menu", ids.preferences, &menu.open, .{ .label = "Preferences", .pinned = menu.pinned }) orelse {
                menu.was_open = false;
                return;
            };
            defer panel.end(ui);
            if (menu.open and !menu.was_open) ui.requestFocus(ids.@"preferences.pin");
            menu.was_open = menu.open;

            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                widgets.labelWith(ui, "Preferences", .{ .role = .title });
                frame_shell.spacer(ui);
                _ = widgets.toggle(ui, ids.@"preferences.pin", "Keep open", &menu.pinned, .{});
            }
            const area = widgets.scrollArea(ui, ids.@"preferences.scroll", .{
                .width = .fixed(preferences_menu_width),
                .height = .fitBetween(0, preferencesMenuRoom(ui)),
                .child_gap = 10,
                .label = "Preferences",
                .layer = widgets.style(ui, .popover, .idle).layer + 1,
            });
            defer area.end(ui);

            menuSection(ui, frame_shell, "VIEW");
            widgets.labeledRow(ui, "Zoom");
            {
                ui.open(.{ .layout = .{ .child_gap = 4, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                const step_width: zui.Sizing = .fixed(zoom_step_button_width);
                if (widgets.button(ui, ids.zoom_out, "-", .{ .variant = .secondary, .size = .small, .width = step_width })) tour.setZoom(tour.zoom - 0.1);
                var zoom_buffer: [16]u8 = undefined;
                if (widgets.button(ui, ids.zoom_reset, std.fmt.bufPrint(&zoom_buffer, "{d:.0}%", .{tour.zoom * 100}) catch "zoom", .{ .variant = .secondary, .size = .small })) tour.zoom = 1;
                if (widgets.button(ui, ids.zoom_in, "+", .{ .variant = .secondary, .size = .small, .width = step_width })) tour.setZoom(tour.zoom + 0.1);
            }
            ui.close();
            var theme = ui.environment().theme;
            widgets.labeledRow(ui, "Theme");
            if (widgets.segmented(ui, ids.theme, &theme, .{ .label = "Theme" })) frame_shell.changeEnvironment(.{ .theme = theme });
            ui.close();

            menuSection(ui, frame_shell, "YOUR PREFERENCES");
            if (menu.declareChoices(ui, frame_shell)) ui.requestFrame();

            menuSection(ui, frame_shell, "FRAMES");
            {
                ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                _ = widgets.checkbox(ui, ids.live, "Live", &tour.live, .{});
                _ = widgets.checkbox(ui, ids.heartbeat, "1 Hz", &tour.heartbeat, .{});
                _ = widgets.checkbox(ui, ids.inspector_toggle, "Inspector", &tour.inspector_open, .{});
            }

            if (screenHasMenuToggles(tour.current)) {
                var heading: [64]u8 = undefined;
                menuSection(ui, frame_shell, std.ascii.upperString(&heading, kit.info(tour.current).title));
                tour.declareScreenMenuToggles(ui, frame_shell);
            }
        }

        fn menuSection(ui: *Ui, frame_shell: *const Shell, heading: []const u8) void {
            frame_shell.widgets.labelWith(ui, heading, .{ .role = .caption, .tone = .muted });
        }

        /// The height the menu's settings may take below the top bar
        /// before they scroll.
        fn preferencesMenuRoom(ui: *const Ui) f32 {
            const viewport = ui.viewport();
            const top = if (ui.rectOf(ids.@"preferences.scroll")) |placed|
                placed.y
            else if (ui.rectOf(ids.preferences)) |button|
                button.y + button.height + preferences_menu_heading_allowance
            else
                viewport[1] / 2;
            return @max(preferences_menu_least_room, viewport[1] - top - preferences_menu_margin);
        }

        /// The section the open screen adds to the menu, from its
        /// `declareMenuToggles`.
        fn declareScreenMenuToggles(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            switch (tour.current) {
                .x_ray => tour.screens.harbor.declareXrayMenuToggles(ui, frame_shell),
                inline else => |screen| if (comptime hasHook(@FieldType(Screens, @tagName(screen)), "declareMenuToggles")) {
                    @field(tour.screens, @tagName(screen)).declareMenuToggles(ui, frame_shell);
                },
            }
        }

        fn screenHasMenuToggles(screen: Screen) bool {
            return switch (screen) {
                .x_ray => true,
                inline else => |named| comptime hasHook(@FieldType(Screens, @tagName(named)), "declareMenuToggles"),
            };
        }

        fn rail(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const colors = frame_shell.colors;
            ui.open(.{
                .id = ids.rail,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(rail_width), .height = .grow } },
                .decoration = .{ .background = colors.get(.surface), .border = .{ .color = colors.get(.outline_muted), .widths = .{ .right = 1 } } },
            });
            defer ui.close();
            const area = frame_shell.widgets.scrollArea(ui, ids.@"rail.scroll", .{ .padding = .all(10), .child_gap = 4, .label = "Screens" });
            defer area.end(ui);

            var selected = rail_rows.rowOf(tour.current);
            if (frame_shell.widgets.navigationList(ui, rail_screens_id, &rail_rows.items, &selected, .{ .label = "Screens" })) {
                tour.requested_screen = rail_rows.screens[selected];
            }
            frame_shell.spacer(ui);
            frame_shell.label(ui, .tiny, "Ctrl+PgUp/PgDn  prev/next");
            frame_shell.label(ui, .tiny, "Ctrl+= / Ctrl+-  zoom");
            frame_shell.label(ui, .tiny, "Ctrl+I  frame inspector");
            if (kit.Inspector != void) frame_shell.label(ui, .tiny, "F12  zui_debug inspector");
            frame_shell.label(ui, .tiny, "Ctrl+L  live mode");
            frame_shell.label(ui, .tiny, "Ctrl+,  preferences");
        }

        fn strip(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const colors = frame_shell.colors;
            const perf = &tour.perf;
            const latest = perf.latest();
            ui.open(.{
                .id = ids.strip,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(64) }, .padding = .symmetric(16, 8), .child_gap = 18, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = colors.get(.surface_sunken), .border = .{ .color = colors.get(.outline_muted), .widths = .{ .top = 1 } } },
            });
            defer ui.close();

            sparkline(ui, frame_shell, perf, 44);
            {
                ui.open(.{ .id = .of("strip.stats"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 6 }, .scroll = .{ .horizontal = true, .vertical = false } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    stat(ui, frame_shell, "zui frames", "{d}", .{perf.zui_frames}, colors.get(.on_surface_accent));
                    stat(ui, frame_shell, "last second", "{d} frames", .{perf.frames_last_second}, colors.get(.on_surface));
                    stat(ui, frame_shell, "producer wakes", "{d}", .{perf.wakes}, colors.get(.on_success_container));
                    stat(ui, frame_shell, "this frame because", "{s}", .{latest.reason.describe()}, colors.get(.on_warning_container));
                    switch (perf.next_frame) {
                        .immediately => stat(ui, frame_shell, "next", "immediately", .{}, colors.get(.on_danger_container)),
                        .at => stat(ui, frame_shell, "next", "in {d:.2} s", .{perf.next_frame_seconds}, colors.get(.on_warning_container)),
                        .on_event => stat(ui, frame_shell, "next", "on input (sleeping)", .{}, colors.get(.on_success_container)),
                    }
                }
                {
                    ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    stat(ui, frame_shell, "beginFrame", "{d:.1} us", .{latest.begin_frame_us}, colors.get(.on_surface));
                    stat(ui, frame_shell, "declare", "{d:.1} us", .{latest.declare_us}, colors.get(.on_surface));
                    stat(ui, frame_shell, "layout+emit", "{d:.1} us", .{latest.end_frame_us}, colors.get(.on_surface));
                    stat(ui, frame_shell, kit.renderer_name ++ " submit", "{d:.0} us", .{perf.submit_us}, colors.get(.on_surface));
                    stat(ui, frame_shell, "elements", "{d}", .{latest.elements}, colors.get(.on_surface));
                    stat(ui, frame_shell, "commands", "{d}", .{latest.commands}, colors.get(.on_surface));
                    stat(ui, frame_shell, "texts measured", "{d}", .{latest.measure_calls}, if (latest.measure_calls == 0) colors.get(.on_success_container) else colors.get(.on_warning_container));
                }
            }
        }

        fn inspector(tour: *Self, ui: *Ui, frame_shell: *const Shell) void {
            const colors = frame_shell.colors;
            const perf = &tour.perf;
            const viewport = ui.viewport();
            tour.inspector_position[0] = std.math.clamp(tour.inspector_position[0], 0, @max(0, viewport[0] - 120));
            tour.inspector_position[1] = std.math.clamp(tour.inspector_position[1], 0, @max(0, viewport[1] - 40));
            ui.open(.{
                .id = ids.inspector,
                .interactive = true,
                .floating = .{ .attach_to = .root, .offset = tour.inspector_position, .z = 500 },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360) } },
                .decoration = .{ .background = colors.get(.surface), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(10) },
                .effects = &floating_panel_effects,
            });
            defer ui.close();
            const dragging = kit.drag(ui, ids.inspector_title, &tour.inspector_position);
            {
                ui.open(.{
                    .id = ids.inspector_title,
                    .interactive = true,
                    .cursor = if (dragging) .grabbing else .grab,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(34) }, .padding = .symmetric(12, 0), .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = colors.get(.surface_raised), .border = .{ .color = colors.get(.outline_muted), .widths = .{ .bottom = 1 } }, .corner_radius = .{ .top_left = 10, .top_right = 10 } },
                });
                defer ui.close();
                frame_shell.label(ui, .body, "Frame inspector");
                frame_shell.spacer(ui);
                ui.open(.{
                    .id = ids.inspector_close,
                    .interactive = true,
                    .cursor = .pointer,
                    .layout = .{ .padding = .symmetric(8, 2) },
                    .decoration = .{ .background = if (ui.hovered(ids.inspector_close)) colors.get(.secondary_container) else null, .corner_radius = .all(4) },
                });
                frame_shell.labelColored(ui, .body, colors.get(.on_surface_muted), "x");
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
            frame_shell.printColored(ui, .caption, colors.get(.on_surface_muted), "begin {d:.0}%  declare {d:.0}%  layout+emit {d:.0}%", .{ 100 * latest.begin_frame_us / total, 100 * latest.declare_us / total, 100 * latest.end_frame_us / total });

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
                frame_shell.meter(ui, fraction, if (fraction > 0.9) colors.get(.danger) else if (fraction > 0.6) colors.get(.warning) else colors.get(.success), 8);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) }, .child_alignment = .{ .x = .end } } });
                frame_shell.print(ui, .caption, "{d}/{d}", .{ needed, limit });
                ui.close();
                ui.close();
            }

            frame_shell.divider(ui);
            frame_shell.label(ui, .caption, "DIAGNOSTICS");
            const diagnostics = perf.diagnostics;
            if (diagnostics.ok()) {
                frame_shell.labelColored(ui, .body, colors.get(.on_success_container), "ok: nothing dropped or refused");
            } else {
                frame_shell.printColored(ui, .body, colors.get(.on_danger_container), "{d} limits exceeded, {d} duplicate ids", .{ diagnostics.exceeded.count(), diagnostics.duplicate_ids });
                if (diagnostics.refused_publishes != 0) frame_shell.printColored(ui, .body, colors.get(.on_danger_container), "{d} publishes refused, first by .{s}", .{ diagnostics.refused_publishes, diagnostics.first_refusing_source });
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
            const colors = frame_shell.colors;
            var tallest: f32 = 50;
            for (perf.history) |sample| tallest = @max(tallest, sample.totalMicroseconds());
            ui.open(.{
                .layout = .{ .sizing = .{ .height = .fixed(height) }, .padding = .all(3), .child_gap = 1, .child_alignment = .{ .y = .end } },
                .decoration = .{ .background = colors.get(.background), .corner_radius = .all(4) },
            });
            defer ui.close();
            for (0..Perf.history_length) |age| {
                const total = perf.sampleAt(age).totalMicroseconds();
                const color = if (total < 500) colors.get(.success) else if (total < 4000) colors.get(.warning) else colors.get(.danger);
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(@max(1, (height - 6) * total / tallest)) } },
                    .decoration = .{ .background = color },
                });
            }
        }
    };
}

/// The rail's rows for `kit`'s screens: a heading for each lane, then
/// that lane's screens in the order Ctrl+PgDn steps through them, each
/// showing the shortcut that reaches it.
pub fn RailRows(comptime kit: type) type {
    const NavigationItem = kit.zui_widgets.NavigationItem;
    const lanes = std.enums.values(shared.Lane);
    const row_count = kit.offered_screens.len + lanes.len;
    return struct {
        pub const items: [row_count]NavigationItem = rows.items;
        /// The screen each row shows; a heading's is the first of its lane.
        pub const screens: [row_count]Screen = rows.screens;

        const rows = rows: {
            var listed: struct { items: [row_count]NavigationItem, screens: [row_count]Screen } = undefined;
            var count: usize = 0;
            for (lanes) |lane| {
                var headed = false;
                for (kit.offered_screens) |screen| {
                    const info = kit.info(screen);
                    if (info.lane != lane) continue;
                    if (!headed) {
                        listed.items[count] = .{ .label = lane.name(), .heading = true };
                        listed.screens[count] = screen;
                        count += 1;
                        headed = true;
                    }
                    const shortcut = if (kit.shortcutDigit(screen)) |digit| std.fmt.comptimePrint("Ctrl+{d}", .{digit}) else "";
                    listed.items[count] = .{ .label = info.title, .shortcut = shortcut };
                    listed.screens[count] = screen;
                    count += 1;
                }
            }
            if (count != row_count) @compileError("every lane of the tour must hold a screen the renderer is offered");
            break :rows listed;
        };

        /// The row that shows `screen`.
        pub fn rowOf(screen: Screen) usize {
            for (screens, items, 0..) |listed, item, row| {
                if (listed == screen and !item.heading) return row;
            }
            unreachable;
        }
    };
}

fn hasHook(comptime ScreenState: type, comptime name: []const u8) bool {
    return @typeInfo(ScreenState) == .@"struct" and @hasDecl(ScreenState, name);
}
