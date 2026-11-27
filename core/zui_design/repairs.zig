const zui = @import("zui");
const contrast = @import("contrast.zig");
const palette = @import("palette.zig");
const color_vision = @import("color_vision.zig");

const ColorRole = zui.design.ColorRole;
const Category = zui.design.Category;

/// One pair a resolve moved to meet its target, or could not.
pub const Repair = struct {
    kind: Kind = .contrast,
    /// For a pair of the categorical palette, its category; `foreground`
    /// and `background` are then the accent's roles it takes its tones
    /// from.
    category: ?Category = null,
    /// For a contrast repair, the role drawn on `background`; for the
    /// others, the first of two status fills.
    foreground: ColorRole,
    /// For a contrast repair, the role `foreground` is drawn on; for the
    /// others, the second of two status fills.
    background: ColorRole,
    scheme: palette.Scheme,
    /// The contrast a contrast repair's pair needs.
    target: contrast.Target = .{ .lightness_contrast = 0, .ratio = 1 },
    /// A contrast repair's pair as the design gave it.
    before: contrast.Contrast = .{ .lightness_contrast = 0, .ratio = 1 },
    /// The simulation under which a color-vision repair's pair was nearest
    /// in lightness, as the design gave it.
    nearest: ?color_vision.Nearest = null,
    /// Null for a side left as it was.
    foreground_moved: ?LightnessMove = null,
    background_moved: ?LightnessMove = null,

    /// What a repair measured.
    pub const Kind = enum {
        /// A pair moved apart until it met its contrast target.
        contrast,
        /// Two status fills moved apart in lightness, so they are told
        /// apart under every simulated color vision.
        color_vision,
        /// Two status fills no move in lightness could tell apart while
        /// keeping their contrast: whatever shows them needs a cue that is
        /// not color.
        needs_non_color_cue,
    };
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
/// for (repairs.slice()) |repair| log.info("{t}: {t} and {t} in {t}", .{ repair.kind, repair.foreground, repair.background, repair.scheme });
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
