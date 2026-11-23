//! Tweens and springs over `ui.state`, which ask for frames only while they
//! move and land at once when the user asks for reduced motion. They live in
//! the core as `zui.motion`, so the widgets reach them too; this module
//! re-exports them.
//!
//! ```zig
//! const opacity = zui_motion.tween(ui, .of("toast"), f32, if (app.importing) 1 else 0, .{ .duration = 0.25 });
//! const background = zui_motion.tween(ui, .of("save"), zui.Color, if (ui.hovered(.of("save"))) hover_color else rest_color, .{});
//! const drawer_x = zui_motion.spring(ui, .of("drawer"), f32, if (app.drawer_open) 0 else -280, .{});
//! ```

const zui = @import("zui");

/// How a tween's progress, from 0 to 1, becomes the share of the way it has
/// moved.
pub const Easing = zui.motion.Easing;
/// A tween's duration, easing and delay.
pub const TweenOptions = zui.motion.TweenOptions;
/// A spring's angular frequency and rest distance.
pub const SpringOptions = zui.motion.SpringOptions;
/// Eases a value toward its target over a duration.
pub const tween = zui.motion.tween;
/// Follows a target with a critically damped spring.
pub const spring = zui.motion.spring;

test {
    _ = @import("tests.zig");
}
