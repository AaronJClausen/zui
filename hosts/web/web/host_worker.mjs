// The dedicated worker an application on `zui_web.Host` runs in: its
// module, the threads its tasks take turns on, and the canvas the page
// transferred, drawn by a `FrameDrawer`. The page sends
//
//   { type: "start", moduleUrl, canvas,      the module, the canvas as an
//     canvasId, cssSize, devicePixelRatio,   OffscreenCanvas with the id it
//     environmentEvents, pageTimeOrigin }    is drawn by, its size in CSS
//                                            pixels and ratio, the sink
//                                            calls of the page's settings
//                                            and visibility, and the
//                                            page's `performance.timeOrigin`
//   { type: "events", events }               `InputRecorder`'s sink calls,
//                                            `[name, ...arguments]`, in order
//   { type: "resize", cssSize, devicePixelRatio }
//
// and the worker answers `{ type: "started" }` once the canvas is
// attached, `{ type: "cursor", cursor }` with each CSS cursor the
// application asks for, `{ type: "textInput", caret }` with each caret the
// page's text field goes to, `[x, y, width, height]` in CSS pixels or null,
// `{ type: "clipboardWrite", text }`, `{ type: "clipboardRead", id }`,
// which the page answers as a sink call, `{ type: "openUrl", url }`, and
// `{ type: "failed", error }`, after which it takes no more turns.
//
// The module's `zuiWebRun` runs the application through `zui_app`, whose
// host yields to this event loop by throwing from an import; from then
// on, each turn is `zuiWebHostTurn`, from an animation frame or a timer as
// the host schedules it. `globalThis.zuiHost` counts the turns and the
// frames drawn, holds the drawers, the module's exports and memory, keeps the
// page's settings and visibility as last delivered, and calls its
// `onSchedule`, if set, with each turn the host schedules, for a check:
//
//   zuiHost.onSchedule = ({ now, kind, atMilliseconds }) => log.push(atMilliseconds - now);

import { FrameDrawer, frameDrawerImports } from "./frame_drawer.mjs";
import { exportsSink, sinkCalls, timedSinkCalls } from "./input_recorder.mjs";
import { importedMemoryLimits, startThreads } from "./shared_module.mjs";
import { parentPort } from "./worker_port.mjs";

const parent = await parentPort();
const yieldedToEventLoop = Symbol("yielded to the event loop");
const scheduleKinds = { animationFrame: 0, timer: 1, input: 2, ended: 3 };
const textDecoder = new TextDecoder();

const drawers = new Map();
const progress = { turns: 0, framesDrawn: 0, contextsLost: 0, contextsRestored: 0, measured: null, settings: {}, pageShown: true, drawers, module: null, memory: null, onSchedule: null };
globalThis.zuiHost = progress;

let wasm = null;
let memory = null;
let sink = null;
let pageToWorkerClock = 0;
let scheduled = null;
let failed = false;

// Shared memory cannot be decoded in place.
function stringAt(start, length) {
  return textDecoder.decode(new Uint8Array(memory.buffer, start >>> 0, length >>> 0).slice());
}

function errorName() {
  const bytes = new Uint8Array(memory.buffer);
  const start = wasm.zuiWebErrorName() >>> 0;
  return stringAt(start, bytes.indexOf(0, start) - start);
}

function fail(error) {
  if (failed) return;
  failed = true;
  cancelScheduled();
  parent.post({ type: "failed", error: error.message ?? String(error) });
}

function cancelScheduled() {
  if (scheduled?.animationFrame !== undefined) cancelAnimationFrame(scheduled.animationFrame);
  if (scheduled?.timer !== undefined) clearTimeout(scheduled.timer);
  scheduled = null;
}

function schedule(kind, atMilliseconds) {
  progress.onSchedule?.({ now: performance.now(), kind: Object.keys(scheduleKinds).find((name) => scheduleKinds[name] === kind), atMilliseconds });
  cancelScheduled();
  if (failed) return;
  if (kind === scheduleKinds.animationFrame) scheduled = { animationFrame: requestAnimationFrame(takeTurn) };
  else if (kind === scheduleKinds.timer) waitUntil(atMilliseconds);
}

function waitUntil(atMilliseconds) {
  scheduled = { timer: setTimeout(() => timerFired(atMilliseconds), Math.max(0, atMilliseconds - performance.now())) };
}

// A timer may fire a little before `performance.now()` reaches its
// deadline, so it is set again for what remains.
function timerFired(atMilliseconds) {
  if (performance.now() < atMilliseconds) waitUntil(atMilliseconds);
  else takeTurn();
}

function takeTurn() {
  scheduled = null;
  progress.turns += 1;
  try {
    if (!wasm.zuiWebHostTurn()) fail(new Error(`the application failed: ${errorName()}`));
  } catch (error) {
    fail(error);
  }
}

