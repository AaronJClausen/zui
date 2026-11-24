const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design");
const zui_fonts = @import("zui_fonts");
const zui_widgets = @import("zui_widgets");

/// The app: its state, kept across frames, and the UI it declares each
/// frame. It is generic over the context, so the window and the tests
/// declare the same UI.
pub fn Counter(comptime Ui: type) type {
    return struct {
        const Self = @This();
        const Tokens = zui.design.Tokens(Ui, void);
        const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));

        pub const increment_id: zui.Id = .of("increment");
        pub const reset_id: zui.Id = .of("reset");

        count: u32 = 0,
        design: zui.design.Design = zui_design.default,
        tokens: Tokens = .{},
        tokens_resolved_for: ?zui_design.Preferences = null,

        /// Adds the bundled fonts the design sets its text in. `text` is
        /// the font system, such as a `*zui_truetype.Text`.
        pub fn addFonts(counter: *Self, text: anytype) !void {
            counter.design.type.fonts = .{
                .regular = try text.addFont(zui_fonts.atkinson_hyperlegible_regular),
                .strong = try text.addFont(zui_fonts.atkinson_hyperlegible_bold),
            };
        }

        pub fn declare(counter: *Self, ui: *Ui) void {
            counter.resolveTokens(ui);
            const tokens = &counter.tokens;
            const widgets: Widgets = .{ .skin = .{ .tokens = tokens } };
            const colors = tokens.colors.get(.idle);

            ui.open(.{
                .id = .of("window"),
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(tokens.space(.xl)), .child_gap = tokens.space(.m) },
                .decoration = .{ .background = colors.get(.background) },
            });
            defer ui.close();

            var title = tokens.text_styles.get(.headline);
            title.color = colors.get(.on_surface);
            ui.text("Hello, zui", title);

            var count_bytes: [32]u8 = undefined;
            widgets.label(ui, std.fmt.bufPrint(&count_bytes, "{d} {s}", .{ counter.count, if (counter.count == 1) "click" else "clicks" }) catch unreachable);

            ui.open(.{ .layout = .{ .direction = .left_to_right, .child_gap = tokens.space(.s) } });
            defer ui.close();
            if (widgets.button(ui, increment_id, "Click me", .{})) counter.count += 1;
            if (widgets.button(ui, reset_id, "Reset", .{ .variant = .secondary, .disabled = counter.count == 0 })) counter.count = 0;
        }

        /// The design's colors and sizes for the system's light or dark
        /// theme, contrast and text size, resolved again only when one
        /// changes.
        fn resolveTokens(counter: *Self, ui: *const Ui) void {
            const preferences: zui_design.Preferences = .from(ui.environment(), .{});
            if (counter.tokens_resolved_for) |resolved_for| {
                if (std.meta.eql(resolved_for, preferences)) return;
            }
            _ = zui_design.resolve(counter.design, preferences, &counter.tokens);
            counter.tokens_resolved_for = preferences;
        }
    };
}
