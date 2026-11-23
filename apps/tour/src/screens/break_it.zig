const std = @import("std");
const zui = @import("zui");

/// A load that pushes one of the context's limits: how much of it this page
/// declares, in the unit its slider moves.
const Load = enum {
    elements,
    depth,
    text_bytes,
    render_commands,
    effects,
    state_slots,

    fn limit(load: Load) zui.Limit {
        return switch (load) {
            .elements => .max_elements,
            .depth => .max_depth,
            .text_bytes => .max_text_bytes,
            .render_commands => .max_render_commands,
            .effects => .max_effects,
            .state_slots => .state_slots,
        };
    }

    fn name(load: Load) []const u8 {
        return switch (load) {
            .elements => "Elements",
            .depth => "Nesting depth",
            .text_bytes => "Text bytes",
            .render_commands => "Render commands",
            .effects => "Effects",
            .state_slots => "State slots",
        };
    }

    fn unit(load: Load) []const u8 {
        return switch (load) {
            .elements => "boxes",
            .depth => "levels",
            .text_bytes => "KB of text",
            .render_commands => "thousand lines",
            .effects => "shadows",
            .state_slots => "states",
        };
    }

    /// What the page declares for one step of the slider.
    fn perStep(load: Load) u32 {
        return switch (load) {
            .text_bytes => text_block.len,
            .render_commands => lines_per_block,
            else => 1,
        };
    }
};

const loads = std.enums.values(Load);

const lines_per_block = 1000;
/// One kilobyte of text, declared as many times as the text slider asks.
const text_block: *const [1024]u8 = ("Keep what fits, report it, never corrupt. " ** 25)[0..1024];
/// A thousand one-character lines: one element, a thousand render commands.
/// A full block, since its sides land on whole pixels: a glyph with
/// antialiased sides stacked a thousand deep drifts on a rasterizer that
/// rounds each blend twice, as llvmpipe does.
const line_block = "█\n" ** lines_per_block;
const boxes_per_row = 128;
const effects_per_row = 40;
const line_blocks_per_row = 12;

