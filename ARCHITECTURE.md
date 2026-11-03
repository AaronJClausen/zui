# Architecture

zui is a layout library, but an application built with it also needs a
window, a renderer, OS services and data from outside the UI. This
document says where each of those lives, how the parts connect, and what
happens when one of them is missing. SPEC.md is the contract for the core;
this is the map of everything around it. ROADMAP.md says when each part
ships; parts not built yet are marked *planned*.

## 1. The layers

| Layer | Holds | Rule that keeps it in bounds |
|---|---|---|
| **Core** (`zui`) | layout, interaction, state, feeds, the vocabulary every other layer speaks, and the contracts they implement | the same behavior on every target; no OS calls; no drawing |
| **Modules** (`zui_*`, in this repo) | widgets, reflection, testing, debugging, motion, color, the wire format, the app runner | the public API only, enforced by the module boundary (SPEC.md §3) |
| **Renderers** | drawing commands, fonts and text measurement, images, shaders | draw into a surface a host provides; declare at comptime what they can draw |
| **Hosts** | windows, the event loop, OS services, system events, signals, frame pacing | one contract, an implementation per target, chosen at comptime |
| **Theme packs** | the design languages of each OS | data and widget skins; no logic of their own |

Tooling (templates, sample apps, profiling guides) supports all of these
and is not library code.

### Dependencies point one way

```
                         application
                              │
                   zui_app (optional runner)
             ┌────────────────┼─────────────────┐
           host               │              renderer
   (native, or an adapter)    │      (sokol_gfx, raylib, web, wire)
             └───────┬────────┴────────┬────────┘
                     │                 │
     modules: widgets, motion,      zui_wire
     debug, color, themes              │
                     └────────┬────────┘
                              │
                          zui core
        (engine, vocabulary, and the Host, Renderer and Feed contracts)
```

- **The core depends on nothing,** and everything depends on it. It owns
  the vocabulary: `Input` and its events, host events, `RenderCommand`,
  `Color`, `Rect`, `Surface`, the capability structs. A renderer that
  imports `zui` only for those types pays nothing for the layout engine,
  because Zig only analyzes what is used, so no separate types package is
  needed.
- **Hosts and renderers never import each other.** They meet at one
  type, `zui.Surface`, which the host creates and the renderer draws into
  (§3.4).
- **The application, or `zui_app`, is the composition root.** It is the
  only place that names a concrete host and renderer.

## 2. The frame boundary

Everything that enters a frame is applied at `beginFrame`, and everything
that leaves it is produced by `endFrame`. Nothing crosses in between.
This rule is what makes relaying, replaying and remote rendering work,
and it is as much part of the common language as the types are.

| Inbound, applied at `beginFrame`, in this order | Outbound, produced by `endFrame` |
|---|---|
| 1. frame parameters: time (`dt_seconds`), viewport, zoom | render commands |
| 2. host events: system theme, scale, locale, power, lifecycle and signals, dropped files, HDR headroom | hit regions |
| 3. input events, in arrival order: pointers, wheel, keys, text, accessibility actions | the semantics list |
| 4. task completions | window-chrome regions (title bar, resize edges) |
| 5. feed deliveries | the deadline for the next frame |

**Input is an ordered event log, not sampled state** *(planned for 0.7,
ROADMAP.md I4)*. Each event carries the host's timestamp, so a press and
release between two frames is still a click, velocity is computed from
the host's clock rather than read during the frame, and replay gives the
same gestures. Today `Input` samples the buttons at poll time, which
loses fast taps; the format changes in the breaking release because the
host contract and the wire format would otherwise freeze it.

Together, the inbound side is a **frame record**. A relay tap receives
each frame record after it is applied, so a recorder, a network link or a
test are all just listeners on that tap.

**Replay is deterministic if the application reads the outside world only
through the frame record:** no clocks, random numbers or file reads
during declaration that bypass a feed. That is documented as the
application's side of the contract, not enforced.

