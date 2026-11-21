const std = @import("std");
const zui = @import("zui");
const DescribedViolation = @import("violation.zig").DescribedViolation;

pub const HostConformance = struct {
    /// Runs the suite's waker, which wakes the host from another thread.
    /// It must offer concurrency.
    io: std.Io,
    window: zui.WindowId = .main,
    /// A wait that should end at once may take this long, and an `.at`
    /// wait may end this long after its instant.
    prompt_ns: u64 = 500 * std.time.ns_per_ms,
    /// Events the harness posted may take this long to be polled.
    event_arrival_ns: u64 = 2 * std.time.ns_per_s,
    /// An `.on_event` wait still waiting after this has lost its wake. The
    /// suite then keeps waking the host until the wait ends, so that a host
    /// which loses only some wakes fails the suite instead of hanging it.
    lost_wake_ns: u64 = 5 * std.time.ns_per_s,
};

pub const HostError = error{
    WindowClosed,
    ZoomNotKept,
    NoViewport,
    SurfaceNotDeclared,
    OutputFormatNotDeclared,
    EventLost,
    ImmediateWaited,
    WakeNotSticky,
    WakeLost,
    WokeBeforeInstant,
    WaitedPastInstant,
    ClosedWindowPolled,
    SemanticsDropped,
    ActionLost,
    ServiceNotAnswered,
    ServiceAnsweredWrongly,
    UrlNotRefused,
    UrlNotOpened,
    SecondWindowNotOpened,
    WindowsShareSurface,
    EventReachedWrongWindow,
    WindowIdReused,
    ClosingOneClosedAnother,
    PollBlocked,
    StartedTwice,
    SteppedBeforeStart,
    ImmediateNotStepped,
    SteppedBeforeInstant,
    SteppedPastInstant,
    SurfaceLossNotReported,
    SurfaceNotGivenBack,
    NotStopped,
    SteppedAfterTheEnd,
};

/// What the user does when the suite calls a service the harness fakes.
pub const ServiceScript = struct {
    /// Chosen in the next file dialog, each followed by a 0 byte; empty cancels it.
    chosen_paths: []const u8 = "",
    /// Chosen in the next menu; null closes it.
    chosen_menu_item: ?zui.MenuItemId = null,
    notification: enum { activated, dismissed } = .activated,
};
pub const HostViolation = DescribedViolation(HostError);

const kept_zoom = 1.5;
const at_wait_ns = 30 * std.time.ns_per_ms;
const other_thread_wake_ns = 20 * std.time.ns_per_ms;

/// Runs a host through the loop's calls on its own, without a `Context`,
/// and fails on the first thing it did differently from the host contract:
/// - `zuiPoll` keeps the application's zoom, reports a viewport, and gives
///   back what the harness posted in the order it was posted;
/// - `zuiSurface` gives a kind its `zui_surfaces` names, in an output format
///   its `zui_output_formats` names;
/// - `zuiWait` returns at once for `.immediately`;
/// - a wake before an `.on_event` wait ends it at once, and is then
///   cleared, so the next `.at` wait lasts until its instant;
/// - a wake from another thread ends an `.on_event` wait;
/// - an `.at` wait ends at its instant, not before and not long after;
/// - `zuiApply` takes requests;
/// - with `zuiChromeRegions`, the host takes a title bar and a close button
///   from a buffer the suite then overwrites, and keeps polling: it must
///   keep a copy, not the slice;
/// - with `zuiSemantics` and a harness `invoke`, a button invoked through
///   the platform's accessibility API arrives as an `action` event naming
///   it;
/// - with `zuiClipboard`, text written is read back, answered once for its
///   request within `event_arrival_ns`; when the harness's
///   `platformOffersClipboard` says the platform has none, writing is
///   refused with `error.Unavailable` instead;
/// - with `zuiOpenUrl`, a path, a `file:` URL and a word are refused with
///   `error.InvalidUrl`, and with a harness `openedUrl`, a URL reaches the
///   system;
/// - with a harness `scriptServices`, a file dialog answers the paths the
///   user chose, or `.canceled`; a menu the item chosen; a notification
///   its activation; each naming its request and window;
/// - with `zui_capabilities.windows = .many`, a second window opens with
///   its own id, viewport and surface, an event posted to either window is
///   reported by that window alone, closing the second leaves the first
///   polling, and a window opened after it has a new id;
/// - when the harness can close the window, `zuiPoll` returns false after
///   it is closed.
///
/// Every wait the suite starts is bounded by `conformance`.
///
/// `harness` is a pointer to a value that declares:
/// - `fn host(self) *Host`;
/// - `fn post(self, event: zui.Event) bool`: make the OS report `event` to
///   the host, or return false when this host cannot report its kind, which
///   the suite then skips;
/// - optionally `fn invoke(self, label: []const u8) bool`: ask the
///   platform's accessibility API to invoke the element labelled `label`,
///   or return false when this host cannot, which the suite then skips. The
///   harness opens its window with room for at least one semantic node;
/// - optionally `fn openedUrl(self) ?[]const u8`: the last URL the host
///   handed to the system, which the harness fakes so no browser opens;
/// - optionally `fn platformOffersClipboard(self) bool`: false when the
///   platform the host runs on has no clipboard, as a headless compositor
///   may not; without it, the platform is taken to have one;
/// - optionally `fn scriptServices(self, script: zui_testing.ServiceScript)
///   void`: make the host's next dialog, menu or notification answer as the
///   script says, without showing anything;
/// - for a host with many windows, `fn postTo(self, window: zui.WindowId,
///   event: zui.Event) bool`, as `post` for that window;
/// - optionally `fn close(self) void`, closing the window as the user would.
///
/// ```zig
/// test "the raylib host conforms" {
///     var harness: RaylibHostHarness = try .init();
///     defer harness.deinit();
///     try zui_testing.expectHostConforms(zui_raylib.Host, &harness, .{ .io = std.testing.io });
/// }
/// ```
pub fn expectHostConforms(comptime Host: type, harness: anytype, conformance: HostConformance) !void {
    const violation = try findHostViolation(Host, harness, conformance) orelse return;
    std.debug.print("zui_testing.expectHostConforms: {s} {s}\n", .{ @typeName(Host), violation.description() });
    return violation.kind;
}

