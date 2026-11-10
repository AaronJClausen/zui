const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Turbo = enum { on, off, unknown };

/// The state of the machine a benchmark ran under: what decides whether
/// two measurements can be compared.
pub const Machine = struct {
    os: []const u8,
    /// Linux: the kernel release; Windows: major.minor.build; macOS: the
    /// product version.
    os_version: ?[]const u8 = null,
    cpu: []const u8,
    /// x86: the CPUID vendor (`GenuineIntel`, `AuthenticAMD`); elsewhere
    /// what the platform names, if anything.
    cpu_vendor: ?[]const u8 = null,
    logical_cpus: u32,
    physical_cores: ?u32 = null,
    /// One core's level 1 data cache, its level 2 cache, and the shared
    /// level 3, in KiB.
    l1d_kib: ?u32 = null,
    l2_kib: ?u32 = null,
    l3_kib: ?u32 = null,
    /// What the reading executable was built for: an architecture, OS and
    /// ABI, and the CPU model its code may assume.
    target: []const u8 = target_triple,
    built_for_cpu: []const u8 = builtin.cpu.model.name,
    /// The commit whose benchmark produced a result; null for the machine
    /// state `bench-compare` records, which covers two commits.
    commit: ?[]const u8 = null,
    pinned_core: ?u32 = null,
    turbo: Turbo = .unknown,
    /// Windows: the active power plan's name.
    power_plan: ?[]const u8 = null,
    /// Windows: `PROCTHROTTLEMAX`, the plan's maximum processor state.
    processor_cap_percent: ?u32 = null,
    /// Windows: `PERFBOOSTMODE`; 0 turns Turbo Boost off.
    boost_mode: ?u32 = null,
    clock_mhz: ?u32 = null,
    max_clock_mhz: ?u32 = null,
    /// Linux: the pinned core's (or core 0's) cpufreq governor.
    governor: ?[]const u8 = null,
    /// Linux: the logical CPUs sharing the pinned core, as `thread_siblings_list` gives them.
    sibling_cores: ?[]const u8 = null,
    /// Linux: `randomize_va_space`; 0 turns address randomization off.
    address_randomization: ?u32 = null,

    /// The fields that may change from one run to the next without the
    /// machine's setup changing; the commit is what is measured, not where.
    const readings = [_][]const u8{ "clock_mhz", "commit" };

    /// Names each setting that differs between `a` and `b`, ignoring the
    /// clock, which moves on its own.
    pub fn differingSettings(a: *const Machine, b: *const Machine, names: *[@typeInfo(Machine).@"struct".fields.len][]const u8) []const []const u8 {
        var count: usize = 0;
        inline for (@typeInfo(Machine).@"struct".fields) |field| {
            const is_reading = comptime for (readings) |reading| {
                if (std.mem.eql(u8, reading, field.name)) break true;
            } else false;
            if (!is_reading and !fieldEql(field.type, @field(a, field.name), @field(b, field.name))) {
                names[count] = field.name;
                count += 1;
            }
        }
        return names[0..count];
    }

    /// Why this machine is too noisy for `--require-quiet`, or null.
    pub fn noisyReason(machine: *const Machine) ?[]const u8 {
        if (machine.turbo == .on) return "turbo is on";
        if (machine.governor) |governor| {
            if (!std.mem.eql(u8, governor, "performance")) return "the cpufreq governor is not \"performance\"";
        }
        return null;
    }

    /// Identifies the machine's setup, readings excluded: results with the
    /// same fingerprint were taken under the same conditions.
    pub fn fingerprint(machine: *const Machine) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        inline for (@typeInfo(Machine).@"struct".fields) |field| {
            const is_reading = comptime for (readings) |reading| {
                if (std.mem.eql(u8, reading, field.name)) break true;
            } else false;
            if (!is_reading) hashField(&hasher, field.type, @field(machine, field.name));
        }
        return hasher.final();
    }

    pub fn writeJson(machine: *const Machine, writer: *Io.Writer) !void {
        try std.json.Stringify.value(machine.*, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, writer);
        try writer.writeByte('\n');
    }

    pub fn print(machine: *const Machine, out: *Io.Writer) !void {
        try out.print("{s}", .{machine.os});
        if (machine.os_version) |version| try out.print(" {s}", .{version});
        try out.print(", {s}, {d} logical CPUs", .{ machine.cpu, machine.logical_cpus });
        if (machine.pinned_core) |core| try out.print(", pinned to {d}", .{core}) else try out.writeAll(", not pinned");
        try out.print(", turbo {s}", .{@tagName(machine.turbo)});
        if (machine.power_plan) |plan| try out.print(", \"{s}\" plan", .{plan});
        if (machine.processor_cap_percent) |cap| try out.print(", cap {d}%", .{cap});
        if (machine.governor) |governor| try out.print(", {s} governor", .{governor});
        if (machine.sibling_cores) |siblings| try out.print(", siblings {s}", .{siblings});
        if (machine.address_randomization) |aslr| try out.print(", randomize_va_space {d}", .{aslr});
        if (machine.clock_mhz) |mhz| try out.print(", {d} MHz", .{mhz});
        if (machine.max_clock_mhz) |mhz| try out.print(" of {d}", .{mhz});
    }
};

