const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

const Room = enum { cabin, lodge, treehouse };
const Listing = enum { list, grid, map };
const Arrival = enum { morning, afternoon, evening, late_night };
const Amenity = enum { sea_view, sauna, breakfast_included, pets_welcome };

const places = [_][]const u8{ "Lisbon", "Porto", "Sintra" };
const policy_url = "https://example.com/cancellation";

const ids = zui.ids(.{
    "cabin_booking.search",
    "cabin_booking.listing",
    "cabin_booking.room",
    "cabin_booking.budget",
    "cabin_booking.policy",
    "cabin_booking.nights",
    "cabin_booking.guests",
    "cabin_booking.breakfast",
    "cabin_booking.pets",
    "cabin_booking.email",
    "cabin_booking.arrival",
    "cabin_booking.details",
    "cabin_booking.book",
    "cabin_booking.save",
    "cabin_booking.share",
    "cabin_booking.close",
    "cabin_booking.agree",
    "cabin_booking.form",
    "cabin_booking.confirm",
    "cabin_booking.confirm.cancel",
    "cabin_booking.confirm.book",
    "cabin_booking.notices",
});

const undo_booking = 1;

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        /// A booking form built from the essential inputs: a search field
        /// and filter chips, a segmented control, a radio group, a slider
        /// with ticks, steppers, switches in settings rows, a text field
        /// with help and an error, buttons of each size and a link. Its
        /// icon buttons show their labels as tooltips; Book asks in a
        /// dialog, and a toast says what happened, with an Undo.
        pub const CabinBooking = struct {
            query_bytes: [48]u8 = undefined,
            query: zui_widgets.EditableText = .{ .buffer = &.{} },
            email_bytes: [64]u8 = undefined,
            email: zui_widgets.EditableText = .{ .buffer = &.{} },
            amenities: std.EnumArray(Amenity, bool) = .initFill(false),
            shown_places: [places.len]bool = @splat(true),
            listing: Listing = .list,
            room: Room = .cabin,
            budget: u16 = 120,
            nights: u8 = 3,
            guests: u8 = 2,
            breakfast: bool = true,
            pets: bool = false,
            agreed: bool = false,
            arrival: Arrival = .afternoon,
            details_open: bool = true,
            booked: u32 = 0,
            saved: bool = false,
            policy_opened: bool = false,
            confirming: bool = false,
            notice_storage: [4]zui_widgets.ToastEntry = undefined,
            notices: zui_widgets.ToastQueue = .{ .entries = &.{} },

            pub fn declare(self: *CabinBooking, ui: *Ui, shell: *const Shell) void {
                if (self.query.buffer.len == 0) {
                    self.query = .init(&self.query_bytes, "");
                    self.email = .init(&self.email_bytes, "ada@");
                    self.notices = .init(&self.notice_storage);
                }
                if (ui.chordPressed(.{ .key = .k, .modifiers = .{ .control = true } })) ui.requestFocus(ids.@"cabin_booking.search");
                shell.pageHeading(ui, "CABIN BOOKING", "Essential inputs", "A booking form drawn from the tokens: search and filters, choices, numbers, switches, a field that explains itself, and buttons of every size.");
                {
                    const area = shell.widgets.scrollArea(ui, ids.@"cabin_booking.form", .{ .direction = .left_to_right, .child_gap = 16, .label = "Booking" });
                    defer area.end(ui);
                    self.find(ui, shell);
                    self.book(ui, shell);
                }
                self.confirm(ui, shell);
                if (shell.widgets.toasts(ui, ids.@"cabin_booking.notices", &self.notices)) |tag| {
                    if (tag == undo_booking and self.booked != 0) {
                        self.booked -= 1;
                        _ = self.notices.push(.{ .message = "Booking undone." });
                    }
                }
            }

            fn confirm(self: *CabinBooking, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                var description: [96]u8 = undefined;
                const shown = widgets.dialog(ui, ids.@"cabin_booking.confirm", &self.confirming, .{
                    .title = "Book this stay?",
                    .description = std.fmt.bufPrint(&description, "{d} nights for {d} guests, at {d} a night.", .{ self.nights, self.guests, self.budget }) catch "",
                    .initial_focus = ids.@"cabin_booking.confirm.book",
                }) orelse return;
                defer shown.end(ui);
                widgets.labelWith(ui, "Free cancellation until 48 hours before.", .{ .role = .caption, .tone = .muted });
                shown.actions(ui);
                defer ui.close();
                if (widgets.button(ui, ids.@"cabin_booking.confirm.cancel", "Not yet", .{ .variant = .secondary })) self.confirming = false;
                if (widgets.button(ui, ids.@"cabin_booking.confirm.book", "Book", .{})) {
                    self.confirming = false;
                    self.booked += 1;
                    var message: [64]u8 = undefined;
                    _ = self.notices.push(.{
                        .message = std.fmt.bufPrint(&message, "Booked {d} nights by the bay.", .{self.nights}) catch "Booked.",
                        .action = "Undo",
                        .tone = .success,
                        .tag = undo_booking,
                    });
                }
            }

            fn find(self: *CabinBooking, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 12 } });
                defer ui.close();
                widgets.labelWith(ui, "Find a stay", .{ .role = .title });
                _ = widgets.searchField(ui, ids.@"cabin_booking.search", &self.query, .{ .placeholder = "Search cabins", .shortcut = "Ctrl K", .label = "Search cabins" });
                for (0..2) |line| {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                    defer ui.close();
                    for (std.enums.values(Amenity)[line * 2 ..][0..2]) |amenity| {
                        _ = widgets.chip(ui, .indexed("cabin_booking.amenity", @intFromEnum(amenity)), amenityLabel(amenity), .{ .selected = self.amenities.getPtr(amenity) });
                    }
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    var any = false;
                    for (places, &self.shown_places, 0..) |place, *shown, index| {
                        if (!shown.*) continue;
                        any = true;
                        if (widgets.chip(ui, .indexed("cabin_booking.place", index), place, .{ .closable = true }).closed) shown.* = false;
                    }
                    if (!any) {
                        widgets.labelWith(ui, "Anywhere", .{ .tone = .muted });
                        if (widgets.button(ui, .of("cabin_booking.places_reset"), "Bring them back", .{ .variant = .tertiary, .size = .small })) self.shown_places = @splat(true);
                    }
                }
                widgets.divider(ui, .{});
                widgets.labeledRow(ui, "Show as");
                _ = widgets.segmented(ui, ids.@"cabin_booking.listing", &self.listing, .{ .label = "Show as" });
                ui.close();
                widgets.labeledRow(ui, "Room");
                _ = widgets.radioGroup(ui, ids.@"cabin_booking.room", &self.room, .{ .label = "Room", .direction = .left_to_right });
                ui.close();
                widgets.labeledRowWith(ui, "Budget a night", .{ .description = "Drag to see the price." });
                _ = widgets.slider(ui, ids.@"cabin_booking.budget", &self.budget, .{ .min = 40, .max = 240, .step = 20, .ticks = true, .label = "Budget a night" });
                ui.close();
                {
                    ui.open(.{ .layout = .{ .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    widgets.labelWith(ui, "Free cancellation until 48 hours before.", .{ .role = .caption, .tone = .muted });
                    if (widgets.link(ui, ids.@"cabin_booking.policy", "Read the policy", policy_url)) self.policy_opened = true;
                }
                if (self.policy_opened) widgets.labelWith(ui, "The host's open_url service would open " ++ policy_url ++ ".", .{ .role = .caption, .tone = .accent, .wrap = .words });
                widgets.labelWith(ui, "This tour loads no icon font, so the icon buttons and the field's leading icons draw nothing; each frame counts them in Diagnostics.missing_icons.", .{ .role = .caption, .tone = .muted, .wrap = .words });
            }

            fn book(self: *CabinBooking, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 12 } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 4, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    widgets.labelWith(ui, "Your booking", .{ .role = .title });
                    shell.spacer(ui);
                    _ = widgets.iconButton(ui, ids.@"cabin_booking.share", .info, .{ .label = "About this cabin", .variant = .tonal, .size = .small });
                    _ = widgets.iconButton(ui, ids.@"cabin_booking.close", .close, .{ .label = "Close", .size = .small });
                }
                {
                    const stay = widgets.groupBox(ui, .of("cabin_booking.stay"), "Stay", .{ .description = "Pets stay free; breakfast is 12 a night." });
                    defer stay.end(ui);
                    widgets.labeledRow(ui, "Nights");
                    _ = widgets.numberStepper(ui, ids.@"cabin_booking.nights", &self.nights, .{ .min = 1, .max = 30, .unit = "nights", .label = "Nights" });
                    ui.close();
                    widgets.labeledRowWith(ui, "Guests", .{ .divider_above = true });
                    _ = widgets.numberStepper(ui, ids.@"cabin_booking.guests", &self.guests, .{ .min = 1, .max = 8, .label = "Guests" });
                    ui.close();
                    widgets.labeledRowWith(ui, "Breakfast", .{ .description = "Served from 7 to 10.", .divider_above = true });
                    _ = widgets.toggle(ui, ids.@"cabin_booking.breakfast", "", &self.breakfast, .{ .label = "Breakfast" });
                    ui.close();
                    widgets.labeledRowWith(ui, "Pets", .{ .divider_above = true });
                    _ = widgets.toggle(ui, ids.@"cabin_booking.pets", "", &self.pets, .{ .label = "Pets" });
                    ui.close();
                }
                const valid = std.mem.indexOfScalar(u8, self.email.slice(), '@') != null and std.mem.indexOfScalar(u8, self.email.slice(), '.') != null;
                _ = widgets.textField(ui, ids.@"cabin_booking.email", &self.email, .{
                    .label = "Email",
                    .show_label = true,
                    .placeholder = "ada@example.com",
                    .help = "We send the receipt here.",
                    .error_message = if (valid) "" else "Enter a whole address, like ada@example.com.",
                    .leading_icon = .info,
                });
                widgets.labeledRow(ui, "Arrival");
                _ = widgets.dropdownEnum(ui, ids.@"cabin_booking.arrival", &self.arrival, .{ .label = "Arrival" });
                ui.close();
                _ = widgets.disclosure(ui, ids.@"cabin_booking.details", "Price details", &self.details_open);
                if (self.details_open) self.priceDetails(ui, shell);
                _ = widgets.checkbox(ui, ids.@"cabin_booking.agree", "I accept the house rules", &self.agreed, .{});
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    if (widgets.button(ui, ids.@"cabin_booking.book", "Book", .{ .size = .large, .leading_icon = .check, .disabled = !self.agreed or !valid })) self.confirming = true;
                    if (widgets.button(ui, ids.@"cabin_booking.save", if (self.saved) "Saved" else "Save for later", .{ .variant = .secondary, .size = .small })) {
                        self.saved = !self.saved;
                        _ = self.notices.push(.{ .message = if (self.saved) "Saved for later." else "No longer saved." });
                    }
                    widgets.tooltip(ui, ids.@"cabin_booking.save", "Keep this stay in your list", .{ .shortcut = "Ctrl+S" });
                }
                if (self.booked != 0) shell.print(ui, .caption, "Booked {d} time{s}.", .{ self.booked, if (self.booked == 1) "" else "s" });
            }

            fn priceDetails(self: *const CabinBooking, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const breakfasts: u32 = if (self.breakfast) @as(u32, self.nights) * self.guests * 12 else 0;
                const stay: u32 = @as(u32, self.nights) * self.budget;
                var buffer: [64]u8 = undefined;
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .{ .left = 24 }, .child_gap = 4 } });
                defer ui.close();
                widgets.labelWith(ui, std.fmt.bufPrint(&buffer, "{d} nights at {d}: {d}", .{ self.nights, self.budget, stay }) catch "", .{ .role = .numeric });
                widgets.labelWith(ui, std.fmt.bufPrint(&buffer, "Breakfast: {d}", .{breakfasts}) catch "", .{ .role = .numeric, .tone = .muted });
                widgets.labelWith(ui, std.fmt.bufPrint(&buffer, "Total {d}", .{stay + breakfasts}) catch "", .{ .role = .label_strong, .tone = .accent });
            }

            fn amenityLabel(amenity: Amenity) []const u8 {
                return switch (amenity) {
                    inline else => |tag| comptime zui_widgets.labelFromIdentifier(@tagName(tag)),
                };
            }
        };
    };
}
