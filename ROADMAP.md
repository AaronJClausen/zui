# Roadmap

SPEC.md is the contract, and its §21 orders the work into stages by what
depends on what. The roadmap is how each stage is built and judged: its
items, what is known about each, and what decides that it is done.
ARCHITECTURE.md maps where each part lives.

This file holds what every session reads: where the work stands, the
queue, and how items are labelled and judged. Everything else is in
`roadmap/`, one file per group of items:

| File | Holds |
|---|---|
| [`roadmap/01-measure.md`](roadmap/01-measure.md) to [`roadmap/11-polish.md`](roadmap/11-polish.md) | one stage of SPEC.md §21 each: what it delivers, when it is done, and every item planned for it, finished or not |
| [`roadmap/12-font-system.md`](roadmap/12-font-system.md) | the font system, after stage 11, not yet in the queue |
| [`roadmap/13-later.md`](roadmap/13-later.md) | what is built only with a measured win or a demonstrated need, and what is not taken from Clay |
| [`roadmap/14-macos.md`](roadmap/14-macos.md) | macOS, set aside until the owner takes it up |
| [`roadmap/decisions.md`](roadmap/decisions.md) | the decisions made, and those still open |
| [`roadmap/former-ids.md`](roadmap/former-ids.md) | the letter IDs items had before, for commit messages and older reports |

Each item says:

- **Grounding:** what we know, with the code that shows it.
- **Plan:** what to change.
- **Done when:** the test or measurement that decides it.
- **Status:** what is done and what remains.
- **Spec:** the sections it implements.

## Labels

An item is named `{group}:{item}`, each part a number and a name:

```text
10-reach:04-window-decorations
│  │     │  └─ what the item is
│  │     └──── its place in the group
│  └────────── the group: stage 10 of SPEC.md §21, "Reach"
└───────────── the group's place in the build order
```

- **The group** is a stage of SPEC.md §21 under its number there (`01`
  to `11`), then the groups after the stages: `12-font-system`,
  `13-later` and `14-macos`. Its items live in `roadmap/<group>.md`.
- **The item's number** is its place in the group's planned order when
  it was written down; its name says what it builds. An item's heading
  is `## <label> — <title>`, so `grep -rn '^## 10-reach:04' roadmap/`
  finds it.
- **Labels are stable.** Commit messages and other documents cite them,
  so a label is never renamed or renumbered, even when the queue is
  reordered. A new item takes the next number in its group, and numbers
  are never reused, so a gap is an item that was merged. A retired item
  keeps its label and says why it was retired.
- A label is written in backticks wherever it is cited, in full, so that
  a search for it finds every mention.

## Where we are

