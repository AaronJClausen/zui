# Declaration performance: ideas to try

In 0.5, layout and emission got about twice as fast, so declaring the UI
is now the larger half of a frame. In the 4,096-box benchmark on the
reference machine (an i9-10900K), a frame takes about 206 µs, and
`endFrame` (layout and emission) about 97 µs. That leaves about 110 µs, or
27 ns per element, for `beginFrame`, the `open`/`close` calls and the
application's own loop. No target in SPEC.md §6.5 covers declaration, so
this cost has never been tracked.

This document lists ideas for reducing it. Each item says:
- **Grounding:** what we actually know, kept apart from what is only expected.
- **Plan:** what to change.
- **To confirm:** the measurement that decides whether it ships.
- **Spec:** whether it departs from SPEC.md, and if so, whether that is
  worth it.

The 0.5 work is a warning: four plausible layout optimizations made
layout slower, and only measuring showed it. So the measurement comes
first (item 0), and every item ships only if its numbers say so.

## Results so far

Measured on the reference machine as the fastest of 15 to 20 alternating
runs of `zig build bench`. Each commit message has its own before-and-after
numbers.

| Item | Outcome |
|---|---|
| 0. Measure declaration | Shipped. `zig build bench` has declare columns, a Documents-view scenario, and `--compare` checks declaration too. The `perf` profile is below. |
| 5, step 1. Delete `floating_root` | Shipped. −16 KiB of `required_bytes`; declaration flat except the Documents view (−7%). |
| 1. Stop copying `ElementConfig` | Shipped, variant 1 (`inline`). Declaration −7% to −40%, `endFrame` unchanged; demo binary +1.5%. |
| 2. Remove the child links | Shipped. Declaration −6% to −31%, layout unchanged, −48 KiB of `required_bytes`. |
| 3. Counters out of frame memory | Moving the counts to `Context` changed nothing (±3%). Shipped instead: count only dropped elements and bytes, and add the stored totals in `endFrame`. Declaration −2% to −8% on top of the `depth` fix below. |
| Found by the profile: `depth: u32` | Shipped. Box tree declaration −28%, depth 64 −20%, text −6%. See below. |
| 4. Clear only the used id slots | Shipped, then reverted: −2% to −4% (1–3 µs) on the 4,000-element trees, whose tables are 32 KiB, but 0.1 µs at the default config's 16 KiB table, for +16 KiB of `required_bytes`. Its test, that a reused frame forgets the earlier ids, was kept. |
| 5, step 2. Fewer per-element writes | Shipped: `floating_index` only for floating elements (−1% to −19%, most in the Documents view), `subtree_end` only for leaves (box tree −2%). |
| 5, step 3. Pack the hot fields | Not tried. With the stall below fixed, no instruction in the box tree's declaration has more than 4% of its samples, so packing has no hot spot to target. |
| 6. Static subtrees | Not tried: waits for an application with enough static structure. |

Together, against the item-0 commit (the same library code as 0.5):

| Scenario | Declaration | `endFrame` |
|---|---|---|
| 4,096 boxes, depth 8 | 104.0 → 51.8 µs (−50%) | 99.1 → 100.0 µs |
| 4,000 children of one parent | 123.9 → 54.5 µs (−56%) | 64.9 → 67.9 µs |
| 1,000 texts, warm cache | 25.8 → 13.9 µs (−46%) | 184.1 → 184.2 µs |
| depth 64 | 1.9 → 1.1 µs (−42%) | 1.9 → 1.9 µs |
| Documents view | 7.4 → 3.4 µs (−54%) | 6.4 → 6.4 µs |

The wide tree's `endFrame` moves between about 65 and 67 µs from one
build to the next, whatever the change, so its +5% is code placement.

### The profile: a store-forwarding stall on `depth`

Profiled with `perf` in WSL, in an `x86_64-linux-gnu` build with LLVM and
LLD. This `perf` cannot resolve symbols at Zig's 0x1000000 image base, so
the samples from `perf script -F ip` were matched to `nm` by hand.

After items 1, 2, 4 and 5, 27.5% of the box tree's declaration samples land
on a single load: `appendElement` reloading `Context.depth` to find the
parent, `open_stack[depth - 1]`.
- `depth` is a `u16`, and the previous `open` wrote it with a 16-bit store.
- LLVM widened the reload to 32 bits. A load wider than a recent store
  cannot be forwarded from the store buffer, so every `open` waits for the
  previous one's store to reach the cache.