/// `expectHostConforms` without printing: the first violation, or null.
pub fn findHostViolation(comptime Host: type, harness: anytype, conformance: HostConformance) !?HostViolation {
    comptime zui.checkHost(Host);
    const Harness = @typeInfo(@TypeOf(harness)).pointer.child;
    const opens_many_windows = comptime @hasDecl(Host, "zui_capabilities") and Host.zui_capabilities.windows == .many;
    if (opens_many_windows and !@hasDecl(Harness, "postTo")) {
        @compileError("zui_testing: " ++ @typeName(Harness) ++ " tests a host with many windows, so it must declare `fn postTo(self, window: zui.WindowId, event: zui.Event) bool`");
    }
    const host: *Host = harness.host();
    const window = conformance.window;
    const io = conformance.io;

    var event_buffer: [64]zui.Event = undefined;
    var text_buffer: [64]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.params.zoom = kept_zoom;

    if (!host.zuiPoll(window, &builder)) return .init(error.WindowClosed, "closed its window before the first poll", .{});
    if (builder.params.zoom != kept_zoom) {
        return .init(error.ZoomNotKept, "replaced the application's zoom of {d} with {d}", .{ kept_zoom, builder.params.zoom });
    }
    const viewport = builder.params.viewport;
    if (!(viewport[0] > 0 and viewport[1] > 0)) return .init(error.NoViewport, "reported a viewport of {d} by {d}", .{ viewport[0], viewport[1] });
    const surface = host.zuiSurface(window);
    const surface_kind = std.meta.activeTag(surface);
    if (!Host.zui_surfaces.contains(surface_kind)) {
        return .init(error.SurfaceNotDeclared, "gave a .{t} surface, which its zui_surfaces does not name", .{surface_kind});
    }
    if (!zui.declaredOutputFormats(Host).contains(surface.outputFormat())) {
        return .init(error.OutputFormatNotDeclared, "gave a surface in .{t}, which its zui_output_formats does not name", .{surface.outputFormat()});
    }

    if (try expectPostedEvents(host, harness, &builder, conformance)) |violation| return violation;

    var started = now(io);
    host.zuiWait(.immediately);
    var waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited > conformance.prompt_ns) return .init(error.ImmediateWaited, "took {d} ms to return from an .immediately wait", .{milliseconds(waited)});

    host.zuiWaker().wake();
    started = now(io);
    try waitOnEvent(host, null, conformance);
    waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited > conformance.prompt_ns) {
        return .init(error.WakeNotSticky, "took {d} ms to end an .on_event wait woken before it began", .{milliseconds(waited)});
    }
    if (try expectWaitUntil(host, &builder, conformance, "after a wake the previous wait had taken")) |violation| return violation;

    started = now(io);
    try waitOnEvent(host, other_thread_wake_ns, conformance);
    waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited >= conformance.lost_wake_ns) {
        return .init(error.WakeLost, "took {d} ms to end an .on_event wait woken from another thread after {d} ms", .{ milliseconds(waited), milliseconds(other_thread_wake_ns) });
    }
    if (try expectWaitUntil(host, &builder, conformance, "")) |violation| return violation;

    host.zuiApply(window, .{ .cursor = .pointer });
    host.zuiApply(window, .{});
    if (@hasDecl(Host, "zuiChromeRegions")) {
        var regions = [_]zui.ChromeRegion{
            .{ .id = 1, .bounds = .{ .width = viewport[0], .height = 32 }, .kind = .title_bar },
            .{ .id = 2, .bounds = .{ .x = viewport[0] - 46, .width = 46, .height = 32 }, .kind = .close_button },
        };
        host.zuiChromeRegions(window, &regions);
        @memset(std.mem.sliceAsBytes(&regions), 0xaa);
        if (!host.zuiPoll(window, &builder)) return .init(error.WindowClosed, "closed its window after it was handed chrome regions", .{});
    }
    if (@hasDecl(Host, "zuiSemantics") and @hasDecl(Harness, "invoke")) {
        if (try expectInvokedAction(host, harness, &builder, conformance)) |violation| return violation;
    }
    if (expectServicesAnswer(Host, host, harness, conformance)) |violation| return violation;
    if (opens_many_windows) {
        if (try expectWindowsKeptApart(host, harness, &builder, conformance)) |violation| return violation;
    }
    if (@hasDecl(Harness, "close")) {
        harness.close();
        if (host.zuiPoll(window, &builder)) return .init(error.ClosedWindowPolled, "polled true after its window was closed", .{});
    }
    return null;
}

pub fn now(io: std.Io) zui.Instant {
    return .fromTimestamp(std.Io.Timestamp.now(io, .awake));
}

pub fn milliseconds(nanoseconds: u64) u64 {
    return nanoseconds / std.time.ns_per_ms;
}

