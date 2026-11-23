# The native hosts

`zui_host` holds the native hosts: each owns its OS's windows and event
loop, and implements zui's host contract, so any renderer that draws
into the same kind of surface can draw for it. One directory per OS,
chosen by the target: Windows, and Linux on Wayland or X11. On Linux it
needs `libwayland-dev libxkbcommon-dev libegl-dev` and
`libx11-dev libx11-xcb-dev libxcb1-dev libxcb-xkb-dev libxcb-cursor-dev libxkbcommon-x11-dev`.

```zig
// build.zig, with `zui` the dependency from the main README
const zui_host = zui.builder.dependency("zui_host", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_host", zui_host.module("zui_host"));
```

```zig
const zui_host = @import("zui_host");
const Host = zui_host.Host; // zui_host.windows.Host on Windows, zui_host.linux.Host on Linux
```

With `zui_app`, name it as the application's host:

```zig
const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = MyRenderer; // one that draws into .win32, or .wayland and .x11 on Linux
    // ...
};
```

The host must not move between `init` and `deinit`, since its window
thread (on Windows) and the compositor's listeners (on Linux) hold a
pointer to it, as does the Linux host's signal handler. `forced_scale`,
`system_material_unavailable`, and on Linux `forced_backend`,
`bus_addresses` and `forced_blur_offers`, may be set before `init`,
which keeps them; `zui_app` starts each field at its default.
`service_fake` may be set before `init` too, or after it with
`Host.fakeServices(fake)`, before the first service call.

The examples below are each drawn by the sokol renderer.

## Development