- The reload happens because `appendElement` first increments
  `needed.elements` through the frame pointer, which might alias `self`.
  Without that store, LLVM reuses the `depth` it already loaded for the
  depth check.

That is also why moving the counts to `Context` (item 3 as planned)
changed nothing: it is still a store through a pointer before the reload.

Two fixes, measured together and apart against the code before them
(fastest of 20 alternating runs of declaration):

| Change | 4,096 boxes | 4,000 children | 1,000 texts | depth 64 | Documents view |
|---|---|---|---|---|---|
| none | 71.8 µs | 54.0 µs | 15.3 µs | 1.5 µs | 3.4 µs |
| `depth: u32` | 52.3 µs (−27%) | 53.8 µs (0%) | 14.3 µs (−7%) | 1.2 µs (−20%) | 3.3 µs (−3%) |
| derived counts | 52.0 µs (−28%) | 53.3 µs (−1%) | 14.2 µs (−7%) | 1.1 µs (−27%) | 3.3 µs (−3%) |
| both | 51.3 µs (−29%) | 53.0 µs (−2%) | 13.8 µs (−10%) | 1.2 µs (−20%) | 3.2 µs (−6%) |

- **`depth: u32`** is one line. Loads and stores of `depth` are then the
  same width, so forwarding works whether or not LLVM reloads it.
- **Derived counts** go further than item 3 planned: in the normal case
  `needed.elements` is `element_count` and `needed.text_bytes` is
  `text_bytes_used`. Only dropped elements and bytes are counted as they
  happen, and `endFrame` adds the stored totals. That removes the
  per-element read-modify-write instead of moving it. The capacity tests,
  including the overflowing frames, pass unchanged.

The wide tree has a single `open`, so it gains nothing from either.
`endFrame` is within ±1% for all three. Both shipped, `depth: u32` first.

## 0. First, measure declaration on its own

**Plan.**
- Add a "declare" column to `zig build bench`: the time from
  `beginFrame` to the start of `endFrame`. Today it can only be worked out
  from two columns (frame median minus layout median).
- Add declaration-heavy scenarios: the box tree, the 4,000-child row, and
  the zui-raylib demo's Documents view (declared by hand, many small
  elements).
- Profile the box tree's declaration with `perf` in WSL, as was done for
  layout in 0.5. Build for `x86_64-linux-gnu` with `-fllvm -flld
  -fno-strip`, because `perf` could not resolve symbols in binaries from
  Zig's own linker. Temporarily mark the functions of interest
  `@call(.never_inline, ...)`, so samples land per function.
- Extend the CI regression check (§14.3) to the new column, so a
  declaration slowdown fails CI the way a layout slowdown does.

**To confirm.** Nothing to confirm; this is the baseline every later item
is judged against. Record the per-element cost and the top functions in
the profile before changing anything.

**Spec.** §14.3 gains a declaration column. This is an addition, not a
change.

## 1. Stop copying the whole `ElementConfig`

**Grounding.**
- **Measured:** in the 0.5 profile of the box tree, the hottest
  instruction in the whole program, with 9% of all samples, was in
  `appendElement`. It was a load copying the config struct onto the
  stack.
- **Measured:** `ElementConfig` is 168 bytes. `open` and `box` take it by
  value, and pass it on by value to `appendElement`.
- **Expected:** most call sites pass a literal where almost every field is
  a compile-time default (no floating, no scroll, no border). If the
  config never leaves the call site, the compiler can drop the stores and
  tests for those fields entirely.

**Plan.** Try two variants, in this order:
1. Mark `open`, `box`, `leaf` and `appendElement` as `inline`, so each call
   site gets its own copy specialized to its literal.
2. If that grows code too much, split `appendElement` into an inline part
   for the common fields (id, layout, background, the interaction flags)
   and an out-of-line part for the rare ones (floating, scroll, clip,
   border), which is called only when one of them is set.

**To confirm.**
- The box tree's declaration median falls by at least 10%.
- Layout does not get slower; 0.5 showed inlining can hurt nearby code.
- Code size: measure the zui-raylib demo binary and the benchmark binary
  before and after. More than about 10% growth for the demo needs a
  second look, and the split variant is the fallback.
- All tests pass in Debug, ReleaseSafe and ReleaseFast. Debug builds get
  no benefit from inlining and may get slower; check they stay usable.

