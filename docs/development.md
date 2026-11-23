# Development

The engine and its modules are the package in `core/`; the repository's
root is the package `zui` that users fetch, which re-exports core's
modules and runs core's steps under the same names. Every other package
is a directory of its own, listed in the
[README](../README.md#packages), naming `core/` and any other package it
uses by path, so a change is built and tested against all of them in
place.

Each package has its own `test` and `check`, run from its directory, and
the root's `test-all` and `check-all` run them all. A package's own
README lists its steps and what they need:
[raylib](../renderers/raylib/README.md#development),
[sokol](../renderers/sokol/README.md#development),
[terminal](../renderers/terminal/README.md#development),
[WebGL](../renderers/webgl/README.md#development),
[the native hosts](../hosts/native/README.md#development),
[the web host](../hosts/web/README.md#development),
[the tour](../apps/tour/README.md#development) and
[the text packages](../text/README.md#development).

## The root's steps

Run these from the root:

| Command | What it does |
|---|---|
| `zig build test` | run the unit, golden, randomized-invariant, widget and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build test-unit`, `test-compile-errors` and `check-bench-tools` | the three parts of `test`: the unit tests, in the selected optimize mode; every compile error's message; and the benchmark tools, each built in its own fixed mode |
| `zig build test-unit-1` and `test-unit-2` | the two shards of `test-unit`, which CI runs as jobs of their own in ReleaseSafe and ReleaseFast: each test binary compiles zui again, and a release build of all of them takes nine minutes on a macOS runner. The first holds zui's own tests, the longest to build, with the cheap ones |
| `zig build check` | compile one full frame, every widget, the default sources and the test driver without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
| `zig build test -Dzui-tracy=true` | fetch Tracy and test `zui_tracy` with its client linked |
| `zig build test -Dzui-sanitize-thread=true` | run the tests under ThreadSanitizer, through LLVM, on Linux; ThreadSanitizer needs ASLR entropy of at most 28 bits (`sysctl vm.mmap_rnd_bits=28`), or a container started with `--security-opt seccomp=unconfined` |
| `zig build bench` | run the benchmarks in ReleaseFast and print each phase's fastest, median and 95th-percentile frame; add `-- --check-targets` to fail on a missed performance target, `-- --core <n>` to pin to one core at a raised priority, `-- --machine-json <path>` to record the machine's state, `-- --scenario <name>` (see `-- --list-scenarios`) to run only some scenarios, or `-- --counters` to count each phase's cycles, instructions and cache and branch misses (Linux on bare metal); `ZUI_BENCH_LAYOUT_SEED=<n>` moves the stack and each `Context`'s memory, and `-Dbench-layout-seed=<n>` moves the code; `-- --results-dir <dir>` keeps the times and the machine they came from for `bench-report` |
| `zig build bench-report -- <dir> [<commit>]` | set side by side each machine's results for one commit, each normalized to its own box tree, and name the scenarios whose relative cost differs most between machines (see [Comparing machines](benchmarking.md#comparing-machines)) |
| `zig build counts` | count each benchmark's instructions per frame under Callgrind, on x86_64 Linux with Valgrind (on Windows, in a Linux container), with simulated cache and branch misses beside them; add `-- --json counts.json` to save them and `-- --compare counts.json` to fail on more than 2% growth in instructions (misses are informational) |
| `zig build bench-compare -- main` | run the benchmarks of `main` and of the working tree alternately, pinned to one core, until each time's change is known closely enough; report each change with its 95% interval, calling it only beyond this machine's noise band; the rounds take turns with 3 layouts of code and memory (`-- --layouts <k>`), so a change that only moves code is not called; `-- --metric cycles` or `instructions` compares hardware counts instead of times; `-- <base> <head>` compares two commits (SPEC.md §20.3) |
| `zig build bench-install` | install the benchmark executable into `zig-out/bin`, as `bench-compare` does to run one scenario at a time; a base from before this step is compared one whole run at a time instead, which a scenario's position in the run can bias |
| `zig build bench-compare -- --calibrate` | compare `HEAD` with itself and save each time's noise band for this machine's setup; run it once per machine, and again after changing the setup |
| `zig build docs` | generate API documentation into `zig-out/docs` |
| `zig build test-all` | run `zig build test` in every package's directory, each as a process of its own |
| `zig build check-all` | run `zig build check` in every package's directory; `-Dtarget` and `-Doptimize` are passed on |
| `zig build fmt` | format every Zig source file |
| `zig build fmt-check` | fail if any file is not formatted, as CI does |
| `zig build fmt-md` | format every Markdown file with mdformat, run through [uv](https://docs.astral.sh/uv/) (see *Markdown*, below) |
| `zig build fmt-md-check` | fail if any Markdown file is not formatted, as the `pre-commit` hook does for what is staged |
| `zig build ci` | run CI's jobs for what `HEAD` changes since its upstream branch, on this machine (see *CI on this machine*, below); `-- --help` lists its options |
| `zig build hooks` | have git run the hooks in `.githooks/` (sets `core.hooksPath`), and `git blame` skip the commits in `.git-blame-ignore-revs`; run it once per clone |

## Markdown

`zig build fmt-md` runs mdformat over every Markdown file, with the
settings in `.mdformat.toml`, the plugin in `tools/mdformat/` and every
Python package pinned there; uv fetches them the first time. It wraps
paragraphs at 72 columns, fitting as many words on each line as will
fit, and writes tables without padding, so a long cell does not widen
every row. The plugin keeps the documents' own style where mdformat's
differs: an ordered list numbered from its first item, each item's text
indented to its own marker, a thematic break as `---`, and a table's
delimiter row as `|---|---|`. mdformat refuses to write a file that
would render differently, so formatting never changes what a document
says.

Two things it shows rather than hides:

- A sub-list or paragraph inside a numbered item must be indented to the
  item's text, 3 spaces under `1.` and 4 under `10.`. Indented less, it
  ends the list, and the next item starts a new list, which keeps its
  number.
- A line break inside a paragraph is lost when it is rewrapped; one that
  must stay ends its line with `\`.

## Git hooks

`zig build hooks` turns on three hooks, kept in `.githooks/`.
`--no-verify` skips the one for a commit or a push. Claude Code cannot:
`.claude/settings.json` runs
`.claude/hooks/refuse-skipping-git-hooks.sh` before each of its shell
commands, which refuses `--no-verify`, `git commit -n` and any change to
`core.hooksPath`, outside a heredoc's body.

- **`pre-commit`**, under a second for most commits: on what is staged,
  not the working tree, it fails on whitespace errors and conflict
  markers (`git diff --cached --check`), on anything under `zig-out/`,
  `.zig-cache/` or `zig-pkg/`, on a file over 1 MiB, and on a `.zig` or
  `.zon` file that `zig fmt` would change or that `zig ast-check`
  rejects, and on staged Markdown that `zig build fmt-md` would change
  (all of it when `.mdformat.toml` or `tools/mdformat/` is staged),
  which needs uv. It also fails when a change leaves out a file that
  must come with it: a new case in `core/tests/compile_errors/` or
  `apps/tour/tests/compile_errors/` without that package's `build.zig`;
  a changed `.glsl` in `renderers/sokol/src/` without its `.glsl.zig`; a
  new `core/zui_<name>/zui_<name>.zig` without `core/build.zig`,
  `core/build.zig.zon` and the root's `build.zig`. When `core/`,
  `tests/` or the root's build files are staged, it runs
  `zig build check` on the working tree, 2 to 4 s. It warns, without
  failing, when a `pub` declaration in `core/src/` changes with no
  Markdown staged, and when `ROADMAP.md` changes with nothing in
  `roadmap/`.
- **`commit-msg`**: fails on a Conventional Commits prefix (`feat:`), a
  subject over 72 characters or ending in a period, and a body that does
  not start after a blank line; it warns on a subject that starts with a
  past or progressive verb ("Added", "Adding"). Merges, reverts and
  `fixup!` commits pass. A refused message is kept in
  `.git/zui-rejected-commit-msg`.
- **`pre-push`**: runs CI on this machine (below) for each pushed ref,
  on the pushed commit against the one the remote has, and refuses the
  push when a leg fails. A new branch, or a remote commit this clone
  does not have, runs every job.

## CI

CI runs on every push that changes something a build reads (a push of
only Markdown, `docs/`, `assets/`, `LICENSE`, `.editorconfig`,
Dependabot's settings or the Pages workflow runs nothing). Its first
job, `changes`, runs `.github/scripts/affected_packages.py`, which reads
each package's `build.zig.zon` and names the packages the change
reaches: a package's jobs run when a file under it, or under a package
it names by `.path`, directly or not, changed. A change to `ci.yml`,
`.github/actions/` or `.github/scripts/`, a new branch or a manual run
reaches every package. Each job, from its package's directory, fits
within 10 minutes:

- the root, on every run: the format check, the documentation, and
  `check`, which compiles core and the apps through the root's
  re-exports;
- core, from the root, when `core/` or the root's build changes: `test`
  (the unit tests in Debug, the compile errors and the benchmark tools)
  on Linux, Windows and macOS; each of `test-unit`'s two shards in
  ReleaseSafe and in ReleaseFast there, a job apiece; `test-unit` as a
  32-bit x86 Linux program in Debug, and its shards in ReleaseFast;
  `test-unit` under ThreadSanitizer, which stresses every `zui_async`
  source with producers on other threads, and with Tracy's client on
  Linux, Windows and macOS; the whole `test` with `-Dzui-debug=true`;
  and, in one job, `check` for six targets: 32- and 64-bit, big-endian,
  freestanding and WebAssembly;
- with core's jobs, the benchmarks, failing on any allocation after
  `init` (times and the SPEC.md §20.2 budgets are reported in the job
  summary but not compared: runners vary too much, so check for
  slowdowns on your own machine with `zig build bench-compare`), and
  instruction counts of this commit and of the commit the push or pull
  request is based on, failing on more than 2% growth, with simulated
  cache and branch misses reported beside them;
- `text/glyphs/`, `text/fonts/`, `text/truetype/`, `apps/showcase/`,
  `apps/tour/`, `themes/`, `examples/` and `renderers/webgl/`, which are
  pure Zig and compile for `wasm32-freestanding`: on Linux, three jobs
  for each, its tests in Debug with `check` there and for x86-64 Windows
  and ARM64 macOS, and its tests in each release mode; `text/truetype/`,
  which compiles stb_truetype's C, is also tested on Windows;
- `renderers/raylib/`: its tests and `check` on Linux, Windows and
  macOS, and `check -Dzui-tracy=true` on Linux; and in a job of its own
  on Linux, under `xvfb-run`, its conformance, the `tour` target's visit
  of every screen, five screenshots, the CPU the tour uses while idle,
  shown in the job summary, and the `showcase` target's frames. Only
  Linux runners give it OpenGL 3.3, through Mesa;
- `renderers/sokol/`: its tests and `check` on Linux, Windows and macOS,
  its `check` for `wasm32-freestanding` on Linux and with `-Dgl=true` on
  Windows; and its conformance, which reads back through OpenGL, in a
  job of its own on Linux under `xvfb-run`;
- `renderers/terminal/`: its tests, its conformance, its `check`, the
  `showcase` target's `--dump`, and the `tour` target's
  `--dump --every-screen`, which fails when a screen cuts a line of text
  short at the side of its clip, on Linux, Windows and macOS;
- `hosts/native/`: its tests in Debug and ReleaseSafe and its `check`,
  on Windows, and on Linux under a headless Weston with a D-Bus daemon
  of its own (`.github/actions/wayland-session`), where `check` for
  ARM64 Windows runs too; and in a job of its own under Weston, the
  `theme` example's `--check`, the `tour` target's visit of every
  screen, which must report no layer or glyph atlas overflow and clean
  diagnostics, its CPU while idle, shown in the job summary, and the
  `showcase` target's frames. A headless Weston has no seat, so no
  clipboard, and the `services` example's `--check` runs on a desktop,
  as the Windows examples do;
- `hosts/web/`: on Linux, its tests in Debug with `check` there and for
  x86-64 Windows and ARM64 macOS, its tests in each release mode,
  `test-demo` in Debug and in ReleaseSafe, and `test-input`, each in a
  job of its own; `test-site` in headless Google Chrome; and `test-draw`
  under `xvfb-run`, its reference drawn by llvmpipe and compared with
  its allowance, keeping the frames that do not match as the run's
  artifacts. `test-host`, the tour on the web host in headless Chromium,
  has no job yet and runs locally.

Every job sets Zig up through `.github/actions/setup-zig`, which turns
off Windows Defender's real-time scanning on Windows, where it slows
every build, and keeps a cache of Zig's for each job, OS and the leg its
`cache-key` names. A repository's caches are held to 10 GB, and a run
saves one of each, so legs that share most of their build share a key (a
package's legs, the shards of one optimize mode), and the quickest jobs
keep none. Zig never deletes what its cache no longer needs, so each key
also names the day (UTC): a run restores the cache saved earlier that
day, and a day's first run starts cold, rather than every cache growing
by each run's builds until setup-zig empties it at 2 GiB.

When CI passes on a push to `main` and its `test-site` job ran, the
Pages workflow builds the site in ReleaseSmall, runs `test-site` on it,
and publishes it; `workflow_dispatch` publishes without asking CI.

Those targets exist to catch assumptions about the host machine early:
the first 32-bit build found two places that used a 64-bit hash as an
index.

## CI on this machine

`zig build ci`, and the `pre-push` hook, run `tools/ci/local_ci.py`
through uv. It reads `.github/workflows/ci.yml` from the commit it
tests, runs the `changes` job's script to find the affected jobs,
expands each job's matrix and runs its legs side by side
(`-- --jobs <n>`), each within its job's `timeout-minutes`:

- a Linux leg runs its steps in an Ubuntu 26.04 container, the one
  `ubuntu-latest` runs, built from `tools/ci/Dockerfile`, with Zig,
  Node, Google Chrome and every package the workflow and its actions
  `apt-get install`; the image is built once for each set of packages.
  Its build cache is kept in `.git/local-ci/container-cache`, apart from
  this machine's;
- a Windows or macOS leg, which cannot run here, becomes
  `zig build check -Dtarget=x86_64-windows` or `aarch64-macos`, with the
  leg's other `-D` options, run here. A cross-check analyses the code
  without linking it, and catches what only that target rejects, but
  runs no test, so a Windows-only timing or a macOS-only crash is still
  CI's to find. sokol's macOS check needs macOS's SDK, and is skipped.

It tests a commit, never the working tree, in a worktree of its own at
`.git/local-ci/worktree`, kept between runs so its caches stay warm, and
keeps the last runs' logs in `.git/local-ci/runs/`; a failing leg's log
ends the report. `-- --all` runs every job, `-- --only <regex>` the legs
whose names match, `-- --list` names them without running them, and
`-- --base <commit> --head <commit>` tests another change. It needs uv
and Docker, which the user must be able to reach without `sudo`.

Why the benchmarks are trusted, and how to profile, quiet the machine
and compare machines, is in [benchmarking.md](benchmarking.md).

## Conformance suites

A renderer or host proves its contract by running zui's suite in its
package's CI job. Each suite takes a harness: a value that gives the
suite what only the implementation knows how to do, such as making a
drawing target and reading its pixels back, or making the OS report an
event.

```zig
// src/conformance.zig, a test root importing the backend and zui_testing
test "the renderer passes zui's renderer suite" {
    var harness: MyHarness = undefined; // declares config, renderer, beginDraw, and pixel when it can read back
    harness.init();
    defer harness.deinit();
    try zui_testing.expectRendererConforms(MyRenderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
}
```

The recipe the backends follow:

- `src/conformance.zig` holds the harness and the test, built by a
  `conformance` step in `build.zig`. The harness keeps only what is the
  backend's own: its window, its renderer and how it reads a frame back.
  What harnesses share is `zui_testing`'s: `ReadBack(.sdr)` and
  `ReadBack(.scrgb_fp16)` hold a frame read back in either row order and
  answer `pixel` and `extendedPixel`, and `PolledRecord` is the record a
  host's own tests poll into;
- CI runs `zig build conformance`, under `xvfb-run --auto-servernum` on
  Linux when the backend needs a window for its graphics context;
- a backend whose test step needs no display adds `conformance` to
  `test` too, as the terminal renderer does.

`zui_testing.findRendererViolation` and `findHostViolation` return the
first violation instead of failing, and the doc comments of
`expectRendererConforms` and `expectHostConforms` list what a harness
declares. `renderers/raylib/`, `renderers/sokol/` and
`renderers/terminal/` each have a `src/conformance.zig` to copy.

## Line endings

The repository uses LF line endings everywhere (see `.gitattributes`),
whatever your `core.autocrlf` setting.
