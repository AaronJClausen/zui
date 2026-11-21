//! `Kit`: the `Ui` the tour declares through, made for one renderer and
//! one font system, which screens that renderer is offered, and the
//! `Shell` each screen declares with.

const std = @import("std");
const zui_app = @import("zui_app");
const zui_debug = @import("zui_debug");
const zui_tracy = @import("zui_tracy");
const shared = @import("shared.zig");

/// What a `Kit` is made for.
pub const Spec = struct {
    Renderer: type,
    /// A font system, such as `zui_truetype.Text`.
    FontSystem: type,
    /// `zui_debug`'s inspector, and its zone timer, which passes each zone
    /// on to Tracy.
    inspector: bool,
    /// The renderer as the tour names it to the user.
    renderer_name: []const u8,
};

/// The `Ui` the tour declares through for `spec`, which screens it offers,
/// and the `Shell` each screen declares with.
pub fn Kit(comptime spec: Spec) type {
    return struct {
        pub const zui = @import("zui");
        pub const zui_widgets = @import("zui_widgets");
        pub const zui_reflect = @import("zui_reflect");
        pub const zui_async = @import("zui_async");
        pub const Perf = shared.Perf;
        pub const Sources = shared.Sources;
        pub const Screen = shared.Screen;
        pub const Typeface = shared.Typeface;
        pub const Palette = shared.Palette;
        pub const Tone = shared.Tone;
        pub const EnvironmentQueue = shared.EnvironmentQueue;
        pub const hueColor = shared.hueColor;

        pub const Renderer = spec.Renderer;
        pub const renderer_name = spec.renderer_name;
        pub const Text = shared.Text(spec.FontSystem, spec.Renderer);
        pub const Fonts = Text.Fonts;
        /// Times each zone for `zui_debug`'s panel, and passes it on to Tracy.
        pub const ZoneTimer = if (spec.inspector) zui_debug.ZoneTimer(zui_tracy.Tracer) else void;

        pub const config = zui_app.contextConfig(Renderer, .{
            .Text = Text,
            .Sources = Sources,
            .features = .{ .semantics = true, .Tracer = ZoneTimer },
            .limits = .{
                .max_elements = 16384,
                .max_depth = 128,
                .max_text_bytes = 256 * 1024,
                .max_render_commands = 32768,
                .state_slots = 4096,
                .measure_cache_entries = 8192,
                .string_cache_entries = 4096,
            },
        });
        pub const Ui = zui.Context(config);
        pub const Inspector = if (spec.inspector) zui_debug.Inspector(Ui) else void;
        pub const Widgets = zui_widgets.Widgets(Ui);
        pub const TextStyle = Ui.TextStyle;

        pub const draws_frost = config.commands.contains(.backdrop_blur);
        pub const draws_transforms = config.commands.contains(.transform);
        /// The renderer's materials, which the materials screen shows only
        /// when they offer the patterns it picks between.
        pub const Material = config.MaterialHandle;
        pub const draws_material_patterns = config.commands.contains(.material) and shared.offersPatterns(Material);

        /// The screens this renderer draws everything of, in the rail's order.
        pub const offered_screens: []const Screen = offered: {
            var screens: []const Screen = &.{};
            for (std.enums.values(Screen)) |screen| {
                if (offers(screen)) screens = screens ++ .{screen};
            }
            break :offered screens;
        };

        pub fn offers(comptime screen: Screen) bool {
            return switch (screen) {
                .transforms => draws_transforms,
                .materials => draws_material_patterns,
                else => true,
            };
        }

        /// The screen's place in the rail.
        pub fn positionOf(screen: Screen) usize {
            return std.mem.indexOfScalar(Screen, offered_screens, screen) orelse 0;
        }

        /// Ctrl+1 to Ctrl+9, then Ctrl+0, reach the first ten screens; the
        /// rest have no digit.
        pub fn shortcutDigit(screen: Screen) ?u8 {
            const position = positionOf(screen);
            return if (position < 10) @intCast((position + 1) % 10) else null;
        }

        pub fn info(screen: Screen) Screen.Info {
            return switch (screen) {
                .welcome => .{ .title = "Welcome", .tagline = "A guided tour of zui, drawn by " ++ renderer_name, .features = &.{ "requestFrameAt", "floating", "focus" }, .hue = 0.62 },
                .layout_lab => .{ .title = "Layout Lab", .tagline = "Every sizing rule, alignment and gap, live", .features = &.{ "fit/grow/fixed/percent", "zui_reflect", "rectOf" }, .hue = 0.55 },
                .box_storm => .{ .title = "Box Storm", .tagline = "Thousands of elements, timed every frame", .features = &.{ "16k elements", "string cache", "depth 90" }, .hue = 0.0 },
                .gallery => .{ .title = "Infinite Gallery", .tagline = "10,000 tiles loaded only when seen", .features = &.{ "KeyedLoads", "virtual scroll", "cancellation" }, .hue = 0.8 },
                .mission_control => .{ .title = "Mission Control", .tagline = "Threads publish; the UI never waits", .features = &.{ "Latest", "Stream", "Task" }, .hue = 0.08 },
                .window_manager => .{ .title = "Window Manager", .tagline = "Floating layers, anchors and focus scopes", .features = &.{ "floating z", "anchors", "focus scope" }, .hue = 0.45 },
                .robot_workshop => .{ .title = "Robot Workshop", .tagline = "An editor generated from a struct", .features = &.{ "zui_reflect", "widgets", "environment" }, .hue = 0.3 },
                .pixel_pad => .{ .title = "Pixel Pad", .tagline = "Pointer, keys, chords and typed text", .features = &.{ "pointerLocal", "chords", "keyEvents" }, .hue = 0.92 },
                .typography => .{ .title = "Typography", .tagline = "Three TrueType fonts, wrapping and spacing", .features = &.{ "wrap modes", "letter spacing", "zoom" }, .hue = 0.15 },
                .light_and_depth => if (draws_frost)
                    .{ .title = "Light & Depth", .tagline = "Gradients in OKLab, shadows, glow and frost", .features = &.{ "Gradient", "Shadow", "BackdropBlur" }, .hue = 0.75 }
                else
                    .{ .title = "Light & Depth", .tagline = "Gradients in OKLab, shadows and glow", .features = &.{ "Gradient", "Shadow", "glow" }, .hue = 0.75 },
                .transforms => .{ .title = "Transforms", .tagline = "Moved, scaled and turned as painted, hit where drawn", .features = &.{ "Transform", "hit inversion", "origin" }, .hue = 0.5 },
                .materials => .{ .title = "Materials", .tagline = "The renderer's own shader, or its fallback", .features = &.{ "Material", "phase", "fallback" }, .hue = 0.4 },
                .classic => .{ .title = "Classic", .tagline = "The showcase every zui renderer shares", .features = &.{ "shared demo", "compare renderers" }, .hue = 0.7 },
            };
        }

        /// Moves `position` with the pointer while `handle` is pressed,
        /// keeping the point that was grabbed under the pointer. Returns
        /// whether it is dragging.
        pub fn drag(ui: *Ui, handle: zui.Id, position: *[2]f32) bool {
            const grip = ui.state(handle, shared.DragGrip);
            if (!ui.pressed(handle)) {
                grip.active = false;
                return false;
            }
            const pointer = ui.primaryPointer() orelse return false;
            if (!grip.active) {
                grip.active = true;
                grip.grab_offset = .{ pointer.position[0] - position[0], pointer.position[1] - position[1] };
            }
            position.* = .{ pointer.position[0] - grip.grab_offset[0], pointer.position[1] - grip.grab_offset[1] };
            return true;
        }

        fn widgetTheme(palette: Palette, text_scale: f32, fonts: Fonts) Widgets.Theme {
            return .{
                .text = .{ .size = 16 * text_scale, .color = palette.text, .font = fonts.body },
                .muted_text_color = palette.muted,
                .disabled_text_color = palette.faint,
                .control = .init(.{
                    .idle = palette.raised,
                    .hovered = palette.hovered,
                    .pressed = palette.accent,
                    .focused = palette.raised,
                    .disabled = palette.sunken,
                }),
                .field_background = palette.sunken,
                .border_color = palette.border,
                .accent = palette.accent,
                .check_mark = palette.on_accent,
                .track = palette.border,
                .thumb = palette.text,
                .caret = palette.text,
                .focus_ring = palette.focus,
                .popup_background = palette.surface,
                .option_highlight = palette.hovered,
                .selected_option = palette.accent.mix(palette.surface, 0.6),
                .corner_radius = 5,
                .control_height = @round(30 * text_scale),
                .label_width = 150,
            };
        }

        /// Everything a screen needs besides its own state, rebuilt each
        /// frame from the environment the host last reported.
        pub const Shell = struct {
            io: std.Io,
            palette: Palette,
            widgets: Widgets,
            fonts: Fonts,
            text_scale: f32,
            reduced_motion: bool,
            /// Seconds since the tour started, from the frame record's clock.
            seconds: f64,
            perf: *const Perf,
            sources: *Sources,
            waker: zui.Waker,
            environment_changes: *EnvironmentQueue,
            requested_screen: *?Screen,

            pub fn init(ui: *const Ui, io: std.Io, seconds: f64, fonts: Fonts, perf: *const Perf, sources: *Sources, waker: zui.Waker, environment_changes: *EnvironmentQueue, requested_screen: *?Screen) Shell {
                const environment = ui.environment();
                const palette: Palette = .forEnvironment(environment);
                const text_scale = std.math.clamp(environment.text_scale, 0.5, 2);
                const theme = widgetTheme(palette, text_scale, fonts);
                return .{
                    .io = io,
                    .palette = palette,
                    .widgets = .{ .theme = theme, .dark_theme = theme },
                    .fonts = fonts,
                    .text_scale = text_scale,
                    .reduced_motion = environment.reduced_motion,
                    .seconds = seconds,
                    .perf = perf,
                    .sources = sources,
                    .waker = waker,
                    .environment_changes = environment_changes,
                    .requested_screen = requested_screen,
                };
            }

            pub fn font(self: *const Shell, typeface: Typeface) Ui.FontId {
                return switch (typeface) {
                    inline else => |named| @field(self.fonts, @tagName(named)),
                };
            }

            pub fn style(self: *const Shell, tone: Tone, color: zui.Color) TextStyle {
                return .{
                    .size = tone.size() * self.text_scale,
                    .color = color,
                    .font = switch (tone) {
                        .hero, .title, .heading => self.fonts.bold,
                        .body, .caption, .tiny => self.fonts.body,
                    },
                    .letter_spacing = if (tone == .hero) 2 else 0,
                };
            }

            pub fn defaultColor(self: *const Shell, tone: Tone) zui.Color {
                return switch (tone) {
                    .caption, .tiny => self.palette.muted,
                    else => self.palette.text,
                };
            }

            pub fn label(self: *const Shell, ui: *Ui, tone: Tone, content: []const u8) void {
                ui.text(content, self.style(tone, self.defaultColor(tone)));
            }

            pub fn labelColored(self: *const Shell, ui: *Ui, tone: Tone, color: zui.Color, content: []const u8) void {
                ui.text(content, self.style(tone, color));
            }

            /// The formatted text is copied by `ui.text`, so the stack buffer may die here.
            pub fn print(self: *const Shell, ui: *Ui, tone: Tone, comptime format: []const u8, arguments: anytype) void {
                self.printColored(ui, tone, self.defaultColor(tone), format, arguments);
            }

            pub fn printColored(self: *const Shell, ui: *Ui, tone: Tone, color: zui.Color, comptime format: []const u8, arguments: anytype) void {
                var buffer: [512]u8 = undefined;
                ui.text(std.fmt.bufPrint(&buffer, format, arguments) catch format, self.style(tone, color));
            }

            /// Opens a titled panel; declare its contents, then `ui.close()`.
            pub fn openCard(self: *const Shell, ui: *Ui, title: []const u8, sizing: zui.Sizing2) void {
                self.openCardWith(ui, .{ .layout = .{ .sizing = sizing } }, title);
            }

            /// `openCard` that scrolls its contents vertically when the
            /// window is too short, instead of making the whole screen taller.
            pub fn openScrollingCard(self: *const Shell, ui: *Ui, id: zui.Id, title: []const u8, sizing: zui.Sizing2) void {
                self.openCardWith(ui, .{ .id = id, .layout = .{ .sizing = sizing }, .scroll = .{} }, title);
            }

            fn openCardWith(self: *const Shell, ui: *Ui, element: Ui.Element, title: []const u8) void {
                var card = element;
                card.layout = .{ .direction = .top_to_bottom, .sizing = element.layout.?.sizing, .padding = .all(14), .child_gap = 10 };
                card.decoration = .{ .background = self.palette.surface, .border = .{ .color = self.palette.border, .widths = .all(1) }, .corner_radius = .all(10) };
                ui.open(card);
                if (title.len != 0) self.label(ui, .heading, title);
            }

            pub fn chip(self: *const Shell, ui: *Ui, content: []const u8, color: zui.Color) void {
                ui.open(.{
                    .layout = .{ .padding = .symmetric(8, 3) },
                    .decoration = .{ .background = color.mix(self.palette.surface, 0.8), .border = .{ .color = color, .widths = .all(1) }, .corner_radius = .all(10) },
                });
                self.labelColored(ui, .caption, color, content);
                ui.close();
            }

            /// A labeled slider with its value printed in `format` beside it.
            pub fn sliderRow(self: *const Shell, ui: *Ui, id: zui.Id, name: []const u8, value: *f32, minimum: f64, maximum: f64, step: f64, comptime format: []const u8) void {
                self.widgets.labeledRow(ui, name);
                defer ui.close();
                _ = self.widgets.slider(ui, id, value, .{ .min = minimum, .max = maximum, .step = step });
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(40) }, .child_alignment = .{ .x = .end } } });
                self.print(ui, .caption, format, .{value.*});
                ui.close();
            }

            pub fn spacer(_: *const Shell, ui: *Ui) void {
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } } });
            }

            pub fn divider(self: *const Shell, ui: *Ui) void {
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(1) } }, .decoration = .{ .background = self.palette.border } });
            }

            pub fn meter(self: *const Shell, ui: *Ui, fraction: f32, color: zui.Color, height: f32) void {
                const clamped = std.math.clamp(fraction, 0, 1);
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(height) } },
                    .decoration = .{ .background = self.palette.sunken, .corner_radius = .all(height / 2) },
                });
                if (clamped > 0) ui.box(.{
                    .layout = .{ .sizing = .{ .width = .percent(clamped), .height = .grow } },
                    .decoration = .{ .background = color, .corner_radius = .all(height / 2) },
                });
                ui.close();
            }

            /// Asks the next frame for an environment change, as an OS
            /// would report one; widgets and the palette follow it.
            pub fn changeEnvironment(self: *const Shell, change: zui.EnvironmentChange) void {
                self.environment_changes.push(change);
            }

            /// 0 under reduced motion, so animations hold still.
            pub fn motionSeconds(self: *const Shell) f32 {
                return if (self.reduced_motion) 0 else @floatCast(self.seconds);
            }
        };
    };
}
