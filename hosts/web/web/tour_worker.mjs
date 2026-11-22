// The tour in a Web Worker, behind the page. The page sends
//
//   { type: "start", wasm, steadyTimings }    the tour's module, as bytes, and
//                                             whether to time its frames on a
//                                             steady stopwatch, as natively
//   { type: "frame", now, previousDraw,       its clock and how long it took to
//     records }                               draw the frame before, in
//                                             milliseconds, and the records
//                                             written since the last; the
//                                             tour declares a frame only if
//                                             one is due
//
// and the worker answers `{ type: "ready" }` once its threads have started,
// then `{ type: "frame", bytes, tasks, frameMicroseconds, wakeAt }` for
// each: the frame's wire bytes, empty before the first record or when none
// was due, how many tasks the tour has started, finished and been refused,
// the microseconds its strip shows the newest frame took to declare, and
// the instant on the page's clock by which to send the next, 0 for at once
// and Infinity for not before input. A failure is `{ type: "failed", error }`.

import { importedMemoryLimits, startThreads } from "./shared_module.mjs";
import { parentPort } from "./worker_port.mjs";

const parent = await parentPort();
let tour = null;
let memory = null;

function errorName() {
  const bytes = new Uint8Array(memory.buffer);
  const start = tour.zuiTourErrorName() >>> 0;
  return new TextDecoder().decode(bytes.slice(start, bytes.indexOf(0, start)));
}

async function start(wasm, steadyTimings) {
  const module = await WebAssembly.compile(wasm);
  memory = new WebAssembly.Memory(importedMemoryLimits(wasm));
  tour = (await WebAssembly.instantiate(module, { env: { memory, performanceNow: () => performance.now() } })).exports;
  if (!tour.zuiTourInit(steadyTimings)) throw new Error(`the tour could not reserve its memory: ${errorName()}`);
  await startThreads(module, memory, {
    count: tour.zuiTourThreadCount(),
    stackTop: (index) => tour.zuiTourThreadStackTop(index) >>> 0,
    threadLocalStorage: (index) => tour.zuiTourThreadLocalStorage(index) >>> 0,
    entry: "zuiTourRunThread",
  });
}

function frame(now, previousDraw, records) {
  if (records.length > 0) {
    const room = tour.zuiTourRoomForRecords(records.length) >>> 0;
    if (room === 0) throw new Error(`no room for ${records.length} bytes of records: ${errorName()}`);
    new Uint8Array(memory.buffer, room, records.length).set(records);
    tour.zuiTourReceivedRecords(records.length);
  }
  const count = tour.zuiTourFrame(now, previousDraw);
  if (count < 0) throw new Error(`the tour could not write its frame: ${errorName()}`);
  const bytes = new Uint8Array(memory.buffer, tour.zuiTourFrameBytes() >>> 0, count).slice();
  const tasks = { started: tour.zuiTourTasksStarted(), finished: tour.zuiTourTasksFinished(), refused: tour.zuiTourTasksRefused() };
  return { bytes, tasks, frameMicroseconds: tour.zuiTourNewestFrameMicroseconds(), wakeAt: tour.zuiTourNextWakeMilliseconds() };
}

parent.listen(async (message) => {
  try {
    if (message.type === "start") {
      await start(message.wasm, message.steadyTimings ?? false);
      parent.post({ type: "ready" });
    } else if (message.type === "frame") {
      const answer = frame(message.now, message.previousDraw, message.records);
      parent.post({ type: "frame", ...answer }, [answer.bytes.buffer]);
    }
  } catch (error) {
    parent.post({ type: "failed", error: error.message });
  }
});
