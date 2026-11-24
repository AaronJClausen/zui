const std = @import("std");

const ContrastChoice = enum { system, normal, high };

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        /// The menu the top bar opens, holding every setting the tour
        /// offers: while pinned it stays open beside the screen, the screen
        /// still taking the pointer, so a change shows as it is made.
        pub const PreferencesMenu = struct {
            open: bool = false,
            pinned: bool = false,
            /// Whether it was open in the previous frame, so the frame it
            /// opens in moves focus into it.
            was_open: bool = false,
            /// The slider's own value, kept while the system's text scale
            /// is followed so turning that off starts from where it was.
            text_scale: f32 = 1,

            /// The choices no OS reports, and the ones the tour may
            /// override: density, color vision, contrast and text scale,
            /// each resolved into new tokens on the frame after it changes.
            /// Returns whether one changed.
            pub fn declareChoices(menu: *PreferencesMenu, ui: *Ui, shell: *const Shell) bool {
                const widgets = shell.widgets;
                const chosen = shell.preference_choices;
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
                } else .system;
                widgets.labeledRow(ui, "Contrast");
                if (widgets.dropdownEnum(ui, .of("preferences.contrast"), &contrast, .{ .label = "Contrast" })) {
                    chosen.contrast = switch (contrast) {
                        .system => null,
                        .normal => .normal,
                        .high => .high,
                    };
                    changed = true;
                }
                ui.close();

                var follows_system_text = chosen.text_scale == null;
                if (widgets.checkbox(ui, .of("preferences.system_text"), "Use the system's text size", &follows_system_text, .{})) {
                    chosen.text_scale = if (follows_system_text) null else menu.text_scale;
                    changed = true;
                }
                widgets.labeledRow(ui, "Text size");
                if (widgets.slider(ui, .of("preferences.text_scale"), &menu.text_scale, .{ .min = kit.text_scale_range[0], .max = kit.text_scale_range[1], .step = 0.05, .disabled = follows_system_text, .label = "Text size" })) {
                    chosen.text_scale = menu.text_scale;
                    changed = true;
                }
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(48) }, .child_alignment = .{ .x = .end } } });
                shell.print(ui, .caption, "{d:.0}%", .{shell.preferences.text_scale * 100});
                ui.close();
                ui.close();

                if (widgets.button(ui, .of("preferences.reset"), "Reset", .{ .variant = .secondary, .disabled = std.meta.eql(chosen.*, kit.PreferenceChoices{}) })) {
                    chosen.* = .{};
                    changed = true;
                }
                return changed;
            }
        };
    };
}
