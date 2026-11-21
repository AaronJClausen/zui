# 04-native-host: A native host

Stage 4 of SPEC.md §21: Windows, with the system material, per-monitor
scale, lifecycle, clipboard and drop.

**Done when:** the demo runs unchanged, passes the host suite, and idles
at 0% CPU.

**Status.** Done.

## Items

| Item | Status |
|---|---|
| `04-native-host:01-windows-host` The Windows host | done |
| `04-native-host:02-system-material` The desktop showing through the window | done |
| `04-native-host:03-app-text-contract` `zui_app` with a separate text contract | done |

---

## 04-native-host:01-windows-host — The Windows host

`zui_host`, in `hosts/native/` (`0731195`), created here, one
directory per OS; `zui_host.Host` is `windows/host.zig` on Windows and a
compile error naming the OS elsewhere. The Windows host:
- runs its window's message loop on a thread of its own, so the window
  keeps drawing while Windows runs a move or resize loop; the window
  thread queues events in physical pixels under a lock, and `zuiPoll`
  converts them with the record's scale and zoom;
- waits on a sticky manual-reset wake event, an input event the poll
  resets, and a high-resolution waitable timer for `.at`;
- reports per-monitor scale (DPI awareness v2, `WM_DPICHANGED`), the
  mouse, the wheel (40 layout units a notch, as raylib and sokol), keys
  with modifiers and scan codes, UTF-8 text with surrogate pairs joined
  and consecutive characters in one event, the environment (dark mode,
  which also darkens the title bar, high contrast, animations, power,
  focus), dropped files (`WM_DROPFILES`), and lifecycle events: console
  control events and `WM_QUERYENDSESSION` are `.terminate_requested`,
  `WM_POWERBROADCAST` gives `.suspend` and `.resume`, and a memory
  resource notification `.low_memory`;
- sets the cursor and places the IME's composition and candidate windows
  at the caret, turning the IME off while no editable asks for text;
- offers the clipboard as text through `zuiClipboard`.

The core gained what such a host reports and the record could not carry
(`d9d279e`): `Event.files_dropped` (`zui.FilesDropped`, paths copied
whole into the new `limits.max_dropped_path_bytes`, `ui.filesDropped()`,
`RecordBuilder.appendFilesDropped`) and `Event.lifecycle`
(`zui.Lifecycle`, `ui.lifecycle()`). `zig build counts` against `638080d`,
in a local Docker container: declaration +1 instruction in every
scenario, `endFrame` unchanged.

The sokol renderer (`05485b5`, `2d11a00`) draws into a `win32` surface
when built with OpenGL (`-Dgl=true`): `Renderer.initForSurface` makes the
window's OpenGL 4.3 core context through WGL and sets sokol_gfx up on it
without sokol_app, and `zuiSubmit` presents with vsync. A D3D11 build does
not declare the surface, so pairing it with the host fails to compile.

It passes `03-contracts:03-conformance-suites`: `expectHostConforms` against a hidden window, with a
harness that sends the messages Windows would, and ten more tests (DPI
changes, text, the wheel, dropped files, the session ending, Ctrl+C, the
clipboard, requests). The demo is the sokol renderer's tour, whose
application the sokol renderer exports as a module of its own and the
native hosts run unchanged under their own six-line loop; under
sokol_app it runs as before (its tour test passes). Measured on the
reference machine in ReleaseSafe with
`--measure-idle` on the Layout Lab screen (heartbeat off): 15.6, 15.6,
31.3 and 62.5 ms of CPU over 10 s, 0 or 1 frames and 0 wakes; the Welcome
screen, which animates once a second, 15.6 ms and 10 frames. A screenshot
through the compositor (`--screenshot`) shows the tour drawn. The native
hosts' CI checks the format, runs the tests and the host suite on GitHub's
Windows runner in Debug and ReleaseSafe, and cross-compiles from Linux for
x86-64 and ARM64 Windows, which found a function-pointer alignment that
only ARM64 enforces in the sokol renderer's WGL code (`2d11a00`).

