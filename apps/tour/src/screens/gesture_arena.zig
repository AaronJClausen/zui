const std = @import("std");
const zui = @import("zui");

const world_size: [2]f32 = .{ 2000, 1200 };
const grid_spacing = 100;
const minimum_zoom = 0.25;
const maximum_zoom = 3;
/// The list is pinned to this point of the world, so it moves with the map.
const list_anchor: [2]f32 = .{ 760, 380 };
const list_size: [2]f32 = .{ 300, 340 };
const card_size: [2]f32 = .{ 132, 84 };
const card_gap = 8;
/// A session ends once nothing has moved for this long.
const session_idle_seconds = 0.6;
const log_capacity = 12;
const lasso_capacity = 256;

const Place = struct { name: []const u8, position: [2]f32 };

const place_names = [_][]const u8{
    "North Pier",    "Customs",        "Dry Dock 2",  "Ferry Slip", "Grain Silo",    "Lighthouse",
    "Pilot Station", "Container Yard", "Fish Market", "Tug Basin",  "Coal Wharf",    "Marina",
    "Signal Tower",  "Rope Walk",      "Boat Yard",   "Ice House",  "Harbor Office", "Old Quay",
    "Fuel Berth",    "Breakwater",     "Crane 7",     "Cold Store", "Ship Chandler", "South Mole",
};

/// Spread over the world along two irrational strides, so they never line up.
const places: [place_names.len]Place = blk: {
    var result: [place_names.len]Place = undefined;
    for (place_names, 0..) |name, index| {
        const along: f32 = @floatFromInt(index + 1);
        const x = along * 0.6180339 - @floor(along * 0.6180339);
        const y = along * 0.4142135 - @floor(along * 0.4142135);
        result[index] = .{ .name = name, .position = .{ 120 + x * (world_size[0] - 240), 100 + y * (world_size[1] - 200) } };
    }
    break :blk result;
};

const vessels = [_][2][]const u8{
    .{ "Northern Star", "berth 4, 06:40" },
    .{ "Kestrel", "anchored" },
    .{ "Maren Holt", "berth 9, 08:15" },
    .{ "Aurora Bay", "pilot boarding" },
    .{ "Selkie", "berth 2, 11:00" },
    .{ "Grey Heron", "in tow" },
    .{ "Cape Verity", "berth 7, 13:30" },
    .{ "Tern", "departed" },
};

const list_rows = [_][]const u8{
    "Berth 1, ro-ro",   "Berth 2, ferries", "Berth 3, bulk",     "Berth 4, containers",
    "Berth 5, tankers", "Berth 6, repair",  "Berth 7, cruise",   "Berth 8, reefer",
    "Berth 9, project", "Berth 10, layby",  "Berth 11, fishing", "Berth 12, naval",
};

/// What a press landed on, by the rectangles of the frame before.
const Target = union(enum) {
    map,
    control,
    list,
    row: u8,
    carousel,
    card: u8,
};

/// What took a pointer's motion, as the page saw it move.
const Winner = enum {
    map_pan,
    map_zoom,
    list,
    carousel,

    fn title(winner: Winner) []const u8 {
        return switch (winner) {
            .map_pan => "The map took the pan",
            .map_zoom => "The map took the pinch",
            .list => "The list took the drag",
            .carousel => "The carousel took the drag",
        };
    }
};

const Axis = enum { horizontal, vertical };

fn predictedWinner(target: Target, axis: Axis) Winner {
    return switch (target) {
        .card, .carousel => if (axis == .horizontal) .carousel else .list,
        .row, .list => if (axis == .vertical) .list else .map_pan,
        .map, .control => .map_pan,
    };
}

fn ruleReason(target: Target, axis: Axis) []const u8 {
    return switch (target) {
        .card, .carousel => if (axis == .horizontal)
            "Pressed on the carousel, moving sideways: the innermost element under the press that pans that way."
        else
            "Pressed on a card, moving vertically: the carousel pans only sideways, so the list around it takes it.",
        .row, .list => if (axis == .vertical)
            "Pressed in the list, moving vertically: the innermost element under the press that pans that way."
        else
            "Pressed in the list, moving sideways: the list pans only vertically, so the map around it takes it.",
        .map => "Pressed on the map itself: nothing inside it was under the press.",
        .control => "Pressed on a button, which does not pan: past the slop, the map around it takes the drag.",
    };
}

