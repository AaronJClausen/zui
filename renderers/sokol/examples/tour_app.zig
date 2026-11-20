//! The tour's application, for a host's loop to run, as `zui_host`'s tour
//! does through `zui_app`: `b.dependency("zui_sokol", .{ .gl = true })
//! .module("zui_sokol_tour")`.

pub const App = @import("app.zig").App;
pub const kit = @import("kit.zig");
pub const FrameReason = @import("perf.zig").FrameReason;
