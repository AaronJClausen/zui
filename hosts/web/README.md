# zui-web

[zui](https://github.com/AaronJClausen/zui) in the browser: first a thin client that draws a zui app streamed over zui_wire, later a web host with a canvas surface.

Built by roadmap items V4 (the demo in a browser, a thin client over zui_wire) and H5 (the web host).

## Status

V4 has begun. The client's decoder runs in WebAssembly: `zig build` writes
`zig-out/web/zui-web.wasm` (19 KB in ReleaseSmall, 12 MiB of memory once
`zuiWebInit` reserves it), which takes a `zui_wire` stream in pieces of any
size, as a socket delivers it, and decodes each frame once all of it has
arrived. `zig build test-demo` declares every screen of zui-sokol's tour
headlessly, streams its frames to that client under Node in pieces of 1 to
16,384 bytes, and checks that each of the 312 frames decodes to what the tour
drew. Nothing draws them yet, and there is no page.
See [zui's ROADMAP.md](https://github.com/AaronJClausen/zui/blob/main/ROADMAP.md).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically (pinned by commit in `build.zig.zon`)
- for `zig build test-demo`: Node on the `PATH`, and on Linux sokol's X11,
  OpenGL and PulseAudio headers, since the tour links them; zui-sokol,
  which holds the tour, is fetched automatically, pinned as zui is

## Development

| Command | Does |
|---|---|
| `zig build test` | run the tests; CI also runs `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` |
| `zig build` | write the client, `zig-out/web/zui-web.wasm` |
| `zig build check` | compile without running, and compile the client for `wasm32-freestanding` |
| `zig build test-demo` | stream zui-sokol's tour to the client under Node, and check every frame decodes to what was drawn |
| `zig build fmt` | format the Zig sources |
| `zig build fmt-check` | fail if a Zig source is not formatted (CI) |
| `zig build test --fork=../zui` | build against a local zui checkout instead of the pin |

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.
Keep zui's pin the one zui-sokol's pin names, and move the two together:
the tour and the client then share zui's types, and `--fork=../zui`, which
cannot fork two zui packages into one checkout, matches only one.

## License

MIT, as zui.