*Planned for 0.6:* task completions are drained at each `request` today
(`src/tasks.zig`), so two elements in one frame can see the same pool in
different states. Moving the drain to `beginFrame` brings tasks under
this rule.

## 3. The contracts

Each contract is a comptime interface, checked the way `Platform` is
today: missing required declarations are compile errors with exact
messages, unknown `pub` declarations starting with `zui` are rejected so
a misspelled optional one is never silently ignored, and every optional
declaration has a documented default. The sketches below show shape; the
names are settled in the release that builds them.

### 3.1 Platform, composed from the host and the renderer

`Context(config, Platform)` stays as it is. Today one `Platform` supplies
text measurement, which belongs to the renderer (it owns the fonts), and
`wake` and `scale`, which belong to the host (it owns the window). From
0.7, `zui_app.Platform(Host, Renderer)` builds that type from the two, so
the core's signature does not change and applications that write their
own `Platform` keep working.

### 3.2 Renderer *(planned for 0.7)*

```zig
const SokolRenderer = struct {
    pub const capabilities: zui.RendererCapabilities = .{ .gradients = true, .backdrop_blur = false };
    pub const accepted_surfaces: zui.SurfaceKinds = .initMany(&.{ .win32, .cocoa, .wayland, .x11 });

    pub fn measureText(self: *SokolRenderer, text: []const u8, key: zui.MeasureKey) [2]f32 { ... }
    pub fn submit(self: *SokolRenderer, surface: zui.Surface, commands: []const Ui.RenderCommand) !void { ... }
};
```

**Base commands** (rectangle, border, text, image, clip, custom) are
required. Everything else is optional and declared in `capabilities`.
The core **lowers** what a renderer cannot draw during emission, so the
renderer never sees it:

| Optional command | Lowered to |
|---|---|
| gradient | a rectangle in the gradient's mean color (in OKLab) |
| shadow, glow | nothing |
| backdrop blur | a rectangle in the element's fallback tint |
| transform | the untransformed element (and its hit region stays untransformed) |
| extended color (G6) | the color clamped to `Color`; tone mapping to a display is the renderer's |

Capabilities are comptime-known, so lowering costs nothing for a renderer
that supports everything. A renderer's exhaustive `switch` covers only
the base commands plus what it declared, so adding an optional command
never breaks an existing renderer, and adding a base command always does.

### 3.3 Host *(planned for 0.7)*

```zig
const Win32Host = struct {
    pub const capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true };

    pub fn poll(self: *Win32Host, record: *zui.FrameRecord) void { ... }
    pub fn wake(self: *Win32Host) void { ... } // from any thread
    pub fn waitUntil(self: *Win32Host, deadline: ?zui.Instant) void { ... }
    pub fn surface(self: *Win32Host, window: zui.WindowId) zui.Surface { ... }
    pub fn scale(self: *const Win32Host, window: zui.WindowId) f32 { ... }

    pub const Notifications = struct { ... }; // optional services
    pub const Clipboard = struct { ... };
};
```

Optional services (notifications, clipboard, file dialogs, opening URLs,
system materials, native menus) are declarations the host may or may not
have. An application uses them through `zui_app`, which reports absence
by the rules in §4.

Two kinds of implementation share the contract:
- **Native hosts** own the window and the loop, one per OS, and hand a
  surface to any renderer that accepts it.
- **Adapter hosts** wrap a library that insists on owning its window,
  such as raylib, with fewer capabilities (one window, no materials).
  They let the contract be proven before native hosts exist, and let an
  application move to a native host without changing its UI code. A
  library that only reports input state goes through `zui.InputSampler`,
  which turns successive states into events (I4).

### 3.4 Surface

`zui.Surface` is a tagged union of native handles: `win32` (`HWND`),
`cocoa` (`NSView`), `wayland` (`wl_surface` and display), `x11`, `web`
(a canvas id), and `offscreen` (a size, for headless and wire use).
Pairing a host with a renderer whose `accepted_surfaces` share no kind
with the host's is a compile error naming both.

