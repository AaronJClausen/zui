// The published page: zui-sokol's tour in a Web Worker, its frames drawn on
// the canvas and the canvas's input sent back to it as records. As a native
// host does, it sleeps between the frames the tour needs, stepping it only
// on input, a resize, or when the worker's answer said to wake. The page
// must be cross-origin isolated, so the worker can share the tour's memory
// with its threads.
//
//   const tour = await runTour(canvas, (error) => show(error));
//   tour.framesDrawn; // so far
//   tour.wakes; // the times the page stepped the tour, drawing a frame or not
//   tour.onStep = ({ now, wakeAt, tasks }) => log.push(wakeAt - now); // Infinity: until input

import { startClient } from "./client.mjs";
import { FrameDrawer } from "./frame_drawer.mjs";
import { InputRecorder } from "./input_recorder.mjs";
import { Inbox, startWorker } from "./worker_port.mjs";

// Starts the tour and draws its frames until it fails, when `stopped` is
// called with the error. Resolves once the first frame is drawn.
export async function runTour(canvas, stopped) {
  if (!globalThis.crossOriginIsolated) throw new Error("the page is not cross-origin isolated, so its worker cannot share the tour's memory");
  const { wasm, errorName } = await startClient();
  const drawer = new FrameDrawer(canvas, wasm);
  const recorder = new InputRecorder(canvas, wasm, () => wake());
  canvas.focus();

  const worker = await startWorker(new URL("./tour_worker.mjs", import.meta.url));
  const inbox = new Inbox(worker);
  const tourWasm = new Uint8Array(await (await fetch("zui-web-tour.wasm")).arrayBuffer());
  worker.post({ type: "start", wasm: tourWasm }, [tourWasm.buffer]);
  await inbox.expect("ready");

  const tour = { framesDrawn: 0, wakes: 0, tasks: null, frameMicroseconds: 0, drawer };
  let previousDraw = 0;
  let animationFrameRequested = false;
  let stepping = false;
  let wokenWhileStepping = false;
  let deadlineTimer = null;
  let failed = false;

  let firstFrameDrawn;
  let failedBeforeFirstFrame;
  const firstFrame = new Promise((resolve, reject) => {
    firstFrameDrawn = resolve;
    failedBeforeFirstFrame = reject;
  });

  const resizes = new ResizeObserver(() => wake());
  resizes.observe(canvas);
  let scaleQuery = null;
  function wakeWhenTheScaleChanges() {
    scaleQuery = matchMedia(`(resolution: ${globalThis.devicePixelRatio ?? 1}dppx)`);
    scaleQuery.addEventListener("change", scaleChanged, { once: true });
  }
  function scaleChanged() {
    wake();
    wakeWhenTheScaleChanges();
  }
  wakeWhenTheScaleChanges();

  function stop(error) {
    failed = true;
    clearTimeout(deadlineTimer);
    resizes.disconnect();
    scaleQuery.removeEventListener("change", scaleChanged);
    worker.terminate();
    recorder.detach();
    if (tour.framesDrawn === 0) failedBeforeFirstFrame(error);
    else stopped(error);
  }

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

  // Steps the tour, draws the frame it declared if one was due, and
  // returns the instant to step it again by.
  async function stepAndDrawIfDue() {
    const now = performance.now();
    const records = recorder.takeRecord(now) ?? new Uint8Array(0);
    worker.post({ type: "frame", now, previousDraw, records, onlyWhenDue: true }, [records.buffer]);
    const { bytes, tasks, frameMicroseconds, wakeAt } = await inbox.expect("frame");
    tour.wakes += 1;
    tour.tasks = tasks;
    tour.frameMicroseconds = frameMicroseconds;
    tour.onStep?.({ now, wakeAt, tasks });
    if (receive(bytes)) {
      const drawStarted = performance.now();
      drawer.draw();
      previousDraw = performance.now() - drawStarted;
      recorder.applyHostRequests();
      tour.framesDrawn += 1;
      if (tour.framesDrawn === 1) firstFrameDrawn();
    }
    return wakeAt;
  }

  async function onAnimationFrame() {
    animationFrameRequested = false;
    stepping = true;
    let wakeAt;
    try {
      wakeAt = await stepAndDrawIfDue();
    } catch (error) {
      stop(error);
      return;
    }
    stepping = false;
    if (wokenWhileStepping) {
      wokenWhileStepping = false;
      wake();
    } else sleepUntil(wakeAt);
  }

  function wake() {
    if (failed) return;
    if (stepping) {
      wokenWhileStepping = true;
      return;
    }
    if (animationFrameRequested) return;
    clearTimeout(deadlineTimer);
    animationFrameRequested = true;
    requestAnimationFrame(onAnimationFrame);
  }

  // A timer may fire a little before `performance.now()` reaches its
  // deadline, so it is set again for what remains.
  function sleepUntil(wakeAt) {
    if (wakeAt === Infinity) return;
    const wait = wakeAt - performance.now();
    if (wait <= 0) wake();
    else deadlineTimer = setTimeout(() => sleepUntil(wakeAt), wait);
  }

  wake();
  await firstFrame;
  return tour;
}
