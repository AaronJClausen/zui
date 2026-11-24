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
        pub const zui_design = @import("zui_design");
        pub const zui_reflect = @import("zui_reflect");
        pub const zui_async = @import("zui_async");
        pub const zui_motion = @import("zui_motion");
        pub const Perf = shared.Perf;
        pub const Sources = shared.Sources;
        pub const Screen = shared.Screen;
        pub const Lane = shared.Lane;
        pub const DemandedProducer = shared.DemandedProducer;
        pub const Typeface = shared.Typeface;
        pub const Colors = shared.Colors;
        pub const Emphasis = shared.Emphasis;
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
                .exit_ghost_commands = 1024,
            },
        });
        pub const Ui = zui.Context(config);
        pub const Inspector = if (spec.inspector) zui_debug.Inspector(Ui) else void;
        pub const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
        pub const TextStyle = Ui.TextStyle;

        pub const draws_frost = config.commands.contains(.backdrop_blur);
        pub const draws_every_corner_shape = config.corner_shapes.eql(.initFull());
        /// Of every card and panel. A renderer that draws only round
        /// corners draws these round and reports it in `Diagnostics`.
        pub const panel_corner_shape: zui.CornerShape = .continuous;
        pub const draws_transforms = config.commands.contains(.transform);
        /// The renderer's materials, which the light lab shows only when
        /// they offer the patterns it picks between.
        pub const Material = config.MaterialHandle;
        pub const draws_material_patterns = config.commands.contains(.material) and shared.offersPatterns(Material);

        /// The screens this renderer draws everything of, in the order
        /// Ctrl+PgDn steps through them.
        pub const offered_screens: []const Screen = offered: {
            var screens: []const Screen = &.{};
            for (std.enums.values(Screen)) |screen| {
                if (offers(screen)) screens = screens ++ .{screen};
            }
            break :offered screens;
        };

        pub fn offers(comptime screen: Screen) bool {
            return switch (screen) {
                .clickable_chaos => draws_transforms,
                else => true,
            };
        }

        /// The rail's rows for these screens, and the id of the list they
        /// are the rows of.
        pub const rail = @import("tour.zig").RailRows(@This());
        pub const rail_screens_id = @import("tour.zig").rail_screens_id;

        /// The screen's place in `offered_screens`.
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
                .overview => .{ .title = "Overview", .tagline = "Four ways to see zui, drawn by " ++ renderer_name, .lane = .start, .features = &.{ "flagship", "field cases", "spectacles" } },
                .harbor => .{ .title = "Harbor", .tagline = "An operations console built on zui", .lane = .flagship, .features = &.{ "sources", "virtual scroll", "floating", "focus" } },
                .x_ray => .{ .title = "Harbor X-ray", .tagline = "The same console, with every feature pointed out", .lane = .flagship, .features = &.{ "rectOf", "attach_to", "live counts" } },
                .photo_cull => .{ .title = "Photo Culling", .tagline = "Thousands of photos, loaded only when seen", .lane = .field_case, .features = &.{ "KeyedLoads", "cancellation", "keyboard" } },
                .log_tail => .{ .title = "Log Tail", .tagline = "Follow a busy service's log without stalling", .lane = .field_case, .features = &.{ "Stream", "Latest", "framesSinceRead" } },
                .kanban => .{ .title = "Kanban", .tagline = "Cards dragged between lists, or moved by keys", .lane = .field_case, .features = &.{ "drag and drop", "focus", "actions" } },
                .settings_form => .{ .title = "Settings Form", .tagline = "A form that holds up at any size and direction", .lane = .field_case, .features = &.{ "textField", "validation", "right-to-left" } },
                .field_guide => .{ .title = "Field Guide", .tagline = "A docs browser's section tabs, trail, cards, menus and popovers", .lane = .field_case, .features = &.{ "tabs", "menu", "popover" } },
                .quiet_machine => .{ .title = "Quiet Machine", .tagline = "A busy page that declares almost no frames", .lane = .spectacle, .features = &.{ "requestFrameAt", "NextFrame", "idle" } },
                .time_machine => .{ .title = "Time Machine", .tagline = "Scrub a session back and forth, frame by frame", .lane = .spectacle, .features = &.{ "determinism", "replay", "scrubbing" } },
                .break_it => .{ .title = "Break It", .tagline = "Push every limit and watch nothing corrupt", .lane = .spectacle, .features = &.{ "Limits", "Diagnostics", "graceful" } },
                .gesture_arena => .{ .title = "Gesture Arena", .tagline = "Nested gestures, each going to its owner", .lane = .spectacle, .features = &.{ "Gestures", "momentum", "claim" } },
                .light_lab => .{ .title = "Light Lab", .tagline = "Gradients, shadows, frost, materials and corners, or their fallbacks", .lane = .spectacle, .features = &.{ "Effects", "Material", "CornerShape" } },
                .one_declaration => .{ .title = "One Declaration", .tagline = "The same UI in every theme, size and direction", .lane = .spectacle, .features = &.{ "Environment", "right-to-left", "contrast" } },
                .cabin_booking => .{ .title = "Cabin Booking", .tagline = "A booking form of steppers, switches, chips, a dialog and toasts", .lane = .field_case, .features = &.{ "numberStepper", "dialog", "toasts" } },
                .clickable_chaos => .{ .title = "Clickable Chaos", .tagline = "Hundreds of turning cards, each hit where drawn", .lane = .spectacle, .features = &.{ "Transform", "hit inversion" } },
                .preferences => .{ .title = "Preferences", .tagline = "Density, color vision, contrast and text size, for the whole tour", .lane = .start, .features = &.{ "zui_design", "Tokens", "Preferences" } },
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

        pub const Tokens = zui.design.Tokens(Ui, void);

        /// The tokens the tour and its widgets are styled from, resolved
        /// again only when the preferences they follow change.
        pub const Appearance = struct {
            tokens: Tokens = .{},
            preferences: ?zui_design.Preferences = null,

            pub fn follow(self: *Appearance, preferences: zui_design.Preferences, fonts: Fonts) void {
                if (self.preferences) |current| if (std.meta.eql(current, preferences)) return;
                self.preferences = preferences;
                _ = zui_design.resolve(designWith(fonts), preferences, &self.tokens);
            }

            pub fn colors(self: *const Appearance) Colors {
                return self.tokens.colors.get(.idle);
            }
        };

        /// What the user chose on the preferences screen over what the
        /// environment reports. A null contrast or text scale follows the
        /// environment's.
        pub const PreferenceChoices = struct {
            density: zui.design.Density = .comfortable,
            color_vision: zui_design.ColorVision = .typical,
            contrast: ?zui.Environment.Contrast = null,
            text_scale: ?f32 = null,
        };

        /// The text scales the tour's layout still fits.
        pub const text_scale_range: [2]f32 = .{ 0.5, 2 };

        /// The environment's preferences with the user's `choices`, the
        /// text scale held where the tour's layout still fits.
        pub fn preferencesOf(environment: *const zui.Environment, choices: PreferenceChoices) zui_design.Preferences {
            var preferences: zui_design.Preferences = .from(environment, .{ .density = choices.density, .color_vision = choices.color_vision });
            if (choices.contrast) |contrast| preferences.contrast = contrast;
            preferences.text_scale = std.math.clamp(choices.text_scale orelse environment.text_scale, text_scale_range[0], text_scale_range[1]);
            return preferences;
        }

        /// The tour's background under `environment`'s preferences, for a
        /// renderer to clear to before the tour has declared a frame.
        pub fn backgroundOf(environment: *const zui.Environment) zui.Color {
            var tokens: Tokens = .{};
            _ = zui_design.resolve(zui_design.default, preferencesOf(environment, .{}), &tokens);
            return tokens.colors.get(.idle).get(.background);
        }

        fn designWith(fonts: Fonts) zui.design.Design {
            var with_fonts = zui_design.default;
            with_fonts.type.fonts = .{
                .regular = fontIndex(fonts.body),
                .strong = fontIndex(fonts.bold),
                .monospace = fontIndex(fonts.mono),
                .italic = fontIndex(fonts.italic),
                .strong_italic = fontIndex(fonts.bold_italic),
            };
            return with_fonts;
        }

        fn fontIndex(font: Ui.FontId) u32 {
            return switch (@typeInfo(Ui.FontId)) {
                .@"enum" => @intFromEnum(font),
                else => font,
            };
        }

        /// Everything a screen needs besides its own state, rebuilt each
        /// frame from the environment the host last reported and the
        /// tokens resolved for it.
        pub const Shell = struct {
            io: std.Io,
            tokens: *const Tokens,
            colors: Colors,
            /// The preferences the tokens were resolved for.
            preferences: zui_design.Preferences,
            /// The tour's, which the preferences screen changes.
            preference_choices: *PreferenceChoices,
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

            /// `appearance` has followed the preferences of this frame.
            pub fn init(ui: *const Ui, io: std.Io, seconds: f64, fonts: Fonts, appearance: *const Appearance, preference_choices: *PreferenceChoices, perf: *const Perf, sources: *Sources, waker: zui.Waker, environment_changes: *EnvironmentQueue, requested_screen: *?Screen) Shell {
                const environment = ui.environment();
                const preferences = appearance.preferences orelse preferencesOf(environment, preference_choices.*);
                return .{
                    .io = io,
                    .tokens = &appearance.tokens,
                    .colors = appearance.colors(),
                    .preferences = preferences,
                    .preference_choices = preference_choices,
                    .widgets = .{ .skin = .{ .tokens = &appearance.tokens } },
                    .fonts = fonts,
                    .text_scale = preferences.text_scale,
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
                    .letter_spacing = 0,
                };
            }

            pub fn defaultColor(self: *const Shell, tone: Tone) zui.Color {
                return switch (tone) {
                    .caption, .tiny => self.colors.get(.on_surface_muted),
                    else => self.colors.get(.on_surface),
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
                card.layout = .{ .direction = .top_to_bottom, .sizing = element.layout.?.sizing, .padding = .all(16), .child_gap = 10 };
                card.decoration = .{ .background = self.colors.get(.surface), .border = .{ .color = self.colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8), .corner_shape = panel_corner_shape };
                ui.open(card);
                if (title.len != 0) self.label(ui, .heading, title);
            }

            /// A page's opening: a small colored eyebrow, its title, and a
            /// sentence saying what it is for.
            pub fn pageHeading(self: *const Shell, ui: *Ui, eyebrow: []const u8, title: []const u8, description: []const u8) void {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
                defer ui.close();
                self.labelColored(ui, .caption, self.colors.get(.on_surface_accent), eyebrow);
                self.label(ui, .title, title);
                self.labelColored(ui, .body, self.colors.get(.on_surface_muted), description);
            }

            /// The lane's name in a quiet pill of its color.
            pub fn lanePill(self: *const Shell, ui: *Ui, lane: Lane) void {
                const emphasis = lane.emphasis();
                ui.open(.{
                    .layout = .{ .padding = .symmetric(8, 2) },
                    .decoration = .{ .background = emphasis.container(self.colors), .corner_radius = .all(9) },
                });
                self.labelColored(ui, .tiny, emphasis.onContainer(self.colors), lane.name());
                ui.close();
            }

            /// Shows `screen` from the next frame on.
            pub fn requestScreen(self: *const Shell, screen: Screen) void {
                self.requested_screen.* = screen;
            }

            pub fn chip(self: *const Shell, ui: *Ui, content: []const u8, emphasis: Emphasis) void {
                ui.open(.{
                    .layout = .{ .padding = .symmetric(8, 3) },
                    .decoration = .{ .background = emphasis.container(self.colors), .border = .{ .color = emphasis.fill(self.colors), .widths = .all(1) }, .corner_radius = .all(10) },
                });
                self.labelColored(ui, .caption, emphasis.onContainer(self.colors), content);
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
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(1) } }, .decoration = .{ .background = self.colors.get(.outline_muted) } });
            }

            pub fn meter(self: *const Shell, ui: *Ui, fraction: f32, color: zui.Color, height: f32) void {
                const clamped = std.math.clamp(fraction, 0, 1);
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(height) } },
                    .decoration = .{ .background = self.colors.get(.surface_sunken), .corner_radius = .all(height / 2) },
                });
                if (clamped > 0) ui.box(.{
                    .layout = .{ .sizing = .{ .width = .percent(clamped), .height = .grow } },
                    .decoration = .{ .background = color, .corner_radius = .all(height / 2) },
                });
                ui.close();
            }

            /// Asks the next frame for an environment change, as an OS
            /// would report one; the tokens follow it.
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
