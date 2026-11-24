//! zui's test card, which every backend draws for the checks that run it.
//! A target names its host, renderer and font system, and `zui_app` runs it:
//!
//! ```zig
//! const App = zui_test_card.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib" });
//!
//! pub fn main(init: std.process.Init) !void {
//!     try zui_app.run(App, init, .{ .title = "zui test card (raylib)", .size = zui_test_card.window_size });
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_glyphs = @import("zui_glyphs");
const card_file = @import("card.zig");
const text_file = @import("text.zig");

pub const size = card_file.size;
pub const Scene = card_file.Scene;
pub const Region = card_file.Region;
pub const ids = card_file.ids;
pub const preferences = card_file.preferences;
pub const Identity = card_file.Identity;
pub const Values = card_file.Values;
pub const Card = card_file.Card;
pub const swatchCode = card_file.swatchCode;
pub const Typeface = text_file.Typeface;
pub const Text = text_file.Text;

/// The window a target opens: the card's size.
pub const window_size: [2]u32 = .{ @intFromFloat(size[0]), @intFromFloat(size[1]) };

/// Frames a held scene takes to settle: the first frame places what the
/// second's input aims at.
pub const settling_frames = 3;

/// What a target names: the card's host, renderer and font system.
pub const Config = struct {
    Host: type,
    Renderer: type,
    /// A font system, such as `zui_truetype.Text`: it declares
    /// `addFont(bytes) !FontId`, `zuiMeasure` and `zuiFingerprint`.
    Text: type,
    /// The renderer as the `identity` region names it, such as "raylib".
    renderer_name: []const u8,
    /// The host as the `identity` region names it; its type's name when
    /// null.
    host_name: ?[]const u8 = null,
};

/// How a run of the card behaves, as its flags say:
///
/// ```sh
/// --scene <name>       hold one scene; without it, the scenes in turn, a frame each, while --frames is given, and rest otherwise
/// --frames <count>     quit after this many frames, printing whether every frame was ok
/// --hidden             for the target: keep the window hidden
/// --screenshot <path>  for the target: save the window once the scene settles, then quit
/// ```
pub const Options = struct {
    scene: ?Scene = null,
    frame_limit: ?u64 = null,
    hidden: bool = false,
    screenshot_path: ?[:0]const u8 = null,

    pub const usage = "--scene <name>, --frames <count>, --hidden or --screenshot <path>";

    /// The options `arguments` give, the program's name first.
    pub fn parse(arguments: []const [:0]const u8) error{ UnknownArgument, UnknownScene, InvalidCharacter, Overflow }!Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            const has_value = index + 1 < arguments.len;
            if (std.mem.eql(u8, argument, "--scene") and has_value) {
                index += 1;
                options.scene = std.meta.stringToEnum(Scene, arguments[index]) orelse return error.UnknownScene;
            } else if (std.mem.eql(u8, argument, "--frames") and has_value) {
                index += 1;
                options.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
            } else if (std.mem.eql(u8, argument, "--screenshot") and has_value) {
                index += 1;
                options.screenshot_path = arguments[index];
                options.hidden = true;
            } else if (std.mem.eql(u8, argument, "--hidden")) {
                options.hidden = true;
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }

    /// The scene of frame `index`, counted from 0.
    pub fn sceneOf(options: Options, index: u64) Scene {
        if (options.scene) |held| return held;
        return if (options.frame_limit != null) .inTurn(index) else .rest;
    }
};

