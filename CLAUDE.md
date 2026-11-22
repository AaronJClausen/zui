# Working on zui

zui is an immediate-mode UI engine for Zig 0.16. Four documents govern
it, and each has one job:

| Document | Its job | Changes when |
|---|---|---|
| `SPEC.md` | the contract: what zui is, every API, every budget | the implementation proves it wrong, or an open question (§22) is settled |
| `ROADMAP.md` and `roadmap/` | **the queue** of work and where it stands (`ROADMAP.md`); each item's plan, test and status, in its group's file (`roadmap/<group>.md`); the decisions (`roadmap/decisions.md`) | every item, every slice of an item |
| `ARCHITECTURE.md` | the map: which layer and package holds each part, and how today's code still differs from the spec (§7) | a difference closes or opens, or a feature moves layer or stage |
| `README.md`, each package's `README.md`, and `docs/development.md` and `docs/benchmarking.md` | what a user sees: in `README.md`, the status in one line per stage, the core API, the packages and the common build commands; in a package's `README.md` (`renderers/<name>/`, `hosts/native/`, `hosts/web/`, `apps/tour/`, `text/`), its API, what it draws or reports, its limits and its build steps; in `docs/development.md`, every root step, CI and the conformance recipe; in `docs/benchmarking.md`, profiling and measuring | a stage or a user-visible API ships, or a build step changes |

The code and these documents move together. A commit that changes one
and leaves another stale is not done.

## "Tackle the next item"

1. **Find it.** Open `ROADMAP.md`, section *The queue*. Take the first
   row whose status is not `waiting`. An `in progress` row is continued,
   not restarted: its item's **Status** says which slice comes next.
   Work set aside is parked on a branch that the item's **Status**
   names; read it before starting, and build on `main` unless the Status
   says to rebase.
2. **Read it.** Read the item's entry in its group's file, the part of
   its label before the colon (`10-reach:01-linux-host` is in
   `roadmap/10-reach.md`): its Grounding, Plan and Done when, then every
   SPEC.md section it names, and the files in its *Where* column. Check
   the *Waits for* column; if a prerequisite is not done, mark the row
   `waiting on <item>` and take the next row.
3. **Check the ground.** The Grounding cites `file:line`; confirm it
   still holds before building on it. If it does not, fix the Grounding
   in the same commit.
4. **Plan a slice.** An item that will not fit one session is done in
   slices, each one a commit that leaves every check green. Say in a
   sentence or two what this slice covers before writing code.
5. **Build it,** putting each piece where the table below says.
6. **Verify it** with the commands below, and with the item's own *Done
   when*. A speedup is measured (`zig build bench-compare -- <base>`),
   or it does not ship.
7. **Update the documents** using the checklist below.
8. **Commit,** one commit per item or slice, and report to the user what
   was done, what was measured, and which row is next.

Stop and ask the user instead of guessing when:

- the item needs a decision listed under *Open* in
  `roadmap/decisions.md` that has not been made;
- the work would change a budget in SPEC.md §20.2, retire an item, or
  reorder the queue beyond moving a blocked row down;
- the *Done when* can only be met by CI or another machine. Commit what
  can be verified here, mark the row `waiting on CI` with what to check,
  and say so;
- the item's counts or budgets fail because of code it did not write.
  Profile where the cost lands and propose an item to fix that code
  first, rather than building on it: this is how the data-oriented
  design audit went ahead of stage 8.

## Where things go

