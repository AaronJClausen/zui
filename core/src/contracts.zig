const std = @import("std");
const style = @import("style.zig");
const text = @import("text.zig");
const trace = @import("trace.zig");
const sources = @import("sources.zig");
const commands = @import("commands.zig");
const surface = @import("surface.zig");
const host = @import("host.zig");
const record = @import("record.zig");
const semantics = @import("semantics.zig");
const chrome = @import("chrome.zig");
const services = @import("services.zig");
const design = @import("design.zig");
const WidgetState = @import("interaction.zig").WidgetState;

/// Every `zui`-prefixed declaration of every contract. One that is not
/// here belongs to no contract, which is almost always a misspelling.
const known_declarations = text_declarations ++ source_declarations ++ renderer_declarations ++
    host_declarations ++ tracer_declarations ++ skin_declarations ++ wire_declarations ++ app_declarations ++ design_declarations;

const text_declarations = [_][]const u8{ "zuiMeasure", "zuiSegment", "zui_thread_safe", "zuiFingerprint" };
const source_declarations = [_][]const u8{ "zuiSwap", "zuiView", "zuiDelivery", "zuiInject", "zuiPending", "zuiEndFrame", "zuiRefusedCount" };
const renderer_declarations = [_][]const u8{ "zuiSubmit", "zui_surfaces", "zui_commands", "zui_corner_shapes", "zui_extended_color", "zui_render_thread", "zui_output_formats" } ++ renderer_surface_calls;
/// Called as each window after the first opens, and as each window closes.
const renderer_surface_calls = [_][]const u8{ "zuiAttachSurface", "zuiDetachSurface" };
const host_declarations = [_][]const u8{ "zuiPoll", "zuiWaker", "zuiSurface", "zuiApply", "zui_capabilities", "zui_output_formats" } ++ host_loop_calls ++ host_window_calls ++ host_frame_calls ++ host_services;
/// At most one: zui pulls the loop of a host that waits, the platform
/// pushes the loop of a host that runs, and the application's own loop
/// steps a host with neither.
const host_loop_calls = [_][]const u8{ "zuiWait", "zuiRun" };
/// Declared exactly when `zui_capabilities.windows` is `.many`.
const host_window_calls = [_][]const u8{ "zuiOpenWindow", "zuiCloseWindow" };
/// What `zui_app` hands the host from each frame, besides its requests.
const host_frame_calls = [_][]const u8{ "zuiSemantics", "zuiChromeRegions" };
const host_services = [_][]const u8{ "zuiClipboard", "zuiNotifications", "zuiFileDialogs", "zuiOpenUrl", "zuiMenus", "zuiFileWatch" };
const tracer_declarations = [_][]const u8{ "zuiBegin", "zuiEnd" };
const skin_declarations = [_][]const u8{"zuiStyle"};
const wire_declarations = [_][]const u8{ "zuiSerialize", "zuiDeserialize" };
/// Declared by an application that `zui_app` runs.
const app_declarations = [_][]const u8{ "zuiDeclare", "zuiLoader" };
/// Declared by a component that `zui.design.Tokens` styles, and by an
/// application's extra roles.
const design_declarations = [_][]const u8{ "zuiAppearance", "zuiDistinguish", "zuiPairs", "zuiPreviews" };

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
    const Segment = fn (*Text, []const u8, *text.BreakSink) void;
    if (@hasDecl(Text, "zuiSegment") and @TypeOf(Text.zuiSegment) != Segment) {
        @compileError("zui: " ++ @typeName(Text) ++ ".zuiSegment must be " ++ @typeName(Segment) ++ ", found " ++ @typeName(@TypeOf(Text.zuiSegment)));
    }
    if (@hasDecl(Text, "zuiFingerprint") and @TypeOf(Text.zuiFingerprint) != fn (*const Text) u64) {
        @compileError("zui: " ++ @typeName(Text) ++ ".zuiFingerprint must be " ++ @typeName(fn (*const Text) u64) ++ ", found " ++ @typeName(@TypeOf(Text.zuiFingerprint)));
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
    if (@hasDecl(Renderer, "zui_corner_shapes")) {
        expectDeclarationType(Renderer, "zui_corner_shapes", style.CornerShapeSet, "zui.CornerShapeSet");
        if (!Renderer.zui_corner_shapes.contains(.round)) @compileError("zui: " ++ name ++ ".zui_corner_shapes does not include .round, which every other shape is drawn as");
    }
    if (@hasDecl(Renderer, "zui_extended_color")) expectDeclarationType(Renderer, "zui_extended_color", bool, "bool");
    if (@hasDecl(Renderer, "zui_render_thread")) expectDeclarationType(Renderer, "zui_render_thread", bool, "bool");
    checkOutputFormats(Renderer);
    if (surface.declaredOutputFormats(Renderer).contains(.scrgb_fp16) and !(@hasDecl(Renderer, "zui_extended_color") and Renderer.zui_extended_color)) {
        @compileError("zui: " ++ name ++ ".zui_output_formats includes .scrgb_fp16 but " ++ name ++ ".zui_extended_color is not true, so it would be given only clamped colors");
    }
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
    checkSurfaceCalls(Renderer);
}

