# 06-text-and-layout: Text and layout

Stage 6 of SPEC.md §21: string cache and fast path, segmentation, grow
basis, aspect ratio, natural sizes, floating options, right-to-left,
wrap, static styles.

**Done when:** goldens for each; warm text within its budget; no other
budget regresses.

**Status.** Done.

**The data-oriented design audit.** `06-text-and-layout:14-layer-sort`
to `06-text-and-layout:20-text-commands-point-at-style` came after stage
7, from `DOD-AUDIT-2026-11-09-5b032b7.md`, which found the costs next to
the layout sweeps, in paths no benchmark ran until `db4ea4d` added
scenes for them: floating layers, ids on every element, and a pointer
pressing. The owner put its findings ahead of stage 8. Each is judged by
`bench-compare` against its parent, with turbo off, and by `counts`; one
that costs more elsewhere than it saves in its scene does not ship.
`06-text-and-layout:19-flat-child-lists` was retired on its profile, and
`06-text-and-layout:20-text-commands-point-at-style` when a scene that
reads the commands as a renderer does was no faster with it.

## Items

| Item | Status |
|---|---|
| `06-text-and-layout:01-single-line-fast-path` The single-line fast path | done |
| `06-text-and-layout:02-whole-string-cache` The whole-string cache | done |
| `06-text-and-layout:03-static-styles` Static styles | done |
| `06-text-and-layout:04-box-tree-layout-budget` The box tree's layout and emission within budget | done |
| `06-text-and-layout:05-box-tree-declaration-budget` The box tree's declaration within budget | done |
| `06-text-and-layout:06-line-break-segmentation` Line-break segmentation | done |
| `06-text-and-layout:07-grow-basis` A grow basis | done |
| `06-text-and-layout:08-aspect-ratio-and-natural-sizes` Aspect ratio and natural sizes | done |
| `06-text-and-layout:09-dividers-and-decorated-images` Dividers and decorated images | done |
| `06-text-and-layout:10-floating-options` Floating options | done |
| `06-text-and-layout:11-right-to-left` Right-to-left layout | done |
| `06-text-and-layout:12-wrap` Wrap | done |
| `06-text-and-layout:13-image-tint-and-corners` The backends draw images' tint and corner radius | done |
| `06-text-and-layout:14-layer-sort` The layer sort | done |
| `06-text-and-layout:15-id-rect-table` A narrow id → rect table | done |
| `06-text-and-layout:16-one-hit-test-per-press` One hit test per press | done |
| `06-text-and-layout:17-wrapped-lines-cached` Wrapped lines kept with the string cache | done |
| `06-text-and-layout:18-string-cache-keys-apart` The string cache's keys apart from its values | done |
| `06-text-and-layout:19-flat-child-lists` Flat child lists | retired |
| `06-text-and-layout:20-text-commands-point-at-style` Text commands that point at their style | retired |

---

## 06-text-and-layout:01-single-line-fast-path — The single-line fast path

`Metrics.has_paragraph_break`, and `wrapLines` emitting a text without
one whose unwrapped width fits as one line, with that width, without
walking its words; a text with `.newlines` and no newline, too.
`measureMetrics` learns of a break from a widest-ended-paragraph width
that starts negative, because a flag carried through its word loop cost
about 4 instructions a word. A randomized test checks that the fast path
emits exactly the line greedy wrapping does, over 2,000 texts of spaces,
newlines and letters at random widths; the golden and randomized layout
tests pass unchanged.

The warm text wall wraps nearly every text in its 160-unit panels, so a
new scenario, `1000 single-line texts, warm`, lays the same sentences in
panels 480 units wide (its own commit, `bf807b9`, so each side of a
comparison has it). Against `bf807b9`:

- `zig build counts`, in a local Docker container: the single-line
  scenario's `endFrame` −17.8% (2,287,233 to 1,879,297 instructions),
  the documents view's −7.8% (97,370 to 89,782); the text walls'
  `endFrame` +0.3%, and text declarations +0.8% (one instruction a text,
  from the larger record);
- `zig build bench-compare -- bf807b9` (10 rounds, i9-10900K): the
  single-line scenario −26.2% (216.0 to 159.9 µs, middle half −26.6% to
  −25.7%), the documents view −2.7%; nothing slower.

## 06-text-and-layout:02-whole-string-cache — The whole-string cache

`Limits.string_cache_entries` (1,024 by default, a power of two, with
its compile-error test), and a second table in the measurement cache
keyed by the whole string, its `MeasureKey`, the zoom and the wrap mode.
An entry holds the text's metrics and the widths of up to 16 runs; a hit
copies them into the frame and walks no words, so with
`06-text-and-layout:01-single-line-fast-path`'s fast path a warm label
does no per-word work, and a warm text that wraps reads its word widths
without probing. A text of more than 16 runs is cached by its metrics
alone, and `wrapTexts` measures its runs only when it does not fit on
one line. A golden test lays out wrapping, single-line, long,
newline-separated and zoomed texts in one context over five frames at
two widths and two zooms, against a fresh context each frame, with the
run widths moving between frames; it fails if pending runs are not
measured or if the zoom is left out of the key.

A Callgrind profile first confirmed the cost: at `b99fa79`, 60% of the
warm text wall's `endFrame` was measuring through per-word probes
(`measureMetrics` 27.0%, `Measurer.measure` 21.4%, wyhash 12.1%), and
20% `wrapLines`. Most of the wall's texts wrap, which is why an entry
holds word widths, not only the metrics SPEC.md §9.3 first listed; the
spec now says so. `1000 new strings, warm words` (its own commit,
`77027e8`) is the frame that changes every string. Against `77027e8`:

- `zig build counts`, in a local Docker container: warm text wall
  `endFrame` −53.8% (2,361,336 to 1,090,886), single-line texts −67.6%,
  documents view −25.9%; new strings +0.3% and the cold wall +1.2%, the
  string hash and probe of a miss; nothing else moved by more than one
  instruction;
- `zig build bench-compare -- 77027e8` (10 rounds): warm text wall
  −56.4% (225.3 to 98.5 µs), single-line texts −71.2%, documents view
  −27.8%; new strings −3.9% and the cold wall −5.0%, faster, not slower;
  first frame of 1,000 texts −6.4%; `init` +19.1% (110.7 to 134.8 µs)
  and `initBuffer` +13.2% (9.5 to 10.8 µs), clearing the new table's 104
  KB (`init` allocates 4.75 MiB, from 4.61);
- `zig build bench -- --check-targets`: warm text's fastest frame 98.9
  µs against the 120 µs budget (see *Where we are* in `ROADMAP.md`).