| Change | Goes in |
|---|---|
| core engine and vocabulary | `core/src/<topic>.zig`; public names are exported from `core/src/root.zig` |
| a contract check (`zui`-prefixed declarations) | `core/src/contracts.zig` |
| core tests | `core/src/tests/<area>.zig`, imported from the `test` block of `core/src/root.zig`; shared helpers in `core/src/tests/support.zig` |
| a compile-error message | `core/tests/compile_errors/<case>.zig`, plus a row in `compile_error_cases` in `core/build.zig` with the complete message. Every message SPEC.md quotes has one |
| a new public API that is generic | exercised in `core/tests/instantiate.zig`, so `zig build check` type-checks it on every target |
| a module `zui_<name>` | `core/zui_<name>/zui_<name>.zig` and `core/zui_<name>/tests.zig`. In `core/build.zig`: `b.addModule`, the test loop, the `check` imports and `formatted_paths`. Also `.paths` in `core/build.zig.zon`, `core_modules` in the root `build.zig`, which re-exports it, and the import snippet in `README.md`. A module imports only its own directory and `@import("zui")` (SPEC.md §3.3) |
| a conformance suite (`expect*Conforms`) | `core/zui_testing/zui_testing.zig`, or `core/zui_testing/<contract>_conformance.zig` exported from it |
| a conformance harness | `src/conformance.zig` in a renderer's package, `<os>/conformance.zig` in `hosts/native/`, run by the package's `conformance` step. It keeps only its window, its renderer or host, and its read-back; a part two harnesses would repeat goes in `core/zui_testing/harness.zig` (`ReadBack`, `PolledRecord`), generic over the renderer and its text, with its tests in `core/zui_testing/tests.zig` |
| a benchmark scenario | `core/bench/bench.zig`; its budget, if any, comes from SPEC.md §20.2 |
| the Markdown formatter | `.mdformat.toml`, and `tools/mdformat/`: mdformat's pinned versions and the plugin that keeps the documents' style, run by `zig build fmt-md` through uv |
| a git hook | `.githooks/<hook>`, a POSIX `sh` script, which `zig build hooks` turns on; what it checks is listed in `docs/development.md` |
| CI | `.github/workflows/ci.yml`: jobs per package, run from its directory, with a leg for each OS it needs; a package's jobs run only when `changes` (`.github/scripts/affected_packages.py`, which reads every `build.zig.zon`) finds a change under it or a package it names by `.path`. Core's legs (optimize modes, compile errors, Tracy, ThreadSanitizer, `zui-debug`, 32-bit x86, cross-targets), `bench` and `counts` run from the root. A pure-Zig package is tested on Linux and cross-checked for Windows and macOS. A job that needs a display or a compositor is its own job; steps two jobs share go in `.github/actions/`. Every job and leg fits `timeout-minutes: 10`. Publishing the web host's page, `.github/workflows/pages.yml`, after CI passes and runs `hosts/web: test-site` |
| what font systems and renderers share: the layout of a run into positioned glyphs, the placement a renderer declares, the type-erased fonts a renderer draws through, the glyph atlas, the font systems' conformance suite | `text/glyphs/src/<topic>.zig`, exported from `text/glyphs/src/root.zig` (the `zui_glyphs` module, which the root re-exports); pure Zig, importing nothing but `std` |
| the default font system, `zui_truetype.Text` on stb_truetype | `text/truetype/src/`, the `zui_truetype` module, reached through `zui.builder.dependency("zui_truetype", …)` and never re-exported, since it builds stb; it lays text out only through `zui_glyphs` and never imports a renderer. stb_truetype is compiled in from `text/truetype/src/stb_truetype.c` without a C library on every target |
| a bundled typeface | `text/fonts/`, its file and licence beside `zui_fonts.zig`, which makes it a `pub const` of its `@embedFile` bytes and adds both to `.paths` in `text/fonts/build.zig.zon` |
| a new face, shaper or rasterizer | a package of its own beside `text/truetype/`, depending on `zui_glyphs`, and in the root's `packages`, `.paths` and `.dependencies` |
| the tour | `apps/tour/src/`, the `zui_tour` module, which the root re-exports: `zui_tour.App(.{ .Host, .Renderer, .Text, .renderer_name })` is the application `zui_app` runs. A screen is `apps/tour/src/screens/<name>.zig`, generic over the tour's `Kit` through `Using(kit)`, a field of `Screens` in `apps/tour/src/tour.zig` and a case of `Screen` in `apps/tour/src/shared.zig`; one that needs an optional command is offered only by `Kit.offers`. The tour imports no renderer, host or font system, and compiles for `wasm32-freestanding`. Its headless test is `apps/tour/src/tests.zig`, its compile errors `apps/tour/tests/compile_errors/<case>.zig` with a row in `compile_error_cases` in `apps/tour/build.zig` |
| the showcase | `apps/showcase/zui_showcase.zig`, the `zui_showcase` module, which the root re-exports: `zui_showcase.App(.{ .Host, .Renderer, .Text, .title })` is the application `zui_app` runs. It imports only `zui`, `zui_widgets`, `zui_app` and `zui_glyphs` |
| a target: a `main` that runs an app on a host, a renderer and a font system | `examples/<app>.zig` in the renderer's or host's package (`renderers/raylib/`, `renderers/terminal/`, `hosts/native/`; sokol's are `hosts/native/`'s), built as the step named after the app, `tour` or `showcase`. It names the app, the host, the renderer and the font system at one place, and adds only what its host or its flags need, such as screenshots or `--dump` |
| the design vocabulary: roles, tiers, `Design`, `Tokens`, the appearance contract | `core/src/design.zig`, exported as `zui.design`; its check in `core/src/contracts.zig` |
| an OS design language | `themes/src/<design language>.zig`, exported from `themes/src/root.zig` (the `zui_themes` module), with its tests beside it. It is a `zui.design.Design`, data the widgets reach through `zui_widgets.DesignSkin`: it imports only `zui`, its tests also `zui_design`, and it holds no drawing or OS code |
| the review of a component's permutations, and the workbench | `apps/review/`, the `zui_review` module, an app like the tour, generic over host, renderer and font system |
| the template project | `examples/template/`, a package of its own, so it can be copied out as a new app |
| a sample | `examples/samples/<name>/`, built and tested from `examples/build.zig` and imported from the `test` block of `examples/samples/root.zig`. A sample uses only the public APIs of zui, its modules, and the renderers and hosts, as a user would |
| a package | its own directory, with its `build.zig` and `build.zig.zon`, naming other packages by `.path`; in the root, a line in `packages` in `build.zig` and in `.paths` in `build.zig.zon`. A renderer or host package is also a `.path` entry in the root's `.dependencies`, so users reach it as `zui.builder.dependency("<name>", …)`; the root's `build()` never instantiates it |
| renderer changes | `renderers/<name>/`, which names `core/` by path, so it is tested in place from its directory: `renderers/raylib/`, `renderers/sokol/`, `renderers/terminal/`, `renderers/webgl/`. A renderer module imports `zui_glyphs`, never a font system: it takes the text it is given as `anytype`, erases it with `zui_glyphs.Fonts.of`, and draws where `zui_glyphs` lays the text out, declaring `glyph_placement` when it does not draw on the pixel grid |
| native hosts | `hosts/native/<os>/`, in the package `zui_host`, which names `core/` and `renderers/sokol/` by path, so it is tested in place from `hosts/native/`; its examples are `hosts/native/examples/` |
| the browser's drawing of a frame | `renderers/webgl/src/<topic>.zig`, reached from `renderers/webgl/src/root.zig` (the module `zui_webgl`); the page's WebGL 2 drawing of it, `renderers/webgl/web/frame_drawer.mjs`. It never imports anything of `hosts/web/` |
| the web client and, later, the web host | `hosts/web/src/<topic>.zig`, reached from `hosts/web/src/root.zig`, in the package `zui_web`, which names `core/`, `renderers/webgl/`, `apps/tour/` and `text/` by path, and `renderers/sokol/`, lazily, for `test-draw`'s reference drawing alone, so it is tested in place from `hosts/web/`. The tour's worker declares its frames for `zui_webgl.Renderer`, the browser's renderer |
| what the browser runs | reached from `hosts/web/src/browser.zig`, the client's WebAssembly exports, or `hosts/web/src/tour_worker.zig`, the tour's in a worker, which `zig build check` compiles for `wasm32-freestanding` |
| what only a check needs in the browser | `hosts/web/src/browser_wire_check.zig`, which adds exports to the client's for `zig build test-demo`; `hosts/web/web/check_*`, the pages and Node scripts the checks run |
| native programs the web checks run, such as the tour's stream | `hosts/web/tools/` |
| JavaScript and HTML glue | `hosts/web/web/` |
| the published page | `hosts/web/web/index.html` and what it loads, listed in `site_scripts` in `hosts/web/build.zig`, which `zig build site` writes with the client, the frame drawer, the worker and the fonts |