fn checkSurfaceCalls(comptime Renderer: type) void {
    const name = @typeName(Renderer);
    const attaches = @hasDecl(Renderer, "zuiAttachSurface");
    const detaches = @hasDecl(Renderer, "zuiDetachSurface");
    if (attaches != detaches) {
        const declared, const missing = if (attaches) .{ "zuiAttachSurface", "zuiDetachSurface" } else .{ "zuiDetachSurface", "zuiAttachSurface" };
        @compileError("zui: " ++ name ++ " declares `" ++ declared ++ "` without `" ++ missing ++ "`; a renderer that keeps something per window declares both");
    }
    if (!attaches) return;
    const Attach = @TypeOf(Renderer.zuiAttachSurface);
    const attaches_a_surface = switch (@typeInfo(Attach)) {
        .@"fn" => |function| function.params.len == 2 and function.params[0].type == *Renderer and function.params[1].type == surface.Surface and
            if (function.return_type) |Returned| @typeInfo(Returned) == .error_union and @typeInfo(Returned).error_union.payload == void else false,
        else => false,
    };
    if (!attaches_a_surface) @compileError("zui: " ++ name ++ ".zuiAttachSurface must be fn (*" ++ name ++ ", zui.Surface) !void, found " ++ @typeName(Attach));
    const Detach = @TypeOf(Renderer.zuiDetachSurface);
    if (Detach != fn (*Renderer, surface.Surface) void) @compileError("zui: " ++ name ++ ".zuiDetachSurface must be fn (*" ++ name ++ ", zui.Surface) void, found " ++ @typeName(Detach));
}

/// The host contract: the window half, four calls and `zui_surfaces`; at
/// most one call of the loop half; and optionally `zui_capabilities`, the
/// frame calls and the services, each a struct of functions whose types
/// are checked.
pub fn checkHost(comptime Host: type) void {
    if (@typeInfo(Host) != .@"struct") @compileError("zui: a host must be a struct type, got " ++ @typeName(Host));
    const name = @typeName(Host);
    checkKnownDeclarations(Host);
    for ([_][]const u8{ "zuiPoll", "zuiWaker", "zuiSurface", "zuiApply", "zui_surfaces" }) |required| {
        if (!@hasDecl(Host, required)) @compileError("zui: " ++ name ++ " does not implement zui.Host: missing `" ++ required ++ "`");
    }
    expectDeclarationType(Host, "zui_surfaces", surface.SurfaceKinds, "zui.SurfaceKinds");
    if (Host.zui_surfaces.count() == 0) @compileError("zui: " ++ name ++ ".zui_surfaces names no surface kind, so no renderer can draw into it");
    if (@hasDecl(Host, "zui_capabilities")) {
        expectDeclarationType(Host, "zui_capabilities", host.HostCapabilities, "zui.HostCapabilities");
        if (Host.zui_capabilities.custom_title_bar and !@hasDecl(Host, "zuiChromeRegions")) {
            @compileError("zui: " ++ name ++ ".zui_capabilities.custom_title_bar is true but " ++ name ++ " does not declare zuiChromeRegions, so the OS could not move its window");
        }
    }
    checkOutputFormats(Host);
    for (host_services) |service| {
        if (!@hasDecl(Host, service)) continue;
        expectDeclarationType(Host, service, type, "type");
        if (@typeInfo(@field(Host, service)) != .@"struct") {
            @compileError("zui: " ++ name ++ "." ++ service ++ " must be a struct type, got " ++ @typeName(@field(Host, service)));
        }
    }

    const host_pointer = "*" ++ name;
    expectHostCall(Host, "zuiPoll", fn (*Host, host.WindowId, *record.RecordBuilder) bool, "fn (" ++ host_pointer ++ ", zui.WindowId, *zui.RecordBuilder) bool");
    expectHostCall(Host, "zuiWaker", fn (*Host) sources.Waker, "fn (" ++ host_pointer ++ ") zui.Waker");
    checkLoopCalls(Host);
    expectHostCall(Host, "zuiSurface", fn (*Host, host.WindowId) surface.Surface, "fn (" ++ host_pointer ++ ", zui.WindowId) zui.Surface");
    expectHostCall(Host, "zuiApply", fn (*Host, host.WindowId, record.HostRequests) void, "fn (" ++ host_pointer ++ ", zui.WindowId, zui.HostRequests) void");
    checkWindowCalls(Host);
    inline for (hostFrameCalls(Host)) |call| {
        if (@hasDecl(Host, call.declaration)) expectHostCall(Host, call.declaration, call.Expected, call.expected_name);
    }
    inline for (serviceFunctions(Host)) |function| {
        if (!@hasDecl(Host, function.service)) continue;
        const Service = @field(Host, function.service);
        const service_name = name ++ "." ++ function.service;
        if (!@hasDecl(Service, function.name)) {
            if (function.optional) continue;
            @compileError("zui: " ++ service_name ++ " is missing `" ++ function.name ++ "`, which must be " ++ function.expected_name);
        }
        const Found = @TypeOf(@field(Service, function.name));
        if (Found != function.Expected) @compileError("zui: " ++ service_name ++ "." ++ function.name ++ " must be " ++ function.expected_name ++ ", found " ++ @typeName(Found));
    }
}