function answerWake() {
  if (failed) return;
  try {
    wasm.zuiWebHostAnswerWake();
  } catch (error) {
    fail(error);
  }
}

function hostImports() {
  return {
    zuiWebHostNow: () => performance.now(),
    zuiWebHostSchedule: schedule,
    // Called inside a turn, which reads the wake as it ends, or between
    // turns; either way it is answered once what runs now returns.
    zuiWebHostWake: () => queueMicrotask(answerWake),
    zuiWebHostShowCursor: (name, length) => parent.post({ type: "cursor", cursor: stringAt(name, length) }),
    zuiWebHostYield: () => {
      throw yieldedToEventLoop;
    },
    zuiWebHostShowTextInput: (shown, x, y, width, height) => parent.post({ type: "textInput", caret: shown ? [x, y, width, height] : null }),
    zuiWebHostWriteClipboard: (text, length) => parent.post({ type: "clipboardWrite", text: stringAt(text, length) }),
    zuiWebHostReadClipboard: (id) => parent.post({ type: "clipboardRead", id }),
    zuiWebHostOpenUrl: (url, length) => parent.post({ type: "openUrl", url: stringAt(url, length) }),
  };
}

function drawingImports() {
  const imports = frameDrawerImports(drawers, () => memory);
  const draw = imports.zui_webgl.zuiWebglDraw;
  imports.zui_webgl.zuiWebglDraw = (canvas, frame) => {
    draw(canvas, frame);
    progress.framesDrawn += 1;
  };
  return imports;
}

// A lost context's default is prevented, so the browser restores it; the
// drawer made on it before is gone with it.
function followContext(canvas, canvasId) {
  canvas.addEventListener("webglcontextlost", (event) => {
    event.preventDefault();
    progress.contextsLost += 1;
    wasm.zuiWebHostLoseContext();
  });
  canvas.addEventListener("webglcontextrestored", () => {
    drawers.set(canvasId, new FrameDrawer(canvas));
    progress.contextsRestored += 1;
    wasm.zuiWebHostRestoreContext();
  });
}

async function start({ moduleUrl, canvas, canvasId, cssSize, devicePixelRatio, environmentEvents, pageTimeOrigin }) {
  const bytes = new Uint8Array(await (await fetch(moduleUrl)).arrayBuffer());
  const module = await WebAssembly.compile(bytes);
  memory = new WebAssembly.Memory(importedMemoryLimits(bytes));
  progress.memory = memory;
  const instance = await WebAssembly.instantiate(module, { env: { memory }, zui_web_host: hostImports(), ...drawingImports() });
  wasm = instance.exports;
  progress.module = wasm;
  sink = exportsSink(wasm, () => memory);
  pageToWorkerClock = pageTimeOrigin - performance.timeOrigin;

  let yielded = false;
  try {
    wasm.zuiWebRun();
  } catch (error) {
    if (error !== yieldedToEventLoop) throw error;
    yielded = true;
  }
  if (!yielded) throw new Error(`the application did not start: ${errorName()}`);

  await startThreads(module, memory, {
    count: wasm.zuiWebThreadCount(),
    stackTop: (index) => wasm.zuiWebThreadStackTop(index) >>> 0,
    threadLocalStorage: (index) => wasm.zuiWebThreadLocalStorage(index) >>> 0,
    entry: "zuiWebRunThread",
    forwarded: ["zuiWebHostWake"],
    onCall: answerWake,
    onFailure: fail,
  });

  // Before the canvas, so the first record carries what the page measured.
  deliver(environmentEvents);
  drawers.set(canvasId, new FrameDrawer(canvas));
  followContext(canvas, canvasId);
  wasm.zuiWebHostAttachCanvas(canvasId, cssSize[0], cssSize[1], devicePixelRatio);
  progress.measured = { cssSize, devicePixelRatio };
}

function resize({ cssSize, devicePixelRatio }) {
  progress.measured = { cssSize, devicePixelRatio };
  wasm.zuiWebHostResize(cssSize[0], cssSize[1], devicePixelRatio);
}

// The page's event times are on its own clock, which started before this
// worker's.
function deliver(events) {
  for (const [name, ...call] of events) {
    if (!sinkCalls.includes(name)) throw new Error(`the page sent an event "${name}", which no sink takes`);
    if (timedSinkCalls.includes(name)) call[call.length - 1] += pageToWorkerClock;
    if (name === "setting") progress.settings[call[0]] = call[1];
    if (name === "pageShown") progress.pageShown = call[0];
    sink[name](...call);
  }
}

let started = null;
parent.listen(async (message) => {
  try {
    if (message.type === "start") {
      started = start(message);
      await started;
      parent.post({ type: "started" });
      return;
    }
    await started;
    if (failed) return;
    if (message.type === "events") deliver(message.events);
    else if (message.type === "resize") resize(message);
  } catch (error) {
    fail(error);
  }
});
