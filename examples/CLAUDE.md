# Working on zui-examples

zui-examples holds a template project and samples for zui. It is filled
by roadmap items D1 (the template), D2 (samples: a settings screen with
zui_reflect and ZON, a data feed, a multi-window tool, a remote session)
and D3 (a developer-experience audit of building each sample from the
docs alone).

zui's `ROADMAP.md` is the queue; this repository has none of its own.
Read the item's entry there, and the SPEC.md sections it names, before
starting. zui's `CLAUDE.md` holds the rules every zui repository keeps (no
allocation after `init`, every limit fails the same way, pay only for what
you declare); they hold here too.

## Where things go

| Change | Goes in |
|---|---|
| the template project | `template/`, its own package (`build.zig`, `build.zig.zon`) so it can be copied out as a new app |
| a sample | `samples/<name>/`, built and tested from `build.zig` and imported from the `test` block of `samples/root.zig` |
| CI | `.github/workflows/ci.yml` |

A sample uses only public APIs of zui, its modules, and the published
renderers and hosts, as a user would.

## Verifying

Run each with `timeout 590` in front:

| Command | When |
|---|---|
| `zig build test` | always |
| `zig build test -Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` | before committing; CI runs all three |
| `zig build check` | always; CI runs it on Linux, Windows and macOS |
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
in the same commit as the code that needs it.

## Workflow

- One worktree per item or slice:
  `git worktree add .worktrees/<item> -b <item> origin/main`
  (`.worktrees/` is ignored). Commit there, merge into `main` with
  `git merge --no-edit`, push, then remove the worktree and the branch,
  locally and on origin.
- Commit messages follow the history: an imperative subject without a
  prefix ("Add the settings sample"), and a body that says what changed
  and why, with measurements where there are any.
- Do not push or tag unless the user says to in this session.
- LF line endings everywhere (`.gitattributes` and `.editorconfig` enforce it).
- A new top-level directory goes in `.paths` in `build.zig.zon`, and in
  `formatted_paths` in `build.zig` if it holds Zig.
- Names over comments. Comment only what is not obvious from the code.
- `README.md` stays current: its status when an item lands, its commands
  table when a build step changes. When an item finishes, zui's ROADMAP.md
  and ARCHITECTURE.md §8 are brought up to date in zui.