Everything under `renderers/webgl/src/` and `hosts/web/src/` that the
browser runs must compile for `wasm32-freestanding`: no `std.fs`,
threads or OS calls there.

Each stage's features and their layer are listed in `ARCHITECTURE.md`
§6. If an item puts something in a different layer, change §6 too.

## Keeping the documents current

In every item's commit:

- [ ] **ROADMAP.md, the queue:** the row's status. When the item is
  done, remove its row. When five or fewer open rows remain, add the
  next items from the next stage of SPEC.md §21, in dependency order,
  each labelled and entered in its group's file.
- [ ] **roadmap/<group>.md, the item:** a **Status** line saying what is
  done and what remains, and its row in the group's *Items* table. When
  it is done, the Status says so with what it measured, as
  `01-measure:01-bench-compare` and `01-measure:02-startup-benchmarks`
  are written, and the item stays where it is.
- [ ] **ROADMAP.md, *Where we are*:** when a stage finishes, or a budget
  measurement changes.
- [ ] **ARCHITECTURE.md §7:** remove a row the item closed; add one for
  any new difference between the code and the spec.
- [ ] **SPEC.md:** if the implementation shows the spec is wrong, fix
  the spec in the same commit and give the reason in the commit message.
  When an open question in §22 is settled, remove it there and record
  the outcome under *Made* in `roadmap/decisions.md`.
