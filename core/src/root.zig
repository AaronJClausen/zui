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
const services = @import("services.zig");
const contracts = @import("contracts.zig");
const semantics = @import("semantics.zig");
const chrome = @import("chrome.zig");
const exit = @import("exit.zig");
const sweeps = @import("sweeps.zig");

pub const Context = context.Context;
pub const Config = context.Config;
pub const Limits = context.Limits;
pub const Features = context.Features;
pub const Limit = context.Limit;
pub const Element = context.ElementWith(style.Decoration);
pub const ElementWith = context.ElementWith;
pub const Diagnostics = context.Diagnostics;
/// What `Frame.inspect` reports of an element's declaration and layout.
pub const ElementFlags = context.ElementFlags;

pub const TraceZone = trace.TraceZone;

pub const Invariant = sweeps.Invariant;
pub const SweepFailure = sweeps.SweepFailure;

pub const OptionalCommand = commands.OptionalCommand;
pub const CommandSet = commands.CommandSet;
pub const cornerShapeOf = commands.cornerShapeOf;
pub const Surface = surface.Surface;
pub const SurfaceKind = surface.SurfaceKind;
pub const SurfaceKinds = surface.SurfaceKinds;
pub const OutputFormat = surface.OutputFormat;
pub const OutputFormats = surface.OutputFormats;
pub const declaredOutputFormats = surface.declaredOutputFormats;
pub const sharedOutputFormats = surface.sharedOutputFormats;

/// Fails to compile, with a message naming the declaration, unless
/// `Renderer` implements the renderer contract: `zuiSubmit` and
/// `zui_surfaces`, and optionally `zui_commands`, `zui_extended_color`,
/// `zui_render_thread` (`zuiSubmit` may run on a thread other than the
/// one that made the renderer), `zui_output_formats` (with `.sdr`, and
/// `.scrgb_fp16` only beside `zui_extended_color`) and the payload types
/// `ImageHandle`, `MaterialHandle`, `CustomData` and `FontId`.
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

/// Checks a component's `zuiPreviews`, the content it is shown with under
/// review.
pub const checkPreviews = contracts.checkPreviews;

pub const WindowId = host.WindowId;
pub const HostCapabilities = host.HostCapabilities;
pub const WindowOptions = host.WindowOptions;
pub const Driver = host.Driver;
pub const OpenWindowError = host.OpenWindowError;
pub const SystemMaterial = host.SystemMaterial;
pub const TitleBar = host.TitleBar;
pub const FileChange = host.FileChange;
pub const FileChangeSink = host.FileChangeSink;
pub const FileWatchError = host.FileWatchError;
pub const ServiceRequest = services.ServiceRequest;
pub const ServiceError = services.ServiceError;
pub const ServiceFailure = services.ServiceFailure;
pub const ServiceAnswer = services.ServiceAnswer;
pub const ServiceReply = services.ServiceReply;
pub const ServiceSink = services.ServiceSink;
pub const Notification = services.Notification;
pub const FileDialog = services.FileDialog;
pub const FileFilter = services.FileFilter;
pub const MenuItemId = services.MenuItemId;
pub const MenuItem = services.MenuItem;
pub const isOpenableUrl = services.isOpenableUrl;

/// Fails to compile, with a message naming the declaration, unless `Host`
/// implements the host contract: its window half, `zuiPoll`, `zuiWaker`,
/// `zuiSurface`, `zuiApply` and `zui_surfaces`; at most one loop half,
/// `zuiWait` for a loop zui pulls or `zuiRun` for one the platform
/// pushes, neither for a host only the application's own loop steps; and
/// optionally
/// `zui_capabilities` (with `custom_title_bar` only beside
/// `zuiChromeRegions`), `zui_output_formats` (with `.sdr`), the frame calls
/// `zuiSemantics` and `zuiChromeRegions`, and the services
/// (`zuiClipboard`, `zuiNotifications`, `zuiFileDialogs`, `zuiOpenUrl`,
/// `zuiMenus`, `zuiFileWatch`), each a struct of functions taking the host
/// first, whose types it checks. A host's `zuiWaker` must be sticky: a wake
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

pub const SemanticNode = semantics.SemanticNode;
pub const Semantics = semantics.Semantics;
pub const SemanticRole = semantics.Role;
pub const SemanticValue = semantics.Value;
pub const SemanticRange = semantics.Range;
pub const SemanticState = semantics.State;
pub const SemanticScroll = semantics.SemanticScroll;
pub const Action = semantics.Action;
pub const ActionKind = semantics.ActionKind;
pub const Actions = semantics.Actions;
pub const ActionEvent = semantics.ActionEvent;
pub const SemanticsCapacity = semantics.SemanticsCapacity;
pub const SemanticsDropped = semantics.SemanticsDropped;

pub const ChromeKind = chrome.ChromeKind;
pub const ChromeRegion = chrome.ChromeRegion;

/// The design vocabulary: the roles, tiers and appearance contract a
/// component declares its look in, `Design`, what an application or a
/// theme pack declares, and `Tokens`, the resolved values a frame reads.
///
/// ```zig
/// const look = app.tokens.look(Chip, .container, ui.widgetState(id));
/// ui.open(.{ .id = id, .decoration = look.decoration, .layout = .{ .padding = look.padding, .child_gap = app.tokens.space(.xs) } });
/// ```
pub const design = @import("design.zig");

/// Tweens and springs over `ui.state`, which ask for frames only while
/// they move and land at once when the user asks for reduced motion.
///
/// ```zig
/// const opacity = zui.motion.tween(ui, .of("toast"), f32, if (app.importing) 1 else 0, app.tokens.motion.toast_exit);
/// const drawer_x = zui.motion.spring(ui, .of("drawer"), f32, if (app.drawer_open) 0 else -280, app.tokens.motion.drawer);
/// ```
pub const motion = @import("motion.zig");

pub const Exit = exit.Exit;
pub const ExitFade = exit.ExitFade;

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
pub const Drag = input.Drag;
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
pub const ExtendedColor = style.ExtendedColor;
pub const Edges = style.Edges;
pub const CornerRadius = style.CornerRadius;
pub const CornerShape = style.CornerShape;
pub const CornerShapeSet = style.CornerShapeSet;
pub const NestedCorners = style.NestedCorners;
pub const Rect = style.Rect;
pub const Border = style.Border;
pub const BorderWith = style.BorderWith;
pub const Decoration = style.Decoration;
pub const DecorationWith = style.DecorationWith;
pub const Gradient = style.Gradient;
pub const GradientWith = style.GradientWith;
pub const Shadow = style.Shadow;
pub const ShadowWith = style.ShadowWith;
pub const BackdropBlur = style.BackdropBlur;
pub const BackdropBlurWith = style.BackdropBlurWith;
pub const Transform = style.Transform;
pub const Affine = style.Affine;
pub const Effects = style.Effects;
pub const EffectsWith = style.EffectsWith;
pub const Style = style.Style;
pub const StyleWith = style.StyleWith;
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
    _ = @import("tests/drag_drop.zig");
    _ = @import("tests/effects.zig");
    _ = @import("tests/materials.zig");
    _ = @import("tests/transforms.zig");
    _ = @import("tests/colors.zig");
    _ = @import("tests/inspection.zig");
    _ = @import("tests/semantics.zig");
    _ = @import("tests/chrome.zig");
    _ = @import("tests/exit_animations.zig");
    _ = @import("tests/motion.zig");
    _ = @import("tests/design.zig");
    _ = @import("tests/corners.zig");
    _ = @import("tests/borders.zig");
}