Decided here:
- **The demo for a native host is the sokol renderer's tour,** not the raylib renderer's
  demo: raylib owns its window and cannot draw into another, so the
  application that runs unchanged across hosts is the one whose renderer
  can. The tour runs under a loop written by hand, not `zui_app`, because
  `zui_app` gives the context the renderer as its text contract and
  the sokol renderer's text contract is a separate `Text`.
- **The window's loop runs on its own thread,** so Windows' modal move
  and resize loops never stop frames; the contract does not change, as
  the host owns its threads.
- **A terminate request closes the window one frame later:** the host
  delivers it, and its next `zuiPoll` returns false, the OS default with a
  frame to react (SPEC.md §7.1).
- **The clipboard service** is `zuiClipboard`, a type with
  `read(host, buffer) ?[]u8` and `write(host, text) !void`, until `10-reach:03-services` gives
  the services one shape.
- **A test may fix the host's scale** (`Host.forced_scale`), so the suite's
  positions in layout units are whole pixels on any monitor.

What remains, and where it went:
- **Touch and pen** (`WM_POINTER`) are not reported yet; nothing in `04-native-host:01-windows-host`'s
  plan asked for them, and `07-gestures:01-gesture-arbitration`'s gestures will.
- **IME composition text** is shown by the IME's own window; the
  `composition` event and the IME area's use by an editable are `11-polish:06-text-editing`'s.
- **A console close, logoff or shutdown** ends the process when the
  handler returns, so the application's frame for that request may not
  run; `WM_QUERYENDSESSION` gives it the time Windows allows.
- **Seen only on this machine:** one monitor at 125%; a second monitor of
  another DPI was simulated by sending `WM_DPICHANGED`.

## 04-native-host:02-system-material — The desktop showing through the window

`zui.SystemMaterial` (`none`, `window`, `transient`) in
`WindowOptions.material`, passed by `zui_app.Options.material`, and
`Environment.system_material`, the host's answer on this machine, an
environment change like every other (`50430d8`). The Windows host
(`a958595`) declares `system_material`: it asks DWM for the backdrop
(`DWMWA_SYSTEMBACKDROP_TYPE`, Mica or Acrylic), extends the frame over the
client area and paints it black, which is transparent there, and reports
`system_material` (the backdrop taken and transparency effects on) and
`reduced_transparency`, again when the settings change.
`Host.system_material_unavailable` makes it behave as Windows 10, which
refuses the attribute.

The renderer clears to transparent and must keep its alpha. Windows
ignores the alpha of an OpenGL window and of a Direct3D swapchain made for
a window: over Acrylic's #545454, an opaque #2d2d2d card showed #818181,
the backdrop added under every pixel. So the sokol renderer (`6d49d41`)
now draws into a `win32` window with D3D11, its default backend, through a
swapchain DirectComposition composes into the window with premultiplied
alpha, and its sokol_gl pipeline writes alpha, which sokol_gl does not by
default. sokol's built-in bitmap text writes 0 between a glyph's strokes, which let the
backdrop through each glyph's cell over a card, so when the surface
composes alpha every rectangle and border is drawn again into the alpha
channel after the text, with MAX blending.

