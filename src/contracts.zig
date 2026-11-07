const std = @import("std");
const style = @import("style.zig");
const trace = @import("trace.zig");
const sources = @import("sources.zig");
const commands = @import("commands.zig");
const surface = @import("surface.zig");

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

/// The renderer contract. A renderer is usually also the text contract,
/// which `Context` checks when it is `Config.Text`.
pub fn checkRenderer(comptime Renderer: type) void {
    if (@typeInfo(Renderer) != .@"struct") @compileError("zui: a renderer must be a struct type, got " ++ @typeName(Renderer));
    const name = @typeName(Renderer);
    checkKnownDeclarations(Renderer);
    for ([_][]const u8{ "zuiSubmit", "zui_surfaces" }) |required| {
        if (!@hasDecl(Renderer, required)) @compileError("zui: " ++ name ++ " does not implement zui.Renderer: missing `" ++ required ++ "`");
    }
    expectDeclarationType(Renderer, "zui_surfaces", surface.SurfaceKinds, "zui.SurfaceKinds");
    if (Renderer.zui_surfaces.count() == 0) @compileError("zui: " ++ name ++ ".zui_surfaces names no surface kind, so no host can give it one");
    if (@hasDecl(Renderer, "zui_commands")) expectDeclarationType(Renderer, "zui_commands", commands.CommandSet, "zui.CommandSet");
    if (@hasDecl(Renderer, "zui_extended_color")) expectDeclarationType(Renderer, "zui_extended_color", bool, "bool");
    for ([_][]const u8{ "ImageHandle", "MaterialHandle", "CustomData", "FontId" }) |payload_type| {
        if (@hasDecl(Renderer, payload_type)) expectDeclarationType(Renderer, payload_type, type, "type");
    }
    if (@hasDecl(Renderer, "zui_commands") and Renderer.zui_commands.contains(.material) and rendererType(Renderer, "MaterialHandle", void) == void) {
        @compileError("zui: " ++ name ++ ".zui_commands includes .material but " ++ name ++ ".MaterialHandle is void");
    }

    const expected_submit = "fn (*" ++ name ++ ", zui.Surface, frame: anytype) !void";
    const submits_a_frame = switch (@typeInfo(@TypeOf(Renderer.zuiSubmit))) {
        .@"fn" => |function| function.params.len == 3 and
            function.params[0].type == *Renderer and
            function.params[1].type == surface.Surface and
            function.params[2].type == null,
        else => false,
    };
    // Not "found ...": a generic function's type name spells out its inferred error set in builtins.
    if (!submits_a_frame) @compileError("zui: " ++ name ++ ".zuiSubmit must be " ++ expected_submit);
}

/// The renderer's declaration `declaration`, or `default` without one.
fn rendererType(comptime Renderer: type, comptime declaration: []const u8, comptime default: type) type {
    return if (@hasDecl(Renderer, declaration)) @field(Renderer, declaration) else default;
}

fn expectDeclarationType(comptime Implementer: type, comptime declaration: []const u8, comptime Expected: type, comptime expected_name: []const u8) void {
    const Found = @TypeOf(@field(Implementer, declaration));
    if (Found != Expected) @compileError("zui: " ++ @typeName(Implementer) ++ "." ++ declaration ++ " must be a " ++ expected_name ++ ", found " ++ @typeName(Found));
}

pub fn checkSources(comptime Sources: type) void {
    if (@typeInfo(Sources) != .@"struct") @compileError("zui: Sources must be a struct type, got " ++ @typeName(Sources));
    for (@typeInfo(Sources).@"struct".fields) |field| checkSource(field.type, @typeName(Sources) ++ "." ++ field.name);
}

/// `name` is the field holding the source, e.g. `AppSources.quotes`, which
/// says more than the source's own type when one type serves many fields.
fn checkSource(comptime Source: type, comptime name: []const u8) void {
    if (@typeInfo(Source) != .@"struct") @compileError("zui: " ++ name ++ " must be a struct type implementing zui.Source, got " ++ @typeName(Source));
    checkKnownDeclarationsAs(Source, name);
    for ([_][]const u8{ "Delivery", "View", "zuiSwap", "zuiView", "zuiDelivery", "zuiInject" }) |required| {
        if (!@hasDecl(Source, required)) @compileError("zui: " ++ name ++ " does not implement zui.Source: missing `" ++ required ++ "`");
    }
    for ([_][]const u8{ "Delivery", "View" }) |type_name| {
        const Declared = @TypeOf(@field(Source, type_name));
        if (Declared != type) @compileError("zui: " ++ name ++ "." ++ type_name ++ " must be a type, found " ++ @typeName(Declared));
    }
    expectSignature(Source, name, "zuiSwap", fn (*Source) void);
    expectSignature(Source, name, "zuiView", fn (*Source) Source.View);
    expectSignature(Source, name, "zuiDelivery", fn (*const Source, *Source.Delivery) void);
    expectSignature(Source, name, "zuiInject", fn (*Source, *const Source.Delivery) void);
    if (@hasDecl(Source, "zuiPending")) expectSignature(Source, name, "zuiPending", fn (*const Source) bool);
    if (@hasDecl(Source, "zuiEndFrame")) expectSignature(Source, name, "zuiEndFrame", fn (*Source, sources.EndFrameInfo) void);
    if (@hasDecl(Source, "zuiRefusedCount")) expectSignature(Source, name, "zuiRefusedCount", fn (*Source) u32);
}

fn expectSignature(comptime Implementer: type, comptime name: []const u8, comptime declaration: []const u8, comptime Expected: type) void {
    const Found = @TypeOf(@field(Implementer, declaration));
    if (Found != Expected) @compileError("zui: " ++ name ++ "." ++ declaration ++ " must be " ++ @typeName(Expected) ++ ", found " ++ @typeName(Found));
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
    checkKnownDeclarationsAs(Implementer, @typeName(Implementer));
}

fn checkKnownDeclarationsAs(comptime Implementer: type, comptime name: []const u8) void {
    @setEvalBranchQuota(10 * known_declarations.len * @typeInfo(Implementer).@"struct".decls.len + 1000);
    for (@typeInfo(Implementer).@"struct".decls) |declaration| {
        if (!std.mem.startsWith(u8, declaration.name, "zui")) continue;
        for (known_declarations) |known| {
            if (std.mem.eql(u8, declaration.name, known)) break;
        } else @compileError("zui: " ++ name ++ " declares unknown `" ++ declaration.name ++ "`");
    }
}
