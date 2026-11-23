const std = @import("std");
const zui = @import("zui");

const lanes_shown = [_]@import("../shared.zig").Lane{ .flagship, .field_case, .spectacle };

const FrameStep = struct { name: []const u8, detail: []const u8 };

const frame_steps = [_]FrameStep{
    .{ .name = "Declare", .detail = "Your function describes the whole UI, every frame." },
    .{ .name = "Lay out", .detail = "zui sizes, wraps and measures, caching every text." },
    .{ .name = "Draw", .detail = "A list of commands any renderer can draw." },
    .{ .name = "Sleep", .detail = "No frame until input, a timer or a source wakes it." },
};

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const Lane = kit.Lane;
    const Screen = kit.Screen;
    return struct {
        /// The landing page: what zui is, and every screen this renderer is
        /// offered, by lane. It declares nothing that moves, so the tour
        /// sleeps here between the strip's heartbeats.
        pub const Overview = struct {
            pub fn declare(_: *Overview, ui: *Ui, shell: *const Shell) void {
                introduction(ui, shell);
                frameSteps(ui, shell);
                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    for (lanes_shown) |lane| laneCard(ui, shell, lane);
                }
                facts(ui, shell);
            }
        };

        fn introduction(ui: *Ui, shell: *const Shell) void {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
            defer ui.close();
            shell.label(ui, .heading, "An immediate-mode UI engine for Zig.");
            shell.labelColored(ui, .body, shell.colors.get(.on_surface_muted), "You declare the whole UI every frame; zui lays it out, measures it and draws it, and sleeps when nothing changes.");
        }

        fn frameSteps(ui: *Ui, shell: *const Shell) void {
            const colors = shell.colors;
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
            defer ui.close();
            for (frame_steps, 1..) |step, number| {
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow_equal }, .padding = .symmetric(12, 10), .child_gap = 10 },
                    .decoration = .{ .background = colors.get(.surface_raised), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                shell.printColored(ui, .heading, colors.get(.on_surface_accent), "{d}", .{number});
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                defer ui.close();
                shell.label(ui, .body, step.name);
                shell.label(ui, .caption, step.detail);
            }
        }

        fn laneDescription(lane: Lane) []const u8 {
            return switch (lane) {
                .start => "Where the tour begins.",
                .flagship => "A product built on zui, then the same product with its workings pointed out.",
                .field_case => "Real problems, each solved plainly.",
                .spectacle => "Pages built to show what an immediate-mode engine can do.",
            };
        }

        fn screensIn(lane: Lane) usize {
            var count: usize = 0;
            for (kit.offered_screens) |screen| {
                if (kit.info(screen).lane == lane) count += 1;
            }
            return count;
        }

        fn laneCard(ui: *Ui, shell: *const Shell, lane: Lane) void {
            const colors = shell.colors;
            ui.open(.{
                .id = .indexed("overview.lane", @intFromEnum(lane)),
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal, .height = .grow }, .padding = .all(16), .child_gap = 6 },
                .decoration = .{ .background = colors.get(.surface), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8) },
                .scroll = .{},
            });
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(3), .height = .fixed(18) } }, .decoration = .{ .background = lane.emphasis().fill(colors), .corner_radius = .all(1.5) } });
                shell.label(ui, .heading, lane.name());
                shell.spacer(ui);
                const count = screensIn(lane);
                shell.print(ui, .caption, "{d} {s}", .{ count, if (count == 1) "screen" else "screens" });
            }
            shell.label(ui, .caption, laneDescription(lane));
            ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(4) } } });
            for (kit.offered_screens) |screen| {
                if (kit.info(screen).lane == lane) screenRow(ui, shell, screen);
            }
        }

        fn screenRow(ui: *Ui, shell: *const Shell, screen: Screen) void {
            const colors = shell.colors;
            const info = kit.info(screen);
            const id: zui.Id = .indexed("overview.screen", @intFromEnum(screen));
            if (ui.clicked(id)) shell.requestScreen(screen);
            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .link, .label = info.title },
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(10, 8), .child_gap = 10, .child_alignment = .{ .y = .center } },
                .decoration = .{
                    .background = if (state == .hovered or state == .pressed) colors.get(.secondary_container) else colors.get(.surface_raised),
                    .border = .{ .color = if (ui.focused(id)) colors.get(.focus) else colors.get(.outline_muted), .widths = .all(1) },
                    .corner_radius = .all(6),
                },
            });
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                defer ui.close();
                ui.text(info.title, shell.style(.body, colors.get(.on_surface)));
                shell.label(ui, .caption, info.tagline);
            }
            if (kit.shortcutDigit(screen)) |digit| shell.printColored(ui, .tiny, colors.get(.on_surface_muted), "Ctrl+{d}", .{digit});
            shell.labelColored(ui, .body, if (state == .hovered) colors.get(.on_surface_accent) else colors.get(.on_surface_muted), ">");
        }

        fn facts(ui: *Ui, shell: *const Shell) void {
            const colors = shell.colors;
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 20, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            fact(ui, shell, "drawn by", "{s}", .{kit.renderer_name});
            fact(ui, shell, "frames declared", "{d}", .{shell.perf.zui_frames});
            fact(ui, shell, "the last one because", "{s}", .{shell.perf.latest().reason.describe()});
            shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "Nothing here moves, so the tour sleeps until you act.");
        }

        fn fact(ui: *Ui, shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype) void {
            ui.open(.{ .layout = .{ .child_gap = 6, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            shell.label(ui, .tiny, name);
            shell.print(ui, .caption, format, arguments);
        }
    };
}
