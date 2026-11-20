# Siblings' baseline, at their pins and against today's core (86c6a2d)

Taken 2026-11-20 on Omarchy (Hyprland, Wayland + Xwayland, `DISPLAY=:0`,
`WAYLAND_DISPLAY=wayland-1`), Zig 0.16.0, Node v26.13.0, Chromium 155.
Each sibling was cloned from `../zui-<name>`
into a scratch directory and run there; the originals were not built or changed.
"Today's core" is a clone of zui checked out at `86c6a2d`, passed as
`--fork=<scratch>/zui-core-86c6a2d`.

Every command ran under `timeout <= 600`; the raw logs were not kept.
`--summary all` was added to the CI commands to get test counts; nothing
else was changed. Durations are with Zig's global package cache warm and a
fresh `.zig-cache` per clone; a step that reuses what an earlier step
compiled shows a short time.

**Headline: every sibling builds and passes against today's core with no
change. No compile errors.** Two failures were found, neither caused by
core: zui-host's `check -Dtarget=aarch64-windows` fails at its own pin, and
zui-web cannot be `--fork`ed onto today's zui-sokol while its zui pin
differs from zui-sokol's (a build-runner error, not an API break).

## Pins

| Sibling | HEAD (= origin/main) | zui pin | commits from pin to 86c6a2d | other pins |
|---|---|---|---|---|
| zui-terminal | `0b5e849` (2026-11-17) | `a4f7c66` | 31 | — |
| zui-raylib | `b4e3258` (2026-11-17) | `a4f7c66` | 31 | raylib `dbc56a8` (tarball, **not lazy**) |
| zui-sokol | `f03fb36` (2026-11-20) | `7d9117a` | 5 | sokol-zig `cc3473c`, stb `4e9b368` (both **not lazy**) |
| zui-host | `e2b15ad` (2026-11-20) | `7d9117a` | 5 | zui-sokol `f03fb36` (= zui-sokol HEAD, lazy) |
| zui-web | `80e1512` (2026-11-17) | `a4f7c66` | 31 | zui-sokol `73f3612` (9 commits behind HEAD, lazy; it pins zui `a4f7c66` too), stb `4e9b368` (not lazy) |
| zui-themes | `e6115e7` (2026-11-07) | `075fbbd` | 111 | — |
| zui-examples | `c57b9fb` (2026-11-07) | `075fbbd` | 111 | — |

Each sibling's only branch is `main`, matching `origin/main`; each original's
`git status --short` was empty before and after.

---

## zui-terminal

**(a) Pin:** zui `a4f7c66`. 1,657 lines of Zig, 7 commits. `.paths`:
`build.zig, build.zig.zon, src, examples, README.md, LICENSE`.

**(b) Steps:** `test` (unit tests + the renderer suite; depends on
`conformance`), `conformance`, `demo` (stdio inherited), `check` (compiles
the demo), `fmt`, `fmt-check`. Exports module `zui_terminal`.

**(c) CI** (`.github/workflows/ci.yml`):
- Format (ubuntu): `zig fmt --check build.zig build.zig.zon src examples`
  (not the `fmt-check` step).
- Test and build, matrix ubuntu / windows / macos: `zig build test`,
  `zig build check`, then in bash
  `zig build demo -- --dump | tee dump.txt && grep -q "zui + terminal" dump.txt`.
- README also names: `zig build demo` (interactive), `zig build conformance`,
  `zig build test --fork=../zui`.

