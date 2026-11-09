const std = @import("std");
const context = @import("context.zig");
const style = @import("style.zig");
const text = @import("text.zig");
const id = @import("id.zig");
const interaction = @import("interaction.zig");
const input = @import("input.zig");
const record = @import("record.zig");
const trace = @import("trace.zig");
const sources = @import("sources.zig");
const commands = @import("commands.zig");
const surface = @import("surface.zig");
const host = @import("host.zig");
const contracts = @import("contracts.zig");

pub const Context = context.Context;
pub const Config = context.Config;
pub const Limits = context.Limits;
pub const Features = context.Features;
pub const Limit = context.Limit;
pub const Element = context.Element;
pub const Diagnostics = context.Diagnostics;

pub const TraceZone = trace.TraceZone;

pub const OptionalCommand = commands.OptionalCommand;
pub const CommandSet = commands.CommandSet;
pub const Surface = surface.Surface;
pub const SurfaceKind = surface.SurfaceKind;
pub const SurfaceKinds = surface.SurfaceKinds;

/// Fails to compile, with a message naming the declaration, unless
/// `Renderer` implements the renderer contract: `zuiSubmit` and
/// `zui_surfaces`, and optionally `zui_commands`, `zui_extended_color`,
/// `zui_render_thread` (`zuiSubmit` may run on a thread other than the
/// one that made the renderer) and the payload types `ImageHandle`, `MaterialHandle`, `CustomData` and
/// `FontId`.
///
/// ```zig
/// pub fn config(overrides: zui.Config) zui.Config {
///     comptime zui.checkRenderer(Renderer);
///     var result = overrides;
///     result.commands = Renderer.zui_commands;
///     return result;
/// }
/// ```
pub const checkRenderer = contracts.checkRenderer;

pub const WindowId = host.WindowId;
pub const HostCapabilities = host.HostCapabilities;
pub const WindowOptions = host.WindowOptions;
pub const SystemMaterial = host.SystemMaterial;
pub const FileChange = host.FileChange;
pub const FileChangeSink = host.FileChangeSink;
pub const FileWatchError = host.FileWatchError;

/// Fails to compile, with a message naming the declaration, unless `Host`
/// implements the host contract: `zuiPoll`, `zuiWaker`, `zuiWait`,
/// `zuiSurface`, `zuiApply` and `zui_surfaces`, and optionally
/// `zui_capabilities` and the services (`zuiClipboard`, `zuiFileDialogs`
/// and the rest), each a type. `zuiFileWatch` declares
/// `watch(host, directory, sink) zui.FileWatchError!void`. A host's `zuiWaker` must be sticky: a wake
/// that arrives while the loop is not waiting ends its next wait.
pub const checkHost = contracts.checkHost;

/// `checkHost` and `checkRenderer`, and fails to compile, naming both,
/// unless the host gives a surface kind the renderer draws into. The
/// composition root calls it, as it is the one place naming both:
///
/// ```zig
/// comptime zui.checkHostAndRenderer(zui_raylib.Host, zui_raylib.Renderer);
/// ```
pub const checkHostAndRenderer = contracts.checkHostAndRenderer;

pub const Waker = sources.Waker;
pub const Wake = sources.Wake;
pub const EndFrameInfo = sources.EndFrameInfo;
pub const Status = sources.Status;
pub const StatusWithProgress = sources.StatusWithProgress;
pub const Deliveries = sources.Deliveries;

pub const Instant = record.Instant;
pub const FrameParams = record.FrameParams;
pub const FrameRecord = record.FrameRecord;
pub const FrameRecordWith = record.FrameRecordWith;
pub const Relay = record.Relay;
pub const RecordBuilder = record.RecordBuilder;
pub const NextFrame = record.NextFrame;
pub const HostRequests = record.HostRequests;
pub const Cursor = record.Cursor;
pub const TextInputArea = record.TextInputArea;
pub const SemanticNode = record.SemanticNode;

pub const Event = input.Event;
pub const Pointer = input.Pointer;
pub const PointerId = input.PointerId;
pub const PointerKind = input.PointerKind;
pub const PointerButton = input.PointerButton;
pub const PointerMove = input.PointerMove;
pub const Button = input.Button;
pub const Wheel = input.Wheel;
pub const Manipulation = input.Manipulation;
pub const NavigationDirection = input.NavigationDirection;
pub const PointerEvents = input.PointerEvents;
pub const Key = input.Key;
pub const KeyEvent = input.KeyEvent;
pub const Modifiers = input.Modifiers;
pub const Chord = input.Chord;
pub const InputSampler = input.InputSampler;
pub const Environment = input.Environment;
pub const EnvironmentChange = input.EnvironmentChange;
pub const ReadingDirection = input.ReadingDirection;
pub const Locale = input.Locale;
pub const FilesDropped = input.FilesDropped;
pub const Lifecycle = input.Lifecycle;
pub const LifecycleSet = input.LifecycleSet;

pub const Id = id.Id;
pub const ids = id.ids;

pub const Axis = style.Axis;
pub const Axes = style.Axes;
pub const Color = style.Color;
pub const Edges = style.Edges;
pub const CornerRadius = style.CornerRadius;
pub const Rect = style.Rect;
pub const Border = style.Border;
pub const Decoration = style.Decoration;
pub const Style = style.Style;
pub const Static = style.Static;
pub const static = style.static;
pub const Sizing = style.Sizing;
pub const Sizing2 = style.Sizing2;
pub const Direction = style.Direction;
pub const Mirrored = style.Mirrored;
pub const Alignment = style.Alignment;
pub const Alignment2 = style.Alignment2;
pub const Layout = style.Layout;
pub const TextWrap = style.TextWrap;
pub const MeasureKey = style.MeasureKey;
pub const BreakSink = text.BreakSink;
pub const Scroll = style.Scroll;
pub const Floating = style.Floating;
pub const AttachTo = style.AttachTo;
pub const FloatingClip = style.FloatingClip;
pub const AnchorPoint = style.AnchorPoint;

pub const WidgetState = interaction.WidgetState;
pub const ScrollState = interaction.ScrollState;
pub const Gestures = interaction.Gestures;
pub const Momentum = interaction.Momentum;

test {
    std.testing.refAllDecls(@This());
    _ = @import("commands.zig");
    _ = @import("text.zig");
    _ = @import("input.zig");
    _ = @import("state.zig");
    _ = @import("parallel_measure.zig");
    _ = @import("sources.zig");
    _ = @import("tests/golden.zig");
    _ = @import("tests/invariants.zig");
    _ = @import("tests/memory.zig");
    _ = @import("tests/interaction.zig");
    _ = @import("tests/layers.zig");
    _ = @import("tests/frames.zig");
    _ = @import("tests/parallel.zig");
    _ = @import("tests/tracing.zig");
    _ = @import("tests/sources.zig");
    _ = @import("tests/renderers.zig");
    _ = @import("tests/hosts.zig");
    _ = @import("tests/relay.zig");
    _ = @import("tests/styles.zig");
    _ = @import("tests/segmentation.zig");
    _ = @import("tests/mirroring.zig");
    _ = @import("tests/wrapping.zig");
    _ = @import("tests/gestures.zig");
}
