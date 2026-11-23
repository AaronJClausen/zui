const std = @import("std");
const zui = @import("zui");

/// The guide's sections, each a tab.
const Section = enum { getting_started, layout, containers, navigation, tokens, changelog };
/// What a section shows, each a tab in the groove below the sections.
const View = enum { overview, examples, settings };

const Guide = struct { title: []const u8, summary: []const u8 };
const Example = struct { title: []const u8, body: []const u8, note: []const u8 };

const Contents = struct {
    title: []const u8,
    guides: []const Guide,
    example: Example,
    follow: []const u8,
};

/// Each section's guides, its example and the update it can be followed for.
const contents = std.EnumArray(Section, Contents).init(.{
    .getting_started = .{
        .title = "Getting started",
        .guides = &.{
            .{ .title = "Declare a frame", .summary = "Open and close elements into a zui.Context every frame; zui keeps only what you keep." },
            .{ .title = "Pick a renderer", .summary = "raylib, sokol, the terminal and WebGL draw the same commands, each saying which it draws." },
            .{ .title = "Run it with zui_app", .summary = "One call ties your app to a host, a renderer and a font system, and sleeps between frames." },
        },
        .example = .{ .title = "The smallest app", .body = "A button that counts its clicks: one open, one text and one close, declared again each frame.", .note = "Its id is all zui remembers of it." },
        .follow = "Email me when Getting started changes",
    },
    .layout = .{
        .title = "Layout",
        .guides = &.{
            .{ .title = "Sizing", .summary = "Fixed, fit, grow or a share of the parent, along each axis on its own." },
            .{ .title = "Padding and gaps", .summary = "Room inside an element's edges, and between its children." },
            .{ .title = "Alignment", .summary = "Children at the start, the center or the end of either axis." },
            .{ .title = "Text wrapping", .summary = "Text wraps at words to its container's width, measured once and cached." },
            .{ .title = "Floating", .summary = "An element attached to its parent, the root or another by id, above the page." },
        },
        .example = .{ .title = "Two columns", .body = "A sidebar of a fixed width beside content that grows to fill the window.", .note = "Resize the window: only the content's width changes." },
        .follow = "Email me when Layout changes",
    },
    .containers = .{
        .title = "Containers",
        .guides = &.{
            .{ .title = "Cards", .summary = "A raised surface for one thing, and a button when it opens something." },
            .{ .title = "Scroll areas", .summary = "A thin scrollbar that widens under the pointer and fades when idle." },
            .{ .title = "Group boxes", .summary = "Rows of settings on one card, titled and described." },
            .{ .title = "Dividers", .summary = "A line between sections, inset at one edge or both, or broken by a label." },
        },
        .example = .{ .title = "A card that is not a button", .body = "It stands at the raised elevation: its surface, its rim and its shadow come from the tokens.", .note = "An inset divider stops short of the card's edges." },
        .follow = "Email me when Containers changes",
    },
    .navigation = .{
        .title = "Navigation",
        .guides = &.{
            .{ .title = "Tabs", .summary = "Sections of one page, underlined or in a groove; the arrow keys move between them." },
            .{ .title = "Sidebar lists", .summary = "Places to go in sections, with counts and shortcuts, a density's xs tier apart." },
            .{ .title = "Breadcrumbs", .summary = "The way back up; past four crumbs the middle ones fold away." },
        },
        .example = .{ .title = "This page", .body = "Its sections are tabs, its views a groove, and the trail above it follows both.", .note = "The tour's rail of screens is a sidebar list." },
        .follow = "Email me when Navigation changes",
    },
    .tokens = .{
        .title = "Tokens",
        .guides = &.{
            .{ .title = "Color roles", .summary = "Surfaces and the text on them, resolved for the theme, the contrast and color vision." },
            .{ .title = "Spacing tiers", .summary = "From hair to xxl, every tier scaled by the density, compact to roomy." },
            .{ .title = "Elevations", .summary = "Raised, floating and modal: a surface, a rim and a shadow each." },
            .{ .title = "Motion", .summary = "A spring or a tween for each kind of change, landing at once under reduced motion." },
        },
        .example = .{ .title = "Resolved again", .body = "Change the density in Preferences: every gap and control height on this page follows.", .note = "Its widgets name no size of their own." },
        .follow = "Email me when Tokens changes",
    },
    .changelog = .{
        .title = "Changelog",
        .guides = &.{
            .{ .title = "2.4", .summary = "Tabs slide their underline through the toggle spring." },
            .{ .title = "2.3", .summary = "Breadcrumbs fold their middle crumbs past four." },
            .{ .title = "2.2", .summary = "Scroll areas fade their edges into the surface beneath." },
            .{ .title = "2.1", .summary = "Group boxes take a description below the box." },
            .{ .title = "2.0", .summary = "Cards lift while hovered and press in while pressed." },
        },
        .example = .{ .title = "Reading a release", .body = "Each release is a card: its number, then what changed for the widgets you use.", .note = "Follow the changelog under Settings to hear of the next." },
        .follow = "Email me when the Changelog changes",
    },
});

