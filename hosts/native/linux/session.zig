const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;
const desktop_bus = @import("desktop_bus.zig");
const services = @import("services.zig");
const file_watch = @import("file_watch.zig");
const Inbox = @import("inbox.zig").Inbox;

/// What the desktop's buses have said, which every window reports.
pub const DesktopSettings = struct {
    theme: zui.Environment.Theme = .light,
    contrast: zui.Environment.Contrast = .normal,
    reduced_motion: bool = false,
    reduced_transparency: bool = false,
    on_battery: bool = false,
    power_saver: bool = false,
    accent: ?zui.Color = null,

    pub fn power(self: DesktopSettings) zui.Environment.Power {
        return if (self.power_saver) .saver else if (self.on_battery) .battery else .plugged;
    }
};

/// The fields of `zui.Environment` a Linux host reports: the desktop's
/// settings, and what the window manager decides about each window.
pub const ReportedEnvironment = struct {
    theme: zui.Environment.Theme,
    contrast: zui.Environment.Contrast,
    reduced_motion: bool,
    reduced_transparency: bool,
    power: zui.Environment.Power,
    system_material: bool,
    custom_title_bar: bool,
    window_maximized: bool,
    accent: ?zui.Color,

    /// The desktop's part of it, beside the window's.
    pub fn of(settings: DesktopSettings, window: WindowFacts) ReportedEnvironment {
        return .{
            .theme = settings.theme,
            .contrast = settings.contrast,
            .reduced_motion = settings.reduced_motion,
            .reduced_transparency = settings.reduced_transparency,
            .power = settings.power(),
            .system_material = window.shows_material and !settings.reduced_transparency,
            .custom_title_bar = window.custom_title_bar,
            .window_maximized = window.maximized,
            .accent = settings.accent,
        };
    }

    pub const WindowFacts = struct { shows_material: bool = false, custom_title_bar: bool = false, maximized: bool = false };

    /// Pushes a change for each field of `current` that differs from
    /// `reported`, or for every field when nothing was reported yet; true
    /// when it pushed one.
    pub fn deliverChanges(reported: ?ReportedEnvironment, current: ReportedEnvironment, inbox: *Inbox) bool {
        var changed = false;
        inline for (std.meta.fields(ReportedEnvironment)) |field| {
            const value = @field(current, field.name);
            if (reported == null or !std.meta.eql(@field(reported.?, field.name), value)) {
                inbox.push(.{ .environment = @unionInit(zui.EnvironmentChange, field.name, value) });
                changed = true;
            }
        }
        return changed;
    }
};