/// Posts a click, a key, typed text and a move, then polls until each
/// event the harness could post has arrived after the one before it.
pub fn expectPostedEvents(host: anytype, harness: anytype, builder: *zui.RecordBuilder, conformance: HostConformance) !?HostViolation {
    const at = builder.params.now;
    const press: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 10, 10 }, .at = at };
    const moved: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 20, 30 }, .at = at };
    const candidates = [_]zui.Event{
        .{ .pointer_move = .{ .pointer = press } },
        .{ .pointer_down = .{ .pointer = press } },
        .{ .pointer_up = .{ .pointer = press } },
        .{ .key_down = .{ .key = .s, .at = at } },
        .{ .key_up = .{ .key = .s, .at = at } },
        .{ .text = "ok" },
        .{ .pointer_move = .{ .pointer = moved } },
    };
    var posted: [candidates.len]zui.Event = undefined;
    var posted_count: usize = 0;
    for (candidates) |event| {
        if (!harness.post(event)) continue;
        posted[posted_count] = event;
        posted_count += 1;
    }

    var arrived: usize = 0;
    const started = now(conformance.io);
    while (arrived < posted_count) {
        if (@hasDecl(@TypeOf(host.*), "zuiWait")) host.zuiWait(.immediately);
        if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window while the suite polled for events", .{});
        for (builder.events()) |event| {
            if (arrived < posted_count and sameEvent(event, posted[arrived])) arrived += 1;
        }
        if (now(conformance.io).nanoseconds -| started.nanoseconds > conformance.event_arrival_ns) break;
    }
    if (arrived == posted_count) return null;
    return .init(error.EventLost, "reported the posted {t} (event {d} of {d}) out of order or not at all", .{
        std.meta.activeTag(posted[arrived]), arrived + 1, posted_count,
    });
}

/// Opens a second window, posts a key to the first and a move to the
/// second, and expects each in its own window only; then closes it, and
/// opens and closes a third.
fn expectWindowsKeptApart(host: anytype, harness: anytype, builder: *zui.RecordBuilder, conformance: HostConformance) !?HostViolation {
    const first = conformance.window;
    const second_options: zui.WindowOptions = .{ .title = "zui host suite, second window", .size = .{ 320, 240 }, .visible = false };
    const second = host.zuiOpenWindow(second_options) catch |err| return .init(error.SecondWindowNotOpened, "could not open a second window: {t}", .{err});
    var second_events: [64]zui.Event = undefined;
    var second_text: [64]u8 = undefined;
    var second_builder: zui.RecordBuilder = .init(&second_events, &second_text);
    if (second == first) return .init(error.WindowIdReused, "gave its second window the first one's id, {d}", .{@intFromEnum(second)});
    if (!host.zuiPoll(second, &second_builder)) return .init(error.SecondWindowNotOpened, "polled its second window false as soon as it opened", .{});
    const viewport = second_builder.params.viewport;
    if (!(viewport[0] > 0 and viewport[1] > 0)) return .init(error.NoViewport, "reported a viewport of {d} by {d} for its second window", .{ viewport[0], viewport[1] });
    if (std.meta.eql(host.zuiSurface(first), host.zuiSurface(second))) return .init(error.WindowsShareSurface, "gave both windows the same surface", .{});

    const at = second_builder.params.now;
    const moved_in_second: zui.Event = .{ .pointer_move = .{ .pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 15, 25 }, .at = at } } };
    const key_in_first: zui.Event = .{ .key_down = .{ .key = .k, .at = at } };
    const posted = [2]bool{ harness.postTo(first, key_in_first), harness.postTo(second, moved_in_second) };
    var arrived = [2]bool{ false, false };
    const started = now(conformance.io);
    while (!std.meta.eql(arrived, posted) and now(conformance.io).nanoseconds -| started.nanoseconds <= conformance.event_arrival_ns) {
        host.zuiWait(.immediately);
        if (!host.zuiPoll(first, builder)) return .init(error.WindowClosed, "closed its first window while the suite polled both", .{});
        if (!host.zuiPoll(second, &second_builder)) return .init(error.WindowClosed, "closed its second window while the suite polled both", .{});
        for (builder.events()) |event| {
            if (sameEvent(event, moved_in_second)) return .init(error.EventReachedWrongWindow, "reported a move posted to its second window in the first", .{});
            if (sameEvent(event, key_in_first)) arrived[0] = true;
        }
        for (second_builder.events()) |event| {
            if (sameEvent(event, key_in_first)) return .init(error.EventReachedWrongWindow, "reported a key posted to its first window in the second", .{});
            if (sameEvent(event, moved_in_second)) arrived[1] = true;
        }
    }
    for (posted, arrived, [_][]const u8{ "key posted to its first", "move posted to its second" }) |was_posted, did_arrive, what| {
        if (was_posted and !did_arrive) return .init(error.EventLost, "did not report the {s} window within {d} ms", .{ what, milliseconds(conformance.event_arrival_ns) });
    }

    host.zuiCloseWindow(second);
    if (host.zuiPoll(second, &second_builder)) return .init(error.ClosedWindowPolled, "polled its second window true after closing it", .{});
    if (!host.zuiPoll(first, builder)) return .init(error.ClosingOneClosedAnother, "closed its first window when it closed the second", .{});
    const third = host.zuiOpenWindow(second_options) catch |err| return .init(error.SecondWindowNotOpened, "could not open a window after closing one: {t}", .{err});
    defer host.zuiCloseWindow(third);
    if (third == second or third == first) return .init(error.WindowIdReused, "gave a new window the id {d}, which an earlier window had", .{@intFromEnum(third)});
    return null;
}

/// Both halves of the id are non-zero, so a host that keeps only one fails.
const invoked_button: zui.SemanticNode = .{
    .id = 0x8000_0001_0000_0002,
    .parent = null,
    .role = .button,
    .label = "Save",
    .value = .none,
    .bounds = .{ .x = 8, .y = 8, .width = 80, .height = 24 },
    .state = .{},
    .actions = .initOne(.invoke),
};

