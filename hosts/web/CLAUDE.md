# Working on zui-web

zui-web is zui in the browser. It is filled by roadmap items V4 (the demo
in a browser: a thin client that draws frames streamed over zui_wire,
published from CI) and later H5 (a web host with a canvas surface, using
`tryBeginFrame` since it cannot block). The wire client comes first
(zui's ROADMAP.md, Decisions, Open #2).

zui's `ROADMAP.md` is the queue; this repository has none of its own.
Read the item's entry there, and the SPEC.md sections it names, before
starting. zui's `CLAUDE.md` holds the rules every zui repository keeps (no
allocation after `init`, every limit fails the same way, pay only for what
you declare); they hold here too.

## Where things go

| Change | Goes in |
|---|---|
| the client and, later, the host | `src/<topic>.zig`, reached from `src/root.zig` |
| what the browser runs | reached from `src/browser.zig`, the client's WebAssembly exports, or `src/tour_worker.zig`, the tour's in a worker, which `zig build check` compiles for `wasm32-freestanding` |
| what only a check needs in the browser | `src/browser_wire_check.zig`, which adds exports to the client's for `zig build test-demo`; `web/check_*`, the pages and Node scripts the checks run |
| native programs the checks run, such as the tour's stream | `tools/` |
| JavaScript and HTML glue | `web/` |
| the published page | `web/index.html` and what it loads, listed in `site_scripts` in `build.zig`, which `zig build site` writes with the client, the worker and the fonts |
| CI | `.github/workflows/ci.yml`; publishing the page, `.github/workflows/pages.yml` |

Everything under `src/` that the browser runs must compile for
`wasm32-freestanding`: no `std.fs`, threads or OS calls there.

## Verifying

Run each with `timeout 590` in front:

| Command | When |
|---|---|
| `zig build test` | always |
| `zig build test -Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` | before committing; CI runs all three |
| `zig build check` | always; it also compiles the client for `wasm32-freestanding`, so a browser break fails here and in CI |
| `zig build test-demo` | any change to the client, `src/demo_ui.zig`, the tour's worker (`src/tour_*.zig`, `src/stepped_io.zig`, `web/tour_*.mjs`), or the zui or zui-sokol pin; needs Node, and in CI runs on Linux |
| `zig build test-draw` | any change to how the client lays frames out or the page draws them, or to the zui or zui-sokol pin; needs Node, Chromium (`-Dbrowser=<path>` names another) and a display, and in CI runs on Linux under Xvfb. Agents may run Chromium headless here, under `timeout`, leaving no Chromium process behind |
| `zig build test-input` | any change to how the client writes records or the page reads input or applies host requests, or to the zui or zui-sokol pin; needs Node and Chromium, run headless, and no display; in CI runs on Linux with Google Chrome |
| `zig build test-site` | any change to the published page, its service worker, `web/tour_page.mjs` or what it loads, or `site_scripts`; needs Node and Chromium, run headless, and no display; in CI runs on Linux with Google Chrome, and the Pages workflow runs it before publishing |
| `zig build fmt` | before committing; CI runs `fmt-check` |

- Every command, test run and CI job has a hard limit of 10 minutes
  (`timeout-minutes: 10` on every CI job). No test may wait without a
  bound. Work that does not fit is restructured, never given a longer limit.
- A failing check is reported with its output, never skipped or relaxed.
- There are no git hooks; CI enforces everything.

## The zui pin

`build.zig.zon` pins zui by commit. Develop against a local checkout with
`zig build test --fork=../zui`. A commit here can only pin a zui commit
that is pushed: move the pin with
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`,
in the same commit as the code that needs it. Keep it the commit
zui-sokol's pin names, since `test-demo` builds the tour with zui-sokol's
zui and `--fork=../zui` can fork only one zui package. Keep the `stb` pin
zui-sokol's too: the client compiles the same stb_truetype, so its glyphs
are zui-sokol's.

## Workflow

- One worktree per item or slice:
  `git worktree add .worktrees/<item> -b <item> origin/main`
  (`.worktrees/` is ignored). Commit there, merge into `main` with
  `git merge --no-edit`, push, then remove the worktree and the branch,
  locally and on origin.
- Commit messages follow the history: an imperative subject without a
  prefix ("Draw wire frames on a canvas"), and a body that says what changed
  and why, with measurements where there are any.
- Do not push or tag unless the user says to in this session.
- LF line endings everywhere (`.gitattributes` and `.editorconfig` enforce it).
- A new top-level directory goes in `.paths` in `build.zig.zon`, and in
  `formatted_paths` in `build.zig` if it holds Zig.
- Names over comments. Comment only what is not obvious from the code.
- `README.md` stays current: its status when an item lands, its commands
  table when a build step changes. When an item finishes, zui's ROADMAP.md
  and ARCHITECTURE.md §8 are brought up to date in zui.