const target_triple = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);

fn fieldEql(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| if (a == null or b == null) a == null and b == null else fieldEql(optional.child, a.?, b.?),
        .pointer => std.mem.eql(u8, a, b),
        else => a == b,
    };
}

fn hashField(hasher: *std.hash.Wyhash, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            hasher.update(&.{@intFromBool(value != null)});
            if (value) |present| hashField(hasher, optional.child, present);
        },
        .pointer => {
            hasher.update(value);
            hasher.update(&.{0});
        },
        .@"enum" => hasher.update(@tagName(value)),
        else => hasher.update(std.mem.asBytes(&value)),
    }
}

pub const PinError = error{ PinningUnsupported, CoreUnavailable };

pub const PinScope = enum {
    /// The calling thread only; threads it starts later run anywhere on Windows.
    thread,
    /// The whole process, and every process it starts.
    process,
};

pub fn pinToCore(core: u32, scope: PinScope) PinError!void {
    switch (builtin.os.tag) {
        .windows => {
            if (core >= @bitSizeOf(usize)) return error.CoreUnavailable;
            const mask = @as(usize, 1) << @intCast(core);
            const pinned = switch (scope) {
                .thread => win.SetThreadAffinityMask(std.os.windows.GetCurrentThread(), mask) != 0,
                .process => win.SetProcessAffinityMask(std.os.windows.GetCurrentProcess(), mask).toBool(),
            };
            if (!pinned) return error.CoreUnavailable;
        },
        // Linux applies affinity to the calling thread, and every thread or
        // process it starts afterwards inherits it, so both scopes are one call.
        .linux => {
            var set: std.os.linux.cpu_set_t = @splat(0);
            const bits_per_word = @bitSizeOf(usize);
            if (core >= set.len * bits_per_word) return error.CoreUnavailable;
            set[core / bits_per_word] |= @as(usize, 1) << @intCast(core % bits_per_word);
            std.os.linux.sched_setaffinity(0, &set) catch return error.CoreUnavailable;
        },
        else => return error.PinningUnsupported,
    }
}

pub const PriorityError = error{ PriorityUnsupported, PriorityDenied };

/// Windows: the high priority class, which processes it starts do not
/// inherit. Linux: a nice value of -10, which needs `CAP_SYS_NICE` and is
/// inherited.
pub fn raisePriority() PriorityError!void {
    switch (builtin.os.tag) {
        .windows => {
            const high_priority_class = 0x80;
            if (!win.SetPriorityClass(std.os.windows.GetCurrentProcess(), high_priority_class).toBool()) return error.PriorityDenied;
        },
        .linux => {
            const linux = std.os.linux;
            const prio_process = 0;
            const nice: isize = -10;
            const rc = linux.syscall3(.setpriority, prio_process, 0, @bitCast(nice));
            if (linux.errno(rc) != .SUCCESS) return error.PriorityDenied;
        },
        else => return error.PriorityUnsupported,
    }
}

pub fn logicalCpuCount() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

