const std = @import("std");
const zui = @import("zui");

const wall_columns = 20;

/// Effects the rest of the tour may declare beside the wall, such as the
/// frame inspector's shadow.
const effects_left_for_the_shell = 16;

/// The longest step the wave takes in one frame, so a frame after a long
/// sleep does not jump it.
const longest_step_seconds = 0.1;

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const wall_rows: usize = @min(12, (Ui.limits.max_effects -| effects_left_for_the_shell) / wall_columns);
    const card_count = wall_rows * wall_columns;
    return struct {
        /// A wall of cards, each turned, scaled and moved by its own
        /// `zui.Transform` in a wave, and each hovered and clicked where it
        /// is drawn rather than where layout put it.
        pub const ClickableChaos = struct {
            wave_seconds: f32 = 0,
            speed: f32 = 1,
            swing_degrees: f32 = 28,
            paused: bool = false,
            show_layout_boxes: bool = false,
            hits: u32 = 0,
            flipped: [card_count]bool = @splat(false),

            /// The toggles the top bar's menu offers while this screen is open.
            pub fn declareMenuToggles(self: *ClickableChaos, ui: *Ui, shell: *const Shell) void {
                _ = shell.widgets.checkbox(ui, .of("menu.clickable_chaos.paused"), "Pause the wave", &self.paused, .{});
                _ = shell.widgets.checkbox(ui, .of("menu.clickable_chaos.layout_boxes"), "Outline where layout put them", &self.show_layout_boxes, .{});
            }

            pub fn declare(self: *ClickableChaos, ui: *Ui, shell: *const Shell) void {
                const moving = !self.paused and !shell.reduced_motion and self.speed > 0;
                if (moving) {
                    self.wave_seconds += @min(ui.dt(), longest_step_seconds) * self.speed;
                    ui.requestFrame();
                }
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                const hovered_card = self.takeClicks(ui);
                self.controls(ui, shell, hovered_card);
                self.wall(ui, shell);
            }

            /// Returns the card the pointer was over in the last frame.
            fn takeClicks(self: *ClickableChaos, ui: *Ui) ?usize {
                var hovered_card: ?usize = null;
                for (&self.flipped, 0..) |*flipped, card| {
                    const id = cardId(card);
                    if (ui.clicked(id)) {
                        flipped.* = !flipped.*;
                        self.hits += 1;
                    }
                    if (ui.hovered(id)) hovered_card = card;
                }
                return hovered_card;
            }

            fn controls(self: *ClickableChaos, ui: *Ui, shell: *const Shell, hovered_card: ?usize) void {
                const widgets = shell.widgets;
                const colors = shell.colors;
                shell.openScrollingCard(ui, .of("clickable_chaos.controls"), "", .{ .width = .fixed(300), .height = .grow });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 16 } });
                    defer ui.close();
                    tally(ui, shell, "hits", "{d}", .{self.hits}, colors.get(.on_surface_accent));
                    tally(ui, shell, "flipped", "{d}", .{std.mem.count(bool, &self.flipped, &.{true})}, colors.get(.on_surface_accent));
                    if (hovered_card) |card| tally(ui, shell, "under the pointer", "#{d}", .{card + 1}, colors.get(.on_surface)) else tally(ui, shell, "under the pointer", "none", .{}, colors.get(.on_surface_muted));
                }
                shell.divider(ui);
                if (widgets.button(ui, .of("clickable_chaos.pause"), if (self.paused) "Resume the wave" else "Pause the wave", .{ .width = .grow })) self.paused = !self.paused;
                shell.sliderRow(ui, .of("clickable_chaos.speed"), "speed", &self.speed, 0, 3, 0.05, "{d:.2}");
                shell.sliderRow(ui, .of("clickable_chaos.swing"), "swing", &self.swing_degrees, 0, 90, 1, "{d:.0}");
                _ = widgets.checkbox(ui, .of("clickable_chaos.layout_boxes"), "outline where layout put them", &self.show_layout_boxes, .{});
                if (shell.reduced_motion) shell.label(ui, .caption, "Reduced motion is on, so the wall holds still.");
                if (widgets.button(ui, .of("clickable_chaos.reset"), "Clear the hits", .{})) {
                    self.hits = 0;
                    self.flipped = @splat(false);
                }
                shell.divider(ui);
                shell.print(ui, .caption, "{d} cards, each its own transform: {d} of the frame's {d} effects.", .{ card_count, card_count, Ui.limits.max_effects });
                shell.meter(ui, @as(f32, @floatFromInt(card_count)) / @as(f32, @floatFromInt(@max(1, Ui.limits.max_effects))), colors.get(.accent), 6);
                shell.label(ui, .caption, "Layout never moves: each card is painted turned and scaled, and zui inverts the same transform to find which card the pointer is over, so a corner that swings into a neighbour's box still belongs to its own card.");
            }

            fn wall(self: *const ClickableChaos, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(18), .child_gap = 0 },
                    .decoration = .{ .background = colors.get(.surface_sunken), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8) },
                    .clip = .both,
                });
                defer ui.close();
                for (0..wall_rows) |row| {
                    ui.open(.{ .layout = .{ .sizing = .grow_both } });
                    defer ui.close();
                    for (0..wall_columns) |column| {
                        const card = row * wall_columns + column;
                        const id = cardId(card);
                        const hovered = ui.hovered(id);
                        ui.open(.{
                            .layout = .{ .sizing = .grow_both, .padding = .all(3) },
                            .decoration = if (self.show_layout_boxes) .{ .border = .{ .color = colors.get(.on_surface_muted), .widths = .all(1) } } else null,
                        });
                        defer ui.close();
                        ui.box(.{
                            .id = id,
                            .interactive = true,
                            .cursor = .pointer,
                            .layout = .{ .sizing = .grow_both },
                            .decoration = self.cardDecoration(colors, row, column, hovered),
                            .effects = &.{ .transform = self.cardTransform(row, column, hovered, ui.pressed(id)) },
                        });
                    }
                }
            }

            fn cardDecoration(self: *const ClickableChaos, colors: kit.Colors, row: usize, column: usize, hovered: bool) Ui.Decoration {
                const flipped = self.flipped[row * wall_columns + column];
                const across = @as(f32, @floatFromInt(column)) / wall_columns;
                const down = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(wall_rows));
                const hue = kit.hueColor(0.55 + 0.3 * across + 0.15 * down, 0.6, 0.9);
                const face = if (flipped) hue else hue.mix(colors.get(.surface), 0.78);
                return .{
                    .background = if (hovered) face.mix(colors.get(.on_surface), 0.35) else face,
                    .border = .{ .color = if (hovered) colors.get(.on_surface) else hue.mix(colors.get(.surface), if (flipped) 0.2 else 0.6), .widths = .all(if (hovered) 2 else 1) },
                    .corner_radius = .all(5),
                };
            }

            fn cardTransform(self: *const ClickableChaos, row: usize, column: usize, hovered: bool, pressed: bool) zui.Transform {
                const along: f32 = @floatFromInt(column);
                const down: f32 = @floatFromInt(row);
                const time = self.wave_seconds;
                const wave = @sin(time * 1.6 - along * 0.42 - down * 0.31);
                const breath = @cos(time * 1.1 - (along + down) * 0.27);
                const lift: f32 = if (pressed) 0.9 else if (hovered) 1.25 else 1;
                return .{
                    .rotation = std.math.degreesToRadians(self.swing_degrees * wave),
                    .scale = @splat((0.82 + 0.18 * breath) * lift),
                    .translation = .{ 4 * breath, 6 * wave },
                };
            }
        };

        fn cardId(card: usize) zui.Id {
            return .indexed("clickable_chaos.card", card);
        }

        fn tally(ui: *Ui, shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype, color: zui.Color) void {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 2 } });
            defer ui.close();
            shell.printColored(ui, .title, color, format, arguments);
            shell.label(ui, .tiny, name);
        }
    };
}