**Spec.** No change to the API in §7.1: the signatures stay the same.
One visible difference: a Zig `inline fn` has no address, so code that
takes `&Ui.open` as a function pointer would stop compiling. That seems
unlikely to matter, but if it does, the split variant keeps `open` an
ordinary function.

## 2. Remove `first_child`, `last_child` and `next_sibling`

**Grounding.**
- **Known from the design:** elements are stored in declaration order
  (pre-order). A parent's first child, if it has one, is always the next
  element, `index + 1`. A child's next sibling is always the element after
  its own subtree, which is `subtree_end[child]`, already stored.
- **Measured:** every element writes all three arrays, and its parent's
  `first_child`, `last_child` and `next_sibling` entries are updated too.
- **Checked:** after the 0.5 rewrites, the only readers are
  `FlowChildren` and `sizeFloatingChildren` in `layout.zig`, plus the
  invariant tests.

**Plan.** Delete the three arrays. Walk children as `child = parent + 1`
while `child < subtree_end[parent]`, stepping with
`child = subtree_end[child]`. A leaf's `subtree_end` is `index + 1`, so the
walk needs no special case.

**To confirm.**
- Declaration time falls (three fewer arrays written per element, and three
  fewer for the parent).
- Layout time for the box tree and the wide tree is unchanged or better.
  Stepping by `subtree_end` reads one array instead of chasing
  `next_sibling`, but both are dependent loads, so a gain is possible but
  not certain.
- All invariant, golden and randomized tests pass. The randomized tree
  test (up to 5,000 elements) covers deep and wide shapes.
- `required_bytes` shrinks by 3 × 2 bytes × `max_elements` per frame in
  flight (48 KiB for the default config with two frames).

**Spec.** This departs from §4.3, which lists `first_child` and
`next_sibling` among the per-element arrays and counts "seven 2-byte links
and indices" in its 48-byte estimate. The change is worth making to the
spec:
- The links duplicate information the tree's order already encodes.
- Storing less per element is the goal §4.3 itself argues for.
- The per-element core shrinks from about 48 bytes to about 42.

`subtree_end` is not in §4.3's table today, though the code has stored it
since 0.1, so the update should add it and remove the two links.

## 3. Keep the diagnostic counts out of frame memory

**Grounding.**
- **Measured:** every `open`, `box` and `text` updates
  `frame.diagnostics.needed`, an `EnumArray` in frame memory:
  - each element adds one to `.elements`;
  - each `open` may raise `.depth`;
  - each `text` adds to `.text_bytes`.
- **Expected:** these are read-modify-writes through a pointer. The
  compiler cannot keep the counts in registers, because other writes to
  frame memory might alias them. Emission had the same pattern; 0.5
  changed it to count in a local and write once at the end, in the same
  step as another small fix, and the two together saved about 1 µs. The
  counter's own share was not measured.

**Plan.** Keep the counts as plain fields on `Context`, and write them
into `frame.diagnostics` once, in `endFrame`.

**To confirm.**
- A declaration speedup that is measurable (expected to be small, a few
  percent).
- The capacity tests still report the same `needed` values, including on
  frames that overflow, and `endFrame` still returns
  `error.CapacityExceeded`.

**Spec.** No change. §13.2 describes what is reported, not when it is
counted.

## 4. Clear only the used slots of the id table

**Grounding.**
- **Measured:** `beginFrame` calls `frame.reset`, which zeroes the whole
  duplicate-id table. That is 16 KiB at the default config (8,192 two-byte
  slots) and 32 KiB at the benchmark's 4,200 elements.
- **Known:** in 0.5, the same fix for the interaction results table, which
  was 16,384 slots cleared every frame, saved 13 µs of emission time in the
  box tree. This table is smaller, so the saving should be too, perhaps
  1–2 µs.
- **Expected:** the cost is per frame and does not depend on how many
  elements are declared, so it matters most for small UIs at high frame
  rates.

**Plan.** Record each slot as it is filled in `registerId`, and zero only
those slots at the next reset. Only elements with explicit ids use the
table, so for most frames this is far less work. The first `reset` after
`init` still clears the whole table.

**To confirm.**
- `beginFrame` gets faster, most visibly in a scenario with few elements
  (the depth-64 tree).
- The duplicate-id tests still catch duplicates in the frame after a
  frame that declared many ids.

**Spec.** No change.

## 5. Write fewer arrays per element