/// Reads the machine's state as it is now. Anything the platform does not
/// expose is left null.
pub fn read(io: Io, arena: std.mem.Allocator, pinned_core: ?u32) !Machine {
    var machine: Machine = .{
        .os = @tagName(builtin.os.tag),
        .cpu = try cpuModel(io, arena),
        .logical_cpus = logicalCpuCount(),
        .pinned_core = pinned_core,
    };
    if (builtin.cpu.arch.isX86()) machine.cpu_vendor = try x86Vendor(arena);
    switch (builtin.os.tag) {
        .windows => try readWindows(arena, &machine),
        .linux => try readLinux(io, arena, &machine),
        .macos => try readMacos(arena, &machine),
        else => {},
    }
    return machine;
}

fn x86Vendor(arena: std.mem.Allocator) ![]const u8 {
    const leaf = cpuid(0);
    const words = [3]u32{ leaf.ebx, leaf.edx, leaf.ecx };
    return arena.dupe(u8, std.mem.asBytes(&words));
}

fn cpuModel(io: Io, arena: std.mem.Allocator) ![]const u8 {
    if (builtin.cpu.arch.isX86()) return x86BrandString(arena);
    if (builtin.os.tag == .linux) {
        if (readSmallFile(io, arena, "/proc/cpuinfo")) |cpuinfo| {
            for ([_][]const u8{ "model name", "Model", "Hardware" }) |key| {
                if (cpuinfoValue(cpuinfo, key)) |value| return value;
            }
        } else |_| {}
    }
    return builtin.cpu.model.name;
}

fn cpuinfoValue(cpuinfo: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn x86BrandString(arena: std.mem.Allocator) ![]const u8 {
    if (cpuid(0x80000000).eax < 0x80000004) return builtin.cpu.model.name;
    var brand: [48]u8 = undefined;
    for (0..3) |index| {
        const leaf = cpuid(0x80000002 + @as(u32, @intCast(index)));
        @memcpy(brand[index * 16 ..][0..16], std.mem.asBytes(&[4]u32{ leaf.eax, leaf.ebx, leaf.ecx, leaf.edx }));
    }
    const end = std.mem.indexOfScalar(u8, &brand, 0) orelse brand.len;
    return arena.dupe(u8, std.mem.trim(u8, brand[0..end], " "));
}

const CpuidLeaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (0),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Reads a file whose reported size cannot be trusted, as with `/proc` and `/sys`.
fn readSmallFile(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(1024 * 1024));
}

fn readTrimmed(io: Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const contents = readSmallFile(io, arena, path) catch return null;
    return std.mem.trim(u8, contents, " \t\r\n");
}

fn readNumber(io: Io, arena: std.mem.Allocator, path: []const u8) ?u32 {
    return std.fmt.parseInt(u32, readTrimmed(io, arena, path) orelse return null, 10) catch null;
}

fn readLinux(io: Io, arena: std.mem.Allocator, machine: *Machine) !void {
    var uts: std.os.linux.utsname = undefined;
    if (std.os.linux.errno(std.os.linux.uname(&uts)) == .SUCCESS) machine.os_version = try arena.dupe(u8, std.mem.sliceTo(&uts.release, 0));
    if (machine.cpu_vendor == null) {
        if (readSmallFile(io, arena, "/proc/cpuinfo")) |cpuinfo| machine.cpu_vendor = cpuinfoValue(cpuinfo, "CPU implementer") else |_| {}
    }
    // The affinity mask hides the other CPUs from a pinned process.
    if (linuxPresentCpus(io, arena)) |present| machine.logical_cpus = present;
    machine.physical_cores = try linuxPhysicalCores(io, arena, machine.logical_cpus);
    try readLinuxCaches(io, arena, machine);

    const core = machine.pinned_core orelse 0;
    const cpu_directory = try std.fmt.allocPrint(arena, "/sys/devices/system/cpu/cpu{d}", .{core});
    machine.governor = readTrimmed(io, arena, try std.fs.path.join(arena, &.{ cpu_directory, "cpufreq/scaling_governor" }));
    machine.sibling_cores = readTrimmed(io, arena, try std.fs.path.join(arena, &.{ cpu_directory, "topology/thread_siblings_list" }));
    if (readNumber(io, arena, try std.fs.path.join(arena, &.{ cpu_directory, "cpufreq/scaling_cur_freq" }))) |khz| machine.clock_mhz = khz / 1000;
    if (readNumber(io, arena, try std.fs.path.join(arena, &.{ cpu_directory, "cpufreq/cpuinfo_max_freq" }))) |khz| machine.max_clock_mhz = khz / 1000;
    machine.address_randomization = readNumber(io, arena, "/proc/sys/kernel/randomize_va_space");
    if (readNumber(io, arena, "/sys/devices/system/cpu/intel_pstate/no_turbo")) |no_turbo| {
        machine.turbo = if (no_turbo == 1) .off else .on;
    } else if (readNumber(io, arena, "/sys/devices/system/cpu/cpufreq/boost")) |boost| {
        machine.turbo = if (boost == 1) .on else .off;
    }
}