Laying the tables out as structure-of-arrays moved those page faults
from `init` into the first frame (+76% for the documents view's) and
grew the miss paths by 7% in counts, so the entries stay whole.

## 06-text-and-layout:03-static-styles — Static styles

**Plan.** `zui.static` and `Static(T)`; config references in element
storage as pointers into the frame arena or static memory; fields on the
element overriding the style's. **Done when:** the box tree's
declaration stays within its 55 µs budget with references, and declaring
an element with a static style copies no config
(`01-measure:03-instruction-counts-in-ci`). **Spec.** §10.3.

`zui.Style` (a layout and a decoration), `zui.Static(T)`, which holds a
pointer to read-only memory, and `zui.static(comptime value)`, which is
the only way to make one; `Element.style`, with `layout` and
`decoration` set on the element replacing the style's. A frame now keeps
`layout: [max_elements]*const Layout`, pointing at a copy in its arena,
a static style's, or one default layout, and
`decoration: [max_elements]?*const Decoration`, null where nothing is
drawn (a static style whose decoration draws nothing included);
`Frame.layoutOf` and the new `decorationOf` read them. Copies go through
a cursor into the arena, `next_layout` and `next_decoration`, rather
than a count, which saved the address arithmetic that otherwise made
declaration grow by up to 4%.

Tests: a styled element lays out and draws exactly as one with the same
configs copied; the frame holds the static style's own addresses; an
element's own layout or empty decoration replaces the style's, and a
static decoration that draws nothing is none; a style's direction flows
its children. `zig build check` declares a styled element on every
target. A new scenario, `4096 static-styled boxes`, is the box tree with
each element's configs in one of 32 static styles.

`zig build counts` against `342b04a`, in a local Docker container: the
box tree's declaration −2.35% (588,151 to 574,326) and `endFrame` −4.8%;
`endFrame` fewer in every scenario (−0.3% to −5.0%), declaration within
+0.7% elsewhere (depth 64, 14,405 to 14,502), the wide tree's −3.9%. The
static-styled tree declares in 445,291 instructions, 22.5% fewer than
copying, with the same `endFrame`. `zig build bench -- --check-targets`,
four runs: the static-styled tree's declaration 34.5 to 34.7 µs at best,
within the 55 µs budget; the copying box tree's 57.7 to 58.5 µs, still
over it (`06-text-and-layout:05-box-tree-declaration-budget`), and its
layout and emission 92.3 to 94.4 µs; warm text 97.5 to 102.7 µs.
`zig build bench-compare -- 342b04a` (4 rounds): the box tree's
declaration −6.1% and the wide tree's −8.3%, depth 64's `endFrame`
−4.5%; slower, warm text's `endFrame` +7.0% (91.4 to 98.4 µs, within its
120 µs budget, with 0.8% fewer instructions) and the documents view's
first frame +5.8%. Callgrind's cache simulation puts warm text's extra
time in the wider arrays: 6% more first-level read misses, from two
8-byte references an element where there were two 2-byte indices.

Tried and dropped:

- **Indices into tables of references** (`layout_index` into
  `layout_refs`): read misses back to before, but declaration +4.2% for
  the box tree and +10.6% for the wide tree, a store more per config;
- **a `decorated` flag,** writing the decoration only where one is
  drawn: warm text's misses unchanged, and the static-styled tree's
  declaration +11.6%, reading each style's decoration to set the flag.

Decided here:

- **What a reference is:** a pointer, as SPEC.md §10.3 says, also for
  the default layout, a constant in read-only memory, so a pass never
  branches on whether an element has a layout.
- **Overriding** is by kind: an element's `layout` replaces the style's
  layout whole, as does its `decoration`, so a reference is never merged
  into a copy.

The copying box tree's declaration budget was met by
`06-text-and-layout:05-box-tree-declaration-budget`.

## 06-text-and-layout:04-box-tree-layout-budget — The box tree's layout and emission within budget

**Grounding.** At `a6d8e34` the box tree's `endFrame` took 101.2 µs
against a 100 µs budget, and no item was aimed at it. Stage 2 has
changed emission since (scale and zoom snapping, the frame's
diagnostics), so the first step is to measure it again.

**Plan.** Re-measure on the reference machine. If it is still over, take
a `01-measure:04-tracer-contract` trace of the passes and work on the
costliest, judged by `01-measure:03-instruction-counts-in-ci`'s counts
and `bench-compare`.

**Done when:** `zig build bench -- --check-targets` meets both box-tree
budgets on the reference machine, and no other scenario is slower by
`bench-compare`.

Done with `06-text-and-layout:05-box-tree-declaration-budget`, which
brought the declaration within budget. After
`06-text-and-layout:05-box-tree-declaration-budget`,
`zig build bench-compare -- afacf87` (8 rounds) calls no scenario
slower: the box tree's `endFrame` −19.0% and declaration −27.4%, warm
text −6.1%, the wide tree −7.6% and −7.9%, the documents view −9.3%,
everything else within noise.

Measured first at `afacf87` on the reference machine: `endFrame` 111.0
µs and declaration 68.5 µs, the machine running slower than at `a6d8e34`
(*Where we are* in `ROADMAP.md`). Callgrind's profile of `endFrame` gave
position 21% (82 instructions an element: its along and across
coordinates were indexed at run time, so each parent spilled them to the
stack), the two distribute passes 20%, the two fit passes 20% and
emission 12%. Landed:

- **Position by parent.** Each parent places its flow children in one
  loop specialized by the flow's axis; the per-parent placement records
  are gone. Position went from 365,000 to 232,000 instructions a frame.
- **A default layout at `layouts[none_index]`,** so `layoutOf` and
  `sizingOf` never branch.
- **Declaration:** an element without an id takes `id.internal`, one
  multiply where `mix` took two, because such ids are never looked up;
  `Sizing.Rule` is four bytes, so a layout has no padding bytes to copy;
  `content_index` is not written for a plain box; `flagsFor` is inline;
  the root is a comptime case of `appendElement`.

Against `afacf87`, `zig build counts` in a local Docker container: the
box tree's `endFrame` −14.3% (1,562,373 to 1,339,297) and declaration
−23.2% (765,869 to 588,146); every other scenario fewer in both phases
(text declarations −10% to −18%, `endFrame` −0.4% to −15%).
`zig build bench-compare -- afacf87` (8 rounds): box tree `endFrame`
−16.0% (111.0 to 93.5 µs), declaration −9.6% (68.5 to 61.9 µs), warm
text −5.8%, depth 64 −8.3%, documents view −3.8%; slower: the text
walls' declaration +3.7% (16.3 to 16.9 µs) and the wide tree's +4.4%,
with 18% and 11% fewer instructions and the same simulated cache misses
(Callgrind `--cache-sim`), which points at code placement rather than
work.

Tried and dropped:

- zeroing `size` and `min_size` at the start of `endFrame` rather than
  in declaration: declaration −8%, but `endFrame` +3% for the box and
  wide trees, the cost of touching 128 KB, so it would only move the
  time; `@memset` there was compiler_rt's, 90,000 instructions without
  libc, and `rep stosb` was slower still;
- one integer for `child_count` and `flow_child_count`: −4,000
  instructions in declaration, +40,000 in `endFrame`;
- layouts and decorations at the element's own index, with no counts:
  −2% in declaration, but the first frame of 1,000 texts +5.7%, from the
  pages the sparse layouts touch;
