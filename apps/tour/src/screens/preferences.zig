const std = @import("std");

const ContrastChoice = enum { follow_the_system, normal, high };

const shown_emphases = [_]@import("../shared.zig").Emphasis{ .accent, .success, .warning, .danger };

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const ControlSize = kit.zui.design.ControlSize;
    return struct {
        /// The choices no OS reports, and the ones the tour may override:
        /// density, color vision, contrast and text scale. Each is resolved
        /// into new tokens once, on the frame after it changes, and every
        /// screen and widget follows.
        pub const Preferences = struct {
            /// The slider's own value, kept while the system's text scale
            /// is followed so turning that off starts from where it was.
            text_scale: f32 = 1,

            pub fn declare(self: *Preferences, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "PREFERENCES", "Your preferences", "zui_design resolves the tokens again only when one of these changes; the whole tour follows.");
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                if (self.choices(ui, shell)) ui.requestFrame();
                resolved(ui, shell);
            }

            fn choices(self: *Preferences, ui: *Ui, shell: *const Shell) bool {
                const widgets = shell.widgets;
                const chosen = shell.preference_choices;
                shell.openCard(ui, "Your choices", .{ .width = .grow_equal, .height = .grow });
                defer ui.close();
                var changed = false;

                widgets.labeledRow(ui, "Density");
                changed = widgets.dropdownEnum(ui, .of("preferences.density"), &chosen.density, .{ .label = "Density" }) or changed;
                ui.close();

                widgets.labeledRow(ui, "Color vision");
                changed = widgets.dropdownEnum(ui, .of("preferences.color_vision"), &chosen.color_vision, .{ .label = "Color vision" }) or changed;
                ui.close();

                var contrast: ContrastChoice = if (chosen.contrast) |contrast| switch (contrast) {
                    .normal => .normal,
                    .high => .high,
                } else .follow_the_system;
                widgets.labeledRow(ui, "Contrast");
                if (widgets.dropdownEnum(ui, .of("preferences.contrast"), &contrast, .{ .label = "Contrast" })) {
                    chosen.contrast = switch (contrast) {
                        .follow_the_system => null,
                        .normal => .normal,
                        .high => .high,
                    };
                    changed = true;
                }
                ui.close();

                var follows_system_text = chosen.text_scale == null;
                if (widgets.checkbox(ui, .of("preferences.system_text"), "Use the system's text size", &follows_system_text, .{})) {
                    chosen.text_scale = if (follows_system_text) null else self.text_scale;
                    changed = true;
                }
                widgets.labeledRow(ui, "Text size");
                if (widgets.slider(ui, .of("preferences.text_scale"), &self.text_scale, .{ .min = kit.text_scale_range[0], .max = kit.text_scale_range[1], .step = 0.05, .disabled = follows_system_text, .label = "Text size" })) {
                    chosen.text_scale = self.text_scale;
                    changed = true;
                }
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(48) }, .child_alignment = .{ .x = .end } } });
                shell.print(ui, .caption, "{d:.0}%", .{shell.preferences.text_scale * 100});
                ui.close();
                ui.close();

                shell.spacer(ui);
                if (widgets.button(ui, .of("preferences.reset"), "Reset", .{ .variant = .secondary, .disabled = std.meta.eql(chosen.*, kit.PreferenceChoices{}) })) {
                    chosen.* = .{};
                    changed = true;
                }
                return changed;
            }
        };

        fn resolved(ui: *Ui, shell: *const Shell) void {
            const tokens = shell.tokens;
            const preferences = shell.preferences;
            shell.openCard(ui, "What the tokens resolved to", .{ .width = .grow_equal, .height = .grow });
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
            shell.divider(ui);
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