| Release or stage | Scope | Status |
|---|---|---|
| 0.1 | layout core, text wrapping, measurement cache, render commands | shipped |
| 0.2 | input, focus, clipping, scrolling, floating, state | shipped |
| 0.3 | task pools, `needsFrame`, frames held by a render thread | shipped; task pools are deleted in stage 2 |
| 0.4 | `zui_widgets`, `zui_reflect`, `zui_testing` | shipped |
| 0.5 | layout performance, parallel measurement, benchmarks | shipped |
| after 0.5 | declaration work: −42% to −56% | on `main` |
| 0.6, in part | `bench-compare`, startup benchmarks, task completions at `beginFrame`, the async design | done; the rest of 0.6 became stage 1 |
| [1, measure](roadmap/01-measure.md) | instruction counts in CI, the tracer contract and `zui_tracy`; after stage 7, benchmarks that can be trusted | done; a commit compared with itself over three code layouts calls nothing, its intervals 0.52% wide on average, and a change that only moves code is not called |
| [2, the frame record](roadmap/02-frame-record.md) | the code brought to the spec's shape: `Context(config)`, the record's parameters, input as events, `endFrame` that always returns a frame, `TaskPool` deleted, `nextFrame`; letter spacing; the environment and host requests; sources in the core; `zui_async`; the backends on the new API, the demo's thumbnails on `KeyedLoads` | done; the demo idles at 0% CPU |
| [3, the contracts](roadmap/03-contracts.md) | the renderer contract and the generated commands; the host contract and `RecordBuilder`; the conformance suites; `Features`; `zui_app`; the raylib adapter host | done; the backends are renderers and pass the renderer suite in CI, raylib's host passes the host suite, and the demo runs through `zui_app`, presenting its first frame 288 ms after the process starts; lowering comes with stage 8's commands |
| [4, a native host](roadmap/04-native-host.md) | the Windows host, with dropped files and lifecycle events in the record; the system material; `zui_app` with the application's own text contract | done; the sokol renderer's tour runs on it unchanged, through `zui_app`, and idles at 0% CPU, and the same code shows Mica or a solid background |
| [5, the wire](roadmap/05-wire.md) | relay; `zui_wire`; replay in `zui_testing`; the wire host, renderer and client; file watching as a source | done; editing a theme file restyles a running window on the Windows host within 4 ms; a recorded session of the sokol renderer's tour replays to identical commands without starting any work, the sokol renderer's tour goes over the wire at a hundredth of its frames' whole size, but for the screen that moves every box, and it runs in one process and draws in another on the Windows host, its keys going back |
| [6, text and layout](roadmap/06-text-and-layout.md) | the single-line fast path, the whole-string cache, static styles, the box tree's layout, emission and declaration, line-break segmentation, the grow basis, aspect ratio and natural sizes, dividers and decorated images, floating options, right-to-left layout, wrap; the backends drawing images' tint and corner radius; after stage 7, the data-oriented design audit's findings | done; the box tree's and warm text's budgets met, as they were then judged with Turbo Boost on: the box tree declares in 48.9 µs and lays out and emits in 89.2 µs, warm text in 90.5 µs; a box tree of static styles declares in 28.0 µs; the raylib and sokol renderers draw tinted, rounded images and pass the renderer suite that checks them. The audit: a tooltip declared before a 3,000-cell grid lays out in 79 µs, not 671 µs; warm text −43%; `init` from 138 µs to 92 µs; the budgets judged in benchmarking mode |
| [7, gestures](roadmap/07-gestures.md) | arbitration by motion component, zoom, long press, double tap, momentum, the intents and custom recognizers; drag and drop between elements | done: a carousel in a list, a pinch starting on a list inside a map, a lasso module against a map's pan, and `zui_testing.Driver.drag` moving an item between two lists, out of one that scrolls by dragging |
| [8, effects](roadmap/08-effects.md) | gradients, shadows and glow; backdrop blur; effects in the corners of a decoration that draws nothing; transforms with hit inversion; materials; HDR and wide gamut | done: the sokol renderer draws gradients, shadows, backdrop blurs, transforms and materials through a shader of its own and passes the renderer suite, its effects rounded by a decoration that draws nothing, a pointer hits a turned button where it is drawn, and a frame without effects runs no more instructions than before; `zui.ExtendedColor` is clamped for a renderer that draws only `Color`, and on a monitor in HDR the Windows host opens the window in scRGB and reports its headroom, and the sokol renderer shows twice SDR white at 2.00× and four times it at 4.00×, measured off the desktop |
| [9, seeing the UI](roadmap/09-seeing-the-ui.md) | `zui_debug`; semantics and accessibility actions; safety sweeps; the demo in a browser | done: every `zui_widgets` control lists its semantics, and the Windows host bridges them to UI Automation with each control's pattern, its state and changes, and every action, so a client out of process toggles, sets, expands, selects, scrolls and invokes the native hosts' accessibility example; the sokol renderer's tour runs in a browser at the display's frame rate, from the published page, in a Web Worker behind a page that draws its frames over `zui_wire` and sleeps between the frames the tour needs; `Frame.inspect` and the inspector's diagnostics, fallbacks, zone times from its `ZoneTimer` tracer, element tree and hovered element's configs, and its theme reloaded from a watched file; the raylib renderer's tour opens it with F12 through `zui_app`'s `zuiObserve`, and draws every screen with it open within its limits |
| [10, reach](roadmap/10-reach.md) | Linux and web hosts; services; window decorations; many windows; hosts whose platform owns the loop | done: the Linux host passes the conformance suites on Wayland and X11, the tour runs on it unchanged and idles at 0% CPU, and the theme example restyles on a file change; the web host, services, window decorations, many windows and the platform-owned loop are done |
| [11, polish](roadmap/11-polish.md) | `zui_motion` and exit ghosts; the design system (SPEC.md §18); text editing with IME; `zui_color`, `zui_icons`, skins and theme packs; samples, the template and a profiling guide | in progress: `zui_motion`, exit animations, `zui_color`, the skin contract, the profiling guide, the design system's resolver, `zui_design`, the default design, motion in the core, the focus ring outside its control, the tour's 24-unit targets and italics are done |

No release is tagged; everything is on `main`. From here, work is
tracked by stage rather than by release number. Each stage may be tagged
when it is done.

Measured on the reference machine (i9-10900K) in benchmarking mode
(Turbo Boost off, 3.7 GHz, the `performance` governor), the fastest
frame at `9154f3f`, after the audit's `06-text-and-layout:14-layer-sort`
to `06-text-and-layout:18-string-cache-keys-apart`, against the budgets
of SPEC.md §20.2:

