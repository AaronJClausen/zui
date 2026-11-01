const std = @import("std");
const options = @import("zui_options");

/// The name an id was created from, kept only in `-Dzui-debug` builds so
/// that diagnostics can say "save" instead of a hash. Zero bytes otherwise.
pub const DebugName = if (options.debug) []const u8 else void;
const unnamed: DebugName = if (options.debug) "" else {};

/// A 64-bit name for an element that is stable across frames.
///
/// ```zig
/// ui.open(.{ .id = .of("toolbar") });                 // hashed at compile time
/// ui.open(.{ .id = .indexed("row", row_index) });     // one runtime mix
/// ui.open(.{ .id = parent.child("close_button") });   // scoped under another id
/// ```
pub const Id = struct {
    hash: u64,
    debug_name: DebugName = unnamed,

    /// "No id": the element gets an internal one and cannot be queried.
    pub const none: Id = .{ .hash = 0 };

    pub fn of(comptime name: []const u8) Id {
        return .{ .hash = comptime nonZero(fnv1a(name)), .debug_name = debugName(name) };
    }

    pub fn indexed(comptime name: []const u8, index: usize) Id {
        return .{ .hash = nonZero(mix(comptime fnv1a(name), index)), .debug_name = debugName(name) };
    }

    /// For names only known at run time. Debug builds do not keep the name,
    /// because the caller's buffer may not outlive the frame.
    pub fn dynamic(name: []const u8) Id {
        return .{ .hash = nonZero(fnv1a(name)) };
    }

    pub fn child(parent: Id, comptime name: []const u8) Id {
        return .{ .hash = nonZero(mix(parent.hash, comptime fnv1a(name))), .debug_name = debugName(name) };
    }

    pub fn isNone(self: Id) bool {
        return self.hash == 0;
    }

    pub fn eql(self: Id, other: Id) bool {
        return self.hash == other.hash;
    }
};

fn debugName(comptime name: []const u8) DebugName {
    return if (options.debug) name else {};
}

pub fn fnv1a(bytes: []const u8) u64 {
    if (@inComptime()) @setEvalBranchQuota(@intCast(bytes.len * 4 + 100));
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Combines two hashes; the splitmix64 finalizer spreads small inputs such
/// as loop indices across all 64 bits.
pub fn mix(seed: u64, value: u64) u64 {
    var combined = seed ^ (value +% 0x9e3779b97f4a7c15 +% (seed << 6) +% (seed >> 2));
    combined = (combined ^ (combined >> 30)) *% 0xbf58476d1ce4e5b9;
    combined = (combined ^ (combined >> 27)) *% 0x94d049bb133111eb;
    return combined ^ (combined >> 31);
}

/// Hash 0 means `Id.none`, so a real name never maps to it.
fn nonZero(hash: u64) u64 {
    return if (hash == 0) 1 else hash;
}

/// A struct with one `Id` field per name, checked at compile time for
/// repeated names and hash collisions.
///
/// ```zig
/// const ids = zui.ids(.{ "root", "sidebar", "save" });
/// ui.open(.{ .id = ids.sidebar });
/// ```
pub fn ids(comptime names: anytype) IdSet(names) {
    return .{};
}

pub fn IdSet(comptime names: anytype) type {
    const name_count = names.len;
    var field_names: [name_count][]const u8 = undefined;
    var field_types: [name_count]type = undefined;
    var field_attributes: [name_count]std.builtin.Type.StructField.Attributes = undefined;
    for (0..name_count) |index| {
        const name: []const u8 = names[index];
        for (0..index) |earlier_index| {
            const earlier: []const u8 = names[earlier_index];
            if (std.mem.eql(u8, earlier, name)) @compileError("zui.ids: \"" ++ name ++ "\" appears more than once");
            if (fnv1a(earlier) == fnv1a(name)) @compileError("zui.ids: \"" ++ earlier ++ "\" and \"" ++ name ++ "\" have the same hash");
        }
        const default_id: Id = .of(name);
        field_names[index] = name;
        field_types[index] = Id;
        field_attributes[index] = .{ .default_value_ptr = &default_id };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attributes);
}

test "compile-time and run-time hashing agree" {
    var runtime_name: []const u8 = "toolbar";
    _ = &runtime_name;
    try std.testing.expectEqual(Id.of("toolbar").hash, Id.dynamic(runtime_name).hash);
    try std.testing.expect(!Id.of("toolbar").eql(.of("toolbar2")));
}

test "FNV-1a matches the published test vectors" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a("a"));
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a("foobar"));
}

test "indexed and child ids are distinct and stable" {
    try std.testing.expect(!Id.indexed("row", 0).eql(.indexed("row", 1)));
    try std.testing.expect(Id.indexed("row", 7).eql(.indexed("row", 7)));
    const list_a: Id = .of("list_a");
    const list_b: Id = .of("list_b");
    try std.testing.expect(!list_a.child("item").eql(list_b.child("item")));
}

test "ids builds a struct of ids" {
    const set = ids(.{ "root", "save" });
    try std.testing.expect(set.save.eql(.of("save")));
    try std.testing.expect(!set.root.eql(set.save));
}
