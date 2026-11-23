# Plan: zui's default design

zui's own look, its colors in light, dark and high contrast, its type,
spacing, shape, elevation and motion, and the built-in components it
styles, as the owner approved them from the showcase at
<https://claude.ai/artifact/TR8QmQsFoHdqBdu58p7ryP>. This plan said how
it lands in zui, step by step. Every step is now an item of
`roadmap/11-polish.md`, in the queue of `ROADMAP.md`, and each item's
entry is where its plan, its Done when and its status are kept; this
file is the record of how they were made, and `exports/` stays the
reference the components are built from and the tests compare against.

| Step | Item |
|---|---|
| D1 | `11-polish:19-default-design`, slice 1, done |
| D2 | `11-polish:19-default-design`, slice 2, done |
| D3 | `11-polish:19-default-design`, slice 3 |
| D4 | `11-polish:27-essential-inputs`, with the toggle and the existing widgets' remaining spec |
| D5 | `11-polish:28-containers-and-navigation` |
| D6 | `11-polish:29-overlays` |
| D7 | `11-polish:30-feedback-and-media`, with the progress bar, the async image and a categorical palette |
| D8 | `11-polish:31-rich-text-and-reordering` |
| D9 | `11-polish:32-zui-widgets-data` |
| D10 | `11-polish:33-pickers` |
| D11 | `11-polish:34-zui-widgets-views` |
| — | `11-polish:35-italics`, for rich text's emphasis |
| — | `11-polish:36-motion-in-core`, so the widgets reach the motion tokens |
| — | the text area, in `11-polish:06-text-editing` |
| — | the icons the components need, listed in `11-polish:07-zui-icons` |
| — | the personalities, reference for `11-polish:08-zui-themes` and `11-polish:10-samples` |

## The files here

| File | Holds |
|---|---|
| `exports/zui-default-design.json` | everything: the `Design`, every role's tone in all four schemes, the layer shares, the resolved hex of every role in every state, the text styles at text scale 1 and 1.5, the metrics, elevation, motion, the accent presets, the personalities, each component's spec, the changes to zui, and every contrast check with its measured value |
| `exports/color-roles.zig.txt` | the `ColorRole` enum with the 12 new roles, and `partnerOf`, `kindOf` and `tierOf` |
| `exports/tones.zig.txt` | the four schemes' tone tables, in the shape of `tones` in `core/zui_design/palette.zig` |
| `exports/design.zig.txt` | `TypeRole` with `label_strong`, `zui_design.default`, each type role's scale step and font |
| `exports/tokens.zig.txt` | control heights and icon sizes per density, the focus ring, the target floors, the elevation levels per scheme and the motion tokens |
| `exports/resolved-colors.md` | each role's resolved color, idle, hovered and pressed in light and dark, idle in high contrast |
| `personalities/quiet-instrument.json`, `personalities/crisp-technical.json` | the two other personalities the showcase sketched: each one's `Design` fragment, preferences and skin choices, the CSS the page drew it with, and its colors as resolved from its seeds |

The files in `exports/` are the showcase's six Copy texts, byte for
byte, with no final newline. The Zig drafts are fragments that name
`std`, `Scheme` and other declarations of the files they go into, so
they are kept as `.zig.txt`; `zig fmt` and `zig ast-check` would refuse
them as `.zig`. `.mdformat.toml` excludes `exports/` so the formatter
leaves the Markdown table as it was copied.

## How the values were made

The showcase computed every color with a port of `zui_design`'s own math
to JavaScript: each role a lightness on one of five ramps, gamut-mapped
by chroma as `gamutMappedLinear` does, encoded to bytes as
`byteOfLinear` rounds, the state layers mixed in OKLab toward each
fill's partner with the shares `contrast.layerShares` would search, and
contrast measured in APCA 0.0.98G-4g and WCAG 2. So
`resolved[scheme][role][state]` in the JSON is what
`zui_design.resolve(zui_design.default, …)` must write once the tones
and roles land, to the byte.

Two parts of the resolver were not ported, so they are checked when it
lands rather than trusted from the sketch:

- `color_vision.separateStatusRoles`, which moves the status fills apart
  in lightness. A comptime resolve of the default design fails the build
  if it would move one, so that build is the check.