**(d) At its pin**

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig fmt --check build.zig build.zig.zon src examples` | 0 | 0.0 s | clean |
| `zig build test` | 0 | 0.4 s compile | 6/6 steps; 21/21 tests (20 unit + 1 conformance) |
| `zig build check` | 0 | 0.3 s | 3/3 steps |
| `zig build conformance` | 0 | 0.1 s | 1/1 tests |
| `zig build demo -- --dump \| tee dump.txt && grep -q "zui + terminal" dump.txt` | 0 | <1 s | grep found it |
| `zig build check -Dtarget=x86_64-windows` (extra) | 0 | 4.4 s | 3/3 steps |
| `zig build check -Dtarget=aarch64-macos` (extra) | 0 | 3.5 s | 3/3 steps |

Not runnable here: the windows-latest and macos-latest legs of
*Test and build* (`zig build test`, `zig build check`, the `--dump` check).
Cross-compiled `check` for x86_64-windows and aarch64-macos passes.

**(e) Against today's core** (`--fork=…/zui-core-86c6a2d`, "matched 1 zui packages")

| Command | Exit | Result |
|---|---|---|
| `zig build test` | 0 | 21/21 tests |
| `zig build check` | 0 | 3/3 steps |
| `zig build conformance` | 0 | 1/1 tests |
| `zig build demo -- --dump` + grep | 0 | found; the dump is **byte-identical** to the pin's |

No compile errors.

**(f) Gotchas**
- CI's format job calls `zig fmt --check` on paths, not `zig build fmt-check`.
- The `--dump` check writes `dump.txt` into the working directory (CI's
  `tee`), outside `zig-out`.
- No `linkThroughLlvmOnLinux` here: the terminal builds link no libc and
  need no workaround.
- `src/root.zig` re-exports `zui`, `zui_widgets`, `zui_reflect` (2 uses of
  `zui_terminal.zui` in the repo).
- `examples/showcase.zig` is the shared copy (see the cross-sibling section).

---

## zui-raylib

**(a) Pin:** zui `a4f7c66`; raylib `dbc56a87…` by tarball URL, **not
`.lazy`**. 5,658 lines of Zig, 17 commits. `.paths`:
`build.zig, build.zig.zon, src, examples, README.md, LICENSE` (`docs/`,
which holds `demo.png` and `gallery.png`, is not in `.paths`).

**(b) Steps:** `test` (backend unit tests), `conformance` (renderer and
host suites in hidden windows; needs a display), `demo`, `test-tour`,
`check` (demo, tour tests and conformance compiled), `fmt`, `fmt-check`.
Option `-Dzui-tracy=<bool>`, forwarded to the zui dependency. Exports module
`zui_raylib`.

**(c) CI:**
- Format (ubuntu): `zig build fmt-check`.
- Windows (windows-latest): `zig build test`, `zig build test-tour`, `zig build check`.
- Linux (ubuntu-latest; apt: libx11-dev libxrandr-dev libxinerama-dev
  libxcursor-dev libxi-dev libgl1-mesa-dev xvfb):
  `zig build test`; `zig build check`;
  `xvfb-run --auto-servernum zig build conformance`; `zig build test-tour`;
  `set -o pipefail; xvfb-run --auto-servernum zig build demo -- --hidden --frames 600 --cycle 50 2>&1 | tee cycle.log; grep "diagnostics ok: true" cycle.log`;
  for `welcome gallery mission_control typography light_and_depth`:
  `xvfb-run --auto-servernum zig build demo -- --screenshot "$PWD/demo-$screen.png" --screen $screen`;
  `timeout 60 xvfb-run --auto-servernum zig build demo -- --measure-idle 2>&1 | grep "^idle"`
  (into the step summary); uploads `demo*.png`.
- macOS (macos-latest): `zig build check`.
- README also names: `demo -- --screen gallery`, `--frames 900 --cycle 40`,
  `--measure-startup`, `--zui-debug`, `demo -Dzui-tracy=true`,
  `zig build test --fork=../zui`.

**(d) At its pin** (`xvfb-run` dropped; run against the real display)

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 1.5 s | clean |
| `zig build test` | 0 | 6.7 s | 9/9 steps; 10/10 tests |
| `zig build check` | 0 | 6.4 s | 10/10 steps |
| `zig build conformance` | 0 | 0.5 s | 2/2 tests |
| `zig build test-tour` | 0 | 0.5 s | 4/4 tests |
| `demo -- --hidden --frames 600 --cycle 50` + grep | 0 | 5.6 s | `drew 600 frames, diagnostics ok: true` |
| `demo -- --screenshot $PWD/demo-<screen>.png --screen <screen>` ×5 | 0 each | 1.5 s each | 5 PNGs, 233–349 KB |
| `timeout 60 zig build demo -- --measure-idle \| grep "^idle"` | 0 | 16.3 s | `idle: 61.6 ms of CPU over 10.0 s (0.616% of one core), 10 frames, 0 wakes` |
| `zig build check -Dzui-tracy=true` (extra) | 0 | 10.1 s | 10/10 steps |
| `zig build check -Dtarget=x86_64-windows` (extra) | 0 | 10.8 s | 10/10 steps |

Not runnable here: the Windows job (`zig build test`, `zig build test-tour`,
`zig build check` on windows-latest) and the macOS job (`zig build check`).

**(e) Against today's core** ("matched 1 zui packages")

| Command | Exit | Result |
|---|---|---|
| `zig build test` | 0 | 10/10 tests |
| `zig build check` | 0 | 10/10 steps |
| `zig build conformance` | 0 | 2/2 tests |
| `zig build test-tour` | 0 | 4/4 tests |
| cycle `--hidden --frames 600 --cycle 50` + grep | 0 | `drew 600 frames, diagnostics ok: true` |
| screenshots ×5 | 0 each | written |
| `--measure-idle` | 0 | `idle: 62.9 ms of CPU over 10.0 s (0.628% of one core), 11 frames, 0 wakes` |
| `zig build check -Dzui-tracy=true` | 0 | 10/10 steps |

No compile errors.

**(f) Gotchas**
- `raylib` is fetched eagerly (`b.dependency`); RESTRUCTURE wants every
  third-party library `.lazy = true` with `lazyDependency`.
- Screenshots are **not byte-reproducible**: two runs at the pin of the same
  screen differ, so pin-vs-core PNGs cannot be compared by hash.
- `cycle.log` and the screenshots are written to the working directory
  (CI passes `$PWD/demo-*.png`), outside `zig-out`.
- Workarounds in `build.zig`: `linkThroughLlvmOnLinux` (LLVM + LLD on Linux,
  for GCC 16's crt1.o `.sframe` relocations) and
  `moveSystemLibrariesOntoModule` (moves raylib's GL/X11 system libraries
  off the static library so LLD does not fail on archived `.so` members).
- `src/root.zig` re-exports `zui`, `zui_app`, `zui_widgets`, `zui_reflect`,
  `zui_async`, `zui_tracy`, `zui_debug`; 10 uses in the repo.
- Its `examples/` is the raylib copy of the tour (see cross-sibling);
  only raylib has `LiberationMono-Regular.ttf` and its licence, and the
  Tracy/inspector wiring.

---

## zui-sokol

**(a) Pin:** zui `7d9117a`; sokol-zig `cc3473c` (git URL) and stb
`4e9b368`, **neither lazy**; `build.zig` does `const sokol = @import("sokol")`
at the top (for `sokol.shdc`). 10,570 lines of Zig, 40 commits. `.paths`:
`build.zig, build.zig.zon, src, examples, README.md, LICENSE`.

**(b) Steps:** `check` (backend + demo, plus `examples/tour_freestanding.zig`
linked for wasm32-freestanding; with `-Dtarget=wasm32-freestanding` the
build returns after declaring the tour modules), `test` (backend + `zui_sokol_ui`
unit tests), `test-tour`, `demo`, `conformance` (renderer suite in a window,
always OpenGL), `shaders` (regenerates `src/{material,linear_light,present_scrgb}.glsl.zig`
with sokol-shdc), `fmt`, `fmt-check` (both exclude the generated files).
Option `-Dgl=<bool>` (OpenGL instead of D3D11/Metal). Exports modules
`zui_sokol`, `zui_sokol_ui`, `zui_sokol_tour`.

**(c) CI:**
- Format (ubuntu): `zig build fmt-check`.
- Renderer suite (ubuntu; apt: libx11-dev libxi-dev libxcursor-dev
  libgl1-mesa-dev libpulse-dev libegl-dev libwayland-dev xvfb):
  `xvfb-run --auto-servernum zig build conformance`.
- Test and build, matrix ubuntu / windows / macos (Linux apt as above
  without xvfb): `zig build test`, `zig build check`, on Windows only
  `zig build check -Dgl=true`, then `zig build test-tour`.
- README also names: `demo -- --screen gallery`, `demo -- --frames 900 --cycle 40`,
  `demo -Dgl=true`, `zig build shaders`, `zig build test --fork=../zui`.

**(d) At its pin**

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 1.3 s | clean |
| `zig build test` | 0 | 4.6 s | 10/10 steps; 33/33 tests |
| `zig build check` | 0 | 10.3 s | 10/10 steps (includes the wasm32 tour link) |
| `zig build test-tour` | 0 | 6.2 s | 3/3 tests |
| `zig build conformance` (xvfb dropped) | 0 | 3.7 s | `zui_sokol.Renderer passes zui's renderer suite into its swapchain, into .sdr and .scrgb_fp16 offscreen images, and into a multisampled .sdr one` |
| `zig build demo -- --frames 900 --cycle 40` (README) | 0 | 6.4 s | `drew 900 frames, declared 899, 0 layer overflows, 0 glyph atlas overflows, diagnostics ok: true` |
| `zig build check -Dtarget=x86_64-windows` (Windows leg, cross) | 0 | 7.6 s | 10/10 steps |
| `zig build check -Dgl=true -Dtarget=x86_64-windows` (Windows leg, cross) | 0 | 7.2 s | 10/10 steps |
| `zig build shaders` (extra) | 0 | 1.2 s | regenerated files **byte-identical** (`git status` clean) |