const ServiceFunction = struct {
    service: []const u8,
    name: []const u8,
    Expected: type,
    expected_name: []const u8,
    optional: bool = false,
};

/// Each function of each service, in the order they are checked.
fn serviceFunctions(comptime Host: type) []const ServiceFunction {
    const host_pointer = "*" ++ @typeName(Host);
    const ServiceError = services.ServiceError;
    return &.{
        .{
            .service = "zuiClipboard",
            .name = "write",
            .Expected = fn (*Host, []const u8) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", []const u8) zui.ServiceError!void",
        },
        .{
            .service = "zuiClipboard",
            .name = "read",
            .Expected = fn (*Host, services.ServiceRequest, services.ServiceSink) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.ServiceRequest, zui.ServiceSink) zui.ServiceError!void",
        },
        .{
            .service = "zuiNotifications",
            .name = "show",
            .Expected = fn (*Host, services.ServiceRequest, services.Notification, services.ServiceSink) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.ServiceRequest, zui.Notification, zui.ServiceSink) zui.ServiceError!void",
        },
        .{
            .service = "zuiFileDialogs",
            .name = "show",
            .Expected = fn (*Host, host.WindowId, services.ServiceRequest, services.FileDialog, services.ServiceSink) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId, zui.ServiceRequest, zui.FileDialog, zui.ServiceSink) zui.ServiceError!void",
        },
        .{
            .service = "zuiOpenUrl",
            .name = "open",
            .Expected = fn (*Host, []const u8) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", []const u8) zui.ServiceError!void",
        },
        .{
            .service = "zuiMenus",
            .name = "popup",
            .Expected = fn (*Host, host.WindowId, services.ServiceRequest, []const services.MenuItem, [2]f32, services.ServiceSink) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, [2]f32, zui.ServiceSink) zui.ServiceError!void",
        },
        .{
            .service = "zuiMenus",
            .name = "setBar",
            .Expected = fn (*Host, host.WindowId, services.ServiceRequest, []const services.MenuItem, services.ServiceSink) ServiceError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, zui.ServiceSink) zui.ServiceError!void",
            .optional = true,
        },
        .{
            .service = "zuiFileWatch",
            .name = "watch",
            .Expected = fn (*Host, []const u8, host.FileChangeSink) host.FileWatchError!void,
            .expected_name = "fn (" ++ host_pointer ++ ", []const u8, zui.FileChangeSink) zui.FileWatchError!void",
        },
    };
}

