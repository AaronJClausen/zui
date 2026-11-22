// A thread an application's tasks take turns on: its module instantiated
// again on its shared memory, with a stack and thread-local storage of its
// own, running `entry` until the application stops. An import named in
// `forwarded` posts `{ type: "call", name }` to the worker that started
// the thread; any other import but the clock fails the thread, since
// only the worker that runs the application calls it.

import { parentPort } from "./worker_port.mjs";

const parent = await parentPort();

function importsOnThread(module, memory, forwarded) {
  const imports = {};
  for (const { module: from, name, kind } of WebAssembly.Module.imports(module)) {
    imports[from] ??= {};
    if (kind === "memory") imports[from][name] = memory;
    else if (name === "performanceNow") imports[from][name] = () => performance.now();
    else if (forwarded.includes(name)) imports[from][name] = () => parent.post({ type: "call", name });
    else
      imports[from][name] = () => {
        throw new Error(`${from}.${name} was called on a task's thread`);
      };
  }
  return imports;
}

parent.listen(({ module, memory, index, stackTop, threadLocalStorage, entry = "zuiTourRunThread", forwarded = [] }) => {
  try {
    const instance = new WebAssembly.Instance(module, importsOnThread(module, memory, forwarded));
    const exports = instance.exports;
    exports.__stack_pointer.value = stackTop;
    exports.__wasm_init_tls(threadLocalStorage);
    parent.post({ type: "thread ready", index });
    exports[entry](index);
  } catch (error) {
    console.error(`thread ${index}: ${error.message}`);
    parent.post({ type: "failed", error: `thread ${index}: ${error.message}` });
  }
});
