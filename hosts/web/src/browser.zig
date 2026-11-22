const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");
const DemoUi = @import("demo_ui.zig").DemoUi;
const Renderer = @import("zui_webgl").Renderer;
const Text = @import("text.zig").Text;
const browser_input = @import("browser_input.zig");

pub const DemoStream = @import("frame_stream.zig").FrameStream(DemoUi);
pub const DemoRecords = @import("record_stream.zig").RecordStream(DemoUi);

pub var stream: DemoStream = undefined;
/// The frame decoded last, which is the one to draw.
pub var newest: ?*const DemoStream.Frame = null;
pub var records: DemoRecords = undefined;
var renderer: Renderer = .{};
var text: Text = undefined;
var last_error: ?anyerror = null;
const canvas_surface: zui.Surface = .{ .web = .{ .canvas = 0 } };
const key_name_bytes_most = 64;
var key_names: [2 * key_name_bytes_most]u8 = undefined;
var typed_text: [DemoUi.limits.max_text_input_bytes]u8 = undefined;
var taken_record: []const u8 = &.{};

/// Reserves the client's memory. False when the browser has too little.
/// The fonts the stream's text uses are handed over before its first
/// frame, with `zuiWebAddTrueTypeFont`. The module draws through
/// `frameDrawerImports`, from web/frame_drawer.mjs.
///
/// ```js
/// const drawers = new Map();
/// const { instance } = await WebAssembly.instantiate(bytes, frameDrawerImports(drawers, () => instance.exports.memory));
/// const wasm = instance.exports;
/// wasm.zuiWebInit();
/// drawers.set(0, new FrameDrawer(canvas));
/// for (const font of [regularTtf, boldTtf, monoTtf]) {
///   new Uint8Array(wasm.memory.buffer, wasm.zuiWebRoomForFont(font.length), font.length).set(font);
///   wasm.zuiWebAddTrueTypeFont(font.length);
/// }
/// socket.onmessage = ({ data }) => {
///   const bytes = new Uint8Array(data);
///   const room = wasm.zuiWebRoomFor(bytes.length);
///   new Uint8Array(wasm.memory.buffer, room, bytes.length).set(bytes);
///   wasm.zuiWebReceived(bytes.length);
///   while (wasm.zuiWebNextFrame() > 0) {}
///   wasm.zuiWebDrawNewestFrame(0);
///   recorder.applyHostRequests(); // InputRecorder, from web/input_recorder.mjs
/// };
/// requestAnimationFrame(function send() {
///   const record = recorder.takeRecord();
///   if (record) socket.send(record);
///   requestAnimationFrame(send);
/// });
/// ```
export fn zuiWebInit() bool {
    stream = DemoStream.init(std.heap.wasm_allocator, .{}) catch |err| {
        last_error = err;
        return false;
    };
    text = Text.init(std.heap.wasm_allocator) catch |err| {
        last_error = err;
        return false;
    };
    renderer.init(canvas_surface, &text) catch |err| {
        last_error = err;
        return false;
    };
    records = DemoRecords.init(std.heap.wasm_allocator, .{}) catch |err| {
        last_error = err;
        return false;
    };
    return true;
}

/// Where to write the next TrueType font's `count` bytes, or 0 when they
/// do not fit.
export fn zuiWebRoomForFont(count: usize) usize {
    const room = text.roomForFont(count) orelse return 0;
    return @intFromPtr(room.ptr);
}

/// Adds the TrueType font written to `zuiWebRoomForFont`, returning its
/// `FontId`, which follows those added before it, or -1 when it cannot be
/// read, as `zuiWebErrorName` says. From then
/// on, a stream measured with other fonts is refused.
export fn zuiWebAddTrueTypeFont(count: usize) i32 {
    const font = text.addTrueTypeFont(count) catch |err| {
        last_error = err;
        return -1;
    };
    stream.fingerprint = zui_wire.fingerprintOf(&text);
    return font;
}

