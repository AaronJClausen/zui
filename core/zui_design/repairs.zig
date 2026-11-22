const zui = @import("zui");
const contrast = @import("contrast.zig");
const palette = @import("palette.zig");

const ColorRole = zui.design.ColorRole;

/// One pair a resolve moved to meet its target.
pub const Repair = struct {
    foreground: ColorRole,
    background: ColorRole,
    scheme: palette.Scheme,
    target: contrast.Target,
    /// The pair's contrast as the design gave it.
    before: contrast.Contrast,
    /// Null for a side left as it was.
    foreground_moved: ?LightnessMove = null,
    background_moved: ?LightnessMove = null,
};

/// The OKLCH lightness a color had and the one a repair gave it.
pub const LightnessMove = struct {
    from: f32,
    to: f32,
};

/// What a resolve changed from its design to meet a target: the first
/// `capacity` repairs, and a count of those past it.
///
/// ```zig
/// const repairs = zui_design.resolve(app.design, preferences, &app.tokens);
/// for (repairs.slice()) |repair| log.info("{t} on {t} moved in {t}", .{ repair.foreground, repair.background, repair.scheme });
/// ```
pub const Repairs = struct {
    pub const capacity = 32;

    kept: [capacity]Repair = undefined,
    kept_count: u32 = 0,
    /// Repairs made but not kept, past `capacity`.
    dropped: u32 = 0,

    pub fn record(self: *Repairs, repair: Repair) void {
        if (self.kept_count == capacity) {
            self.dropped += 1;
            return;
        }
        self.kept[self.kept_count] = repair;
        self.kept_count += 1;
    }

    pub fn slice(self: *const Repairs) []const Repair {
        return self.kept[0..self.kept_count];
    }

    /// True when the design met every target as it was given.
    pub fn isEmpty(self: *const Repairs) bool {
        return self.kept_count == 0 and self.dropped == 0;
    }
};
