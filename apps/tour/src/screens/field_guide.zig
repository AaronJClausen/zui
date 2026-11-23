const std = @import("std");
const zui = @import("zui");

const Tab = enum { overview, examples, settings };
const ExampleView = enum { cards, timeline };

const Guide = struct { title: []const u8, summary: []const u8 };

const guides = [_]Guide{
    .{ .title = "Cards", .summary = "A raised surface for one thing, and a button when it opens something." },
    .{ .title = "Scroll areas", .summary = "A thin scrollbar that widens under the pointer and fades when idle." },
    .{ .title = "Group boxes", .summary = "Rows of settings on one card, titled and described." },
    .{ .title = "Tabs", .summary = "Sections of one page; the arrow keys move between them." },
    .{ .title = "Sidebar lists", .summary = "Places to go, in sections, hovered in the secondary container." },
    .{ .title = "Breadcrumbs", .summary = "The way back up; past four crumbs the middle ones fold away." },
};

const timeline = [_][]const u8{
    "2.4: tabs slide their underline through the toggle spring",
    "2.3: breadcrumbs fold their middle crumbs past four",
    "2.2: scroll areas fade their edges into the surface",
    "2.1: group boxes take a description below the box",
    "2.0: cards lift while hovered and press in while pressed",
    "1.9: sidebar lists skip their headings with the arrow keys",
    "1.8: dividers take an inset and a label",
    "1.7: the scrollbar's thumb is dragged, or the track paged",
    "1.6: every container reads its look from the tokens",
    "1.5: the field guide opened",
};

const ids = zui.ids(.{
    "field_guide.places",
    "field_guide.path",
    "field_guide.tabs",
    "field_guide.views",
    "field_guide.guides",
    "field_guide.timeline",
    "field_guide.settings",
    "field_guide.compact",
    "field_guide.counts",
    "field_guide.digest",
});

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const NavigationItem = kit.zui_widgets.NavigationItem;
    const places = [_]NavigationItem{
        .{ .label = "Basics", .heading = true },
        .{ .label = "Getting started" },
        .{ .label = "Layout", .count = "6" },
        .{ .label = "Widgets", .heading = true },
        .{ .label = "Containers", .count = "4" },
        .{ .label = "Navigation", .count = "3" },
        .{ .label = "Reference", .heading = true },
        .{ .label = "Tokens" },
        .{ .label = "Changelog" },
    };
    return struct {
        /// A documentation browser built from the containers and the
        /// navigation: a sidebar list, a trail back, tabs, cards, group
        /// boxes and areas that scroll.
        pub const FieldGuide = struct {
            place: usize = 4,
            tab: Tab = .overview,
            view: ExampleView = .cards,
            opened: ?usize = null,
            compact: bool = false,
            show_counts: bool = true,
            digest: bool = true,

            pub fn declare(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                shell.pageHeading(ui, "FIELD GUIDE", "Containers and navigation", "A documentation browser drawn from the tokens: a sidebar, a trail back, tabs, cards and areas that scroll.");
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(@round(230 * shell.text_scale)), .height = .grow } } });
                    defer ui.close();
                    var shown: [places.len]NavigationItem = places;
                    if (!self.show_counts) for (&shown) |*item| {
                        item.count = "";
                    };
                    _ = widgets.navigationList(ui, ids.@"field_guide.places", &shown, &self.place, .{ .label = "Field guide" });
                }
                widgets.divider(ui, .{ .axis = .vertical });
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                self.trail(ui, shell);
                _ = widgets.tabs(ui, ids.@"field_guide.tabs", &self.tab, .{ .label = "Page" });
                switch (self.tab) {
                    .overview => self.overview(ui, shell),
                    .examples => self.examples(ui, shell),
                    .settings => self.settings(ui, shell),
                }
            }

            fn trail(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const section = sectionOf(self.place);
                const crumbs = [_][]const u8{ "Docs", "Field guide", places[section].label, places[self.place].label };
                const chosen = shell.widgets.breadcrumbs(ui, ids.@"field_guide.path", &crumbs, .{ .label = "Location" }) orelse return;
                if (chosen < 2) self.place = 1 else self.place = section + 1;
                self.tab = .overview;
            }

            fn sectionOf(place: usize) usize {
                var index = place;
                while (index > 0 and !places[index].heading) index -= 1;
                return index;
            }

            fn overview(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const area = widgets.scrollArea(ui, ids.@"field_guide.guides", .{ .child_gap = 12, .label = "Guides" });
                defer area.end(ui);
                if (self.opened) |index| {
                    shell.labelColored(ui, .body, shell.colors.get(.on_surface_muted), "Opened:");
                    shell.label(ui, .body, guides[index].title);
                }
                var index: usize = 0;
                while (index < guides.len) : (index += 2) {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
                    defer ui.close();
                    for (guides[index..@min(index + 2, guides.len)], index..) |guide, guide_index| {
                        if (widgets.card(ui, .indexed("field_guide.guide", guide_index), .{ .interactive = true, .label = guide.title, .width = .grow_equal })) self.opened = guide_index;
                        widgets.cardTitle(ui, guide.title);
                        if (!self.compact) widgets.cardBody(ui, guide.summary);
                        ui.close();
                    }
                }
                widgets.divider(ui, .{ .label = "end of the guides" });
            }

            fn examples(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                _ = widgets.tabs(ui, ids.@"field_guide.views", &self.view, .{ .style = .pill, .label = "View" });
                switch (self.view) {
                    .cards => {
                        _ = widgets.card(ui, .of("field_guide.example"), .{});
                        widgets.cardTitle(ui, "A card that is not a button");
                        widgets.cardBody(ui, "It stands at the raised elevation: its surface, its rim and its shadow come from the tokens.");
                        widgets.divider(ui, .{ .inset = .both });
                        widgets.cardBody(ui, "An inset divider stops short of the card's edges.");
                        ui.close();
                    },
                    .timeline => {
                        const area = widgets.scrollArea(ui, ids.@"field_guide.timeline", .{ .height = .fixed(@round(220 * shell.text_scale)), .child_gap = 10, .label = "Changes" });
                        defer area.end(ui);
                        for (timeline, 0..) |change, index| {
                            if (index != 0) widgets.divider(ui, .{});
                            shell.label(ui, .body, change);
                        }
                    },
                }
            }

            fn settings(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const area = widgets.scrollArea(ui, ids.@"field_guide.settings", .{ .child_gap = 16, .label = "Settings" });
                defer area.end(ui);
                {
                    const reading = widgets.groupBox(ui, .of("field_guide.reading"), "Reading", .{ .description = "Compact cards show their titles alone." });
                    defer reading.end(ui);
                    _ = widgets.checkbox(ui, ids.@"field_guide.compact", "Compact cards", &self.compact, .{});
                    widgets.divider(ui, .{});
                    _ = widgets.checkbox(ui, ids.@"field_guide.counts", "Show counts in the sidebar", &self.show_counts, .{});
                }
                {
                    const updates = widgets.groupBox(ui, .of("field_guide.updates"), "Updates", .{});
                    defer updates.end(ui);
                    _ = widgets.checkbox(ui, ids.@"field_guide.digest", "Email me a weekly digest", &self.digest, .{});
                }
            }
        };
    };
}