/// What a Linux host holds whichever display server it shows its windows
/// on: the wake, SIGINT, SIGTERM and SIGHUP as terminate requests, the
/// desktop's settings over D-Bus, the services and the watches. It must
/// not move after `open`, since the signal handler holds a pointer to it.
pub const Session = struct {
    io: std.Io,
    /// An eventfd: any thread writes it, and the wait reads it after it
    /// returns, so a wake that came before the wait ends it.
    wake_fd: i32,
    desktop: desktop_bus.DesktopBus = .{},
    settings: DesktopSettings = .{},
    services: services.Services,
    file_watches: file_watch.Watches = .{},

    /// Set by the signal handler, and taken by the next poll.
    termination_signalled: std.atomic.Value(bool) = .init(false),
    /// For each of `termination_signals`, whether this session handles it,
    /// and what `close` gives it back.
    handled_signals: [termination_signals.len]bool = @splat(false),
    replaced_signal_actions: [termination_signals.len]std.posix.Sigaction = undefined,

    /// How long `readDesktop` waits for the desktop's settings, so the
    /// first frame has them; later answers arrive as changes.
    pub const desktop_answer_ns = 250 * std.time.ns_per_ms;
    const termination_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };

    /// The descriptors `pollDescriptors` gives, which a host waits on
    /// beside its display's.
    pub const descriptor_count = 5;

    pub fn open(self: *Session, io: std.Io, service_fake: ?*services.ServiceFake) error{NoWakeEvent}!void {
        self.* = .{ .io = io, .wake_fd = undefined, .services = .{ .fake = service_fake } };
        const wake_fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wake_fd) != .SUCCESS) return error.NoWakeEvent;
        self.wake_fd = @intCast(wake_fd);
    }

    pub fn close(self: *Session) void {
        self.restoreTerminationSignals();
        self.services.close(self.io);
        self.desktop.close();
        self.file_watches.stopAll();
        _ = linux.close(self.wake_fd);
    }

    pub fn now(self: *const Session) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    pub fn waker(self: *Session) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    fn wake(context: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    pub fn clearWake(self: *Session) void {
        var count: u64 = 0;
        _ = linux.read(self.wake_fd, std.mem.asBytes(&count), @sizeOf(u64));
    }

    /// Connects to the desktop's buses, `addresses` or the environment's
    /// for null, and waits up to `desktop_answer_ns` for their answers,
    /// each reaching `listener.onDesktopReport(report)`.
    pub fn readDesktop(self: *Session, addresses: ?desktop_bus.Addresses, listener: anytype) void {
        var session_address: [256]u8 = undefined;
        const chosen = addresses orelse desktop_bus.DesktopBus.addressesFromEnvironment(&session_address);
        self.readDesktopUntil(chosen, listener, self.now().addNanoseconds(desktop_answer_ns));
    }

    /// `readDesktop` at `chosen`, waiting no later than `deadline`, for a
    /// host that connects to the session bus for more and waits for all of
    /// it at once.
    pub fn readDesktopUntil(self: *Session, chosen: desktop_bus.Addresses, listener: anytype, deadline: zui.Instant) void {
        self.desktop.open(self.io, chosen, deadline);
        if (chosen.session) |session| self.services.open(self.io, session, deadline);
        while (self.desktop.awaitingReplies()) {
            const remaining_ns = deadline.nanoseconds -| self.now().nanoseconds;
            if (remaining_ns == 0) break;
            const bus_fds = self.desktop.descriptors();
            var descriptors = [_]linux.pollfd{
                .{ .fd = bus_fds[0], .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = bus_fds[1], .events = linux.POLL.IN, .revents = 0 },
            };
            var timeout = timespecOf(remaining_ns);
            _ = linux.ppoll(&descriptors, descriptors.len, &timeout, null);
            self.desktop.receive(listener);
        }
    }

    /// Takes a report into the settings, or returns the lifecycle change it
    /// is, which every window should receive.
    pub fn settle(self: *Session, report: desktop_bus.Report) ?zui.Lifecycle {
        const settings = &self.settings;
        switch (report) {
            .theme => |theme| settings.theme = theme,
            .contrast => |contrast| settings.contrast = contrast,
            .reduced_motion => |reduced_motion| settings.reduced_motion = reduced_motion,
            .reduced_transparency => |reduced_transparency| settings.reduced_transparency = reduced_transparency,
            .on_battery => |on_battery| settings.on_battery = on_battery,
            .power_saver => |power_saver| settings.power_saver = power_saver,
            .accent => |accent| settings.accent = accent,
            .preparing_for_sleep => |sleeping| return if (sleeping) .@"suspend" else .@"resume",
        }
        return null;
    }

    /// Publishes the services' answers that need no bus, before a wait.
    pub fn publishPending(self: *Session) void {
        self.services.publishPending(self.io, self.waker());
    }

    /// The wake, the desktop's buses, the watches and the services, in
    /// the order `receive` reads them.
    pub fn pollDescriptors(self: *const Session) [descriptor_count]linux.pollfd {
        const bus_fds = self.desktop.descriptors();
        return .{
            .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = bus_fds[0], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = bus_fds[1], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.file_watches.descriptor(), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.services.descriptor(), .events = linux.POLL.IN, .revents = 0 },
        };
    }

    /// Reads what `polled`, as `pollDescriptors` gave them, found ready,
    /// the desktop's reports reaching `listener.onDesktopReport(report)`;
    /// true when the wake was written.
    pub fn receive(self: *Session, polled: [descriptor_count]linux.pollfd, listener: anytype) bool {
        if (polled[1].revents | polled[2].revents != 0) self.desktop.receive(listener);
        if (polled[3].revents != 0) self.file_watches.receive();
        if (polled[4].revents != 0) self.services.receive(self.io, self.waker());
        return polled[0].revents & linux.POLL.IN != 0;
    }

    pub fn timespecOf(nanoseconds: u64) linux.timespec {
        return .{ .sec = @intCast(nanoseconds / std.time.ns_per_s), .nsec = @intCast(nanoseconds % std.time.ns_per_s) };
    }

    /// Leaves alone a signal the application handles or ignores. Each
    /// handler is reset as it runs, so a second Ctrl+C ends a process that
    /// did not end at the first.
    pub fn handleTerminationSignals(self: *Session) void {
        if (signalled_session.cmpxchgStrong(null, self, .acq_rel, .monotonic) != null) return;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onTerminationSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESETHAND,
        };
        for (termination_signals, &self.handled_signals, &self.replaced_signal_actions) |signal, *handled, *replaced| {
            std.posix.sigaction(signal, null, replaced);
            handled.* = replaced.handler.handler == std.posix.SIG.DFL;
            if (handled.*) std.posix.sigaction(signal, &action, null);
        }
    }

    fn restoreTerminationSignals(self: *Session) void {
        if (signalled_session.load(.acquire) != self) return;
        for (termination_signals, self.handled_signals, &self.replaced_signal_actions) |signal, handled, *replaced| {
            if (handled) std.posix.sigaction(signal, replaced, null);
        }
        signalled_session.store(null, .release);
    }

    /// Whether this session turns `signal` into a terminate request.
    pub fn handlesSignal(self: *const Session, signal: std.posix.SIG) bool {
        if (signalled_session.load(.acquire) != self) return false;
        for (termination_signals, self.handled_signals) |handled_signal, handled| if (handled_signal == signal) return handled;
        return false;
    }

    /// True once after a termination signal arrived.
    pub fn takeTerminationSignal(self: *Session) bool {
        return self.termination_signalled.swap(false, .acq_rel);
    }
};

/// A signal handler has no context, so it reaches the session that
/// installed it through here.
var signalled_session: std.atomic.Value(?*Session) = .init(null);

/// Only sets a flag and wakes, which a signal handler may do.
fn onTerminationSignal(_: std.posix.SIG) callconv(.c) void {
    const session = signalled_session.load(.acquire) orelse return;
    session.termination_signalled.store(true, .release);
    Session.wake(session);
}
