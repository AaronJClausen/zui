# 14-macos: macOS, for later

Not to be built until the owner chooses to take up macOS: there is no
macOS hardware to run or check it on. Nothing here is in the queue, is
next, or counts against a stage; stage 10 and stage 11 are done without
it. When macOS is taken up, these items return to the queue in this
order, each given its Grounding, Plan and Done when as it is taken.

What fixes a contract's shape for macOS is already in the code, as a
stub with nothing behind it, so taking up macOS changes no contract:
- `zui.Surface.cocoa`, an `NSView` by pointer, and `.cocoa` among the
  surface kinds (`core/src/surface.zig`);
- `HostCapabilities.system_material` and `Environment.system_material`,
  which name vibrancy beside Mica;
- `Modifiers.super`, which a macOS host reports for Command;
- bench's `Machine`, which reads a Mac's OS version and caches
  (`core/bench/machine.zig`), and `--counters`, which says that kperf's
  counters are not read (`core/bench/counters.zig`).

`zui_host.Host` stays a compile error on macOS until `14-macos:01-macos-host` adds
its directory to `hosts/native/`. CI's macOS runners stay: they are GitHub's, and they check
that the core and its modules build and pass there.

## Items

| Item | Status |
|---|---|
| `14-macos:01-macos-host` The macOS host | set aside |
| `14-macos:02-macos-hardware-counters` macOS's hardware counters | set aside |
| `14-macos:03-macos-skin` macOS's skin | set aside |
| `14-macos:04-macos-ime` The IME on macOS | set aside |

---

## 14-macos:01-macos-host — The macOS host

Stage 10, `hosts/native/`: a Cocoa host passing
`03-contracts:03-conformance-suites`, its surface `.cocoa`, its event loop
on the main thread as AppKit requires, driving `zui_app` through
`10-reach:06-platform-owned-loop`'s `zuiRun`; vibrancy through
`NSVisualEffectView` as the system material
(`04-native-host:02-system-material`); many windows, a context each, as
`10-reach:05-many-windows` built on Windows; the EDR headroom that
`08-effects:06-hdr-and-wide-gamut` left unreported; a custom title bar's
chrome regions (`10-reach:04-window-decorations`); and the services of
`10-reach:03-services` (`NSPasteboard`, `NSOpenPanel`, the menu bar, user
notifications, `NSWorkspace`). `zui_sokol` draws into it through Metal,
which also first compiles the Metal that sokol-shdc wrote for
`08-effects:05-materials`' material shader.

## 14-macos:02-macos-hardware-counters — macOS's hardware counters

`01-measure:11-across-systems-and-hardware`'s remainder,
`core/bench/counters.zig`: `--counters` through kperf, which needs `sudo`.

## 14-macos:03-macos-skin — macOS's skin

`11-polish:08-zui-themes`' remainder, in `themes/`, once it ships the
others.

## 14-macos:04-macos-ime — The IME on macOS

`11-polish:06-text-editing`'s remainder: `NSTextInputClient` on
`14-macos:01-macos-host`'s view, against its composition events and IME
area.
