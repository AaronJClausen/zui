const zui = @import("zui");
const zui_color = @import("zui_color");

export fn entry() u8 {
    const shades = zui_color.lightnessScale(1, zui.Color.rgb(0x3366ff), 0.3, 0.9);
    return shades[0].r;
}