fn expectInvokedAction(host: anytype, harness: anytype, builder: *zui.RecordBuilder, conformance: HostConformance) !?HostViolation {
    const dropped = host.zuiSemantics(conformance.window, &.{invoked_button});
    if (dropped.nodes != 0) return .init(error.SemanticsDropped, "dropped {d} of 1 semantic nodes", .{dropped.nodes});
    if (!harness.invoke(invoked_button.label)) return null;
    const started = now(conformance.io);
    while (now(conformance.io).nanoseconds -| started.nanoseconds <= conformance.event_arrival_ns) {
        host.zuiWait(.immediately);
        if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window while the suite polled for an action", .{});
        for (builder.events()) |event| {
            if (event == .action and event.action.target == invoked_button.id and event.action.action == .invoke) return null;
        }
    }
    return .init(error.ActionLost, "did not report the invoke an assistive technology asked for within {d} ms", .{milliseconds(conformance.event_arrival_ns)});
}

const SuiteReply = zui.ServiceReply(256);

/// Takes one answer at a time, as a host never publishes from two threads
/// at once.
const SuiteReplies = struct {
    replies: [4]SuiteReply = undefined,
    published: std.atomic.Value(u32) = .init(0),

    pub fn publish(self: *SuiteReplies, reply: SuiteReply) error{Full}!zui.Wake {
        const count = self.published.load(.monotonic);
        if (count == self.replies.len) return error.Full;
        self.replies[count] = reply;
        self.published.store(count + 1, .release);
        return if (count == 0) .needed else .already_pending;
    }
};

const reply_poll_ns = 5 * std.time.ns_per_ms;
const copied_text = "zui \u{2713} clipboard";
const refused_urls = [_][]const u8{ "C:\\Windows\\notepad.exe", "file:///C:/Windows/notepad.exe", "notepad" };
const opened_url = "https://ziglang.org/";

fn expectServicesAnswer(comptime Host: type, host: *Host, harness: anytype, conformance: HostConformance) ?HostViolation {
    const Harness = @typeInfo(@TypeOf(harness)).pointer.child;
    const window = conformance.window;
    const platform_offers_clipboard = !@hasDecl(Harness, "platformOffersClipboard") or harness.platformOffersClipboard();
    if (@hasDecl(Host, "zuiClipboard") and !platform_offers_clipboard) {
        if (Host.zuiClipboard.write(host, copied_text)) |_| {
            return .init(error.ServiceAnsweredWrongly, "copied text to a clipboard its platform does not offer, rather than refusing with Unavailable", .{});
        } else |err| if (err != error.Unavailable) {
            return .init(error.ServiceAnsweredWrongly, "refused to copy text to a clipboard its platform does not offer with {t}, not Unavailable", .{err});
        }
    } else if (@hasDecl(Host, "zuiClipboard")) {
        Host.zuiClipboard.write(host, copied_text) catch |err| return .init(error.ServiceAnsweredWrongly, "refused to copy text to the clipboard: {t}", .{err});
        var replies: SuiteReplies = .{};
        const paste: zui.ServiceRequest = .of("suite paste");
        Host.zuiClipboard.read(host, paste, .of(&replies)) catch |err| return .init(error.ServiceAnsweredWrongly, "refused to read the clipboard: {t}", .{err});
        const reply = awaitReply(host, &replies, conformance) orelse return notAnswered("the clipboard read", conformance);
        if (wrongRequest(reply, paste, .main, "the clipboard read")) |violation| return violation;
        if (reply.kind != .clipboard_text or !std.mem.eql(u8, reply.text(), copied_text)) {
            return .init(error.ServiceAnsweredWrongly, "answered the clipboard read with .{t} \"{s}\", not the text it was given", .{ reply.kind, reply.text() });
        }
    }
    if (@hasDecl(Host, "zuiOpenUrl")) {
        for (refused_urls) |not_a_url| {
            if (Host.zuiOpenUrl.open(host, not_a_url)) |_| {
                return .init(error.UrlNotRefused, "handed \"{s}\" to the system rather than refusing it", .{not_a_url});
            } else |err| if (err != error.InvalidUrl) {
                return .init(error.UrlNotRefused, "refused \"{s}\" with error.{t}, not error.InvalidUrl", .{ not_a_url, err });
            }
        }
        if (@hasDecl(Harness, "openedUrl")) {
            Host.zuiOpenUrl.open(host, opened_url) catch |err| return .init(error.UrlNotOpened, "refused to open {s}: {t}", .{ opened_url, err });
            const deadline = now(conformance.io).addNanoseconds(conformance.event_arrival_ns);
            while (!std.mem.eql(u8, harness.openedUrl() orelse "", opened_url)) {
                if (!now(conformance.io).isBefore(deadline)) return .init(error.UrlNotOpened, "did not hand {s} to the system within {d} ms", .{ opened_url, milliseconds(conformance.event_arrival_ns) });
                host.zuiWait(.{ .at = now(conformance.io).addNanoseconds(reply_poll_ns) });
            }
        }
    }
    if (!@hasDecl(Harness, "scriptServices")) return null;
    if (@hasDecl(Host, "zuiFileDialogs")) {
        const dialog: zui.FileDialog = .{ .kind = .open_files, .title = "Open themes", .filters = &.{.{ .name = "Themes", .extensions = &.{"zon"} }} };
        for ([_][]const u8{ "zui/a.zon\x00zui/b.zon\x00", "" }) |chosen_paths| {
            harness.scriptServices(.{ .chosen_paths = chosen_paths });
            var replies: SuiteReplies = .{};
            const open: zui.ServiceRequest = .of("suite open");
            Host.zuiFileDialogs.show(host, window, open, dialog, .of(&replies)) catch |err| return .init(error.ServiceAnsweredWrongly, "refused to show a file dialog: {t}", .{err});
            const reply = awaitReply(host, &replies, conformance) orelse return notAnswered("the file dialog", conformance);
            if (wrongRequest(reply, open, window, "the file dialog")) |violation| return violation;
            const expected: SuiteReply.Kind = if (chosen_paths.len == 0) .canceled else .files_chosen;
            if (reply.kind != expected or !std.mem.eql(u8, reply.bytes[0..reply.len], chosen_paths)) {
                return .init(error.ServiceAnsweredWrongly, "answered a file dialog with .{t}, not .{t} with the paths chosen", .{ reply.kind, expected });
            }
        }
    }
    if (@hasDecl(Host, "zuiMenus")) {
        const chosen: zui.MenuItemId = @enumFromInt(7);
        harness.scriptServices(.{ .chosen_menu_item = chosen });
        var replies: SuiteReplies = .{};
        const edit: zui.ServiceRequest = .of("suite menu");
        const items = [_]zui.MenuItem{ .{ .id = @enumFromInt(6), .label = "Cut" }, .separator, .{ .id = chosen, .label = "Paste" } };
        Host.zuiMenus.popup(host, window, edit, &items, .{ 10, 10 }, .of(&replies)) catch |err| return .init(error.ServiceAnsweredWrongly, "refused to show a menu: {t}", .{err});
        const reply = awaitReply(host, &replies, conformance) orelse return notAnswered("the menu", conformance);
        if (wrongRequest(reply, edit, window, "the menu")) |violation| return violation;
        if (reply.kind != .menu_item_chosen or reply.menu_item != chosen) {
            return .init(error.ServiceAnsweredWrongly, "answered a menu with .{t} item {d}, not the item chosen, {d}", .{ reply.kind, @intFromEnum(reply.menu_item), @intFromEnum(chosen) });
        }
    }
    if (@hasDecl(Host, "zuiNotifications")) {
        harness.scriptServices(.{ .notification = .activated });
        var replies: SuiteReplies = .{};
        const saved: zui.ServiceRequest = .of("suite notification");
        Host.zuiNotifications.show(host, saved, .{ .title = "Saved", .body = "zui's host suite" }, .of(&replies)) catch |err| return .init(error.ServiceAnsweredWrongly, "refused to show a notification: {t}", .{err});
        const reply = awaitReply(host, &replies, conformance) orelse return notAnswered("the notification", conformance);
        if (wrongRequest(reply, saved, .main, "the notification")) |violation| return violation;
        if (reply.kind != .notification_activated) return .init(error.ServiceAnsweredWrongly, "answered a notification the user clicked with .{t}", .{reply.kind});
    }
    return null;
}