### 3.5 Feeds *(planned for 0.9)*

A feed is how outside data reaches declaration: typed, of fixed capacity,
owned by an id, and sampled at the frame boundary.

```zig
var quotes: zui.Feed(Quote, .{ .capacity = 64, .delivery = .every_item, .when_full = .drop_oldest }) = .{};
var battery: zui.Feed(BatteryState, .{ .delivery = .latest }) = .{};

// On any thread:
quotes.push(quote);

// During declaration, which sees what was delivered at beginFrame:
for (quotes.items(ui, .of("ticker"))) |quote| tickerRow(ui, quote);
if (battery.latest(ui, .of("status_bar"))) |state| batteryIcon(ui, state);
```

- **Delivery** is `.latest` (only the newest value matters) or
  `.every_item` (each one, in order).
- **When full,** a feed drops the oldest or the newest item, as declared,
  and reports the overflow like the other limits (SPEC.md §13.2).
- **A push wakes the host,** and makes `needsFrame` true.
- **Unmounting:** when no element reads a feed under its id for a frame,
  the feed's subscription for that id ends, as a task is canceled today.
- **A task is a feed that delivers once.** `TaskPool` keeps its API and
  becomes a feed of one value per id, so its completions arrive in the
  frame record like everything else.
- **Large data travels by handle.** A feed of assets carries handles;
  the bytes stay where they were loaded.

What feeds deliberately are not: there are no operators, no derived
feeds and no callbacks. A feed delivers values to a frame, and the
declaration code decides what they mean.

### 3.6 The wire format *(planned for 0.9)*

`zui_wire` encodes both sides of the frame boundary: frame records
inbound and commands outbound. It is versioned from its first release.
- **Deltas:** a frame is sent as its changes from the previous one.
- **Application payloads** (`ImageHandle`, `CustomData`, feed items)
  serialize automatically when they are plain data, and otherwise must
  declare `zuiSerialize` and `zuiDeserialize`, checked at comptime.
- **Fonts must match:** text is measured where layout runs, so a stream
  carries a fingerprint of the fonts it was measured with, and a renderer
  without them rejects it rather than drawing overflowing text.

Uses: remote sessions (frame records in, commands out), a remote
inspector, frames attached to bug reports, headless rendering, and
golden files for `zui_testing`.

## 4. When something is missing

| Case | Absence is | Examples |
|---|---|---|
| zui needs it to work | **a compile error** naming what is missing | `measureText`; a renderer that cannot draw a base command; a host without `poll` |
| zui uses it implicitly | **a fallback** to a documented default | no `scale`: no pixel snapping; no system material: the theme's solid color; an unhandled signal: the OS default; no backdrop blur: the fallback tint |
| the application asks for it by name | **a compile error at the call**, unless the call is guarded by `has_*` | notifications or file dialogs on a target without them |
| the target has it, this machine does not | **a returned status**, never a crash | a system material on Windows 10; notifications the user has denied |

What zui uses quietly falls back. What the application asks for by name
fails at compile time when it cannot exist on the target. What can only
be known at run time is a value to check. The inspector lists every
fallback in effect, so none of them is silent to a developer who looks.

## 5. Making the parts agree

1. **One vocabulary,** owned by the core, versioned once it is on the
   wire.
2. **Comptime contract checks** for `Platform`, `Renderer`, `Host` and
   feed payloads, with exact messages, each pinned by a compile-error
   test.
3. **Conformance suites** in `zui_testing`, which every implementation
   runs in its own CI:
   - `expectRendererConforms(Renderer)` draws recorded wire frames and
     checks clip balance, that every declared command is handled, and
     pixels within a tolerance where a reference image exists;
   - `expectHostConforms(Host)` checks the order of events, `wake` from
     another thread, and that `waitUntil` honors its deadline.
4. **Capabilities at run time:** `zui_app` reports what the host and
   renderer support and which fallbacks are in effect, for the inspector
   and for logs.

