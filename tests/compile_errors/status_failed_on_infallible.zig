const zui = @import("zui");

export fn describe(status: *const zui.Status(u32)) u32 {
    return switch (status.*) {
        .idle, .running, .canceled => 0,
        .ready => |value| value,
        .failed => 1,
    };
}
