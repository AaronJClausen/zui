const zui_color = @import("zui_color");

export fn entry() u8 {
    const shades = zui_color.ramp(0, .black, .white);
    return shades.len;
}
