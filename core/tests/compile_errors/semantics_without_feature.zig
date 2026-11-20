const zui = @import("zui");

const Ui = zui.Context(.{});

export fn entry(frame: *const Ui.Frame) usize {
    return frame.semantics().len;
}
