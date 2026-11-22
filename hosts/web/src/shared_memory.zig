const std = @import("std");

/// Each task thread's stack, which its worker sets `__stack_pointer` to
/// the top of before calling into the module.
pub const thread_stack_bytes = 256 * 1024;
/// The most thread-local storage a module on these threads may declare.
pub const thread_local_bytes_most = 4096;

/// The stacks and thread-local storage of the workers that share a
/// module's memory, reserved once, one after another.
pub const ThreadMemory = struct {
    memory: []align(16) u8 = &.{},

    const bytes_per_thread = thread_stack_bytes + thread_local_bytes_most;

    /// Reserves room for `thread_count` threads; fails when the module
    /// declares more thread-local storage than each is given.
    pub fn init(gpa: std.mem.Allocator, thread_count: u32) error{ OutOfMemory, ThreadLocalStorageTooLarge }!ThreadMemory {
        if (threadLocalBytes() > thread_local_bytes_most) return error.ThreadLocalStorageTooLarge;
        return .{ .memory = try gpa.alignedAlloc(u8, .@"16", thread_count * bytes_per_thread) };
    }

    /// Where thread `index`'s stack starts, for its worker to set
    /// `__stack_pointer` to.
    pub fn stackTop(self: ThreadMemory, index: u32) usize {
        return @intFromPtr(self.of(index).ptr) + thread_stack_bytes;
    }

    /// The thread-local storage for thread `index`'s worker to pass to
    /// `__wasm_init_tls`, just past its stack.
    pub fn threadLocalStorage(self: ThreadMemory, index: u32) usize {
        return @intFromPtr(self.of(index).ptr) + thread_stack_bytes;
    }

    fn of(self: ThreadMemory, index: u32) []u8 {
        return self.memory[index * bytes_per_thread ..][0..bytes_per_thread];
    }
};

fn threadLocalBytes() usize {
    return asm (
        \\ .globaltype __tls_size, i32, immutable
        \\ global.get __tls_size
        \\ local.set %[ret]
        : [ret] "=r" (-> usize),
    );
}

/// The futex threads on shared memory take turns by, which only a worker
/// may wait on.
pub const futex_io: std.Io = .{ .userdata = null, .vtable = &futex_vtable };

const futex_vtable: std.Io.VTable = vtable: {
    var table = std.Io.failing.vtable.*;
    table.futexWaitUncancelable = futexWaitUncancelable;
    table.futexWake = futexWake;
    break :vtable table;
};

fn futexWaitUncancelable(_: ?*anyopaque, futex: *const u32, expected: u32) void {
    _ = asm volatile (
        \\local.get %[futex]
        \\local.get %[expected]
        \\i64.const -1
        \\memory.atomic.wait32 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [futex] "r" (futex),
          [expected] "r" (expected),
    );
}

fn futexWake(_: ?*anyopaque, futex: *const u32, max_waiters: u32) void {
    _ = asm volatile (
        \\local.get %[futex]
        \\local.get %[max_waiters]
        \\memory.atomic.notify 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [futex] "r" (futex),
          [max_waiters] "r" (max_waiters),
    );
}

/// Takes memory from the end of the module's, growing it, and frees none,
/// for a module that allocates only as it starts, on the one worker that
/// starts it. A module that also allocates through
/// `std.heap.page_allocator` names this one as its root's
/// `os.heap.page_allocator`, so nothing else grows the memory under it.
pub const growing_allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = growingAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
} };

var growing_end: usize = 0;

fn growingAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const page_bytes = std.wasm.page_size;
    if (growing_end == 0) growing_end = @wasmMemorySize(0) * page_bytes;
    const start = alignment.forward(growing_end);
    const end = start + len;
    const pages_held = @wasmMemorySize(0);
    const pages_needed = std.math.divCeil(usize, end, page_bytes) catch unreachable;
    if (pages_needed > pages_held and @wasmMemoryGrow(0, pages_needed - pages_held) < 0) return null;
    growing_end = end;
    return @ptrFromInt(start);
}