**Grounding.**
- **Measured:** `appendElement` writes about 20 per-element arrays. Some
  writes help only rare cases:
  - `floating_index` and the floating-config storage only matter for
    floating elements.
  - `subtree_end` is written twice for containers: once when the element
    is opened, and again in `close`. Leaves need the first write.
- **Found while writing this document:** `floating_root` is written for
  every element and **never read**. Its only reader was the old position
  pass, which 0.5 replaced. Deleting it is free.
- **Unknown:** whether the remaining writes cost much. They go to arrays
  that the passes stream through in order, so they may already be cheap.

**Plan.**
1. Delete `floating_root` (no measurement needed beyond the tests).
2. Measure, then try the rest one at a time:
   - write `floating_index` only for floating elements, which needs a flag
     (the `floating` bit added in 0.5 already exists);
   - write `subtree_end` only for leaves, leaving containers to `close`.
3. Only if the profile still shows the per-element stores as hot: try
   packing the fields written at declaration and read by every pass
   (`parent`, `flags`, `layout_index`, content kind and index) into one
   small record per element, so declaration writes one cache line instead
   of several.

**To confirm.**
- Step 1: all tests pass, and `required_bytes` shrinks by 2 bytes ×
  `max_elements` per frame in flight.
- Step 2: a measurable declaration speedup, with no layout regression.
- Step 3: declaration must improve *and* layout must not regress, on both
  the box tree and the wide tree. Packing helps the code that writes the
  fields and may hurt the passes that read only some of them.

**Spec.**
- Steps 1 and 2: no change.
- Step 3 departs from §4.3, which says per-element data is
  structure-of-arrays "so each layout pass streams through only the fields
  it uses". It would make the storage partly array-of-structs. That is
  worth considering, because 0.5 found layout limited by instruction count,
  not memory bandwidth: the 66-element depth-64 tree, which fits in the L1
  cache, cost as much per element as the 4,096-box tree. §4.3's argument
  for structure-of-arrays is about bandwidth, so it is weaker than the spec
  assumes. But the change should ship only if both declaration and layout
  measure better, and §4.3 should then say why the hybrid was chosen.

## 6. Static subtrees

**Grounding.**
- **Known:** SPEC.md §16 already plans static subtrees: a tree described as
  a compile-time value, laid out during the build and stored as a constant
  command array.
- **Known:** the spec deferred them because the comptime lesson measured
  the costs: about 2 µs per comptime loop iteration, and five times the
  code size when unrolled. It also says the win only exists for subtrees
  without text measurement, or with font metrics embedded with
  `@embedFile`.
- **Expected:** a fixed toolbar or HUD frame would skip both declaration
  and layout for its elements. That is the largest possible saving per
  element, but only for the parts of a UI that never change.

**Plan.** Not before items 1–5, and only if a real application has enough
static structure to matter. The zui-raylib demo's toolbar (seven buttons)
is too small to justify it.
1. Measure how much of a realistic frame is static.
2. Prototype a static subtree as a pre-recorded block of element records,
   copied in with one `@memcpy` and laid out normally. That keeps the
   declaration saving without the build-time layout, so text in the
   subtree still works.

**To confirm.**
- Declaring a 100-element static toolbar costs less than declaring it
  normally, at a build-time and code-size cost that is acceptable.
- Interaction still works, because the copied elements must keep their
  ids.

**Spec.** The copy-in prototype departs from §16's design, which lays the
subtree out during the build. It would be worth changing the spec to
allow it:
- It removes the text-measurement restriction (layout still runs at run
  time).
- It avoids the comptime costs the lesson measured.
- It keeps most of the declaration saving, which is now the larger cost.

Build-time layout could remain a later step for subtrees with no text.

## Suggested order

| Order | Item | Why this position |
|---|---|---|
| 1 | 0. Measure declaration on its own | everything else is judged against it |
| 2 | 5, step 1. Delete `floating_root` | dead code; free |
| 3 | 1. Stop copying `ElementConfig` | the one measured hot spot |
| 4 | 2. Remove the child links | also simplifies layout and shrinks memory |
| 5 | 3 and 4. Counters and id-table clearing | small, safe, independent |
| 6 | 5, steps 2–3. Fewer per-element writes | only if the profile still points there |
| 7 | 6. Static subtrees | only with a real application that needs it |

Each item should land on its own, with before-and-after numbers from
`zig build bench` in the commit message. The mutation testing used for
0.4 and 0.5 should cover items 2 and 5, which change how the tree is
stored.