Run from `hosts/native/`; the examples fetch sokol-zig and stb for the
sokol renderer that draws them, and on Linux the build needs
`libwayland-dev libxkbcommon-dev libegl-dev`, X11's
`libx11-dev libx11-xcb-dev libxcb1-dev libxcb-xkb-dev libxcb-cursor-dev libxkbcommon-x11-dev`,
and for the examples sokol's
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev`:

| Command | What it does |
|---|---|
| `zig build test` | the unit tests, and zui's host suite and the host's own tests against a window the user never sees (on Linux, on Wayland and on X11, each skipped without its display server) |
| `zig build conformance` | only the host suite and the host's own tests |
| `zig build check` | compile the host, its tests and the examples; add `-Dtarget=x86_64-windows` or `aarch64-windows` to cross-compile |
| `zig build tour` | run the tour, drawn by the sokol renderer (Windows, Direct3D 11; Linux, OpenGL through EGL on Wayland or X11); `-- --frames 300 --cycle 30` visits every screen and quits, `-- --measure-idle` reports the CPU used over 10 idle seconds |
| `zig build material` | show the system material, or its fallback; `-- --check` reports a hidden window's material and quits, `-- --frames 120` quits after 120 frames |
| `zig build hdr` | show HDR white beside SDR white (Windows) |
| `zig build remote` | run the tour in another process and draw it here, over `zui_wire` (Windows) |
| `zig build theme` | a window styled by a theme file, restyled when it changes; `-- --check` scripts it |
| `zig build accessible` | `zui_widgets` controls for Narrator and Accessibility Insights (Windows) |
| `zig build services` | every host service from buttons, each answer shown; `-- --check` runs it against the fake |
| `zig build title-bar` | a title bar the application draws, which the OS still drags, maximizes and resizes (Windows also snaps it); `-- --check` hit-tests it hidden |
| `zig build many-windows` | one application in two windows, each with its own UI; `-- --check` clicks and closes them, hidden on Windows and shown on Linux |

The tests and examples need a Wayland compositor or an X server on Linux
(CI runs a headless Weston and Xvfb), and an example without `--check`,
`--frames` or `--measure-idle` keeps its window open until it is closed.
The tests that play the desktop portal and the notification daemon need
a session bus of their own, named by `ZUI_HOST_TEST_SESSION_BUS` (see
*The Linux host*). Its links on Linux print
`warning(link): unexpected LLD stderr` and still succeed.

## The Windows host

`zui_host.Host` opens Win32 windows and gives renderers each one's
`win32` surface (the `HWND`). Its message loop runs on a thread of its
own, so a window keeps drawing while the user drags its edges or moves
it. It:

- opens many windows (`zui_capabilities.windows = .many`): `init` opens
  `.main`, and `zuiOpenWindow(options)` up to `Host.max_windows - 1`
  more, each with an id never given twice, its own events, scale,
  requests, chrome regions, accessibility bridge and menu bar, polled by
  its id; `zuiCloseWindow(window)` closes any of them, `.main` included.
  One wait covers them all. A message-only window anchors the window
  thread and owns the clipboard and the notification icon, so every
  service keeps working whichever windows are open, and the console's
  terminate and low memory reach every window;
- reports per-monitor scale (per-monitor DPI awareness v2), keeping the
  window's size in layout units when it moves to a monitor of another
  DPI;
- reports the mouse, the wheel, keys with their modifiers and scan
  codes, and typed text as UTF-8, surrogate pairs joined and consecutive
  characters in one event;
- reports the environment: dark mode (also darkening the title bar),
  high contrast, animations turned off (`reduced_motion`), power
  (plugged, on battery, battery saver), whether the window has focus,
  and the accent color, `DwmGetColorizationColor`'s, read again on
  `WM_DWMCOLORIZATIONCOLORCHANGED`;
- reports lifecycle events: Ctrl+C, Ctrl+Break, the console closing,
  logging off, shutting down and the session ending are
  `.terminate_requested`, after which the next poll reports the window
  closed; the system sleeping and waking are `.suspend` and `.resume`;
  low memory is `.low_memory`;
- reports files dropped onto the window, with their paths and where;
- sets the cursor a frame asks for, and places the IME's composition and
  candidate windows at the caret of a frame's text-input request,
  turning the IME off while no editable asks for one;
- waits as `nextFrame` says: at once, until an instant on a
  high-resolution timer, or until input or a wake, which is sticky and
  works from any thread;
- offers zui's host services: the clipboard as text,
  `Host.zuiClipboard.write(host, text)` and `read(host, request, sink)`;
  `Host.zuiOpenUrl.open(host, url)`, which hands a URL to the system's
  handler for its scheme and refuses paths and `file:` URLs;
  `Host.zuiNotifications.show(host, request, notification, sink)`, a
  balloon of the window's notification-area icon, which Windows 10 and
  11 show as a toast, answering `.notification_activated` when clicked
  and `.notification_dismissed` when it times out, is closed or is
  replaced by the next; and
  `Host.zuiFileDialogs.show(host, window, request, dialog, sink)`, the
  shell's open, save and folder dialogs, owned by the window and one at
  a time, answering `.files_chosen` with the paths chosen or
  `.canceled`; and `Host.zuiMenus`, Windows' own menus:
  `popup(host, window, request, items, position, sink)`, a context menu
  at a position in layout units, one at a time with a file dialog,
  answering the item chosen or `.canceled`, and
  `setBar(host, window, request, items, sink)`, which replaces the
  window's menu bar, or removes it given no items, and answers each item
  chosen from it, or is `error.Unavailable` under a custom title bar,
  which would hide it. Labels show as written, with shortcuts after them
  (`Ctrl+Shift+S`). Each call returns at once; the window thread does
  the work and publishes every answer, a `zui.ServiceReply`, into a
  source of the application's, so answers never come from two threads;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: a thread per
  directory waits on `ReadDirectoryChangesW` and publishes each change,
  a `zui.FileChange`, into a source of the application's, waking the
  window for the first since the last frame;
- shows the system's material behind the window when it asks for one
  (`WindowOptions.material`: `.window` is Mica, `.transient` Acrylic),
  and reports whether it shows as `Environment.system_material`: false
  on Windows 10 and Windows 11 before 22H2, with transparency effects
  turned off, or for `.none`;
- opens the surface in `.scrgb_fp16` while the window's monitor runs in
  HDR, if the window was opened with it (`zui_app` passes it when the
  renderer declares it too), and in `.sdr` otherwise, and reports
  `Environment.hdr_headroom`: the monitor's peak over the SDR white that
  its SDR content brightness slider sets, or 1 in `.sdr`. Moving to
  another monitor and turning HDR on or off change both;
- bridges `Frame.semantics()` to UI Automation, through `zuiSemantics`,
  when the window was opened with room for it
  (`WindowOptions.semantics`, which `zui_app` sizes from `Config.limits`
  when `features.semantics` is on); see *Accessibility* below;
- leaves the title bar to the application for a window opened with
  `WindowOptions.title_bar = .custom`, reporting
  `Environment.custom_title_bar` and `.window_maximized`, and answers
  Windows from the frame's chrome regions, which `zui_app` hands to
  `zuiChromeRegions`; see *A custom title bar* below.

It passes zui's host suite (`zui_testing.expectHostConforms`) against
hidden windows, two of them for its many-windows steps, whose harness
sends each window the messages Windows would.

## The Linux host

On Linux, `zui_host.Host` is `zui_host.linux.Host`, which chooses its
display server at `init`: Wayland where a compositor answers, and X11
otherwise, where `DISPLAY` names a server. `ZUI_HOST_BACKEND=x11` or
`ZUI_HOST_BACKEND=wayland` forces one, and `Host.forced_backend` set
before `init` wins over the variable; `host.backendInUse()` says which
it chose. Each call is one switch on it. The Wayland host and the X11
host are also `zui_host.linux.WaylandHost` and `zui_host.linux.X11Host`.

```sh
ZUI_HOST_BACKEND=x11 zig build tour    # the tour on X11, under Xwayland too
```

### On Wayland

`zui_host.linux.WaylandHost` opens Wayland windows through
libwayland-client and xdg-shell, and gives renderers each one's
`wayland` surface (the `wl_display` and its `wl_surface`). It reads and
dispatches the compositor's events on the thread that polls it, since a
Wayland client has no modal loop to escape. So far it:

- opens many windows (`zui_capabilities.windows = .many`): `init` opens
  `.main`, and `zuiOpenWindow(options)` up to `Host.max_windows - 1`
  more, returning once the compositor has configured it, each with an id
  never given twice, its own surface, events, scale, requests and chrome
  regions, polled by its id; `zuiCloseWindow(window)` destroys any of
  them, `.main` included. The pointer's events reach the window whose
  surface it entered, keys the one with the keyboard's focus, a drop the
  one the drag entered and an input method's text the one with the
  text-input focus. The seat, the clipboard, the watches and the
  services belong to the host, so they keep working whichever windows
  are open, and a terminate request, the system sleeping and the
  desktop's settings reach every window. One wait covers them all;
- reports the scale the compositor prefers: fractional
  (`wp_fractional_scale_v1`, in 120ths) where it also offers
  `wp_viewporter`, the buffer drawn at physical pixels and the viewport
  giving the surface its size; otherwise the integer buffer scale
  (`wl_surface.preferred_buffer_scale`). It keeps the window's size in
  layout units when the scale changes, and takes the size the compositor
  configures, such as a tiling compositor's tile;
- reports the mouse, the wheel (40 layout units a notch, a touchpad's
  distance as it is), keys through the compositor's keymap with their
  modifiers and evdev codes, typed text, and whether the window has
  focus; typed text goes through the locale's compose sequences
  (xkbcommon's, from `LC_ALL`, `LC_CTYPE` or `LANG`), so a dead acute
  and `e` type "é" and `Multi_key` `o` `c` types "©", a key inside a
  sequence typing nothing, as on X11;
- repeats a held key at the rate and after the delay the compositor
  gives (`wl_keyboard.repeat_info`), each repeat a `key_down` with
  `repeat` set and its text typed again; a modifier pressed meanwhile
  leaves it repeating;
- reports the environment the desktop gives over D-Bus: the theme, high
  contrast, reduced motion and the accent color from the XDG desktop
  portal's settings (`org.freedesktop.appearance`; an `accent-color` out
  of 0 to 1 is no accent, `null`), on Wayland and X11 alike, and power
  from UPower (on battery) and power-profiles-daemon (`power-saver` is
  the saver), each change as it is signalled. Without a session bus, a
  portal or either daemon, as in a container or under a bare compositor,
  those settings stay at zui's defaults, and `host.environmentSources()`
  says which answered;
- reports lifecycle events: SIGINT, SIGTERM and SIGHUP are
  `.terminate_requested`, after which the next poll reports the window
  closed, unless the application handles or ignores the signal itself (a
  second Ctrl+C ends the process); the system sleeping and waking
  (logind's `PrepareForSleep`) are `.suspend` and `.resume`;
- reports files dropped onto the window (`wl_data_device`, an offer of
  `text/uri-list` accepted for copying), each `file://` URI on this
  machine percent-decoded to its path, at the drop's position;