- `sizingOf` returning `.fit` without a load: +86,000 instructions in
  the box tree's `endFrame`; `.fit` tested before the switch in
  `distribute`: no change;
- computing the flags before the first store: no change (see
  `06-text-and-layout:05-box-tree-declaration-budget`).

**Spec.** §8.2, §20.2.

## 06-text-and-layout:05-box-tree-declaration-budget — The box tree's declaration within budget

**Plan.** With `06-text-and-layout:03-static-styles`'s config references
in place, cut the per-element stores of `open`, and store the flags
without reloading the element's fields, through a different `Element`
shape if the compiler cannot be led to it. **Done when:**
`zig build bench -- --check-targets` meets the declaration budget on the
reference machine, and no scenario is slower by `bench-compare`.
**Spec.** §5.1, §10.1, §20.2.

The box tree declares in 48.9 to 50.2 µs at best over five runs of
`zig build bench -- --check-targets`, against 55 µs, and lays out and
emits in 89.2 to 93.5 µs. Callgrind's profile of an `open` after
`06-text-and-layout:03-static-styles` put most of what was left in two
places that were not the stores of element storage:

- **The element's switches.** Zig writes a `bool` field of a struct
  literal as one bit and reads it as a byte, and LLVM cannot forward a
  store to a wider load, so the scene's `Element` stayed on the stack:
  every `open` stored `interactive`, `focusable`, `focus_scope` and
  `disabled` and loaded and masked them back, about 25 instructions. An
  optional is stored and loaded as bytes, and its defaults fold, so the
  four are `?bool`, null meaning false. They are written as before, and
  SPEC.md §10.1 records why. A switch set at run time still costs a
  store and a load, half of what a `bool` did. `Axes` was a two-bit enum
  with the same problem, so it is a byte.
- **Reloads through the frame.** The copied layout and decoration take
  their slot in a local before the copy, so the cursor is not loaded
  again after it.

And in element storage, `child_count` and `flow_child_count` are one
array of pairs, `child_counts`, so declaration zeroes both in one store
and counts a flow child in one addition; the passes read each half as
before. `fit` takes each element's sizing from `contentSize`, which
already read its layout, and a text element's from the default layout
without reading its reference.

`zig build counts` against `beb36f5`, in a local Docker container: the
box tree's declaration −24.1% (574,326 to 436,050) and its `endFrame`
−1.1%; the static-styled tree's declaration −31.2%, the wide tree's
−35.0% and depth 64's −15.0%; the texts' declarations −3.1% to −6.9%;
every scenario fewer in both phases.
`zig build bench-compare -- beb36f5` (6 rounds): the box tree's
declaration −15.6% (58.3 to 49.6 µs), the static-styled tree's −20.8%,
the wide tree's −11.9%, depth 64's −13.3%; warm text's `endFrame` −6.6%
(97.9 to 91.5 µs), the box tree's −2.6%; none slower. Against `342b04a`,
before `06-text-and-layout:03-static-styles` (8 rounds), warm text's
`endFrame` is +1.4%, within noise, where
`06-text-and-layout:03-static-styles` had left it +7.0%.

Tried and dropped:

- **The content kind in the flags,** saving one store an element:
  declaration −1%, but `endFrame` +1%, from masking the kind out of the
  flags in every pass;
- **`sizingOf` answering a text element without its reference,**
  everywhere: warm text's `endFrame` −0.4% and its read misses −1.2%,
  but the box tree's `endFrame` +2.5%;
- **the pair of child counts as a packed struct:** the same declaration,
  but the box tree's `endFrame` +2.9%, from extracting each half.

## 06-text-and-layout:06-line-break-segmentation — Line-break segmentation

**Plan.** The optional `zuiSegment` on the text contract, writing break
opportunities into a `BreakSink`; ASCII spaces and newlines without it.
**Done when:** a golden test wraps CJK text with a segmenting test
contract, and texts without it are no slower. **Spec.** §9.2, §9.4.

`zuiSegment(self, paragraph, breaks: *zui.BreakSink)`, checked by
`checkText`, with a compile-error test for a wrong signature. zui splits
a text at newlines itself and asks the contract for one paragraph at a
time; the segments between its breaks are measured and wrapped as words
are, each without the spaces that end it, which hang past the end of a
line that breaks after it. The breaks go into a scratch buffer of
`limits.max_text_bytes` offsets, in `Context` memory only when the
contract declares `zuiSegment`. Without it, nothing changes: the
segmenting path is chosen at compile time, its own functions
(`measureSegments`, `wrapSegmentedLines`), so the default path's code is
the code it was.

Tests: CJK text wraps between characters at the width of whole
characters; Latin words stay whole beside CJK, and the space before a
break hangs; each paragraph is segmented on its own and the contract
never sees a newline; a cached string past the 16 widths a cache entry
keeps wraps as a fresh one, with no new measurements; a contract that
breaks after every space reproduces the default's metrics and lines over
2,000 random texts. `zig build check` declares a thread-safe segmenting
contract, so the parallel path's run iterator is type-checked on every
target.

Fixed on the way: the first word of a paragraph after the first was
given the width of a space before it, so the first line of every later
paragraph came out a space wide too, and sooner wrapped.

`zig build counts` against `c5b0401`, in a local Docker container: warm
text's `endFrame` −2.6% (1,060,636 to 1,033,320), from the fix, and the
other text scenarios −0.2% to −1.2%; every other scenario unchanged.
`zig build bench-compare -- c5b0401` called no scenario slower over 10
rounds, but put warm text's `endFrame` at +4.0% (+0.4% to +5.4%), and an
earlier run of the same code at +6.8%. With the fix taken out, warm text
ran the very same instructions as at `c5b0401`, with the same simulated
cache misses and branch mispredictions, and still measured +7.8%; and
`c5b0401` with only `wrapLines` aligned to 64 bytes measured the
new-strings scenario +2.8% slower. So on this machine where the code
lands moves the text scenarios by several percent, and wall-clock
comparisons of them below that are not meaningful; instruction counts
are. Aligning `wrapLines` did not pin it down and was dropped.

## 06-text-and-layout:07-grow-basis — A grow basis

**Grounding.** Two `.grow` siblings holding "a" and "abcdefghijklmnop"
in 300 px came out 90 / 210, as with CSS `flex-basis: auto`, and there
was no way to ask for equal columns. **Plan.** `Sizing.basis`, and
`Sizing.grow_equal`. **Done when:** golden tests for both bases, with
the weight invariant. **Spec.** §8.1.

The zero basis is a rule, `Sizing.Rule.grow_from_min`, rather than a
`basis` field: `Sizing` had no room for one without padding, and two
two-byte fields (`rule` and `basis`) made the box tree's declaration
3.8% more instructions (436,050 to 452,435) with no change to layout.
`Sizing.grow_equal` is `.{ .rule = .grow_from_min, .amount = 1 }`, and
SPEC.md §8.1 records why. It comes after `grow` in the enum, so that
`fit`, `grow` and `grow_from_min` are one range: after `percent`, the
`switch`es over the rule cost the box tree's `endFrame` 2.6% more
instructions.

