# 13-later: Later

Only with a measured win or a demonstrated need. None of it is in the
queue.

## Items

| Item | Status |
|---|---|
| `13-later:01-simd-candidates` SIMD candidates | not planned |
| `13-later:02-dedicated-benchmark-machine` A dedicated benchmark machine | not planned |

Ideas without an item yet:
- **Docking and tear-off panels,** once `10-reach:05-many-windows` has
  more than one window.
- **A grid layout,** if wrap is not enough.
- **Layout islands** (SPEC.md §8.5), with a benchmark above roughly 10k
  elements.
- **Static subtrees:** pre-recorded element records copied in with one
  `@memcpy` and laid out normally.

---

## 13-later:01-simd-candidates — SIMD candidates

Each measured by `01-measure:03-instruction-counts-in-ci` and
`01-measure:01-bench-compare` before it ships.

## 13-later:02-dedicated-benchmark-machine — A dedicated benchmark machine

A self-hosted, bare-metal CI runner set up as `01-measure:05-pinned-runs`
describes, the only way wall-clock times could gate CI. Until then CI
reports times and gates on instruction counts. A decision for when the
hardware exists.

---

## Not taken from Clay

Deliberate, and each a reason to choose zui:
- a global current context;
- `void*` payloads and callbacks in the hot path;
- 32-bit ids;
- limits set at run time. zui's are comptime so that `required_bytes` is
  exact and `initBuffer` works with a static buffer.