- [ ] **README.md:** the status list's line for the stage when a stage
  ships; the API example whenever the API it shows changes; the
  *Packages* table when a package is added. A package's feature, API,
  limit or build step goes in that package's `README.md`; a root step or
  a CI job, in `docs/development.md`.
- [ ] **docs/feature-tour.html and docs/feature-tour.md:** when a
  user-visible feature ships or its API changes, add or update its entry
  in both, with an example in a consumer's own code; move a feature out
  of *Declared but not working yet* once it works. The two files carry
  the same content and change together.
- [ ] **Doc comments** on every new or changed `pub` declaration.

A new item takes the next number in its group, and numbers are never
reused; *Labels* in `ROADMAP.md` explains how an item is named.

## Verifying

Run these from the repository's root, which runs core's steps under the
same names; another package's own steps run from its directory. In
`themes/`, `examples/`, `text/glyphs/`, `text/fonts/` and
`text/truetype/`, run `zig build test` in all three optimize modes and
`zig build check` (which, for the text packages, also compiles their
tests for `wasm32-freestanding`) before committing; `test-all` and
`check-all` run them from the root. In `apps/tour/` and
`apps/showcase/`, run `zig build test` in all three optimize modes,
`zig build check`, which also compiles the tour or the showcase's tests
for `wasm32-freestanding`, and the same `check` with
`-Dtarget=x86_64-windows`; the tour's `test` declares every screen
headlessly on renderers that draw every optional command and none, in
pixels and in cells, and checks its compile errors. In
`renderers/terminal/`, run `zig build test` (which runs `conformance`
too), `zig build check`, the same `check` with `-Dtarget=x86_64-windows`
and `-Dtarget=aarch64-macos`, `zig build showcase -- --dump`, which
prints the showcase's glyphs and must contain "zui + terminal", and
`zig build tour -- --dump --every-screen`, which prints every screen the
terminal is offered and fails when one cuts text short. Without `--dump`
the targets are interactive: never run them so outside a terminal of
their own (`script` under `timeout`, with `--frames`). In
`renderers/raylib/`, run `zig build test`, `zig build check` and
`zig build conformance`; the tour's cycle,
`zig build tour -- --hidden --frames 600 --cycle 50`, which must print
`diagnostics ok: true`; a screenshot of each of `overview`, `harbor`,
`x_ray`, `log_tail` and `light_lab` with
`zig build tour -- --screenshot <absolute path> --screen <name>`;
`zig build tour -- --measure-idle`;
`zig build showcase -- --hidden --frames 60`, which must print
`diagnostics ok: true`; and `check` with `-Dzui-tracy=true` and with
`-Dtarget=x86_64-windows`. Conformance and the targets open hidden
windows, so they need a display (CI runs them under `xvfb-run`); never
run a target without `--hidden --frames`, `--screenshot` or
`--measure-idle`, since its window stays open until closed. Its links on
Linux print `warning(link): unexpected LLD stderr` and still succeed. In
`renderers/sokol/`, run `zig build test`, `zig build check`, the same
`check` with `-Dtarget=wasm32-freestanding`, with
`-Dtarget=x86_64-windows` and with `-Dgl=true -Dtarget=x86_64-windows`,
and `zig build conformance`, which opens a window and must print that
`zui_sokol.Renderer` passes zui's renderer suite; its tour and showcase
are `hosts/native/`'s, below. After changing a shader's GLSL, run
`zig build shaders` and commit the regenerated `.glsl.zig`. Its links on
Linux print `warning(link): unexpected LLD stderr` and a
`failed command:` line and still succeed. In `hosts/native/`, start a
session bus of the tests' own
(`dbus-daemon --session --nofork --address=unix:abstract=/zui-host-test --print-address`,
kept running) and run with its address in `ZUI_HOST_TEST_SESSION_BUS`
`zig build test --summary all` and the same with
`-Doptimize=ReleaseSafe`, which skip only the test that needs
`ZUI_HOST_TEST_SHOWN_WINDOW` (without the bus, four are skipped);
`zig build check`, and the same with `-Dtarget=x86_64-windows` and
`-Dtarget=aarch64-windows`; `zig build services -- --check`, which must
print that every service answered; `zig build theme -- --check`, which
must print the frame it restyled in; the tour's cycle,
`zig build tour -- --frames 300 --cycle 30`, which must print
`0 layer overflows, 0 glyph atlas overflows, diagnostics ok: true`, also
after any change to the sokol renderer or the tour;
`zig build tour -- --measure-idle`; and
`zig build showcase -- --frames 60`, which must print
`diagnostics ok: true`. They need a Wayland compositor (CI runs a
headless Weston); never run an example without `--check`, `--frames` or
`--measure-idle`, since its window stays open until closed. Its links on
Linux print the same LLD noise. In `renderers/webgl/`, run
`zig build test` in all three optimize modes and `zig build check`,
which also compiles the tests for `wasm32-freestanding`. In
`hosts/web/`, run `zig build test` in all three optimize modes and
`zig build check`, which compiles the client and the tour's worker for
`wasm32-freestanding`, so a browser break fails there; and, each with
`timeout` in front: `zig build test-demo` (and with
`-Doptimize=ReleaseSafe`) after any change to the client,
`hosts/web/src/demo_ui.zig`, the tour's worker
(`hosts/web/src/tour_*.zig`, `hosts/web/src/stepped_io.zig`,
`hosts/web/web/tour_*.mjs`), core, `text/` or `apps/tour/`; it needs
Node. `zig build test-draw` after any change to how the client lays
frames out or the page draws them (`renderers/webgl/`), or to `text/`,
`apps/tour/` or the sokol renderer; it needs Node, Chromium
(`-Dbrowser=<path>` names another) and a display, and
`ZUI_WEB_DRAW_FAILURES=<dir>` keeps its failing frames.
`zig build test-input` after any change to how the client writes records
or the page reads input or applies host requests; it needs Node and
Chromium, run headless, and no display. `zig build test-site`, and
`zig build site -Doptimize=ReleaseSmall` with `test-site` in
ReleaseSmall, after any change to the published page, its service
worker, `hosts/web/web/tour_page.mjs` or what it loads, or
`site_scripts`; it needs Node and Chromium, run headless, and no
display, and the Pages workflow runs it before publishing.
`zig build test-host` after any change to the web host
(`hosts/web/src/host.zig`, `browser_host.zig`, `worker.zig`,
`shared_memory.zig`), its worker and page (`hosts/web/web/host_*.mjs`,
`tour.html`, `input_recorder.mjs`, `tour_thread.mjs`,
`shared_module.mjs`), `hosts/web/examples/`, `renderers/webgl/`, core or
`apps/tour/`; it needs Node and Chromium, run headless, and no display.
Chromium runs headless here, under `timeout`, and must leave no Chromium
process behind (`pgrep -af -- --headless`). Its tools that run the tour
natively print the same LLD noise.

