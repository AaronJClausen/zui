//! Instantiates `zui_design` for `zig build check`, which type-checks only
//! what is referenced: a resolve at run time and at comptime, in both
//! color types and with extra roles.

const zui = @import("zui");
const zui_design = @import("zui_design");

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 } });
const ExtendedUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Color = zui.ExtendedColor, .FontId = enum(u8) { regular, strong, monospace } });

const Roles = enum {
    brand,
    on_brand,
    chart_line,

    pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand, .chart_line = .surface };
};

const checked_design: zui.design.Design = .{
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
};

var tokens: zui.design.Tokens(Ui, void) = .{};
var extended_tokens: zui.design.Tokens(ExtendedUi, Roles) = .{};
var environment: zui.Environment = .{};

const comptime_tokens = resolved: {
    var resolved: zui.design.Tokens(Ui, Roles) = .{};
    _ = zui_design.resolve(checked_design, .{ .theme = .dark, .contrast = .high }, &resolved);
    break :resolved resolved;
};

export fn zuiDesignCheck() f32 {
    const preferences: zui_design.Preferences = .from(environment, .{ .accent = .rgb(0xff8800) });
    _ = zui_design.resolve(checked_design, preferences, &tokens);
    _ = zui_design.resolve(checked_design, preferences, &extended_tokens);
    return tokens.space(.m) + extended_tokens.space(.m) + comptime_tokens.measure;
}
