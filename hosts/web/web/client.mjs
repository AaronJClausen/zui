// The client, `zui-web.wasm`, started and handed the tour's fonts: each
// TrueType font that `truetype-fonts.json` lists, in the order the tour
// added them. Without them, it draws no text. It draws on the FrameDrawer
// `drawers` holds by the canvas id `zuiWebDrawNewestFrame` is given.
//
//   const drawers = new Map();
//   const { wasm, errorName } = await startClient({ drawers });
//   drawers.set(0, new FrameDrawer(canvas));
//   const withoutText = await startClient({ fonts: false });

import { frameDrawerImports } from "./frame_drawer.mjs";

export async function startClient({ fonts = true, drawers = new Map() } = {}) {
  let wasm = null;
  const imports = frameDrawerImports(drawers, () => wasm.memory);
  ({ exports: wasm } = (await WebAssembly.instantiateStreaming(fetch("zui-web.wasm"), imports)).instance);
  const errorName = () => {
    const memory = new Uint8Array(wasm.memory.buffer);
    const start = wasm.zuiWebErrorName() >>> 0;
    return new TextDecoder().decode(memory.subarray(start, memory.indexOf(0, start)));
  };
  if (!wasm.zuiWebInit()) throw new Error("the client could not reserve its memory");
  if (!fonts) return { wasm, errorName };

  for (const url of await (await fetch("truetype-fonts.json")).json()) {
    const font = new Uint8Array(await (await fetch(url)).arrayBuffer());
    const room = wasm.zuiWebRoomForFont(font.length) >>> 0;
    if (room === 0) throw new Error(`no room for ${url}`);
    new Uint8Array(wasm.memory.buffer, room, font.length).set(font);
    if (wasm.zuiWebAddTrueTypeFont(font.length) < 0) throw new Error(`${url}: ${errorName()}`);
  }
  return { wasm, errorName };
}