| Command | When |
|---|---|
| `zig build test` | always; about 25 s |
| `zig build test -Doptimize=ReleaseFast` and `-Doptimize=ReleaseSafe` | before committing; CI runs all three |
| `zig build check -Dtarget=wasm32-freestanding` and `-Dtarget=powerpc-linux` | any change to `core/src/` (freestanding and big-endian) |
| `zig build test -Dtarget=x86-linux` | any index or hash arithmetic; catches 64-bit assumptions |
| `zig build test -Dzui-sanitize-thread=true` | any change to a source, an atomic or the conformance suite; on Linux only, so here in a container run with `--security-opt seccomp=unconfined` |
| `zig build test -Dzui-tracy=true` | any change to `zui_tracy` or the trace zones; fetches Tracy |
| `zig build test-all` and `zig build check-all` | any change a package other than core could feel; each runs the step in every package's directory |
| `zig build fmt` and `zig build fmt-md` | before committing; CI runs `fmt-check`, and the `pre-commit` hook checks staged Markdown |
| `zig build bench -- --check-targets` | any change to a hot path; in benchmarking mode, as SPEC.md §20.2's budgets are set |
| `zig build bench-compare -- <base>` | any change claiming a speedup or risking a slowdown |
| `zig build counts -- --compare <file>` | any change to a hot path; CI compares with the parent commit and fails on more than 2% growth |