/// The first answer, waiting on the host meanwhile, so a host whose answers
/// arrive while it waits can publish them.
fn awaitReply(host: anytype, replies: *SuiteReplies, conformance: HostConformance) ?*const SuiteReply {
    const deadline = now(conformance.io).addNanoseconds(conformance.event_arrival_ns);
    while (replies.published.load(.acquire) == 0) {
        if (!now(conformance.io).isBefore(deadline)) return null;
        host.zuiWait(.{ .at = now(conformance.io).addNanoseconds(reply_poll_ns) });
    }
    return &replies.replies[0];
}

fn notAnswered(comptime service: []const u8, conformance: HostConformance) HostViolation {
    return .init(error.ServiceNotAnswered, "did not answer " ++ service ++ " within {d} ms", .{milliseconds(conformance.event_arrival_ns)});
}

fn wrongRequest(reply: *const SuiteReply, request: zui.ServiceRequest, window: zui.WindowId, comptime service: []const u8) ?HostViolation {
    if (reply.request != request) return .init(error.ServiceAnsweredWrongly, "answered " ++ service ++ " naming request {d}, not {d}", .{ @intFromEnum(reply.request), @intFromEnum(request) });
    if (reply.window != window) return .init(error.ServiceAnsweredWrongly, "answered " ++ service ++ " naming window {d}, not {d}", .{ @intFromEnum(reply.window), @intFromEnum(window) });
    return null;
}

fn sameEvent(event: zui.Event, posted: zui.Event) bool {
    if (std.meta.activeTag(event) != std.meta.activeTag(posted)) return false;
    return switch (posted) {
        .pointer_down => |press| samePress(press, event.pointer_down),
        .pointer_up => |release| samePress(release, event.pointer_up),
        .pointer_move => |move| std.meta.eql(move.pointer.position, event.pointer_move.pointer.position),
        .key_down => |key| key.key == event.key_down.key,
        .key_up => |key| key.key == event.key_up.key,
        .text => |text| std.mem.eql(u8, text, event.text),
        else => unreachable,
    };
}

fn samePress(posted: zui.PointerButton, polled: zui.PointerButton) bool {
    return posted.button == polled.button and std.meta.eql(posted.pointer.position, polled.pointer.position);
}

/// An `.at` wait 30 ms from the host's own clock: it may not end before
/// its instant, which a wake left over from an earlier wait would do.
fn expectWaitUntil(host: anytype, builder: *zui.RecordBuilder, conformance: HostConformance, comptime context: []const u8) !?HostViolation {
    if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window before an .at wait", .{});
    const instant = builder.params.now.addNanoseconds(at_wait_ns);
    host.zuiWait(.{ .at = instant });
    if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window during an .at wait", .{});
    const ended = builder.params.now;
    const separator = if (context.len == 0) "" else ", ";
    if (ended.isBefore(instant)) {
        return .init(error.WokeBeforeInstant, "returned from an .at wait {d} ms before its instant" ++ separator ++ context, .{milliseconds(instant.nanoseconds - ended.nanoseconds)});
    }
    if (ended.nanoseconds - instant.nanoseconds > conformance.prompt_ns) {
        return .init(error.WaitedPastInstant, "returned from an .at wait {d} ms after its instant" ++ separator ++ context, .{milliseconds(ended.nanoseconds - instant.nanoseconds)});
    }
    return null;
}

