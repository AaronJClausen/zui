// zui-sokol's tour in a Web Worker, behind the page. The page sends
//
//   { type: "start", wasm }                   the tour's module, as bytes
//   { type: "frame", now, records }           its clock, in milliseconds, and
//                                             the records written since the last
//
// and the worker answers `{ type: "ready" }` once its threads have started,
// then `{ type: "frame", bytes, tasks }` for each frame: the frame's wire
// bytes, empty before the first record, and how many tasks the tour has
// started, finished and been refused. A failure is `{ type: "failed", error }`.

import { Inbox, parentPort, startWorker } from "./worker_port.mjs";

const parent = await parentPort();
let tour = null;
let memory = null;

function errorName() {
  const bytes = new Uint8Array(memory.buffer);
  const start = tour.zuiTourErrorName() >>> 0;
  return new TextDecoder().decode(bytes.slice(start, bytes.indexOf(0, start)));
}

// The limits of the memory the module imports, which a shared memory must
// be given exactly.
function importedMemoryLimits(wasm) {
  let at = 8;
  const byte = () => wasm[at++];
  const unsigned = () => {
    let value = 0;
    for (let shift = 0; ; shift += 7) {
      const next = byte();
      value += (next & 0x7f) * 2 ** shift;
      if ((next & 0x80) === 0) return value;
    }
  };
  const skip = (count) => (at += count);
  const skipName = () => skip(unsigned());
  while (at < wasm.length) {
    const section = byte();
    const size = unsigned();
    if (section !== 2) {
      skip(size);
      continue;
    }
    for (let imports = unsigned(); imports > 0; imports -= 1) {
      skipName();
      skipName();
      const kind = byte();
      if (kind === 2) {
        const flags = byte();
        const initial = unsigned();
        return { initial, maximum: flags & 1 ? unsigned() : initial, shared: true };
      }
      if (kind === 0) unsigned();
      else if (kind === 1) {
        byte();
        const flags = byte();
        unsigned();
        if (flags & 1) unsigned();
      } else if (kind === 3) skip(2);
    }
  }
  throw new Error("the tour's module imports no memory");
}

async function start(wasm) {
  const module = await WebAssembly.compile(wasm);
  memory = new WebAssembly.Memory(importedMemoryLimits(wasm));
  tour = (await WebAssembly.instantiate(module, { env: { memory } })).exports;
  if (!tour.zuiTourInit()) throw new Error(`the tour could not reserve its memory: ${errorName()}`);
  const started = [];
  for (let index = 0; index < tour.zuiTourThreadCount(); index += 1) {
    const thread = await startWorker(new URL("./tour_thread.mjs", import.meta.url));
    const ready = new Inbox(thread).expect("thread ready");
    thread.post({
      module,
      memory,
      index,
      stackTop: tour.zuiTourThreadStackTop(index) >>> 0,
      threadLocalStorage: tour.zuiTourThreadLocalStorage(index) >>> 0,
    });
    started.push(ready);
  }
  await Promise.all(started);
}

function frame(now, records) {
  if (records.length > 0) {
    const room = tour.zuiTourRoomForRecords(records.length) >>> 0;
    if (room === 0) throw new Error(`no room for ${records.length} bytes of records: ${errorName()}`);
    new Uint8Array(memory.buffer, room, records.length).set(records);
    tour.zuiTourReceivedRecords(records.length);
  }
  const count = tour.zuiTourFrame(now);
  if (count < 0) throw new Error(`the tour could not write its frame: ${errorName()}`);
  const bytes = new Uint8Array(memory.buffer, tour.zuiTourFrameBytes() >>> 0, count).slice();
  const tasks = { started: tour.zuiTourTasksStarted(), finished: tour.zuiTourTasksFinished(), refused: tour.zuiTourTasksRefused() };
  return { bytes, tasks };
}

parent.listen(async (message) => {
  try {
    if (message.type === "start") {
      await start(message.wasm);
      parent.post({ type: "ready" });
    } else if (message.type === "frame") {
      const { bytes, tasks } = frame(message.now, message.records);
      parent.post({ type: "frame", bytes, tasks }, [bytes.buffer]);
    }
  } catch (error) {
    parent.post({ type: "failed", error: error.message });
  }
});