A `grow_from_min` child starts at its `min` and shares the parent's
content box by weight, as CSS `flex: 1`, but is never narrower than its
content's minimum, so a word never overflows a column: the others share
what it leaves, still by weight. Distribution holds it at that minimum,
and when a parent has one, `growFromMin` raises every growing child to
`clamp(start + share × weight, floor, max)` with one `share`, found by
walking up through the points where a child leaves its floor or reaches
its max. Parents without one keep `grow` as it was: the same walk for
the box tree's capped children cost 0.9% more instructions but ran 6.8%
slower on the wall clock, from its divisions.

Tests: golden layouts for a content basis (90 / 210) and a zero basis
(150 / 150), weights over the whole box, a child held at its content's
minimum with the rest shared 1 : 2, a max, a content and a zero basis
side by side, a zero weight, a `fit` parent, overflow, and rows down a
column. The randomized trees declare `grow_equal` and weighted
`grow_from_min` with mins and maxes, and check the weight invariant:
`grow_from_min` siblings that are neither at their floor nor at their
max have grown from `min` by one share of their weights.

`zig build counts` against `9b506be`, in a local Docker container: every
scenario within −0.51% to +0.02% (the box tree's `endFrame` 1,239,720 to
1,239,211, warm text's 1,033,320 to 1,030,421).
`zig build bench-compare -- 9b506be` (8 rounds) calls nothing slower
beyond the 0.1 µs resolution of depth 64 and the documents view; the box
tree's `endFrame` +1.6% (−1.3% to +3.3%, fastest 90.9 µs), the
static-styled tree's +2.6%, warm text's −5.7%, with the same
instructions: code placement, as
`06-text-and-layout:06-line-break-segmentation` found.

## 06-text-and-layout:08-aspect-ratio-and-natural-sizes — Aspect ratio and natural sizes

**Plan.** `Layout.aspect_ratio`, deriving height from the settled width;
`Image.natural_size` for `fit` images. **Done when:** golden tests cover
aspect ratio under every rule on the other axis, and a `fit` image takes
its natural size. **Spec.** §8.1, §10.1.

The aspect ratio is a height rule, `Sizing.Rule.aspect_ratio`, written
`.height = .aspectRatio(16.0 / 9.0)`, rather than a `Layout` field, as
the grow basis is a rule (`06-text-and-layout:07-grow-basis`):
`aspect_ratio: ?f32` made every `Layout` eight bytes larger (56 to 64),
and the box tree's declaration 0.94% more instructions and 6.6% slower
on the wall clock (49.1 to 52.7 µs, of a 55 µs budget); a plain `f32`
made it 60 bytes, and the box tree's `endFrame` 6.7% slower. SPEC.md
§8.1 now says so. The fit pass of the heights derives it from the
settled width, `width / ratio` within `min` and `max`, so no pass is
added; a parent neither stretches nor grows it, and children overflow
it. On a width, or with a ratio that is not positive, it takes the
content's size.

`Ui.Image` is now the declaration's own type, `handle` and
`natural_size`, apart from the `image` command, which keeps only the
handle until `06-text-and-layout:09-dividers-and-decorated-images` adds
`tint` and `corner_radius`; image storage is reserved only when
`ImageHandle` is not `void`. A natural size is the image's content,
inside its padding; its width may shrink below it, as a leaf's does in a
narrower parent, and its height then keeps the natural proportions
unless its own rule is `aspect_ratio`, `fixed` or `percent`. The natural
size is read only when `ImageHandle` is not `void`.

Where the rule sits in the fit pass decided its cost. In an arm of its
own, LLVM either summed the content before the `switch`, for `fixed`
elements too (4,000 fixed-height children +4.2% instructions), or turned
the `switch` into a jump table whose mispredictions doubled the box
tree's indirect branches and made its `endFrame` 5.5% slower. It shares
the content-based arm instead, as the fourth of one range of rules.

Tests: golden layouts for an aspect ratio under every width rule
(`fixed`, `grow`, `grow_equal`, `percent`, `fit`), within `min` and
`max`, with padding inside it, neither stretched across a row nor grown
down a column beside a `grow` sibling, wrapped by a `fit` parent,
overflowed by a child, and on a width or with a zero ratio. Images: a
natural size with and without padding and none at all, the command's
bounds and handle; a growing and a squeezed image keeping their
proportions; `aspectRatio`, fixed sizes and a zero natural width taking
precedence.

`zig build counts` against `075fbbd`, in a local Docker container: every
declaration unchanged; the box tree's `endFrame` +1.36% (1,239,211 to
1,256,115), depth 64's +1.65%, 4,000 children's +0.47%, every text
scenario within +0.11%; branch mispredictions in the box tree's
`endFrame` unchanged (137,390 to 137,270).
`zig build bench-compare -- 075fbbd` (8 rounds) called no frame slower:
the box tree's `endFrame` +1.5% (0.0% to +1.7%), its declaration +1.0%;
only the first frame of the documents view, a startup time, came out
+4.4% (+3.1% to +6.0%).

## 06-text-and-layout:09-dividers-and-decorated-images — Dividers and decorated images

**Plan.** `Border.between_children`; image commands with `corner_radius`
and `tint`. **Done when:** snapshot tests for both. **Spec.** §10.1,
§13.1.

`Border.between_children` is the width of a divider between each two
adjacent children in the flow, emitted as a `rectangle` in the border's
color rather than a command of its own, so no renderer breaks. It is
centered in the gap, from the end of one child to the start of the next,
so alignment and scrolling move it with them, and it spans the element
across its flow inside the border's widths. Floating children take no
part. Dividers are emitted when the element's subtree ends, inside its
clip, so they paint over the children, scroll and are cut off with them,
and come before the border. `Border.widths` now defaults to zero, and a
border of zero widths emits no `border` command, so
`.border = .{ .color = line, .between_children = 1 }` draws dividers
alone. SPEC.md §10.1 now shows `Decoration` and `Border` and says so.

`Ui.Image` takes `tint` (white) and `corner_radius` (square), and the
`image` command carries both, with the same defaults so that renderers
and tests that build one with a handle alone still compile.
`zui_testing.snapshot` writes them when they are not the defaults. The
raylib and sokol renderers draw images without them until
`06-text-and-layout:13-image-tint-and-corners`.

Tests: dividers across a row with a border, sitting in the gaps inside
the border's widths, after the children and before the border; down a
column with no outline, skipping a floating child, with no `border`
command; in a clipping container, only the divider inside the clip,
between `clip_begin` and `clip_end`. An image command's default and
declared tint and corner radius, and `zui_testing`'s snapshot of both.