Not runnable here: the windows-latest and macos-latest legs of
*Test and build* (`test`, `check`, `check -Dgl=true` on Windows, `test-tour`).
Their `check` was cross-compiled for x86_64-windows, with and without `-Dgl=true`.

**(e) Against today's core** ("matched 1 zui packages")

| Command | Exit | Result |
|---|---|---|
| `zig build test` | 0 | 33/33 tests |
| `zig build check` | 0 | 10/10 steps |
| `zig build test-tour` | 0 | 3/3 tests |
| `zig build conformance` | 0 | passes, same message |
| `demo -- --frames 900 --cycle 40` | 0 | same line as at the pin |
| `check -Dtarget=x86_64-windows`, and with `-Dgl=true` | 0, 0 | 10/10 steps each |

No compile errors.

**(f) Gotchas**
- **LLD noise that looks like a failure:** every Linux link of an artifact
  using `sokol_clib` prints
  `error: warning(link): unexpected LLD stderr:` /
  `ld.lld: warning: …/libsokol_clib.a: archive member '/lib64/libpulse.so' is neither ET_REL nor LLVM bitcode`
  (also libpulse-simple, libGL, libX11, libXi, libXcursor) and a
  `failed command:` line, yet the step succeeds and the build exits 0. Same
  in zui-web and zui-host. Do not read it as a failure.
- `sokol_app` prints `LINUX_X11_QUERY_SYSTEM_DPI_FAILED … assuming default 96.0`
  under Xwayland; harmless.
- `linkThroughLlvmOnLinux` is applied to every test and executable.
- Generated files `src/*.glsl.zig` (716 + 831 + 516 lines) are checked in;
  `shaders` writes into `src/` (outside `zig-out`); `fmt`/`fmt-check`
  exclude them via `generated_paths`. A root-level `fmt-check` over the
  whole tree must exclude them too.