/// An `.on_event` wait, with another thread waking the host after
/// `wake_after_ns` when it is set, and again every 50 ms from
/// `lost_wake_ns` on, until the wait ends.
fn waitOnEvent(host: anytype, wake_after_ns: ?u64, conformance: HostConformance) !void {
    var waker: OtherThreadWaker = .{ .waker = host.zuiWaker(), .io = conformance.io, .wake_after_ns = wake_after_ns, .rescue_after_ns = conformance.lost_wake_ns };
    var group: std.Io.Group = .init;
    try group.concurrent(conformance.io, OtherThreadWaker.run, .{&waker});
    host.zuiWait(.on_event);
    waker.wait_ended.store(true, .release);
    group.await(conformance.io) catch {};
}

const OtherThreadWaker = struct {
    waker: zui.Waker,
    io: std.Io,
    wake_after_ns: ?u64,
    rescue_after_ns: u64,
    wait_ended: std.atomic.Value(bool) = .init(false),

    const rescue_interval_ns = 50 * std.time.ns_per_ms;
    const poll_interval_ns = 2 * std.time.ns_per_ms;

    fn run(self: *OtherThreadWaker) void {
        const started = now(self.io);
        if (self.wake_after_ns) |delay| {
            if (!self.sleepUntil(started.addNanoseconds(delay))) return;
            self.waker.wake();
        }
        if (!self.sleepUntil(started.addNanoseconds(self.rescue_after_ns))) return;
        while (!self.wait_ended.load(.acquire)) {
            self.waker.wake();
            self.io.sleep(.fromNanoseconds(rescue_interval_ns), .awake) catch return;
        }
    }

    /// False when the wait ended first.
    fn sleepUntil(self: *OtherThreadWaker, instant: zui.Instant) bool {
        while (now(self.io).isBefore(instant)) {
            if (self.wait_ended.load(.acquire)) return false;
            self.io.sleep(.fromNanoseconds(poll_interval_ns), .awake) catch return false;
        }
        return !self.wait_ended.load(.acquire);
    }
};

/// A mistake `QueueHost` makes, which the suite must catch.
const QueueHostFlaw = enum {
    none,
    /// A wake that arrives before a wait is lost.
    clears_wake_before_waiting,
    gives_undeclared_hdr_surface,
    /// Its accessibility bridge keeps nothing, so an invoke names no element.
    drops_actions,
    /// Its clipboard answers a read naming the next request.
    answers_another_request,
    /// Its URL opener hands anything to the system.
    opens_paths,
    /// It copies text when its platform offers no clipboard.
    copies_without_clipboard,
};

/// Reports what its harness posts, and waits on an `Io.Event` for the
/// awake clock.
fn QueueHost(comptime flaw: QueueHostFlaw) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

        io: std.Io,
        woken: std.Io.Event = .unset,
        queued: [16]zui.Event = undefined,
        queued_count: usize = 0,
        window_open: bool = true,
        applied: zui.HostRequests = .{},
        bridged: [4]zui.SemanticNode = undefined,
        bridged_count: usize = 0,
        copied: [64]u8 = undefined,
        copied_len: usize = 0,
        opened_url: ?[]const u8 = null,
        script: ServiceScript = .{},
        platform_offers_clipboard: bool = true,

        const longest_wait_ns = 10 * std.time.ns_per_s;

        pub const zuiClipboard = struct {
            pub fn write(self: *Self, text: []const u8) zui.ServiceError!void {
                if (!self.platform_offers_clipboard and flaw != .copies_without_clipboard) return error.Unavailable;
                if (text.len > self.copied.len) return error.TooLarge;
                @memcpy(self.copied[0..text.len], text);
                self.copied_len = text.len;
            }

            pub fn read(self: *Self, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
                const answered: zui.ServiceRequest = if (flaw == .answers_another_request) @enumFromInt(@intFromEnum(request) +% 1) else request;
                self.answer(sink, .{ .request = answered, .outcome = .{ .clipboard_text = self.copied[0..self.copied_len] } });
            }
        };

        pub const zuiOpenUrl = struct {
            pub fn open(self: *Self, url: []const u8) zui.ServiceError!void {
                if (flaw != .opens_paths and !zui.isOpenableUrl(url)) return error.InvalidUrl;
                self.opened_url = url;
            }
        };

        pub const zuiFileDialogs = struct {
            pub fn show(self: *Self, window: zui.WindowId, request: zui.ServiceRequest, _: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
                const chosen = self.script.chosen_paths;
                self.answer(sink, .{ .request = request, .window = window, .outcome = if (chosen.len == 0) .canceled else .{ .files_chosen = chosen } });
            }
        };

        pub const zuiMenus = struct {
            pub fn popup(self: *Self, window: zui.WindowId, request: zui.ServiceRequest, _: []const zui.MenuItem, _: [2]f32, sink: zui.ServiceSink) zui.ServiceError!void {
                const chosen = self.script.chosen_menu_item;
                self.answer(sink, .{ .request = request, .window = window, .outcome = if (chosen) |item| .{ .menu_item_chosen = item } else .canceled });
            }
        };

        pub const zuiNotifications = struct {
            pub fn show(self: *Self, request: zui.ServiceRequest, _: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
                self.answer(sink, .{ .request = request, .outcome = switch (self.script.notification) {
                    .activated => .notification_activated,
                    .dismissed => .notification_dismissed,
                } });
            }
        };

        fn answer(self: *Self, sink: zui.ServiceSink, answered: zui.ServiceAnswer) void {
            self.zuiWaker().wakeIf(sink.publish(&answered));
        }

        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            if (!self.window_open) return false;
            record.begin(.{ .now = now(self.io), .viewport = .{ 800, 600 }, .scale = 2 });
            for (self.queued[0..self.queued_count]) |event| switch (event) {
                .text => |text| record.appendText(text),
                else => record.append(event),
            };
            self.queued_count = 0;
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        pub fn zuiWait(self: *Self, next: zui.NextFrame) void {
            if (flaw == .clears_wake_before_waiting) self.woken.reset();
            const deadline: zui.Instant = switch (next) {
                .immediately => now(self.io),
                .at => |instant| instant,
                .on_event => now(self.io).addNanoseconds(longest_wait_ns),
            };
            const awake_deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake };
            while (!self.woken.isSet() and now(self.io).isBefore(deadline)) {
                self.woken.waitTimeout(self.io, .{ .deadline = awake_deadline }) catch {};
            }
            self.woken.reset();
        }

        pub fn zuiSurface(_: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            const format: zui.OutputFormat = if (flaw == .gives_undeclared_hdr_surface) .scrgb_fp16 else .sdr;
            return .{ .offscreen = .{ .size = .{ 1600, 1200 }, .format = format } };
        }

        pub fn zuiApply(self: *Self, window: zui.WindowId, requests: zui.HostRequests) void {
            std.debug.assert(window == .main);
            self.applied = requests;
        }

        pub fn zuiSemantics(self: *Self, window: zui.WindowId, nodes: []const zui.SemanticNode) zui.SemanticsDropped {
            std.debug.assert(window == .main);
            if (flaw == .drops_actions) return .{};
            const kept = @min(nodes.len, self.bridged.len);
            @memcpy(self.bridged[0..kept], nodes[0..kept]);
            self.bridged_count = kept;
            return .{ .nodes = @intCast(nodes.len - kept) };
        }

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.woken.set(self.io);
        }
    };
}