`zig build counts` against `5824aea`, in a local Docker container: every
declaration unchanged; every `endFrame` +15 instructions, but the
documents view's +1.36% (59,710 to 60,522), about 20 instructions in
`leave` for each of its 40 focusable rows, which leave a level of their
own and carry a decoration. Emitting the dividers inline, and comparing
the widths with `std.meta.eql`, had made it +1.86%; `emitDividers` is
never inlined, and `leave` reads the border through a pointer.
`zig build bench-compare -- 5824aea` (8 rounds): the box tree's
`endFrame` −0.8% and declaration +0.4%, the static-styled tree's −1.0%,
the documents view's `endFrame` +2.1% (−2.0% to +2.1%); called slower:
warm text's `endFrame` +2.8% (90.0 to 92.6 µs), which runs the same
instructions but 15, so code placement as
`06-text-and-layout:06-line-break-segmentation` found, and depth 64's
+4.8%, one step of its 0.1 µs resolution.
`zig build bench -- --check-targets` meets every budget: the box tree
declares in 51.0 µs and lays out and emits in 91.8 µs, warm text in 92.0
µs.

## 06-text-and-layout:10-floating-options — Floating options

**Grounding.** Every floating element got a hit region, so a tooltip
blocked what was under it; floating elements always escaped their
ancestors' clip; a target declared after the floating element fell back
to the parent. **Plan.** `Floating.capture`, `Floating.clip`, and later
targets placed after pass 6. **Done when:** interaction, layer and
golden tests for each. **Spec.** §8.4.

`Floating.capture` (true) and `Floating.clip` (`.none`, or `.target`).
With `capture = false` a floating element has no hit region of its own,
so the pointer reaches what it covers, while interactive elements inside
it still take it. `.clip = .target` cuts it off where its target's
children are: as a child in the flow for `.parent`, by the element's own
clip within its ancestors' for an element (found by walking up from it,
bounded, since it is not on the stack of open levels), and by the
viewport for `.root`. That clip, merged with the element's own, is one
`clip_begin` pushed in its layer before it draws, since sorting moves
the layer away from its ancestors' clips; its region is cut off with it.
To end that one clip after the border, every border is now emitted
before its element's own `clip_end`: it lies in the element's box, so
its own clip leaves it whole, and SPEC.md §13.2 says so.

A floating element whose target is declared later is placed against its
parent in pass 6, then placed again with its subtree once the pass is
over, in declaration order, so nested floating elements, `.root` ones
included, end up against their own targets. A target inside the floating
element's own subtree, or an id no element has, falls back to the
parent. `capture` and `clip == .target` are copied into the element's
flags at declaration, so emission reads them without the floating
config.

Tests: a menu attached to a later element, its child moved with it and a
`.root`-attached element inside it left in the corner; a later target in
a scrolled list followed where the scroll put it; a target inside the
subtree falling back to the parent; a floating element clipped to its
parent's clip, to a row of a scrolled list (with its own clip and border
in one clip pair) and to a target outside every clip; a tooltip with
`capture = false` passing the pointer to the button under it while a
chip inside it is hovered; a flyout clipped to its pane taking the
pointer only inside the pane; a button attached to a later target
clicked where it is drawn. The randomized trees float elements with
random `capture` and `clip`, attached to earlier, later, inner and
missing targets.

`zig build counts` against `96cbb40`, in a local Docker container: every
declaration unchanged; the box tree's `endFrame` −0.41% (1,256,130 to
1,251,001), depth 64's −1.96%, 4,000 children's +1.39%, warm text's
+0.51%, the documents view's +0.38%. The first versions cost up to +21%:
emission reading the floating config for every element, a `Level` field
for the target's clip, and a call to place floating elements that kept
the passes' hot loops from staying in registers. Testing whether an
element draws anything in emission's loop, before `enter`, is what
brought the box tree and depth 64 below their old counts.
`zig build bench-compare -- 96cbb40` (6 rounds): the box tree's
`endFrame` −0.4%, the static-styled tree's −1.4%, depth 64's −4.5%;
called slower: warm text's `endFrame` +8.1% (92.5 to 99.7 µs),
single-line text's +2.7% and 4,000 children's +3.6%. Callgrind's branch
and cache simulation of warm text gives the same mispredictions and
misses as `96cbb40`, and 0.5% more instructions, so this is where the
code lands, as `06-text-and-layout:06-line-break-segmentation` found,
and not work added. `zig build bench -- --check-targets` meets every
budget: the box tree declares in 50.7 µs and lays out and emits in 91.2
µs, warm text in 99.8 µs.

## 06-text-and-layout:11-right-to-left — Right-to-left layout

**Plan.** `Direction.right_to_left`, `Layout.mirrored`, and logical
padding, alignment and anchors, following the environment's direction.
**Done when:** golden tests mirror every alignment and anchor. **Spec.**
§8.1.

`Layout.mirrored` is `zui.Mirrored`, `.inherit`, `.yes` or `.no`: an
element is mirrored by its own, else by its parent's, and the root by
the environment's `direction`. A `?bool`, as SPEC.md had it, is two
bytes and would have made every `Layout` 60 bytes instead of 56, the
size that made the box tree's `endFrame` 6.7% slower in
`06-text-and-layout:08-aspect-ratio-and-natural-sizes`; SPEC.md §8.1 now
says so. `Direction` gains `right_to_left`, which reverses an element
for its own children alone, as CSS `row-reverse`, so in a mirrored
element it flows from the left. An element places its children from the
right when it is mirrored or `right_to_left`, not both: the position
pass lays them out as before, then reflects them across the parent's
box, which carries the padding (`left` is the start side), the alignment
on both axes and the scroll offset over with them, and a floating
child's position across the box it attaches to, which reflects its
anchor, attach point and offset. A mirrored text's `.start` and `.end`
swap, in the text record, so the text path does no work for it. A
reversed scroll container's horizontal offset grows to the left, and its
region carries `scroll_x_reversed`, so the wheel's physical delta moves
it the way the pointer goes. Dividers sit in the gap between two
children whichever way they flow. Positions and borders stay physical.

Nothing is paid for it in a frame that does not mirror.
`Frame.may_mirror` starts true only in a right-to-left environment;
otherwise the position pass looks at each parent's `direction` and
`mirrored` and, at the first that mirrors, starts again with a copy of
the pass that works out each element's `mirrored` and `reversed` flags.
Detecting it at declaration instead cost the static-styled tree's
declaration 5.4% more instructions, since a static style's layout is not
folded there.

Tests: each of the nine alignments of a row and a column, with uneven
padding, mirrored by the environment, by an ancestor's
`.mirrored = .yes` and by the row's own `right_to_left`, is the
left-to-right layout reflected; and one by hand. Each of the 81 anchor
and attach point pairs, for a parent, the root and an element target,
likewise, and a menu by hand. A text's alignments; `.no` and `.yes`
overriding the parent, and `right_to_left` in a mirrored row flowing
from the left; a mirrored scroller starting at its right edge and
following the wheel; a reversed row's dividers; a frame that cannot
mirror setting no flag. The randomized trees declare `right_to_left` and
`mirrored`, check that children start inside the content box at the
right for a reversed parent, and 500 of them, laid out in a
right-to-left environment, are the left-to-right trees reflected,
element by element.

