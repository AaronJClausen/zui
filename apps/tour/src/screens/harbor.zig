const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

/// The fleet's totals at one instant, as the metrics producer publishes them.
pub const Metrics = struct {
    requests_per_second: f32 = 0,
    error_percent: f32 = 0,
    p95_milliseconds: f32 = 0,
    healthy_services: u32 = 0,
    /// Counts every publication, including those the UI never saw.
    sample: u64 = 0,
};

/// The newest fleet totals: values published between two frames replace each other.
pub const MetricsSource = zui_async.Latest(Metrics);

/// How much an event asks of whoever is on call.
pub const Severity = enum(u8) { info, warn, critical };

/// One line of the events feed.
pub const Event = struct {
    bytes: [96]u8 = undefined,
    len: u8 = 0,
    severity: Severity = .info,

    /// The event's line, as the feed shows it.
    pub fn text(self: *const Event) []const u8 {
        return self.bytes[0..self.len];
    }

    fn init(severity: Severity, comptime format: []const u8, arguments: anytype) Event {
        var event: Event = .{ .severity = severity };
        const written: []const u8 = std.fmt.bufPrint(&event.bytes, format, arguments) catch event.bytes[0..0];
        event.len = @intCast(written.len);
        return event;
    }
};

/// Every event, in order. The events producer and a requested burst publish at once, hence `.many`.
pub const EventSource = zui_async.Stream(Event, .{ .capacity = 64, .producers = .many });

const service_count = 5000;
const row_pitch: f32 = 32;
const history_length = 40;
const chart_samples = 32;
const kept_events = 64;
const burst_size = 40;
const latest_burst_size = 50;
const deploy_seconds: f32 = 4;
const toast_seconds: f32 = 3.5;
const unread_frames_before_stopping = 2;

const environments = [_][]const u8{ "production", "staging", "canary", "development" };
const environment_traffic = [_]f32{ 1, 0.12, 0.05, 0.01 };

const service_words = [_][]const u8{ "checkout", "payments", "search", "catalog", "identity", "ledger", "inventory", "shipping", "pricing", "notify", "media", "billing", "session", "gateway", "profile", "reviews" };
const service_roles = [_][]const u8{ "api", "worker", "cache", "edge", "sync", "index", "stream", "jobs", "rpc", "store" };
const regions = [_][]const u8{ "us-east", "us-west", "eu-west", "eu-central", "ap-south", "ap-east" };
const deployers = [_][]const u8{ "ci-bot", "maria.k", "deploy-train", "j.okafor", "lin.w" };

const Status = enum(u8) {
    healthy,
    degraded,
    down,

    fn label(status: Status) []const u8 {
        return @tagName(status);
    }
};

const Service = struct {
    region: []const u8,
    status: Status,
    requests_per_second: u32,
    p95_milliseconds: u32,
    error_basis_points: u32,
    version_minor: u8,
    version_patch: u8,

    fn versionKey(service: Service) u32 {
        return @as(u32, service.version_minor) * 100 + service.version_patch;
    }
};

fn mixBits(value: u64) u64 {
    var mixed = value +% 0x9E3779B97F4A7C15;
    mixed = (mixed ^ (mixed >> 30)) *% 0xBF58476D1CE4E5B9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94D049BB133111EB;
    return mixed ^ (mixed >> 31);
}

/// Every service is made from its index alone, so the table needs no storage per row.
fn serviceAt(index: u16) Service {
    const bits = mixBits(index);
    const roll = bits % 1000;
    const status: Status = if (roll < 12) .down else if (roll < 70) .degraded else .healthy;
    const base_latency: u32 = 18 + @as(u32, @intCast((bits >> 12) % 160));
    return .{
        .region = regions[@intCast((bits >> 8) % regions.len)],
        .status = status,
        .requests_per_second = if (status == .down) 0 else 20 + @as(u32, @intCast((bits >> 20) % 2400)),
        .p95_milliseconds = if (status == .degraded) base_latency + 240 else base_latency,
        .error_basis_points = switch (status) {
            .healthy => @intCast((bits >> 32) % 40),
            .degraded => 150 + @as(u32, @intCast((bits >> 32) % 450)),
            .down => 10_000,
        },
        .version_minor = 8 + @as(u8, @intCast((bits >> 44) % 12)),
        .version_patch = @intCast((bits >> 52) % 10),
    };
}

fn serviceName(index: u16, buffer: *[40]u8) []const u8 {
    const word = service_words[index % service_words.len];
    const role = service_roles[(index / service_words.len) % service_roles.len];
    const number = index / (service_words.len * service_roles.len);
    return std.fmt.bufPrint(buffer, "{s}-{s}-{d:0>2}", .{ word, role, number }) catch buffer[0..0];
}

fn withThousands(buffer: *[32]u8, value: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return buffer[0..0];
    var length: usize = 0;
    for (plain, 0..) |digit, position| {
        if (position != 0 and (plain.len - position) % 3 == 0) {
            buffer[length] = ',';
            length += 1;
        }
        buffer[length] = digit;
        length += 1;
    }
    return buffer[0..length];
}

const Column = enum {
    service,
    region,
    status,
    requests,
    p95,
    errors,
    version,

    fn title(column: Column) []const u8 {
        return switch (column) {
            .service => "Service",
            .region => "Region",
            .status => "Status",
            .requests => "Req/s",
            .p95 => "p95",
            .errors => "Errors",
            .version => "Version",
        };
    }

    fn tooltip(column: Column) []const u8 {
        return switch (column) {
            .service => "Sort by name",
            .region => "Sort by region",
            .status => "Sort by status, worst first",
            .requests => "Sort by requests per second",
            .p95 => "Sort by 95th percentile latency",
            .errors => "Sort by error rate",
            .version => "Sort by deployed version",
        };
    }

    /// Null grows into the room the fixed columns leave.
    fn width(column: Column) ?f32 {
        return switch (column) {
            .service => null,
            .region => 92,
            .status => 104,
            .requests => 76,
            .p95 => 72,
            .errors => 68,
            .version => 80,
        };
    }

    fn alignsToEnd(column: Column) bool {
        return switch (column) {
            .requests, .p95, .errors => true,
            else => false,
        };
    }

    fn sortsDescendingFirst(column: Column) bool {
        return switch (column) {
            .requests, .p95, .errors, .version => true,
            else => false,
        };
    }

    fn shownAt(column: Column, table_width: f32) bool {
        return switch (column) {
            .region, .version => table_width >= 730,
            .errors => table_width >= 540,
            else => true,
        };
    }
};

fn compareServices(column: Column, left: u16, right: u16) std.math.Order {
    const left_service = serviceAt(left);
    const right_service = serviceAt(right);
    return switch (column) {
        .service => {
            var left_name: [40]u8 = undefined;
            var right_name: [40]u8 = undefined;
            return std.mem.order(u8, serviceName(left, &left_name), serviceName(right, &right_name));
        },
        .region => std.mem.order(u8, left_service.region, right_service.region),
        .status => std.math.order(@intFromEnum(right_service.status), @intFromEnum(left_service.status)),
        .requests => std.math.order(left_service.requests_per_second, right_service.requests_per_second),
        .p95 => std.math.order(left_service.p95_milliseconds, right_service.p95_milliseconds),
        .errors => std.math.order(left_service.error_basis_points, right_service.error_basis_points),
        .version => std.math.order(left_service.versionKey(), right_service.versionKey()),
    };
}

const RowOrder = struct {
    column: Column,
    descending: bool,

    fn lessThan(order: RowOrder, left: u16, right: u16) bool {
        const comparison = compareServices(order.column, left, right);
        return switch (if (order.descending) comparison.invert() else comparison) {
            .lt => true,
            .gt => false,
            .eq => left < right,
        };
    }
};

fn matchesFilter(index: u16, filter: []const u8) bool {
    if (filter.len == 0) return true;
    var name_buffer: [40]u8 = undefined;
    const service = serviceAt(index);
    return std.ascii.indexOfIgnoreCase(serviceName(index, &name_buffer), filter) != null or
        std.ascii.indexOfIgnoreCase(service.region, filter) != null or
        std.ascii.indexOfIgnoreCase(service.status.label(), filter) != null;
}

/// The point of the console each X-ray node explains, in the order the nodes are numbered.
const Feature = enum {
    virtual_scroll,
    latest_source,
    stream_source,
    demand,
    anchors,
    focus_scope,
    exit_ghosts,
    motion,
    text_cache,
    idle,
    effects,
    semantics,
    environment,

    fn title(feature: Feature) []const u8 {
        return switch (feature) {
            .virtual_scroll => "Virtual scroll",
            .latest_source => "Latest source",
            .stream_source => "Stream source",
            .demand => "Producers on demand",
            .anchors => "Floating, anchored",
            .focus_scope => "Focus scope",
            .exit_ghosts => "Exit ghosts",
            .motion => "Motion",
            .text_cache => "Text measurement",
            .idle => "Idle by default",
            .effects => "Effects that lower",
            .semantics => "Semantics",
            .environment => "Environment",
        };
    }

    fn why(feature: Feature) []const u8 {
        return switch (feature) {
            .virtual_scroll => "Only the rows inside the viewport are declared, plus one above and one below. Scrolling costs the same at 100 rows or 10 million.",
            .latest_source => "A fast producer can never flood the UI: values it replaces between two frames are skipped, not queued.",
            .stream_source => "Nothing is skipped. A full ring refuses the newest item and reports it in Diagnostics, instead of growing or dropping silently.",
            .demand => "Leave Harbor and both producers stop within a quarter second, so every task finishes and the app can sleep. They start again the frame you come back.",
            .anchors => "A floating element takes no room in the layout and follows its anchor wherever layout puts it: resize the window and every one stays attached.",
            .focus_scope => "Tab and Shift+Tab cycle inside the dialog, Escape dismisses it, and the console behind it cannot be clicked.",
            .exit_ghosts => "The console simply stops declaring a toast; zui draws its departure. No animation state lives in the app.",
            .motion => "An animation asks for frames only while it moves, and lands at once when the user asks for reduced motion.",
            .text_cache => "Typing or scrolling measures only the strings not seen before. A frame with nothing new measures nothing.",
            .idle => "With nothing changing, the console costs nothing. The timeline shows why each recent frame was declared.",
            .effects => "A renderer that cannot draw an effect lowers it: a gradient becomes its mean color, a shadow is left out. The layout is the same either way.",
            .semantics => "The accessibility tree comes from the same declaration as the pixels, so it cannot drift from what is drawn.",
            .environment => "Every screen follows the environment with no code of its own: right to left mirrors the layout, high contrast strengthens the borders.",
        };
    }
};