## 6. Threads

- **The host owns the main thread.** macOS requires the event loop
  there, and declaration runs on it by default.
- **A render thread is optional,** using frames in flight
  (SPEC.md §10.2); `zui_app` sets it up when the renderer allows it.
- **Feed producers and tasks run on any thread;** they only push and wake.
- **Signal handlers only set an atomic flag and wake the host.** The
  lifecycle event arrives in the next frame record. SIGKILL and SIGSTOP
  cannot be caught, so they are not values of the event enum.

## 7. Where each kind of feature lives

| Feature | Lives in | Roadmap |
|---|---|---|
| zoom and display scale | core (layout units × zoom; display scale from the host) | S1 |
| right-to-left layout, flex wrap, responsive helpers | core; breakpoint helpers in a module | L6, L7 |
| gradients, shadows, glow, backdrop blur, transforms | core defines and lowers the commands; renderers draw them | G1–G3 |
| the desktop showing through the window (Mica, vibrancy) | host asks the OS; renderer clears to transparent; core lets backgrounds be absent | H8 |
| drag and drop between elements | core interaction, arbitrated with other gestures | I1, I5 |
| many pointers: touch, pen, mouse | host reports pointer events; core keeps a pointer table | I4 |
| gestures the OS recognizes (trackpad pinch and rotate) | host, as input events | I4 |
| gestures zui recognizes: pan, zoom, drag, long press, double tap, momentum | core, from what each element declares it accepts | I5 |
| custom gestures, such as a lasso | modules or the application, over `pointerEvents` and `state` | I5 |
| other devices: gamepads, dials, crowns | host maps them to key and pointer events; core merges them into intents | I4, I5 |
| accessibility actions (Invoke, RangeValue, Scroll) | host bridge, as input events naming an element | V2 |
| HDR and wide gamut | core's color type; renderer tone-maps; host reports headroom | G6 |

| files dropped from the OS | host event | H6 |
| next-frame deadline, frame-rate caps, vsync | core reports the deadline; host paces | I2, H2 |
| trace zones for profiling | core, compiled out unless enabled | P2 |
| feeds, relaying, replay, remote rendering | core (feeds), `zui_wire`, `zui_testing` | F1–F6 |
| hot reload of assets and themes | a file-watching feed, plus `zui_debug` | F6, V1 |
| windows: secondary, child, tear-off | host (one `Context` per window); docking module later | H9 |
| native decorations, custom title bars | host, with window-chrome regions from the core | H7 |
| system events, signals, power, network | host, as frame-record events | C2, H2–H5 |
| notifications, clipboard, dialogs, URLs | host services | H6 |
| HSL, OKLCH, OKLab, palettes | `zui_color` module | K1 |
| dark, light, high-contrast themes | `zui_widgets` themes | K2 |
| icons | `zui_icons` module; glyphs drawn by the renderer | K3 |
| fonts, shaping, bidirectional text | renderer, behind `measureText` | — |
| OS design languages | `zui-themes`, one module per language | K4 |
| shaders | renderer: a typed material handle, or `custom` | G5 |
| app settings | application, shown in a sample with `zui_reflect` and ZON | D2 |
| templates, samples, DX audit, profiling guide | `zui-examples`, docs | D1–D4 |
| CMYK | out of scope; at most one conversion in `zui_color` | — |
| number, date and plural formatting | out of scope; a localization library | — |

## 8. Repositories

| Repository | Holds |
|---|---|
| `zui` | the core, the contracts, and the modules: widgets, reflect, testing, debug, motion, color, icons, wire, app |
| `zui-host` | native hosts, one directory per OS, chosen by target |
| `zui-raylib`, `zui-sokol`, `zui-terminal`, later `zui-web` | renderers; `zui-raylib` also ships the raylib adapter host |
| `zui-themes` | theme packs, one module per OS design language |
| `zui-examples` | sample applications and the template project |
