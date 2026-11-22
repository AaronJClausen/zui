// A WebAssembly module on memory shared with the workers its tasks take
// turns on, each running the module again on a stack of its own
// (`tour_thread.mjs`).
//
//   const memory = new WebAssembly.Memory(importedMemoryLimits(bytes));
//   await startThreads(module, memory, {
//     count: exports.zuiWebThreadCount(),
//     stackTop: (index) => exports.zuiWebThreadStackTop(index) >>> 0,
//     threadLocalStorage: (index) => exports.zuiWebThreadLocalStorage(index) >>> 0,
//     entry: "zuiWebRunThread",
//     forwarded: ["zuiWebHostWake"],
//     onCall: (name) => exports.zuiWebHostAnswerWake(),
//     onFailure: (error) => stop(error),
//   });

import { startWorker } from "./worker_port.mjs";

// The limits of the memory the module imports, which a shared memory must
// be given exactly.
export function importedMemoryLimits(wasm) {
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
  throw new Error("the module imports no memory");
}

// Starts `count` threads, each calling `entry` with its index, and
// resolves once all have started. A thread's call of an import named in
// `forwarded` is `onCall(name)` here; a thread that fails is
// `onFailure(error)`.
export async function startThreads(module, memory, { count, stackTop, threadLocalStorage, entry, forwarded = [], onCall = () => {}, onFailure = () => {} }) {
  const started = [];
  for (let index = 0; index < count; index += 1) {
    const thread = await startWorker(new URL("./tour_thread.mjs", import.meta.url));
    started.push(
      new Promise((resolve, reject) => {
        let ready = false;
        const failed = (message) => {
          const error = new Error(message);
          if (ready) onFailure(error);
          else reject(error);
        };
        thread.listen((message) => {
          if (message.type === "thread ready") {
            ready = true;
            resolve();
          } else if (message.type === "call") onCall(message.name);
          else if (message.type === "failed") failed(message.error);
        });
        thread.onError(failed);
      }),
    );
    thread.post({ module, memory, index, stackTop: stackTop(index), threadLocalStorage: threadLocalStorage(index), entry, forwarded });
  }
  await Promise.all(started);
}
