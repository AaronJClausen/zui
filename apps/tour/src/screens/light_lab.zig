const std = @import("std");
const zui = @import("zui");

const drifting_shape_count = 7;

const srgb_steps = 16;

/// The longest step the scene takes in one frame, so a frame after a long
/// sleep does not jump it.
const longest_step_seconds = 0.1;

const scene_id: zui.Id = .of("light_lab.scene");

fn rgbOf(color: zui.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

fn rgbaOf(color: zui.Color) u32 {
    return rgbOf(color) << 8 | color.a;
}

fn alphaOf(fraction: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(fraction, 0, 1) * 255));
}

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const Material = kit.Material;
    const patterns = if (kit.draws_material_patterns) std.enums.values(Material.Pattern) else &[_]void{};
    return struct {
        /// Gradients, shadows, frost and the renderer's materials over a
        /// drifting scene, and the three corner shapes, each beside what a
        /// renderer without it draws.
        pub const LightLab = struct {
            angle_degrees: f32 = 35,
            from_hue: f32 = 0.92,
            to_hue: f32 = 0.58,
            shadow_offset_y: f32 = 16,
            shadow_blur: f32 = 36,
            shadow_spread: f32 = 0,
            shadow_opacity: f32 = 0.6,
            glow: bool = false,
            frost_radius: f32 = 14,
            frost_tint: f32 = 0.18,
            corner_radius: f32 = 20,
            material_pattern_index: usize = if (patterns.len == 0) 0 else patterns.len - 1,
            material_turns_per_second: f32 = 0.1,
            animate: bool = true,
            scene_seconds: f32 = 0,

            pub fn declare(self: *LightLab, ui: *Ui, shell: *const Shell) void {
                if (self.animate and !shell.reduced_motion) {
                    self.scene_seconds += @min(ui.dt(), longest_step_seconds);
                    ui.requestFrame();
                }
                const seconds = self.scene_seconds;

                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                self.controls(ui, shell);
                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    {
                        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                        defer ui.close();
                        self.scene(ui, shell, seconds);
                        self.declarationCode(ui, shell, seconds);
                    }
                    {
                        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(206) }, .child_gap = 12 } });
                        defer ui.close();
                        self.gradientLowering(ui, shell, seconds);
                        self.shadowLowering(ui, shell);
                        self.frostLowering(ui, shell, seconds);
                        self.materialLowering(ui, shell, seconds);
                    }
                }
            }

            fn gradient(self: *const LightLab, seconds: f32) Ui.Gradient {
                return .{
                    .from = kit.hueColor(self.from_hue, 0.75, 0.95),
                    .to = kit.hueColor(self.to_hue, 0.75, 0.95),
                    .angle = std.math.degreesToRadians(self.angle_degrees + seconds * 20),
                };
            }

            fn shadow(self: *const LightLab, shell: *const Shell) Ui.Shadow {
                if (self.glow) {
                    var glow_color = shell.palette.spectacle;
                    glow_color.a = alphaOf(self.shadow_opacity);
                    var glow: Ui.Shadow = .glow(glow_color, self.shadow_blur);
                    glow.spread = self.shadow_spread;
                    return glow;
                }
                return .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = alphaOf(self.shadow_opacity) }, .offset = .{ 0, self.shadow_offset_y }, .blur = self.shadow_blur, .spread = self.shadow_spread };
            }

            fn frost(self: *const LightLab) Ui.BackdropBlur {
                return .{ .radius = self.frost_radius, .tint = .{ .r = 255, .g = 255, .b = 255, .a = alphaOf(self.frost_tint) } };
            }

            fn material(self: *const LightLab, pattern: Material.Pattern, seconds: f32) Material {
                return .{
                    .pattern = pattern,
                    .first = kit.hueColor(self.to_hue, 0.7, 0.35),
                    .second = kit.hueColor(self.from_hue, 0.6, 0.95),
                    .phase = seconds * self.material_turns_per_second,
                    .scale = 64,
                };
            }

            fn materialFallback(self: *const LightLab) zui.Color {
                return kit.hueColor(self.to_hue, 0.7, 0.35);
            }

            fn controls(self: *LightLab, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const palette = shell.palette;
                shell.openScrollingCard(ui, .of("light_lab.controls"), "", .{ .width = .fixed(320), .height = .grow });
                defer ui.close();
                shell.labelColored(ui, .caption, palette.spectacle, "GRADIENT, MIXED IN OKLAB");
                shell.sliderRow(ui, .of("light_lab.angle"), "angle", &self.angle_degrees, 0, 360, 1, "{d:.0}");
                shell.sliderRow(ui, .of("light_lab.from"), "from hue", &self.from_hue, 0, 1, 0.01, "{d:.2}");
                shell.sliderRow(ui, .of("light_lab.to"), "to hue", &self.to_hue, 0, 1, 0.01, "{d:.2}");
                shell.divider(ui);
                shell.labelColored(ui, .caption, palette.spectacle, "SHADOW");
                _ = widgets.checkbox(ui, .of("light_lab.glow"), "a glow: no offset", &self.glow, .{});
                if (!self.glow) shell.sliderRow(ui, .of("light_lab.offset"), "offset y", &self.shadow_offset_y, -40, 40, 1, "{d:.0}");
                shell.sliderRow(ui, .of("light_lab.blur"), "blur", &self.shadow_blur, 0, 80, 1, "{d:.0}");
                shell.sliderRow(ui, .of("light_lab.spread"), "spread", &self.shadow_spread, -20, 30, 1, "{d:.0}");
                shell.sliderRow(ui, .of("light_lab.opacity"), "opacity", &self.shadow_opacity, 0, 1, 0.05, "{d:.2}");
                shell.divider(ui);
                shell.labelColored(ui, .caption, palette.spectacle, "FROST");
                shell.sliderRow(ui, .of("light_lab.frost_radius"), "blur", &self.frost_radius, 0, 40, 1, "{d:.0}");
                shell.sliderRow(ui, .of("light_lab.frost_tint"), "tint", &self.frost_tint, 0, 1, 0.05, "{d:.2}");
                shell.divider(ui);
                shell.labelColored(ui, .caption, palette.spectacle, "MATERIAL");
                if (kit.draws_material_patterns) {
                    ui.open(.{ .layout = .{ .child_gap = 6 } });
                    for (patterns, 0..) |pattern, index| {
                        if (widgets.button(ui, .indexed("light_lab.pattern", index), @tagName(pattern), .{})) self.material_pattern_index = index;
                    }
                    ui.close();
                    shell.sliderRow(ui, .of("light_lab.material_speed"), "turns / s", &self.material_turns_per_second, 0, 0.5, 0.01, "{d:.2}");
                } else {
                    shell.label(ui, .caption, kit.renderer_name ++ " has no materials to show.");
                }
                shell.divider(ui);
                self.cornerShapes(ui, shell);
                shell.sliderRow(ui, .of("light_lab.radius"), "corner radius", &self.corner_radius, 0, 60, 1, "{d:.0}");
                _ = widgets.checkbox(ui, .of("light_lab.animate"), "move the scene", &self.animate, .{});
                if (shell.reduced_motion) shell.label(ui, .caption, "Reduced motion is on, so the scene holds still.");
                if (widgets.button(ui, .of("light_lab.reset"), "Reset", .{})) self.* = .{ .scene_seconds = self.scene_seconds };
            }

            fn scene(self: *const LightLab, ui: *Ui, shell: *const Shell, seconds: f32) void {
                const palette = shell.palette;
                const bounds = ui.rectOf(scene_id) orelse zui.Rect{ .x = 0, .y = 0, .width = 600, .height = 420 };
                ui.open(.{
                    .id = scene_id,
                    .layout = .{ .sizing = .{ .width = .{ .rule = .grow_from_min, .amount = 3 }, .height = .grow }, .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{ .background = palette.sunken, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                    .clip = .both,
                });
                defer ui.close();
                driftingShapes(ui, bounds, seconds);
                {
                    ui.open(.{
                        .floating = .{ .attach_point = .center, .anchor = .center, .z = 2, .clip = .target },
                        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300), .height = .fixed(176) }, .padding = .all(22), .child_gap = 4, .child_alignment = .{ .y = .end } },
                        .decoration = .{ .corner_radius = .all(self.corner_radius) },
                        .effects = &.{ .gradient = self.gradient(seconds), .shadow = self.shadow(shell) },
                    });
                    defer ui.close();
                    ui.text("Light Lab", shell.style(.title, .rgb(0xffffff)));
                    ui.text("a gradient in OKLab over a soft shadow", shell.style(.caption, .rgb(0xffffff)));
                }
                if (kit.draws_frost) {
                    const drift = if (bounds.width > 360) (bounds.width / 2 - 110) * @sin(seconds * 0.5) else 0;
                    ui.open(.{
                        .floating = .{ .attach_point = .center, .anchor = .center, .offset = .{ drift, 70 }, .z = 3, .clip = .target, .capture = false },
                        .layout = .{ .sizing = .{ .width = .fixed(180), .height = .fixed(110) }, .padding = .all(14), .child_alignment = .{ .y = .end } },
                        .decoration = .{ .border = .{ .color = .rgba(0xffffff40), .widths = .all(1) }, .corner_radius = .all(16) },
                        .effects = &.{ .backdrop_blur = self.frost() },
                    });
                    ui.text("frosted", shell.style(.caption, .rgb(0xffffff)));
                    ui.close();
                }
            }

            fn driftingShapes(ui: *Ui, bounds: zui.Rect, seconds: f32) void {
                for (0..drifting_shape_count) |index| {
                    const step: f32 = @floatFromInt(index);
                    const size = 70 + 24 * @mod(step * 1.7, 3);
                    const speed = 0.25 + 0.07 * step;
                    const x = (bounds.width - size) * (0.5 + 0.45 * @sin(seconds * speed + step * 2.3));
                    const y = (bounds.height - size) * (0.5 + 0.45 * @cos(seconds * speed * 0.8 + step * 1.1));
                    ui.box(.{
                        .floating = .{ .offset = .{ x, y }, .z = 1, .clip = .target, .capture = false },
                        .layout = .{ .sizing = .{ .width = .fixed(size), .height = .fixed(size) } },
                        .decoration = .{ .background = kit.hueColor(step / drifting_shape_count, 0.65, 0.9), .corner_radius = .all(if (index % 2 == 0) size / 2 else 12) },
                    });
                }
            }

            fn declarationCode(self: *const LightLab, ui: *Ui, shell: *const Shell, seconds: f32) void {
                const palette = shell.palette;
                ui.open(.{
                    .id = .of("light_lab.code"),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .{ .rule = .grow_from_min, .amount = 2 }, .height = .grow }, .padding = .all(14), .child_gap = 8 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                    .scroll = .{ .horizontal = true, .vertical = true },
                });
                defer ui.close();
                shell.label(ui, .caption, "THE DECLARATION, AS IT IS NOW");
                const gradient_now = self.gradient(seconds);
                const shadow_now = self.shadow(shell);
                const frost_now = self.frost();
                var buffer: [1024]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                writer.print(
                    \\.decoration = .{{ .corner_radius = .all({d:.0}) }},
                    \\.effects = &.{{
                    \\    .gradient = .{{
                    \\        .from = .rgb(0x{x:0>6}),
                    \\        .to = .rgb(0x{x:0>6}),
                    \\        .angle = {d:.2},
                    \\    }},
                    \\    .shadow = .{{
                    \\        .color = .rgba(0x{x:0>8}),
                    \\        .offset = .{{ {d:.0}, {d:.0} }},
                    \\        .blur = {d:.0}, .spread = {d:.0},
                    \\    }},
                    \\}},
                    \\
                    \\// the pane over it
                    \\.effects = &.{{ .backdrop_blur = .{{
                    \\    .radius = {d:.0},
                    \\    .tint = .rgba(0x{x:0>8}),
                    \\}} }},
                , .{
                    self.corner_radius,       rgbOf(gradient_now.from), rgbOf(gradient_now.to), @mod(gradient_now.angle, 2 * std.math.pi),
                    rgbaOf(shadow_now.color), shadow_now.offset[0],     shadow_now.offset[1],   shadow_now.blur,
                    shadow_now.spread,        frost_now.radius,         rgbaOf(frost_now.tint),
                }) catch {};
                if (kit.draws_material_patterns) {
                    const material_now = self.material(patterns[self.material_pattern_index], seconds);
                    writer.print(
                        \\
                        \\
                        \\// the material swatches
                        \\.decoration = .{{
                        \\    .background = .rgb(0x{x:0>6}),
                        \\    .material = .{{ .pattern = .{t},
                        \\        .first = .rgb(0x{x:0>6}),
                        \\        .second = .rgb(0x{x:0>6}),
                        \\        .phase = {d:.2} }},
                        \\}},
                    , .{ rgbOf(self.materialFallback()), material_now.pattern, rgbOf(material_now.first), rgbOf(material_now.second), @mod(material_now.phase, 1) }) catch {};
                }
                ui.text(writer.buffered(), .{ .font = shell.fonts.mono, .size = 13 * shell.text_scale, .color = palette.muted, .wrap = .newlines });
            }

            fn openLoweringCard(ui: *Ui, shell: *const Shell, title: []const u8, drawn: bool) void {
                shell.openCard(ui, "", .{ .width = .grow_equal, .height = .grow });
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                shell.label(ui, .heading, title);
                shell.spacer(ui);
                shell.chip(ui, if (drawn) "drawn" else "lowered", if (drawn) shell.palette.good else shell.palette.warn);
                ui.close();
            }

            fn swatchLabel(ui: *Ui, shell: *const Shell, content: []const u8) void {
                ui.text(content, .{ .font = shell.fonts.body, .size = 11 * shell.text_scale, .color = shell.palette.muted, .wrap = .words });
            }

            fn gradientLowering(self: *const LightLab, ui: *Ui, shell: *const Shell, seconds: f32) void {
                openLoweringCard(ui, shell, "Gradient", kit.config.commands.contains(.gradient));
                defer ui.close();
                const now = self.gradient(seconds);
                const across: Ui.Gradient = .{ .from = now.from, .to = now.to };
                swatchLabel(ui, shell, "OKLab, as drawn");
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(22) } }, .decoration = .{ .corner_radius = .all(5) }, .effects = &.{ .gradient = across } });
                swatchLabel(ui, shell, "sRGB, by Color.mix");
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(22) } } });
                    defer ui.close();
                    for (0..srgb_steps) |step| {
                        const amount = @as(f32, @floatFromInt(step)) / (srgb_steps - 1);
                        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } }, .decoration = .{ .background = now.from.mix(now.to, amount) } });
                    }
                }
                swatchLabel(ui, shell, "lowered: middle color");
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(22) } }, .decoration = .{ .background = now.meanColor(), .corner_radius = .all(5) } });
            }

            fn shadowLowering(self: *const LightLab, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                openLoweringCard(ui, shell, "Shadow", kit.config.commands.contains(.shadow));
                defer ui.close();
                ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .symmetric(4, 8), .child_gap = 16 } });
                defer ui.close();
                const sides = [_]struct { []const u8, ?Ui.Shadow }{ .{ "with it", self.shadow(shell) }, .{ "lowered: none", null } };
                for (sides) |side| {
                    const name, const cast = side;
                    ui.open(.{
                        .layout = .{ .sizing = .{ .width = .grow_equal, .height = .grow }, .padding = .all(8), .child_alignment = .{ .x = .center, .y = .end } },
                        .decoration = .{ .background = palette.raised, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(@min(self.corner_radius, 16)) },
                        .effects = if (cast) |shadow_now| &.{ .shadow = shadow_now } else null,
                    });
                    swatchLabel(ui, shell, name);
                    ui.close();
                }
            }

            /// The three corner shapes at the lab's radius, in the controls
            /// beside the radius they follow.
            fn cornerShapes(self: *const LightLab, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.labelColored(ui, .caption, palette.spectacle, "CORNERS");
                    shell.spacer(ui);
                    shell.chip(ui, if (kit.draws_every_corner_shape) "drawn" else "lowered", if (kit.draws_every_corner_shape) palette.good else palette.warn);
                }
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                defer ui.close();
                for (std.enums.values(zui.CornerShape)) |shape| {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal }, .child_gap = 4, .child_alignment = .{ .x = .center } } });
                    defer ui.close();
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(64) } },
                        .decoration = .{ .background = palette.accent.mix(palette.surface, 0.35), .corner_radius = .all(self.corner_radius), .corner_shape = shape },
                    });
                    const lowered = !kit.config.corner_shapes.contains(shape);
                    swatchLabel(ui, shell, if (lowered) loweredName(shape) else @tagName(shape));
                }
            }

            fn loweredName(shape: zui.CornerShape) []const u8 {
                return switch (shape) {
                    .round => "round",
                    .continuous => "continuous, drawn round",
                    .chamfer => "chamfer, drawn round",
                };
            }

            fn frostLowering(self: *const LightLab, ui: *Ui, shell: *const Shell, seconds: f32) void {
                openLoweringCard(ui, shell, "Frost", kit.draws_frost);
                defer ui.close();
                const frost_now = self.frost();
                const sample_id: zui.Id = .of("light_lab.frost_sample");
                const sample = ui.rectOf(sample_id) orelse zui.Rect{ .x = 0, .y = 0, .width = 160, .height = 120 };
                ui.open(.{
                    .id = sample_id,
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
                    .decoration = .{ .corner_radius = .all(8) },
                    .clip = .both,
                });
                defer ui.close();
                stripes(ui, seconds);
                const panes = [_]struct { []const u8, bool }{ .{ "frosted", true }, .{ "its tint", false } };
                const pane_count: f32 = if (kit.draws_frost) 2 else 1;
                const inset = 8;
                const pane_size: [2]f32 = .{ @max(0, (sample.width - inset * (pane_count + 1)) / pane_count), @max(0, sample.height - 2 * inset) };
                var place: f32 = 0;
                for (panes) |pane| {
                    const name, const frosted = pane;
                    if (frosted and !kit.draws_frost) continue;
                    ui.open(.{
                        .floating = .{ .offset = .{ inset + place * (pane_size[0] + inset), inset }, .clip = .target, .capture = false },
                        .layout = .{ .sizing = .{ .width = .fixed(pane_size[0]), .height = .fixed(pane_size[1]) }, .padding = .all(8), .child_alignment = .{ .y = .end } },
                        .decoration = .{ .background = if (frosted) null else frost_now.tint, .corner_radius = .all(10) },
                        .effects = if (frosted) &.{ .backdrop_blur = frost_now } else null,
                    });
                    ui.text(name, .{ .font = shell.fonts.body, .size = 11 * shell.text_scale, .color = .rgb(0xffffff), .wrap = .words });
                    ui.close();
                    place += 1;
                }
            }

            fn stripes(ui: *Ui, seconds: f32) void {
                for (0..8) |index| {
                    const step: f32 = @floatFromInt(index);
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .grow, .height = .grow } },
                        .decoration = .{ .background = kit.hueColor(step / 8 + seconds * 0.05, 0.6, if (index % 2 == 0) 0.95 else 0.35) },
                    });
                }
            }

            fn materialLowering(self: *const LightLab, ui: *Ui, shell: *const Shell, seconds: f32) void {
                openLoweringCard(ui, shell, "Material", kit.draws_material_patterns);
                defer ui.close();
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 8 } });
                defer ui.close();
                if (kit.draws_material_patterns) {
                    for (patterns, 0..) |pattern, index| {
                        const chosen = index == self.material_pattern_index;
                        ui.open(.{
                            .layout = .{ .sizing = .{ .width = .grow_equal, .height = .grow }, .padding = .all(8), .child_alignment = .{ .y = .end } },
                            .decoration = .{
                                .background = self.materialFallback(),
                                .material = self.material(pattern, seconds),
                                .border = if (chosen) .{ .color = shell.palette.text, .widths = .all(2) } else null,
                                .corner_radius = .all(8),
                            },
                        });
                        swatchLabel(ui, shell, @tagName(pattern));
                        ui.close();
                    }
                }
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow_equal, .height = .grow }, .padding = .all(8), .child_alignment = .{ .y = .end } },
                    .decoration = .{ .background = self.materialFallback(), .corner_radius = .all(8) },
                });
                ui.text("lowered: its background", .{ .font = shell.fonts.body, .size = 11 * shell.text_scale, .color = .rgb(0xffffff), .wrap = .words });
                ui.close();
            }
        };
    };
}
