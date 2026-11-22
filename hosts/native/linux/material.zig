const std = @import("std");
const zui = @import("zui");
const wayland = @import("wayland.zig");
const Proxy = wayland.Proxy;

/// A protocol a compositor blurs what is behind a surface through.
pub const BlurProtocol = enum {
    /// `ext_background_effect_v1`.
    background_effect,
    /// KWin's `org_kde_kwin_blur`.
    kde_blur,
};

/// What the compositor offers to blur behind a window.
pub const BlurOffers = struct {
    /// `ext_background_effect_manager_v1` is bound, and its capabilities
    /// hold blur.
    background_effect_blurs: bool = false,
    /// `org_kde_kwin_blur_manager` is bound.
    kde_blur: bool = false,

    /// `ext_background_effect_v1` where both are offered, since any
    /// compositor may implement it and KWin's is KWin's own.
    pub fn preferred(self: BlurOffers) ?BlurProtocol {
        if (self.background_effect_blurs) return .background_effect;
        if (self.kde_blur) return .kde_blur;
        return null;
    }

    pub fn offers(self: BlurOffers, protocol: BlurProtocol) bool {
        return switch (protocol) {
            .background_effect => self.background_effect_blurs,
            .kde_blur => self.kde_blur,
        };
    }
};

/// The managers a window's blur is made through, each null where the
/// compositor does not offer it, or where a test plays the offers.
pub const BlurManagers = struct {
    background_effect: ?*Proxy,
    kde_blur: ?*Proxy,
};

/// A window's material: whether its surface holds alpha with a blur behind
/// it, chosen when it opens, and the blur's region, kept the window's size.
pub const WindowMaterial = struct {
    /// Null for an opaque window, which draws its own background.
    protocol: ?BlurProtocol = null,
    /// The protocol's object for the surface; null under offers a test
    /// plays, which still record the regions they would send.
    effect: ?*Proxy = null,
    /// In surface coordinates, the size the last region covered.
    blur_region_size: ?[2]u32 = null,
    blur_regions_sent: u32 = 0,

    /// `.window` and `.transient` blur alike, since neither protocol has a
    /// strength.
    pub fn begin(self: *WindowMaterial, asked: zui.SystemMaterial, offers: BlurOffers, managers: BlurManagers, surface: *Proxy) void {
        if (asked == .none) return;
        const protocol = offers.preferred() orelse return;
        self.protocol = protocol;
        self.effect = switch (protocol) {
            .background_effect => if (managers.background_effect) |manager|
                wayland.create(manager, wayland.background_effect_manager_get_background_effect, &wayland.background_effect_interface, 1, .{ wayland.no_id, surface })
            else
                null,
            .kde_blur => if (managers.kde_blur) |manager|
                wayland.create(manager, wayland.kde_blur_manager_create, &wayland.kde_blur_interface, 1, .{ wayland.no_id, surface })
            else
                null,
        };
    }

    /// The window's pixels are blended over the blur by their alpha, so
    /// the renderer keeps it; otherwise every pixel is opaque.
    pub fn holdsAlpha(self: *const WindowMaterial) bool {
        return self.protocol != null;
    }

    /// Blurs behind the whole window, from the surface's next commit; an
    /// unchanged size sends nothing.
    pub fn cover(self: *WindowMaterial, compositor: *Proxy, size: [2]u32) void {
        const protocol = self.protocol orelse return;
        if (std.meta.eql(self.blur_region_size, @as(?[2]u32, size))) return;
        self.blur_region_size = size;
        self.blur_regions_sent += 1;
        const effect = self.effect orelse return;
        const region = wayland.create(compositor, wayland.compositor_create_region, &wayland.wl_region_interface, wayland.wl_proxy_get_version(compositor), .{wayland.no_id}) orelse return;
        defer wayland.destroy(region, wayland.region_destroy);
        const width: i32 = @intCast(@min(size[0], std.math.maxInt(i32)));
        const height: i32 = @intCast(@min(size[1], std.math.maxInt(i32)));
        wayland.send(region, wayland.region_add, .{ @as(i32, 0), @as(i32, 0), width, height });
        switch (protocol) {
            .background_effect => wayland.send(effect, wayland.background_effect_set_blur_region, .{region}),
            .kde_blur => {
                wayland.send(effect, wayland.kde_blur_set_region, .{region});
                wayland.send(effect, wayland.kde_blur_commit, .{});
            },
        }
    }

    /// Before the surface is destroyed.
    pub fn deinit(self: *WindowMaterial) void {
        if (self.effect) |effect| switch (self.protocol.?) {
            .background_effect => wayland.destroy(effect, wayland.background_effect_destroy),
            .kde_blur => wayland.destroy(effect, wayland.kde_blur_release),
        };
        self.* = .{};
    }
};

test "ext_background_effect_v1 is preferred where both protocols blur, and a manager without blur is passed over" {
    try std.testing.expectEqual(BlurProtocol.background_effect, (BlurOffers{ .background_effect_blurs = true, .kde_blur = true }).preferred().?);
    try std.testing.expectEqual(BlurProtocol.kde_blur, (BlurOffers{ .kde_blur = true }).preferred().?);
    try std.testing.expectEqual(@as(?BlurProtocol, null), (BlurOffers{}).preferred());
}
