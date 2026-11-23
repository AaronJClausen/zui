const std = @import("std");
const zui = @import("zui");

const Density = enum { comfortable, compact };

/// What one view of the invoice is declared under. A null theme or contrast
/// follows the environment's.
const Variant = struct {
    name: []const u8,
    parameter: []const u8,
    theme: ?zui.Environment.Theme = null,
    contrast: ?zui.Environment.Contrast = null,
    text_factor: f32 = 1,
    mirrored: bool = false,
    density: Density = .comfortable,
};

const variants = [_]Variant{
    .{ .name = "Dark", .parameter = ".theme = .dark", .theme = .dark },
    .{ .name = "Light", .parameter = ".theme = .light", .theme = .light },
    .{ .name = "High contrast", .parameter = ".contrast = .high", .contrast = .high },
    .{ .name = "150% text", .parameter = ".text_factor = 1.5", .text_factor = 1.5 },
    .{ .name = "Right to left", .parameter = ".mirrored = true", .mirrored = true },
    .{ .name = "Compact", .parameter = ".density = .compact", .density = .compact, .text_factor = 0.9 },
};

const columns = 3;

const LineItem = struct { name: []const u8, cents: u32 };

const line_items = [_]LineItem{
    .{ .name = "Design review", .cents = 120000 },
    .{ .name = "Hosting, March", .cents = 8600 },
    .{ .name = "Support plan", .cents = 24000 },
};

const total_cents = total: {
    var sum: u32 = 0;
    for (line_items) |item| sum += item.cents;
    break :total sum;
};

const deposit_cents = 74000;