const shadow_effects: zui.Effects = .{ .shadow = .{ .color = .rgba(0x00000080), .offset = .{ 0, 2 }, .blur = 4 } };

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        const ids = struct {
            const reset: zui.Id = .of("break_it.reset");
            const diagnostics: zui.Id = .of("break_it.diagnostics");
            const payload: zui.Id = .of("break_it.payload");
        };

        fn limitValue(limit: zui.Limit) u32 {
            return switch (limit) {
                inline else => |tag| @intCast(@field(Ui.limits, @tagName(tag))),
            };
        }

        /// Steps of `load` that take it to half again its limit, past it
        /// whatever the rest of the frame needs.
        fn maximumSteps(load: Load) u32 {
            if (load == .render_commands) return render_command_blocks_maximum;
            return limitValue(load.limit()) * 3 / 2 / load.perStep() + 1;
        }

        /// Past `max_render_commands`, emission drops the end of a clip
        /// whose beginning it kept, and the frame's safety sweep panics on
        /// the unbalanced clip, so this load stays under the limit, with room
        /// for everything else the page and the tour draw.
        const render_command_blocks_maximum = limitValue(.max_render_commands) * 2 / 3 / lines_per_block;

        const Amounts = std.EnumArray(Load, u32);

        /// Within every limit, with room for the rest of the tour's frame.
        const default_amounts: Amounts = .init(.{
            .elements = 1000,
            .depth = 24,
            .text_bytes = 16,
            .render_commands = 2,
            .effects = 32,
            .state_slots = 200,
        });

        /// Loads that push each of the context's limits past it, beside what the frame reported.
        pub const BreakIt = struct {
            amounts: Amounts = default_amounts,

            /// Declares the page into the tour's stage.
            pub fn declare(self: *BreakIt, ui: *Ui, shell: *const Shell) void {
                self.controls(ui, shell);
                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    diagnosticsCard(ui, shell);
                    self.payload(ui, shell);
                }
            }

            fn controls(self: *BreakIt, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                const diagnostics = shell.perf.diagnostics;
                shell.openCard(ui, "", .{ .width = .grow });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    {
                        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                        defer ui.close();
                        if (diagnostics.exceeded.count() == 0) {
                            shell.labelColored(ui, .title, colors.get(.on_success_container), "Within every limit");
                            shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "Drag a slider past its line. These controls are declared first, so they are always kept.");
                        } else {
                            shell.printColored(ui, .title, colors.get(.on_surface_accent), "{d} {s} exceeded, nothing corrupted", .{ diagnostics.exceeded.count(), if (diagnostics.exceeded.count() == 1) "limit" else "limits" });
                            shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "What fit was kept and drawn; the rest was dropped and reported. Whatever the page declares last goes first, the tour's strip below among it.");
                        }
                    }
                    if (shell.widgets.button(ui, ids.reset, "Reset", .{})) {
                        self.amounts = default_amounts;
                        ui.requestFrame();
                    }
                }
                for (loads) |load| self.loadRow(ui, shell, load);
            }

            fn loadRow(self: *BreakIt, ui: *Ui, shell: *const Shell, load: Load) void {
                const colors = shell.colors;
                const limit = load.limit();
                const limit_value = limitValue(limit);
                const exceeded = shell.perf.diagnostics.exceeded.contains(limit);
                const counted_only_when_full = load == .state_slots and !exceeded;
                const needed = if (counted_only_when_full) self.amounts.get(load) else shell.perf.diagnostics.needed.get(limit);
                const fraction = @as(f32, @floatFromInt(needed)) / @as(f32, @floatFromInt(limit_value));

                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(140) } } });
                shell.label(ui, .body, load.name());
                ui.close();
                const amount = self.amounts.getPtr(load);
                if (shell.widgets.slider(ui, .indexed("break_it.load", @intFromEnum(load)), amount, .{ .min = 0, .max = @floatFromInt(maximumSteps(load)), .label = load.name() })) ui.requestFrame();
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(150) } } });
                shell.print(ui, .caption, "{d} {s}", .{ amount.*, load.unit() });
                ui.close();
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(160) } } });
                shell.meter(ui, fraction, if (exceeded or needed > limit_value) colors.get(.danger) else if (fraction > 0.8) colors.get(.warning) else colors.get(.success), 8);
                ui.close();
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(170) }, .child_alignment = .{ .x = .end } } });
                shell.printColored(ui, .caption, if (exceeded or needed > limit_value) colors.get(.on_danger_container) else colors.get(.on_surface), "{s}{d} / {d}", .{ if (counted_only_when_full) "at least " else "", needed, limit_value });
                ui.close();
            }

            fn diagnosticsCard(ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                const diagnostics = shell.perf.diagnostics;
                shell.openScrollingCard(ui, ids.diagnostics, "What the frame reported", .{ .width = .fixed(380), .height = .grow });
                defer ui.close();
                shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "frame.diagnostics, from the last frame:");
                if (diagnostics.ok()) {
                    shell.labelColored(ui, .body, colors.get(.on_success_container), "ok(): nothing dropped or refused");
                } else {
                    shell.labelColored(ui, .body, colors.get(.on_danger_container), "ok() is false; check() returns error.CapacityExceeded");
                    var exceeded = diagnostics.exceeded.iterator();
                    while (exceeded.next()) |limit| {
                        const needed = diagnostics.needed.get(limit);
                        const limit_value = limitValue(limit);
                        shell.printColored(ui, .caption, colors.get(.on_surface), ".{t}: needed {d}, kept {d}, dropped {d}", .{ limit, needed, @min(needed, limit_value), needed -| limit_value });
                    }
                    if (diagnostics.first_dropped_id != 0) shell.printColored(ui, .caption, colors.get(.on_surface_muted), "first element dropped: id {x:0>16}", .{diagnostics.first_dropped_id});
                }
                if (diagnostics.lowered.count() != 0) shell.printColored(ui, .caption, colors.get(.on_surface_muted), "{d} kinds of command lowered for this renderer (not a failure)", .{diagnostics.lowered.count()});
                shell.divider(ui);
                shell.labelColored(ui, .caption, colors.get(.on_surface_accent), "EVERY LIMIT FAILS THE SAME WAY");
                rule(ui, shell, "1", "The part that fits is kept. Overflowing elements are dropped, their subtrees skipped with depth still tracked, so every close still pairs up.");
                rule(ui, shell, "2", "The frame reports which limit, the peak it needed, and the first id dropped.");
                rule(ui, shell, "3", "Nothing is corrupted: no wild write, no crash, no lost state. Reset, and the next frame is whole again.");
            }

            fn rule(ui: *Ui, shell: *const Shell, number: []const u8, content: []const u8) void {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                defer ui.close();
                shell.labelColored(ui, .heading, shell.colors.get(.on_surface_accent), number);
                shell.label(ui, .caption, content);
            }

            /// Declared last, so it is what a limit cuts off first.
            fn payload(self: *const BreakIt, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                shell.openCard(ui, "The load", .{ .width = .grow, .height = .grow });
                defer ui.close();
                ui.open(.{
                    .id = ids.payload,
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(8), .child_gap = 8 },
                    .decoration = .{ .background = colors.get(.surface_sunken), .corner_radius = .all(6) },
                    .scroll = .both,
                });
                defer ui.close();

                for (0..self.amounts.get(.state_slots)) |index| _ = ui.state(.indexed("break_it.slot", index), u32);
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                    defer ui.close();
                    nest(ui, colors, self.amounts.get(.depth));
                    shadows(ui, colors, self.amounts.get(.effects));
                }
                lineBlocks(ui, shell, self.amounts.get(.render_commands));
                boxes(ui, colors, self.amounts.get(.elements));
                const text_style = shell.style(.tiny, colors.get(.on_surface_muted));
                for (0..self.amounts.get(.text_bytes)) |_| ui.text(text_block, .{ .size = text_style.size, .font = text_style.font, .color = text_style.color, .wrap = .none });
            }

            /// Each block's thousand lines are drawn almost on top of each
            /// other, so all of them are on screen and none is culled.
            fn lineBlocks(ui: *Ui, shell: *const Shell, count: u32) void {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 4 } });
                defer ui.close();
                var placed: u32 = 0;
                while (placed < count) {
                    const in_row = @min(line_blocks_per_row, count - placed);
                    ui.open(.{ .layout = .{ .child_gap = 6 } });
                    for (0..in_row) |_| ui.text(line_block, .{ .size = 10, .font = shell.fonts.mono, .color = shell.colors.get(.on_surface_accent), .wrap = .newlines, .line_height = 0.02 });
                    ui.close();
                    placed += in_row;
                }
            }

            fn nest(ui: *Ui, colors: kit.Colors, levels: u32) void {
                for (0..levels) |level| ui.open(.{
                    .layout = .{ .padding = .all(2) },
                    .decoration = .{ .border = .{ .color = if (level % 2 == 0) colors.get(.accent) else colors.get(.outline_muted), .widths = .all(1) } },
                });
                if (levels != 0) ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = colors.get(.accent) } });
                for (0..levels) |_| ui.close();
            }

            fn shadows(ui: *Ui, colors: kit.Colors, count: u32) void {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4, .padding = .all(4) } });
                defer ui.close();
                var placed: u32 = 0;
                while (placed < count) {
                    const in_row = @min(effects_per_row, count - placed);
                    ui.open(.{ .layout = .{ .child_gap = 4 } });
                    for (0..in_row) |_| ui.box(.{
                        .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } },
                        .decoration = .{ .background = colors.get(.surface_raised), .corner_radius = .all(2) },
                        .effects = &shadow_effects,
                    });
                    ui.close();
                    placed += in_row;
                }
            }

            fn boxes(ui: *Ui, colors: kit.Colors, count: u32) void {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 1 } });
                defer ui.close();
                var placed: u32 = 0;
                while (placed < count) {
                    const in_row = @min(boxes_per_row, count - placed);
                    ui.open(.{ .layout = .{ .child_gap = 1 }, .decoration = .{ .background = colors.get(.outline_muted) } });
                    for (0..in_row) |column| ui.box(.{
                        .layout = .{ .sizing = .{ .width = .fixed(3), .height = .fixed(3) } },
                        .decoration = if ((placed + column) % 8 == 0) .{ .background = colors.get(.accent) } else null,
                    });
                    ui.close();
                    placed += in_row;
                }
            }
        };
    };
}