- closes when its close button or the compositor asks;
- shows what is behind a window opened with a `WindowOptions.material`
  other than `.none`, blurred, where the compositor blurs through
  `ext_background_effect_v1` (with its `blur` capability) or KWin's
  `org_kde_kwin_blur`, preferring the first: the window's `.wayland`
  surface is then `transparent`, so the renderer keeps alpha, and a blur
  region covers the whole window, following its size. `.window` and
  `.transient` blur alike, since neither protocol has a strength. It
  reports `Environment.system_material` true unless
  `reduced_transparency` is on, and again whenever that, or the
  background effect's capabilities, change. Under a compositor that
  blurs through neither, or with `system_material_unavailable` set, the
  window stays opaque and reports false. No portal setting carries
  reduced transparency yet, so it stays false;
- leaves the title bar to the application for a window opened with
  `WindowOptions.title_bar = .custom`, asking the compositor for
  client-side decorations (xdg-decoration), and reports
  `Environment.custom_title_bar` and `.window_maximized`; presses on the
  frame's chrome regions go to the compositor; see *A custom title bar*
  below;
- sets the cursor a frame asks for, where the compositor offers
  `wp_cursor_shape_v1`;
- enables the input method where the compositor offers
  `zwp_text_input_v3`, while the window has the seat's text-input focus
  and a frame's text-input request names a caret, with its cursor
  rectangle around the caret in surface coordinates, and disables it
  while no editable asks; it sends nothing for a frame that asks for
  what the last one did. Text the input method commits is typed as
  `text` when it is done, beside text typed from keys. Composing text
  (the preedit) is kept but not reported yet, and no surrounding text or
  content type is sent;
- offers zui's host services over the session bus, the Windows host's
  shapes:
  `Host.zuiNotifications.show(host, request, notification, sink)`, a
  notification from the desktop's notification daemon
  (`org.freedesktop.Notifications`), one at a time and replaced by the
  next, answering `.notification_activated` when clicked and
  `.notification_dismissed` when it expires, is closed or is replaced;
  `Host.zuiFileDialogs.show(host, window, request, dialog, sink)`, the
  XDG desktop portal's open, save and folder dialogs (`FileChooser`),
  one at a time, answering `.files_chosen` with the paths chosen or
  `.canceled`; and `Host.zuiOpenUrl.open(host, url)`, which hands a URL
  to the portal's `OpenURI` and refuses paths and `file:` URLs. Each
  call only sends; the poll and the wait read the bus and publish every
  answer, a `zui.ServiceReply`, into a source of the application's.
  Without a session bus each call is `error.Unavailable`, and without a
  daemon or a portal the answer is `.failed = .unavailable`. There are
  no menus, which Wayland does not have;
- waits as `nextFrame` says: at once, until an instant, or until input,
  a key's repeat, a signal or a wake, which is sticky and works from any
  thread (an `eventfd`); the compositor's and the buses' other messages,
  such as a buffer released after each frame, do not end a wait;