- Every command, test run and CI job has a hard limit of 10 minutes:
  `timeout 600 zig build test`, `timeout-minutes` in CI. No test may
  wait without a bound. Work that does not fit is restructured, never
  given a longer limit.
- This machine dual-boots. On Windows, Valgrind and Callgrind do not
  run, but Docker does, so instruction counts are taken in a Linux
  container. On its bare-metal Linux install (Omarchy) they run
  natively, and so do hardware counters (`bench --counters`).
- On the Linux install, the owner switches the CPU between its normal
  mode (Turbo Boost on, the usual governor) and benchmarking mode (Turbo
  Boost off, `performance` governor on every core) with a shell command,
  `turbo`, which needs sudo. It toggles, so check the state first:
  `cat /sys/devices/system/cpu/intel_pstate/no_turbo` (1 is benchmarking
  mode) and `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`.
  When a measurement needs the other mode, ask the owner to run `turbo`
  rather than changing the settings yourself, and tell them when the
  measurement is done so they can switch back.
- Wall-clock times are judged only on one machine with `bench-compare`,
  never across runs or runners.
- A failing check is reported with its output, never skipped or relaxed
  to pass.
- Shell heredocs mangle `\n` in Zig string literals on this machine;
  edit Zig files with the Edit or Write tools.

## Rules the code keeps

- **No allocation after `init`.** The benchmarks fail on one.
- **Every limit fails the same way** (SPEC.md §17.2): keep what fits,
  report it in `Diagnostics`, never corrupt.
- **Every contract or configuration mistake is a `@compileError`** with
  an exact message, pinned by a compile-error test.
- **A module before core.** If it can be built on the public API, it
  goes in a module.
- **Pay only for what you declare.** A feature that is off, or a payload
  type that is `void`, generates no code.
- **Names over comments.** Comment only what is not obvious from the
  code, and do not reference other files or the spec in comments.
- LF line endings everywhere.

## Packages and the build

Zig 0.16's package manager behaves in ways that are easy to get wrong:

- **One `zui` module needs one set of options.** A package passes a core
  option to `b.dependency("zui_core", …)` only when the user gave it,
  leaving it `null` otherwise, never an explicit default such as
  `.@"zui-tracy" = false`. Two option sets instantiate core twice, and
  the build fails with "file exists in modules 'zui' and 'zui0'". So
  every package on core declares `zui-debug`, `zui-sanitize-thread` and
  `zui-tracy` (its build's `CoreOptions`) and passes all three to each
  package on core it depends on, and the root passes them to the
  packages it re-exports; the root's `check` compiles
  `tests/reexports.zig`, which imports `zui` and the apps together.
- **A renderer's or host's entry in the root `build.zig.zon` is not
  lazy.** With `.lazy = true`, `zui.builder.dependency(…)` panics ("must
  use the lazyDependency function"); a `.path` dependency fetches
  nothing anyway, and its own third-party libraries stay lazy.
- **A third-party library is lazy and reached with `lazyDependency`,**
  and a package declares its modules only once its libraries are
  fetched. A package that uses another's modules takes the dependency
  only once it has declared the module it needs, as the hosts'
  `sokolDeclaring` does, or it panics with "unable to find module" in
  CI's empty cache while passing here.
- **"Fetches nothing" is checked with an empty cache:**
  `zig build --help --global-cache-dir <empty dir>` after deleting any
  `zig-pkg/`. With the usual cache, Zig copies the lazy packages it
  already has into `zig-pkg/` without the network, and a fetch goes
  unnoticed.
- A dependency's build sees no `-- <args>` and installs into a prefix of
  its own, which is why the root runs and installs core's benchmark
  executables itself.
- A `.path` cycle (a package naming the root) crashes the toolchain
  before any `build()` runs.

## Commits

- Commit messages follow the history: an imperative subject without a
  prefix ("Add the tracer contract"), of at most 72 characters, and a
  body that says what changed and why, with measurements. The hooks in
  `.githooks/` (`zig build hooks`) check the message, the staged files'
  formatting, and the tests of what a push reaches; a refused commit is
  fixed, never retried with `--no-verify`.
- Work on `main`, as the history does. **Do not push or tag** unless the
  user says to in this session. Every package names `core/`, and any
  other package it uses, by path, so a change is built and tested
  against all of them in place: `zig build test-all` and
  `zig build check-all` run every package's steps.