- `contrast.solve`, which repairs a failing pair. Every pair passes as
  the tones stand, 252 checks in four schemes, so it should move
  nothing; `Repairs` must come back empty.

Every check also passes for the eight accent presets and for both
personalities' seeds. The JSON's `checks` lists them with their values.
Beyond the resolver's own pairs, they include the text roles on every
surface text sits on, which `rows hover in secondary_container` below
depends on.

## Where the resolver differs from the export

D1 found three places where `resolved` in the JSON is not what the
resolver writes, and the resolver was kept in each:

- **`danger`.** It shared `success`'s lightness in every scheme, so the
  two collapsed under simulated tritanopia and achromatopsia, and the
  comptime resolve failed, as the check above foresaw. By the owner's
  choice `danger` is darker: L 0.355 in light and dark, 0.24 in high
  contrast. Its resolved bytes in the JSON are out of date.
- **The surfaces' layers.** The port searched each surface's layer share
  against the text role partnered with it alone, but `on_surface` sits
  on every surface. In light `surface_sunken` and in light high contrast
  `background`, `surface_raised`, `surface_sunken` and `surface_overlay`
  its full layers would take `on_surface` below its target, so the
  resolver gives them less.
- **`outline_muted` disabled.** The port left it as it was; the resolver
  greys and fades every foreground role.

`core/zui_design/default_tests.zig` compares every other value to the
byte.

## What the design decides

- **Consumer apps first.** Comfortable density, Atkinson Hyperlegible at
  16 (x-height 6.4) on a 1.2 scale, `continuous` corners, controls
  `smooth` (8) and containers and popups `soft` (16), chips and
  indicators pills.
- **One accent on cool neutrals.** Seeds: accent L 0.55, C 0.17, H 258;
  neutral C 0.008 at the same hue. Eight presets, each a hue and chroma.
- **Fills before lines.** Fields and secondary buttons are tonal fills;
  a line shows only a state.
- **Dark designed, not inverted.** In dark, height is a lighter surface
  and a lit `rim`, the accent as text is lighter and softer, and the
  containers are deep tints.
- **Four elevation levels.** 1 for cards, 2 for menus, popovers and
  tooltips, 3 for dialogs and toasts, 4 for the command palette and a
  dragged row. Each is one shadow, since an element draws one
  (`core/src/style.zig:787`), plus a 1-unit rim.
- **57 components in three modules.** 39 in `zui_widgets`, 12 in a new
  `zui_widgets_data` and 6 in a new `zui_widgets_views`, each with a
  spec of parts, roles, tiers, sizes, variants, states and keys in the
  JSON's `components`.

## What it changes in zui

At `6aeed25`:

| Where | Change |
|---|---|
| `core/src/design.zig:10`, `ColorRole` | 12 new roles: `surface_overlay`, `on_surface_accent`, `danger_container`, `on_danger_container`, `warning_container`, `on_warning_container`, `success_container`, `on_success_container`, `selection`, `on_selection`, `shadow`, `rim` |
| `core/zui_design/palette.zig:162`, `:229`; `core/zui_design/contrast.zig:70` | each new role's partner, kind and tier. `shadow` and `rim` are kind `scrim`: never layered, never greyed when disabled |
| `core/zui_design/palette.zig:268`, `tones` | the four tables replaced |
| `core/zui_design/palette.zig:121` | `shadow` and `rim` exempt from `reduced_transparency_alpha`, which would raise a 7% rim to 85% |
| `core/src/design.zig:43`, `TypeRole`; `core/zui_design/zui_design.zig:415`, `:466` | `label_strong`, step −1 in the strong font; `title`, `headline` and `display` in the strong font |
| `core/src/design.zig:423`, `Tokens` | control heights and icon sizes per density, the focus ring's offset, elevation levels 1 to 4 |
| `core/zui_design/` | `zui_design.default`, with fonts left for the application |
| `core/zui_widgets/zui_widgets.zig:216` | `DefaultSkin` replaced by `DesignSkin` over tokens, as `11-polish:19-default-design` already plans |

## Steps

