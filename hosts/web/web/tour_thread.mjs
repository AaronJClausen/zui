// A thread the tour's tasks take turns on: the tour's module instantiated
// again on its shared memory, with a stack and thread-local storage of its
// own, running `zuiTourRunThread` until the tour stops.

import { parentPort } from "./worker_port.mjs";

const parent = await parentPort();
parent.listen(({ module, memory, index, stackTop, threadLocalStorage }) => {
  try {
    const instance = new WebAssembly.Instance(module, { env: { memory, performanceNow: () => performance.now() } });
    const tour = instance.exports;
    tour.__stack_pointer.value = stackTop;
    tour.__wasm_init_tls(threadLocalStorage);
    parent.post({ type: "thread ready", index });
    tour.zuiTourRunThread(index);
  } catch (error) {
    parent.post({ type: "failed", error: `thread ${index}: ${error.message}` });
  }
});