- offers the clipboard as text, `Host.zuiClipboard.write(host, text)`
  and `read(host, request, sink)`, through the seat's selection: `write`
  offers up to 64 KiB of UTF-8 as `text/plain;charset=utf-8`,
  `UTF8_STRING` and `text/plain`, and `read` publishes a
  `zui.ServiceReply` once the selection's owner has written it, up to 64
  KiB with the rest counted as left out, `""` when the clipboard holds
  no text, or `.failed` after 2 s. Both directions go through pipes the
  host's wait reads and writes, so the host can paste its own text, and
  a reader that closes early does not raise SIGPIPE. The compositor
  names the selection only to the window with keyboard focus; until it
  names another, a read answers the last text written;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: one inotify
  descriptor, read in the host's wait, with a watch for each directory,
  added as subdirectories are created or moved in (up to 256 in all;
  past them, or past a path of 255 bytes, a `.rescan`), publishing each
  change, a `zui.FileChange`, into a source of the application's.

It links libwayland-client and libxkbcommon, and speaks D-Bus itself: a
client of its own, in `hosts/native/linux/dbus.zig`, reads the buses'
sockets into fixed buffers, beside the display in the same wait, so it
needs no libdbus and allocates nothing. `init` waits up to 250 ms for
the desktop's current settings, so the first frame has them. A window
opened with `visible = false` is a surface with no role, which the
compositor never shows. The services have a connection to the session
bus of their own, which reads nothing while no call waits for an answer.
Low memory, reduced transparency from the desktop, the input method's
composing text are still to come.

It passes zui's host suite (`zui_testing.expectHostConforms`) against
windows the compositor never shows, two of them for its many-windows
steps, whose harness delivers what a compositor would to the host's own
handlers, entering the window each event is posted to first; without a
compositor to connect to, the suite and the host's own tests are skipped
with a message. The services are answered there through the host's fake
(`Host.fakeServices`), so nothing shows. A test with
`ZUI_HOST_TEST_SHOWN_WINDOW` set shows a window for a moment, so the
compositor gives it focus, and reads text written to the clipboard back
through the compositor's own selection; without it, the clipboard's
pipes are tested with the host at both ends. The tests read no bus but
the ones named by `ZUI_HOST_TEST_SESSION_BUS`: set to a bus's address,
tests play the portal and the notification daemon on it, and check that
the settings, a notification's arguments and signals, a file chooser's
options and its answer (paths or a cancel), and `OpenURI` reach the host
or the played service, that another sender's signals do not, and that a
notification with no daemon fails without blocking.

```sh
dbus-daemon --session --nofork --address=unix:abstract=/zui-host-test --print-address
ZUI_HOST_TEST_SESSION_BUS=unix:abstract=/zui-host-test zig build test
```

### On X11

`zui_host.linux.X11Host` opens X11 windows through Xlib's display, which
EGL's X11 platform takes, and speaks the protocol through the xcb
connection beneath it, which owns its event queue. It gives renderers
each window's `x11` surface (the Xlib `Display` and the window's id),
and reads and dispatches the server's events on the thread that polls
it. So far it:

- opens many windows (`zui_capabilities.windows = .many`): `init` opens
  `.main`, and `zuiOpenWindow(options)` up to `Host.max_windows - 1`
  more, each with an id never given twice, its own X window, events,
  requests, cursor, chrome regions and drag, polled by its id;
  `zuiCloseWindow(window)` destroys any of them, `.main` included, and
  `WM_DELETE_WINDOW` closes only the window it names. Each X event names
  its window: the pointer's reach the window it entered or pressed in,
  keys the one with the keyboard's focus, which the input method
  follows, and a drop the one it was dropped on. The clipboard is owned
  by an unmapped input-only window of the host's own, so it keeps
  working whichever windows are open, and a terminate request, the
  system sleeping and the desktop's settings reach every window. The
  scale is the screen's, so every window has the same;
- opens each window at the requested size in layout units, titled
  through `_NET_WM_NAME` and `WM_NAME`, of class `zui`, with min and max
  sizes for one that is not resizable, and unmapped for
  `visible = false`, so the server never shows it; its size follows
  `ConfigureNotify`;
- reports the scale `Xft.dpi` gives in the resource manager's string (96
  is 1, 144 is 1.5), read at `init` and again whenever the root window's
  `RESOURCE_MANAGER` changes; without it the scale is 1;
- reports the mouse (buttons 1 to 3 as zui's primary, middle and
  secondary buttons; back and forward have no zui button), the wheel (a
  notch of buttons 4 to 7 is 40 layout units), keys through the server's
  XKB keymap (`xkbcommon-x11`) with the modifiers XKB's state events
  report, their evdev codes (the X key code less 8) and typed text
  through the locale's compose sequences, as on Wayland, the pointer
  leaving, and whether the window has focus (a grab's moving the
  keyboard aside is not a change of focus);
- reports a held key's repeats as the server makes them, each a
  `key_down` with `repeat` set that types again: it asks XKB for
  detectable auto-repeat, so a repeat is a press alone;
- closes a window when the window manager sends it `WM_DELETE_WINDOW`;
- sets the cursor a frame asks for from the cursor theme (`xcb-cursor`),
  by its CSS name or the X cursor font's;
- offers the clipboard as text through the `CLIPBOARD` selection:
  `Host.zuiClipboard.write(host, text)` owns it with up to 64 KiB of
  UTF-8 and answers other clients' requests for `TARGETS`,
  `UTF8_STRING`, `text/plain;charset=utf-8`, `TEXT` and `STRING` (in
  Latin-1, each character past it a `?`), refusing any other target, and
  drops the text when another client takes the selection;
  `read(host, request, sink)` answers the host's own text at once, and
  otherwise converts the selection to `UTF8_STRING` into a property of
  the host's window, publishing a `zui.ServiceReply` from the host's
  wait once the owner has written it, whole or in `INCR`'s chunks: up to
  64 KiB, cut at a character with the rest counted as left out, `""`
  when no client owns it or its owner refuses, and `.failed` when the
  owner takes longer than 2 s for it or a chunk of it. The `PRIMARY`
  selection is not read or written;