const ids = zui.ids(.{
    "field_guide.path",
    "field_guide.sections",
    "field_guide.views",
    "field_guide.guides",
    "field_guide.example",
    "field_guide.settings",
    "field_guide.compact",
    "field_guide.counts",
});

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        /// A documentation browser built from the containers and the
        /// navigation: sections on tabs, views in a groove, a trail back,
        /// cards, group boxes and areas that scroll.
        pub const FieldGuide = struct {
            section: Section = .containers,
            view: View = .overview,
            opened: ?usize = null,
            compact: bool = false,
            show_counts: bool = true,
            following: std.EnumArray(Section, bool) = .initFill(false),

            pub fn declare(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                shell.pageHeading(ui, "FIELD GUIDE", "Containers and navigation", "A documentation browser drawn from the tokens: sections on tabs, views in a groove, a trail back, cards and areas that scroll.");
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                self.trail(ui, shell);
                if (widgets.tabs(ui, ids.@"field_guide.sections", &self.section, .{ .label = "Sections" })) self.opened = null;
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    const guide_count = contents.get(self.section).guides.len;
                    if (self.show_counts) shell.printColored(ui, .caption, shell.colors.get(.on_surface_muted), "{d} {s} in {s}", .{ guide_count, if (guide_count == 1) "guide" else "guides", contents.get(self.section).title });
                    shell.spacer(ui);
                    _ = widgets.tabs(ui, ids.@"field_guide.views", &self.view, .{ .style = .pill, .label = "View" });
                }
                switch (self.view) {
                    .overview => self.overview(ui, shell),
                    .examples => self.example(ui, shell),
                    .settings => self.settings(ui, shell),
                }
            }

            fn trail(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const crumbs = [_][]const u8{ "Docs", "Field guide", contents.get(self.section).title, viewTitle(self.view) };
                const chosen = shell.widgets.breadcrumbs(ui, ids.@"field_guide.path", &crumbs, .{ .label = "Location" }) orelse return;
                if (chosen < 2) self.section = .getting_started;
                self.view = .overview;
                self.opened = null;
            }

            fn viewTitle(view: View) []const u8 {
                return switch (view) {
                    .overview => "Overview",
                    .examples => "Examples",
                    .settings => "Settings",
                };
            }

            fn overview(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const guides = contents.get(self.section).guides;
                const area = widgets.scrollArea(ui, ids.@"field_guide.guides", .{ .child_gap = 12, .label = "Guides" });
                defer area.end(ui);
                if (self.opened) |index| {
                    ui.open(.{ .layout = .{ .child_gap = 6 } });
                    defer ui.close();
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
                    if (index + 1 == guides.len) ui.box(.{ .layout = .{ .sizing = .{ .width = .grow_equal } } });
                }
                widgets.divider(ui, .{ .label = "end of the section" });
            }

            fn example(self: *FieldGuide, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const shown = contents.get(self.section).example;
                _ = widgets.card(ui, ids.@"field_guide.example", .{});
                widgets.cardTitle(ui, shown.title);
                widgets.cardBody(ui, shown.body);
                widgets.divider(ui, .{ .inset = .both });
                widgets.cardBody(ui, shown.note);
                ui.close();
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
                    _ = widgets.checkbox(ui, ids.@"field_guide.counts", "Show how many guides a section holds", &self.show_counts, .{});
                }
                {
                    const updates = widgets.groupBox(ui, .of("field_guide.updates"), "Updates", .{ .description = "A weekly digest, for the sections you follow." });
                    defer updates.end(ui);
                    const section = self.section;
                    _ = widgets.checkbox(ui, .indexed("field_guide.follow", @intFromEnum(section)), contents.get(section).follow, self.following.getPtr(section), .{});
                }
            }
        };
    };
}