const text_scale_steps = [_]f32{ 1, 1.25, 1.5 };

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const Palette = kit.Palette;
    const Tone = kit.Tone;
    const Widgets = kit.Widgets;
    return struct {
        /// One function declares an invoice; the page shows it under six
        /// sets of parameters, all reading the same state, and changes the
        /// tour's real environment on request.
        pub const OneDeclaration = struct {
            paid_cents: u32 = deposit_cents,
            autopay: bool = true,
            receipts: bool = false,
            /// Each view's widgets' tokens, for its theme, contrast, text
            /// size and density.
            appearances: [variants.len]kit.Appearance = @splat(.{}),

            pub fn declare(self: *OneDeclaration, ui: *Ui, shell: *const Shell) void {
                environmentBar(ui, shell);
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    defer ui.close();
                    shell.labelColored(ui, .caption, shell.palette.muted, "Per subtree, as parameters: palette, text size, spacing and layout.mirrored. The environment's, for the whole tour: theme, contrast, text scale and reading direction.");
                }
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                var index: usize = 0;
                while (index < variants.len) : (index += columns) {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    for (variants[index..@min(index + columns, variants.len)], index..) |variant, variant_index| {
                        self.variantPanel(ui, shell, variant, variant_index);
                    }
                }
            }

            fn variantPanel(self: *OneDeclaration, ui: *Ui, shell: *const Shell, variant: Variant, variant_index: usize) void {
                const palette = shell.palette;
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal, .height = .grow }, .child_gap = 6 } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.label(ui, .body, variant.name);
                    shell.spacer(ui);
                    ui.text(variant.parameter, .{ .font = shell.fonts.mono, .size = 12 * shell.text_scale, .color = palette.faint, .wrap = .none });
                }
                const appearance = &self.appearances[variant_index];
                const look: Look = .of(ui.environment(), variant, shell, appearance);
                ui.open(.{
                    .id = .indexed("one_declaration.view", variant_index),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(look.gap), .mirrored = if (variant.mirrored) .yes else .inherit },
                    .decoration = .{ .background = look.palette.background, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                    .scroll = .{},
                });
                defer ui.close();
                self.invoice(ui, look, variant_index);
            }

            /// The one declaration every view shares.
            fn invoice(self: *OneDeclaration, ui: *Ui, look: Look, variant_index: usize) void {
                const palette = look.palette;
                const paid = self.paid_cents >= total_cents;
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(look.padding), .child_gap = look.gap },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = look.gap, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    look.label(ui, .heading, palette.text, "Invoice 1042");
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    look.pill(ui, if (paid) "Paid" else "Due in 5 days", if (paid) palette.good else palette.warn);
                }
                for (line_items) |item| {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = look.gap } });
                    defer ui.close();
                    look.label(ui, .caption, palette.muted, item.name);
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    look.amount(ui, .caption, palette.text, item.cents);
                }
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(1) } }, .decoration = .{ .background = palette.border } });
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = look.gap } });
                    defer ui.close();
                    look.label(ui, .body, palette.text, "Total");
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    look.amount(ui, .body, palette.text, total_cents);
                }
                look.progress(ui, @as(f32, @floatFromInt(self.paid_cents)) / total_cents);
                {
                    var buffer: [32]u8 = undefined;
                    look.label(ui, .tiny, palette.muted, std.fmt.bufPrint(&buffer, "{f} paid", .{Money{ .cents = self.paid_cents }}) catch "");
                }
                look.toggle(ui, .indexed("one_declaration.autopay", variant_index), "Autopay", &self.autopay);
                look.toggle(ui, .indexed("one_declaration.receipts", variant_index), "Email receipts", &self.receipts);
                const widgets = look.widgets();
                if (paid) {
                    if (widgets.button(ui, .indexed("one_declaration.undo", variant_index), "Undo payment", .{ .width = .grow })) self.paid_cents = deposit_cents;
                } else {
                    var buffer: [32]u8 = undefined;
                    const content = std.fmt.bufPrint(&buffer, "Pay {f}", .{Money{ .cents = total_cents - self.paid_cents }}) catch "Pay";
                    if (widgets.button(ui, .indexed("one_declaration.pay", variant_index), content, .{ .width = .grow })) self.paid_cents = total_cents;
                }
            }
        };

        /// Everything a view's declaration reads besides the shared state.
        const Look = struct {
            palette: Palette,
            text_scale: f32,
            padding: f32,
            gap: f32,
            control_height: f32,
            fonts: kit.Fonts,
            tokens: *const kit.Tokens,

            fn of(environment: *const zui.Environment, variant: Variant, shell: *const Shell, appearance: *kit.Appearance) Look {
                var variant_environment = environment.*;
                if (variant.theme) |theme| variant_environment.theme = theme;
                if (variant.contrast) |contrast| variant_environment.contrast = contrast;
                const compact = variant.density == .compact;
                const text_scale = shell.text_scale * variant.text_factor;
                var preferences = kit.preferencesOf(&variant_environment);
                preferences.text_scale = text_scale;
                preferences.density = if (compact) .compact else .comfortable;
                appearance.follow(preferences, shell.fonts);
                return .{
                    .tokens = &appearance.tokens,
                    .palette = .forEnvironment(&variant_environment),
                    .text_scale = text_scale,
                    .padding = if (compact) 8 else 14,
                    .gap = if (compact) 4 else 8,
                    .control_height = @round(@as(f32, if (compact) 24 else 30) * text_scale),
                    .fonts = shell.fonts,
                };
            }

            fn style(look: Look, tone: Tone, color: zui.Color) Ui.TextStyle {
                return .{
                    .size = tone.size() * look.text_scale,
                    .color = color,
                    .font = switch (tone) {
                        .hero, .title, .heading => look.fonts.bold,
                        .body, .caption, .tiny => look.fonts.body,
                    },
                };
            }

            fn label(look: Look, ui: *Ui, tone: Tone, color: zui.Color, content: []const u8) void {
                ui.text(content, look.style(tone, color));
            }

            fn amount(look: Look, ui: *Ui, tone: Tone, color: zui.Color, cents: u32) void {
                var buffer: [32]u8 = undefined;
                var styled = look.style(tone, color);
                styled.wrap = .none;
                ui.text(std.fmt.bufPrint(&buffer, "{f}", .{Money{ .cents = cents }}) catch "", styled);
            }

            fn pill(look: Look, ui: *Ui, content: []const u8, color: zui.Color) void {
                ui.open(.{
                    .layout = .{ .padding = .symmetric(8, 2) },
                    .decoration = .{ .background = color.mix(look.palette.surface, 0.82), .corner_radius = .all(9) },
                });
                var styled = look.style(.tiny, color);
                styled.wrap = .none;
                ui.text(content, styled);
                ui.close();
            }

            fn progress(look: Look, ui: *Ui, fraction: f32) void {
                const clamped = std.math.clamp(fraction, 0, 1);
                ui.open(.{
                    .semantics = .{ .role = .progress_bar, .label = "paid", .value = .{ .range = .{ .value = clamped } } },
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(6) } },
                    .decoration = .{ .background = look.palette.sunken, .corner_radius = .all(3) },
                });
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .percent(clamped), .height = .grow } },
                    .decoration = .{ .background = if (clamped >= 1) look.palette.good else look.palette.accent, .corner_radius = .all(3) },
                });
                ui.close();
            }

            /// A switch: its knob sits at the start when off and the end
            /// when on, so a mirrored view moves it the other way.
            fn toggle(look: Look, ui: *Ui, id: zui.Id, content: []const u8, on: *bool) void {
                if (ui.clicked(id)) on.* = !on.*;
                const palette = look.palette;
                const track_height = @round(look.control_height * 0.6);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .semantics = .{ .role = .toggle, .label = content, .state = .{ .checked = on.* } },
                    .layout = .{ .sizing = .{ .width = .grow }, .child_gap = look.gap, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else null, .corner_radius = .all(4) },
                });
                defer ui.close();
                look.label(ui, .caption, palette.text, content);
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .fixed(track_height * 1.8), .height = .fixed(track_height) }, .padding = .all(2), .child_alignment = .{ .x = if (on.*) .end else .start } },
                    .decoration = .{ .background = if (on.*) palette.accent else palette.border, .corner_radius = .all(track_height / 2) },
                });
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(track_height - 4), .height = .fixed(track_height - 4) } },
                    .decoration = .{ .background = if (on.*) palette.on_accent else palette.surface, .corner_radius = .all((track_height - 4) / 2) },
                });
                ui.close();
            }

            fn widgets(look: Look) Widgets {
                return .{ .skin = .{ .tokens = look.tokens } };
            }
        };

        fn environmentBar(ui: *Ui, shell: *const Shell) void {
            const widgets = shell.widgets;
            const environment = ui.environment();
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            shell.label(ui, .body, "The environment:");
            const dark = environment.theme == .dark;
            if (widgets.button(ui, .of("one_declaration.theme"), if (dark) "Theme: dark" else "Theme: light", .{})) shell.changeEnvironment(.{ .theme = if (dark) .light else .dark });
            const high = environment.contrast == .high;
            if (widgets.button(ui, .of("one_declaration.contrast"), if (high) "Contrast: high" else "Contrast: normal", .{})) shell.changeEnvironment(.{ .contrast = if (high) .normal else .high });
            var scale_buffer: [24]u8 = undefined;
            const scale_label = std.fmt.bufPrint(&scale_buffer, "Text: {d:.0}%", .{environment.text_scale * 100}) catch "Text";
            if (widgets.button(ui, .of("one_declaration.text_scale"), scale_label, .{})) shell.changeEnvironment(.{ .text_scale = nextTextScale(environment.text_scale) });
            const right_to_left = environment.direction == .right_to_left;
            if (widgets.button(ui, .of("one_declaration.direction"), if (right_to_left) "Direction: right to left" else "Direction: left to right", .{})) shell.changeEnvironment(.{ .direction = if (right_to_left) .left_to_right else .right_to_left });
            const changed = environment.contrast != .normal or environment.text_scale != 1 or environment.direction != .left_to_right;
            if (widgets.button(ui, .of("one_declaration.reset"), "Reset", .{ .disabled = !changed })) {
                shell.changeEnvironment(.{ .contrast = .normal });
                shell.changeEnvironment(.{ .text_scale = 1 });
                shell.changeEnvironment(.{ .direction = .left_to_right });
            }
        }

        fn nextTextScale(current: f32) f32 {
            for (text_scale_steps) |step| {
                if (step > current + 0.01) return step;
            }
            return text_scale_steps[0];
        }
    };
}

const Money = struct {
    cents: u32,

    pub fn format(money: Money, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const dollars = money.cents / 100;
        if (dollars >= 1000) {
            try writer.print("${d},{d:0>3}", .{ dollars / 1000, dollars % 1000 });
        } else {
            try writer.print("${d}", .{dollars});
        }
        try writer.print(".{d:0>2}", .{money.cents % 100});
    }
};