`zig build counts` against `68545eb`, in a local Docker container: the
box tree's declaration +0.94% (436,051 to 440,150), one store per
element for the `mirrored` byte that was padding, and every other
declaration within +0.54%; the box tree's `endFrame` +0.82% (1,251,001
to 1,261,249) and depth 64's +1.00%, from looking at each parent's
`direction` and `mirrored`; the documents view's +0.86%; warm text's
+0.03% (1,036,264 to 1,036,572), and every other text scenario within
+0.05%. `zig build bench-compare -- 68545eb` (6 rounds): declarations
−1.1% to +0.3%; the box tree's `endFrame` +1.0%, the static-styled
tree's +1.8%, warm text's +1.5% (100.0 to 101.1 µs), with the same
instructions but 308; called slower only depth 64's declaration, one
step of its 0.1 µs resolution, and `initBuffer`, a startup time this
does not touch. `zig build bench -- --check-targets` meets every budget,
over three runs: the box tree declares in 50.4 to 51.0 µs and lays out
and emits in 92.1 to 93.2 µs, warm text in 101.3 to 101.7 µs.

## 06-text-and-layout:12-wrap — Wrap

**Plan.** Wrapping for rows that opt in, compiled out without
`features.flex_wrap`, which `03-contracts:04-features` added; asking for
it with the feature off fails as a gated API does. **Done when:** golden
tests for wrapping under each alignment, and with the feature off,
`01-measure:03-instruction-counts-in-ci` counts are unchanged. **Spec.**
§8.1, §8.2.

A row wraps when `ui.wrapChildren()` is called after its `open`, not by
a `Layout.wrap` field as SPEC.md had it: a field's value is not known at
compile time, so it could not fail with
`"zui: wrapChildren() needs Config.features.flex_wrap = true"`, and
`Layout` has no byte free, so a field would make it 60 bytes, the size
that made the box tree's `endFrame` 6.7% slower in
`06-text-and-layout:08-aspect-ratio-and-natural-sizes`. The call sets an
element flag, the last free bit, and a column ignores it. SPEC.md §8.1
and §8.2 now say so, and that the work is spread over the existing
passes rather than in a pass of its own between distribution and
positioning, where a fit row's height could no longer follow its lines.

Pass 1 sizes a wrapping row from its children: as wide as one line, no
narrower than its widest child's minimum. Pass 2 breaks the children
into lines at the size each rule asks for before free space is handed
out, recording each line's first child in `Frame.starts_line`, an array
that is empty without the feature, then grows or shrinks each line as a
row, so a child wider than the row takes a line of its own and shrinks
to it. Pass 4 makes the row as tall as its lines, each as tall as its
tallest child and `child_gap` apart; pass 5 stretches a growing height
to its line; pass 6 places line by line, `child_alignment.y` placing the
lines as a group and each child in its line, `.x` each line along the
row, and reflects them when the row is mirrored. Dividers sit between
the children of a line, as tall as the line, and between the lines,
across the row. Each step is behind `features.flex_wrap` and out of
line, so a frame that does not wrap pays one flag test per parent, and
nothing without the feature.

Tests: every alignment of a two-line row, against the formula and once
by hand, and mirrored, the row reflected; growing children sharing each
line's free space; a text wider than the row on a line of its own,
wrapping; a fit row as wide as one line, narrowing in a narrower column;
a growing height stretched to its line; a floating child outside the
lines; a column that does not wrap; a gallery scrolling through its
lines; dividers in a line and between lines; and the compile error. The
test context turns the feature on, and the randomized trees wrap one
container in six, checking that each line fits unless it holds one
child, leaves space only when its growing children are at their max, and
lies below the one before, and still mirror exactly.

`zig build counts` against `0bd3ac2`, in a local Docker container, with
the feature off as in every benchmark: every declaration within ±2
instructions; warm text's `endFrame` unchanged (1,036,572), and every
other text scenario too; the box tree's −0.28% (1,261,249 to 1,257,778),
the documents view's −0.14%, 4,000 children's +0.06%, depth 64's −0.02%,
from `grow`, `growFromMin` and `shrink` taking the children to share
rather than the parent. Sharing the rest of distribution's steps with
the wrapping path had cost the box tree +1.47%, so `distribute` keeps
its own. `zig build bench-compare -- 0bd3ac2` (6 rounds): warm text's
`endFrame` −9.8% (101.4 to 91.4 µs) on the same instructions, back from
the drift of `06-text-and-layout:08-aspect-ratio-and-natural-sizes` to
`06-text-and-layout:11-right-to-left`; the box tree's +1.3% and the
static-styled tree's +1.2%, on fewer instructions; none called slower.
`zig build bench -- --check-targets`, over six runs, met every budget in
five: the box tree declares in 49.8 to 51.0 µs and lays out and emits in
93.6 to 95.0 µs, warm text in 90.5 to 91.2 µs; one run's box-tree
declaration came out at 65.3 µs, its other scenarios slower alike, on
code this item does not change.

## 06-text-and-layout:13-image-tint-and-corners — The backends draw images' tint and corner radius

**Grounding.** Since
`06-text-and-layout:09-dividers-and-decorated-images` the `image`
command carries `tint` and `corner_radius`, but the raylib renderer
draws an image with its handle and bounds alone
(`renderers/raylib/src/root.zig:541`,
`drawTexture(image.handle, bounds)`), and so does the sokol renderer
(`renderers/sokol/src/renderer.zig:185`); the terminal renderer has no
images. The renderer suite's reference scene declares an untinted,
square image.

**Plan.** Each backend multiplies the tint into the image and rounds its
corners; the renderer suite's reference scene declares a tinted image
with a corner radius and checks a pixel inside it and one in a corner.

**Done when:** the raylib and sokol renderers pass the extended renderer
suite in CI.

**Spec.** §10.1, §13.1, §16.2.

**Status.** Done. The renderer suite's reference scene declares its
image with a tint, `0xffff80`, and corners rounded by 12 units, and
checks the pixel at its center for the image's color times the tint,
`0x00ff80`, and the pixels just inside its top-left and bottom-right
corners for the background behind it. A renderer that draws the image
untinted, or that replaces its pixels with the tint, is a whole channel
off at the center; one that draws it square fills the corners.
`zui_testing`'s own software renderer multiplies the tint and tests each
pixel against the rounded corners, and a flawed copy of it that draws
images untinted and square fails with
`drew #00ffff at (32, 112) in the reference scene, where a tinted image of one color should be #00ff80`.

The sokol renderer sets the tint as the vertex color, which sokol_gl
multiplies into each texel, and draws a rounded image as a fan of
textured triangles from its center over the outline its rounded
rectangles already trace, each corner with its own radius. raylib
multiplies a texture by a tint too, but cannot round one, so the raylib
renderer draws a rounded image the same way through rlgl, wound
counter-clockwise on screen as raylib's culling wants, with each
corner's own radius, though its rectangles round all four corners by the
largest. A square image is drawn as before, one quad, with the tint.