fn checkLoopCalls(comptime Host: type) void {
    const name = @typeName(Host);
    const host_pointer = "*" ++ name;
    const waits = @hasDecl(Host, "zuiWait");
    const runs = @hasDecl(Host, "zuiRun");
    if (waits and runs) @compileError("zui: " ++ name ++ " declares both `zuiWait` and `zuiRun`; zui pulls a host's loop or the platform pushes it, never both");
    if (waits) expectHostCall(Host, "zuiWait", fn (*Host, record.NextFrame) void, "fn (" ++ host_pointer ++ ", zui.NextFrame) void");
    if (!runs) return;
    const Run = @TypeOf(Host.zuiRun);
    const runs_a_loop = switch (@typeInfo(Run)) {
        .@"fn" => |function| function.params.len == 4 and function.params[0].type == *Host and function.params[1].type == std.Io and
            function.params[2].type == host.WindowOptions and function.params[3].type == host.Driver and
            if (function.return_type) |Returned| Returned == noreturn or (@typeInfo(Returned) == .error_union and @typeInfo(Returned).error_union.payload == void) else false,
        else => false,
    };
    if (!runs_a_loop) @compileError("zui: " ++ name ++ ".zuiRun must be fn (" ++ host_pointer ++ ", std.Io, zui.WindowOptions, zui.Driver) !void, or noreturn, found " ++ @typeName(Run));
}

fn checkWindowCalls(comptime Host: type) void {
    const name = @typeName(Host);
    const host_pointer = "*" ++ name;
    const many_windows = @hasDecl(Host, "zui_capabilities") and Host.zui_capabilities.windows == .many;
    const calls = [_]HostCall{
        .{
            .declaration = "zuiOpenWindow",
            .Expected = fn (*Host, host.WindowOptions) host.OpenWindowError!host.WindowId,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowOptions) zui.OpenWindowError!zui.WindowId",
        },
        .{
            .declaration = "zuiCloseWindow",
            .Expected = fn (*Host, host.WindowId) void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId) void",
        },
    };
    inline for (calls) |call| {
        const declared = @hasDecl(Host, call.declaration);
        if (many_windows and !declared) {
            @compileError("zui: " ++ name ++ " declares zui_capabilities.windows = .many but not `" ++ call.declaration ++ "`, which must be " ++ call.expected_name);
        }
        if (!many_windows and declared) @compileError("zui: " ++ name ++ " declares `" ++ call.declaration ++ "`, but its zui_capabilities.windows is .one");
        if (declared) expectHostCall(Host, call.declaration, call.Expected, call.expected_name);
    }
}

const HostCall = struct {
    declaration: []const u8,
    Expected: type,
    expected_name: []const u8,
};

/// Each takes the window and a slice of the frame's data, which is valid
/// only during the call.
fn hostFrameCalls(comptime Host: type) []const HostCall {
    const host_pointer = "*" ++ @typeName(Host);
    return &.{
        .{
            .declaration = "zuiSemantics",
            .Expected = fn (*Host, host.WindowId, []const semantics.SemanticNode) semantics.SemanticsDropped,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId, []const zui.SemanticNode) zui.SemanticsDropped",
        },
        .{
            .declaration = "zuiChromeRegions",
            .Expected = fn (*Host, host.WindowId, []const chrome.ChromeRegion) void,
            .expected_name = "fn (" ++ host_pointer ++ ", zui.WindowId, []const zui.ChromeRegion) void",
        },
    };
}

fn checkOutputFormats(comptime Party: type) void {
    if (!@hasDecl(Party, "zui_output_formats")) return;
    expectDeclarationType(Party, "zui_output_formats", surface.OutputFormats, "zui.OutputFormats");
    if (!Party.zui_output_formats.contains(.sdr)) {
        @compileError("zui: " ++ @typeName(Party) ++ ".zui_output_formats does not include .sdr, which every window falls back to");
    }
}

/// `expected_name` spells zui's types as the application does: their own
/// type names would be the files that declare them.
fn expectHostCall(comptime Host: type, comptime declaration: []const u8, comptime Expected: type, comptime expected_name: []const u8) void {
    const Found = @TypeOf(@field(Host, declaration));
    if (Found != Expected) @compileError("zui: " ++ @typeName(Host) ++ "." ++ declaration ++ " must be " ++ expected_name ++ ", found " ++ @typeName(Found));
}

