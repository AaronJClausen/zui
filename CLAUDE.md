# Working on zui

zui is an immediate-mode UI engine for Zig 0.16. Four documents govern it,
and each has one job:

| Document | Its job | Changes when |
|---|---|---|
| `SPEC.md` | the contract: what zui is, every API, every budget | the implementation proves it wrong, or an open question (§22) is settled |
| `ROADMAP.md` | **the queue** of work, each item's plan and test, and what is done | every item, every slice of an item |
| `ARCHITECTURE.md` | the map: which layer and repository holds each part, and how today's code still differs from the spec (§7) | a difference closes or opens, or a feature moves layer or stage |
| `README.md` | what a user sees: status, today's API, the build commands | a stage or a user-visible API ships, or a build step changes |

The code and these documents move together. A commit that changes one and
leaves another stale is not done.

## "Tackle the next item"

1. **Find it.** Open `ROADMAP.md`, section *The queue*. Take the first row
   whose status is not `waiting`. An `in progress` row is continued, not
   restarted: its item's **Status** says which slice comes next.
2. **Read it.** Read the item's entry in `ROADMAP.md` (Grounding, Plan,
   Done when), every SPEC.md section it names, and the files in its
   *Where* column. Check the *Waits for* column; if a prerequisite is not
   done, mark the row `waiting on <item>` and take the next row.
3. **Check the ground.** The Grounding cites `file:line`; confirm it still
   holds before building on it. If it does not, fix the Grounding in the
   same commit.
4. **Plan a slice.** An item that will not fit one session is done in
   slices, each one a commit that leaves every check green. Say in a sentence
   or two what this slice covers before writing code.
5. **Build it,** putting each piece where the table below says.
6. **Verify it** with the commands below, and with the item's own *Done
   when*. A speedup is measured (`zig build bench-compare -- <base>`), or
   it does not ship.
7. **Update the documents** using the checklist below.
8. **Commit,** one commit per item or slice, and report to the user what
   was done, what was measured, and which row is next.

Stop and ask the user instead of guessing when:
- the item needs a decision listed under *Decisions → Open* in `ROADMAP.md`
  that has not been made;
- the work would change a budget in SPEC.md §20.2, retire an item, or
  reorder the queue beyond moving a blocked row down;
- the *Done when* can only be met by CI or another machine. Commit what
  can be verified here, mark the row `waiting on CI` with what to check,
  and say so;
- the item is in a repository other than this one and the user has not
  said to work there in this session.

## Where things go

| Change | Goes in |
|---|---|
| core engine and vocabulary | `src/<topic>.zig`; public names are exported from `src/root.zig` |
| a contract check (`zui`-prefixed declarations) | `src/contracts.zig` |
| core tests | `src/tests/<area>.zig`, imported from the `test` block of `src/root.zig`; shared helpers in `src/tests/support.zig` |
| a compile-error message | `tests/compile_errors/<case>.zig`, plus a row in `compile_error_cases` in `build.zig` with the complete message. Every message SPEC.md quotes has one |
| a new public API that is generic | exercised in `tests/instantiate.zig`, so `zig build check` type-checks it on every target |
| a module `zui_<name>` | `zui_<name>/zui_<name>.zig` and `zui_<name>/tests.zig`. In `build.zig`: `b.addModule`, the test loop, the `check` imports and `formatted_paths`. Also `.paths` in `build.zig.zon` and the import snippet in `README.md`. A module imports only its own directory and `@import("zui")` (SPEC.md §3.3) |
| a conformance suite (`expect*Conforms`) | `zui_testing/zui_testing.zig` |
| a benchmark scenario | `bench/bench.zig`; its budget, if any, comes from SPEC.md §20.2 |
| CI | `.github/workflows/ci.yml` |
| renderer and adapter-host changes | `../zui-raylib`, `../zui-sokol`, `../zui-terminal`, tested against this checkout with `zig build test --fork=../zui` |
| native hosts | `../zui-host`, which is created by H2 and not before |