Each step is a roadmap item, one commit or a few slices, every check
green after each. D1 to D3 are `11-polish:19-default-design`, which
exists and waits for nothing that is not done; the rest are new items,
numbered from 27, the next free number in `roadmap/11-polish.md`.

| Step | Item | What it builds | Where | Waits for |
|---|---|---|---|---|
| D1 | `11-polish:19-default-design`, slice 1 | the 12 roles, `label_strong` and bold headings, the tones, the exempt alpha, the new `Tokens` fields, `zui_design.default` | `core/src/design.zig`, `core/zui_design/` | |
| D2 | `11-polish:19-default-design`, slice 2 | `DesignSkin`: the 12 existing widgets to their specs, `DefaultSkin` removed | `core/zui_widgets/` | D1 |
| D3 | `11-polish:19-default-design`, slice 3 | the tour and the showcase on tokens, the tour's preferences screen | `apps/tour/`, `apps/showcase/` | D2 |
| D4 | `11-polish:27-essential-inputs` | radio group, segmented control, number stepper, search field, icon button, link, chip | `core/zui_widgets/` | D2, `11-polish:07-zui-icons` |
| D5 | `11-polish:28-containers-and-navigation` | card, divider, scroll area, group box, tabs, sidebar list, breadcrumbs | `core/zui_widgets/` | D2 |
| D6 | `11-polish:29-overlays` | tooltip, menu and context menu, popover, dialog, toast | `core/zui_widgets/` | D5 |
| D7 | `11-polish:30-feedback-and-media` | banner, badge, spinner, skeleton, empty state, avatar | `core/zui_widgets/` | D2, `11-polish:07-zui-icons` |
| D8 | `11-polish:31-rich-text-and-reordering` | rich text and Markdown, the reorderable list | `core/zui_widgets/` | D5, `11-polish:06-text-editing` for selection in rich text |
| D9 | `11-polish:32-zui-widgets-data` | the module, with table, tree, split pane, toolbar, status bar, command palette and property grid | `core/zui_widgets_data/` | D6 |
| D10 | `11-polish:33-pickers` | color picker, calendar, date picker, time picker, drop zone | `core/zui_widgets_data/` | D9 |
| D11 | `11-polish:34-zui-widgets-views` | the module, with code and log view, sparkline, chart, timeline, node graph, minimap | `core/zui_widgets_views/` | D2 |

The personalities are not items. They are reference for
`11-polish:08-zui-themes`, whose design languages start from
`zui_design.default`, and for `11-polish:10-samples`, where one could
show the same app in another design.

### D1: the vocabulary and the default design

**Grounding.** The roles at `core/src/design.zig:10`, the tones at
`core/zui_design/palette.zig:268`, the text styles at
`core/zui_design/zui_design.zig:466`, the radii at `:241`.

**Plan.** Take `exports/color-roles.zig.txt` into `core/src/design.zig`
and the partner, kind and tier switches; `exports/tones.zig.txt` into
`palette.zig`; `exports/design.zig.txt` into `TypeRole`, `scaleStepOf`,
`writeTextStyles` and a new `core/zui_design/default.zig` exported as
`zui_design.default`; `exports/tokens.zig.txt` into `Tokens` and
`resolve`. Each new `pub` declaration gets its doc comment. Every place
that switches over `ColorRole` or `TypeRole`
(`grep -rn 'ColorRole\|TypeRole' core apps themes`) gains the new cases.

**Done when.** A test resolves `zui_design.default` in each scheme and
each state and compares every role to `resolved` in
`exports/zui-default-design.json`, exactly; another compares the text
styles at text scale 1 and 1.5 to `text_styles`; the default resolves at
comptime with no repairs, which also proves no status fill was moved;
each accent preset's seed passes at run time with an empty `Repairs`;
`zig build test` in three modes, `check` for `wasm32-freestanding` and
`powerpc-linux`, `test-all` and `check-all`.

### D2: `DesignSkin`

**Plan.** As `11-polish:19-default-design` plans: each `Part` declares
its appearance from the JSON's `components` entry for its widget
(`button`, `checkbox`, `toggle`, `slider`, `text_field`, `text_area`,
`dropdown`, `disclosure`, `progress_bar`, `label`, `labeled_row`,
`async_image`), and `zuiStyle` answers from `tokens.look`. A spec value
that names a role, a tier, a control height or a shape role is taken
from tokens; a literal (a 2-unit caret, an 18-unit box) is a constant in
the skin.