| Scenario | Declaration | `endFrame` | Budget |
|---|---|---|---|
| 4,096 boxes, depth 8 | 57.3 µs | 108.6 µs | layout and emission < 125 µs, declaration < 69 µs: both met |
| 1,000 texts, warm caches | 17.7 µs | 66.5 µs | < 150 µs: met |
| 4,096 boxes of static styles | 28.5 µs | 104.4 µs | |
| 4,000 children of one parent | 56.3 µs | 77.1 µs | |

These are the fastest of six runs (five for the last two rows) of
`zui-bench --core 3`, whose fastest box-tree frames were 57.3 to 58.1 µs
for declaration and 108.6 to 109.0 µs for layout and emission, and warm
text's 66.5 to 67.4 µs. Until `9154f3f` the budgets were 100 µs, 55 µs
and 120 µs and were judged with Turbo Boost on, where the box tree had
measured 48.9 µs and 89.2 µs after
`06-text-and-layout:05-box-tree-declaration-budget`. The owner moved
them to the mode `bench-compare` measures in, which is steadier
(turbo-on runs had drifted by 10% on the same instructions), scaling
each by 1.25, the box tree's own ratio of turbo-off to turbo-on time.

## The queue

Work is taken from the top. The first row whose status is not `waiting`
is the next item, and CLAUDE.md says how to take it on. An item too
large for one sitting lands in slices, each a commit with every check
green, and its **Status** line says which slice is next. An item's entry
is in the file its group names.

| Item | Where | Waits for | Status |
|---|---|---|---|
| `11-polish:31-rich-text-and-reordering` | `core/zui_widgets/` | `11-polish:28-containers-and-navigation`, `11-polish:06-text-editing` | waiting on `11-polish:06-text-editing` |
| `11-polish:32-zui-widgets-data` | `core/zui_widgets_data/` | `11-polish:29-overlays` | in progress: slice 2 (toolbar, status bar, command palette, property grid, the tour) |
| `11-polish:33-pickers` | `core/zui_widgets_data/` | `11-polish:32-zui-widgets-data` | |
| `11-polish:34-zui-widgets-views` | `core/zui_widgets_views/` | `11-polish:30-feedback-and-media` | |
| `11-polish:39-frame-snapshots` | `core/zui_testing/`, `apps/test_card/` | `11-polish:38-test-card` | waiting on CI: `apps/test_card: snapshots` on Windows and macOS |
| `11-polish:40-terminal-snapshots` | `renderers/terminal/`, `apps/test_card/` | `11-polish:39-frame-snapshots` | waiting on CI: the terminal job's `--dump --check` on Windows and macOS |
| `11-polish:41-pixel-hashes` | `apps/test_card/`, `renderers/raylib/`, `hosts/native/`, `.github/`, `tools/ci/` | `11-polish:39-frame-snapshots` | |
| `11-polish:42-scripted-input` | `apps/test_card/`, `renderers/raylib/`, `renderers/terminal/`, `hosts/native/` | `11-polish:39-frame-snapshots` | |
| `11-polish:43-test-card-review` | `apps/test_card/` | `11-polish:41-pixel-hashes` | |
| `11-polish:44-test-card-on-the-web` | `hosts/web/`, `apps/test_card/` | `11-polish:39-frame-snapshots` | |
| `11-polish:22-appearance-review` | `apps/review/` | `11-polish:20-appearance-audit`, `11-polish:21-permutations` | |
| `11-polish:23-design-workbench` | `apps/review/` | `11-polish:22-appearance-review` | |
| `11-polish:06-text-editing` | `core/src/`, `core/zui_widgets/`, `hosts/native/` | | |
| `11-polish:10-samples` | `examples/` | `11-polish:09-template-project` | |
| `11-polish:12-developer-experience-audit` | `examples/`, `README.md`, `docs/` | `11-polish:09-template-project`, `11-polish:10-samples` | |

Stage 11's rows follow stage 10's, in dependency order, the design
system's first (`roadmap/11-polish.md`, *The design system*), by the
owner's choice. The default design's components follow it, items 27 to
36, from the plan in `docs/plans/default-ui-designs/`, whose `exports/`
hold each component's approved spec. The test card's items, 38 to 44,
from `docs/plans/test-card.md`, follow the components, by the owner's
choice, ahead of the appearance review, whose permutations the card's
review mode may later show. The design system's items have their
Grounding, Plan and Done when; each of stage 11's other items is given
them as it is taken.