/// The card as `zui_app` runs an application on `config.Host`, drawn by
/// `config.Renderer` in `config.Text`'s fonts, laid out for the placement
/// the renderer draws. It counts the renderer's `layer_overflows` and
/// `glyphOverflows()` when the renderer counts them. Its `init` takes its
/// `Options` from the process's arguments; a target that does more holds
/// an `App` and calls `initWith`, with `startOf` its own `Start`.
pub fn App(comptime config: Config) type {
    return struct {
        const Self = @This();

        pub const Host = config.Host;
        pub const Renderer = config.Renderer;
        pub const Text = text_file.Text(config.Text, Renderer);
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = Self.Text }));
        pub const CardOnUi = Card(Ui);

        const counts_layer_overflows = @hasField(Renderer, "layer_overflows");
        const counts_glyph_overflows = @hasDecl(Renderer, "glyphOverflows");

        card: CardOnUi,
        tokens: CardOnUi.Tokens,
        host: *Host,
        renderer: *Renderer,
        options: Options,
        /// Frames drawn so far.
        frames: u64 = 0,
        diagnostics_ok: bool = true,
        layer_overflows: u32 = 0,
        glyph_overflows: u32 = 0,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            if (builtin.os.tag == .freestanding) return app.initWith(start, .{});
            const process = start.process orelse return app.initWith(start, .{});
            const options = Options.parse(try process.minimal.args.toSlice(process.arena.allocator())) catch |err| {
                std.log.err("{t}; the test card takes {s}", .{ err, Options.usage });
                return err;
            };
            app.initWith(start, options);
        }

        pub fn initWith(app: *Self, start: zui_app.Start(Self), options: Options) void {
            app.* = .{ .card = undefined, .tokens = .{}, .host = start.host, .renderer = start.renderer, .options = options };
            CardOnUi.resolveTokens(&app.tokens, start.text.fonts);
            app.card.init(&app.tokens, .{
                .renderer_name = config.renderer_name,
                .host_name = config.host_name orelse @typeName(Host),
                .fonts_fingerprint = start.text.zuiFingerprint(),
                .placement = zui_glyphs.placementOf(Renderer),
            });
            const background = app.card.background();
            if (@hasField(Renderer, "clear_color")) start.renderer.clear_color = background;
            if (@hasField(Renderer, "background")) start.renderer.background = background;
        }

        /// `start`, a `zui_app.Start` of a target's application around
        /// this one, as this one's.
        pub fn startOf(start: anytype) zui_app.Start(Self) {
            return .{ .gpa = start.gpa, .io = start.io, .process = start.process, .host = start.host, .renderer = start.renderer, .text = start.text, .waker = start.waker, .windows = {} };
        }

        pub fn deinit(app: *Self) void {
            if (app.options.frame_limit == null) return;
            if (counts_layer_overflows or counts_glyph_overflows) {
                std.log.info("drew {d} frames, {d} layer overflows, {d} glyph atlas overflows, diagnostics ok: {}", .{ app.frames, app.layer_overflows, app.glyph_overflows, app.diagnostics_ok });
            } else {
                std.log.info("drew {d} frames, diagnostics ok: {}", .{ app.frames, app.diagnostics_ok });
            }
        }

        pub fn zuiRecord(app: *Self, record: *zui.RecordBuilder) void {
            app.card.prepareRecord(app.options.sceneOf(app.frames), record);
        }

        pub fn zuiDeclare(app: *Self, ui: *Ui) void {
            if (app.options.frame_limit != null or app.frames < settling_frames) ui.requestFrame();
            const scene = app.options.sceneOf(app.frames);
            app.card.declare(ui, scene, app.options.sceneOf(app.frames + 1) != scene);
        }

        pub fn zuiObserve(app: *Self, ui: *const Ui, frame: *const Ui.Frame) void {
            app.diagnostics_ok = app.diagnostics_ok and frame.diagnostics.ok();
            app.card.observe(ui, frame);
        }

        /// Counts the frame and closes the host at the frame limit.
        pub fn zuiLoader(app: *Self, _: *const Ui, _: std.Io) void {
            app.frames += 1;
            if (counts_layer_overflows) app.layer_overflows = app.renderer.layer_overflows;
            if (counts_glyph_overflows) app.glyph_overflows = app.renderer.glyphOverflows();
            if (app.options.frame_limit) |limit| if (app.frames == limit) app.closeHost();
        }

        /// Ends the run after this frame, on a host that can close its window.
        pub fn closeHost(app: *Self) void {
            if (@hasDecl(Host, "close")) app.host.close() else std.log.err("zui_test_card: {s} cannot close its window, so the run goes on", .{@typeName(Host)});
        }
    };
}