/// How many CPUs `/sys/devices/system/cpu/present` lists, as ranges such
/// as `0-19` or `0-3,8-11`.
fn linuxPresentCpus(io: Io, arena: std.mem.Allocator) ?u32 {
    const present = readTrimmed(io, arena, "/sys/devices/system/cpu/present") orelse return null;
    var count: u32 = 0;
    var ranges = std.mem.tokenizeScalar(u8, present, ',');
    while (ranges.next()) |range| {
        const dash = std.mem.indexOfScalar(u8, range, '-');
        const first = std.fmt.parseInt(u32, range[0 .. dash orelse range.len], 10) catch return null;
        const last = if (dash) |at| std.fmt.parseInt(u32, range[at + 1 ..], 10) catch return null else first;
        count += last - first + 1;
    }
    return count;
}

/// The distinct sets of hardware threads that share a core.
fn linuxPhysicalCores(io: Io, arena: std.mem.Allocator, logical_cpus: u32) !?u32 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (0..logical_cpus) |cpu| {
        const path = try std.fmt.allocPrint(arena, "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list", .{cpu});
        try seen.put(arena, readTrimmed(io, arena, path) orelse return null, {});
    }
    return seen.count();
}

/// Core 0's caches, which on every CPU this has met are the same size as
/// every other core's of their level.
fn readLinuxCaches(io: Io, arena: std.mem.Allocator, machine: *Machine) !void {
    for (0..8) |index| {
        const directory = try std.fmt.allocPrint(arena, "/sys/devices/system/cpu/cpu0/cache/index{d}", .{index});
        const level = readNumber(io, arena, try std.fs.path.join(arena, &.{ directory, "level" })) orelse break;
        const kind = readTrimmed(io, arena, try std.fs.path.join(arena, &.{ directory, "type" })) orelse continue;
        const size_text = readTrimmed(io, arena, try std.fs.path.join(arena, &.{ directory, "size" })) orelse continue;
        const kib = std.fmt.parseInt(u32, std.mem.trimEnd(u8, size_text, "K"), 10) catch continue;
        if (std.mem.eql(u8, kind, "Instruction")) continue;
        switch (level) {
            1 => machine.l1d_kib = kib,
            2 => machine.l2_kib = kib,
            3 => machine.l3_kib = kib,
            else => {},
        }
    }
}

fn readMacos(arena: std.mem.Allocator, machine: *Machine) !void {
    machine.os_version = try sysctlText(arena, "kern.osproductversion");
    if (machine.cpu_vendor == null and builtin.cpu.arch == .aarch64) machine.cpu_vendor = "Apple";
    if (!builtin.cpu.arch.isX86()) {
        if (try sysctlText(arena, "machdep.cpu.brand_string")) |brand| machine.cpu = brand;
    }
    machine.physical_cores = if (sysctlNumber("hw.physicalcpu")) |cores| @intCast(cores) else null;
    // On Apple silicon these describe the performance cores.
    machine.l1d_kib = if (sysctlNumber("hw.l1dcachesize")) |bytes| @intCast(bytes / 1024) else null;
    machine.l2_kib = if (sysctlNumber("hw.l2cachesize")) |bytes| @intCast(bytes / 1024) else null;
    machine.l3_kib = if (sysctlNumber("hw.l3cachesize")) |bytes| @intCast(bytes / 1024) else null;
}