fn QueueHostHarness(comptime Host: type) type {
    return struct {
        const Self = @This();

        queue_host: Host,

        pub fn host(self: *Self) *Host {
            return &self.queue_host;
        }

        pub fn post(self: *Self, event: zui.Event) bool {
            if (event == .key_up) return false;
            self.queue_host.queued[self.queue_host.queued_count] = event;
            self.queue_host.queued_count += 1;
            return true;
        }

        /// As an assistive technology finds an element: by its label, in
        /// what the bridge kept.
        pub fn invoke(self: *Self, label: []const u8) bool {
            const queue_host = &self.queue_host;
            for (queue_host.bridged[0..queue_host.bridged_count]) |node| {
                if (!std.mem.eql(u8, node.label, label)) continue;
                queue_host.queued[queue_host.queued_count] = .{ .action = .{ .target = node.id, .action = .invoke } };
                queue_host.queued_count += 1;
            }
            return true;
        }

        pub fn openedUrl(self: *Self) ?[]const u8 {
            return self.queue_host.opened_url;
        }

        pub fn platformOffersClipboard(self: *Self) bool {
            return self.queue_host.platform_offers_clipboard;
        }

        pub fn scriptServices(self: *Self, script: ServiceScript) void {
            self.queue_host.script = script;
        }

        pub fn close(self: *Self) void {
            self.queue_host.window_open = false;
        }
    };
}

/// A mistake `WindowsQueueHost` makes, which the suite must catch.
const WindowsQueueHostFlaw = enum {
    none,
    routes_every_event_to_main,
    reuses_closed_ids,
};

/// `QueueHost`'s polls and waits over four windows, each with its own
/// queue and surface.
fn WindowsQueueHost(comptime flaw: WindowsQueueHostFlaw) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many };

        const Window = struct {
            id: zui.WindowId = .main,
            open: bool = false,
            queued: [8]zui.Event = undefined,
            queued_count: usize = 0,
        };

        io: std.Io,
        woken: std.Io.Event = .unset,
        windows: [4]Window = .{ .{ .open = true }, .{}, .{}, .{} },
        next_id: u32 = 1,

        pub fn zuiOpenWindow(self: *Self, _: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
            const window = for (&self.windows) |*window| {
                if (!window.open) break window;
            } else return error.TooManyWindows;
            const id: zui.WindowId = @enumFromInt(self.next_id);
            if (flaw != .reuses_closed_ids) self.next_id += 1;
            window.* = .{ .id = id, .open = true };
            return id;
        }

        pub fn zuiCloseWindow(self: *Self, id: zui.WindowId) void {
            if (self.find(id)) |window| window.open = false;
        }

        fn find(self: *Self, id: zui.WindowId) ?*Window {
            for (&self.windows) |*window| if (window.open and window.id == id) return window;
            return null;
        }

        fn queue(self: *Self, id: zui.WindowId, event: zui.Event) bool {
            const window = self.find(if (flaw == .routes_every_event_to_main) .main else id) orelse return false;
            window.queued[window.queued_count] = event;
            window.queued_count += 1;
            return true;
        }

        pub fn zuiPoll(self: *Self, id: zui.WindowId, record: *zui.RecordBuilder) bool {
            const window = self.find(id) orelse return false;
            record.begin(.{ .now = now(self.io), .viewport = .{ 800, 600 }, .scale = 2 });
            for (window.queued[0..window.queued_count]) |event| switch (event) {
                .text => |text| record.appendText(text),
                else => record.append(event),
            };
            window.queued_count = 0;
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        pub fn zuiWait(self: *Self, next: zui.NextFrame) void {
            const deadline: zui.Instant = switch (next) {
                .immediately => now(self.io),
                .at => |instant| instant,
                .on_event => now(self.io).addNanoseconds(10 * std.time.ns_per_s),
            };
            const awake_deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake };
            while (!self.woken.isSet() and now(self.io).isBefore(deadline)) {
                self.woken.waitTimeout(self.io, .{ .deadline = awake_deadline }) catch {};
            }
            self.woken.reset();
        }

        pub fn zuiSurface(_: *Self, id: zui.WindowId) zui.Surface {
            return .{ .offscreen = .{ .size = .{ 100 + @intFromEnum(id), 100 } } };
        }

        pub fn zuiApply(_: *Self, _: zui.WindowId, _: zui.HostRequests) void {}

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.woken.set(self.io);
        }
    };
}