Neither renderer's code changes beyond drawing images, and the terminal
renderer, which has no images, does not change. The raylib renderer's
renderer and host suites and the sokol renderer's renderer suite pass on
Windows, and the raylib renderer's old drawing fails the extended suite
with the message above; CI runs the suites on Linux under `xvfb-run`.
The core is unchanged, so its instruction counts and times are too.

## 06-text-and-layout:14-layer-sort — The layer sort

**Grounding.** Any frame with a floating element ran `std.sort.block`
over all its 80-byte commands. With a tooltip declared before a
3,000-cell grid, `endFrame` took 670.9 µs, against 81.3 µs declared
after it.

**Plan.** Sort only what is out of place. **Done when:** both tooltip
scenes are faster by `bench-compare`, and no scenario is slower.

A frame's commands change layer only where emission enters a floating
element or leaves one, so the emitter records each run of commands
outside layer 0 there, and `push` is unchanged. After emission, the runs
are gathered into the unused end of the commands; layer 0's commands
close up behind them, each moving at most once and not at all when no
run comes before them; the gathered runs are sorted only if their layers
were emitted out of order, and copied back in place, the layers below 0
rotated in front. Past 64 runs, or without room at the end, the whole
frame is sorted as before. The `sort_layers` zone now runs when a frame
draws outside layer 0, not when it merely declares a floating element.

`zig build bench-compare -- fb3c7bd` (100 rounds over 3 layouts, turbo
off, pinned): tooltip first −88.2% (671.0 to 79.4 µs), tooltip last
−9.8% (81.3 to 73.4 µs); nothing slower. `zig build counts`: tooltip
first's `endFrame` −86.4% (5,853,440 to 798,765 instructions), tooltip
last's −7.6%; the other scenes' `endFrame` +0.1% to +1.0%, from the
layer check when a level ends.

Tried and dropped, each measured by `counts`:

- **layered commands written backwards from the end in `push`,** as the
  audit sketched: up to +2.9% instructions in scenes with no floating
  element, as `push` choosing between two destinations kept LLVM from
  building each command in place;
- **one cursor and step in `push`, switched out of line:** up to +5.5%,
  from the call on its path;
- **the level's clip and layer endings in one packed byte:** up to
  +3.7%.