- reports files dropped onto the window through XDND, version 5
  (`XdndAware`): a drag that offers `text/uri-list`, among its first
  three types or on its `XdndTypeList`, is accepted for copying in each
  `XdndStatus`, and its drop's list is read from `XdndSelection` as the
  clipboard's is, up to 32 KiB of whole lines, then finished with
  `XdndFinished`; each `file://` URI on this machine is percent-decoded
  to its path and reported at the drop's position. Any other drag is
  refused, and its drop finished unaccepted;
- leaves the title bar to the application for a window opened with
  `.title_bar = .custom`, asking the window manager for no decorations
  through `_MOTIF_WM_HINTS`, where the window manager moves windows
  through `_NET_WM_MOVERESIZE` and draws no frame of its own; presses on
  the frame's chrome regions go to the window manager, and the host
  works the caption buttons; see *A custom title bar* below;
- shows what is behind a window opened with a `WindowOptions.material`
  other than `.none`, blurred, where the root window announces
  `_KDE_NET_WM_BLUR_BEHIND_REGION` (as KWin's blur effect does, or
  `_NET_SUPPORTED` lists it) and a compositing manager owns
  `_NET_WM_CM_S<screen>`: the window is made with the screen's 32-bit
  TrueColor visual and a colormap of its own, its `.x11` surface is
  `transparent`, and `_KDE_NET_WM_BLUR_BEHIND_REGION` covers the whole
  window, written again only when its size changes. It reports
  `Environment.system_material` as the Wayland host does, and again when
  the root window's announcement changes. Elsewhere, or with
  `system_material_unavailable`, the window stays on the root's visual,
  opaque, and reports false;
- types through the session's input method over IBus's D-Bus protocol,
  which ibus-daemon and fcitx5 both serve: at `init`, within its 250 ms,
  it connects to the session bus and asks the portal
  `org.freedesktop.portal.IBus` for an input context (without starting
  an input method the session does not run), setting its capabilities to
  preedit text and focus once it answers. While a frame's
  `HostRequests.text_input` names a caret and the window has focus, the
  context is focused (`FocusIn`) with the caret's rectangle in root
  coordinates (`SetCursorLocation`), and otherwise unfocused
  (`FocusOut`), each sent only when it changes. While it is focused,
  each press and release goes to `ProcessKeyEvent` with its keysym,
  evdev code and modifier mask, and waits, in order behind the keys
  before it, for the answer: a key the input method consumes reaches the
  record as a key and types nothing, and one it does not types through
  the keymap and compose. A key unanswered after 100 ms (fcitx5 here
  answers in under 2 ms) is typed with every key behind it, and the
  input method is passed over until it answers again. `CommitText` is
  typed once, behind the keys held before it, `ForwardKeyEvent` types
  the key it names, and the preedit (`UpdatePreeditText`) is kept but
  not yet reported. An input method that leaves the bus types the keys
  it held at once, and one that takes its place is asked for a context
  again. Up to 64 keys and 4 KiB of committed text are held; what does
  not fit is counted in the record's dropped events and text bytes;
- reports the desktop's environment, the lifecycle events and the
  services as the Wayland host does, through the same D-Bus clients, and
  watches directories through the same inotify watches;
- waits as `nextFrame` says, on the connection, the desktop's buses, the
  watches, the input method and the wake.

XIM is not used: it needs Xlib to own the event queue, which the host
gives to xcb. It links libX11, libX11-xcb, libxcb, libxcb-xkb,
libxcb-cursor and libxkbcommon-x11.

It passes zui's host suite against a window that is never mapped, whose
harness delivers what the server would to the host's own handlers, and
its own tests drive the keys, a repeat, the wheel, a resize the server
makes, `Xft.dpi`, focus, the close button and the cursor, and, with a
second window, the close button closing it alone, the pointer and keys
reaching the window each names, a fifth window refused and a new id
after a close, the clipboard and a file dialog after `.main` closed, a
terminate request in every window, and each window's chrome regions
apart; its many-windows steps run in the host suite. Another client on a
connection of its own reads the window's clipboard as each target, owns
the clipboard and answers the window's reads whole, refused, never, and
in `INCR`'s chunks within and past the bound, and drags and drops onto
the window, with and without a URI list. With
`ZUI_HOST_TEST_SESSION_BUS` set, a test plays the input method on that
bus under the portal's name and checks the context's creation, focus and
the caret following the frames, a consumed key typing nothing and an
unconsumed one typing, committed text typed once, keys unanswered past
the bound typed in order, and an input method that leaves the bus, or
none at all, leaving typing to the keymap; with
`ZUI_HOST_TEST_SHOWN_WINDOW` set, a shown window types through the
session's own input method. Without an X server to connect to, they are
skipped with a message. Under Wayland they run against Xwayland when
`DISPLAY` is set, and CI runs them under Xvfb.

## Accessibility