/// Since `zuiWebInit`, how often a frame left glyphs out because the atlas
/// was full, or stb_truetype ran out of memory rasterizing one.
export fn zuiWebGlyphOverflows() u32 {
    return renderer.glyphOverflows();
}

/// Where to write the next `count` bytes of the stream, or 0 when they do
/// not fit until frames are taken with `zuiWebNextFrame`.
export fn zuiWebRoomFor(count: usize) usize {
    const room = stream.roomFor(count) catch |err| {
        last_error = err;
        return 0;
    };
    return @intFromPtr(room.ptr);
}

export fn zuiWebReceived(count: usize) void {
    stream.received(count);
}

/// 1 when another frame was decoded, 0 until more of the stream arrives,
/// -1 when the stream cannot be read, as `zuiWebErrorName` says.
export fn zuiWebNextFrame() i32 {
    newest = (stream.nextFrame() catch |err| {
        last_error = err;
        return -1;
    }) orelse return 0;
    return 1;
}

export fn zuiWebFrameNumber() u64 {
    return if (newest) |frame| frame.number else 0;
}

export fn zuiWebCommandCount() usize {
    return if (newest) |frame| frame.commands().len else 0;
}

/// The last failure, as a C string, or an empty one.
export fn zuiWebErrorName() [*:0]const u8 {
    return if (last_error) |err| @errorName(err) else "";
}

/// Draws the newest frame on the canvas `canvas` names in the page's
/// `frameDrawerImports`: false, drawing nothing, before the first frame.
export fn zuiWebDrawNewestFrame(canvas: u32) bool {
    const frame = newest orelse return false;
    renderer.zuiSubmit(.{ .web = .{ .canvas = canvas } }, frame) catch unreachable;
    return true;
}

/// Since `zuiWebInit`, how often a frame left a shape out, drew a clip
/// or transform as its parent, or a blur or material as what it lowers
/// to, because the draw list was full.
export fn zuiWebDrawListOverflows() u32 {
    return renderer.drawListOverflows();
}

/// The canvas's size in CSS pixels, which are layout units, and
/// `devicePixelRatio`; a record is sent when either changes.
export fn zuiWebMeasure(width: f32, height: f32, scale: f32) void {
    records.measure(.{ width, height }, scale);
}

/// A button pressed, `MouseEvent.button`, by a pointer of the kind
/// `BrowserPointerKind` numbers, at a place in CSS pixels from the canvas's
/// top-left, at `Event.timeStamp`. Pressure is from 0 to 1 and tilt in
/// degrees, as `PointerEvent` reports them.
export fn zuiWebPointerDown(browser_pointer_id: u32, browser_kind: u32, browser_button: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
    const pressed = browser_input.button(browser_button) orelse return;
    records.builder.append(.{ .pointer_down = .{ .pointer = pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds), .button = pressed } });
}

export fn zuiWebPointerUp(browser_pointer_id: u32, browser_kind: u32, browser_button: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
    const released = browser_input.button(browser_button) orelse return;
    records.builder.append(.{ .pointer_up = .{ .pointer = pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds), .button = released } });
}

export fn zuiWebPointerMove(browser_pointer_id: u32, browser_kind: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
    records.builder.append(.{ .pointer_move = .{ .pointer = pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds) } });
}

/// The browser took the pointer, as `pointercancel` says.
export fn zuiWebPointerCancel(browser_pointer_id: u32, browser_kind: u32) void {
    records.builder.append(.{ .pointer_cancel = browser_input.pointerId(browser_input.pointerKind(browser_kind), browser_pointer_id) });
}

/// A hovering pointer left the canvas.
export fn zuiWebPointerLeave(browser_pointer_id: u32, browser_kind: u32) void {
    records.builder.append(.{ .pointer_leave = browser_input.pointerId(browser_input.pointerKind(browser_kind), browser_pointer_id) });
}

