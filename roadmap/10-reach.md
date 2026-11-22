# 10-reach: Reach

Stage 10 of SPEC.md §21: Linux and web hosts; services; window
decorations; many windows.

- **`10-reach:01-linux-host`:** Wayland, then X11; KDE blur where offered.
- **`10-reach:02-web-host`:** a canvas surface, on the loop
  `10-reach:06-platform-owned-loop` gives a host that cannot block.
- **`10-reach:03-services`:** clipboard, notifications, file dialogs,
  opening URLs, native menus, each an optional host declaration.
- **`10-reach:04-window-decorations`:** native by default; a custom title
  bar uses chrome regions so the OS still moves, resizes and snaps the
  window.
- **`10-reach:05-many-windows`:** one `Context` per window, with sources
  published into each.
- **`10-reach:06-platform-owned-loop`:** the browser's main thread, macOS,
  iOS and Android, driving `zui_app` from their own callbacks, and a
  surface the platform takes away and gives back.

**Done when (each):** the host passes `03-contracts:03-conformance-suites`,
and the demo runs on it unchanged.

`14-macos:01-macos-host`, the macOS host, is set aside in
[14-macos](14-macos.md), and stage 10 is done without it.

## Items

| Item | Status |
|---|---|
| `10-reach:01-linux-host` Linux | in progress |
| `10-reach:02-web-host` Web | in progress |
| `10-reach:03-services` Services | done |
| `10-reach:04-window-decorations` Window decorations | waiting on a person |
| `10-reach:05-many-windows` Many windows | done |
| `10-reach:06-platform-owned-loop` Hosts whose platform owns the loop | done |

---

## 10-reach:01-linux-host — Linux

**Grounding.** `hosts/native/` has one directory per OS, and `zui_host.Host`
is a compile error on anything but Windows (`hosts/native/zui_host.zig:8-11`); its
build links Win32 libraries and builds the examples only there
(`hosts/native/build.zig:17-19`, `hosts/native/build.zig:43`). The Windows host is the shape to
follow: an `Inbox` of events in physical pixels (`hosts/native/windows/host.zig:84`),
converted to layout units at `zuiPoll` (`:203`, `:245`), a sticky wake
cleared after the wait (`:272`), and a harness that delivers what the OS
would, synchronously, to the host's own handlers
(`hosts/native/windows/conformance.zig:36`, `:66`). Its message loop runs on a thread
of its own (`:348`) only because Windows runs moves and resizes in a
modal loop; a Wayland client has no such loop, so one thread suffices.
SPEC.md §16.4's `wayland` surface is a display and a surface
(`core/src/surface.zig:48`), the objects of libwayland-client: EGL's and
Vulkan's Wayland platforms take exactly those, so a host that spoke the
protocol itself would give a surface no GPU driver can draw into.
sokol-zig links libwayland-client, libwayland-egl, libxkbcommon and EGL
for its own Wayland window (its `build.zig`, the `wayland` option), so
linking them is the ecosystem's way. `zui_sokol` draws into a native window
only on Windows (`renderers/sokol/src/renderer.zig:29`, `:50`, `:119`), through a context
of its own, as `renderers/sokol/src/wgl.zig` does with WGL; on Linux sokol_gfx draws with
OpenGL, so a `.wayland` surface is an EGL context on a `wl_egl_window`.
The tour on the host (`hosts/native/examples/tour.zig:171`, `:114`, `:217`) names
`.win32` and reads the process's CPU time and the screen through Win32.

**Plan.** In slices, each passing `03-contracts:03-conformance-suites` where it can run:
1. **A Wayland window** (`hosts/native/linux/`): libwayland-client with xdg-shell's
   interfaces written in Zig, a `.wayland` surface, integer scale from
   `wl_surface.preferred_buffer_scale`, the pointer, the wheel by
   notch, keys through xkbcommon with modifiers, the evdev code and
   typed text, focus, the close button, the cursor through
   `wp_cursor_shape_v1`, and waits on the display, an `eventfd` wake and
   a deadline. `zui_sokol` draws into `.wayland` through EGL; the tour runs
   on it; the host suite runs against an unmapped window, skipping with
   a message where no compositor runs.
2. **Repeat, lifecycle and the environment:** key repeat from
   `repeat_info`, SIGINT and SIGTERM as `.terminate_requested` (the
   handler sets a flag and wakes), the theme, contrast and reduced
   motion from the XDG desktop portal's settings over D-Bus, and power
   from UPower.
3. **Fractional scale, the clipboard, drops and file watching:**
   `wp_fractional_scale_v1` with `wp_viewporter`, `wl_data_device`'s
   selection as `zuiClipboard` and its drops as `files_dropped`,
   `zuiFileWatch` through inotify; `zig build theme` on Linux.
4. **Services,** `10-reach:03-services`'s shapes on Linux: notifications through
   `org.freedesktop.Notifications`, file dialogs through the desktop
   portal's `FileChooser`, URLs through its `OpenURI`, on the host's own
   D-Bus client; no `zuiMenus`, which Wayland lacks; `zig build services`
   on Linux.
5. **The IME:** `zwp_text_input_v3`, enabled while a frame asks for text
   input, its cursor rectangle at the caret, committed text as `text`.
6. **A custom title bar,** `10-reach:04-window-decorations`'s on Linux: `xdg-decoration` asked for
   client-side, presses on `.title_bar` and the edges handed to
   `xdg_toplevel.move` and `resize`, the caption buttons worked by the
   host, `window_maximized` from the toplevel's states; `zig build
   title-bar` on Linux.
7. **Many windows,** `10-reach:05-many-windows`'s on Linux: the host `.many`, a toplevel and a
   surface per window, and `zui_sokol` attaching a `wl_egl_window` and
   `EGLSurface` per window on one `EGLContext`; `zig build many-windows`
   on Linux.
8. **The material:** an alpha surface, KDE's `org_kde_kwin_blur` where
   KWin offers it, and `ext_background_effect_v1` where a compositor
   offers that, reported as `Environment.system_material`.
9. **X11:** an X11 host with the same reports, and `zui_host.Host`
   choosing Wayland when a compositor answers and X11 otherwise, its
   surface `.wayland` or `.x11`; `zui_sokol` draws both through EGL.

Slices 4, 6 and 7 were added when the Windows host's `10-reach:03-services`, `10-reach:04-window-decorations` and `10-reach:05-many-windows` had
landed, so that the Linux host makes every report the Windows host makes.

**Done when:** the host passes `03-contracts:03-conformance-suites` on Wayland and on X11, in CI under a
headless compositor and Xvfb; the tour runs on it unchanged and
idles at 0% CPU; and the theme example restyles on a file change.

**Spec.** §7, §16.3, §16.4, §21 (stage 10).

**Status.** Slice 1 is done: `aab0e37` (`hosts/native/linux/host.zig`,
`hosts/native/linux/wayland.zig`, `hosts/native/linux/xkb.zig`, `hosts/native/linux/keys.zig`) and
`77e9448` (`renderers/sokol/src/egl.zig`). On Hyprland with an NVIDIA RTX 2060
SUPER, the host suite and six tests of the host's own pass in Debug,
ReleaseFast and ReleaseSafe against a window the compositor never shows,
and skip with a message without a compositor; the tour drew 1,500 frames
across every screen in a tiled window, seen in a screenshot, with no
layer overflow; and Layout Lab idled at 1.2 to 4.4 ms of CPU over 10 s,
with 0 or 1 frames and no wakes, in five ReleaseSafe runs of six (the
sixth drew 96 frames for the pointer over the window). The native hosts'
CI gains a Linux job under a headless Weston, which passes (`d703a34`).

Slice 2 is done in `hosts/native/` alone, `3bd5c13` (`hosts/native/linux/host.zig`,
`hosts/native/linux/dbus.zig`, `hosts/native/linux/desktop_bus.zig`), reporting what the Windows host reports
(`hosts/native/windows/host.zig:504`, `:534-544`, `:672-706`, `:768-777`) where Linux
has it. A held key repeats at `repeat_info`'s rate and delay, each repeat
a `key_down` with `repeat` set that types again, and a wait ends at the
next repeat. SIGINT, SIGTERM and SIGHUP set a flag and wake, and the next
poll delivers `.terminate_requested`, after which the window reports
closed; logind's `PrepareForSleep` is `.suspend` and `.resume`. The
theme, contrast and reduced motion come from the portal's
`org.freedesktop.appearance` settings (`ReadAll`, then `SettingChanged`),
and power from UPower's `OnBattery` and power-profiles-daemon's
`ActiveProfile` (`power-saver` is `.saver`), each change as signalled,
the buses' sockets waited on beside the display. Without a bus, portal
or daemon they stay at zui's defaults, and `environmentSources()` says
which answered. On Hyprland, with the portal, UPower and
power-profiles-daemon running, `init` took 1.9 ms in all and the first
record held the dark theme the portal reported; the host suite and 13
tests of the host's own pass in Debug, ReleaseFast and ReleaseSafe, 15
unit tests beside them, one of which plays the portal on a
`dbus-daemon` of its own and checks that its answer and signal arrive
and an impostor's signal does not (CI starts such a daemon). The tour
drew 300 frames across every screen with no layer overflow, and Layout
Lab idled at 9.7 to 15.2 ms of CPU over 10 s with 9 to 11 frames and no
wakes in three runs of four (the fourth drew 58 frames for the pointer),
as `d703a34` did the same day (10.6 and 12.8 ms, 9 and 10 frames): a run
counted no reads of either bus while idle, and the frames come from the
compositor's events. Not reported yet: `.low_memory` (the Windows host's
memory notification has no unprivileged counterpart but pressure
triggers), reduced transparency and text scale, which the portal does not
carry.

Slice 3 is done in `hosts/native/` alone, `3f3d57a` (`hosts/native/linux/data_device.zig`,
`hosts/native/linux/file_watch.zig`). With `wp_fractional_scale_v1` and
`wp_viewporter` both offered, the record's scale is `preferred_scale /
120` and the buffer `round(size × scale)` with a buffer scale of 1; one
function, `pixelsPerSurfaceCoordinate`, converts surface coordinates, and
`forced_scale` still wins. `zuiClipboard`, in `10-reach:03-services`'s shape, offers a
`wl_data_source` of three text types and reads the selection through a
pipe from the wait loop, each transfer bounded at 2 s, into 64 KiB with
text past it cut at a character and counted; until another selection is
named, a read answers the last text written. Hyprland names a selection
only to the focused client, so the unshown suite reads its own text, and
an opt-in test (`ZUI_HOST_TEST_SHOWN_WINDOW=1`) shows a window for a
moment and reads back through the compositor; the suite leaves the
desktop's clipboard empty, as the Windows host's overwrites it. Drops of
`text/uri-list` arrive as one `files_dropped` at the drag position,
`file://` URIs percent-decoded. `zuiFileWatch` reads one inotify
descriptor in the same `ppoll`, without threads: 4 roots and 256
directory watches, a subdirectory watched as it appears and what it
already holds reported as added, overflow published as a rescan. `zig
build theme -- --check` restyled 18.7 ms after the file was rewritten,
against 2 to 4 ms on Windows. The tour idled at 10.3 and 10.8 ms of CPU
over 10 s, 9 and 10 frames, no wakes. Not run: a drag from another
application, and a fractional scale on a monitor (the tests convert at
1.25 and 1.5 through the listeners).