fn winnerName(winner: Winner) []const u8 {
    return switch (winner) {
        .map_pan, .map_zoom => "map",
        .list => "list",
        .carousel => "carousel",
    };
}

const Tone = enum { map, list, carousel, lasso, tap };

const LogEntry = struct {
    tone: Tone = .tap,
    title_bytes: [64]u8 = undefined,
    title_len: u8 = 0,
    detail_bytes: [160]u8 = undefined,
    detail_len: u8 = 0,
    meta_bytes: [64]u8 = undefined,
    meta_len: u8 = 0,

    fn title(entry: *const LogEntry) []const u8 {
        return entry.title_bytes[0..entry.title_len];
    }

    fn detail(entry: *const LogEntry) []const u8 {
        return entry.detail_bytes[0..entry.detail_len];
    }

    fn meta(entry: *const LogEntry) []const u8 {
        return entry.meta_bytes[0..entry.meta_len];
    }
};

fn copyInto(buffer: []u8, content: []const u8) u8 {
    const length = @min(buffer.len, content.len);
    @memcpy(buffer[0..length], content[0..length]);
    return @intCast(length);
}

const ArbitrationLog = struct {
    entries: [log_capacity]LogEntry = undefined,
    newest: usize = log_capacity - 1,
    count: usize = 0,
    total: u32 = 0,

    fn add(log: *ArbitrationLog, tone: Tone, title: []const u8, detail: []const u8, comptime meta_format: []const u8, meta_arguments: anytype) void {
        log.newest = (log.newest + 1) % log_capacity;
        log.count = @min(log.count + 1, log_capacity);
        log.total += 1;
        const entry = &log.entries[log.newest];
        entry.* = .{ .tone = tone };
        entry.title_len = copyInto(&entry.title_bytes, title);
        entry.detail_len = copyInto(&entry.detail_bytes, detail);
        const meta = std.fmt.bufPrint(&entry.meta_bytes, meta_format, meta_arguments) catch "";
        entry.meta_len = @intCast(meta.len);
    }

    /// Newest first.
    fn at(log: *const ArbitrationLog, age: usize) *const LogEntry {
        return &log.entries[(log.newest + log_capacity - age) % log_capacity];
    }
};

/// One press and what its motion went to, until things settle.
const Session = struct {
    open: bool = false,
    pressed: bool = false,
    kind: zui.PointerKind = .mouse,
    target: Target = .map,
    axis: Axis = .horizontal,
    logged: std.EnumSet(Winner) = .initEmpty(),
    last_activity_seconds: f64 = 0,
};

fn kindName(kind: zui.PointerKind) []const u8 {
    return switch (kind) {
        .mouse => "mouse",
        .touch => "touch",
        .pen => "pen",
    };
}

fn targetName(buffer: []u8, target: Target) []const u8 {
    return switch (target) {
        .map => "the map",
        .control => "a zoom button",
        .list => "the list",
        .row => |row| std.fmt.bufPrint(buffer, "row {d}", .{row + 1}) catch "a row",
        .carousel => "the carousel",
        .card => |card| std.fmt.bufPrint(buffer, "card {d}", .{card + 1}) catch "a card",
    };
}