fn pointer(browser_pointer_id: u32, browser_kind: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) zui.Pointer {
    const kind = browser_input.pointerKind(browser_kind);
    return .{
        .id = browser_input.pointerId(kind, browser_pointer_id),
        .kind = kind,
        .position = .{ x, y },
        .at = browser_input.instant(at_milliseconds),
        .pressure = if (kind == .mouse) 1 else pressure,
        .tilt = .{ std.math.degreesToRadians(tilt_x), std.math.degreesToRadians(tilt_y) },
    };
}

/// A `WheelEvent`'s place in CSS pixels from the canvas's top-left, its
/// deltas and their `deltaMode`.
export fn zuiWebWheel(x: f32, y: f32, delta_x: f32, delta_y: f32, browser_delta_mode: u32, at_milliseconds: f64) void {
    records.builder.append(.{ .wheel = .{
        .position = .{ x, y },
        .delta = browser_input.wheelDelta(.{ delta_x, delta_y }, browser_delta_mode, records.builder.params.viewport),
        .at = browser_input.instant(at_milliseconds),
    } });
}

/// Where to write a `KeyboardEvent`'s `key` in UTF-8, and its `code` at
/// `zuiWebKeyNameBytesMost` bytes after it, before `zuiWebKey`.
export fn zuiWebKeyNames() usize {
    return @intFromPtr(&key_names);
}

export fn zuiWebKeyNameBytesMost() usize {
    return key_name_bytes_most;
}

/// A key pressed or released, its names written to `zuiWebKeyNames`, with
/// the modifiers held as `browser_input.modifiers` reads them.
export fn zuiWebKey(down: bool, key_bytes: usize, code_bytes: usize, browser_modifier_bits: u32, repeat: bool, at_milliseconds: f64) void {
    const key = key_names[0..@min(key_bytes, key_name_bytes_most)];
    const code = key_names[key_name_bytes_most..][0..@min(code_bytes, key_name_bytes_most)];
    const event: zui.KeyEvent = .{
        .key = browser_input.logicalKey(key, code),
        .modifiers = browser_input.modifiers(browser_modifier_bits),
        .repeat = repeat,
        .scancode = browser_input.scancode(code),
        .at = browser_input.instant(at_milliseconds),
    };
    records.builder.append(if (down) .{ .key_down = event } else .{ .key_up = event });
}

/// Where to write up to `zuiWebTypedTextBytesMost` bytes of committed
/// UTF-8 before `zuiWebTyped`.
export fn zuiWebTypedText() usize {
    return @intFromPtr(&typed_text);
}

export fn zuiWebTypedTextBytesMost() usize {
    return typed_text.len;
}

export fn zuiWebTyped(count: usize) void {
    records.builder.appendText(typed_text[0..@min(count, typed_text.len)]);
}

/// Writes the record to send at `performance.now()`, returning how many
/// bytes `zuiWebRecordBytes` holds, the stream's header first: 0 when
/// nothing happened since the last, or -1 when the record was too large
/// and its events were dropped, as `zuiWebErrorName` says.
export fn zuiWebTakeRecord(now_milliseconds: f64) i32 {
    const taken = records.take(browser_input.instant(now_milliseconds)) catch |err| {
        last_error = err;
        return -1;
    };
    const bytes = taken orelse return 0;
    taken_record = bytes;
    return @intCast(bytes.len);
}

export fn zuiWebRecordBytes() usize {
    return @intFromPtr(taken_record.ptr);
}

/// Since `zuiWebInit`, input events the records had no room for.
export fn zuiWebDroppedEvents() u32 {
    return records.dropped_events;
}

/// The CSS `cursor` the newest frame asks for, as a C string.
export fn zuiWebCursorName() [*:0]const u8 {
    const requests = if (newest) |frame| frame.requests() else zui.HostRequests{};
    return browser_input.cursorName(requests.cursor);
}
