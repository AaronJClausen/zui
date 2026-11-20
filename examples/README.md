# zui-examples

Samples and a template project for [zui](https://github.com/AaronJClausen/zui).

Built by roadmap items D1 (this repository and the template) and D2 (a settings screen with zui_reflect and ZON, a data feed, a multi-window tool, a remote session).

## Status

A skeleton: the build and CI, with no template or samples yet.
See [zui's ROADMAP.md](https://github.com/AaronJClausen/zui/blob/main/ROADMAP.md).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically (pinned by commit in `build.zig.zon`)

## Development

| Command | Does |
|---|---|
| `zig build test` | run the tests; CI also runs `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` |
| `zig build check` | compile without running |
| `zig build fmt` | format the Zig sources |
| `zig build fmt-check` | fail if a Zig source is not formatted (CI) |
| `zig build test --fork=../zui` | build against a local zui checkout instead of the pin |

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.

## License

MIT, as zui.
