// The published page: zui-sokol's tour in a Web Worker, its frames drawn on
// the canvas and the canvas's input sent back to it as records, a frame
// for each of the display's. The page must be cross-origin isolated, so
// the worker can share the tour's memory with its threads.
//
//   const tour = await runTour(canvas, (error) => show(error));
//   tour.framesDrawn; // so far

import { startClient } from "./client.mjs";
import { FrameDrawer } from "./frame_drawer.mjs";
import { InputRecorder } from "./input_recorder.mjs";
import { Inbox, startWorker } from "./worker_port.mjs";

const nextAnimationFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));

// Starts the tour and draws its frames until it fails, when `stopped` is
// called with the error. Resolves once the first frame is drawn.
export async function runTour(canvas, stopped) {
  if (!globalThis.crossOriginIsolated) throw new Error("the page is not cross-origin isolated, so its worker cannot share the tour's memory");
  const { wasm, errorName } = await startClient();
  const drawer = new FrameDrawer(canvas, wasm);
  const recorder = new InputRecorder(canvas, wasm);
  canvas.focus();

  const worker = await startWorker(new URL("./tour_worker.mjs", import.meta.url));
  const inbox = new Inbox(worker);
  const tourWasm = new Uint8Array(await (await fetch("zui-web-tour.wasm")).arrayBuffer());
  worker.post({ type: "start", wasm: tourWasm }, [tourWasm.buffer]);
  await inbox.expect("ready");

  const tour = { framesDrawn: 0, tasks: null, drawer };

  // Whether `bytes` completed a frame.
  function receive(bytes) {
    if (bytes.length === 0) return false;
    const room = wasm.zuiWebRoomFor(bytes.length) >>> 0;
    if (room === 0) throw new Error(`the client had no room for ${bytes.length} bytes: ${errorName()}`);
    new Uint8Array(wasm.memory.buffer, room, bytes.length).set(bytes);
    wasm.zuiWebReceived(bytes.length);
    let completed = false;
    for (let status = wasm.zuiWebNextFrame(); status !== 0; status = wasm.zuiWebNextFrame()) {
      if (status < 0) throw new Error(`the client could not decode a frame: ${errorName()}`);
      completed = true;
    }
    return completed;
  }

  async function drawNextFrame() {
    await nextAnimationFrame();
    const now = performance.now();
    const records = recorder.takeRecord(now) ?? new Uint8Array(0);
    worker.post({ type: "frame", now, records }, [records.buffer]);
    const { bytes, tasks } = await inbox.expect("frame");
    tour.tasks = tasks;
    if (!receive(bytes)) return;
    drawer.draw();
    recorder.applyHostRequests();
    tour.framesDrawn += 1;
  }

  while (tour.framesDrawn === 0) await drawNextFrame();
  (async () => {
    for (;;) await drawNextFrame();
  })().catch((error) => {
    worker.terminate();
    recorder.detach();
    stopped(error);
  });
  return tour;
}