fn insidePolygon(point: [2]f32, polygon: []const [2]f32) bool {
    if (polygon.len < 3) return false;
    var inside = false;
    var previous = polygon[polygon.len - 1];
    for (polygon) |current| {
        const crosses = (current[1] > point[1]) != (previous[1] > point[1]);
        if (crosses) {
            const crossing_x = current[0] + (point[1] - current[1]) * (previous[0] - current[0]) / (previous[1] - current[1]);
            if (point[0] < crossing_x) inside = !inside;
        }
        previous = current;
    }
    return inside;
}

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        const ids = struct {
            const map: zui.Id = .of("gesture_arena.map");
            const list: zui.Id = .of("gesture_arena.list");
            const carousel: zui.Id = .of("gesture_arena.carousel");
            const zoom_in: zui.Id = .of("gesture_arena.zoom_in");
            const zoom_out: zui.Id = .of("gesture_arena.zoom_out");
            const lasso_tool: zui.Id = .of("gesture_arena.lasso_tool");
            const reset_view: zui.Id = .of("gesture_arena.reset_view");
            const log: zui.Id = .of("gesture_arena.log");
        };

        fn cardId(index: usize) zui.Id {
            return .indexed("gesture_arena.card", index);
        }

        fn rowId(index: usize) zui.Id {
            return .indexed("gesture_arena.row", index);
        }

        /// Where the map shows the world: its center and scale, in the
        /// map's rectangle.
        const Camera = struct {
            center: [2]f32 = .{ 900, 520 },
            zoom: f32 = 0.6,

            fn toLocal(camera: Camera, map: zui.Rect, world: [2]f32) [2]f32 {
                return .{ (world[0] - camera.center[0]) * camera.zoom + map.width / 2, (world[1] - camera.center[1]) * camera.zoom + map.height / 2 };
            }

            fn toSurface(camera: Camera, map: zui.Rect, world: [2]f32) [2]f32 {
                const local = camera.toLocal(map, world);
                return .{ map.x + local[0], map.y + local[1] };
            }

            fn zoomAbout(camera: *Camera, map: zui.Rect, surface_point: [2]f32, factor: f32) void {
                const from_middle: [2]f32 = .{ surface_point[0] - map.x - map.width / 2, surface_point[1] - map.y - map.height / 2 };
                const world: [2]f32 = .{ from_middle[0] / camera.zoom + camera.center[0], from_middle[1] / camera.zoom + camera.center[1] };
                camera.zoom = std.math.clamp(camera.zoom * factor, minimum_zoom, maximum_zoom);
                camera.center = .{ world[0] - from_middle[0] / camera.zoom, world[1] - from_middle[1] / camera.zoom };
            }

            fn keepInWorld(camera: *Camera) void {
                camera.center = .{ std.math.clamp(camera.center[0], 0, world_size[0]), std.math.clamp(camera.center[1], 0, world_size[1]) };
            }
        };

        const LassoPath = struct {
            points: [lasso_capacity][2]f32 = undefined,
            len: u16 = 0,
            pointer: ?zui.PointerId = null,

            fn add(path: *LassoPath, point: [2]f32) void {
                if (path.len == lasso_capacity) return;
                path.points[path.len] = point;
                path.len += 1;
            }

            fn slice(path: *const LassoPath) []const [2]f32 {
                return path.points[0..path.len];
            }
        };

        /// A map holding a list holding a carousel, with a log of which element each gesture went to and why.
        pub const GestureArena = struct {
            camera: Camera = .{},
            lasso_tool: bool = false,
            lasso: LassoPath = .{},
            selected: std.StaticBitSet(places.len) = .initEmpty(),
            session: Session = .{},
            log: ArbitrationLog = .{},
            previous_list_offset: [2]f32 = .{ 0, 0 },
            previous_carousel_offset: [2]f32 = .{ 0, 0 },
            previous_pointer_position: ?[2]f32 = null,
            picked_row: ?u8 = null,

            /// Declares the page into the tour's stage.
            /// The toggles the top bar's menu offers while this screen is open.
            pub fn declareMenuToggles(self: *GestureArena, ui: *Ui, shell: *const Shell) void {
                _ = shell.widgets.checkbox(ui, .of("menu.gesture_arena.lasso_tool"), "Lasso tool", &self.lasso_tool, .{});
            }

            pub fn declare(self: *GestureArena, ui: *Ui, shell: *const Shell) void {
                const map_rect = ui.rectOf(ids.map) orelse zui.Rect{ .width = 800, .height = 560 };
                self.lassoRecognizer(ui, map_rect);
                self.followMotion(ui, shell, map_rect);
                self.handleClicks(ui, map_rect);

                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    self.toolbar(ui, shell);
                    self.map(ui, shell, map_rect);
                }
                self.logCard(ui, shell);
            }

            fn targetAt(ui: *Ui, position: [2]f32) Target {
                for ([_]zui.Id{ ids.zoom_in, ids.zoom_out }) |control| {
                    if (ui.rectOf(control)) |rect| if (rect.contains(position)) return .control;
                }
                const list = ui.rectOf(ids.list) orelse return .map;
                if (!list.contains(position)) return .map;
                if (ui.rectOf(ids.carousel)) |carousel| if (carousel.contains(position)) {
                    for (0..vessels.len) |index| {
                        if (ui.rectOf(cardId(index))) |card| if (card.contains(position)) return .{ .card = @intCast(index) };
                    }
                    return .carousel;
                };
                for (0..list_rows.len) |index| {
                    if (ui.rectOf(rowId(index))) |row| if (row.contains(position)) return .{ .row = @intCast(index) };
                }
                return .list;
            }

            /// The lasso's recognizer, on the map while the tool is on. It
            /// claims a press on the map's own background and draws with it;
            /// any other press it declines, and zui arbitrates that one over
            /// all its motion since the press.
            fn lassoRecognizer(self: *GestureArena, ui: *Ui, map_rect: zui.Rect) void {
                var events = ui.pointerEvents(ids.map);
                while (events.next()) |event| switch (event) {
                    .pointer_down => |press| self.decideLasso(ui, press.pointer),
                    .pointer_move => |motion| if (self.lasso.pointer == motion.pointer.id) self.lasso.add(motion.pointer.position),
                    .pointer_up => |release| if (self.lasso.pointer == release.pointer.id) self.closeLasso(release.pointer.position, map_rect),
                    .pointer_cancel => |pointer_id| if (self.lasso.pointer == pointer_id) {
                        self.lasso = .{};
                    },
                    else => {},
                };
            }

            fn decideLasso(self: *GestureArena, ui: *Ui, pointer: zui.Pointer) void {
                const target = targetAt(ui, pointer.position);
                if (!self.lasso_tool) return ui.decline(pointer.id);
                if (self.lasso.pointer == null and target == .map) {
                    ui.claim(pointer.id);
                    self.lasso = .{ .pointer = pointer.id };
                    self.lasso.add(pointer.position);
                    self.log.add(.lasso, "The lasso claimed the press", "Pressed on the map's background, so its recognizer called claim(): from the next frame the map neither pans nor taps with it.", "{s}, claimed", .{kindName(pointer.kind)});
                    return;
                }
                ui.decline(pointer.id);
                var name: [16]u8 = undefined;
                var detail: [160]u8 = undefined;
                self.log.add(.lasso, "The lasso declined the press", std.fmt.bufPrint(&detail, "Pressed on {s}, not the background, so it called decline(): zui arbitrates the pointer as if it had never been held.", .{targetName(&name, target)}) catch "", "{s}, declined", .{kindName(pointer.kind)});
            }

            fn closeLasso(self: *GestureArena, position: [2]f32, map_rect: zui.Rect) void {
                self.lasso.add(position);
                self.lasso.pointer = null;
                self.selectInsideLasso(map_rect);
                var detail: [160]u8 = undefined;
                self.log.add(.lasso, "The lasso closed", std.fmt.bufPrint(&detail, "{d} places inside its path are selected.", .{self.selected.count()}) catch "", "{d} points drawn", .{self.lasso.len});
            }

            fn selectInsideLasso(self: *GestureArena, map_rect: zui.Rect) void {
                self.selected = .initEmpty();
                for (places, 0..) |place, index| {
                    if (insidePolygon(self.camera.toSurface(map_rect, place.position), self.lasso.slice())) self.selected.set(index);
                }
            }

            /// Credits each motion to whatever moved, and says why the rule
            /// gave it that one. Where the press began is where the pointer
            /// is less what it has moved, since an element's first motion
            /// carries all of it from the press.
            fn followMotion(self: *GestureArena, ui: *Ui, shell: *const Shell, map_rect: zui.Rect) void {
                var motions: std.EnumArray(Winner, ?[2]f32) = .initFill(null);
                if (ui.manipulation(ids.map)) |manipulation| {
                    self.camera.center[0] -= manipulation.translation[0] / self.camera.zoom;
                    self.camera.center[1] -= manipulation.translation[1] / self.camera.zoom;
                    if (manipulation.scale != 1) {
                        self.camera.zoomAbout(map_rect, manipulation.pivot, manipulation.scale);
                        motions.set(.map_zoom, .{ 0, 0 });
                    } else if (manipulation.translation[0] != 0 or manipulation.translation[1] != 0) {
                        motions.set(.map_pan, manipulation.translation);
                    }
                    self.camera.keepInWorld();
                }
                const list_offset = ui.scrollOffset(ids.list);
                if (list_offset[1] != self.previous_list_offset[1]) motions.set(.list, .{ 0, self.previous_list_offset[1] - list_offset[1] });
                self.previous_list_offset = list_offset;
                const carousel_offset = ui.scrollOffset(ids.carousel);
                if (carousel_offset[0] != self.previous_carousel_offset[0]) motions.set(.carousel, .{ self.previous_carousel_offset[0] - carousel_offset[0], 0 });
                self.previous_carousel_offset = carousel_offset;

                const pointer = ui.primaryPointer();
                const pointer_moved = if (pointer) |current| if (self.previous_pointer_position) |previous| !std.meta.eql(previous, current.position) else false else false;
                self.previous_pointer_position = if (pointer) |current| current.position else null;

                var moved_any = false;
                for ([_]Winner{ .map_zoom, .carousel, .list, .map_pan }) |winner| {
                    const motion = motions.get(winner) orelse continue;
                    if (!moved_any and !self.session.open) self.openSession(ui, shell, winner, motion, if (pointer_moved) pointer else null);
                    moved_any = true;
                    self.credit(winner);
                }
                if (moved_any) self.session.last_activity_seconds = shell.seconds;
                if (self.session.open) {
                    const idle = shell.seconds - self.session.last_activity_seconds;
                    if (idle > session_idle_seconds) {
                        self.session.open = false;
                    } else {
                        ui.requestFrameAt(ui.now().addSeconds(session_idle_seconds - idle + 0.01));
                    }
                }
            }

            fn openSession(self: *GestureArena, ui: *Ui, shell: *const Shell, winner: Winner, motion: [2]f32, dragging_pointer: ?zui.Pointer) void {
                self.session = .{ .open = true, .last_activity_seconds = shell.seconds };
                const pointer = dragging_pointer orelse return;
                const press_position: [2]f32 = .{ pointer.position[0] - motion[0], pointer.position[1] - motion[1] };
                self.session.pressed = true;
                self.session.kind = pointer.kind;
                self.session.target = targetAt(ui, press_position);
                self.session.axis = switch (winner) {
                    .carousel => .horizontal,
                    .list => .vertical,
                    .map_pan, .map_zoom => if (@abs(motion[0]) >= @abs(motion[1])) .horizontal else .vertical,
                };
            }

            fn credit(self: *GestureArena, winner: Winner) void {
                if (self.session.logged.contains(winner)) return;
                self.session.logged.insert(winner);
                const tone: Tone = switch (winner) {
                    .map_pan, .map_zoom => .map,
                    .list => .list,
                    .carousel => .carousel,
                };
                if (!self.session.pressed) {
                    self.log.add(tone, winner.title(), "No press held it: the wheel, or a fling coasting on, goes to the innermost region that scrolls that way with room.", "wheel or momentum", .{});
                    return;
                }
                var name: [16]u8 = undefined;
                const target = targetName(&name, self.session.target);
                if (winner == .map_zoom) {
                    self.log.add(tone, winner.title(), "Two pointers in a region that zooms: the map takes both, from whatever they pressed or panned.", "{s}, pressed on {s}", .{ kindName(self.session.kind), target });
                    return;
                }
                const predicted = predictedWinner(self.session.target, self.session.axis);
                var detail: [160]u8 = undefined;
                const reason = if (predicted == winner)
                    ruleReason(self.session.target, self.session.axis)
                else
                    std.fmt.bufPrint(&detail, "The {s} pans that way but was at its end, so the drag chained out to the {s} around it.", .{ winnerName(predicted), winnerName(winner) }) catch "";
                self.log.add(tone, winner.title(), reason, "{s}, pressed on {s}, moving {t}", .{ kindName(self.session.kind), target, self.session.axis });
            }

            fn handleClicks(self: *GestureArena, ui: *Ui, map_rect: zui.Rect) void {
                const map_middle: [2]f32 = .{ map_rect.x + map_rect.width / 2, map_rect.y + map_rect.height / 2 };
                if (ui.clicked(ids.zoom_in)) self.camera.zoomAbout(map_rect, map_middle, 1.25);
                if (ui.clicked(ids.zoom_out)) self.camera.zoomAbout(map_rect, map_middle, 0.8);
                for (0..list_rows.len) |index| {
                    if (!ui.clicked(rowId(index))) continue;
                    self.picked_row = @intCast(index);
                    self.logTap(.{ .row = @intCast(index) });
                }
                for (0..vessels.len) |index| {
                    if (ui.clicked(cardId(index))) self.logTap(.{ .card = @intCast(index) });
                }
                if (ui.clicked(ids.map)) self.logTap(.map);
            }

            fn logTap(self: *GestureArena, target: Target) void {
                var name: [16]u8 = undefined;
                var title: [64]u8 = undefined;
                self.log.add(.tap, std.fmt.bufPrint(&title, "A tap on {s}", .{targetName(&name, target)}) catch "A tap", "Released within the 8-unit slop, so nothing panned: what it pressed is clicked.", "tap", .{});
            }

            fn toolbar(self: *GestureArena, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                _ = shell.widgets.checkbox(ui, ids.lasso_tool, "Lasso tool", &self.lasso_tool, .{});
                if (shell.widgets.button(ui, ids.reset_view, "Reset view", .{})) {
                    self.camera = .{};
                    self.selected = .initEmpty();
                    self.lasso = .{};
                }
                shell.spacer(ui);
                shell.printColored(ui, .caption, colors.get(.on_surface_muted), "zoom {d:.0}%   list {d:.0}   carousel {d:.0}", .{ self.camera.zoom * 100, self.previous_list_offset[1], self.previous_carousel_offset[0] });
            }

            fn map(self: *GestureArena, ui: *Ui, shell: *const Shell, map_rect: zui.Rect) void {
                const colors = shell.colors;
                ui.open(.{
                    .id = ids.map,
                    .gestures = .{ .pan = .both, .zoom = true, .custom = self.lasso_tool },
                    .cursor = if (self.lasso_tool) .crosshair else .grab,
                    .layout = .{ .sizing = .grow_both },
                    .decoration = .{ .background = colors.get(.surface_sunken), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8) },
                    .clip = .both,
                });
                defer ui.close();
                self.grid(ui, colors, map_rect);
                self.pins(ui, shell, map_rect);
                self.listPanel(ui, shell, map_rect);
                self.lassoPath(ui, colors, map_rect);
                self.zoomButtons(ui, shell);
            }

            fn grid(self: *const GestureArena, ui: *Ui, colors: kit.Colors, map_rect: zui.Rect) void {
                const top_left = self.camera.toLocal(map_rect, .{ 0, 0 });
                const extent: [2]f32 = .{ world_size[0] * self.camera.zoom, world_size[1] * self.camera.zoom };
                ui.box(.{
                    .floating = .{ .offset = top_left, .capture = false, .clip = .target },
                    .layout = .{ .sizing = .{ .width = .fixed(extent[0]), .height = .fixed(extent[1]) } },
                    .decoration = .{ .background = colors.get(.background), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) } },
                });
                const columns: usize = @intFromFloat(world_size[0] / grid_spacing);
                for (1..columns) |column| ui.box(.{
                    .floating = .{ .offset = .{ top_left[0] + @as(f32, @floatFromInt(column * grid_spacing)) * self.camera.zoom, top_left[1] }, .capture = false, .clip = .target },
                    .layout = .{ .sizing = .{ .width = .fixed(1), .height = .fixed(extent[1]) } },
                    .decoration = .{ .background = colors.get(.outline_muted).mix(colors.get(.background), 0.5) },
                });
                const rows: usize = @intFromFloat(world_size[1] / grid_spacing);
                for (1..rows) |row| ui.box(.{
                    .floating = .{ .offset = .{ top_left[0], top_left[1] + @as(f32, @floatFromInt(row * grid_spacing)) * self.camera.zoom }, .capture = false, .clip = .target },
                    .layout = .{ .sizing = .{ .width = .fixed(extent[0]), .height = .fixed(1) } },
                    .decoration = .{ .background = colors.get(.outline_muted).mix(colors.get(.background), 0.5) },
                });
            }

            fn pins(self: *const GestureArena, ui: *Ui, shell: *const Shell, map_rect: zui.Rect) void {
                const colors = shell.colors;
                for (places, 0..) |place, index| {
                    const at = self.camera.toLocal(map_rect, place.position);
                    const selected = self.selected.isSet(index);
                    const diameter: f32 = if (selected) 14 else 10;
                    ui.box(.{
                        .floating = .{ .offset = .{ at[0] - diameter / 2, at[1] - diameter / 2 }, .capture = false, .clip = .target },
                        .layout = .{ .sizing = .{ .width = .fixed(diameter), .height = .fixed(diameter) } },
                        .decoration = .{ .background = if (selected) colors.get(.on_surface) else colors.get(.accent), .border = .{ .color = colors.get(.background), .widths = .all(2) }, .corner_radius = .all(diameter / 2) },
                    });
                    const label_style = shell.style(.tiny, if (selected) colors.get(.on_surface) else colors.get(.on_surface_muted));
                    const label_at: [2]f32 = .{ at[0] + 9, at[1] - 8 };
                    const label_size = ui.measureText(place.name, label_style);
                    const label_fits = label_at[0] >= 0 and label_at[1] >= 0 and label_at[0] + label_size[0] <= map_rect.width and label_at[1] + label_size[1] <= map_rect.height;
                    if (!label_fits) continue;
                    ui.open(.{ .floating = .{ .offset = label_at, .capture = false, .clip = .target } });
                    ui.text(place.name, label_style);
                    ui.close();
                }
            }

            fn listPanel(self: *GestureArena, ui: *Ui, shell: *const Shell, map_rect: zui.Rect) void {
                const colors = shell.colors;
                const at = self.camera.toLocal(map_rect, list_anchor);
                ui.open(.{
                    .id = ids.list,
                    .floating = .{ .offset = at, .z = 2, .clip = .target },
                    .gestures = .{ .pan = .vertical },
                    .scroll = .{},
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(list_size[0]), .height = .fixed(list_size[1]) }, .padding = .all(12), .child_gap = 6 },
                    .decoration = .{ .background = colors.get(.surface), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                shell.label(ui, .heading, "Inner harbor");
                shell.labelColored(ui, .tiny, colors.get(.on_surface_muted), "VESSELS DUE, A CAROUSEL");
                {
                    ui.open(.{
                        .id = ids.carousel,
                        .gestures = .{ .pan = .horizontal },
                        .scroll = .{ .horizontal = true, .vertical = false },
                        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(card_size[1]) }, .child_gap = card_gap },
                    });
                    defer ui.close();
                    for (vessels, 0..) |vessel, index| {
                        const id = cardId(index);
                        ui.open(.{
                            .id = id,
                            .interactive = true,
                            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(card_size[0]), .height = .fixed(card_size[1]) }, .padding = .all(10), .child_gap = 4 },
                            .decoration = .{ .background = if (ui.pressed(id)) colors.get(.secondary_container) else colors.get(.surface_raised), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(6) },
                        });
                        shell.labelColored(ui, .caption, colors.get(.on_surface), vessel[0]);
                        shell.labelColored(ui, .tiny, colors.get(.on_surface_muted), vessel[1]);
                        ui.close();
                    }
                }
                shell.labelColored(ui, .tiny, colors.get(.on_surface_muted), "BERTHS, A LIST");
                for (list_rows, 0..) |row, index| {
                    const id = rowId(index);
                    const picked = if (self.picked_row) |picked_row| picked_row == index else false;
                    ui.open(.{
                        .id = id,
                        .interactive = true,
                        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(30) }, .padding = .symmetric(10, 0), .child_alignment = .{ .y = .center } },
                        .decoration = .{ .background = if (picked) colors.get(.selection) else if (ui.pressed(id)) colors.get(.secondary_container) else colors.get(.surface_raised), .corner_radius = .all(4) },
                    });
                    shell.labelColored(ui, .caption, if (picked) colors.get(.on_selection) else colors.get(.on_surface), row);
                    ui.close();
                }
            }

            fn lassoPath(self: *const GestureArena, ui: *Ui, colors: kit.Colors, map_rect: zui.Rect) void {
                for (self.lasso.slice()) |point| ui.box(.{
                    .floating = .{ .offset = .{ point[0] - map_rect.x - 2, point[1] - map_rect.y - 2 }, .z = 3, .capture = false, .clip = .target },
                    .layout = .{ .sizing = .{ .width = .fixed(4), .height = .fixed(4) } },
                    .decoration = .{ .background = colors.get(.accent), .corner_radius = .all(2) },
                });
            }

            fn zoomButtons(self: *const GestureArena, ui: *Ui, shell: *const Shell) void {
                _ = self;
                ui.open(.{
                    .floating = .{ .anchor = .top_right, .attach_point = .top_right, .offset = .{ -12, 12 }, .z = 4, .clip = .target },
                    .layout = .{ .direction = .top_to_bottom, .child_gap = 6 },
                });
                defer ui.close();
                _ = shell.widgets.button(ui, ids.zoom_in, "+", .{ .width = .fixed(34), .variant = .secondary });
                _ = shell.widgets.button(ui, ids.zoom_out, "-", .{ .width = .fixed(34), .variant = .secondary });
            }

            fn logCard(self: *const GestureArena, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                shell.openScrollingCard(ui, ids.log, "", .{ .width = .fixed(340), .height = .grow });
                defer ui.close();
                shell.labelColored(ui, .caption, colors.get(.on_surface_accent), "WHO GOT EACH GESTURE, AND WHY");
                shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "Past the 8-unit slop a pointer's axis locks, and it goes to the innermost element under its press that pans that way and still has room. A second finger inside a region that zooms makes the pair zoom it.");
                shell.divider(ui);
                if (self.log.count == 0) {
                    shell.labelColored(ui, .body, colors.get(.on_surface_muted), "Drag the map, the list or the carousel, each both ways; pinch; tap a card; or turn on the lasso tool and draw around a few places.");
                    return;
                }
                for (0..self.log.count) |age| {
                    const entry = self.log.at(age);
                    const emphasis: kit.Emphasis = switch (entry.tone) {
                        .map => .accent,
                        .list => .success,
                        .carousel => .warning,
                        .lasso => .danger,
                        .tap => .neutral,
                    };
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 10 } });
                    defer ui.close();
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(3), .height = .grow } }, .decoration = .{ .background = if (age == 0) emphasis.fill(colors) else emphasis.fill(colors).mix(colors.get(.surface), 0.5), .corner_radius = .all(1.5) } });
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                    defer ui.close();
                    shell.labelColored(ui, .body, if (age == 0) emphasis.text(colors) else colors.get(.on_surface), entry.title());
                    shell.labelColored(ui, .caption, colors.get(.on_surface_muted), entry.detail());
                    shell.labelColored(ui, .tiny, colors.get(.on_surface_muted), entry.meta());
                }
                shell.printColored(ui, .tiny, colors.get(.on_surface_muted), "{d} decisions logged", .{self.log.total});
            }
        };
    };
}
