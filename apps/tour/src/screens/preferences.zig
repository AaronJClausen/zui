const std = @import("std");

const shown_emphases = [_]@import("../shared.zig").Emphasis{ .accent, .success, .warning, .danger };

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const ControlSize = kit.zui.design.ControlSize;
    return struct {
        /// What `zui_design` resolved the tokens to from the preferences
        /// the top bar's menu chooses, which every screen and widget
        /// follows.
        pub const Preferences = struct {
            pub fn declare(_: *Preferences, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "TOKENS", "What your preferences resolved to", "Choose density, color vision, contrast and text size in Preferences on the top bar; zui_design resolves the tokens again only when one changes, and the whole tour follows.");
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                preferencesAndHeights(ui, shell);
                statusAndWidgets(ui, shell);
            }
        };

        fn preferencesAndHeights(ui: *Ui, shell: *const Shell) void {
            const tokens = shell.tokens;
            const preferences = shell.preferences;
            shell.openCard(ui, "Your preferences", .{ .width = .grow_equal, .height = .grow });
            defer ui.close();
            shell.print(ui, .caption, "theme .{t}, contrast .{t}, density .{t}", .{ preferences.theme, preferences.contrast, preferences.density });
            shell.print(ui, .caption, "color vision .{t}, text {d:.0}%", .{ preferences.color_vision, preferences.text_scale * 100 });
            shell.divider(ui);
            shell.label(ui, .caption, "CONTROL HEIGHTS");
            {
                ui.open(.{ .layout = .{ .child_gap = 16 } });
                defer ui.close();
                inline for (comptime std.enums.values(ControlSize)) |size| {
                    shell.print(ui, .body, "{t} {d:.0}", .{ size, tokens.control_heights.get(size) });
                }
            }
            shell.print(ui, .caption, "the least target {d:.0}, a gap of {d:.0}", .{ tokens.target_floors.get(.pointer), tokens.space(.m) });
        }

        fn statusAndWidgets(ui: *Ui, shell: *const Shell) void {
            shell.openCard(ui, "Status and widgets", .{ .width = .grow_equal, .height = .grow });
            defer ui.close();
            shell.label(ui, .caption, "STATUS, ADAPTED TO YOUR COLOR VISION");
            {
                ui.open(.{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                for (shown_emphases) |emphasis| shell.chip(ui, @tagName(emphasis), emphasis);
            }
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 4 } });
                defer ui.close();
                for (shown_emphases) |emphasis| shell.meter(ui, 1, emphasis.fill(shell.colors), 8);
            }
            shell.divider(ui);
            shell.label(ui, .caption, "THE WIDGETS, FROM THE SAME TOKENS");
            {
                ui.open(.{ .layout = .{ .child_gap = 8, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                _ = shell.widgets.button(ui, .of("preferences.primary"), "Primary", .{});
                _ = shell.widgets.button(ui, .of("preferences.secondary"), "Secondary", .{ .variant = .secondary });
            }
        }
    };
}
