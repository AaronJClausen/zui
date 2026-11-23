//! The design languages of the desktops zui runs on, each a
//! `zui.design.Design` an application resolves in place of
//! `zui_design.default`: Windows' Fluent, GNOME's libadwaita and KDE's
//! Breeze. Each changes the default's seeds, type scale, shapes, density
//! and motion and keeps its tones, so every one meets the same contrast
//! targets in light, dark and high contrast, and follows the system's
//! accent through `zui_design.Preferences`. The fonts stay the
//! application's: none of the languages' typefaces is bundled.
//!
//! ```zig
//! const app_design = design: {
//!     var language = switch (builtin.os.tag) {
//!         .windows => zui_themes.fluent,
//!         else => zui_themes.libadwaita,
//!     };
//!     language.type.fonts = .{
//!         .regular = @intFromEnum(FontId.atkinson_regular),
//!         .strong = @intFromEnum(FontId.atkinson_bold),
//!         .monospace = @intFromEnum(FontId.liberation_mono),
//!     };
//!     break :design language;
//! };
//!
//! // Each frame, before declaring the UI:
//! const preferences: zui_design.Preferences = .from(ui.environment(), app.choices);
//! if (!std.meta.eql(preferences, app.preferences)) {
//!     app.preferences = preferences;
//!     _ = zui_design.resolve(app_design, preferences, &app.tokens);
//! }
//! ```

/// Windows 11's Fluent 2, as WinUI 3 draws it.
pub const fluent = @import("fluent.zig").fluent;
/// GNOME's design language, as libadwaita draws it.
pub const libadwaita = @import("libadwaita.zig").libadwaita;
/// KDE Plasma's Breeze.
pub const breeze = @import("breeze.zig").breeze;

test {
    _ = fluent;
    _ = libadwaita;
    _ = breeze;
}
