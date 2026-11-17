// The client, `zui-web.wasm`, started and handed the tour's fonts: the six
// bitmap fonts' rows from `bitmap.fonts`, then each TrueType font that
// `truetype-fonts.json` lists, in the order the tour's host added them.
// Without them, it draws no text.
//
//   const { wasm, errorName } = await startClient();
//   const withoutText = await startClient({ fonts: false });

export async function startClient({ fonts = true } = {}) {
  const { instance } = await WebAssembly.instantiateStreaming(fetch("zui-web.wasm"), {});
  const wasm = instance.exports;
  const errorName = () => {
    const memory = new Uint8Array(wasm.memory.buffer);
    const start = wasm.zuiWebErrorName() >>> 0;
    return new TextDecoder().decode(memory.subarray(start, memory.indexOf(0, start)));
  };
  if (!wasm.zuiWebInit()) throw new Error("the client could not reserve its memory");
  if (!fonts) return { wasm, errorName };

  const bitmapFontRows = new Uint8Array(await (await fetch("bitmap.fonts")).arrayBuffer());
  new Uint8Array(wasm.memory.buffer, wasm.zuiWebBitmapFontRows() >>> 0, bitmapFontRows.length).set(bitmapFontRows);
  wasm.zuiWebLoadBitmapFonts();
  for (const url of await (await fetch("truetype-fonts.json")).json()) {
    const font = new Uint8Array(await (await fetch(url)).arrayBuffer());
    const room = wasm.zuiWebRoomForFont(font.length) >>> 0;
    if (room === 0) throw new Error(`no room for ${url}`);
    new Uint8Array(wasm.memory.buffer, room, font.length).set(font);
    if (wasm.zuiWebAddTrueTypeFont(font.length) < 0) throw new Error(`${url}: ${errorName()}`);
  }
  return { wasm, errorName };
}