A window opened with `WindowOptions.semantics` answers UI Automation's
`WM_GETOBJECT` with a fragment root, whose elements are the nodes of the
last `Frame.semantics()` the host was handed: each with its label as its
name, its role as a control type, its id in hex as its AutomationId, its
bounds in screen pixels and its place in the tree, and a heading with
its level. Each offers the pattern that stands for what it does: Toggle
on a checkbox, ExpandCollapse on a dropdown or disclosure, RangeValue on
a slider, Value on a text field or dropdown, SelectionItem on an option
or radio, Selection on a list, Scroll on a scroll container, Window on a
dialog, and Invoke on what is left that clicks.

A client's requests arrive in the next record as the actions that answer
them: Invoke, Toggle, Expand, Collapse and Select as `invoke`, answered
as a click; a range's SetValue as `adjust` by whole steps; a scroll by a
notch (a wheel step), a page or to a percentage as `scroll`;
ShowContextMenu as `show_menu`; a dialog's Close as `dismiss`; and
SetFocus as `focus`, answered as Tab would be. A text field's text is
read through its Value pattern and typed from the keyboard, since zui
has no action that replaces it. Focus, structure and property changes
(name, value, toggle, expand, selection, enabled, scroll position) are
raised only while a client listens, from the window thread.

The host copies each list into one of two snapshots it allocates in
`init`, so a list past that room is cut from the end and reported, and
nothing is allocated after `init`. Without room, the window is left to
Windows' default accessibility.

`zig build accessible` shows a heading, a button, a checkbox, a slider,
a text field, a dropdown and a scrolling log, from `zui_widgets` and
zui, for trying with Narrator or Accessibility Insights;
`-- --frames 30` draws 30 frames and quits. The tour declares its
semantics too, so the tour on this host can be read the same way. The
host's tests read their windows through UI Automation's own client,
in-process, from a thread that owns no window: a window that was never
shown is exposed too.

## The desktop through the window

`zig build material` shows a window whose root draws no background while
`ui.environment().system_material` is true, and the theme's background
otherwise: the same code shows Mica on Windows 11 and a solid background
on Windows 10, and on Wayland or X11 the compositor's blur behind a
window whose surface holds alpha, or a solid background where the
compositor offers no blur. `-- --no-system-material` makes the host
behave as on Windows 10, `-- --transient` asks for Acrylic, and
`-- --screenshot file.bmp` (Windows) saves what the screen shows.
`-- --check` opens the window hidden, polls it once, prints
`system material: <bool>`, and on Linux checks that the renderer
presents alpha exactly where the surface is `transparent`, also on a
second hidden window asked to be (on X11, one the host makes with its
32-bit visual as if the desktop blurred), then prints the backend and
quits without drawing; `-- --frames 120` draws 120 frames and quits. The
renderer clears to transparent and must keep its alpha: the sokol
renderer does, with D3D11, through a swapchain DirectComposition
composes into the window; Windows ignores the alpha of an OpenGL window,
so with `-Dgl=true` the backdrop would be added under every pixel.

## HDR white

`zig build hdr` shows boxes of SDR white and of two and four times it,
in `zui.ExtendedColor`, with the output format and `hdr_headroom` the
window got. On a monitor in HDR the host opens it in `.scrgb_fp16` and
the sokol renderer draws into a half-float scRGB swapchain, so the
brighter boxes show brighter; elsewhere all three show as SDR white.
`-- --measure` reads the boxes back off the desktop in scRGB, where 1.0
is 80 nits, through DXGI's desktop duplication, and fails if twice SDR
white does not show brighter than SDR white:

```
output scrgb_fp16, headroom 3.81; the desktop shows, in scRGB (1.0 is 80 nits):
  SDR white  3.500 3.500 3.500, 1.00x SDR white
  2x         7.000 7.000 7.000, 2.00x SDR white
  4x         14.000 14.000 14.000, 4.00x SDR white
```

## A theme from a file

`zig build theme` draws a window in the colors of
`hosts/native/examples/theme.zon` and restyles it when the file changes,
on Windows and on Linux. The host's file watch publishes into a
`zui_async.Stream(zui.FileChange, ...)` among the application's sources;
declaration sees the theme's file among the changes, and the loader,
between frames, reads and parses it into a `zui_async.Latest` that the
next frame draws with. Declaration does no I/O, so a recorded session
restyles in replay as it did live.

```zig
try Host.zuiFileWatch.watch(host, "examples", .of(&app.sources.theme_files));
```

```sh
zig build theme                          # edit examples/theme.zon while it runs
zig build theme -- --theme my/theme.zon  # watch another file
zig build theme -- --check               # rewrite a theme file, wait for the restyled frame, quit
```

`--check` writes a dark theme into `zig-out/theme-check/theme.zon`,
opens the window, and once a frame draws it, writes a light one over it;
it fails unless a frame draws the light background within 10 s. On the
reference machine the restyled frame came 2 to 4 ms after the write, two
frames after the first, on Windows; on Linux under Hyprland at 60 Hz, it
came 18.7 ms after it, in the second frame.

## Host services

`zig build services` has a button for each service, with its answer
beside it: pick a file, save a file, show a notification, open a popup
menu, set or clear the menu bar, copy, paste, and open
<https://ziglang.org>. It runs on both hosts; a service the host does
not offer says so beside its button. A right click anywhere opens the
context menu, and Ctrl+C, Ctrl+V, Ctrl+O and Ctrl+S do what the menus
say. Declaration only notes what was asked for, and the loader makes the
calls between frames through `zui_app.ServicesOf`, so every answer comes
back through one source, a
`zui_async.Stream(zui.ServiceReply(16 * 1024), ...)`:

```zig
const services = zui_app.ServicesOf(zui_host.Host);

pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
    if (services.has_file_dialogs and app.wants_file) {
        app.wants_file = false;
        services.file_dialogs.show(app.host, .main, .of("pick a file"), .{ .title = "Pick a file" }, .of(&app.sources.replies)) catch {};
    }
}
```

```sh
zig build services                 # interactive window
zig build services -- --check      # every service against the host's fake, in a hidden window, then quit
```

`--check` hides the window and answers every service through the host's
fake (`Host.fakeServices`), so nothing opens or shows. It presses each
button in turn, opens the popup menu by a right click on the window's
empty background, reported through the host's own handlers as the OS
would, chooses an item from the menu bar as Windows would report it, and
fails unless each answer shows in a frame within 10 s. It uses the real
clipboard, and so replaces what it holds. A paste right after a copy
often finds the clipboard held by clipboard history, and is answered
`.failed = .unavailable`; the check presses Paste again, as a user
would. Setting a menu bar shrinks the window's content by the bar's
height. On Linux the check presses only the buttons of the services the
host offers, the file dialogs, the notification and the URL, and draws
nothing: a surface the compositor never shows gets no frame callbacks,
which a renderer's swap waits for.

## A custom title bar

`zig build title-bar` draws its own title bar, over Mica on Windows: a
title, a search field and minimize, maximize and close buttons, and a
resize grip in the bottom-right corner. The application marks each part
with `Element.chrome`, behind `features.chrome_regions`, and opens the
window with `.title_bar = .custom`:

```zig
ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) } } });
defer ui.close();
_ = widgets.textField(ui, .of("search"), &app.search, .{ .label = "Search" }); // interactive, so it stays the application's
if (captionButton(ui, .of("close"), .close_button, "Close")) app.host.close(); // the keyboard's or Narrator's click
```

The window keeps the system's frame on the left, right and bottom, so
DWM draws its border, rounded corners and shadow, and only the caption
goes. `WM_NCHITTEST` is answered from the system's borders first, then a
resize band the host keeps along the top, then the frame's regions, the
last on top: a title bar is `HTCAPTION`, so Windows drags the window,
maximizes it on a double click, opens the system menu on a right click
and snaps it with Win+arrows; the maximize button is `HTMAXBUTTON`, so
hovering it shows snap layouts; resize edges and grips are the `HT` code
of their edge; and the interactive elements inside the title bar stay
`HTCLIENT`. The host keeps a copy of up to 256 regions, in pixels, under
a lock the window thread takes shared.

Over the caption buttons the pointer still reaches zui, so they show
hover and press. The host works them itself when a press and its release
land on the same button, as Windows' own buttons, and ends the press
with `pointer_cancel` rather than a release, so zui reports no click. An
application acts on `clicked` only for the keyboard and Narrator,
through `Host.minimize`, `Host.toggleMaximized` and `Host.close`, so
each button is worked once. Maximized, the content starts below the edge
of the monitor.

```sh
zig build title-bar                          # interactive window
zig build title-bar -- --no-system-material  # the solid background Windows 10 shows
zig build title-bar -- --check               # hit-test each part in a hidden window, then quit
```

`--check` hides the window, draws it twice, sends `WM_NCHITTEST` at each
part as laid out, and exits 0 only when the title is `HTCAPTION`, the
search field and the content `HTCLIENT`, the buttons `HTMINBUTTON`,
`HTMAXBUTTON` and `HTCLOSE`, and the grip in the bottom-right corner
`HTBOTTOMRIGHT`.

On Linux the window asks the compositor, through
`zxdg_decoration_manager_v1` where it is offered, to leave the
decorations to the client; where it is not, a window is already
client-side. The host keeps a copy of up to 256 regions in surface
coordinates and hit-tests each press against it, the last region on top:
a primary press on the title bar is `xdg_toplevel.move`, a second within
`zui.Gestures.double_tap_seconds` of the first maximizes or restores the
window, and a secondary press opens the compositor's window menu
(`show_window_menu`); a press on a resize edge or grip is
`xdg_toplevel.resize` from that edge. Each goes with the press's serial,
and neither the press nor its release reaches zui. The caption buttons
work as on Windows: the press reaches zui, its release on the same
button arrives as `pointer_cancel`, and the host minimizes, maximizes or
restores, or closes the window. `window_maximized` follows the
`maximized` state of the toplevel's configures. A Wayland window has no
border of the compositor's, so it resizes only from the edges and grips
the application declares; the example declares a grip. A compositor that
insists on drawing the decorations itself, as Hyprland does, gets them:
`custom_title_bar` is then false, the example draws no title bar, and
the host hands no press to the compositor. Its `--check` hit-tests each
part through `Host.chromeKindAt` in a window the compositor never shows,
expecting the title bar, the three buttons and the grip and nothing over
the search field and the content, and submits no frame, since a swap on
a surface the compositor never shows waits for a frame callback that
never comes.

