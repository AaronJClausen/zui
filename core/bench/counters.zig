//! Hardware counters for the calling thread, through Linux's
//! `perf_event_open`: one group, counting in user mode only, switched on
//! and off around each phase the way `counts` toggles Callgrind.

const std = @import("std");
const builtin = @import("builtin");

pub const Event = enum {
    cycles,
    instructions,
    branch_misses,
    l1d_read_misses,
    last_level_misses,

    /// The suffix of the event's keys in the benchmark's JSON, and its
    /// column in the counters table.
    pub fn label(event: Event) []const u8 {
        return switch (event) {
            .cycles => "cycles",
            .instructions => "instructions",
            .branch_misses => "branch misses",
            .l1d_read_misses => "L1D read misses",
            .last_level_misses => "LL misses",
        };
    }
};

pub const event_count = std.enums.values(Event).len;

/// One phase's count of each event.
pub const Counts = [event_count]u64;

pub const supported = builtin.os.tag == .linux;

/// Where counters come from on each platform this cannot count on.
pub const alternatives = switch (builtin.os.tag) {
    .windows => "Windows has no public user-mode API for them: use Windows Performance Recorder with counter sources (`wpr -pmcsources`), Intel VTune or AMD uProf",
    .macos => "on macOS they come from kperf, which needs root, as the macOS fork of poop reads them",
    else => "they need Linux on bare metal (WSL2, Docker on Windows and GitHub's hosted runners hide them)",
};

pub const Group = if (supported) LinuxGroup else UnsupportedGroup;

pub const OpenError = error{ Unsupported, CountersNotPermitted, CounterUnavailable };
pub const ReadError = error{ Unsupported, CounterReadFailed, CountersMultiplexed };

const UnsupportedGroup = struct {
    pub fn open() OpenError!UnsupportedGroup {
        return error.Unsupported;
    }
    pub fn close(_: *UnsupportedGroup) void {}
    pub fn start(_: *UnsupportedGroup) void {}
    pub fn stop(_: *UnsupportedGroup) void {}
    pub fn read(_: *UnsupportedGroup) ReadError!Counts {
        return error.Unsupported;
    }
};

const LinuxGroup = struct {
    const linux = std.os.linux;
    const PERF = linux.PERF;

    /// The leader first: enabling, disabling and reading it acts on all.
    descriptors: [event_count]linux.fd_t,

    const read_format_group = 1 << 3;
    const read_format_total_time_enabled = 1 << 0;
    const read_format_total_time_running = 1 << 1;

    fn config(event: Event) struct { PERF.TYPE, u64 } {
        const cache = PERF.COUNT.HW.CACHE;
        const read_miss = @intFromEnum(cache.OP.READ) << 8 | @intFromEnum(cache.RESULT.MISS) << 16;
        return switch (event) {
            .cycles => .{ .HARDWARE, @intFromEnum(PERF.COUNT.HW.CPU_CYCLES) },
            .instructions => .{ .HARDWARE, @intFromEnum(PERF.COUNT.HW.INSTRUCTIONS) },
            .branch_misses => .{ .HARDWARE, @intFromEnum(PERF.COUNT.HW.BRANCH_MISSES) },
            .l1d_read_misses => .{ .HW_CACHE, @intFromEnum(cache.L1D) | read_miss },
            .last_level_misses => .{ .HARDWARE, @intFromEnum(PERF.COUNT.HW.CACHE_MISSES) },
        };
    }

    /// Opens the group on the calling thread, switched off.
    pub fn open() OpenError!LinuxGroup {
        var group: LinuxGroup = .{ .descriptors = @splat(-1) };
        errdefer group.close();
        for (std.enums.values(Event), 0..) |event, index| {
            const kind, const event_config = config(event);
            var attributes: linux.perf_event_attr = .{
                .type = kind,
                .config = event_config,
                .read_format = read_format_group | read_format_total_time_enabled | read_format_total_time_running,
                .flags = .{ .disabled = index == 0, .exclude_kernel = true, .exclude_hv = true },
            };
            const leader = if (index == 0) -1 else group.descriptors[0];
            const result = linux.perf_event_open(&attributes, 0, -1, leader, PERF.FLAG.FD_CLOEXEC);
            switch (linux.errno(result)) {
                .SUCCESS => group.descriptors[index] = @intCast(result),
                .ACCES, .PERM => return error.CountersNotPermitted,
                .NOENT, .OPNOTSUPP, .NODEV => return error.CounterUnavailable,
                else => |errno| {
                    std.debug.print("perf_event_open for {s} failed: {t}\n", .{ event.label(), errno });
                    return error.CounterUnavailable;
                },
            }
        }
        return group;
    }

    pub fn close(group: *LinuxGroup) void {
        for (group.descriptors) |descriptor| {
            if (descriptor >= 0) _ = linux.close(descriptor);
        }
    }

    /// Zeroes the counts and starts counting.
    pub fn start(group: *LinuxGroup) void {
        _ = linux.ioctl(group.descriptors[0], PERF.EVENT_IOC.RESET, PERF.IOC_FLAG_GROUP);
        _ = linux.ioctl(group.descriptors[0], PERF.EVENT_IOC.ENABLE, PERF.IOC_FLAG_GROUP);
    }

    pub fn stop(group: *LinuxGroup) void {
        _ = linux.ioctl(group.descriptors[0], PERF.EVENT_IOC.DISABLE, PERF.IOC_FLAG_GROUP);
    }

    /// The counts since `start`. Refuses them if the kernel had to share
    /// the hardware counters between events, which scales the counts
    /// from a sample of the time.
    pub fn read(group: *LinuxGroup) ReadError!Counts {
        var buffer: extern struct {
            event_count: u64,
            time_enabled: u64,
            time_running: u64,
            values: Counts,
        } = undefined;
        const result = linux.read(group.descriptors[0], @ptrCast(&buffer), @sizeOf(@TypeOf(buffer)));
        if (linux.errno(result) != .SUCCESS or result != @sizeOf(@TypeOf(buffer)) or buffer.event_count != event_count) return error.CounterReadFailed;
        if (buffer.time_running < buffer.time_enabled) return error.CountersMultiplexed;
        return buffer.values;
    }
};