/// Both contracts, and a surface kind the host gives and the renderer
/// draws into.
pub fn checkHostAndRenderer(comptime Host: type, comptime Renderer: type) void {
    checkHost(Host);
    checkRenderer(Renderer);
    if (Host.zui_surfaces.intersectWith(Renderer.zui_surfaces).count() == 0) {
        @compileError("zui: " ++ @typeName(Host) ++ " and " ++ @typeName(Renderer) ++ " share no surface kind: the host gives " ++
            surfaceKindNames(Host.zui_surfaces) ++ ", the renderer draws into " ++ surfaceKindNames(Renderer.zui_surfaces));
    }
}

/// `.win32, .x11`
fn surfaceKindNames(comptime kinds: surface.SurfaceKinds) []const u8 {
    var names: []const u8 = "";
    for (std.enums.values(surface.SurfaceKind)) |kind| {
        if (!kinds.contains(kind)) continue;
        names = names ++ (if (names.len == 0) "." else ", .") ++ @tagName(kind);
    }
    return names;
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

/// The appearance contract, for `Tokens` whose extra roles are
/// `ExtraRoles`: a `Part` enum and a `zuiAppearance` declaring each of its
/// parts, each text and icon drawn `.on` a part with a surface, each
/// `.unchecked` color with a reason, and optionally `zuiDistinguish`.
pub fn checkAppearance(comptime Component: type, comptime ExtraRoles: type) void {
    const name = @typeName(Component);
    if (@typeInfo(Component) != .@"struct") @compileError("zui: a component must be a struct type, got " ++ name);
    checkKnownDeclarations(Component);
    if (!@hasDecl(Component, "Part")) @compileError("zui: " ++ name ++ " declares no `Part`, the enum of its parts");
    if (!@hasDecl(Component, "zuiAppearance")) @compileError("zui: " ++ name ++ " declares no `zuiAppearance`");
    const Part = Component.Part;
    const Declared = Component.zuiAppearance;
    const declares_appearance = @TypeOf(Declared) == type and @typeInfo(Declared) == .@"struct" and
        @hasDecl(Declared, "parts") and @hasDecl(Declared, "Part") and @hasDecl(Declared, "ExtraRoles") and Declared.Part == Part;
    if (!declares_appearance) @compileError("zui: " ++ name ++ ".zuiAppearance must be a zui.design.Appearance(" ++ @typeName(Part) ++ ", …)");
    if (Declared.ExtraRoles != void and Declared.ExtraRoles != ExtraRoles) {
        @compileError("zui: " ++ name ++ "'s appearance names the extra roles " ++ @typeName(Declared.ExtraRoles) ++ ", but the tokens' extra roles are " ++ @typeName(ExtraRoles));
    }
    for (std.meta.fieldNames(Part)) |part_name| {
        const part = @field(Declared.parts, part_name) orelse
            @compileError("zui: " ++ name ++ "'s appearance has no part `" ++ part_name ++ "` of " ++ @typeName(Part));
        checkPartAppearance(Component, Declared.parts, part_name, part);
    }
    if (@hasDecl(Component, "zuiDistinguish")) checkDistinguish(Component);
}

fn checkPartAppearance(comptime Component: type, comptime parts: anytype, comptime part_name: []const u8, comptime part: anytype) void {
    const name = @typeName(Component) ++ "." ++ part_name;
    var draws_text = part.text != null;
    var draws_icon = part.icon != null;
    checkUncheckedReasons(name, part);
    for (std.meta.fieldNames(@TypeOf(part.states))) |state| {
        const colors = @field(part.states, state) orelse continue;
        draws_text = draws_text or colors.text != null;
        draws_icon = draws_icon or colors.icon != null;
        checkUncheckedReasons(name, colors);
    }
    if (draws_text and draws_icon) @compileError("zui: " ++ name ++ " draws both text and an icon; give each a part of its own");
    const on = part.on orelse {
        if (draws_text) @compileError("zui: " ++ name ++ " draws text but names no part it is drawn `.on`");
        if (draws_icon) @compileError("zui: " ++ name ++ " draws an icon but names no part it is drawn `.on`");
        return;
    };
    const on_name = @tagName(on);
    if (!@hasField(Component.Part, on_name)) @compileError("zui: " ++ name ++ " is drawn on `" ++ on_name ++ "`, which is not a part of " ++ @typeName(Component.Part));
    const beneath = @field(parts, on_name) orelse return;
    if (beneath.surface == null) @compileError("zui: " ++ name ++ " is drawn on `" ++ on_name ++ "`, which has no surface");
}

fn checkUncheckedReasons(comptime name: []const u8, comptime colors: anytype) void {
    inline for (.{ colors.surface, colors.text, colors.icon, colors.outline }) |maybe_choice| {
        const choice = maybe_choice orelse continue;
        if (choice == .unchecked_color and choice.unchecked_color.reason.len == 0) @compileError("zui: " ++ name ++ "'s `.unchecked` color needs a reason");
    }
}

/// Each entry is two parts, `.{ .checked, .unchecked }`, or a part and two
/// states, `.{ .row, .idle, .hovered }`.
fn checkDistinguish(comptime Component: type) void {
    const name = @typeName(Component) ++ ".zuiDistinguish";
    const Part = Component.Part;
    inline for (Component.zuiDistinguish) |entry| {
        const Entry = @TypeOf(entry);
        const is_tuple = @typeInfo(Entry) == .@"struct" and @typeInfo(Entry).@"struct".is_tuple;
        if (!is_tuple or (entry.len != 2 and entry.len != 3)) @compileError("zui: each entry of " ++ name ++ " is two parts, or a part and two states");
        const part_count = if (entry.len == 2) 2 else 1;
        inline for (0..entry.len) |index| {
            const tag = @tagName(entry[index]);
            if (index < part_count) {
                if (!@hasField(Part, tag)) @compileError("zui: " ++ name ++ " names `" ++ tag ++ "`, which is not a part of " ++ @typeName(Part));
            } else if (!@hasField(WidgetState, tag)) {
                @compileError("zui: " ++ name ++ " names `" ++ tag ++ "`, which is not a zui.WidgetState");
            }
        }
    }
}

/// `void`, or an enum of roles that are not `ColorRole`s, declaring
/// `zuiPairs`: the role each of its roles is checked against.
pub fn checkExtraRoles(comptime ExtraRoles: type) void {
    if (ExtraRoles == void) return;
    const name = @typeName(ExtraRoles);
    if (@typeInfo(ExtraRoles) != .@"enum") @compileError("zui: ExtraRoles must be an enum or void, got " ++ name);
    for (std.meta.fieldNames(ExtraRoles)) |role| {
        if (@hasField(design.ColorRole, role)) @compileError("zui: " ++ name ++ "'s `" ++ role ++ "` is already a zui.design.ColorRole");
    }
    if (!@hasDecl(ExtraRoles, "zuiPairs")) @compileError("zui: " ++ name ++ " declares no `zuiPairs`, the role each of its roles pairs with");
    const pairs = ExtraRoles.zuiPairs;
    for (std.meta.fieldNames(@TypeOf(pairs))) |role| {
        if (!@hasField(ExtraRoles, role)) @compileError("zui: " ++ name ++ ".zuiPairs names `" ++ role ++ "`, which is not a role of " ++ name);
        const partner = @tagName(@field(pairs, role));
        if (!@hasField(design.ColorRole, partner) and !@hasField(ExtraRoles, partner)) {
            @compileError("zui: " ++ name ++ ".zuiPairs pairs `" ++ role ++ "` with `" ++ partner ++ "`, which is neither a zui.design.ColorRole nor a role of " ++ name);
        }
    }
    for (std.meta.fieldNames(ExtraRoles)) |role| {
        if (!@hasField(@TypeOf(pairs), role)) @compileError("zui: " ++ name ++ ".zuiPairs gives no pair for `" ++ role ++ "`");
    }
}

/// A component's `zuiPreviews`, the content it is shown with under review:
/// a struct literal of named previews, each the same type.
///
/// ```zig
/// pub const zuiPreviews = .{
///     .short = Content{ .label = "Save" },
///     .long = Content{ .label = "Save every change to every open document" },
/// };
/// ```
pub fn checkPreviews(comptime Component: type) void {
    const name = @typeName(Component) ++ ".zuiPreviews";
    const Previews = @TypeOf(Component.zuiPreviews);
    const info = @typeInfo(Previews);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("zui: " ++ name ++ " must be a struct of named previews, such as .{ .short = …, .long = … }, got " ++ @typeName(Previews));
    }
    const fields = info.@"struct".fields;
    if (fields.len == 0) @compileError("zui: " ++ name ++ " names no preview");
    for (fields[1..]) |field| {
        if (field.type != fields[0].type) {
            @compileError("zui: " ++ name ++ "." ++ field.name ++ " is a " ++ @typeName(field.type) ++ ", but ." ++ fields[0].name ++ " is a " ++ @typeName(fields[0].type) ++ "; every preview is the same type");
        }
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
