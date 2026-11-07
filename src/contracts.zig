const std = @import("std");
const style = @import("style.zig");
const trace = @import("trace.zig");

/// Every `zui`-prefixed declaration of every contract. One that is not
/// here belongs to no contract, which is almost always a misspelling.
const known_declarations = text_declarations ++ source_declarations ++ renderer_declarations ++
    host_declarations ++ tracer_declarations ++ skin_declarations ++ wire_declarations ++ app_declarations;

const text_declarations = [_][]const u8{ "zuiMeasure", "zuiSegment", "zui_thread_safe", "zuiFingerprint" };
const source_declarations = [_][]const u8{ "zuiSwap", "zuiView", "zuiDelivery", "zuiInject", "zuiPending", "zuiEndFrame", "zuiRefusedCount" };
const renderer_declarations = [_][]const u8{ "zuiSubmit", "zui_surfaces", "zui_commands", "zui_extended_color" };
const host_declarations = [_][]const u8{
    "zuiPoll",      "zuiWaker",         "zuiWait",        "zuiSurface", "zuiApply", "zui_capabilities",
    "zuiClipboard", "zuiNotifications", "zuiFileDialogs", "zuiOpenUrl", "zuiMenus", "zuiFileWatch",
};
const tracer_declarations = [_][]const u8{ "zuiBegin", "zuiEnd" };
const skin_declarations = [_][]const u8{"zuiStyle"};
const wire_declarations = [_][]const u8{ "zuiSerialize", "zuiDeserialize" };
/// Declared by an application that `zui_app` runs.
const app_declarations = [_][]const u8{ "zuiDeclare", "zuiLoader" };

pub fn checkText(comptime Text: type, comptime FontId: type) void {
    if (@typeInfo(Text) != .@"struct") @compileError("zui: Text must be a struct type, got " ++ @typeName(Text));
    checkKnownDeclarations(Text);
    if (!@hasDecl(Text, "zuiMeasure")) @compileError("zui: " ++ @typeName(Text) ++ " does not implement zui.Text: missing `zuiMeasure`");
    const Measure = fn (*Text, []const u8, style.MeasureKey(FontId)) [2]f32;
    if (@TypeOf(Text.zuiMeasure) != Measure) {
        @compileError("zui: " ++ @typeName(Text) ++ ".zuiMeasure must be " ++ @typeName(Measure) ++ ", found " ++ @typeName(@TypeOf(Text.zuiMeasure)));
    }
    if (@hasDecl(Text, "zui_thread_safe") and @TypeOf(Text.zui_thread_safe) != bool) {
        @compileError("zui: " ++ @typeName(Text) ++ ".zui_thread_safe must be a bool, found " ++ @typeName(@TypeOf(Text.zui_thread_safe)));
    }
}

pub fn checkTracer(comptime Tracer: type) void {
    if (@typeInfo(Tracer) != .@"struct") @compileError("zui: Tracer must be a struct type, got " ++ @typeName(Tracer));
    checkKnownDeclarations(Tracer);
    for ([_][]const u8{ "zuiBegin", "zuiEnd" }) |required| {
        if (!@hasDecl(Tracer, required)) @compileError("zui: " ++ @typeName(Tracer) ++ " does not implement zui.Tracer: missing `" ++ required ++ "`");
    }
    const Begin = @TypeOf(Tracer.zuiBegin);
    const begins_with_comptime_zone = switch (@typeInfo(Begin)) {
        .@"fn" => |function| function.is_generic and function.params.len == 1 and function.params[0].type == trace.TraceZone,
        else => false,
    };
    if (!begins_with_comptime_zone) {
        @compileError("zui: " ++ @typeName(Tracer) ++ ".zuiBegin must be fn (comptime zone: zui.TraceZone) Span, found " ++ @typeName(Begin));
    }
    const End = fn (@TypeOf(Tracer.zuiBegin(trace.TraceZone.begin_frame))) void;
    if (@TypeOf(Tracer.zuiEnd) != End) {
        @compileError("zui: " ++ @typeName(Tracer) ++ ".zuiEnd must be " ++ @typeName(End) ++ ", the span zuiBegin returns, found " ++ @typeName(@TypeOf(Tracer.zuiEnd)));
    }
}

fn checkKnownDeclarations(comptime Implementer: type) void {
    @setEvalBranchQuota(10 * known_declarations.len * @typeInfo(Implementer).@"struct".decls.len + 1000);
    for (@typeInfo(Implementer).@"struct".decls) |declaration| {
        if (!std.mem.startsWith(u8, declaration.name, "zui")) continue;
        for (known_declarations) |known| {
            if (std.mem.eql(u8, declaration.name, known)) break;
        } else @compileError("zui: " ++ @typeName(Implementer) ++ " declares unknown `" ++ declaration.name ++ "`");
    }
}