`zig build material` in `hosts/native/` declares a root without a background
while `system_material` is true and with the theme's otherwise. Read back
from the screen on the reference machine (Windows 11): Mica shows #202020
where nothing is drawn (black without it), Acrylic #545454, and a #2d2d2d
card at 69% alpha blends over each as drawn (#292929, #393939); with the
material forced unavailable, the root's own #202020 and the same card.
The tour draws through the same D3D11 path and idles at 0.0 ms of CPU over
10 s in three runs of four (62.5 ms, 2 frames, in the fourth), ReleaseSafe.

Decided here:
- **Whether the material shows is an environment setting,** not a
  status a host call returns, so it is in the record, replays, and the
  application reads it where it reads the theme.
- **A native window's renderer composes with alpha** through
  DirectComposition on Windows; the sokol renderer's OpenGL path stays for
  `-Dgl=true` and its renderer suite, and does not show the material.

What remains, and where it went:
- **Windows 10 was not seen:** the fallback there is the path forced by
  `system_material_unavailable`, where the attribute's refusal is the only
  difference; this machine is Windows 11.
- **A light theme and a second monitor** were not seen either; the
  machine is in dark mode.

## 04-native-host:03-app-text-contract — `zui_app` with a separate text contract

Taken ahead of the queue, since stage 10's "the demo runs unchanged on
each host" needs one loop for every application.

**Grounding.** `zui_app.checkApp` made any `Text` but the renderer a
compile error (`03-contracts:05-zui-app`), and `contextConfig` replaced an override's `Text`
with a renderer that measures. The sokol renderer's tour measures with
`zui_sokol.Text`, a separate type its renderer holds a pointer to, so
`04-native-host:01-windows-host` ran it on the Windows host under a hand-written loop.

**Plan.** Let the application name its text contract, keeping "the
renderer measures" as the default, with exact, pinned compile errors.

**Done when:** the native hosts' `tour` step runs the sokol renderer's
tour through `zui_app.run`, `zui_app`'s tests cover both cases, and the
raylib renderer's demo builds unchanged.

What landed:
- **`App.Text`.** An application whose `Config` names `.Text = Fonts`
  declares `pub const Text = Fonts`; `zui_app` makes one (its `init(self)
  !void` and `deinit` if it declares them, else its defaults), gives the
  context a pointer, and gives it to a renderer whose `init` takes
  `(self, surface, text: *const Text)`. `contextConfig` keeps an
  override's `Text`. Four new compile errors are pinned: a `Ui` measuring
  with a type the application does not declare, an `App.Text` that is
  not the `Ui`'s, a renderer `init` taking the wrong text, and a
  `zuiRecord` of the wrong signature.
- **What running the tour unchanged needed besides:** `zuiRecord(app,
  record)`, after the host's poll, where the application sets its zoom
  (which `zui_app` could only set once, from `Options.zoom`) and appends
  events it makes itself (the tour's theme switch); `Start.renderer`;
  `sources` as a field holding the `Sources` or pointing to them, so a
  wrapper uses the sources of the application it wraps; and each field
  of the host, the renderer and the text that has a default holding it
  when their `init` is called. The Windows host's `Host.init` reads
  `forced_scale` and `system_material_unavailable` from itself, which
  under `zui_app` had been undefined.

The native hosts (`d6fe429`) run the tour
with `examples/tour.zig` now `zui_app.run(TourOnHost, ...)`:
`TourOnHost` names the host, the renderer and `zui_sokol.Text`, and
passes each step to the tour's own `App`; a small `SokolRenderer`
opens the sokol renderer with `initForSurface` and times each submit
for the tour's strip, since the sokol renderer's `Renderer.init` predates
`zui_app` and was changing under another item at the time. The
tour visits every screen (`--frames 300 --cycle 30`, diagnostics ok), its
screenshot shows the dark theme `zuiRecord` applied, and in ReleaseSafe
on the reference machine Layout Lab idles at 0.0, 31.3, 15.6 and 0.0 ms
of CPU over 10 s with 0 frames and 0 wakes; Welcome at 0.0 ms with its
11 heartbeat frames. The raylib renderer's demo, tests and suites build
and pass unchanged. Nothing in the core changed, so there is
nothing to count.

Decided here:
- **The text contract under `zui_app`** is the renderer by default, or
  the application's `pub const Text`, which `zui_app` owns.
- **The application's part of the record** is `zuiRecord`, after the
  host's poll: the zoom is the application's (SPEC.md §16.3), and the
  host converted this poll's events at the zoom then on screen.

What remains: the sokol renderer's `Renderer` could take `zui_app`'s
`init(self, surface, text)` itself, which would retire the native hosts'
`SokolRenderer` (`hosts/native/examples/sokol_renderer.zig`).
