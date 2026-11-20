# zui-themes

Skins for [zui](https://github.com/AaronJClausen/zui) in the design languages of Windows, macOS, GNOME and KDE: data only, applied through zui_widgets' skin contract.

Built by roadmap item K4, after the skin contract (K5).

## Status

A skeleton: the build, CI and the `zui_themes` module, with no skins yet.
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