- `sokol` and `stb` are eager; `@import("sokol")` in `build.zig` forces
  sokol to be fetched for any step, `--help` included (Zig needs
  `b.lazyImport` for a lazy dependency's build.zig). Making them lazy is
  part of slice 4.
- Linux builds of the backend link `EGL` and `wayland-egl` (the native
  host's surface); Windows links d3d11/dxgi/user32 + `src/composition.c`,
  or opengl32/gdi32 with `-Dgl=true`.
- zui-web and zui-host reach into this package by path:
  `zui_sokol_dependency.path("examples/fonts/AtkinsonHyperlegible-{Regular,Bold}.ttf")`
  and `examples/fonts/OFL.txt` (zui-web), and modules `zui_sokol_tour`,
  `zui_sokol_ui` (both). Its `.paths` must keep `examples` until slice 11.
- `src/root.zig` re-exports `zui`, `zui_widgets`, `zui_reflect`,
  `zui_sokol_ui`; `src/ui/root.zig` re-exports `zui`.

---

## zui-host

**(a) Pin:** zui `7d9117a`; zui-sokol `f03fb36` by git URL (lazy). 17,123
lines of Zig, 35 commits. `.paths`:
`build.zig, build.zig.zon, zui_host.zig, windows, linux, examples, README.md, LICENSE`.

**(b) Steps:** `test` (unit tests; on Windows and Linux also depends on
`conformance`), `conformance` (host suite + the host's own tests against a
window never shown; Linux skips without a Wayland compositor), `check`,
`fmt`, `fmt-check`; on Windows or Linux targets: `tour`, `theme`,
`services`; on Windows targets only: `remote`, `material`, `hdr`,
`accessible`, `title-bar`, `many-windows`. Exports module `zui_host`.

**(c) CI:**
- Format (ubuntu): `zig build fmt-check`.
- Windows (windows-latest): `zig build test`, `zig build test -Doptimize=ReleaseSafe`,
  `zig build check` (examples compiled only).
- Linux (ubuntu-latest; apt: libwayland-dev libxkbcommon-dev libegl-dev
  libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev weston
  dbus-daemon): starts `weston --backend=headless --socket=wayland-ci --idle-time=0`
  with `XDG_RUNTIME_DIR=$RUNNER_TEMP/xdg`, `WAYLAND_DISPLAY=wayland-ci`;
  starts `dbus-daemon --session --nofork --address=unix:abstract=/zui-host-ci --print-address`
  and sets `ZUI_HOST_TEST_SESSION_BUS` to its address; then
  `zig build test --summary all`, `zig build test -Doptimize=ReleaseSafe`,
  `zig build check`.
- Cross (ubuntu): `zig build check -Dtarget=x86_64-windows`,
  `zig build check -Dtarget=aarch64-windows`.
- README also names: `tour` (`--screen`, `--frames 300 --cycle 30`,
  `--measure-idle`, `--screenshot tour.bmp`), `theme` (`--theme`, `--check`),
  `services` (`--check`), and the Windows-only `remote -- --check tour.bmp`,
  `title-bar -- --check`, `many-windows -- --check / --measure-idle /
  --measure-animation`, `accessible -- --frames 30`, `material`, `hdr -- --measure`;
  env `ZUI_HOST_TEST_SHOWN_WINDOW`, `ZUI_HOST_TEST_SESSION_BUS`.

**(d) At its pin.** Here: the real Hyprland compositor instead of headless
Weston, and a private `dbus-daemon --session --nofork --address=unix:abstract=/zui-host-01b-2 --print-address`
for `ZUI_HOST_TEST_SESSION_BUS`.

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 1.4 s | clean |
| `zig build test` (no bus variable) | 0 | 3.7 s | 7/7 steps; 54/58 tests (4 skipped: 3 D-Bus, 1 shown-window) |
| `ZUI_HOST_TEST_SESSION_BUS=<private bus> zig build test --summary all` | 0 | — | 57/58 tests (1 skipped) |
| same, `-Doptimize=ReleaseSafe` | 0 | 15.3 s | 57/58 tests (1 skipped) |
| `zig build check` | 0 | 8.5 s | 11/11 steps |
| `zig build check -Dtarget=x86_64-windows` | 0 | 10.1 s | 17/17 steps |
| `zig build check -Dtarget=aarch64-windows` | **1** | 11.0 s | **38 compile errors**, all the same (below) |
| `zig build services -- --check` (README) | 0 | <1 s | `services: every service answered and showed its answer; 0 pastes found the clipboard held and were pressed again` |
| `zig build theme -- --check` (README) | 0 | <1 s | `theme: restyled in frame 2, 19.7 ms after the file was rewritten` |
| `zig build tour -- --frames 300 --cycle 30` (README) | 0 | 4.4 s | `drew 300 frames, 0 layer overflows, diagnostics ok: true` |
| `zig build tour -- --measure-idle` (README) | 0 | 11.3 s | `idle: 34.2 ms of CPU over 10 s, 10 frames, 0 wakes` |
| `zig build tour -- --screenshot …/tour.bmp` (README) | 0 | <1 s | **no file**: `error: could not save …: this host does not capture its window yet` (Linux) |

The aarch64-windows failure, at the pin (`e2b15ad`, = origin/main):

```
windows/uia_client.zig:35:16: error: @ptrCast increases pointer alignment
        return @ptrCast(self.vtable[index]);
               ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
windows/uia_client.zig:35:36: note: '*const anyopaque' has alignment '1'
windows/uia_client.zig:35:16: note: '*const fn (*uia_client.Object) callconv(.c) i32' has alignment '4'
windows/uia_client.zig:35:16: note: use @alignCast to assert pointer alignment
referenced by:
    setFocus: windows/uia_client.zig:108:37
    test.an assistive technology's focus arrives as a focus action, …: windows/conformance.zig:978:22
error: 38 compilation errors
```

in `compile test Debug aarch64-windows` (the conformance tests); every
example executable compiled. The file was last changed by `eb9b32e`
(2026-11-19, "Scroll, show the context menu and close dialogs through UI
Automation"), after `a685778` introduced it. So zui-host's own CI *Cross*
job is red at its HEAD (unless GitHub's runner differs), independent of
core. Slice 5's rule "every check green" with the Windows cross-checks will
need it fixed (an `@alignCast`), or a decision.

Not runnable here: the Windows job (`zig build test`, `test -Doptimize=ReleaseSafe`,
`check` on windows-latest) and the Windows-only examples' runs; their
compilation is covered by `check -Dtarget=x86_64-windows`.

**(e) Against today's core** (with the private bus for `test`)

| Command | Exit | Result |
|---|---|---|
| `--fork=core`: `zig build test --summary all` | 0 | 57/58 (1 skipped) |
| `--fork=core`: `zig build test -Doptimize=ReleaseSafe` | 0 | 57/58 (1 skipped) |
| `--fork=core`: `zig build check` | 0 | 11/11 steps |
| `--fork=core`: `check -Dtarget=x86_64-windows` | 0 | 17/17 steps |
| `--fork=core`: `check -Dtarget=aarch64-windows` | 1 | the same 38 `uia_client.zig:35:16` errors as at the pin; nothing new |
| `--fork=core`: `services -- --check`, `theme -- --check` | 0, 0 | same lines (theme 17.4 ms) |
| `--fork=core`: `tour -- --frames 300 --cycle 30` | 0 | `drew 300 frames, 0 layer overflows, diagnostics ok: true` |
| `--fork=core`: `tour -- --measure-idle` | 0 | `idle: 33.7 ms of CPU over 10 s, 10 frames, 0 wakes` |
| `--fork=core --fork=zui-sokol`: `test` | 0 | 57/58 (1 skipped) |
| `--fork=core --fork=zui-sokol`: `check`, `check -Dtarget=x86_64-windows` | 0, 0 | 11/11, 17/17 steps |
| `--fork=core --fork=zui-sokol`: `tour -- --frames 300 --cycle 30` | 0 | same line |

`--fork=core` reaches zui-sokol's zui pin: host and zui-sokol `f03fb36`
both pin zui `7d9117a`, one package, "matched 1 zui packages";
`--fork=zui-sokol` "matched 1 zui_sokol packages". Since the host pins
zui-sokol's HEAD, the second fork changes nothing. No compile errors.

**(f) Gotchas**
- **A dead bus fails three tests.** With `ZUI_HOST_TEST_SESSION_BUS` naming
  a bus whose daemon has exited, three `linux.services` tests fail with
  `error.BusUnavailable` (`linux/dbus.zig:509:25`, from
  `connectAndSayHello`, `linux/services.zig:1098`); without the variable
  they skip. This happened once, when the daemon's `timeout` expired mid-run;
  the tests passed on rerun with a live bus. A slice that starts the daemon must
  keep it alive for every test run.
- The fourth skip needs `ZUI_HOST_TEST_SHOWN_WINDOW` (shows a window).
- `theme -- --check` writes `zig-out/theme-check/theme.zon` (the program,
  not the build system, writes into `zig-out`).
- `tour -- --screenshot` exits 0 on Linux without writing a file; it is not
  a check.
- Linux links `wayland-client` and `xkbcommon`; Windows links ten system
  libraries; `linkThroughLlvmOnLinux` here too (but not on the Windows-only
  examples, which never build for Linux).
- `zui_host.zig` re-exports `zui` (11 uses of `zui_host.zui`).
- `examples/tour.zig` (277 lines) imports `zui_sokol_tour` and `zui_sokol`.

---

## zui-web

**(a) Pin:** zui `a4f7c66`; zui-sokol `73f3612` (lazy; it also pins zui
`a4f7c66`); stb `4e9b368` (not lazy). 4,858 lines of Zig, 20 commits.
`.paths`: `build.zig, build.zig.zon, src, tools, web, README.md, LICENSE`.

**(b) Steps:** `test`, `check` (unit tests, the client for
wasm32-freestanding, and the tour's worker for wasm32 with atomics and
bulk-memory), `test-demo`, `test-draw` (needs a display), `test-input`,
`site` (writes `zig-out/site`), `test-site`, `fmt`, `fmt-check`; the default
install writes `zig-out/web/zui-web.wasm` and `zui-web-tour.wasm`. Option
`-Dbrowser=<path>`, default `"chromium"`, used by `test-draw`, `test-input`
and `test-site`; Node is found as `node` on `PATH`. Env
`ZUI_WEB_DRAW_FAILURES=<dir>` keeps the failing frames of `test-draw`
(otherwise a `mkdtemp` under the system temp dir).

**(c) CI** (`ci.yml`, and `pages.yml`):
- Format (ubuntu): `zig build fmt-check`.
- Test and check, matrix ubuntu / windows / macos: `zig build test`,
  `test -Doptimize=ReleaseSafe`, `test -Doptimize=ReleaseFast`, `zig build check`.
- demo (ubuntu; apt: libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev
  libpulse-dev): `node --version`, `zig build test-demo`,
  `zig build test-demo -Doptimize=ReleaseSafe`, `google-chrome --version`,
  `zig build test-input -Dbrowser=google-chrome`,
  `zig build test-site -Dbrowser=google-chrome`.
- draw (ubuntu; same apt + xvfb):
  `xvfb-run --auto-servernum zig build test-draw -Dbrowser=google-chrome`
  with `ZUI_WEB_DRAW_FAILURES=$RUNNER_TEMP/draw-failures`, uploaded on failure.
- Pages (`pages.yml`, push to main): `zig build site -Doptimize=ReleaseSmall`,
  `zig build test-site -Doptimize=ReleaseSmall -Dbrowser=google-chrome`,
  upload `zig-out/site`, deploy to GitHub Pages.
- CLAUDE.md: `test` always; ReleaseSafe/ReleaseFast before committing;
  `check` always; `test-demo`, `test-draw`, `test-input`, `test-site` on
  the changes it lists; `fmt`; `zig build test --fork=../zui`.

**(d) At its pin** (`-Dbrowser` left at its default, `/usr/bin/chromium`;
`test-draw` against the real display, no xvfb)

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 1.3 s | clean |
| `zig build test` | 0 | 1.0 s | 5/5 steps; 42/42 tests |
| `zig build test -Doptimize=ReleaseSafe` | 0 | 17.0 s | 42/42 tests |
| `zig build test -Doptimize=ReleaseFast` | 0 | 20.1 s | 42/42 tests |
| `zig build check` | 0 | 9.8 s | 10/10 steps |
| `zig build test-demo` | 0 | 8.1 s | 19/19 steps |
| `zig build test-demo -Doptimize=ReleaseSafe` | 0 | 30.4 s | 19/19 steps |
| `zig build test-input` | 0 | 7.2 s | 11/11 steps |
| `zig build test-site` | 0 | 20.6 s | 16/16 steps |
| `ZUI_WEB_DRAW_FAILURES=… zig build test-draw` | 0 | 8.9 s | 17/17 steps; no failure frames |
| `zig build site -Doptimize=ReleaseSmall` | 0 | 7.9 s | 16/16 steps; `zig-out/site`: `zui-web.wasm` 78,159 B, `zui-web-tour.wasm` 798,199 B, `bitmap.fonts` 12,288 B, fonts/, scripts |
| `zig build test-site -Doptimize=ReleaseSmall` | 0 | 18.9 s | 16/16 steps |

The Node checks print nothing on success; the step summaries are the result.
Not runnable here: the windows-latest and macos-latest legs of
*Test and check*; the Pages deploy.

**(e) Against today's core**

`--fork=core` alone ("matched 1 zui packages": zui-web and zui-sokol
`73f3612` both pin `a4f7c66`, so the fork reaches zui-sokol's zui):

| Command | Exit | Result |
|---|---|---|
| `test`, `check` | 0, 0 | 42/42 tests; 10/10 steps |
| `test-demo`, `test-input`, `test-site`, `test-draw` | 0 each | 19/19, 11/11, 16/16, 17/17 steps |
| `site -Doptimize=ReleaseSmall`, `test-site -Doptimize=ReleaseSmall` | 0, 0 | 16/16 steps each |

`--fork=core --fork=zui-sokol` (today's zui-sokol `f03fb36`) **fails before
building anything**, for every step (exit 2):

```
info: fork …/zui-core-86c6a2d matched 2 zui packages
info: fork …/zui-sokol matched 1 zui_sokol packages
.zig-cache/o/…/dependencies.zig:1:1: error: file exists in modules 'root.@dependencies.zui-0.5.0-xfvfqi7vHABEAXHqjHlbLr7xqQ4rLAjOituFbaNLEPG_' and 'root.@dependencies.zui-0.5.0-xfvfqtAvGgCYFsRPGKDph0T_Tqqgb3MQF_-hNPgD_2r-'
.zig-cache/o/…/dependencies.zig:1:1: note: files must belong to only one module
```

Today's zui-sokol pins zui `7d9117a` while zui-web pins `a4f7c66`: two zui
packages in the graph, both forked onto one directory, so the build
runner sees one `build.zig` in two modules. This is a limit of `--fork`, not
an API break. With zui-web's zui pin changed to `7d9117a` (in a second,
scratch-only clone, `zui-web-repinned/build.zig.zon`), every step passes:

| `--fork=core --fork=zui-sokol`, zui pin `7d9117a` | Exit | Result |
|---|---|---|
| `test`, `check` | 0, 0 | 42/42 tests; 10/10 steps |
| `test-demo`, `test-input`, `test-draw`, `test-site` | 0 each | 19/19, 11/11, 17/17, 16/16 steps |
| `site -Doptimize=ReleaseSmall` | 0 | 16/16 steps |

So zui-web works against today's core **and** today's zui-sokol;
`test-draw`'s comparison with zui-sokol's renderer passes against
zui-sokol's HEAD too. No compile errors.

**(f) Gotchas**
- With `.path` deps (slice 6) the two-zui problem goes away; until then, a
  `--fork` of both needs zui-web's zui pin to equal zui-sokol's.
- `test-draw` needs a display: run on the real one locally, `xvfb-run` in CI.
  Chromium is found by `-Dbrowser` (default `chromium`); CI passes
  `google-chrome`. A slice's CI keeps `-Dbrowser=google-chrome`.
- The tools that run the tour natively (`demo-stream`, `tour-frames`,
  `draw-reference`, `bitmap-fonts`, `replay-input`) link sokol, hence
  `linkThroughLlvmOnLinux` and the LLD noise described under zui-sokol.
  `site` needs sokol's X11/GL/PulseAudio headers for the bitmap-fonts tool.
- `build.zig` names zui-sokol's files: `examples/fonts/AtkinsonHyperlegible-Regular.ttf`,
  `…-Bold.ttf` (`tour_truetype_fonts`, "in the order `kit.addFonts` adds
  them"), and `examples/fonts/OFL.txt`; modules `zui_sokol`, `zui_sokol_ui`,
  `zui_sokol_tour`. 3 uses of `zui_sokol.zui`.
- `stb` is eager. `src/stb_truetype.c`, `truetype.zig` and `glyph_atlas.zig`
  are forks of zui-sokol's, not copies (below).

---

## zui-themes

**(a) Pin:** zui `075fbbd` (111 commits behind). 31 lines of Zig
(`src/root.zig`), 2 commits. `.paths`: `build.zig, build.zig.zon, src, README.md, LICENSE`.

**(b) Steps:** `test`, `check`, `fmt`, `fmt-check`.

**(c) CI:** Format (ubuntu): `zig build fmt-check`. Test and check, matrix
ubuntu / windows / macos: `zig build test`, `test -Doptimize=ReleaseSafe`,
`test -Doptimize=ReleaseFast`, `zig build check`. CLAUDE.md and README: the
same, plus `fmt` and `zig build test --fork=../zui`.

**(d) At its pin**

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 2.3 s | clean |
| `zig build test` | 0 | 0.4 s | 4/4 steps; 1/1 tests |
| `zig build test -Doptimize=ReleaseSafe` | 0 | 10.7 s | 1/1 tests |
| `zig build test -Doptimize=ReleaseFast` | 0 | 12.6 s | 1/1 tests |
| `zig build check` | 0 | 1.1 s | 3/3 steps |
| `zig build check -Dtarget=x86_64-windows` (extra) | 0 | 2.1 s | 3/3 steps |

Not runnable here: the windows-latest and macos-latest legs.

**(e) Against today's core:** `test` 0 (1/1), `check` 0 (3/3),
`test -Doptimize=ReleaseSafe` 0 (1/1). No compile errors.

**(f) Gotchas:** a skeleton. Its `src/root.zig` is byte-identical to
zui-examples' `samples/root.zig`. Its CLAUDE.md is an agent guide that
slice 7 folds into the root's.

---

## zui-examples

**(a) Pin:** zui `075fbbd`. 29 lines of Zig (`samples/root.zig`), 2 commits.
`.paths`: `build.zig, build.zig.zon, samples, README.md, LICENSE`.

**(b) Steps:** `test` ("the samples' tests"), `check`, `fmt`, `fmt-check`.

**(c) CI:** identical to zui-themes' (format; test ×3 optimize modes and
check on ubuntu / windows / macos). CLAUDE.md and README: the same commands.

**(d) At its pin**

| Command | Exit | Time | Result |
|---|---|---|---|
| `zig build fmt-check` | 0 | 1.1 s | clean |
| `zig build test` | 0 | 0.4 s | 4/4 steps; 1/1 tests |
| `zig build test -Doptimize=ReleaseSafe` | 0 | 11.6 s | 1/1 tests |
| `zig build test -Doptimize=ReleaseFast` | 0 | 11.0 s | 1/1 tests |
| `zig build check` | 0 | <0.1 s | 3/3 steps |

Not runnable here: the windows-latest and macos-latest legs.

**(e) Against today's core:** `test` 0 (1/1), `check` 0 (3/3),
`test -Doptimize=ReleaseSafe` 0 (1/1). No compile errors.

**(f) Gotchas:** a skeleton; `samples/` is where RESTRUCTURE's
`examples/samples/` comes from, and it has no `template/` yet. CLAUDE.md
folds into the root's.

---

## Across the siblings

### What breaks against today's core

Nothing. By the areas of core that changed since the pins, and the sibling
code that reaches them (from each `build.zig`'s imports and the runs above;
I did not audit which core commits touched which API):

| Core area | Sibling code that reaches it | Result at 86c6a2d |
|---|---|---|
| `zui_app` many-windows API (H9) | raylib (`zui_raylib.Host` on `zui_app`), host (`tour`, `services`, `many-windows`) | compiles and runs; raylib's conformance and cycle, host's tour cycle, services and theme checks pass |
| host services shape | host (`services`, `linux/services.zig`, D-Bus tests) | 57/58 tests, services `--check` passes |
| semantics | sokol's tour (semantics on), host (accessible, UIA on Windows) | sokol test-tour and host Windows cross-check pass |
| chrome regions / title bar | host (`title-bar`, Windows) | x86_64-windows check passes |
| wire payload types | web (`zui_wire` stream, browser client) | test-demo, test-draw, test-input, test-site pass |

The sibling CI suites therefore need **no API absorption** in slices 2–6;
the work there is build wiring (pins to `.path`, re-exports removed, lazy
libraries, CI moved). The only things to plan around:

1. **zui-host `check -Dtarget=aarch64-windows` fails at its own pin**
   (`windows/uia_client.zig:35:16: error: @ptrCast increases pointer alignment`,
   38 times). Not core's doing. Slice 5 must fix it (an `@alignCast`) or
   get a decision, since its Done when includes the Windows cross-checks.
2. **zui-web cannot be `--fork`ed onto today's zui-sokol** while their zui
   pins differ (build-runner error above). Gone once both are `.path` deps.

### Duplicated files (sha256)

Byte-identical:

| File | Copies |
|---|---|
| `examples/showcase.zig` (181 lines, `ed1b422d…`) | terminal, raylib, sokol; header "Keep this file identical" in all three |
| `examples/fonts/AtkinsonHyperlegible-Regular.ttf` (`7fb917c8…`) | raylib, sokol |
| `examples/fonts/AtkinsonHyperlegible-Bold.ttf` (`5a3b0c8c…`) | raylib, sokol |
| `examples/fonts/OFL.txt` (`f32d22b3…`) | raylib, sokol |
| `examples/screens/{layout_lab,pixel_pad,robot_workshop,window_manager}.zig` | raylib, sokol |
| `LICENSE` (`5bd2c99b…`) | all seven |
| `zui-themes/src/root.zig` = `zui-examples/samples/root.zig` (`a554eb25…`) | themes, examples |

Only in raylib: `examples/fonts/LiberationMono-Regular.ttf` and
`LiberationMono-LICENSE.txt`. Not identical (forks): zui-sokol's
`src/ui/truetype.zig` (167 lines) vs zui-web's `src/truetype.zig` (184),
95 changed lines; `src/glyph_atlas.zig` 136 vs 138 lines, 26 changed;
`src/ui/stb_truetype.c` 39 vs 37 lines, 32 changed. zui-web's copies
differ by the same amounts from zui-sokol at `73f3612`, its pin, so the fork
is not from drift since the pin. `zui-sokol/src/bitmap_glyphs.zig` exists
only there.

### The two tours

| | raylib `examples/` | sokol `examples/` |
|---|---|---|
| tracked files | 21 | 23 |
| lines of Zig | 4,539 | 4,693 |
| bytes (with fonts) | 654,969 | 340,951 |

Same-path files: identical `showcase.zig`, the four screens above, the two
Atkinson fonts and `OFL.txt`. Differing (changed lines): `app.zig` 35,
`demo.zig` 496, `kit.zig` 93, `perf.zig` 61, `tour_test.zig` 66,
`screens/typography.zig` 25, `light_and_depth.zig` 60, `gallery.zig` 12,
`mission_control.zig` 4, `welcome.zig` 4, `box_storm.zig` 2. Only in sokol:
`screens/materials.zig`, `screens/transforms.zig`, `tour_app.zig`,
`tour_freestanding.zig`. Only in raylib: Liberation Mono and its licence.
zui-terminal's `examples/` is 300 lines (`demo.zig` 119, `showcase.zig`
181); zui-host's is 2,401 lines in 11 files (`tour.zig` 277).

### What every slice will meet

- **`zig-pkg/`:** Zig 0.16 extracts each package's dependencies into
  `zig-pkg/` inside the package directory (every clone grew one, besides
  `.zig-cache/`). Every sibling's `.gitignore` and core's list `.zig-cache/`,
  `zig-out/`, `zig-pkg/` without a leading slash, so they match at any
  depth. A root `fmt`/`fmt-check` "over the whole tree" must not descend
  into `*/zig-pkg/` or `*/.zig-cache/`, and must exclude sokol's
  `src/*.glsl.zig`. A plain `grep -r 'Keep this file identical'` finds the
  copies in `zig-pkg/` too; `rg` skips them through `.gitignore`.
- **LLD/linker:** `linkThroughLlvmOnLinux` is duplicated in raylib, sokol,
  host and web `build.zig`; raylib also has `moveSystemLibrariesOntoModule`.
  LLD's archive-member warnings print as `error: warning(link)` with exit 0.
- **Needs a display:** raylib `conformance`, the demo cycle, screenshots and
  idle; sokol `conformance` and `demo`; host `test`/`conformance` (a Wayland
  compositor, else skipped) and every example; web `test-draw`. CI wraps
  them in `xvfb-run --auto-servernum` (host: headless Weston); here they ran
  on the real display.
- **Writes outside `zig-out`:** CI's `dump.txt`, `cycle.log`, `demo-*.png`
  in the working directory; sokol's `shaders` into `src/`.
- **Eager third-party libraries:** raylib (zui-raylib), sokol and stb
  (zui-sokol, plus `@import("sokol")` in its `build.zig`), stb (zui-web).
- **Re-exports to remove:** `zui_terminal.{zui,zui_widgets,zui_reflect}`,
  `zui_raylib.{zui,zui_app,zui_widgets,zui_reflect,zui_async,zui_tracy,zui_debug}`,
  `zui_sokol.{zui,zui_widgets,zui_reflect,zui_sokol_ui}`, `zui_sokol_ui.zui`,
  `zui_host.zui`.

## Commands for the next slices

Run from the package's directory, against today's core:

```sh
# terminal
zig build test && zig build check && zig build conformance
zig build demo -- --dump | tee dump.txt && grep -q "zui + terminal" dump.txt

# raylib
zig build test && zig build check && zig build conformance && zig build test-tour
zig build demo -- --hidden --frames 600 --cycle 50 2>&1 | grep "diagnostics ok: true"
zig build demo -- --screenshot "$PWD/demo-welcome.png" --screen welcome   # × 5 screens
timeout 60 zig build demo -- --measure-idle 2>&1 | grep "^idle"

# sokol
zig build test && zig build check && zig build test-tour && zig build conformance
zig build check -Dtarget=x86_64-windows && zig build check -Dgl=true -Dtarget=x86_64-windows

# host (bus kept alive for the whole run)
dbus-daemon --session --nofork --address=unix:abstract=/zui-host-test --print-address &
ZUI_HOST_TEST_SESSION_BUS=unix:abstract=/zui-host-test zig build test --summary all   # expect 57/58, 1 skipped
zig build check && zig build check -Dtarget=x86_64-windows
zig build check -Dtarget=aarch64-windows   # fails at the pin: uia_client.zig:35:16

# web
zig build test && zig build check && zig build test-demo && zig build test-input && zig build test-site
zig build test-draw            # needs a display
zig build site -Doptimize=ReleaseSmall && zig build test-site -Doptimize=ReleaseSmall

# themes, examples
zig build test && zig build test -Doptimize=ReleaseSafe && zig build test -Doptimize=ReleaseFast && zig build check
```
