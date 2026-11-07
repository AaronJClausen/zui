# zui-web

[zui](https://github.com/AaronJClausen/zui) in the browser: first a thin client that draws a zui app streamed over zui_wire, later a web host with a canvas surface.

Built by roadmap items V4 (the demo in a browser, a thin client over zui_wire) and H5 (the web host).

## Status

A skeleton: the build and CI, with no client or host yet. `zig build check` already compiles zui for `wasm32-freestanding`.
See [zui's ROADMAP.md](https://github.com/AaronJClausen/zui/blob/main/ROADMAP.md).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically (pinned by commit in `build.zig.zon`)

## Development

| Command | Does |
|---|---|
| `zig build test` | run the tests; CI also runs `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` |
| `zig build check` | compile without running, and compile zui for `wasm32-freestanding` |
| `zig build fmt` | format the Zig sources |
| `zig build fmt-check` | fail if a Zig source is not formatted (CI) |
| `zig build test --fork=../zui` | build against a local zui checkout instead of the pin |

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.

## License

MIT, as zui.
