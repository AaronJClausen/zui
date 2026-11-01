//! zui: an immediate-mode UI layout library. See SPEC.md for the design.

const std = @import("std");
const context = @import("context.zig");
const style = @import("style.zig");
const id = @import("id.zig");
const interaction = @import("interaction.zig");
const tasks = @import("tasks.zig");

pub const Context = context.Context;
pub const Config = context.Config;
pub const ElementConfig = context.ElementConfig;
pub const Input = context.Input;
pub const Limit = context.Limit;
pub const Diagnostics = context.Diagnostics;
pub const EndFrameError = context.EndFrameError;

pub const Id = id.Id;
pub const ids = id.ids;

pub const Axis = style.Axis;
pub const Color = style.Color;
pub const Edges = style.Edges;
pub const CornerRadius = style.CornerRadius;
pub const Rect = style.Rect;
pub const Border = style.Border;
pub const Sizing = style.Sizing;
pub const Sizing2 = style.Sizing2;
pub const Direction = style.Direction;
pub const Alignment = style.Alignment;
pub const ChildAlignment = style.ChildAlignment;
pub const Layout = style.Layout;
pub const TextWrap = style.TextWrap;
pub const Clip = style.Clip;
pub const Scroll = style.Scroll;
pub const Floating = style.Floating;
pub const AttachTo = style.AttachTo;
pub const AnchorPoint = style.AnchorPoint;

pub const Button = interaction.Button;
pub const Key = interaction.Key;
pub const Modifiers = interaction.Modifiers;
pub const WidgetState = interaction.WidgetState;
pub const ScrollState = interaction.ScrollState;
pub const max_keys_per_frame = interaction.max_keys_per_frame;
pub const max_text_input_bytes = interaction.max_text_input_bytes;

pub const TaskPool = tasks.TaskPool;
pub const TaskStats = tasks.Stats;

test {
    std.testing.refAllDecls(@This());
    _ = @import("text.zig");
    _ = @import("state.zig");
    _ = @import("tests/golden.zig");
    _ = @import("tests/invariants.zig");
    _ = @import("tests/memory.zig");
    _ = @import("tests/interaction.zig");
    _ = @import("tests/layers.zig");
    _ = @import("tests/tasks.zig");
}