fn sysctlText(arena: std.mem.Allocator, comptime name: [:0]const u8) !?[]const u8 {
    var buffer: [256]u8 = undefined;
    var length: usize = buffer.len;
    if (std.c.sysctlbyname(name, &buffer, &length, null, 0) != 0) return null;
    return try arena.dupe(u8, std.mem.sliceTo(buffer[0..length], 0));
}

fn sysctlNumber(comptime name: [:0]const u8) ?u64 {
    var value: u64 = 0;
    var length: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &length, null, 0) != 0 or length == 0) return null;
    return value;
}

fn readWindows(arena: std.mem.Allocator, machine: *Machine) !void {
    const windows = std.os.windows;
    var version: windows.RTL_OSVERSIONINFOW = undefined;
    version.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    if (windows.ntdll.RtlGetVersion(&version) == .SUCCESS) {
        machine.os_version = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ version.dwMajorVersion, version.dwMinorVersion, version.dwBuildNumber });
    }
    try readWindowsTopology(arena, machine);

    var scheme: ?*windows.GUID = null;
    if (win.PowerGetActiveScheme(null, &scheme) == 0) {
        if (scheme) |active| {
            defer _ = win.LocalFree(active);
            machine.power_plan = try powerPlanName(arena, active);
            const on_battery = onBattery();
            machine.processor_cap_percent = powerSetting(active, &win.processor_throttle_maximum, on_battery);
            machine.boost_mode = powerSetting(active, &win.processor_perf_boost_mode, on_battery);
        }
    }
    if (machine.boost_mode) |mode| {
        if (mode == 0) machine.turbo = .off;
    }
    // Below 100%, Windows keeps the clock at or under its base frequency.
    if (machine.processor_cap_percent) |cap| {
        if (cap < 100) machine.turbo = .off;
    }
    if (machine.turbo == .unknown and machine.boost_mode != null and machine.processor_cap_percent != null) machine.turbo = .on;

    const processors = try arena.alloc(win.PROCESSOR_POWER_INFORMATION, machine.logical_cpus);
    const processor_information = 11;
    const status = win.CallNtPowerInformation(processor_information, null, 0, processors.ptr, @intCast(processors.len * @sizeOf(win.PROCESSOR_POWER_INFORMATION)));
    if (status == 0) {
        const processor = processors[@min(machine.pinned_core orelse 0, processors.len - 1)];
        machine.clock_mhz = processor.CurrentMhz;
        machine.max_clock_mhz = processor.MaxMhz;
    }
}

fn readWindowsTopology(arena: std.mem.Allocator, machine: *Machine) !void {
    var size: u32 = 0;
    _ = win.GetLogicalProcessorInformation(null, &size);
    if (size == 0) return;
    const entries = try arena.alloc(win.SYSTEM_LOGICAL_PROCESSOR_INFORMATION, size / @sizeOf(win.SYSTEM_LOGICAL_PROCESSOR_INFORMATION));
    if (!win.GetLogicalProcessorInformation(entries.ptr, &size).toBool()) return;
    var cores: u32 = 0;
    for (entries[0 .. size / @sizeOf(win.SYSTEM_LOGICAL_PROCESSOR_INFORMATION)]) |entry| {
        switch (entry.Relationship) {
            win.relation_processor_core => cores += 1,
            win.relation_cache => {
                const cache = entry.detail.Cache;
                if (cache.Type == win.cache_instruction) continue;
                const kib = cache.Size / 1024;
                switch (cache.Level) {
                    1 => machine.l1d_kib = machine.l1d_kib orelse kib,
                    2 => machine.l2_kib = machine.l2_kib orelse kib,
                    3 => machine.l3_kib = machine.l3_kib orelse kib,
                    else => {},
                }
            },
            else => {},
        }
    }
    if (cores > 0) machine.physical_cores = cores;
}

fn onBattery() bool {
    var status: win.SYSTEM_POWER_STATUS = undefined;
    if (!win.GetSystemPowerStatus(&status).toBool()) return false;
    return status.ACLineStatus == 0;
}

