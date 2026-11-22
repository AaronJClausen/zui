const zui_webgl = @import("zui_webgl");

export fn drawOnTheBrowsersPage(page: *zui_webgl.BrowserPage, frame: *const zui_webgl.DrawnFrame) void {
    page.draw(0, frame);
}