On X11 the window asks for no decorations through `_MOTIF_WM_HINTS`
(decorations only, none). It reports `custom_title_bar` only where the
root window's `_NET_SUPPORTED` lists `_NET_WM_MOVERESIZE`, without which
the window could not be moved, and while the window's
`_NET_FRAME_EXTENTS` gives it no border, which a window manager that
ignores the hint and frames the window sets; otherwise the window
manager keeps its title bar, as on a Wayland compositor that insists on
drawing it. The host keeps up to 256 regions in physical pixels and
hit-tests each press the same way, with the same double click: a primary
press on the title bar or a resize edge ungrabs the pointer and sends
`_NET_WM_MOVERESIZE` to the root window, at the press's root position,
with the direction of the edge (8 for a move) and the X button; a
secondary press on the title bar sends `_GTK_SHOW_WINDOW_MENU` where
`_NET_SUPPORTED` lists it, and reaches zui where it does not. Maximize
and restore are `_NET_WM_STATE` messages adding or removing
`_NET_WM_STATE_MAXIMIZED_VERT` and `_HORZ`, minimize is
`WM_CHANGE_STATE` with `IconicState`, as `XIconifyWindow` sends it, and
`window_maximized` is true while the window's `_NET_WM_STATE` holds both
maximized states. Without a window manager, as under a bare Xvfb, there
is no custom title bar and `--check` fails saying so.

## Many windows

`zig build many-windows` runs one application in two windows through
`zui_app`: each declares its own UI in a context of its own and counts
its own clicks, and a count shared by both is published into each
window's `zui_async.Latest(u32)`. Any window opens another or closes
itself, and the run ends with the last. The sokol renderer draws each
through its own swapchain on one device, or on Linux through its own EGL
surface on one context. It runs on Windows and on Linux.

```sh
zig build many-windows                         # interactive windows
zig build many-windows -- --check              # open, click and close windows, then quit
zig build many-windows -- --measure-idle       # CPU time of two idle windows over 10 s
zig build many-windows -- --measure-animation  # frame rates of one, then two, windows animating
```

`--check` opens a second window, clicks its buttons through the host,
and exits 0 only when the second counts its own click, both show the
shared count, the first counted none, and the first draws on after the
second closes. On Windows its windows are hidden; on Linux they are
shown for the moment the check takes, since a frame drawn into a surface
the compositor never shows waits in its swap for a frame callback that
never comes; with `ZUI_HOST_BACKEND=x11` it clicks through the X11
host's handlers as through the Wayland host's. On a 144 Hz monitor on
Windows, two windows animating at once each hold 143 frames a second, as
one alone holds 144, and two idle windows use no CPU. On Linux under
Hyprland at 144 Hz, one window alone and each of two draw 72 frames a
second, as the one-window tour does there, and two idle windows use 0.9
to 21 ms of CPU over 10 s.

## The tour on a native host

`zig build tour` runs [the tour](../../apps/tour/README.md) on this
host, drawn by the sokol renderer, which draws into a `win32` window
through sokol_gfx with D3D11, or into a `wayland` surface with OpenGL
through EGL, without sokol_app. `hosts/native/examples/tour.zig` is the
target: it names the tour, this host, the sokol renderer and the font
system, and adds the screenshot this host's window gives:

```zig
const Tour = zui_tour.App(.{ .Host = zui_host.Host, .Renderer = SokolRenderer, .Text = zui_truetype.Text, .renderer_name = "sokol" });
```

`SokolRenderer` (`examples/sokol_renderer.zig`) opens the sokol renderer
on the host's window as `zui_app` opens a renderer. The window is always
shown, since the sokol renderer draws only into a window the compositor
shows.

```sh
zig build tour                               # interactive window
zig build tour -- --screen break_it          # start on one screen
zig build tour -- --frames 300 --cycle 30    # visit every screen, 30 frames each, then quit
zig build tour -- --measure-idle             # report the CPU time used over 10 idle seconds
zig build tour -- --screenshot tour.bmp      # save the window after a few frames, then quit
```

Idle, it uses no CPU: on an i9-10900K in ReleaseSafe, the old tour's
Layout Lab screen used 0.0 ms of CPU over 10 s with no frames and no
wakes in three runs of four (Windows counts CPU time in 15.6 ms ticks).
On Linux, under Hyprland with an NVIDIA RTX 2060 SUPER, the overview
used 4.6 ms over 10 s in Debug, with 1 frame and no wakes.
`--screenshot` saves the window on Windows only so far. With `--frames`,
it prints the frames drawn, the sokol renderer's layer and glyph atlas
overflows, and whether every frame's diagnostics were clean
(`diagnostics ok: true`), which CI checks on Linux under a headless
Weston.

## The tour in another process

`zig build remote` runs the same tour in a second process, declared for
the sokol renderer that draws it here and measured in the same fonts,
added in the same order, so the stream's fingerprint matches, on
`zui_wire`'s host and renderer, and draws it here: a `zui_wire.Client`
joins this host and the sokol renderer to it over a loopback TCP
connection, sending this window's input and drawing the frames that come
back, each written as the changes from the one before. Closing the
window ends the tour's process.

```sh
zig build remote                         # the tour runs in a second process; this one draws it
zig build remote -- --check tour.bmp     # press Ctrl+2, Ctrl+4, Ctrl+9, wait for each screen, save, quit
zig build remote -- --serve 7420         # only the tour, waiting for a viewer on port 7420
zig build remote -- --connect 7420       # only the viewer, joining a tour served on port 7420
```

`--check` fails if a screen does not come back within 20 s, and when the
tour's process does not exit with 0. On the reference machine it takes
under a second: the first frame arrives about 3 ms after connecting.