const feature_count = std.enums.values(Feature).len;

const Toast = struct {
    message: [80]u8 = undefined,
    len: u8 = 0,
    serial: u32 = 0,
    expires_at: zui.Instant = .zero,
    tone: Severity = .info,

    fn text(self: *const Toast) []const u8 {
        return self.message[0..self.len];
    }
};

const Deploy = struct {
    service: u16,
    environment: usize,
    canary: bool,
    started_at: zui.Instant,
};

const KeptEvent = struct {
    event: Event,
    received_at_seconds: f64,
};

const FleetSummary = struct {
    healthy: u32 = 0,
    degraded: u32 = 0,
    down: u32 = 0,
};

/// What the X-ray changed in the environment, with the value to put back once the X-ray is left.
const EnvironmentRestore = struct {
    direction: ?zui.ReadingDirection = null,
    text_scale: ?f32 = null,
    contrast: ?zui.Environment.Contrast = null,
    reduced_motion: ?bool = null,
};

const ids = zui.ids(.{
    "harbor_console",
    "harbor_xray_bar",
    "harbor_timeline_toggle",
    "harbor_outline_toggle",
    "harbor_environment_readout",
    "harbor_toolbar",
    "harbor_environment",
    "harbor_filter",
    "harbor_live_pill",
    "harbor_deploy",
    "harbor_kpis",
    "harbor_services",
    "harbor_table_header",
    "harbor_table_body",
    "harbor_details",
    "harbor_chart",
    "harbor_restart",
    "harbor_rollback",
    "harbor_details_deploy",
    "harbor_events",
    "harbor_events_list",
    "harbor_toasts",
    "harbor_dialog_backdrop",
    "harbor_dialog",
    "harbor_dialog_canary",
    "harbor_dialog_cancel",
    "harbor_dialog_confirm",
    "harbor_xray_card",
    "harbor_xray_try",
    "harbor_xray_try_second",
});

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const DemandedProducer = kit.DemandedProducer;
    const EditableText = kit.zui_widgets.EditableText;
    const FrameReason = @FieldType(kit.Perf.Sample, "reason");

    const floating_shadow: zui.Effects = .{ .shadow = .{ .color = .rgba(0x00000040), .offset = .{ 0, 6 }, .blur = 18 } };

    return struct {
        /// Harbor and its X-ray: one console and one state, so the X-ray explains exactly what Harbor shows.
        pub const Harbor = struct {
            tasks: std.Io.Group = .init,
            metrics_producer: DemandedProducer = .{},
            events_producer: DemandedProducer = .{},
            /// Extra publications the metrics producer makes at once on its next tick.
            latest_burst_requested: std.atomic.Value(u32) = .init(0),

            fleet: FleetSummary = .{},
            ordered: [service_count]u16 = undefined,
            shown: [service_count]u16 = undefined,
            shown_count: u16 = 0,
            sort_column: Column = .requests,
            sort_descending: bool = true,
            ordering_stale: bool = true,
            filter_stale: bool = true,
            filter_bytes: [48]u8 = undefined,
            filter: EditableText = undefined,
            environment_choice: usize = 0,
            selected: u16 = 0,
            chart_service: ?u16 = null,

            metrics: ?Metrics = null,
            metrics_seen: u64 = 0,
            kpi_history: [4][history_length]f32 = @splat(@splat(0)),
            kpi_newest: usize = 0,

            events: [kept_events]KeptEvent = undefined,
            events_newest: usize = 0,
            events_count: usize = 0,
            events_received: u64 = 0,
            events_this_frame: usize = 0,
            bursts: u32 = 0,

            toasts: [3]Toast = @splat(.{}),
            toast_serial: u32 = 0,
            dialog_open: bool = false,
            dialog_canary: bool = true,
            deploy: ?Deploy = null,
            deployed_service: ?u16 = null,

            rows_declared: u32 = 0,
            semantic_nodes: u32 = 0,
            tooltips_shown: u32 = 0,
            chart_reveal: f32 = 1,

            xray_declared_this_frame: bool = false,
            xray_shown_since: ?f64 = null,
            pinned_feature: ?Feature = null,
            card_feature: ?Feature = null,
            outline_regions: bool = false,
            show_timeline: bool = false,
            environment_restore: EnvironmentRestore = .{},

            /// Points the filter at its buffer, counts the fleet and orders it busiest first.
            pub fn init(self: *Harbor) void {
                self.filter = .init(&self.filter_bytes, "");
                for (&self.ordered, 0..) |*slot, index| {
                    slot.* = @intCast(index);
                    switch (serviceAt(@intCast(index)).status) {
                        .healthy => self.fleet.healthy += 1,
                        .degraded => self.fleet.degraded += 1,
                        .down => self.fleet.down += 1,
                    }
                }
                self.refreshRows();
                self.selected = self.shown[0];
            }

            /// Cancels the producers and any burst still publishing.
            pub fn deinit(self: *Harbor, io: std.Io) void {
                self.tasks.cancel(io);
            }

            /// The console alone.
            pub fn declare(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                self.declareConsole(ui, shell, false);
            }

            /// The console with numbered nodes on its features; each opens a card with live proof.
            pub fn declareXray(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                self.declareConsole(ui, shell, true);
                self.declareXrayOverlay(ui, shell);
            }

            /// Starts the producers while a frame reads their sources and stops them once none does,
            /// and puts back what the X-ray changed in the environment once it is left.
            pub fn afterFrame(self: *Harbor, ui: *const Ui, shell: *const Shell) void {
                if (ui.framesSinceRead(.harbor_metrics) <= unread_frames_before_stopping) {
                    if (self.metrics_producer.demand()) {
                        const starting = self.metrics orelse Metrics{ .requests_per_second = 12_400, .error_percent = 0.4, .p95_milliseconds = 180, .healthy_services = self.fleet.healthy + self.fleet.degraded };
                        self.tasks.concurrent(shell.io, produceMetrics, .{ shell.io, &self.metrics_producer, &shell.sources.harbor_metrics, shell.waker, starting, self.fleet.healthy + self.fleet.degraded, &self.latest_burst_requested }) catch stopUnstarted(&self.metrics_producer);
                    }
                } else self.metrics_producer.release();

                if (ui.framesSinceRead(.harbor_events) <= unread_frames_before_stopping) {
                    if (self.events_producer.demand()) {
                        self.tasks.concurrent(shell.io, produceEvents, .{ shell.io, &self.events_producer, &shell.sources.harbor_events, shell.waker, self.events_received }) catch stopUnstarted(&self.events_producer);
                    }
                } else self.events_producer.release();

                if (!self.xray_declared_this_frame) {
                    self.xray_shown_since = null;
                    self.restoreEnvironment(shell);
                }
                self.xray_declared_this_frame = false;
            }

            fn stopUnstarted(producer: *DemandedProducer) void {
                producer.release();
                _ = producer.keepGoing();
            }

            fn restoreEnvironment(self: *Harbor, shell: *const Shell) void {
                const restore = &self.environment_restore;
                if (restore.direction) |direction| shell.changeEnvironment(.{ .direction = direction });
                if (restore.text_scale) |text_scale| shell.changeEnvironment(.{ .text_scale = text_scale });
                if (restore.contrast) |contrast| shell.changeEnvironment(.{ .contrast = contrast });
                if (restore.reduced_motion) |reduced_motion| shell.changeEnvironment(.{ .reduced_motion = reduced_motion });
                restore.* = .{};
            }

            fn declareConsole(self: *Harbor, ui: *Ui, shell: *const Shell, xray: bool) void {
                self.rows_declared = 0;
                self.semantic_nodes = 0;
                self.tooltips_shown = 0;
                self.readSources(ui, shell);
                self.advanceDeploy(ui, shell);
                self.refreshRows();

                ui.open(.{ .id = ids.harbor_console, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 } });
                if (xray) self.xrayBar(ui, shell);
                self.toolbar(ui, shell);
                self.kpiRow(ui, shell);
                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    self.servicesPanel(ui, shell);
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(320), .height = .grow }, .child_gap = 12 } });
                    defer ui.close();
                    self.detailsPanel(ui, shell);
                    self.eventsPanel(ui, shell);
                }
                ui.close();
                self.toastStack(ui, shell);
                if (self.dialog_open) self.deployDialog(ui, shell);
            }

            fn semantic(self: *Harbor, semantics: zui.Semantics) zui.Semantics {
                self.semantic_nodes += 1;
                return semantics;
            }

            fn readSources(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const metrics = ui.source(.harbor_metrics);
                if (metrics.changed()) if (metrics.get()) |reading| {
                    self.metrics = reading;
                    self.metrics_seen += 1;
                    self.kpi_newest = (self.kpi_newest + 1) % history_length;
                    const values = [4]f32{ reading.requests_per_second, reading.error_percent, reading.p95_milliseconds, @floatFromInt(reading.healthy_services) };
                    for (&self.kpi_history, values) |*history, value| history[self.kpi_newest] = value;
                };

                var items = ui.source(.harbor_events).items();
                self.events_this_frame = 0;
                while (items.next()) |event| {
                    self.keepEvent(event.*, shell.seconds);
                    self.events_this_frame += 1;
                }
            }

            fn keepEvent(self: *Harbor, event: Event, seconds: f64) void {
                self.events_newest = (self.events_newest + 1) % kept_events;
                self.events[self.events_newest] = .{ .event = event, .received_at_seconds = seconds };
                self.events_count = @min(self.events_count + 1, kept_events);
                self.events_received += 1;
            }

            fn refreshRows(self: *Harbor) void {
                if (self.ordering_stale) {
                    std.mem.sort(u16, &self.ordered, RowOrder{ .column = self.sort_column, .descending = self.sort_descending }, RowOrder.lessThan);
                    self.ordering_stale = false;
                    self.filter_stale = true;
                }
                if (!self.filter_stale) return;
                self.filter_stale = false;
                self.shown_count = 0;
                for (self.ordered) |index| {
                    if (!matchesFilter(index, self.filter.slice())) continue;
                    self.shown[self.shown_count] = index;
                    self.shown_count += 1;
                }
            }

            fn showToast(self: *Harbor, ui: *Ui, tone: Severity, comptime format: []const u8, arguments: anytype) void {
                var oldest: usize = 0;
                for (self.toasts, 0..) |toast, index| {
                    if (toast.serial < self.toasts[oldest].serial) oldest = index;
                }
                self.toast_serial += 1;
                const toast = &self.toasts[oldest];
                const written: []const u8 = std.fmt.bufPrint(&toast.message, format, arguments) catch toast.message[0..0];
                toast.len = @intCast(written.len);
                toast.serial = self.toast_serial;
                toast.tone = tone;
                toast.expires_at = ui.now().addSeconds(toast_seconds);
            }

            fn advanceDeploy(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const deploy = self.deploy orelse return;
                if (ui.now().secondsSince(deploy.started_at) < deploy_seconds) {
                    ui.requestFrameAt(ui.now().addSeconds(0.1));
                    return;
                }
                self.deploy = null;
                self.deployed_service = deploy.service;
                var name_buffer: [40]u8 = undefined;
                const name = serviceName(deploy.service, &name_buffer);
                const service = serviceAt(deploy.service);
                self.showToast(ui, .info, "{s} is live on v2.{d}.{d}", .{ name, service.version_minor, service.version_patch + 1 });
                self.keepEvent(.init(.info, "Deploy finished: {s} v2.{d}.{d} on {s}", .{ name, service.version_minor, service.version_patch + 1, environments[deploy.environment] }), shell.seconds);
            }

            fn select(self: *Harbor, service: u16) void {
                self.selected = service;
            }

            fn openDialog(self: *Harbor, ui: *Ui) void {
                self.dialog_open = true;
                ui.requestFocus(ids.harbor_dialog_confirm);
            }

            fn openPanel(_: *Harbor, ui: *Ui, shell: *const Shell, id: zui.Id, sizing: zui.Sizing2) void {
                ui.open(.{
                    .id = id,
                    .layout = .{ .direction = .top_to_bottom, .sizing = sizing, .padding = .all(16), .child_gap = 10 },
                    .decoration = .{ .background = shell.palette.surface, .border = .{ .color = shell.palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                });
            }

            fn tooltip(self: *Harbor, ui: *Ui, shell: *const Shell, target: zui.Id, content: []const u8) void {
                if (!ui.hovered(target)) return;
                self.tooltips_shown += 1;
                ui.open(.{
                    .floating = .{ .attach_to = .{ .element = target }, .anchor = .bottom_center, .attach_point = .top_center, .offset = .{ 0, -6 }, .z = 600, .capture = false },
                    .layout = .{ .padding = .symmetric(8, 4) },
                    .decoration = .{ .background = shell.palette.text, .corner_radius = .all(4) },
                    .effects = &floating_shadow,
                });
                ui.text(content, noWrap(shell.style(.caption, shell.palette.background)));
                ui.close();
            }

            fn toolbar(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                ui.open(.{
                    .id = ids.harbor_toolbar,
                    .semantics = self.semantic(.{ .role = .group, .label = "Toolbar" }),
                    .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                });
                defer ui.close();
                _ = shell.widgets.dropdown(ui, ids.harbor_environment, &self.environment_choice, &environments, .{ .label = "Environment" });
                if (shell.widgets.textField(ui, ids.harbor_filter, &self.filter, .{ .placeholder = "Filter by name, region or status", .width = .fixed(260) }).changed) self.filter_stale = true;
                var shown_buffer: [32]u8 = undefined;
                shell.printColored(ui, .caption, palette.muted, "{s} of 5,000", .{withThousands(&shown_buffer, self.shown_count)});
                shell.spacer(ui);
                {
                    const running = self.metrics_producer.phase.load(.acquire) == .running;
                    ui.open(.{
                        .id = ids.harbor_live_pill,
                        .layout = .{ .padding = .symmetric(10, 4), .child_gap = 6, .child_alignment = .{ .y = .center } },
                        .decoration = .{ .background = palette.sunken, .corner_radius = .all(12) },
                    });
                    defer ui.close();
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = if (running) palette.good else palette.faint, .corner_radius = .all(4) } });
                    const sample = if (self.metrics) |metrics| metrics.sample else 0;
                    shell.printColored(ui, .caption, palette.muted, "{s} · sample {d}", .{ if (running) "Live" else "Paused", sample });
                }
                if (primaryButton(self, ui, shell, ids.harbor_deploy, "Deploy…")) self.openDialog(ui);
                self.tooltip(ui, shell, ids.harbor_deploy, "Deploy the selected service");
            }

            fn kpiRow(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                ui.open(.{ .id = ids.harbor_kpis, .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
                defer ui.close();
                const traffic = environment_traffic[self.environment_choice];
                const reading = self.metrics;
                var value_buffer: [32]u8 = undefined;
                var detail_buffer: [48]u8 = undefined;
                const tiles = [4]struct { []const u8, []const u8, []const u8, zui.Color, f32 }{
                    .{
                        "Requests per second",
                        if (reading) |metrics| withThousands(&value_buffer, @intFromFloat(metrics.requests_per_second * traffic)) else "—",
                        "across every region",
                        palette.accent,
                        traffic,
                    },
                    .{ "Error rate", "", "of requests, last minute", if (reading != null and reading.?.error_percent > 1) palette.bad else palette.warn, 1 },
                    .{ "p95 latency", "", "fleet-wide, rolling", palette.warn, 1 },
                    .{ "Healthy services", "", "", palette.good, 1 },
                };
                for (tiles, 0..) |tile, index| {
                    const tile_id: zui.Id = .indexed("harbor_kpi", index);
                    var tile_value_buffer: [32]u8 = undefined;
                    const value: []const u8 = switch (index) {
                        0 => tile[1],
                        1 => if (reading) |metrics| std.fmt.bufPrint(&tile_value_buffer, "{d:.2}%", .{metrics.error_percent}) catch "" else "—",
                        2 => if (reading) |metrics| std.fmt.bufPrint(&tile_value_buffer, "{d:.0} ms", .{metrics.p95_milliseconds}) catch "" else "—",
                        else => if (reading) |metrics| withThousands(&tile_value_buffer, metrics.healthy_services) else "—",
                    };
                    const detail: []const u8 = if (index == 3) std.fmt.bufPrint(&detail_buffer, "of 5,000 · {d} down", .{self.fleet.down}) catch "" else tile[2];
                    ui.open(.{
                        .id = tile_id,
                        .semantics = self.semantic(.{ .role = .group, .label = tile[0], .value = .{ .text = value } }),
                        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal }, .padding = .all(12), .child_gap = 6 },
                        .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                    });
                    defer ui.close();
                    ui.text(tile[0], noWrap(shell.style(.caption, palette.muted)));
                    {
                        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .end } } });
                        defer ui.close();
                        ui.text(value, .{ .size = 24 * shell.text_scale, .font = shell.fonts.bold, .color = palette.text, .wrap = .none });
                        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                        shell.labelColored(ui, .tiny, palette.faint, detail);
                        ui.close();
                    }
                    self.sparkline(ui, shell, index, tile[3], tile[4]);
                }
            }

            fn sparkline(self: *Harbor, ui: *Ui, shell: *const Shell, series: usize, color: zui.Color, scale: f32) void {
                const history = &self.kpi_history[series];
                var lowest: f32 = std.math.floatMax(f32);
                var highest: f32 = 0;
                for (history) |value| if (value != 0) {
                    lowest = @min(lowest, value);
                    highest = @max(highest, value);
                };
                const span = @max(highest - lowest, highest * 0.02 + 0.0001);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(20) }, .child_gap = 1, .child_alignment = .{ .y = .end } }, .clip = .both });
                defer ui.close();
                for (0..history_length) |age| {
                    const value = history[(self.kpi_newest + 1 + age) % history_length] * scale;
                    const fraction = if (value == 0) 0.04 else 0.15 + 0.85 * (value / scale - lowest) / span;
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .grow_equal, .height = .percent(std.math.clamp(fraction, 0.04, 1)) } },
                        .decoration = .{ .background = if (age == history_length - 1) color else color.mix(shell.palette.surface, 0.55), .corner_radius = .all(1) },
                    });
                }
            }

            fn servicesPanel(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                self.openPanel(ui, shell, ids.harbor_services, .grow_both);
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 10, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.text("Services", noWrap(shell.style(.heading, palette.text)));
                    shell.spacer(ui);
                    shell.printColored(ui, .caption, palette.good, "{d} healthy", .{self.fleet.healthy});
                    shell.printColored(ui, .caption, palette.warn, "{d} degraded", .{self.fleet.degraded});
                    shell.printColored(ui, .caption, palette.bad, "{d} down", .{self.fleet.down});
                }

                const body = ui.rectOf(ids.harbor_table_body) orelse zui.Rect{ .width = 800, .height = 480 };
                const table_width = self.tableWidthAvailable(ui);
                self.tableHeader(ui, shell, table_width);
                self.handleTableKeys(ui, body.height);

                const count: usize = self.shown_count;
                const offset = ui.scrollOffset(ids.harbor_table_body)[1];
                const last: usize = @min(count, @as(usize, @intFromFloat(@max(0, @ceil((offset + body.height) / row_pitch)))) + 1);
                const first: usize = @min(last, @as(usize, @intFromFloat(@max(0, @floor(offset / row_pitch) - 1))));
                ui.open(.{
                    .id = ids.harbor_table_body,
                    .focusable = true,
                    .semantics = self.semantic(.{ .role = .list_box, .label = "Services" }),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
                    .decoration = .{ .border = if (ui.focused(ids.harbor_table_body)) .{ .color = palette.focus, .widths = .all(1) } else null, .corner_radius = .all(4) },
                    .scroll = .{},
                });
                defer ui.close();
                ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first)) * row_pitch) } } });
                for (self.shown[first..last], first..) |service, position| self.serviceRow(ui, shell, service, position, table_width);
                ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(count - last)) * row_pitch) } } });
                if (count == 0) ui.text("No service matches the filter.", shell.style(.body, palette.muted));
            }

            /// What the window leaves the table, rather than what it took last frame: columns
            /// chosen by the table's own width would keep it as wide as they made it.
            fn tableWidthAvailable(_: *const Harbor, ui: *Ui) f32 {
                const console = ui.rectOf(ids.harbor_console) orelse zui.Rect{ .x = 252, .width = 1172 };
                const stage_right_padding = 16;
                const right_column_and_gap = 332;
                const panel_padding_and_border = 34;
                return ui.viewport()[0] - console.x - stage_right_padding - right_column_and_gap - panel_padding_and_border;
            }

            fn tableHeader(self: *Harbor, ui: *Ui, shell: *const Shell, table_width: f32) void {
                const palette = shell.palette;
                ui.open(.{
                    .id = ids.harbor_table_header,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(30) }, .padding = .{ .left = 12, .right = 12 }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = palette.sunken, .corner_radius = .all(4) },
                });
                defer ui.close();
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(3) } } });
                for (std.enums.values(Column)) |column| {
                    if (!column.shownAt(table_width)) continue;
                    const id: zui.Id = .indexed("harbor_column", @intFromEnum(column));
                    if (ui.clicked(id)) {
                        if (self.sort_column == column) self.sort_descending = !self.sort_descending else {
                            self.sort_column = column;
                            self.sort_descending = column.sortsDescendingFirst();
                        }
                        self.ordering_stale = true;
                    }
                    const sorted = self.sort_column == column;
                    const hovered = ui.hovered(id);
                    ui.open(.{
                        .id = id,
                        .focusable = true,
                        .cursor = .pointer,
                        .semantics = self.semantic(.{ .role = .button, .label = column.tooltip(), .state = .{ .selected = sorted } }),
                        .layout = .{
                            .sizing = .{ .width = if (column.width()) |width| .fixed(width) else .grow, .height = .grow },
                            .child_gap = 4,
                            .child_alignment = .{ .x = if (column.alignsToEnd()) .end else .start, .y = .center },
                        },
                        .decoration = .{ .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else null, .corner_radius = .all(3) },
                    });
                    defer ui.close();
                    ui.text(column.title(), noWrap(shell.style(.caption, if (sorted) palette.text else if (hovered) palette.text else palette.muted)));
                    if (sorted) ui.text(if (self.sort_descending) "▼" else "▲", .{ .size = 9 * shell.text_scale, .font = shell.fonts.mono, .color = palette.accent, .wrap = .none });
                    self.tooltip(ui, shell, id, column.tooltip());
                }
            }

            fn handleTableKeys(self: *Harbor, ui: *Ui, visible_height: f32) void {
                if (!ui.focused(ids.harbor_table_body) or self.shown_count == 0) return;
                const count: isize = self.shown_count;
                const page: isize = @max(1, @as(isize, @intFromFloat(visible_height / row_pitch)) - 1);
                const current: isize = if (std.mem.indexOfScalar(u16, self.shown[0..self.shown_count], self.selected)) |position| @intCast(position) else -1;
                var target = current;
                for (ui.keyEvents()) |key_event| switch (key_event.key) {
                    .down => target += 1,
                    .up => target -= 1,
                    .page_down => target += page,
                    .page_up => target -= page,
                    .home => target = 0,
                    .end => target = count - 1,
                    else => {},
                };
                if (target == current) return;
                const position: usize = @intCast(std.math.clamp(target, 0, count - 1));
                self.select(self.shown[position]);
                const row_top = @as(f32, @floatFromInt(position)) * row_pitch;
                const offset = ui.scrollOffset(ids.harbor_table_body)[1];
                if (row_top < offset) ui.setScrollOffset(ids.harbor_table_body, .{ 0, row_top });
                if (row_top + row_pitch > offset + visible_height) ui.setScrollOffset(ids.harbor_table_body, .{ 0, row_top + row_pitch - visible_height });
            }

            fn serviceRow(self: *Harbor, ui: *Ui, shell: *const Shell, index: u16, position: usize, table_width: f32) void {
                const palette = shell.palette;
                const row_id: zui.Id = .indexed("harbor_row", index);
                if (ui.clicked(row_id)) {
                    self.select(index);
                    ui.requestFocus(ids.harbor_table_body);
                }
                self.rows_declared += 1;
                const service = serviceAt(index);
                const selected = self.selected == index;
                const highlight = easeToward(ui, row_id, if (selected) 1 else 0, 18);
                const selected_background = palette.accent.mix(palette.surface, 0.85);
                const stripe: ?zui.Color = if (position % 2 == 1) palette.raised.mix(palette.surface, 0.4) else null;
                const background: ?zui.Color = if (highlight > 0.01) palette.surface.mix(selected_background, highlight) else if (ui.hovered(row_id)) palette.hovered else stripe;
                var name_buffer: [40]u8 = undefined;
                const name = serviceName(index, &name_buffer);
                ui.open(.{
                    .id = row_id,
                    .interactive = true,
                    .cursor = .pointer,
                    .semantics = self.semantic(.{ .role = .option, .label = name, .state = .{ .selected = selected } }),
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(row_pitch) }, .padding = .{ .left = 12, .right = 12 }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = background, .corner_radius = .all(4) },
                });
                defer ui.close();
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(3), .height = .fixed(18) } },
                    .decoration = if (highlight > 0.01) .{ .background = palette.accent.mix(background orelse palette.surface, 1 - highlight), .corner_radius = .all(1.5) } else null,
                });
                const deploying = if (self.deploy) |deploy| deploy.service == index else false;
                const patch = service.version_patch + @intFromBool(self.deployed_service == index);
                for (std.enums.values(Column)) |column| {
                    if (!column.shownAt(table_width)) continue;
                    ui.open(.{ .layout = .{
                        .sizing = .{ .width = if (column.width()) |width| .fixed(width) else .grow },
                        .child_alignment = .{ .x = if (column.alignsToEnd()) .end else .start, .y = .center },
                    } });
                    defer ui.close();
                    var buffer: [32]u8 = undefined;
                    switch (column) {
                        .service => ui.text(name, noWrap(shell.style(.caption, palette.text))),
                        .region => ui.text(service.region, noWrap(shell.style(.caption, palette.muted))),
                        .status => if (deploying) statusChip(ui, shell, "deploying", palette.accent) else statusChip(ui, shell, service.status.label(), statusColor(palette, service.status)),
                        .requests => ui.text(withThousands(&buffer, @intFromFloat(@as(f32, @floatFromInt(service.requests_per_second)) * environment_traffic[self.environment_choice])), self.monoStyle(shell, palette.text)),
                        .p95 => ui.text(std.fmt.bufPrint(&buffer, "{d} ms", .{service.p95_milliseconds}) catch "", self.monoStyle(shell, if (service.p95_milliseconds > 250) palette.warn else palette.text)),
                        .errors => ui.text(std.fmt.bufPrint(&buffer, "{d:.2}%", .{@as(f32, @floatFromInt(service.error_basis_points)) / 100}) catch "", self.monoStyle(shell, if (service.error_basis_points > 100) palette.bad else palette.muted)),
                        .version => ui.text(std.fmt.bufPrint(&buffer, "v2.{d}.{d}", .{ service.version_minor, patch }) catch "", self.monoStyle(shell, palette.muted)),
                    }
                }
            }

            fn monoStyle(_: *const Harbor, shell: *const Shell, color: zui.Color) kit.TextStyle {
                return .{ .size = 12 * shell.text_scale, .font = shell.fonts.mono, .color = color, .wrap = .none };
            }

            fn detailsPanel(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                const index = self.selected;
                const service = serviceAt(index);
                var name_buffer: [40]u8 = undefined;
                const name = serviceName(index, &name_buffer);
                shell.openScrollingCard(ui, ids.harbor_details, "", .grow_both);
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 2 } });
                    ui.text(name, .{ .size = kit.Tone.heading.size() * shell.text_scale, .font = shell.fonts.bold, .color = palette.text, .wrap = .none });
                    const patch = service.version_patch + @intFromBool(self.deployed_service == index);
                    shell.printColored(ui, .caption, palette.muted, "{s} · v2.{d}.{d}", .{ service.region, service.version_minor, patch });
                    ui.close();
                    statusChip(ui, shell, service.status.label(), statusColor(palette, service.status));
                }
                if (self.deploy) |deploy| if (deploy.service == index) {
                    const progress = ui.now().secondsSince(deploy.started_at) / deploy_seconds;
                    shell.printColored(ui, .caption, palette.accent, "Deploying to {s}{s}: {d:.0}%", .{ environments[deploy.environment], if (deploy.canary) ", canary first" else "", progress * 100 });
                    shell.meter(ui, progress, palette.accent, 6);
                };
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                    defer ui.close();
                    if (shell.widgets.button(ui, ids.harbor_restart, "Restart", .{})) {
                        self.showToast(ui, .info, "Restarting {s}: 0 of 3 replicas", .{name});
                        self.keepEvent(.init(.info, "Rolling restart requested for {s}", .{name}), shell.seconds);
                    }
                    if (shell.widgets.button(ui, ids.harbor_rollback, "Roll back", .{})) {
                        self.showToast(ui, .warn, "Rolled {s} back to v2.{d}.{d}", .{ name, service.version_minor, service.version_patch -| 1 });
                        self.keepEvent(.init(.warn, "Rollback of {s} to v2.{d}.{d}", .{ name, service.version_minor, service.version_patch -| 1 }), shell.seconds);
                    }
                    if (shell.widgets.button(ui, ids.harbor_details_deploy, "Deploy…", .{ .disabled = self.deploy != null })) self.openDialog(ui);
                }
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                    defer ui.close();
                    var buffer: [32]u8 = undefined;
                    const requests = withThousands(&buffer, @intFromFloat(@as(f32, @floatFromInt(service.requests_per_second)) * environment_traffic[self.environment_choice]));
                    miniStat(ui, shell, "Req/s", requests);
                    var latency_buffer: [16]u8 = undefined;
                    miniStat(ui, shell, "p95", std.fmt.bufPrint(&latency_buffer, "{d} ms", .{service.p95_milliseconds}) catch "");
                    var error_buffer: [16]u8 = undefined;
                    miniStat(ui, shell, "Errors", std.fmt.bufPrint(&error_buffer, "{d:.2}%", .{@as(f32, @floatFromInt(service.error_basis_points)) / 100}) catch "");
                }
                self.latencyChart(ui, shell, index, service);
                shell.labelColored(ui, .tiny, palette.faint, "RECENT DEPLOYS");
                for (0..3) |age| {
                    const bits = mixBits(@as(u64, index) * 7 + age);
                    const rolled_back = age == 1 and bits % 4 == 0;
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    var version_buffer: [16]u8 = undefined;
                    const patch: u8 = service.version_patch -| @as(u8, @intCast(age));
                    ui.text(std.fmt.bufPrint(&version_buffer, "v2.{d}.{d}", .{ service.version_minor, patch }) catch "", self.monoStyle(shell, palette.text));
                    shell.printColored(ui, .caption, palette.muted, "{d} h ago · {s}", .{ 2 + age * 26 + bits % 20, deployers[@intCast(bits % deployers.len)] });
                    shell.spacer(ui);
                    if (rolled_back) shell.labelColored(ui, .caption, palette.warn, "rolled back") else shell.labelColored(ui, .caption, palette.good, "ok");
                }
            }

            fn latencyChart(self: *Harbor, ui: *Ui, shell: *const Shell, index: u16, service: Service) void {
                const palette = shell.palette;
                if (self.chart_service != index) {
                    if (self.chart_service != null) ui.state(ids.harbor_chart, Eased).value = 0;
                    self.chart_service = index;
                }
                self.chart_reveal = easeToward(ui, ids.harbor_chart, 1, 9);
                const sample = if (self.metrics) |metrics| metrics.sample else 0;
                shell.labelColored(ui, .tiny, palette.faint, "P95 LATENCY, LAST 32 SAMPLES");
                ui.open(.{
                    .id = ids.harbor_chart,
                    .semantics = self.semantic(.{ .role = .image, .label = "p95 latency over the last 32 samples" }),
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(64) }, .padding = .all(4), .child_gap = 2, .child_alignment = .{ .y = .end } },
                    .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) },
                });
                defer ui.close();
                const base: f32 = @floatFromInt(service.p95_milliseconds);
                for (0..chart_samples) |age| {
                    const moment = sample + age;
                    const wave = @sin(@as(f32, @floatFromInt(moment)) * 0.45 + @as(f32, @floatFromInt(index)));
                    const noise = @as(f32, @floatFromInt(mixBits(@as(u64, index) *% 1_000_003 +% moment) % 1000)) / 1000;
                    const latency = base * (1 + 0.22 * wave + 0.18 * noise);
                    const fraction = std.math.clamp(latency / (base * 1.5), 0.05, 1) * self.chart_reveal;
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .grow_equal, .height = .percent(@max(0.02, fraction)) } },
                        .decoration = .{ .background = if (latency > 250) palette.warn else palette.accent.mix(palette.sunken, 0.25), .corner_radius = .all(1) },
                    });
                }
            }

            fn eventsPanel(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                self.openPanel(ui, shell, ids.harbor_events, .{ .width = .grow, .height = .percent(0.38) });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    ui.text("Events", noWrap(shell.style(.heading, palette.text)));
                    shell.spacer(ui);
                    shell.printColored(ui, .caption, palette.muted, "{d} received", .{self.events_received});
                }
                ui.open(.{
                    .id = ids.harbor_events_list,
                    .semantics = self.semantic(.{ .role = .group, .label = "Events, newest first" }),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 6 },
                    .scroll = .{},
                });
                defer ui.close();
                if (self.events_count == 0) shell.labelColored(ui, .caption, palette.faint, "Waiting for the first event…");
                for (0..self.events_count) |age| {
                    const kept = &self.events[(self.events_newest + kept_events - age) % kept_events];
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                    defer ui.close();
                    var time_buffer: [16]u8 = undefined;
                    const seconds_ago = @max(0, shell.seconds - kept.received_at_seconds);
                    const ago: []const u8 = if (seconds_ago < 60) std.fmt.bufPrint(&time_buffer, "{d:>3.0}s", .{seconds_ago}) catch "" else std.fmt.bufPrint(&time_buffer, "{d:>3.0}m", .{seconds_ago / 60}) catch "";
                    ui.text(ago, self.monoStyle(shell, palette.faint));
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(6), .height = .fixed(6) } }, .decoration = .{ .background = severityColor(palette, kept.event.severity), .corner_radius = .all(3) } });
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    shell.labelColored(ui, .caption, if (kept.event.severity == .info) palette.muted else severityColor(palette, kept.event.severity), kept.event.text());
                    ui.close();
                }
            }

            fn toastStack(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                const now = ui.now();
                var soonest: ?zui.Instant = null;
                var any = false;
                for (self.toasts) |toast| {
                    if (toast.serial == 0 or !now.isBefore(toast.expires_at)) continue;
                    any = true;
                    if (soonest == null or toast.expires_at.isBefore(soonest.?)) soonest = toast.expires_at;
                }
                if (soonest) |instant| ui.requestFrameAt(instant);
                if (!any) return;
                ui.open(.{
                    .id = ids.harbor_toasts,
                    .floating = .{ .attach_to = .{ .element = ids.harbor_console }, .anchor = .bottom_center, .attach_point = .bottom_center, .offset = .{ 0, -16 }, .z = 650, .capture = false },
                    .layout = .{ .direction = .top_to_bottom, .child_gap = 8, .child_alignment = .{ .x = .center } },
                });
                defer ui.close();
                for (self.toasts) |toast| {
                    if (toast.serial == 0 or !now.isBefore(toast.expires_at)) continue;
                    ui.open(.{
                        .id = .indexed("harbor_toast", toast.serial),
                        .exit = .{ .seconds = 0.3, .fade = .ease_out },
                        .semantics = self.semantic(.{ .role = .label, .label = toast.text() }),
                        .layout = .{ .padding = .symmetric(14, 10), .child_gap = 10, .child_alignment = .{ .y = .center } },
                        .decoration = .{ .background = palette.raised, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                        .effects = &floating_shadow,
                    });
                    defer ui.close();
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = if (toast.tone == .info) palette.good else severityColor(palette, toast.tone), .corner_radius = .all(4) } });
                    ui.text(toast.text(), noWrap(shell.style(.body, palette.text)));
                }
            }

            fn deployDialog(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                if (ui.dismissed(ids.harbor_dialog) or ui.clicked(ids.harbor_dialog_backdrop)) {
                    self.dialog_open = false;
                    ui.requestFocus(ids.harbor_deploy);
                    return;
                }
                const index = self.selected;
                const service = serviceAt(index);
                var name_buffer: [40]u8 = undefined;
                const name = serviceName(index, &name_buffer);
                const viewport = ui.viewport();
                ui.open(.{
                    .id = ids.harbor_dialog_backdrop,
                    .interactive = true,
                    .floating = .{ .attach_to = .root, .z = 700 },
                    .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{ .background = palette.overlay },
                });
                defer ui.close();
                ui.open(.{
                    .id = ids.harbor_dialog,
                    .interactive = true,
                    .focus_scope = true,
                    .semantics = self.semantic(.{ .role = .dialog, .label = "Deploy" }),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(440) }, .padding = .all(20), .child_gap = 12 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(10) },
                    .effects = &floating_shadow,
                });
                defer ui.close();
                shell.printColored(ui, .heading, palette.text, "Deploy {s}", .{name});
                shell.printColored(ui, .body, palette.muted, "v2.{d}.{d} to v2.{d}.{d} on {s}, rolling 25% of replicas at a time.", .{ service.version_minor, service.version_patch, service.version_minor, service.version_patch + 1, environments[self.environment_choice] });
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.labelColored(ui, .caption, palette.muted, "Current status");
                    statusChip(ui, shell, service.status.label(), statusColor(palette, service.status));
                }
                _ = shell.widgets.checkbox(ui, ids.harbor_dialog_canary, "Canary first: 5% of traffic for 10 minutes", &self.dialog_canary, .{});
                shell.labelColored(ui, .caption, palette.faint, "Tab stays inside this dialog. Escape cancels.");
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                defer ui.close();
                shell.spacer(ui);
                if (shell.widgets.button(ui, ids.harbor_dialog_cancel, "Cancel", .{})) {
                    self.dialog_open = false;
                    ui.requestFocus(ids.harbor_deploy);
                }
                if (primaryButton(self, ui, shell, ids.harbor_dialog_confirm, "Deploy")) {
                    self.dialog_open = false;
                    self.deploy = .{ .service = index, .environment = self.environment_choice, .canary = self.dialog_canary, .started_at = ui.now() };
                    self.showToast(ui, .info, "Deploying {s} to {s}", .{ name, environments[self.environment_choice] });
                    self.keepEvent(.init(.info, "Deploy started: {s} to {s}", .{ name, environments[self.environment_choice] }), shell.seconds);
                    ui.requestFocus(ids.harbor_table_body);
                }
            }

            fn xrayBar(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                {
                    ui.open(.{
                        .id = ids.harbor_xray_bar,
                        .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(12, 6), .child_gap = 12, .child_alignment = .{ .y = .center } },
                        .decoration = .{ .background = palette.accent.mix(palette.surface, 0.88), .corner_radius = .all(8) },
                    });
                    defer ui.close();
                    ui.text("X-ray", noWrap(shell.style(.heading, palette.accent)));
                    shell.printColored(ui, .caption, palette.muted, "{d} features marked. Hover, Tab to or click a numbered dot.", .{feature_count});
                    shell.spacer(ui);
                    _ = shell.widgets.checkbox(ui, ids.harbor_outline_toggle, "Outline regions", &self.outline_regions, .{});
                    _ = shell.widgets.checkbox(ui, ids.harbor_timeline_toggle, "Frame timeline", &self.show_timeline, .{});
                    const environment = ui.environment();
                    ui.open(.{ .id = ids.harbor_environment_readout, .layout = .{ .padding = .symmetric(8, 3) }, .decoration = .{ .background = palette.surface, .corner_radius = .all(6) } });
                    shell.printColored(ui, .tiny, palette.muted, "{s} · text {d:.0}% · contrast {t}", .{ if (environment.direction == .left_to_right) "ltr" else "rtl", environment.text_scale * 100, environment.contrast });
                    ui.close();
                }
                if (self.show_timeline) frameTimeline(ui, shell);
            }

            fn declareXrayOverlay(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                self.xray_declared_this_frame = true;
                const shown_since = self.xray_shown_since orelse shell.seconds;
                self.xray_shown_since = shown_since;
                const pulsing = !shell.reduced_motion and shell.seconds - shown_since < 4;
                if (pulsing) ui.requestFrame();
                if (self.outline_regions) self.outlines(ui, shell);
                if (self.pinned_feature != null and !self.dialog_open and ui.keyPressed(.escape)) self.pinned_feature = null;

                var open_feature: ?Feature = self.pinned_feature;
                if (open_feature == null and ui.hovered(ids.harbor_xray_card)) open_feature = self.card_feature;
                for (std.enums.values(Feature)) |feature| {
                    const node_id = nodeId(feature);
                    if (ui.clicked(node_id)) self.pinned_feature = if (self.pinned_feature == feature) null else feature;
                    if (open_feature == null and (ui.hovered(node_id) or ui.focused(node_id))) open_feature = feature;
                    self.node(ui, shell, feature, pulsing);
                }
                if (self.pinned_feature) |pinned| open_feature = pinned;
                self.card_feature = open_feature;
                if (open_feature) |feature| self.featureCard(ui, shell, feature);
            }

            fn nodeId(feature: Feature) zui.Id {
                return .indexed("harbor_xray_node", @intFromEnum(feature));
            }

            fn nodeTarget(feature: Feature) zui.Id {
                return switch (feature) {
                    .virtual_scroll => ids.harbor_services,
                    .latest_source => .indexed("harbor_kpi", 0),
                    .stream_source => ids.harbor_events,
                    .demand => ids.harbor_live_pill,
                    .anchors => ids.harbor_environment,
                    .focus_scope => ids.harbor_details_deploy,
                    .exit_ghosts => ids.harbor_restart,
                    .motion => ids.harbor_chart,
                    .text_cache => ids.harbor_filter,
                    .idle => ids.harbor_timeline_toggle,
                    .effects => ids.harbor_deploy,
                    .semantics => ids.harbor_table_header,
                    .environment => ids.harbor_environment_readout,
                };
            }

            fn node(self: *Harbor, ui: *Ui, shell: *const Shell, feature: Feature, pulsing: bool) void {
                const palette = shell.palette;
                const id = nodeId(feature);
                const active = self.card_feature == feature or ui.hovered(id) or ui.focused(id);
                const pulse = if (pulsing) 0.5 + 0.5 * @sin(@as(f32, @floatCast(shell.seconds)) * 5 + @as(f32, @floatFromInt(@intFromEnum(feature)))) else 0;
                const glow: zui.Effects = .{ .shadow = .glow(palette.accent.mix(palette.background, 0.4 + 0.6 * (1 - pulse)), 2 + 6 * pulse) };
                var label_buffer: [4]u8 = undefined;
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .semantics = self.semantic(.{ .role = .button, .label = feature.title() }),
                    .floating = .{ .attach_to = .{ .element = nodeTarget(feature) }, .anchor = .center, .attach_point = .top_right, .z = 800, .clip = .target },
                    .layout = .{ .sizing = .{ .height = .fixed(18) }, .padding = .symmetric(5, 0), .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{
                        .background = if (active) palette.text else palette.accent.mix(palette.text, 0.35 * pulse),
                        .border = .{ .color = if (ui.focused(id)) palette.focus else palette.surface, .widths = .all(2) },
                        .corner_radius = .all(9),
                    },
                    .effects = if (pulsing) &glow else null,
                });
                defer ui.close();
                ui.text(std.fmt.bufPrint(&label_buffer, "{d}", .{@intFromEnum(feature) + 1}) catch "", .{ .size = 11 * shell.text_scale, .font = shell.fonts.bold, .color = if (active) palette.background else palette.on_accent, .wrap = .none });
            }

            fn outlines(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                _ = self;
                const regions_outlined = [_]struct { zui.Id, []const u8 }{
                    .{ ids.harbor_toolbar, "toolbar: row, grow × fit" },
                    .{ ids.harbor_kpis, "metrics: row of 4, grow_equal" },
                    .{ ids.harbor_services, "services: column, grow × grow" },
                    .{ ids.harbor_table_body, "rows: scrolls, virtual" },
                    .{ ids.harbor_details, "details: fixed 320, scrolls" },
                    .{ ids.harbor_events, "events: 38% of its column" },
                };
                for (regions_outlined, 0..) |region, index| {
                    const rect = ui.rectOf(region[0]) orelse continue;
                    ui.open(.{
                        .id = .indexed("harbor_outline", index),
                        .floating = .{ .attach_to = .{ .element = region[0] }, .z = 790, .capture = false },
                        .layout = .{ .sizing = .{ .width = .fixed(rect.width), .height = .fixed(rect.height) } },
                        .decoration = .{ .border = .{ .color = shell.palette.spectacle, .widths = .all(1) }, .corner_radius = .all(4) },
                    });
                    defer ui.close();
                    ui.open(.{
                        .floating = .{ .anchor = .top_left, .attach_point = .bottom_left, .offset = .{ 4, 0 }, .z = 790, .capture = false },
                        .layout = .{ .padding = .symmetric(6, 1) },
                        .decoration = .{ .background = shell.palette.spectacle, .corner_radius = .{ .bottom_left = 4, .bottom_right = 4 } },
                    });
                    ui.text(region[1], noWrap(shell.style(.tiny, shell.palette.on_accent)));
                    ui.close();
                }
            }

            fn featureCard(self: *Harbor, ui: *Ui, shell: *const Shell, feature: Feature) void {
                const palette = shell.palette;
                const node_rect = ui.rectOf(nodeId(feature)) orelse zui.Rect{};
                const viewport = ui.viewport();
                const opens_left = node_rect.x + node_rect.width / 2 > viewport[0] * 0.55;
                const opens_up = node_rect.y + node_rect.height / 2 > viewport[1] * 0.5;
                const anchor: zui.AnchorPoint = if (opens_up) (if (opens_left) .bottom_right else .bottom_left) else (if (opens_left) .top_right else .top_left);
                const attach_point: zui.AnchorPoint = if (opens_up) (if (opens_left) .top_left else .top_right) else (if (opens_left) .bottom_left else .bottom_right);
                const overlap: [2]f32 = .{ if (opens_left) 3 else -3, if (opens_up) 3 else -3 };
                ui.open(.{
                    .id = ids.harbor_xray_card,
                    .interactive = true,
                    .semantics = self.semantic(.{ .role = .group, .label = feature.title() }),
                    .floating = .{ .attach_to = .{ .element = nodeId(feature) }, .anchor = anchor, .attach_point = attach_point, .offset = overlap, .z = 810 },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(340) }, .padding = .all(14), .child_gap = 8 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.accent.mix(palette.border, 0.5), .widths = .all(1) }, .corner_radius = .all(8) },
                    .effects = &floating_shadow,
                });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.printColored(ui, .caption, palette.accent, "{d}", .{@intFromEnum(feature) + 1});
                    ui.text(feature.title(), noWrap(shell.style(.heading, palette.text)));
                    shell.spacer(ui);
                    shell.labelColored(ui, .tiny, palette.faint, if (self.pinned_feature == feature) "pinned · Esc" else "click to pin");
                }
                sectionLabel(ui, shell, "WHAT");
                self.featureWhat(ui, shell, feature);
                sectionLabel(ui, shell, "WHY IT MATTERS");
                shell.labelColored(ui, .caption, palette.muted, feature.why());
                sectionLabel(ui, shell, "LIVE PROOF, THIS FRAME");
                {
                    ui.open(.{
                        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(8), .child_gap = 3 },
                        .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) },
                    });
                    defer ui.close();
                    self.featureProof(ui, shell, feature);
                }
                self.featureTry(ui, shell, feature);
            }

            fn featureWhat(self: *Harbor, ui: *Ui, shell: *const Shell, feature: Feature) void {
                const palette = shell.palette;
                var count_buffer: [32]u8 = undefined;
                switch (feature) {
                    .virtual_scroll => shell.printColored(ui, .body, palette.text, "This table has {s} rows; {d} are declared this frame.", .{ withThousands(&count_buffer, self.shown_count), self.rows_declared }),
                    .latest_source => shell.labelColored(ui, .body, palette.text, "The metric tiles read a zui_async.Latest: the producer publishes the newest totals, and each frame reads one value."),
                    .stream_source => shell.labelColored(ui, .body, palette.text, "The events feed reads a zui_async.Stream: every item, in order, through a ring of 64."),
                    .demand => shell.labelColored(ui, .body, palette.text, "The metrics and events producers run only while a frame reads their sources."),
                    .anchors => shell.printColored(ui, .body, palette.text, "The environment list, the column tooltips, these {d} dots and this card float above the layout, each anchored to an element.", .{feature_count}),
                    .focus_scope => shell.labelColored(ui, .body, palette.text, "Deploy opens a dialog declared with focus_scope = true."),
                    .exit_ghosts => shell.labelColored(ui, .body, palette.text, "Toasts declare exit = .{ .seconds = 0.3 }: once no longer declared, their last commands keep drawing as they fade."),
                    .motion => shell.labelColored(ui, .body, palette.text, "The selected row's highlight and this chart's bars ease toward their targets, kept in ui.state."),
                    .text_cache => shell.labelColored(ui, .body, palette.text, "Every label is measured once and cached. The filter re-measures only names it has not shown before."),
                    .idle => shell.labelColored(ui, .body, palette.text, "zui declares a frame only for a reason: input, a source publishing, a timer coming due, or a request."),
                    .effects => shell.labelColored(ui, .body, palette.text, "The primary buttons carry a gradient, and floating panels a soft shadow."),
                    .semantics => shell.printColored(ui, .body, palette.text, "Rows, headers, buttons and the dialog declare a role and a label: {d} nodes this frame.", .{self.semantic_nodes}),
                    .environment => shell.labelColored(ui, .body, palette.text, "Direction, text size, contrast and motion come from the environment the host reports."),
                }
            }

            fn featureProof(self: *Harbor, ui: *Ui, shell: *const Shell, feature: Feature) void {
                const perf = shell.perf;
                const latest = perf.latest();
                var buffer: [32]u8 = undefined;
                switch (feature) {
                    .virtual_scroll => {
                        proofRow(ui, shell, "rows in the table", "{s}", .{withThousands(&buffer, self.shown_count)});
                        proofRow(ui, shell, "rows declared", "{d}", .{self.rows_declared});
                        proofRow(ui, shell, "content height", "{d:.0} px", .{@as(f32, @floatFromInt(self.shown_count)) * row_pitch});
                        proofRow(ui, shell, "scrolled to", "{d:.0} px", .{ui.scrollOffset(ids.harbor_table_body)[1]});
                        proofRow(ui, shell, "elements, last frame", "{d}", .{latest.elements});
                        proofRow(ui, shell, "declare, last frame", "{d:.1} us", .{latest.declare_us});
                    },
                    .latest_source => {
                        const published = if (self.metrics) |metrics| metrics.sample else 0;
                        proofRow(ui, shell, "values published", "{d}", .{published});
                        proofRow(ui, shell, "values the UI saw", "{d}", .{self.metrics_seen});
                        proofRow(ui, shell, "skipped, never queued", "{d}", .{published -| self.metrics_seen});
                        proofRow(ui, shell, "framesSinceRead", "{d}", .{ui.framesSinceRead(.harbor_metrics)});
                    },
                    .stream_source => {
                        proofRow(ui, shell, "events this frame", "{d}", .{self.events_this_frame});
                        proofRow(ui, shell, "events received", "{d}", .{self.events_received});
                        proofRow(ui, shell, "ring capacity", "{d}", .{64});
                        proofRow(ui, shell, "publishes refused", "{d}", .{perf.diagnostics.refused_publishes});
                    },
                    .demand => {
                        proofRow(ui, shell, "metrics producer", "{s}", .{phaseName(&self.metrics_producer)});
                        proofRow(ui, shell, "events producer", "{s}", .{phaseName(&self.events_producer)});
                        proofRow(ui, shell, "framesSinceRead(.harbor_metrics)", "{d}", .{ui.framesSinceRead(.harbor_metrics)});
                        proofRow(ui, shell, "framesSinceRead(.harbor_events)", "{d}", .{ui.framesSinceRead(.harbor_events)});
                        proofRow(ui, shell, "producer wakes", "{d}", .{perf.wakes});
                    },
                    .anchors => {
                        const anchor = ui.rectOf(ids.harbor_environment) orelse zui.Rect{};
                        proofRow(ui, shell, "anchor at", "{d:.0}, {d:.0}", .{ anchor.x, anchor.y });
                        proofRow(ui, shell, "anchor size", "{d:.0} x {d:.0}", .{ anchor.width, anchor.height });
                        proofRow(ui, shell, "tooltips shown", "{d}", .{self.tooltips_shown});
                        proofRow(ui, shell, "nodes floating", "{d}", .{feature_count});
                    },
                    .focus_scope => {
                        proofRow(ui, shell, "dialog open", "{s}", .{yesNo(self.dialog_open)});
                        proofRow(ui, shell, "Tab stops inside", "{d}", .{3});
                        proofRow(ui, shell, "Escape closes", "{s}", .{"ui.dismissed()"});
                    },
                    .exit_ghosts => {
                        var on_screen: u32 = 0;
                        for (self.toasts) |toast| on_screen += @intFromBool(toast.serial != 0 and ui.now().isBefore(toast.expires_at));
                        proofRow(ui, shell, "toasts declared", "{d}", .{on_screen});
                        proofRow(ui, shell, "ghost commands kept", "{d}", .{perf.diagnostics.needed.get(.exit_ghost_commands)});
                        if (Ui.keeps_exit_ghosts) {
                            proofRow(ui, shell, "ghost capacity", "{d}", .{Ui.limits.exit_ghost_commands});
                        } else {
                            proofRow(ui, shell, "ghost capacity", "{s}", .{"0: leaves at once"});
                        }
                    },
                    .motion => {
                        proofRow(ui, shell, "reduced motion", "{s}", .{yesNo(shell.reduced_motion)});
                        proofRow(ui, shell, "chart revealed", "{d:.0}%", .{self.chart_reveal * 100});
                        proofRow(ui, shell, "frames last second", "{d}", .{perf.frames_last_second});
                    },
                    .text_cache => {
                        proofRow(ui, shell, "texts measured, last frame", "{d}", .{latest.measure_calls});
                        proofRow(ui, shell, "texts measured since start", "{d}", .{perf.measure_calls_total});
                        proofRow(ui, shell, "measure cache entries", "{d}", .{Ui.limits.measure_cache_entries});
                        proofRow(ui, shell, "text scale", "{d:.0}%", .{shell.text_scale * 100});
                    },
                    .idle => {
                        proofRow(ui, shell, "frames in the last second", "{d}", .{perf.frames_last_second});
                        proofRow(ui, shell, "last frame because", "{s}", .{latest.reason.describe()});
                        switch (perf.next_frame) {
                            .immediately => proofRow(ui, shell, "next frame", "{s}", .{"immediately"}),
                            .at => proofRow(ui, shell, "next frame", "in {d:.2} s", .{perf.next_frame_seconds}),
                            .on_event => proofRow(ui, shell, "next frame", "{s}", .{"on input"}),
                        }
                        proofRow(ui, shell, "allocations after init", "{s}", .{"none, by design"});
                    },
                    .effects => {
                        proofRow(ui, shell, "renderer draws gradients", "{s}", .{yesNo(kit.config.commands.contains(.gradient))});
                        proofRow(ui, shell, "renderer draws shadows", "{s}", .{yesNo(kit.config.commands.contains(.shadow))});
                        var lowered_buffer: [64]u8 = undefined;
                        proofRow(ui, shell, "lowered, last frame", "{s}", .{describeCommands(&lowered_buffer, perf.diagnostics.lowered)});
                    },
                    .semantics => {
                        var name_buffer: [40]u8 = undefined;
                        proofRow(ui, shell, "semantic nodes", "{d}", .{self.semantic_nodes});
                        proofRow(ui, shell, "selected row", "{s}", .{serviceName(self.selected, &name_buffer)});
                        proofRow(ui, shell, "its role", "{s}", .{"option, selected"});
                    },
                    .environment => {
                        const environment = ui.environment();
                        proofRow(ui, shell, "direction", "{t}", .{environment.direction});
                        proofRow(ui, shell, "text scale", "{d:.0}%", .{environment.text_scale * 100});
                        proofRow(ui, shell, "contrast", "{t}", .{environment.contrast});
                        proofRow(ui, shell, "theme", "{t}", .{environment.theme});
                    },
                }
            }

            fn featureTry(self: *Harbor, ui: *Ui, shell: *const Shell, feature: Feature) void {
                const environment = ui.environment();
                const first: ?[]const u8, const second: ?[]const u8 = switch (feature) {
                    .virtual_scroll => .{ "Jump to row 4,000", null },
                    .latest_source => .{ "Publish 50 at once", null },
                    .stream_source => .{ "Burst of 40 events", null },
                    .focus_scope => .{ "Open the dialog", null },
                    .exit_ghosts => .{ "Show a toast", null },
                    .motion => .{ if (environment.reduced_motion) "Allow motion" else "Reduce motion", null },
                    .text_cache => .{ if (environment.text_scale > 1.5) "Text at 100%" else "Text at 200%", null },
                    .idle => .{ if (self.show_timeline) "Hide the timeline" else "Show the timeline", null },
                    .environment => .{
                        if (environment.direction == .left_to_right) "Right to left" else "Left to right",
                        if (environment.contrast == .normal) "High contrast" else "Normal contrast",
                    },
                    .demand, .anchors, .effects, .semantics => .{ null, null },
                };
                if (first == null) return;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                defer ui.close();
                shell.spacer(ui);
                if (second) |label| if (shell.widgets.button(ui, ids.harbor_xray_try_second, label, .{})) {
                    if (self.environment_restore.contrast == null) self.environment_restore.contrast = environment.contrast;
                    shell.changeEnvironment(.{ .contrast = if (environment.contrast == .normal) .high else .normal });
                };
                if (!primaryButton(self, ui, shell, ids.harbor_xray_try, first.?)) return;
                switch (feature) {
                    .virtual_scroll => {
                        const position: usize = @min(3999, self.shown_count -| 1);
                        if (self.shown_count != 0) self.select(self.shown[position]);
                        ui.setScrollOffset(ids.harbor_table_body, .{ 0, @as(f32, @floatFromInt(position)) * row_pitch });
                    },
                    .latest_source => _ = self.latest_burst_requested.fetchAdd(latest_burst_size, .monotonic),
                    .stream_source => {
                        self.bursts += 1;
                        self.tasks.concurrent(shell.io, publishBurst, .{ &shell.sources.harbor_events, shell.waker, self.bursts }) catch publishBurst(&shell.sources.harbor_events, shell.waker, self.bursts);
                    },
                    .focus_scope => self.openDialog(ui),
                    .exit_ghosts => self.showToast(ui, .info, "A toast, declared for {d:.1} s", .{toast_seconds}),
                    .motion => {
                        if (self.environment_restore.reduced_motion == null) self.environment_restore.reduced_motion = environment.reduced_motion;
                        shell.changeEnvironment(.{ .reduced_motion = !environment.reduced_motion });
                    },
                    .text_cache => {
                        if (self.environment_restore.text_scale == null) self.environment_restore.text_scale = environment.text_scale;
                        shell.changeEnvironment(.{ .text_scale = if (environment.text_scale > 1.5) 1 else 2 });
                    },
                    .idle => self.show_timeline = !self.show_timeline,
                    .environment => {
                        if (self.environment_restore.direction == null) self.environment_restore.direction = environment.direction;
                        shell.changeEnvironment(.{ .direction = if (environment.direction == .left_to_right) .right_to_left else .left_to_right });
                    },
                    .demand, .anchors, .effects, .semantics => {},
                }
            }

            fn produceMetrics(io: std.Io, producer: *DemandedProducer, source: *MetricsSource, waker: zui.Waker, starting: Metrics, healthy_baseline: u32, burst_requested: *std.atomic.Value(u32)) std.Io.Cancelable!void {
                var prng: std.Random.DefaultPrng = .init(0x4A2B0 +% starting.sample);
                const random = prng.random();
                var reading = starting;
                while (producer.keepGoing()) {
                    const extra = burst_requested.swap(0, .monotonic);
                    for (0..extra + 1) |_| {
                        reading.sample += 1;
                        reading.requests_per_second = std.math.clamp(reading.requests_per_second + random.floatNorm(f32) * 160 + (12_400 - reading.requests_per_second) * 0.08, 8_000, 17_000);
                        reading.error_percent = std.math.clamp(reading.error_percent + random.floatNorm(f32) * 0.03 + (0.4 - reading.error_percent) * 0.1, 0.05, 3);
                        reading.p95_milliseconds = std.math.clamp(reading.p95_milliseconds + random.floatNorm(f32) * 5 + (180 - reading.p95_milliseconds) * 0.1, 90, 420);
                        const flapping = random.uintLessThan(u32, 9);
                        reading.healthy_services = healthy_baseline -| flapping;
                        waker.wakeIf(source.publish(reading));
                    }
                    try io.sleep(.fromMilliseconds(250), .awake);
                }
            }

            fn produceEvents(io: std.Io, producer: *DemandedProducer, source: *EventSource, waker: zui.Waker, seed: u64) std.Io.Cancelable!void {
                var prng: std.Random.DefaultPrng = .init(0xE7E47 +% seed);
                const random = prng.random();
                var quarter_seconds_left: u32 = 2;
                while (producer.keepGoing()) {
                    if (quarter_seconds_left == 0) {
                        waker.wakeIf(source.publish(randomEvent(random)) catch .already_pending);
                        quarter_seconds_left = 3 + random.uintLessThan(u32, 8);
                    }
                    quarter_seconds_left -= 1;
                    try io.sleep(.fromMilliseconds(250), .awake);
                }
            }

            fn publishBurst(source: *EventSource, waker: zui.Waker, burst: u32) void {
                for (0..burst_size) |index| {
                    var name_buffer: [40]u8 = undefined;
                    const service: u16 = @intCast(mixBits(@as(u64, burst) * 131 + index) % service_count);
                    const event: Event = .init(.info, "Burst {d}: health check {d}/{d} passed for {s}", .{ burst, index + 1, burst_size, serviceName(service, &name_buffer) });
                    waker.wakeIf(source.publish(event) catch .already_pending);
                }
            }
        };

        fn randomEvent(random: std.Random) Event {
            var name_buffer: [40]u8 = undefined;
            const service: u16 = @intCast(random.uintLessThan(u32, service_count));
            const name = serviceName(service, &name_buffer);
            const region = regions[random.uintLessThan(u32, regions.len)];
            return switch (random.uintLessThan(u32, 10)) {
                0, 1, 2 => .init(.info, "{s} scaled to {d} replicas", .{ name, 3 + random.uintLessThan(u32, 9) }),
                3 => .init(.warn, "{s} p95 above 400 ms for 2 minutes", .{name}),
                4 => .init(.info, "Autoscaler added {d} nodes in {s}", .{ 1 + random.uintLessThan(u32, 4), region }),
                5 => .init(.critical, "{s} failed 3 health checks in {s}", .{ name, region }),
                6 => .init(.info, "Certificate renewed for {s}", .{name}),
                7 => .init(.warn, "{s} error rate at {d}.{d}%", .{ name, 1 + random.uintLessThan(u32, 4), random.uintLessThan(u32, 10) }),
                else => .init(.info, "Deploy finished: {s} v2.{d}.{d}", .{ name, 8 + random.uintLessThan(u32, 12), random.uintLessThan(u32, 10) }),
            };
        }

        const Eased = struct { value: f32, initialized: bool };

        /// Moves the value kept for `id` a frame's share of the way to `target`, asking for frames until it lands.
        fn easeToward(ui: *Ui, id: zui.Id, target: f32, rate: f32) f32 {
            const eased = ui.state(id, Eased);
            if (!eased.initialized or ui.environment().reduced_motion) {
                eased.* = .{ .value = target, .initialized = true };
                return target;
            }
            const remaining = target - eased.value;
            if (@abs(remaining) < 0.003) {
                eased.value = target;
                return target;
            }
            // A long idle gap before this frame was spent at rest, not moving.
            const step_seconds = @min(ui.dt(), 1.0 / 30.0);
            eased.value += remaining * (1 - @exp(-rate * step_seconds));
            ui.requestFrame();
            return eased.value;
        }

        fn noWrap(text_style: kit.TextStyle) kit.TextStyle {
            var single_line = text_style;
            single_line.wrap = .none;
            return single_line;
        }

        fn primaryButton(harbor: *Harbor, ui: *Ui, shell: *const Shell, id: zui.Id, content: []const u8) bool {
            const palette = shell.palette;
            const state = ui.widgetState(id);
            const base = switch (state) {
                .hovered => palette.accent.mix(palette.text, 0.12),
                .pressed => palette.accent.mix(palette.background, 0.2),
                else => palette.accent,
            };
            const effects: zui.Effects = .{
                .gradient = .{ .from = base.mix(.white, 0.14), .to = base, .angle = std.math.pi / 2.0 },
                .shadow = .{ .color = .rgba(0x00000030), .offset = .{ 0, 1 }, .blur = 3 },
            };
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = harbor.semantic(.{ .role = .button, .label = content }),
                .layout = .{ .sizing = .{ .height = .fixed(@round(30 * shell.text_scale)) }, .padding = .symmetric(14, 0), .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{
                    .background = base,
                    .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(2) } else null,
                    .corner_radius = .all(6),
                },
                .effects = &effects,
            });
            ui.text(content, noWrap(shell.style(.body, palette.on_accent)));
            ui.close();
            return ui.clicked(id);
        }

        fn statusColor(palette: kit.Palette, status: Status) zui.Color {
            return switch (status) {
                .healthy => palette.good,
                .degraded => palette.warn,
                .down => palette.bad,
            };
        }

        fn severityColor(palette: kit.Palette, severity: Severity) zui.Color {
            return switch (severity) {
                .info => palette.accent,
                .warn => palette.warn,
                .critical => palette.bad,
            };
        }

        fn statusChip(ui: *Ui, shell: *const Shell, content: []const u8, color: zui.Color) void {
            ui.open(.{
                .layout = .{ .padding = .symmetric(8, 2), .child_gap = 6, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = color.mix(shell.palette.surface, 0.86), .corner_radius = .all(9) },
            });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(6), .height = .fixed(6) } }, .decoration = .{ .background = color, .corner_radius = .all(3) } });
            ui.text(content, noWrap(shell.style(.tiny, color)));
        }

        fn miniStat(ui: *Ui, shell: *const Shell, name: []const u8, value: []const u8) void {
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal }, .padding = .symmetric(8, 6), .child_gap = 2 },
                .decoration = .{ .background = shell.palette.sunken, .corner_radius = .all(6) },
            });
            defer ui.close();
            ui.text(name, noWrap(shell.style(.tiny, shell.palette.muted)));
            ui.text(value, noWrap(shell.style(.body, shell.palette.text)));
        }

        fn sectionLabel(ui: *Ui, shell: *const Shell, content: []const u8) void {
            ui.text(content, noWrap(shell.style(.tiny, shell.palette.accent)));
        }

        fn proofRow(ui: *Ui, shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
            defer ui.close();
            ui.text(name, noWrap(shell.style(.caption, shell.palette.muted)));
            shell.spacer(ui);
            var buffer: [64]u8 = undefined;
            ui.text(std.fmt.bufPrint(&buffer, format, arguments) catch format, .{ .size = 12 * shell.text_scale, .font = shell.fonts.mono, .color = shell.palette.text, .wrap = .none });
        }

        fn yesNo(value: bool) []const u8 {
            return if (value) "yes" else "no";
        }

        fn phaseName(producer: *const DemandedProducer) []const u8 {
            return @tagName(producer.phase.load(.acquire));
        }

        fn describeCommands(buffer: *[64]u8, commands: zui.CommandSet) []const u8 {
            if (commands.count() == 0) return "nothing";
            var length: usize = 0;
            var iterator = commands.iterator();
            while (iterator.next()) |command| {
                const name = @tagName(command);
                const separator: []const u8 = if (length == 0) "" else ", ";
                if (length + separator.len + name.len > buffer.len) break;
                @memcpy(buffer[length..][0..separator.len], separator);
                length += separator.len;
                @memcpy(buffer[length..][0..name.len], name);
                length += name.len;
            }
            return buffer[0..length];
        }

        /// Why each of the last 120 frames was declared, one bar each, colored by the reason.
        fn frameTimeline(ui: *Ui, shell: *const Shell) void {
            const palette = shell.palette;
            const perf = shell.perf;
            ui.open(.{
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(12, 6), .child_gap = 16, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
            });
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(24) }, .child_gap = 1, .child_alignment = .{ .y = .end } } });
                defer ui.close();
                var tallest: f32 = 50;
                for (perf.history) |sample| tallest = @max(tallest, sample.totalMicroseconds());
                for (0..kit.Perf.history_length) |age| {
                    const sample = perf.sampleAt(age);
                    ui.box(.{
                        .layout = .{ .sizing = .{ .width = .{ .rule = .grow_from_min, .amount = 1, .max = 4 }, .height = .fixed(@max(3, 24 * sample.totalMicroseconds() / tallest)) } },
                        .decoration = .{ .background = reasonColor(palette, sample.reason) },
                    });
                }
            }
            for ([_]FrameReason{ .input, .source, .timer, .requested, .resize }) |reason| {
                ui.open(.{ .layout = .{ .child_gap = 4, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = reasonColor(palette, reason), .corner_radius = .all(2) } });
                ui.text(@tagName(reason), noWrap(shell.style(.tiny, palette.muted)));
            }
        }

        fn reasonColor(palette: kit.Palette, reason: FrameReason) zui.Color {
            return switch (reason) {
                .first => palette.faint,
                .input => palette.accent,
                .resize => palette.muted,
                .requested => palette.spectacle,
                .timer => palette.warn,
                .source => palette.good,
            };
        }
    };
}
