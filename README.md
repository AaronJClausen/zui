# zui

An immediate-mode UI layout library for Zig, in the spirit of
[Clay](https://github.com/nicbarker/clay). Each frame, the application
declares its UI as nested function calls. zui computes the layout and
returns a flat list of render commands for the application's own renderer
to draw.

**Status:** pre-alpha. The design is specified in [SPEC.md](SPEC.md), and
no part of it is implemented yet.

## Requirements

- Zig **0.16.0**

## Development

| Command | What it does |
|---|---|
| `zig build test` | run the unit tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | type-check without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build docs` | generate API documentation into `zig-out/docs` |
| `zig build fmt` | format every Zig source file |
| `zig build fmt-check` | fail if any file is not formatted, as CI does |

CI runs the format check, the tests in all three safety modes on Linux,
Windows and macOS, and `check` for six targets: 32- and 64-bit,
big-endian, freestanding and WebAssembly. Those targets exist to catch
assumptions about the host machine early.

The repository uses LF line endings everywhere (see `.gitattributes`),
whatever your `core.autocrlf` setting.