Slice 4 is done in `hosts/native/` alone, `342302e` (`hosts/native/linux/services.zig`,
`hosts/native/linux/dbus.zig`): `10-reach:03-services`'s shapes on a second session-bus
connection of the host's own, its socket in the same `ppoll`. A call
only writes, at most 100 ms, and answers are published from `zuiPoll`
and `zuiWait`. `zuiNotifications` calls `org.freedesktop.Notifications`'
`Notify` with a `default` action, `ActionInvoked` answering
`.notification_activated` and `NotificationClosed` (or a replacement)
`.notification_dismissed`, from the daemon's unique name only, its match
rule added only while one shows, so an idle host reads no other
application's notifications. `zuiFileDialogs` calls the portal's
`FileChooser`, its `Response` match on the predicted request path added
before the call; `file://` URIs are decoded to paths. `zuiOpenUrl` calls
the portal's `OpenURI` without a reply. No `zuiMenus`. Without a bus a
call is `error.Unavailable` at once; without the daemon or the portal it
answers `.failed = .unavailable`. With `ZUI_HOST_TEST_SESSION_BUS` on a
private `dbus-daemon`, tests play the daemon and the portal: a
notification's arguments and signals, an impostor's ignored, a dialog's
paths and cancel, `OpenURI`'s URL; 57 of 58 tests pass in Debug,
ReleaseFast and ReleaseSafe with both slices, one opt-in skip. `zig
build services -- --check` exits 0, copying and pasting through slice
3's clipboard; against the real desktop, quickshell numbered a
notification and the portal answered `OpenFile`. Tour idle: 10.2 to 13.9
ms of CPU over 10 s, 9 to 11 frames, no wakes, as without the change.
The Linux check draws nothing: `zui_sokol` drawing a surface the
compositor never shows waits in `eglSwapBuffers` for a frame callback
that never comes, which slice 7's hidden many-windows check will meet.