**Done when.** `11-polish:19-default-design`'s own Done when, and every
widget's appearance meets SPEC.md §18.4 in every scheme and density by
the audit.

### D3: the tour and the showcase

As `11-polish:19-default-design`'s plan step 3. The tour's palette
(`apps/tour/src/shared.zig:218`) moves to tokens, which closes the 2,350
text contrast findings its test expects today.

### D4 to D11: the new components

Each component is built from its entry in the JSON's `components`: its
`api` is the starting signature, its `parts` the appearance each part
declares, its `variants`, `states` and `keyboard` the behavior. Each
item:

- adds its widgets to `Widgets(Ui, Skin)`, or to the new module's
  equivalent, with semantics, keyboard operation and accessibility
  actions, as SPEC.md §19.2 requires of every control;
- declares a `zuiPreviews` for each component, so `Permutations` and the
  review app see it;
- exercises each generic API in `core/tests/instantiate.zig`;
- puts a screen or a section of one in the tour where a user would meet
  it.

**Done when,** for each: `zui_testing.Driver` tests of every state and
key the spec lists; the audit clean for each component's `glance`
permutations in every scheme and density; nothing allocated after
`init`; `counts` within 2% of the parent commit for the scenarios that
do not use the new widgets.

D9 and D11 make modules, so each also follows CLAUDE.md's row for a
module: `core/zui_<name>/zui_<name>.zig` and `tests.zig`, and its
registration in `core/build.zig`, `core/build.zig.zon`, the root
`build.zig` and `README.md`'s import snippet. Modules cannot import one
another (SPEC.md §3.3), so `zui_widgets_data` and `zui_widgets_views`
take a `Widgets` value as `anytype` rather than importing `zui_widgets`.

## Decisions for the owner

The six questions the design left open are settled, with the queue's
order, the home of the motion tokens and the tour's colors, under *Made*
in `roadmap/decisions.md`: muted text keeps Lc 75; rows hover in
`secondary_container`; tones stay the resolver's; one shadow per
element; italics are bundled (`11-polish:35-italics`), so rich text's
emphasis is italic, not `body_strong` in `on_surface_accent`;
`label_strong` stays a type role.

## When a step lands

In each step's commit, besides CLAUDE.md's checklist:

- **`ROADMAP.md`, the queue.** Items 27 to 36 are in the queue after
  `11-polish:19-default-design`, in this plan's order, each with its
  *Where* and *Waits for*. A row leaves the queue when its item is done.
- **`roadmap/11-polish.md`.** Each new item gets its row in *Items* and
  its entry under *The design system*, with Grounding, Plan, Done when,
  Waits for and Spec from this plan, and a **Status** as it lands.
  `11-polish:19-default-design`'s Plan takes D1 to D3 as its slices.
  `11-polish:08-zui-themes` notes the personalities here as reference.
- **`roadmap/decisions.md`.** Each decision above, once the owner makes
  it, under *Made*.
- **`SPEC.md`.** D1: §18.1's `ColorRole` and `TypeRole`, §18.4's roles
  and their pairs, §18.5's control heights and icon sizes, §18.6's
  `label_strong` and bold headings, §18.7's elevation levels and rim,
  and §19.11's `zui_design.default`. D2 to D8: §19.2's widget table. D9
  and D11: a new section for each module after §19.2, the modules row of
  §3, and §21's stage 11 scope.
- **`ARCHITECTURE.md`.** §6: a row for each new module's features, in
  stage 11. §7: D1 to D3 close the rows on `zui_design.default` and
  `DefaultSkin`; D9 and D11 add the new modules to the `core/` row of
  the package table.
- **`README.md`.** The import snippet for each new module; stage 11's
  status line when the stage finishes.
- **`docs/feature-tour.html` and `docs/feature-tour.md`.** An entry for
  each component group as it works, with an example in an app's own
  code.
- **This plan.** When D11 is done, the plan becomes a record, as
  `docs/plans/benchmarking.md` is: a table of each step and the item it
  became, above the rest. `exports/` stays as the reference the tests
  compare against.