fn WindowsQueueHostHarness(comptime Host: type) type {
    return struct {
        const Self = @This();

        windows_host: Host,

        pub fn host(self: *Self) *Host {
            return &self.windows_host;
        }

        pub fn post(self: *Self, event: zui.Event) bool {
            return self.windows_host.queue(.main, event);
        }

        pub fn postTo(self: *Self, window: zui.WindowId, event: zui.Event) bool {
            return self.windows_host.queue(window, event);
        }

        pub fn close(self: *Self) void {
            self.windows_host.zuiCloseWindow(.main);
        }
    };
}

test "a host with many windows that keeps each apart passes the suite" {
    const Host = WindowsQueueHost(.none);
    var harness: WindowsQueueHostHarness(Host) = .{ .windows_host = .{ .io = std.testing.io } };
    try expectHostConforms(Host, &harness, .{ .io = std.testing.io });
}

test "a host that reports every window's events in the first fails the suite" {
    const Host = WindowsQueueHost(.routes_every_event_to_main);
    var harness: WindowsQueueHostHarness(Host) = .{ .windows_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.EventReachedWrongWindow, violation.kind);
    try std.testing.expectEqualStrings("reported a move posted to its second window in the first", violation.description());
}

test "a host that gives a closed window's id to a new one fails the suite" {
    const Host = WindowsQueueHost(.reuses_closed_ids);
    var harness: WindowsQueueHostHarness(Host) = .{ .windows_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WindowIdReused, violation.kind);
    try std.testing.expectEqualStrings("gave a new window the id 1, which an earlier window had", violation.description());
}

test "a host that keeps the contract passes the suite" {
    var harness: QueueHostHarness(QueueHost(.none)) = .{ .queue_host = .{ .io = std.testing.io } };
    try expectHostConforms(QueueHost(.none), &harness, .{ .io = std.testing.io });
    try std.testing.expectEqual(zui.Cursor.default, harness.queue_host.applied.cursor);
    try std.testing.expectEqual(@as(usize, 1), harness.queue_host.bridged_count);
}

test "a host that clears a wake before waiting fails the suite" {
    var harness: QueueHostHarness(QueueHost(.clears_wake_before_waiting)) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(QueueHost(.clears_wake_before_waiting), &harness, .{ .io = std.testing.io, .prompt_ns = 100 * std.time.ns_per_ms, .lost_wake_ns = 300 * std.time.ns_per_ms })).?;
    try std.testing.expectEqual(error.WakeNotSticky, violation.kind);
    try std.testing.expect(std.mem.startsWith(u8, violation.description(), "took "));
    try std.testing.expect(std.mem.endsWith(u8, violation.description(), " ms to end an .on_event wait woken before it began"));
}

test "a host that gives a surface in an output format it does not declare fails the suite" {
    const Host = QueueHost(.gives_undeclared_hdr_surface);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.OutputFormatNotDeclared, violation.kind);
    try std.testing.expectEqualStrings("gave a surface in .scrgb_fp16, which its zui_output_formats does not name", violation.description());
}

test "a host whose accessibility bridge loses what it is handed fails the suite" {
    const Host = QueueHost(.drops_actions);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io, .event_arrival_ns = 50 * std.time.ns_per_ms })).?;
    try std.testing.expectEqual(error.ActionLost, violation.kind);
    try std.testing.expectEqualStrings("did not report the invoke an assistive technology asked for within 50 ms", violation.description());
}

test "a host whose service answers another request fails the suite" {
    const Host = QueueHost(.answers_another_request);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.ServiceAnsweredWrongly, violation.kind);
    try std.testing.expect(std.mem.startsWith(u8, violation.description(), "answered the clipboard read naming request "));
}

test "a host whose platform offers no clipboard passes the suite by refusing to copy with Unavailable" {
    const Host = QueueHost(.none);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io, .platform_offers_clipboard = false } };
    try expectHostConforms(Host, &harness, .{ .io = std.testing.io });
}

test "a host that copies text when its platform offers no clipboard fails the suite" {
    const Host = QueueHost(.copies_without_clipboard);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io, .platform_offers_clipboard = false } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.ServiceAnsweredWrongly, violation.kind);
    try std.testing.expectEqualStrings("copied text to a clipboard its platform does not offer, rather than refusing with Unavailable", violation.description());
}

test "a host whose URL opener hands a path to the system fails the suite" {
    const Host = QueueHost(.opens_paths);
    var harness: QueueHostHarness(Host) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.UrlNotRefused, violation.kind);
    try std.testing.expect(std.mem.endsWith(u8, violation.description(), "notepad.exe\" to the system rather than refusing it"));
}