Slice 5 is done in `hosts/native/` alone (`hosts/native/linux/text_input.zig`,
`hosts/native/linux/wayland.zig`): `zwp_text_input_v3` at version 1, its
interfaces written in Zig, one per seat. While the seat's text-input
focus is on the window and a frame's `HostRequests.text_input` names a
caret, the host enables it and sets its cursor rectangle at the caret in
surface coordinates (layout units times the last poll's
`surface_coordinates_per_unit`, so at 1.5 with a zoom of 1.25 a caret at
10, 20 is at 12, 25, not the buffer's 15, 30), floored and ceiled to
cover it; a frame without one disables it. Requests go only when the
caret, or whether one is asked for, changes, so an unchanged or absent
request sends nothing; `enter` resends what the last frame asked for, and
`leave` forgets it. `commit_string` is typed on `done` through the same
inbox as keys, ending a wait, whatever `done`'s serial, as the protocol
says a client must apply text; a `done` that commits nothing ends no
wait. `preedit_string` is kept (`TextInput.preeditText`) and not
reported, which is left for `11-polish:06-text-editing`; no surrounding
text or content type is sent, and `delete_surrounding_text` is ignored.
Keys are untouched: an input method that consumes a key keeps it from
the window, and one it forwards arrives as `wl_keyboard.key`, typed
through xkb as before. Hyprland offers the manager; the host binds it,
and `enter` and `leave` follow keyboard focus. Nine tests drive the
handlers (the caret at scale 1 and at a fractional scale and zoom,
nothing sent for an unchanged frame, disabling, committed text as one
`text` event, a lagging serial, composing text alone ending no wait,
leave and enter, another surface's focus), running under a compositor
without the manager too, and two unit tests cover the rectangle's
rounding and a string past the capacity; 68 of 69 tests pass in Debug and ReleaseSafe,
the opt-in one skipped. Tour idle: 24.4 to 31.4 ms of CPU over 10 s, 10
to 12 frames, no wakes, against 25.3 to 26.6 ms and 10 or 11 frames for
the commit before it measured in the same hour on a busier machine than
slice 4's runs. Not run: typing through fcitx5 into a text field, since
nothing here can focus one without a pointer; Tab presses from `wtype`
reached the tour as keys, but did not focus a field.

Slice 6 is done in `hosts/native/` alone (`hosts/native/linux/chrome.zig`,
`hosts/native/linux/host.zig`, `hosts/native/linux/wayland.zig`, `hosts/native/examples/title_bar.zig`):
`10-reach:04-window-decorations`'s title bar on Wayland. The host declares `custom_title_bar` and
`zuiChromeRegions`, which copies up to 256 regions into a
`WindowChrome` in surface coordinates, the rest counted as dropped; that
one struct holds the window's chrome state, for slice 7 to move into
each window's. `zxdg_decoration_manager_v1` is written in Zig as the
other interfaces are: a `.custom` toplevel asks for `client_side`, a
native one for `server_side`, and without the manager a window is
client-side already. A primary press on the title bar is
`xdg_toplevel.move` with the press's serial, a second within
`zui.Gestures.double_tap_seconds` of the first toggles
`set_maximized`/`unset_maximized`, measured press to press since a moved
window's release never comes back, and a secondary press is
`show_window_menu` at the pointer; a press on a `resize_*` region is
`resize` from its edge, or zui's on a window that is not resizable.
Neither such a press nor its release reaches zui. A caption button's
press does, and its release on the same button arrives as
`pointer_cancel` while the host minimizes, toggles maximized or closes,
as on Windows; released on another, or after the pointer leaves, it
works nothing. `Host.minimize`, `Host.toggleMaximized` and `Host.close`
serve the keyboard. The first record reports `custom_title_bar`, and
`window_maximized` follows the `maximized` state of
`xdg_toplevel.configure`, applied at the `xdg_surface.configure` that
ends it and reported only when it changes. No border band is made: a
Wayland window resizes only from the regions the application declares,
and `zig build title-bar` now declares a grip in its bottom-right corner.
Hyprland answers `server_side` to every request, so there the window
reports `custom_title_bar` false, the example draws no title bar, and
presses on chrome stay zui's; the tests play a compositor that forces it
and one that allows client-side mode. 87 of 88 tests pass in Debug and
ReleaseSafe, the opt-in one skipped: the host suite on a `.custom`
window, and tests that drive presses on the title bar (the move's
serial), each of the eight edges (`xdg_toplevel.resize_edge`'s numbers),
a double click before and after the compositor maximizes, a secondary
click, each caption button's press and release, one released on another
and one left by the pointer, the search field and the content reaching
zui, the regions at a forced scale of 2 and at a fractional 1.5 with a
zoom of 1.25 from a buffer overwritten after the call, configures
toggling `window_maximized`, a forced server-side mode, a native window
keeping no chrome, and a real toplevel's handshake. `zig build title-bar
-- --check` builds on Linux too, from `addTitleBarExample` in
`hosts/native/build.zig`, and hit-tests each part through
`Host.chromeKindAt` in a window the compositor never shows, submitting
no frame, as `zig build services -- --check` does, since a swap there
waits for a frame callback that never comes; it exits 0. Tour idle:
24.1 to 26.1 ms of CPU over 10 s, 10 or 11 frames, no wakes, as slice 5
measured. Not run, and waiting on a person at `zig build title-bar` on a
compositor that leaves decorations to the client, such as GNOME or KDE
Plasma, since Hyprland does not: dragging the title bar moves the
window, double-clicking it maximizes and restores it, right-clicking it
opens the window menu, the grip resizes it, the caption buttons show
hover and press and each works once, the maximize button shows restore
while maximized, and a monitor at a fractional scale keeps the parts
where they are drawn. The Windows check now also expects the grip as
`HTBOTTOMRIGHT`, compiled here and not run. Slice 7 is next.

Decided here:
- **libwayland-client, linked,** as sokol-zig links it, since the surface
  must be its objects; xdg-shell's and cursor-shape-v1's interfaces are
  written in Zig rather than generated at build time, so the build needs
  no wayland-scanner or protocol files.
- **One thread:** the host reads and dispatches in `zuiPoll` and
  `zuiWait`; a wait ends on input, a wake, a configure, a new scale or
  the close button, and the compositor's other events (a buffer
  released after each frame) are dispatched without ending it, which is
  what lets the tour idle.
- **The renderer sizes the surface:** `zui_sokol` resizes its
  `wl_egl_window` to each frame's viewport in physical pixels, since a
  Wayland surface has no size until a buffer is attached.
- **An unshown window is a surface without a role,** so the suite runs
  against a real compositor without showing a window.
- **A logical key** is the keysym at the key's first level, or its US
  place where that names no key; `scancode` is the evdev code.
- **A D-Bus client of the host's own,** not libdbus or sd-bus. Slice 1
  linked libwayland because a surface must be its objects for EGL to draw
  into; nothing outside the host shares a D-Bus connection, so no such
  reason holds here. The portal and the daemons need a SASL `EXTERNAL`
  handshake, a few method calls and three signals over a Unix socket,
  about 900 lines beside their tests, read into fixed buffers on the
  polling thread, so the host allocates nothing after `init` and waits
  on the buses in the same `ppoll` as the display. libdbus would add a
  runtime dependency and a `-dev` package, allocate per message, need
  `dbus_threads_init_default` and a watch-and-timeout main-loop
  integration; sd-bus would tie the host to systemd's libraries, which
  musl distributions lack.
- **The first frame has the desktop's settings:** `init` waits up to
  250 ms for the answers, and one that comes later arrives as a change.
  Match rules name the sender, so another client's signal is not taken
  for the portal's.
- **A signal the application handles or ignores is left alone,** and the
  host's handler resets itself as it runs, so a second Ctrl+C ends a
  process the first did not.
- **Repeats keep their own instants,** and a frame late by more than four
  gets four, not a burst.
- **Text input at version 1,** since version 2 adds only actions,
  languages, panel requests and preedit hints, which nothing in the
  record carries. Its cursor rectangle is the caret's covering in surface
  coordinates, and the state follows the harness's events without the
  manager, so the tests run under compositors that lack it.
- **The compositor's decoration mode wins:** a `.custom` window the
  compositor configures `server_side` reports `custom_title_bar` false
  and hands it no press, as the protocol asks a client to follow the mode.
- **A title bar's double click is measured press to press,** within
  `zui.Gestures.double_tap_seconds`, since the move the first press
  starts takes its release.
- **No resize band of the host's:** a client-side Wayland window has no
  compositor border, and the Windows host's top band stands in for a
  border the caption took, which Wayland never had; the application
  declares the edges and grips it resizes from.

## 10-reach:02-web-host — Web

A canvas surface, on the loop `10-reach:06-platform-owned-loop` gives a
host that cannot block.

**Grounding** (at `dfe65ed`).
- The browser runs the tour as a thin client over `zui_wire`
  (`09-seeing-the-ui:04-demo-in-browser`). A Web Worker steps a
  `zui_app.Session` of `zui_tour.App` (`hosts/web/src/tour_session.zig:22`)
  on a stepped host, `PageHost` (`:256`), whose surface is `.wire`, and a
  renderer, `PageRenderer` (`:291`), that writes each frame as wire bytes.
  The page's second WebAssembly instance, the client
  (`hosts/web/src/browser.zig:49`), decodes them, lays each out in a
  `zui_webgl.DrawList` (`zuiWebLayOutNewestFrame`, `:146`), and
  `FrameDrawer.draw` (`renderers/webgl/web/frame_drawer.mjs:398`) reads the
  list back through the client's `zuiWeb*` exports and draws it with WebGL 2.
  Every frame crosses `postMessage` twice, and the page's loop
  (`hosts/web/web/tour_page.mjs:126-145`) decides when to step the worker.
- `zui_webgl.Drawing` (`renderers/webgl/src/drawing.zig:14`) only declares
  what the page draws; its `zuiSubmit` returns `error.UnsupportedSurface`
  (`:23`). Nothing submits to a `.web` surface, which is
  `struct { canvas: u32, format }` (`core/src/surface.zig:51`), and no host
  gives one.
- The tour's tasks run on `SteppedIo`, whose stepper waits on a futex for
  each task's turn (`hosts/web/src/stepped_io.zig:166`). A browser lets a
  worker wait on shared memory and never the page's main thread, so the
  tour, with the tasks of the Gallery and Mission Control, can be stepped
  only from a worker.
- `10-reach:06-platform-owned-loop` gave the pushed loop half:
  `zuiRun(self, io, window, driver)`, `!void` or `noreturn`
  (`core/src/contracts.zig:237-249`), and `zui_app.runWith`, which makes the
  `Session` behind the `zui.Driver` on the heap
  (`core/zui_app/zui_app.zig:432-441`), so a `zuiRun` that never returns
  leaves it alive. `expectPushedHostConforms` runs `zuiRun` in the test's
  process with a watchdog thread, and is a compile error for a `noreturn`
  one (`core/zui_testing/loop_conformance.zig:59-65`).
- Input already maps from the browser's events to zui's in
  `hosts/web/src/browser_input.zig`, and `web/input_recorder.mjs` reads the
  canvas's events, size and `devicePixelRatio`, calling the client's
  exports; nothing reports the environment, lifecycle or a lost WebGL
  context.

**Plan.** `zui_web.Host` is a pushed host in a dedicated Web Worker that
draws on an `OffscreenCanvas` the page transferred to it, so the
application, its renderer and its tasks share one WebAssembly instance,
and the page keeps only what a worker cannot touch: the canvas's events,
its media queries, and the cursor.
- **The loop.** The worker's own event loop pushes it. `zuiRun` registers
  the driver, schedules the first turn and is `noreturn`: it yields to the
  worker's event loop through an import that throws, which unwinds the
  WebAssembly stack without running its epilogues, so the frames below,
  `runWith`'s included, are never reused, as Emscripten's main loop does.
  The worker's script then calls the host's exports from
  `requestAnimationFrame`, a timer, or a message from the page, and each
  steps the `Io` if it is a `SteppedIo` (known by its vtable), polls, and
  calls `driver.step()`, scheduling the next as the returned
  `NextFrame`, folded with the `Io`'s next wake by `sooner`: `.immediately`
  as an animation frame, `.at` as a timer, `.on_event` as nothing until
  input arrives. A wake from a task, which runs only inside a step, ends
  that step with the next turn due at once.
- **The surface.** The page gives each canvas it transfers an id, and
  `zuiSurface` names it as `.web = .{ .canvas = id }`. A lost WebGL context
  (`webglcontextlost`) is `driver.suspendSurfaces()`, and its return
  `resumeSurfaces()`.
- **The drawing.** `zui_webgl.Renderer` takes the place of `Drawing`: its
  `zuiSubmit` lays the frame out in its `DrawList` in the same instance and
  hands the page's `FrameDrawer` one `zui_webgl.DrawnFrame`, an extern
  struct of the list's pointers and counts, through one import, which only
  the WebAssembly build declares. The wire leaves the drawing path; the
  client draws the frames it decodes through the same renderer.
- **The platform is a type.** `HostOn(Platform)` holds the host's logic;
  `zui_web.Host` is `HostOn` the browser's imports, and the tests run it
  on a scripted platform whose `zuiRun` returns, through
  `expectPushedHostConforms`, natively.

In slices, each a commit with every check green:
1. **The renderer.** `zui_webgl.Renderer`, a `.web` renderer drawing any
   text's fonts, whose `zuiSubmit` lays the frame out and hands a
   `DrawnFrame` to the page; `FrameDrawer.draw(memory, drawnFrame)` reads
   that alone, so the client's layout exports go. The client submits each
   frame it decodes through the renderer, so `test-draw` checks the
   renderer's drawing against the sokol renderer's. `Drawing` is removed,
   and the tour's worker, its context and `demo_ui.zig` name `Renderer`.
   `expectRendererConforms` runs on it natively, its frames handed to a
   page that keeps them, without reading pixels back.
2. **The host.** `zui_web.HostOn(Platform)` in `hosts/web/src/host.zig`:
   the window half over the page's events, which `browser_input` maps,
   into a record of its own; the canvas's size and `devicePixelRatio`; the
   cursor applied through the platform; `.web` surfaces by id; the
   `Waker`; the loop of the plan, with a lost context. It passes
   `expectPushedHostConforms` on a scripted platform, ThreadSanitizer
   included.
3. **The browser and the tour on it.** `web/host_worker.mjs` (the
   module, its threads, animation frames, timers and messages) and
   `web/host_page.mjs` (the canvas transferred, its events sent as
   messages, `input_recorder.mjs` reading them through a sink in place of
   the client's exports, the cursor posted back); the tour target,
   `hosts/web/examples/tour.zig`, naming `zui_tour.App` on `zui_web.Host`,
   `zui_webgl.Renderer` and `zui_truetype.Text`, and `zig build tour`
   writing its page. `zig build test-host` opens it in headless Chromium,
   without a display, and checks that it draws the tour, sleeps while
   idle, its input reaches the tour, it shows the cursor the tour asks
   for, and a context lost through `WEBGL_lose_context` comes back with
   the tour's screen kept.
4. **The environment.** `prefers-color-scheme`, `prefers-contrast`,
   `prefers-reduced-motion` and `prefers-reduced-transparency` from the
   page's media queries, `navigator.language` and the document's
   direction, the window's focus, and the page's visibility as lifecycle
   (`suspend` hidden, `resume` shown), each an `EnvironmentChange` or
   `lifecycle` event in the next record; `test-host` emulates each media
   query and checks the tour restyles.
5. **The published page on the host.** `index.html` runs the tour target;
   `site_scripts`, `test-site` and its service worker follow it. The thin
   client, `TourSession` and the wire stay for `test-demo` and
   `test-draw`, which check that the worker's frames are the native ones
   and that the WebGL drawing is the sokol renderer's.
6. **Text input and services.** The caret's `TextInputArea` places a
   hidden text field on the page, so the browser's IME composes there and
   its text reaches the record; `zuiClipboard` over
   `navigator.clipboard`, answered into its sink later, and `zuiOpenUrl`
   through the page.

**Done when:**
- `zui_web.Host` passes `expectPushedHostConforms`, its logic on a
  scripted platform natively, and `test-host` runs it on the browser's in
  headless Chromium;
- `zui_webgl.Renderer` passes `expectRendererConforms`, and `test-draw`
  checks its drawing against the sokol renderer's;
- the tour runs unchanged on `zui_web.Host`, `zui_webgl.Renderer` and
  `zui_truetype.Text`, named at one place, and the published page runs
  it: `test-host` and `test-site` (also in ReleaseSmall) pass, with its
  environment, lifecycle, lost context, cursor, text input and clipboard
  reaching the tour;
- `test-demo`, `test-draw` and `test-input` still pass, everything the
  browser runs compiles for `wasm32-freestanding`, and each check fits
  10 minutes.

**Spec.** §6.1, §7.2, §7.3, §16.2, §16.3, §16.4, §19.4, §19.5.

**Status.** Slice 1 is done: `zui_webgl.Renderer` (`RendererOn(Page)`
over the browser's page) takes the place of `Drawing`, which is removed.
It draws into a `.web` surface: `zuiSubmit` asks the canvas whether it can
blur, lays the frame out in its `DrawList` and hands the page a
`DrawnFrame`, an extern struct of 56 bytes on `wasm32` whose offsets a
comptime check pins, through the imports `frameDrawerImports`
(`renderers/webgl/web/frame_drawer.mjs`) gives the module; the atlas's
texels go with a frame only when they changed. `FrameDrawer.draw(memory,
address)` reads that alone, for an `HTMLCanvasElement` or an
`OffscreenCanvas`. Called off WebAssembly the renderer is a compile
error, pinned in `renderers/webgl/tests/compile_errors/`, and
`expectRendererConforms` passes on it natively over a page that draws
nothing. The client submits each frame it decodes through the renderer
(`zuiWebDrawNewestFrame`), so its layout exports are gone and `test-draw`
checks the renderer's drawing against the sokol renderer's: `test-demo`
in Debug and ReleaseSafe, `test-draw`, `test-input` and `test-site` (also
in ReleaseSmall, where `zui-web.wasm` is 80 KB, from 82) pass. The
decision on where the host runs is recorded under *Made*. Slice 2, the
host's Zig half, is next.

## 10-reach:03-services — Services

**Grounding** (at `62d0813`, with `hosts/native/` at `0dd3be1`, before the
first slice). The host contract listed six optional services by name
(`core/src/contracts.zig:23`), and `checkHost` only checked that each was a type
(`:100-102`). Only `zuiFileWatch` had a checked shape (`checkFileWatch`,
`:143`), pinned by `host_file_watch_wrong_signature`. The pattern it set
(`05-wire:05-watching-files`) is a sink: `zui.FileChangeSink`, a pointer and a function, made by
`.of(&source)` from any source whose `publish` returns `Wake` or
`error{Full}!Wake` (`core/src/host.zig`). SPEC.md showed the other five only as
`struct { ... }` (§16.3) and said they are reached through `zui_app` with
`has_*` guards (§16.6), but nothing declared a guard. `zui_app` named the
services (`core/zui_app/zui_app.zig:177`) only to report the missing ones
(`:375`); an application reaches its host only through `Start(App).host`
(`:198`), and `zuiLoader` gets the context and the `Io`, not the host
(`:552`). `zui_app`'s test host declared `zuiClipboard = struct {}`
(`core/zui_app/tests.zig:15`).

The frame boundary had no channel for a service: `HostRequests` holds the
cursor and the IME area, diffed as state by `zuiApply`, and a new kind of
event would need a variant, storage in the context and a limit, as dropped
files have. `09-seeing-the-ui:02-semantics-and-accessibility` found that even a zero-size field added to `Frame` moved `01-measure:03-instruction-counts-in-ci`
counts. `zui_wire`'s host declares no services. A `zui_async.Stream` with
one producer panics in safe builds when two publish at once.

On Windows only the clipboard existed, unchecked
(`hosts/native/windows/host.zig:40`): `read(host, buffer) ?[]u8` copied
`CF_UNICODETEXT` on the caller's thread (`:860`), and `write(host, text)`
returned `error{InvalidUtf8, ClipboardUnavailable, OutOfMemory}` (`:873`),
where `OutOfMemory` was `GlobalAlloc` failing (`:875`): the OS's memory,
handed to the clipboard, so not the host's allocation, but named as if it
were. A synchronous read is Windows' alone: on Wayland the selection is
read from a pipe the copying client writes into (`10-reach:01-linux-host` slice 3), and in a
browser `navigator.clipboard.readText` is a promise (`10-reach:02-web-host`). The window
thread runs the message loop in a single-threaded apartment (`:387-389`),
dispatches everything through `handleMessage` (`:467`), and takes work
from the UI thread as `WM_APP` messages (`:93`). A modal loop on it, such
as a move or resize, keeps dispatching the window's messages. Test-only
settings are fields set before `init` (`:62`), and the harness sends what
the OS would (`hosts/native/windows/conformance.zig:43`).

**Plan.** Five slices; the first fixes every shape at once, so `14-macos:01-macos-host` and `10-reach:01-linux-host`
build on one reviewed contract.

1. **The shapes, checked; the clipboard and URLs on Windows.** Core: the
   vocabulary in `core/src/services.zig`; `checkHost` checks every service's
   functions, with a compile-error case for each function, one for a
   service that is not a struct and one for `ServiceSink.of`;
   `zui_app.ServicesOf(Host)`, its `has_*` guards and the unguarded-call
   error; `core/tests/instantiate.zig` declares a host with all five;
   `zui_testing`'s host suite checks the services a host declares.
   `hosts/native/`: the clipboard moves to the new shape and `zuiOpenUrl` is
   added, both answered from the window thread (`windows/services.zig`).
2. **Notifications** (`hosts/native/`): `Shell_NotifyIconW` with `NIF_INFO` and
   `NOTIFYICON_VERSION_4`, the icon added on the first `show` and removed
   when the balloon ends or at `deinit`; `NIN_BALLOONUSERCLICK` answers
   `.notification_activated`, `NIN_BALLOONTIMEOUT` and `NIN_BALLOONHIDE`
   `.notification_dismissed`, as does a notification replaced by the next.
   The fake records `NIM_ADD` and `NIM_MODIFY`, and the tests send the
   callback messages Windows would.
3. **File dialogs** (`hosts/native/`): `IFileOpenDialog` and `IFileSaveDialog`
   created and shown on the window thread, owned by the window; `show`
   copies the dialog's strings into a fixed buffer, posts it and returns;
   the dialog's modal loop keeps dispatching the window's messages, and
   its paths (`SIGDN_FILESYSPATH`) or `.canceled` are published. One
   dialog or menu at a time. The vtables go in `windows/file_dialog.zig`;
   the fake builds and configures the real dialog and reads `GetOptions`
   back without `Show`.
4. **Menus** (`hosts/native/`): `popup` builds a menu with `CreatePopupMenu` and
   `AppendMenuW` on the window thread, converts the position to screen
   pixels, and shows it with `TrackPopupMenuEx(TPM_RETURNCMD)`; `setBar`
   builds one with `CreateMenu` and answers each `WM_COMMAND`. Items are
   numbered by the host (`WM_COMMAND` carries 16 bits) and mapped back.
   A menu bar's `HMENU` lives in one struct of per-window service state,
   for `10-reach:05-many-windows` to move into its window slots; with `10-reach:04-window-decorations`'s custom title bar,
   `setBar` may answer `error.Unavailable`.
5. **The example, and closing `10-reach:03-services`** (`hosts/native/` and core):
   `examples/services.zig` and `zig build services` on `zui_app`, with a
   menu bar, a context menu, and buttons to copy, paste, notify, open,
   save, choose a folder and open a URL, each answer shown; one
   `Stream(zui.ServiceReply(16 * 1024))`, every call from `zuiLoader`
   through `ServicesOf`; `-- --check` scripts what shows nothing.

**Done when.** Automated: core's tests in Debug, ReleaseFast and
ReleaseSafe and its `wasm32-freestanding`, `powerpc-linux` and `x86-linux`
checks; each compile-error case fails with its message; the native hosts' tests
in Debug and ReleaseSafe, `check` and `fmt-check`, with the host suite
passing every service the host has built, faked through
`Host.service_fake`; the host's own tests of `error.Busy`,
`error.TooLarge`, the menu built (read back from the `HMENU`), the
popup's position in screen pixels, a menu bar's `WM_COMMAND`, the dialog's
configuration, the notification's callbacks, and `ShellExecuteW` never
reached with a refused URL; the sokol renderer's tour runs unchanged; `01-measure:03-instruction-counts-in-ci` counts
unchanged. By a person, in slice 5: `zig build services` in `hosts/native/`,
choosing a file, saving, choosing a folder, a notification clicked, a
context menu and the menu bar, a URL opened in the browser, copy and
paste, each in a screenshot.

**Spec.** §14.1, §16.3, §16.6, §19.5, §19.6.

Done in five slices. Slice 1, in `578b8c1` and `22a8cd5`: core gained
`core/src/services.zig`: `zui.ServiceRequest` (`.of(name)`), `ServiceAnswer`
(the outcome, borrowed, and the bytes the host could not hold),
`ServiceReply(n)` (the plain-data copy, text cut at a character and paths
kept whole, the rest counted), `ServiceSink` (`.of(&source)` for any source
whose `publish` takes a `ServiceReply(n)`), `ServiceError`,
`ServiceFailure`, `Notification`, `FileDialog`, `FileFilter`, `MenuItem`,
`MenuItemId` and `isOpenableUrl`. `checkHost` checks each service is a
struct and each function's type, `checkFileWatch` folded into the same
table with its message unchanged; ten compile-error cases pin the
messages. `zui_app.ServicesOf(Host)` gives `has_clipboard` through
`has_file_watch` and `has_menu_bar`, and each service behind its guard.
`zui_testing.expectHostConforms` checks a clipboard round trip, that a
path, a `file:` URL and a word are refused, and with the harness's
`openedUrl` that a URL reaches the system, and with `scriptServices` that
dialogs, menus and notifications answer as scripted, each naming its
request and window; its test host passes, and one answering another
request and one opening a path fail. A delivery of replies round-trips
through `zui_wire`. On Windows, `zuiClipboard.read` and `zuiOpenUrl.open`
claim a slot and post to the window thread, which reads the clipboard
(up to 64 KiB of UTF-8, lone surrogates replaced, the rest counted as left
out) or calls `ShellExecuteW`, so every answer comes from one thread;
`write` reports `GlobalAlloc` failing as `error.Unavailable`. The host
suite passes against a hidden window with the URL opener faked. Measured:
the zui-counts executable's .text and .rodata are byte-identical to
`62d0813`'s (sha256 6ac82a44... and d05b536a...), so `01-measure:03-instruction-counts-in-ci` counts are
unchanged; the sokol renderer's tour on the host, in ReleaseSafe with
`--measure-idle`, idled at 0.0 ms of CPU over 10 s, and `zui_app` now
reports only notifications, file dialogs and menus missing. Decided in
the slice, beyond the plan: `Busy` also refuses a clipboard read or a URL
still waiting for the window thread; `ServiceAnswer.left_out_bytes`
carries what the host itself could not hold; `zui.isOpenableUrl` is core,
so every host refuses the same URLs.

Slice 2, in `hosts/native/` alone (`c6fc2d8`): `zuiNotifications.show`
checks the text is UTF-8, copies the title and body into fixed buffers cut
at a character to what `NOTIFYICONDATAW` holds (63 and 255 UTF-16 units),
and posts to the window thread, which adds the window's notification-area
icon on first use (`NIM_ADD`, then `NIM_SETVERSION` to version 4) and
shows the balloon (`NIM_MODIFY` with `NIF_INFO`), which Windows 10 and 11
show as a toast. The icon's callback message answers
`.notification_activated` for `NIN_BALLOONUSERCLICK` and
`.notification_dismissed` for `NIN_BALLOONTIMEOUT` and `NIN_BALLOONHIDE`,
then removes the icon; a notification replaced by the next is answered
`.notification_dismissed` and the icon stays; `Shell_NotifyIconW` failing
is `.failed = .unavailable`; the icon goes when the window is destroyed,
and one still showing then is not answered. A second `show` while the
first waits for the window thread is `error.Busy`. The fake records each
`Shell_NotifyIconW` call by message and the balloon's text, and answers
as the harness's `scriptServices` says by posting the callback message
Windows would, so the host suite now checks a notification through the
real callback path; the host's own tests check the calls made, the title
cut at a character, a click, a replacement, a time-out removing the icon,
and a callback with nothing showing answering nothing. The sokol renderer's tour on
the host idles as before (15.6 ms of CPU over 10 s and 10 frames on the
Welcome screen in ReleaseSafe) and `zui_app` now reports only file dialogs
and menus missing. Not detected: notifications the user turned off, or Do
Not Disturb, neither of which a balloon reports, so the Windows host never
answers `.failed = .denied`.

Slice 3, in `hosts/native/` alone (`eb0150b`):
`zuiFileDialogs.show(host, window, request, dialog, sink)` copies the
dialog's strings into one fixed buffer of 8,192 UTF-16 units: the title,
the directory made absolute (`GetFullPathNameW`, since the shell takes only
absolute ones), the suggested name, and up to 16 filters as patterns
(`*.zon;*.json`, or `*.*` for one without extensions). Past either limit it
is `error.TooLarge`, and text that is not UTF-8 is `error.InvalidUtf8`. It
then posts to the window thread, which is already a single-threaded
apartment. That thread makes `IFileOpenDialog`, or `IFileSaveDialog` for
`.save_file`, through `CoCreateInstance` (`windows/file_dialog.zig`, its
vtables written by hand). It always sets `FOS_FORCEFILESYSTEM`,
`FOS_NOCHANGEDIR` (so the process's working directory never moves) and
`FOS_PATHMUSTEXIST`. Open dialogs add `FOS_FILEMUSTEXIST`, and
`.open_files` adds `FOS_ALLOWMULTISELECT`. `.save_file` adds
`FOS_OVERWRITEPROMPT` and the first filter's first extension as the
default, and `.choose_folder` adds `FOS_PICKFOLDERS`. The thread then runs
`Show` owned by the window. Its modal loop keeps dispatching the window's
messages. The answer is `.files_chosen` with each `SIGDN_FILESYSPATH`
path in UTF-8 (up to 32 KiB, paths past it counted as left out), or
`.canceled`. A dialog the shell cannot make is `.failed = .unavailable`. A
second `show` while one waits or is open is `error.Busy`. A dialog still
open when the host closes is cancelled first, and its answer is not
published, since the application's sources may be gone by then. The
window closes once `Show` has returned. `IFileDialog.Close` called from
outside the dialog's own events returned `S_OK` but did not end `Show`,
so the host posts `WM_CLOSE` to the dialog's window, found through
`IOleWindow`, which cancels it as the Cancel button does.

The fake makes and configures the real dialog and stands in for `Show`.
It reads back the options, the suggested name and the folder from the
dialog's own getters, records the filters it was given (the shell has no
getter for them), and answers what the harness's `scriptServices` scripts.
It can also hold the dialog open, dispatching the window's messages as
`Show` would. The host suite now checks file dialogs through the window
thread. The host's own tests check an open dialog's options, folder and
filters and its paths; a save dialog's name, overwrite prompt and cancel;
a folder dialog; `Busy` while one is open; paths past the reply's room
counted; `TooLarge` and `InvalidUtf8` showing nothing; and a dialog open at
close answered with nothing. Two checks of the real `Show`, run once by
hand and not committed, showed a dialog on the desktop. One, given the name
`C:\Windows\win.ini` and sent its OK command, answered `.files_chosen`
with that path. The other, open when the host closed, returned
`0x800704C7` (cancelled) and closed the host about 0.1 s later, with
nothing answered.

Found and fixed: a clipboard read (since slice 1) and a file dialog
published their answer before releasing their slot, so a call made as
soon as the answer arrived could be `error.Busy`. Two of about 20 runs of the ReleaseSafe suite failed
this way. Each now releases first. The bytes it answers with stay put,
since only the window thread writes them. Twenty runs each in Debug and
ReleaseSafe then passed. The sokol renderer's tour on the host, in ReleaseSafe with
`--measure-idle`, idled at 31.3 ms of CPU over 10 s and 10 frames on the
Welcome screen, two of Windows' 15.6 ms ticks, against one in slice 2.
`zui_app` now reports only menus missing.

Slice 4, in `hosts/native/` (`02282d5`), with one sentence added to SPEC.md
§16.3 (`fcdef0e`): `zuiMenus.popup(host, window, request, items, position,
sink)` and `setBar(host, window, request, items, sink)` copy the items
into a fixed menu of up to 256 entries and 8,192 UTF-16 units, at most
eight submenus deep (`windows/menu.zig`). Each label is shown as written,
its `&` doubled so Windows underlines nothing, with its shortcut after a
tab as Windows' own menus spell it (`Ctrl+Shift+S`, `F1`). Past a limit
it is `error.TooLarge`, and a label that is not UTF-8 is
`error.InvalidUtf8`. `popup` converts the position to client pixels with
the last poll's scale and posts to the window thread, which builds the
menu with `CreatePopupMenu` and `AppendMenuW`, converts the position to
the screen, and shows it with `TrackPopupMenuEx(TPM_RETURNCMD |
TPM_NONOTIFY)`. It answers `.menu_item_chosen` with the application's own
id, or `.canceled`, and `.failed = .unavailable` while the user is in the
bar's menus, since Windows shows one menu at a time. A file dialog and a
popup now share one claim, so either one while the other waits or is
open is `error.Busy`. A popup still open when the host closes is ended
with `EndMenu`, not answered, and the window closes after it, as an open
dialog does. `setBar` builds the bar with `CreateMenu`, sets it with
`SetMenu` and destroys the one it replaced; given no items it removes the
bar. Each `WM_COMMAND` from it answers `.menu_item_chosen` to its request.
A bar set while the user is in the old bar's menus waits until they
close (`WM_EXITMENULOOP`), so a tracked menu is never destroyed. Each bar
and each popup numbers its items from a range of its own, two bars'
ranges in turn, so a command Windows reports after the bar was replaced
still names the bar it came from and is answered to that bar's request.
SPEC.md now says so, and that `setBar` with no items removes the bar.

The fake builds the real `HMENU` and stands in for `TrackPopupMenuEx`. It
reads the menu back item by item (`GetMenuStringW`, `GetMenuState`,
`GetMenuItemID`), records the position in screen pixels, and answers the
item the harness's `scriptServices` scripts. It can also hold the menu
open, dispatching the window's messages. The host suite now checks menus
through the window thread, so it checks all five services. The host's own
tests check a popup's items, separator, submenu, grayed and checked
states, doubled `&` and shortcut read back from the `HMENU`, and its
position in screen pixels at a forced scale of 2; `Busy` across popups
and dialogs both ways, and a closed menu answering `.canceled`;
`TooLarge` and `InvalidUtf8` showing neither a popup nor a bar; a popup
open at close answered with nothing; and a menu bar read back from the
window's own `GetMenu`, answering two choices sent as `WM_COMMAND`,
waiting while its menus are open, answering a late choice from the bar it
replaced, and removed. The native hosts' tests (63) passed six times each in
Debug and ReleaseSafe. The sokol renderer's tour on the host, in ReleaseSafe
with `--measure-idle`, idled at 0.0 to 31.3 ms of CPU over 10 s with 9 to
14 frames in three runs on the Welcome screen; a fourth drew 96 frames for
the pointer over the window. `zui_app` now reports no service missing.

Slice 5, in `hosts/native/` alone, after `02282d5`: `zig build services`
(`examples/services.zig`), a window on `zui_app` with a button for each
service: pick a file, save a file, show a notification, open a popup
menu, set or clear the menu bar, copy, paste, and open
<https://ziglang.org>. Each answer shows beside its button. A right click
anywhere opens the context menu, and Ctrl+C, Ctrl+V, Ctrl+O and Ctrl+S do
what the menus say. Declaration only notes what was asked for, and reads
the answers from one `Stream(zui.ServiceReply(16 * 1024))`; a popup's or
the bar's choice asks for the action it names. The loader makes every
call through `zui_app.ServicesOf`, behind its guards. The host gained
`Host.fakeServices(fake)`, the fake set after `init`, since `zui_app`
starts every host field at its default. `-- --check` runs the window
hidden, with the fake answering as a user would. It presses each button
in turn, chooses File > Pick a file from the bar by sending the
`WM_COMMAND` Windows would, and passes once each answer shows in a
frame's text and the bar is on, then off, the window (`GetMenu`). It
fails after 10 s. The paste right after the copy usually found the
clipboard held by another application (clipboard history, which opens it
after every change) and answered `.failed = .unavailable`, as the
contract says: four of the first five runs failed this way. The check now
presses Paste again, as a user would, and says how often. It then passed
in seven of seven runs, six in Debug and one in ReleaseSafe, each
pressing Paste once or twice more. The native hosts' 63 tests pass in Debug and ReleaseSafe, with
`check` and `fmt-check`. The sokol renderer's tour on the host, in ReleaseSafe
with `--measure-idle`, idled at 0.0 ms of CPU over 10 s, with 12 frames
and no wakes.

Measured across the item: `01-measure:03-instruction-counts-in-ci` counts unchanged, since the zui-counts
executable's code was byte-identical (slice 1); no host frame path
changed; the host's fixed buffers for services are part of `Host`, so
calls allocate nothing of the process's.

What remains, and where it went:
- **Seen by a person, owed:** `zig build services` on the desktop, with
  a screenshot of each: the real toast, and clicking it to see
  "clicked"; the real open and save dialogs choosing a file; the real
  popup from a right click and from its button; the real menu bar, its
  menus opened by hand and an item chosen; and the browser opening
  <https://ziglang.org>. The hidden window, the fake and the hand-run
  `Show` of slice 3 cover everything else.
- **The menu bar shrinks the client area** by its height: `setBar`
  resizes the window's content, so the next record's viewport is
  smaller, and removing the bar gives it back. A window opened at a
  size keeps its outer size, not its content's.
- **`10-reach:04-window-decorations`:** a custom title bar has no caption for Windows' menu bar to sit
  under. `10-reach:04-window-decorations` decided: under a custom title bar `setBar` answers
  `error.Unavailable`, since a native bar would sit hidden under the
  drawn one, and the application draws its own bar and uses `popup` for
  its menus. A popup's position, in the client area's layout units, holds
  either way.
- **`10-reach:05-many-windows`:** dialogs and menus name their `WindowId`, and the Windows host
  asserts `.main` until `10-reach:05-many-windows` maps ids to windows; the menu bar's state is
  one struct for `10-reach:05-many-windows` to keep per window.
- **`10-reach:01-linux-host`:** the Linux host implements these shapes; `zuiMenus` has no
  Wayland counterpart, so it may declare none.
- **Not detected on Windows:** notifications turned off or Do Not
  Disturb, which a balloon does not report, so `.failed = .denied` is
  never answered there.

## 10-reach:04-window-decorations — Window decorations

**Grounding.**
- Before `10-reach:04-window-decorations`, nothing implemented chrome regions. SPEC.md listed
  `Frame.chromeRegions()` (§6.5), and §13.4 had one sentence about them.
- Hit regions are not a list in the frame. Emission writes them into the
  context's `memory.results` (`core/src/emission.zig:65-66`, `:328-331`), so
  chrome is computed beside the frame instead, after layout, and emission
  is not touched. Its walk is copied per frame kind because any change to
  it moved `endFrame` by up to 5% (`core/src/emission.zig:56-61`).
- The pattern for data beside a frame is `09-seeing-the-ui:02-semantics-and-accessibility`'s: a list in `FrameSlot`
  (`core/src/context.zig:771`). Any field added to `Frame` moved `01-measure:03-instruction-counts-in-ci` counts.
- `appendElement` is `inline`, so an `Element` field left at its default
  costs nothing. `09-seeing-the-ui:02-semantics-and-accessibility`'s `semantics` field left the counts identical with the
  feature off.
- The Windows host:
  - runs its message loop on a thread of its own
    (`hosts/native/windows/host.zig:541`);
  - sizes the window with `AdjustWindowRectExForDpi` (`:588`);
  - handles no non-client message, and sets the application's cursor only
    over `HTCLIENT` (`:724`);
  - stores requests under its SRW lock in `zuiApply` (`:479`), for the
    window thread to apply (`:864`);
  - extends the frame over the client for Mica (`:900`), and sets dark
    mode in `reportEnvironment` (`:914`).
- `10-reach:03-services`'s `zuiMenus.setBar` (`hosts/native/windows/host.zig:150`) sets a native menu bar,
  which is non-client.

**Plan.** A custom title bar is asked for in `WindowOptions`. The
application marks its parts with `Element.chrome`, behind
`features.chrome_regions`. The frame lists them in a slot beside it, and
`zui_app` hands the list to the host through an optional frame call,
`zuiChromeRegions`, as it hands semantics to `zuiSemantics`. The Windows
host keeps a snapshot, answers `WM_NCHITTEST` from it, and works the
caption buttons itself.
1. **The core, `zui_app` and `zui_testing`** (core only):
   - `ChromeKind`, `ChromeRegion` (`core/src/chrome.zig`).
   - `TitleBar`, `WindowOptions.title_bar` and
     `HostCapabilities.custom_title_bar` (`core/src/host.zig`).
   - `Environment.custom_title_bar` and `.window_maximized`, with their
     changes (`core/src/input.zig`).
   - `Features.chrome_regions`, `Element.chrome`, `Frame.chromeRegions()`,
     and the list in `FrameSlot` (`core/src/context.zig`).
   - `zuiChromeRegions` checked as a frame call, and `custom_title_bar`
     checked against it (`core/src/contracts.zig`).
   - `zui_app.Options.title_bar`.
   - A step in the host suite.
2. **The Windows host** (`hosts/native/`, then the documents):
   - `WM_NCCALCSIZE` removes only the caption, so DWM keeps the border,
     the rounded corners and the shadow. A maximized window is inset by
     the frame's thickness.
   - `WM_NCHITTEST` answers, in this order:
     - `DefWindowProcW`'s border codes;
     - a top resize band, from `SM_CYSIZEFRAME + SM_CXPADDEDBORDER`, when
       not maximized;
     - a snapshot of the regions, from the last to the first, under the
       lock taken shared (`HTCAPTION`, `HTMINBUTTON`, `HTMAXBUTTON`,
       `HTCLOSE`, `HTTOP` … `HTBOTTOMRIGHT`, `HTCLIENT`);
     - otherwise `HTCLIENT`.
   - `WM_NCMOUSEMOVE` and `WM_NCMOUSELEAVE` become pointer moves and
     leaves at client points.
   - `WM_NCLBUTTONDOWN` and `WM_NCLBUTTONUP` on a caption button become a
     press and a release, and the host minimizes, maximizes or restores,
     or closes on the release.
   - Presses on the caption and the edges go to `DefWindowProcW`, which
     moves, resizes, maximizes on a double click and opens the system
     menu.
   - Public `minimize`, `toggleMaximized` and `close` let an application
     act on `clicked` for the keyboard and Narrator.
   - The snapshot holds 256 regions, and nothing is allocated after
     `init`.
   - Conformance tests send `WM_NCHITTEST` and the non-client mouse
     messages to hidden windows.
   - `hosts/native/examples/title_bar.zig` and `zig build title-bar`.
   - Under a custom title bar `zuiMenus.setBar` answers
     `error.Unavailable`, since a native bar would sit hidden under the
     drawn one.

**Decisions.** Made by the owner when `10-reach:04-window-decorations` was taken:
- The host works the caption buttons, as the system's own. It also has
  public calls for an application that acts on `clicked`. Slice 2 found
  that a pointer's click would then be worked twice, by the host and by
  `clicked`, and a double maximize undoes itself, so the host ends a
  caption button's press with `pointer_cancel`: zui shows the press and
  reports no click, and `clicked` comes only from the keyboard and
  assistive technologies.
- Under a custom title bar `zuiMenus.setBar` is `error.Unavailable`
  (recorded in `10-reach:03-services` too).
- The channel is an optional frame call, `zuiChromeRegions`, not a field
  of `HostRequests`.
- A title bar's `.client` regions are derived from its interactive,
  disabled and scrolling descendants.
- The Windows host makes the top resize band itself.
- The title bar's state is reported in `Environment`.
- `zui_app.start` refuses `.custom` without the feature.
- A person checks it on a new `hosts/native/examples/title_bar.zig`.

**Done when:**
- A core test lists declared chrome with its bounds and its `.client`
  regions.
- `zui_app` hands the host each frame's list.
- `zui_host`'s tests get `HTCAPTION`, `HTMAXBUTTON`, `HTMINBUTTON`,
  `HTCLOSE`, `HTCLIENT` and the edges from `WM_NCHITTEST`, and the host
  suite passes on a custom window.
- A person drags, double-clicks, snaps with Win+arrows, sees snap layouts
  over the maximize button, and resizes from every edge on
  `zig build title-bar`, with Mica and dark mode showing.
- With the feature off, `01-measure:03-instruction-counts-in-ci` counts are unchanged.

**Spec.** §6.5, §7.2, §10.1, §13.4, §16.3, §19.5.

**Status.** Slice 1, the core, is done:
- `Element.chrome` declares a `ChromeKind`, ignored without
  `features.chrome_regions`.
- `Frame.chromeRegions()` lists the declared chrome in tree order, with
  each element's laid-out bounds and id. Each title bar is followed by a
  `.client` region for each interactive, disabled or scrolling element
  inside it that declares no chrome, in one walk that visits each element
  once from the first chrome element on.
- The list lives in `FrameSlot` beside the semantic list. It holds
  `max_elements` regions, since each element adds at most one, so no
  limit was added.
- `zuiChromeRegions(window, regions)` is a host frame call, checked as
  `zuiSemantics` is. A host whose capabilities set `custom_title_bar`
  without it is a compile error.
- `zui_app` hands the list to the host after `zuiSemantics`, on the UI
  thread and before the frame is submitted, so a render thread never
  races it. `Options.title_bar = .custom` without the feature fails
  `start`.
- The host suite hands a host that declares the call two regions from a
  buffer it then overwrites.
- `01-measure:03-instruction-counts-in-ci`, measured by CI's counts job on `6b6ce6f` against its parent
  `e2ba59b`: every scenario's declaration and `endFrame` per frame is
  identical to the instruction (4096 boxes declare 436,605 and
  `endFrame` 1,264,648; 1000 warm texts' `endFrame` 654,147).

Slice 2, the Windows host (`0e3e704`), is done:
- A window opened with `title_bar = .custom` drops its caption in
  `WM_NCCALCSIZE` and keeps the system's frame on the other three sides,
  so DWM draws its border, rounded corners and shadow. Maximized, its
  client top is inset by the frame's thickness. It is sized so its client
  area is still the size asked for.
- `WM_NCHITTEST` answers the system's borders, then a top resize band
  (`SM_CYSIZEFRAME + SM_CXPADDEDBORDER`), then a snapshot of the regions,
  the last on top. The snapshot is one `ChromeSnapshot` field with its
  own SRW lock, holding up to 256 regions in pixels, ready for `10-reach:05-many-windows` to move
  into each window's state.
- Non-client moves and leaves over the caption buttons reach zui at
  their client points. A press and its release on the same button work
  it through `WM_SYSCOMMAND`, and the release arrives as `pointer_cancel`.
  `Host.minimize`, `Host.toggleMaximized` and `Host.close` serve the
  keyboard and Narrator.
- The first report includes `custom_title_bar`, and `WM_SIZE` reports
  `window_maximized`. `zuiMenus.setBar` is `error.Unavailable` under a
  custom title bar.
- The host suite passes on a custom window. New tests send
  `WM_NCHITTEST` at the title bar, a search field inside it, each
  caption button, a grip, the top band and the three borders at a scale
  of 2, from a buffer overwritten after the call. They also send
  non-client moves, leaves, presses and releases, and check that a
  native window keeps the system's answers.
- `zig build title-bar -- --check` hit-tests each part as `zui_app` laid
  it out in a hidden window, and exits 0.

Waiting on a person, on `zig build title-bar` in `hosts/native/`, with and
without `--no-system-material`, in light and dark mode:
- Dragging the title bar moves the window, double-clicking it maximizes
  and restores it, and right-clicking it opens the system menu.
- Win+Up, Win+Down, Win+Left and Win+Right snap the window, and so does
  dragging it to a screen edge.
- Hovering the maximize button shows snap layouts.
- Resizing works from all four edges and four corners, the top included.
- The caption buttons show hover and press, and minimize,
  maximize/restore and close each work once.
- Maximized, the title bar is not cut off at the top.
- Mica, dark mode, and the DWM border and shadow show.
- Moving the window to a monitor at another scale keeps the parts where
  they are drawn.
Once checked, `10-reach:04-window-decorations` is done.

## 10-reach:05-many-windows — Many windows

**Grounding.** Where the code stood when `10-reach:05-many-windows` was taken (`daba4a7`, with
`hosts/native/` at `dbbef70` and `renderers/sokol/` at `d66de6c`):
- *The core.* A window is a `zui.WindowId` (`core/src/host.zig:5-8`), and a host
  says how many it opens in `HostCapabilities.windows`, default `.one`
  (`:14-24`). `zuiPoll`, `zuiSurface` and `zuiApply` already take a
  `WindowId`; `zuiWaker` and `zuiWait` take none, so one wake and one wait
  serve the whole host (`core/src/contracts.zig:117-121`). No host call opened
  or closed a window, and nothing told a renderer that a surface went
  away.
- *Contexts and sources.* SPEC.md §15.4 already settled the shape:
  contexts share nothing, each has its own sources, and data shared
  between windows is published into each. A source has one reader
  (§14.8). `nextFrame(sources)` is `.immediately` when a source with
  `zuiPending` holds something (`core/src/context.zig`'s `nextFrameWithSources`),
  and every `zui_async` source declares `zuiPending`.
- *`zui_app`.* `Runner` hard-coded `const window: zui.WindowId = .main`
  (`core/zui_app/zui_app.zig:324`) and owned one `Ui`, one `RecordBuilder` and
  one render-thread queue (`:327-345`). `frame` polled, declared, handed
  the frame to the host and the renderer, and waited on that one
  context's `nextFrame` (`:442-477`). `checkApp` accepted only
  `zuiDeclare(app, ui)` (`:592-600`).
- *The Windows host* is `.one` (`hosts/native/windows/host.zig:43`). It holds
  one `hwnd`, one `Inbox`, one `requests`, one `WindowThreadState`, one
  chrome snapshot, one accessibility bridge and one set of service state
  (`:191-220`), and asserts `.main` in every call that takes a window
  (`:122`, `:144`, `:157`, `:395`, `:489-518`). Its waits are already
  host-wide. The window procedure finds the host through `GWLP_USERDATA`
  (`:619`, `:671`), and `WM_DESTROY` ends the window thread (`:695`).
- *The sokol renderer* draws a `.win32` surface through one `native.Context`
  (`renderers/sokol/src/renderer.zig:92`), made in `initForSurface`, which also
  runs `sg.setup` on its device (`:139-146`). sokol_gfx is process-wide, so
  a second window needs a second swapchain on the same device, not a
  second renderer. `zuiSubmit` uses the one context for any `.win32`
  surface (`:184`, `:221`). The scRGB and backdrop-blur targets are made
  again whenever the size changes (`renderers/sokol/src/destination.zig`'s
  `prepare`, `renderers/sokol/src/backdrop_blur.zig`'s `prepare`).

**Plan.** An application opens a window through `zui_app`, between
frames, never in declaration. `zui_app` gives each window a context of
its own, made with `gpa` when the window opens, and the application
declares each window with `zuiDeclare(app, ui, window)`. Sources stay one
per context: the application returns each window's from
`zuiSources(app, window)`. One `zuiWait` covers every window: it waits for
the earliest of the contexts' `nextFrame`, and after it only the windows
that are due run a frame. The renderer stays one, with per-surface state
it attaches when a window opens and detaches before it closes. The
one-window form is untouched. In three slices:
1. **The contract and `zui_app`** (core only): `zui.OpenWindowError`;
   `zuiOpenWindow` and `zuiCloseWindow`, required with `.many` and refused
   with `.one`; `zuiAttachSurface` and `zuiDetachSurface`, declared
   together; `zui_app`'s windowed form, `Windows(App)`, `max_windows`;
   the host suite's many-windows steps; the compile-error cases.
2. **The Windows host opens many windows** (`hosts/native/`): a slot per window,
   `max_windows = 4`, each with its id, `hwnd`, inbox, requests, window
   thread state, chrome snapshot, accessibility bridge and per-window
   service state (the menu bar); a message-only window that anchors the
   window thread and owns the clipboard, so `.main` closes like any
   other; ids never reused; the console's terminate and low memory to
   every window; hosts in the conformance tests off the stack; the
   harness's `postTo`.
3. **Two windows drawn by the sokol renderer** (`renderers/sokol/`, then
   `hosts/native/`): one
   D3D11 device shared by a composition swapchain per window, found by
   `hwnd`, each with its own scRGB and backdrop-blur targets;
   `zuiAttachSurface` and `zuiDetachSurface`; the native hosts'
   `examples/many_windows.zig`, with `--check` and `--measure-idle`.

**When a window is due.** After the wait, each open window is polled and
given to `zuiRecord`. It is declared only when its record has an event,
its viewport, scale, zoom or output format changed, its `nextFrame` asked
again is `.immediately` or an instant that has passed, or it has not had
a frame. When a source of `Ui.Sources` lacks `zuiPending`, a wake cannot
be told apart, so every window is due on every turn.

**Done when.**
- `zui_app`'s tests, with a host of many windows: input reaches only its
  window; a window the user closes is closed and the others go on; the
  wait is the earliest `nextFrame`; a publish makes only its own window
  due; a render thread runs every window's frames, attaches and
  detaches; opening past the host's or `zui_app`'s limit is refused; a
  one-window application runs as before on a host with many.
- The host suite's many-windows steps pass on a host that keeps windows
  apart, and fail on one that reports every event in the first or reuses
  a closed window's id.
- `hosts/native/`'s `zig build test`: the suite passes on the Windows host, now
  `.many`, against hidden windows; `WM_CLOSE` closes one window; a DPI
  change moves one window's scale; Ctrl+C reaches every window; a fifth
  window is refused; the clipboard works after `.main` closes.
- `zig build many-windows -- --check` draws two windows, a click changes
  only its window, and the first draws on after the second closes.
- By a person: on `zig build many-windows`, each window's counter moves
  alone and the shared one in both; closing one leaves the other running;
  two windows idle at 0% CPU; two animating windows both hold the
  display's rate.
- Unchanged: the native hosts' tour, the raylib renderer's `zig build check`, and `01-measure:03-instruction-counts-in-ci`.

**Spec.** §6.1, §6.8, §15.4, §16.2, §16.3, §16.6, §19.4, §19.5.

**Status.** Slice 1, the contract and `zui_app`, is done:
- `zui.OpenWindowError` (`TooManyWindows`, `WindowNotCreated`).
  `checkHost` requires `zuiOpenWindow(options) OpenWindowError!WindowId`
  and `zuiCloseWindow(window)` of a host whose `zui_capabilities.windows`
  is `.many`, and refuses them on `.one`. `checkRenderer` checks
  `zuiAttachSurface(surface) !void` and `zuiDetachSurface(surface)`, and
  that they come together.
- `zui_app`'s windowed form: `zuiDeclare(app, ui, window)`, each hook with
  the window, `zuiSources(app, window)` in place of the `sources` field,
  and an optional `zuiWindowClosed(app, window)`. `Start(App).windows`, a
  `Windows(App)`, opens and closes windows; `open` on a host with one
  window is a compile error unless guarded by `has_many_windows`, and
  opening one during `zuiDeclare` panics. `max_windows` is 8.
- Each window is a heap `Window` holding its context and its record
  builder, made when it opens. The render thread's queue carries frames
  tagged with their context, and attaches and detaches that the UI thread
  waits for, so the renderer is used by one thread at a time and a
  closed window's frames are released before its context is freed.
- The one-window form keeps its fields and its path: a frame every turn.
- `expectHostConforms` opens a second window on a host with many, posts
  to each through the harness's `postTo`, closes it, and opens a third.
- `01-measure:03-instruction-counts-in-ci`, measured by CI's counts job on `ea5ab47`: every scenario's count is
  identical to `6b6ce6f`'s run, its code parent (`daba4a7` changed only
  documents). `core/src/` gains an error set and comptime checks only, and the
  `zui-counts` executable's `.text` (1,171,081 bytes) and `.rodata`
  (145,243 bytes) are byte-identical to `daba4a7`'s.

Slice 2, the Windows host (`bf64f7c`), is done:
- The host is `.many`, with `Host.max_windows = 4` slots. Each slot holds
  the window's `HWND`, inbox, requests, scale, terminate and low-memory
  state, window-thread state, chrome snapshot, accessibility bridge and
  menu bar (`services.MenuBar`). Every call that takes a window finds its
  slot by id; the `.main` asserts are gone, and ids are never reused.
- `zuiOpenWindow` creates a window on the window thread before it
  returns. `zuiCloseWindow` closes any window, `.main` included, once a
  dialog or menu open over it has closed, and the window thread frees the
  slot at `WM_NCDESTROY`.
- A message-only window anchors the window thread. It opens and closes
  the windows, owns the clipboard and the notification icon, and answers
  clipboard reads, URLs and notifications, so every service works after
  `.main` closes. File dialogs and popup menus are owned by the window
  named and answer with its id. The console's terminate and low memory
  reach every window.
- The conformance harness declares `postTo`, so the host suite opens a
  second hidden window, routes input to each and closes it. The host's
  own tests close one window alone, change one window's DPI, deliver
  Ctrl+C to every window, refuse a fifth window and give a new id after
  one closes, and use the clipboard and a dialog over a second window
  after `.main` has closed.
- `zig build test` passes in Debug and ReleaseSafe, `zig build
  conformance` passed 12 runs of 12 with fresh seeds, `services` and
  `title-bar -- --check` pass, and the tour idles at 0.0 ms of CPU over
  10 s.

Slice 3, the sokol renderer drawing many windows (`9ad703d`) and the
example (`c19a504`), is done:
- `zuiAttachSurface` makes a composition swapchain for each `.win32`
  window after the first, on the first one's Direct3D 11 device, and
  `zuiDetachSurface` frees it. `composition.c` takes the device to share
  and holds a reference to it, and the renderer keeps one of its own from
  `initForSurface` to `deinit`, so the first window can close while the
  others draw on.
- Each attached window has its own scRGB offscreen and backdrop-blur
  targets, swapped in for its frames, so windows of two sizes do not
  remake them every frame. With `-Dgl=true`, and on Wayland until `10-reach:01-linux-host`,
  attaching returns `error.UnsupportedSurface`.
- `zig build many-windows` runs one `zui_app` application in two windows.
  Each window declares its own UI and counts its own clicks, and a count
  shared by both is published into each window's `Latest(u32)`. Any
  window opens another or closes itself.
- `-- --check` opens a hidden second window and clicks its buttons
  through the host. It exits 0 only when the second window counted its
  click, both show the shared count, the first counted none, and the
  first drew on after the second closed.
- **The present-wait risk, measured** on this machine's 144 Hz monitor
  with `-- --measure-animation`: one window animating alone draws 144.0
  frames a second, and two at once draw 143.3 and 143.0, in two runs of
  two. Presenting each window with a sync interval of 1 does not halve
  the rate, so nothing was changed for it.
- `-- --measure-idle` with two windows open: 0.0 ms of CPU over 10 s,
  with no frames.

Measured across the item:
- `01-measure:03-instruction-counts-in-ci`: unchanged. CI's counts on `ea5ab47` are identical to `6b6ce6f`'s
  scenario by scenario, and slices 2 and 3 do not touch zui.
- Idle: 0.0 ms of CPU over 10 s for two windows, and for the sokol
  renderer's tour, which runs on the host unchanged.
- Animation: 144 Hz for one window, and 143 Hz for each of two.
- The native hosts' 77 tests pass in Debug and ReleaseSafe. `zig build
  conformance` passed 12 runs of 12 with fresh seeds.
- `services`, `title-bar`, `theme`, `remote` and `many-windows` pass
  `--check`.

What remains, and where it went:
- **Seen by a person, owed:** `zig build many-windows` on the desktop.
  Open a third window from either. Click in each and see only its own
  count move, while the shared count moves in all. Drag each window and
  resize it while the other draws. Move one to a monitor at another
  scale. Close the first window and see the others run on, then close
  the last and see the process end.
- **`10-reach:01-linux-host`, and `14-macos:01-macos-host` once macOS is taken up:** Linux and macOS implement the
  same contract, and their hosts stay `.one` until then. The sokol renderer's EGL
  path would attach a `wl_egl_window` and `EGLSurface` per window on one
  `EGLContext`.
- **`zui_wire`:** a connection carries one window. Many windows over the
  wire would take a connection per window, and is not queued.
- **Docking and tear-off panels** (*Later*) can now build on it.

## 10-reach:06-platform-owned-loop — Hosts whose platform owns the loop

**Grounding.**
- `zui_app.run` owned the loop: `while (try runner.frame()) {}`, each
  turn polling the host, declaring and submitting, then blocking in the
  host's `zuiWait`, so nothing could turn it without blocking. The host
  contract required `zuiWait` (`core/src/contracts.zig:144`).
- The web host's worker forked the frame logic to get a turn that does
  not block: `TourSession.frame` (`hosts/web/src/tour_session.zig:182`)
  begins and ends the tour's frames itself, `frameReason` (`:262`)
  repeats `zui_app`'s judgement of whether a frame is due, and `nextWake`
  (`:249`) folds the stepped `Io`'s next wake into `nextFrame`.
- `zui_raylib.Host` began raylib's drawing in `zuiPoll` and presented it
  in `zuiWait`, so it could not be polled without being waited on.
- The browser's main thread, macOS, iOS and Android own their loops and
  call the application back; Android and a lost GPU device also take the
  surface away and give it back. `zuiAttachSurface` and
  `zuiDetachSurface` (`core/src/contracts.zig:23`) already let a renderer
  drop and take a window's surface while its context lives on (`10-reach:05-many-windows`).

**Plan.** One non-blocking step is the unit of `zui_app`'s frame logic,
and three loops turn it (open decision 2, settled: the owner's choice of
option D). A host is two halves: the window half every host gives
(`zui_surfaces`, `zuiPoll` as a drain that never blocks or presents,
`zuiWaker`, `zuiSurface`, `zuiApply`), and at most one call of the loop
half:
- `zuiWait`: zui pulls the loop, `run` stepping and waiting in turn;
- `zuiRun(self, io, window, driver)`: the platform pushes it, and the
  host calls a `zui.Driver` from its callbacks (`start(io)`, `step`,
  `suspendSurfaces`, `resumeSurfaces`, `stop`), scheduling each turn as
  the `NextFrame` the step returns says; `run` returns as `zuiRun` does,
  `noreturn` included;
- neither: only the application's own loop steps a `zui_app.Session`.

In slices, each a commit with every check green:
1. **The step.** `Runner.frame` splits into `step`, which never blocks and
   judges which windows are due on the one-window path as on the many,
   and `wait`. `NextFrame.sooner` folds two schedules; `Context.hasFreeFrame`
   says whether `beginFrame` would wait. raylib's renderer presents in
   `zuiSubmit`, and its host's `zuiPoll` only drains.
2. **The split contract.** `zuiWait` becomes the optional loop half beside
   `zuiRun` and `zui.Driver`; `Runner` becomes `Session`, with `Loop`,
   `runWith` and a compile error for each mistake; SPEC.md, README.md,
   ARCHITECTURE.md and the feature tour describe it.
3. **Surface loss.** `Session.suspendSurfaces` and `resumeSurfaces`
   detach and re-attach every window's surface through the renderer.
4. **The browser's worker on `Session`.** A stepped host over the page's
   records, `zui_wire`'s renderer and the tour's own `App`, in place of
   `TourSession`'s frames; the owner of the stepped `Io` folds its next
   wake with `sooner`.
5. **Conformance.** `zui_testing` suites for a host that runs its loop
   and one that is stepped, beside the pull suite.

**Done when:**
- `zui_app`'s tests drive a fake host that runs its loop from a scripted
  list of callbacks, on a UI-thread and a render-thread renderer: input
  reaches its window, a step declares only what is due, a lost surface
  is let go and given back with every context and the application's
  state kept, and `run`'s type is `noreturn` for a `zuiRun` that is;
- an application's own loop steps a `Session` on a host with no loop
  half, and declares only the frames that are due;
- every new rule is a compile error with its message pinned;
- the web host's worker runs the tour through `Session`: `test-demo`,
  `test-draw`, `test-input` and `test-site` pass, the worker and the
  native `tour-frames` writing the same bytes;
- every native host's and renderer's tour cycle still prints
  `diagnostics ok: true`, and `01-measure:03-instruction-counts-in-ci` counts are unchanged.

**Spec.** §6.1, §6.3, §16.2, §16.3, §19.4, §19.5.

**Status.** Slice 1 is done: `Runner.step` and `wait`, one judgement of
whether a frame is due for one window and many, `NextFrame.sooner`,
`Context.hasFreeFrame`, and raylib presenting from its renderer (raylib
built with `SUPPORT_CUSTOM_FRAME_CONTROL`, its host polling input once a
turn in `zuiWait`). The turn after `zuiWait` stays due for an
application with one window, measured: without that rule an idle tour
declared 10 frames in 10 s on the Wayland host against 11 (24.8 against
27.9 ms of CPU, within noise), and 10 against 10 on raylib; the busy
cycles were unchanged; nine of `zui_app`'s tests and the showcase's,
whose fake hosts return from every wait with an empty record, declared
fewer frames. Too little to gain for a frame a host's wait may ask for
without a record that shows it. Slices 2 and 3 landed together, since
`zui.Driver` carries the surface calls: `zuiWait` is the optional loop
half beside `zuiRun`, `checkHost` rejecting both and any other `zuiRun`;
`zui.Driver`; `Session(App)` in place of `Runner`, every caller renamed,
with `Loop`, `loopOf`, `runWith`, a `run` whose type is `noreturn` when
`zuiRun`'s is, and a step that leaves input with the host while the
render thread holds every frame (on a host that is not waited on); and
`suspendSurfaces` and `resumeSurfaces` over the renderer's attach and
detach. Six compile errors are pinned. A fake pushed host drives an
application from a scripted list of callbacks through a lost surface and
its return, on a UI-thread and a render-thread renderer and on an `Io`
of its own, and an application's own loop steps a `Session` on a stepped
host. The sokol renderer attaches only `.win32` windows, so a lost
surface of another kind cannot come back to it yet (ARCHITECTURE.md §7).
Slice 4 is done: the worker steps a `Session` of `zui_tour.App`, on a
stepped host over the page's records (`PageHost`) and a renderer that
declares what `zui_webgl.Drawing` declares and writes each frame as wire
bytes (`PageRenderer`), so `TourSession` keeps only the page's side:
records in, bytes out, and the `Io`'s next wake folded in with `sooner`.
Its own judgement of which frames are due, its `.every_call` mode and
the page's `onlyWhenDue` are gone; every step judges. The tour times its
frames on a `zui_tour.Stopwatch` (the `Io`, a page's clock or a steady
one), and takes its submit time from a renderer that reports one
(`submitMicroseconds`), as the page's draw time is. `test-demo` in Debug
and ReleaseSafe, `test-draw`, `test-input` and `test-site` (also in
ReleaseSmall) pass; the worker and the native `tour-frames` still write
the same bytes, a stream that changed once: the tour now records each
frame's timings where `zui_app` takes them. Slice 5 is done:
`zui_testing.expectPushedHostConforms` hands a host's `zuiRun` a
scripted `zui.Driver` and checks that it starts it once before any step,
schedules each step as the one before asked (`.immediately`, `.at` and
`.on_event` with a wake from another thread), never blocks in a poll,
reports a surface its platform takes away and gives back, stops the
driver and steps no more after the end, quitting a platform that stopped
stepping; `expectSteppedHostConforms` checks that a stepped host's poll
never blocks and that posted events arrive in order. Each passes a fake
host that keeps its rules and fails one that breaks each, ThreadSanitizer
included. `10-reach:06-platform-owned-loop` is done; counts were unchanged by every slice.
