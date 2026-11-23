const std = @import("std");
const zui = @import("zui");
const x11 = @import("x11.zig");

/// What the X11 desktop offers to blur behind a window.
pub const BlurOffers = struct {
    /// The root window holds `_KDE_NET_WM_BLUR_BEHIND_REGION`, as KWin's
    /// blur effect announces it, or `_NET_SUPPORTED` lists it.
    blur_behind_region: bool = false,
    /// A compositing manager owns `_NET_WM_CM_S<screen>`. Without one, what
    /// is behind a 32-bit window is never blended by its alpha.
    compositing_manager: bool = false,

    pub fn blurs(self: BlurOffers) bool {
        return self.blur_behind_region and self.compositing_manager;
    }

    /// As the root window, its `_NET_SUPPORTED` and the compositing
    /// manager's selection say now.
    pub fn read(connection: *x11.Connection, root: x11.Window, atoms: *const x11.Atoms, compositing_manager_selection: x11.Atom) BlurOffers {
        const region = atoms.kde_net_wm_blur_behind_region;
        var supported: [supported_capacity]x11.Atom = undefined;
        const listed = region != x11.atom_none and std.mem.indexOfScalar(x11.Atom, x11.readCardinals(connection, root, atoms.net_supported, &supported), region) != null;
        return .{
            .blur_behind_region = listed or x11.holdsProperty(connection, root, region),
            .compositing_manager = x11.selectionOwned(connection, compositing_manager_selection),
        };
    }

    const supported_capacity = 1024;
};

/// The compositing manager's selection of screen `number`.
pub fn compositingManagerSelection(connection: *x11.Connection, number: c_int) x11.Atom {
    var name_buffer: ["_NET_WM_CM_S".len + 12]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "_NET_WM_CM_S{d}", .{number}) catch unreachable;
    return x11.internAtom(connection, name);
}

/// A window's material: whether it was made with a 32-bit visual, which the
/// compositing manager blends by its alpha over a blur, chosen when it
/// opens, and the blur's region, kept the window's size.
pub const WindowMaterial = struct {
    /// Null for an opaque window on the root's visual, which draws its own
    /// background.
    alpha_visual: ?u32 = null,
    /// The alpha visual's colormap, which a window of a visual other than
    /// its parent's must name.
    colormap: u32 = 0,
    /// In physical pixels, the size the last region covered.
    blur_region_size: ?[2]u32 = null,
    blur_regions_sent: u32 = 0,

    /// `.window` and `.transient` blur alike, since the property has no
    /// strength.
    pub fn choose(asked: zui.SystemMaterial, offers: BlurOffers, screen: *const x11.Screen) WindowMaterial {
        if (asked == .none or !offers.blurs()) return .{};
        return .{ .alpha_visual = x11.alphaVisualOf(screen) };
    }

    pub fn holdsAlpha(self: *const WindowMaterial) bool {
        return self.alpha_visual != null;
    }

    /// The depth, visual, value mask and values `CreateWindow` makes the
    /// window with, `event_mask` among them; a colormap of its own for an
    /// alpha visual, whose window would otherwise be refused with
    /// `BadMatch`.
    pub fn creation(self: *WindowMaterial, connection: *x11.Connection, root: x11.Window, event_mask: u32) Creation {
        const visual = self.alpha_visual orelse return .{
            .depth = x11.copy_from_parent,
            .visual = x11.copy_from_parent,
            .value_mask = x11.window_attribute_event_mask,
            .values = .{ event_mask, 0, 0, 0 },
        };
        self.colormap = x11.xcb_generate_id(connection);
        _ = x11.xcb_create_colormap(connection, x11.colormap_alloc_none, self.colormap, root, visual);
        const transparent_black = 0;
        return .{
            .depth = 32,
            .visual = visual,
            .value_mask = x11.window_attribute_back_pixel | x11.window_attribute_border_pixel | x11.window_attribute_event_mask | x11.window_attribute_colormap,
            .values = .{ transparent_black, transparent_black, event_mask, self.colormap },
        };
    }

    pub const Creation = struct {
        depth: u8,
        visual: u32,
        value_mask: u32,
        /// In the order of the value mask's bits.
        values: [4]u32,
    };

    /// Blurs behind the whole window; an unchanged size sends nothing.
    pub fn cover(self: *WindowMaterial, connection: *x11.Connection, window: x11.Window, atoms: *const x11.Atoms, size: [2]u32) void {
        if (self.alpha_visual == null) return;
        if (std.meta.eql(self.blur_region_size, @as(?[2]u32, size))) return;
        self.blur_region_size = size;
        self.blur_regions_sent += 1;
        const region = [4]u32{ 0, 0, size[0], size[1] };
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, window, atoms.kde_net_wm_blur_behind_region, x11.atom_cardinal, 32, region.len, &region);
    }

    /// After the window is destroyed.
    pub fn deinit(self: *WindowMaterial, connection: *x11.Connection) void {
        if (self.colormap != 0) _ = x11.xcb_free_colormap(connection, self.colormap);
        self.* = .{};
    }
};

test "blur needs both the blur-behind property and a compositing manager" {
    try std.testing.expect((BlurOffers{ .blur_behind_region = true, .compositing_manager = true }).blurs());
    try std.testing.expect(!(BlurOffers{ .blur_behind_region = true }).blurs());
    try std.testing.expect(!(BlurOffers{ .compositing_manager = true }).blurs());
}