The font system
([`roadmap/12-font-system.md`](roadmap/12-font-system.md)) has no rows
yet; its items join the queue when the owner orders them.

macOS is not in the queue. Its work is set aside in
[`roadmap/14-macos.md`](roadmap/14-macos.md), and none of it is built
until the owner chooses to take up macOS. Until then, a progress report
leaves it out.

Statuses: `next` (the first open row), `in progress` (a slice has
landed), `waiting on <what>` (blocked by something the next session
cannot do: a decision, CI, a push), or empty (not started). A finished
item's row is removed, and its group's *Items* table and its own
**Status** say it is done. An item whose remaining work is waiting on CI
or a person counts as done for the rows that wait for it, as long as
what they need from it has landed.

Things to know:

- **Judge each item against its parent commit,** in benchmarking mode:
  `zig build bench-compare -- HEAD --require-quiet` compares the working
  tree with the last commit. A base from before `4294abe`
  (`01-measure:07-shuffled-scenarios`) is compared one whole run at a
  time, and one from before `c24f34b`
  (`01-measure:09-layout-as-random-factor`) in a single code layout,
  which where the code lands can move by several percent, so older bases
  such as `a6d8e34` are history, not a judge.
- **Measure one thing at a time.** Compile nothing while a measurement
  runs. `bench-compare` writes its progress to stderr, which `zig build`
  drops once the step succeeds; the report says which mode ran. The
  noise bands live in `.zig-cache/bench-compare/noise-floor.json`, keyed
  by the machine's fingerprint; `--calibrate` again after changing the
  setup.
- **The spec is already written.** Every item implements sections of
  SPEC.md that exist; an item that finds the spec wrong changes it in
  the same commit, with the reason.
- **The code has the spec's shape where the feature exists.** What is
  still missing is listed in ARCHITECTURE.md §7 with the item that adds
  it. With `TaskPool` deleted, outside data reaches a frame only through
  sources: `zui_async`'s (`02-frame-record:12-zui-async`) or the
  application's own (`02-frame-record:11-sources-in-core`).
- **A core change reaches every renderer and host at once.** Every
  package names `core/` by path, and `zig build test-all` tests them all
  with the change; the raylib renderer's tour, run from
  `renderers/raylib/`, checks the idle budget with `--measure-idle` and
  the trace with `-Dzui-tracy=true`, and the web host's checks, run from
  `hosts/web/`, draw and run the tour in a browser.
- **`bench --check-targets` checks §20.2's budgets,** including
  declaration for the box tree, judged in benchmarking mode (Turbo Boost
  off, the `performance` governor), the mode `bench-compare` measures
  in. Times vary by machine; instruction counts (`zig build counts`,
  `01-measure:03-instruction-counts-in-ci`) do not, and CI fails on more
  than 2% growth over the parent commit; the simulated misses beside
  them (`01-measure:10-simulated-misses`) show direction and never fail.
  They need Valgrind, so on Windows take them in a Linux container.

## How stages ship

- **Measure first.** Stage 1 gave every later change an instruction
  count no machine can move. Its times did not hold: unpinned, judged by
  a hand-set 2%, and in one code layout, they could not tell a change of
  a few percent from where the code landed. `01-measure:05-pinned-runs`
  to `01-measure:10-simulated-misses` made them trustworthy before the
  audit's work was judged by them.
- **Fix the foundation before building on it.** When an item's counts or
  budgets fail because of the code under it rather than its own, that
  code is profiled and fixed first, as items of their own.
  `08-effects:01-gradients-shadows-glow` is why the audit's findings
  went ahead of stage 8.
- **One breaking change, made once.** Stage 2 changes the shape of
  `Context`, the frame record, input and outside data together, and
  stage 3 adds the contracts on top, before any native host or wire
  format can freeze the old shapes. Every backend, `zui_testing` and
  `core/bench/` are updated in the same week, and the notes say what to
  change.
- **Prove each contract twice.** An adapter proves it in stage 3; a
  native host proves it again in stage 4, because a contract with one
  implementation is not yet a contract.
- **After stage 3, new commands never break renderers.** Optional
  commands are lowered by the core for renderers that do not declare
  them, which is why effects can come in stage 8.
- **A module before core.** A feature that can be built on the public
  API is; the core gains only what a module proves it cannot do without.
- **Items may land early** once their prerequisites have.
  `06-text-and-layout:01-single-line-fast-path` and
  `06-text-and-layout:02-whole-string-cache`, for example, need only
  stage 1.
- **A speedup ships with its measurement,** and one that is not measured
  does not ship.