**Spec.** §16 (the tracer's zones), §17.2.

## 06-text-and-layout:15-id-rect-table — A narrow id → rect table

**Grounding.** `Results.entries` was `nextPowerOfTwo(2 × max_elements)`
slots of 32 bytes, 256 KiB at the default limits, written at random once
per element with an id and read by `widgetState`, `rectOf`, coasting and
zoom; `regionFlags` then read the region as well.

**Plan.** Slots that index dense entries. **Done when:** the interactive
scenes are faster by `bench-compare`, and no scenario slower.

Each slot now holds the smallest index type into `entries`, which are
dense in emission order: 16 KiB of slots at the default limits, 2 bytes
each. `slot_of_entry` keeps the slot each entry took, so `clear` empties
only those, and each entry carries its region's flags in what was its
padding, so `widgetState` reads no region. `Results` is 96 KiB smaller.

`zig build bench-compare -- d0809fd` (100 rounds over 3 layouts, turbo
off, pinned): `4096 interactive boxes` −5.9% (191.5 to 179.0 µs) and its
declaration −7.2% (124.8 to 115.2 µs); pressed −5.7% and −8.5%; `init`
−26.9% (138.3 to 101.0 µs) and `initBuffer` −50.5% (17.0 to 8.4 µs),
which empty the smaller table; nothing slower. `zig build counts`: the
interactive scenes' `endFrame` +1.3% instructions, with 3.1% fewer
simulated D1 misses, and their declaration −0.3%, with 3.2% to 4.1%
fewer.

**Spec.** §5, §11.

## 06-text-and-layout:16-one-hit-test-per-press — One hit test per press

**Grounding.** A primary `pointer_down` ran `Results.topmostAt` in
`refreshHover`, `longPressOwner` and `recognizerAt`, and `startZoom` a
fourth time when another contact was down, each at the same point over
the same results.

**Plan.** Hit-test once per press. **Done when:**
`4096 interactive, pressed` runs fewer instructions in its declaration
by `counts`, and no scenario is slower.

The press hit-tests once and hands the region to the four; a move, a
release and the wheel still hit-test for themselves. `zig build counts`
against `b0106bd`: `4096 interactive, pressed` declares in 2.6% fewer
instructions (1,303,365 to 1,269,280, `beginFrame`'s events included),
with 10.3% fewer simulated D1 misses; nothing else changed.
`zig build bench-compare -- b0106bd` calls nothing faster or slower: the
scene presses on every other frame, and `bench` keeps each scene's
fastest frame, which is always a release, so the clock cannot see a
press. `4096 interactive, clicked every frame` was added after it to
time one: with that scene on both, `bench-compare` (100 rounds over 3
layouts, turbo off) times its declaration 3.9% faster (137.3 µs to 131.9
µs, 95% interval −4.5% to −3.1%) and calls nothing slower.

**Spec.** §11.

## 06-text-and-layout:17-wrapped-lines-cached — Wrapped lines kept with the string cache

**Grounding.** `wrapTexts` wrapped every text wider than its box from
its bytes every frame, though a warm hit in the string cache already
proved the text unchanged. Under Callgrind, `wrapTexts` was 47% of warm
text's `endFrame`.

**Plan.** Keep the lines of a text's last wrap beside its cache entry.
**Done when:** warm text is faster by `bench-compare`, cold text no
slower, and the string cache's growth is recorded.

`measureText` now writes the metrics into the text's record and returns
the index of its string's entry, or `new_string` for a string it had to
measure; the record keeps the index in what was padding, so it stays 64
bytes. `wrapTexts` writes a text that fits on one line itself, without
calling into the wrap. A text that wraps first looks at its entry: if
the entry was last wrapped at exactly this width, its lines are copied
and nothing is measured or walked. Otherwise the text is wrapped and,
for a string found rather than measured, its lines kept when there are
at most 4 of a text under 64 KiB. Lines are kept in an array beside the
entries, so a frame that only measures never touches them. An entry
records the generation it was measured in, so a text whose entry another
string takes later in the same frame neither reuses nor keeps lines
there.

The string cache grows by 8 bytes an entry and 36 bytes of lines an
entry, 44 KiB at the default 1,024 entries; SPEC.md §20.2 has no memory
budget.

`zig build bench-compare -- adc5677` (100 rounds over 3 layouts, turbo
off, pinned): warm text −43.4% (123.0 to 69.6 µs), the documents view
−12.5%, single-line texts −9.7% (60.8 to 54.9 µs), depth 64 −1.7%.
Slower: `init` +3.4% (101.6 to 105.2 µs) and `initBuffer` +1.5% (8.4 to
8.5 µs), from the larger cache; cold text +0.7% (263.2 to 265.3 µs); new
strings +0.3%, within noise. `zig build counts`: warm text's `endFrame`
−36.8%, single-line −7.1%, documents view −11.9%; cold text +1.4% and
new strings +1.3%, for the index and the two fields of every string they
measure.

Tried and dropped:

- **looking the string up again by its key in `wrapTexts`,** with an
  8-byte key in the record: cold text +7.6% instructions;
- **one flag for a frame in which any entry in use was given up:** the
  warm text wall fills 98% of the cache, so the flag was set every frame
  and nothing was reused;
- **a 4-byte index in the record,** which made it 68 bytes: +2
  instructions a text in declaration.

**Spec.** §9.3.

## 06-text-and-layout:18-string-cache-keys-apart — The string cache's keys apart from its values

**Grounding.** Under Callgrind's cache simulation, 39% of cold text's
simulated D1 read misses in `endFrame` (67,646 of 174,532 over 10
frames), and 34% of new strings', fell on one line: the string cache's
probe in `lookupOrClaim`. A text it has not seen walks the whole probe
window for the least recently used entry, and every step lands on a
different 112-byte entry, about 7 misses a text.

**Plan.** Keys and ages in arrays of their own. **Done when:** the cold
scenes are faster by `bench-compare`, warm text no slower.

`LruTable` takes a `KeyLayout`: the string cache keeps its keys and ages
apart from its values, so a window's 8 keys share one or two lines; the
segment cache, probed once a word and hit on its first step, keeps each
key with its 8-byte value, which a hit reads in one line.

`zig build bench-compare -- 5d2eb30` (100 rounds over 3 layouts, turbo
off, pinned): cold text −2.0% (265.2 to 260.0 µs), warm text −1.2% (69.7
to 68.9 µs), single-line texts −1.1%, `init` −11.9% (104.9 to 91.8 µs),
whose reset now walks 8 KiB of keys rather than every entry,
`initBuffer` −1.3%; nothing slower. This wins back what
`06-text-and-layout:17-wrapped-lines-cached` cost cold text and `init`.
`zig build counts`: the cold scenes' `endFrame` −0.7% instructions with
17.4% fewer simulated D1 misses; warm text's has 5.4% more, from its key
and its value now on two lines.

Tried and dropped: **both tables split:** +6% to +7% instructions in the
cold scenes, from three addresses to work out at each of the segment
cache's probes, once a word. Not tried: prefetching the next texts'
keys, which the audit also proposed.

**Spec.** §9.3.

## 06-text-and-layout:19-flat-child-lists — Flat child lists

**Grounding.** `Frame.Children.next` (`core/src/context.zig:487`) and
`FlowChildren` (`core/src/layout.zig:76`) step to each sibling through
`subtree_end`, one dependent load at a time.

**Plan.** Only after `perf` attributes cycles of
`4000 children of one parent` to these walks: child indices in one
array, built after declaration from `child_counts` and a prefix sum.
`06-text-and-layout:04-box-tree-layout-budget` recorded that reshaping
these passes cost 3% to 17% before.

**Done when:** the wide tree is faster by `bench-compare` and the box
tree no slower; or retired with the profile.

**Retired by the owner,** on the profile taken at `85242fc` and
`a4dfbf4`; nothing was built. Under Callgrind, `Children.next` takes
24,000 steps a frame in `4000 children of one parent`, 5.5% of its
`endFrame` instructions. `bench --counters` (turbo off, pinned) counts
that `endFrame` at 877,162 instructions in 289,703 cycles, 3.0 a cycle,
with 34 branch misses and no last-level misses: a pass waiting on a
chain of dependent loads could not keep that rate. The box tree runs 3.1
a cycle. `perf record -e cycles:upp` over 40 runs of the scene (35,520
samples) puts 0.9% of its cycles on the walk's lines
(`context.zig:489-491`), against 21% in `distribute` and `position` as a
whole: the time goes to each child's work, most of it reading the
child's sizing through its `layout` pointer (`context.zig:506`, `:517`)
and its size, not to finding the next child. A flat child list could
save at most that 0.9%, and would build two more passes every frame.

## 06-text-and-layout:20-text-commands-point-at-style — Text commands that point at their style

**Grounding.** `RenderCommand.Text` (`core/src/commands.zig:85`) holds a
copy of its `TextStyle`, 20 bytes of its 40, and `emitText`
(`core/src/emission.zig:330`) copies the record's style into every line.
A command is 80 bytes.

**Plan.** `style: *const TextStyle`, pointing at the text record's
style, which the frame holds until it is released as it holds `content`.
Renderers read `text.style.size` unchanged. `zui_wire` sends a single
pointer as what it points at, and keeps a copy beside the command's text
in its histories and the remote's slots.

**Done when:** a renderer reading a text-heavy frame's commands is
faster by `bench-compare`, and no scene is slower.

**Status.** Measured at `9154f3f` in the core alone, then set aside on
the branch `p12-text-style-pointer` (`7e9d2fb`, off `fb3c7bd`), whose
commit message lists what is left. A command becomes 72 bytes, not
fewer, since a border's 36-byte payload then sets the union's size, and
a text payload 32. By `counts`, the text scenes run 0.06% to 0.24% fewer
instructions and their simulated D1 misses change by under 0.1%, while
`4096 interactive boxes`, which draws no text, runs 1.17% more. No scene
reads the commands as a renderer does, which is where the audit put the
saving. `1000 labels, rendered` (`core/bench/scenes.zig`) now does:
1,000 single-line labels in 8 bordered columns, all inside the viewport,
whose commands are read after each frame as the sokol and raylib
renderers read them, each command's bounds and payload and, for a text,
its style and every byte of its content, a pen advanced glyph by glyph.
`bench` times the read as a phase of its own (`, read`), and `counts`
counts it: 35.5 µs and 244,757 instructions a frame at its commit, from
about 1,000 text commands and 16 for the columns.

Carried onto `main` after `a021c1d` and finished, then judged and not
shipped: parked on `p12-text-style-pointer-on-main` (`7e27942`), which
supersedes `p12-text-style-pointer`, with the terminal renderer's two
tests changed beside it. A context that clamps `ExtendedColor` points
its commands at a clamped copy per text record,
`Frame.clamped_text_styles`, which exists only there; `zui_wire` copies
the style beside the text in its histories and the remote's slots. The
raylib and sokol renderers pass against it unchanged; the web host's
tests, which build three text commands by value, were not updated. Every
check passes. `bench-compare -- a021c1d --require-quiet` (100 rounds
over 3 layouts, turbo off, pinned): the read +0.4% (+0.1% to +0.9%),
within its band, so not faster; called slower, beyond their bands, are
`4096 interactive boxes`' declaration +2.3%, the documents view's +2.4%,
both cells scenes' +0.8% and +1.3%, warm, single-line and cold text's
+1.1% to +1.2%, and `depth 64`'s `endFrame` +1.3%. By `counts`, the read
runs 0.76% more instructions with 45.6% more simulated D1 misses (1,917
to 2,791 a frame): the style becomes a load from the frame's text
records, away from the command the renderer is already reading, while
every `endFrame` runs 0.05% to 1.09% fewer instructions. The saving the
audit predicted is not there for a renderer that reads the commands in
order.

**Retired by the owner** on those measurements. The scene stays on
`main`.