Each stage's features and their layer are listed in `ARCHITECTURE.md` §6.
If an item puts something in a different layer, change §6 too.

## Keeping the documents current

In every item's commit:
- [ ] **ROADMAP.md, the queue:** the row's status. When the item is done,
      remove its row. When five or fewer open rows remain, add the next
      items from the next stage of SPEC.md §21, in dependency order.
- [ ] **ROADMAP.md, the item:** a **Status** line saying what is done and
      what remains. When it is done, move the item to *Done* with what it
      measured, as R2 and P1 are written.
- [ ] **ROADMAP.md, *Where we are*:** when a stage finishes, or a budget
      measurement changes.
- [ ] **ARCHITECTURE.md §7:** remove a row the item closed; add one for any
      new difference between the code and the spec.
- [ ] **SPEC.md:** if the implementation shows the spec is wrong, fix the
      spec in the same commit and give the reason in the commit message.
      When an open question in §22 is settled, remove it there and record
      the outcome under *Decisions → Made* in ROADMAP.md.
- [ ] **README.md:** the status list when a stage or user-visible feature
      ships; the API example whenever the API it shows changes; the
      *Development* table when a build step changes.
- [ ] **docs/feature-tour.html and docs/feature-tour.md:** when a
      user-visible feature ships or its API changes, add or update its
      entry in both, with an example in a consumer's own code; move a
      feature out of *Declared but not working yet* once it works. The two
      files carry the same content and change together.
- [ ] **Doc comments** on every new or changed `pub` declaration.

New items take the next number in their series, and numbers are never
reused (`ROADMAP.md` explains the letters).

## Verifying

| Command | When |
|---|---|
| `zig build test` | always; about 25 s |
| `zig build test -Doptimize=ReleaseFast` and `-Doptimize=ReleaseSafe` | before committing; CI runs all three |
| `zig build check -Dtarget=wasm32-freestanding` and `-Dtarget=powerpc-linux` | any change to `src/` (freestanding and big-endian) |
| `zig build test -Dtarget=x86-linux` | any index or hash arithmetic; catches 64-bit assumptions |
| `zig build test -Dzui-sanitize-thread=true` | any change to a source, an atomic or the conformance suite; on Linux only, so here in a container run with `--security-opt seccomp=unconfined` |
| `zig build test -Dzui-tracy=true` | any change to `zui_tracy` or the trace zones; fetches Tracy |
| `zig build fmt` | before committing; CI runs `fmt-check` |
| `zig build bench -- --check-targets` | any change to a hot path; in benchmarking mode, as SPEC.md §20.2's budgets are set |
| `zig build bench-compare -- <base>` | any change claiming a speedup or risking a slowdown |
| `zig build counts -- --compare <file>` | any change to a hot path; CI compares with the parent commit and fails on more than 2% growth |

- Every command, test run and CI job has a hard limit of 10 minutes:
  `timeout 600 zig build test`, `timeout-minutes` in CI. No test may wait
  without a bound. Work that does not fit is restructured, never given a
  longer limit.
- This machine dual-boots. On Windows, Valgrind and Callgrind do not run,
  but Docker does, so instruction counts are taken in a Linux container.
  On its bare-metal Linux install (Omarchy) they run natively, and so do
  hardware counters (`bench --counters`).
- On the Linux install, the owner switches the CPU between its normal mode
  (Turbo Boost on, the usual governor) and benchmarking mode (Turbo Boost
  off, `performance` governor on every core) with a shell command,
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
- **Names over comments.** Comment only what is not obvious from the code,
  and do not reference other files or the spec in comments.
- LF line endings everywhere.

## Commits and other repositories

- Commit messages follow the history: an imperative subject without a
  prefix ("Add the tracer contract"), and a body that says what changed
  and why, with measurements.
- Work on `main`, as the history does. **Do not push or tag** unless the
  user says to in this session. Sibling repositories pin zui by commit,
  so they cannot take a zui change until it is pushed. Until then, test
  them with `--fork=../zui`.
- Work in a sibling repository only for an item whose *Where* names it,
  and leave that repository's own README current in the same way.