fn powerSetting(scheme: *const std.os.windows.GUID, setting: *const std.os.windows.GUID, on_battery: bool) ?u32 {
    var value: u32 = undefined;
    const read_value: *const @TypeOf(win.PowerReadACValueIndex) = if (on_battery) &win.PowerReadDCValueIndex else &win.PowerReadACValueIndex;
    if (read_value(null, scheme, &win.processor_settings_subgroup, setting, &value) != 0) return null;
    return value;
}

fn powerPlanName(arena: std.mem.Allocator, scheme: *const std.os.windows.GUID) !?[]const u8 {
    var size: u32 = 0;
    if (win.PowerReadFriendlyName(null, scheme, null, null, null, &size) != 0 or size < 2) return null;
    const name = try arena.alignedAlloc(u16, .of(u16), size / 2);
    if (win.PowerReadFriendlyName(null, scheme, null, null, @ptrCast(name.ptr), &size) != 0) return null;
    const end = std.mem.indexOfScalar(u16, name, 0) orelse name.len;
    return try std.unicode.utf16LeToUtf8Alloc(arena, name[0..end]);
}

const win = struct {
    const windows = std.os.windows;
    const BOOL = windows.BOOL;
    const HANDLE = windows.HANDLE;
    const GUID = windows.GUID;

    const processor_settings_subgroup = GUID.parse("{54533251-82be-4824-96c1-47b60b740d00}");
    const processor_throttle_maximum = GUID.parse("{bc5038f7-23e0-4960-96da-33abaf5935ec}");
    const processor_perf_boost_mode = GUID.parse("{be337238-0d82-4146-a960-4f3749d470c7}");

    const PROCESSOR_POWER_INFORMATION = extern struct {
        Number: u32,
        MaxMhz: u32,
        CurrentMhz: u32,
        MhzLimit: u32,
        MaxIdleState: u32,
        CurrentIdleState: u32,
    };

    const relation_processor_core = 0;
    const relation_cache = 2;
    const cache_instruction = 1;

    const CACHE_DESCRIPTOR = extern struct {
        Level: u8,
        Associativity: u8,
        LineSize: u16,
        Size: u32,
        Type: u32,
    };

    const SYSTEM_LOGICAL_PROCESSOR_INFORMATION = extern struct {
        ProcessorMask: usize,
        Relationship: u32,
        detail: extern union {
            ProcessorCore: u8,
            NumaNode: u32,
            Cache: CACHE_DESCRIPTOR,
            Reserved: [2]u64,
        },
    };

    const SYSTEM_POWER_STATUS = extern struct {
        ACLineStatus: u8,
        BatteryFlag: u8,
        BatteryLifePercent: u8,
        SystemStatusFlag: u8,
        BatteryLifeTime: u32,
        BatteryFullLifeTime: u32,
    };

    extern "kernel32" fn SetThreadAffinityMask(thread: HANDLE, mask: usize) callconv(.winapi) usize;
    extern "kernel32" fn SetProcessAffinityMask(process: HANDLE, mask: usize) callconv(.winapi) BOOL;
    extern "kernel32" fn SetPriorityClass(process: HANDLE, priority_class: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetSystemPowerStatus(status: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLogicalProcessorInformation(buffer: ?[*]SYSTEM_LOGICAL_PROCESSOR_INFORMATION, length: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "powrprof" fn PowerGetActiveScheme(root: ?*anyopaque, scheme: *?*GUID) callconv(.winapi) u32;
    extern "powrprof" fn PowerReadACValueIndex(root: ?*anyopaque, scheme: *const GUID, subgroup: *const GUID, setting: *const GUID, value: *u32) callconv(.winapi) u32;
    extern "powrprof" fn PowerReadDCValueIndex(root: ?*anyopaque, scheme: *const GUID, subgroup: *const GUID, setting: *const GUID, value: *u32) callconv(.winapi) u32;
    extern "powrprof" fn PowerReadFriendlyName(root: ?*anyopaque, scheme: ?*const GUID, subgroup: ?*const GUID, setting: ?*const GUID, buffer: ?[*]u8, size: *u32) callconv(.winapi) u32;
    extern "powrprof" fn CallNtPowerInformation(level: i32, input: ?*anyopaque, input_size: u32, output: ?*anyopaque, output_size: u32) callconv(.winapi) i32;
};
