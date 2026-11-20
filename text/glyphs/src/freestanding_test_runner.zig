const std = @import("std");
const builtin = @import("builtin");

/// `wasm32-freestanding` has no threads or files for `std.debug` to
/// capture stack traces with.
pub const std_options_debug_io: std.Io = .failing;

/// Exported so that every test compiles for `wasm32-freestanding`; nothing
/// runs it, since the tests run natively.
export fn zuiRunTests() u32 {
    var failed: u32 = 0;
    for (builtin.test_functions) |test_function| {
        test_function.func() catch {
            failed += 1;
        };
    }
    return failed;
}
