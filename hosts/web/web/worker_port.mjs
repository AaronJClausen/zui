// Messages between a worker and the one that started it, in a browser or
// under Node's worker_threads, which name them differently.
//
//   const parent = await parentPort();
//   parent.listen((message) => parent.post({ echoed: message }));
//   const child = await startWorker(new URL("child.mjs", import.meta.url));
//   const inbox = new Inbox(child);
//   child.post({ type: "hello" });
//   const answer = await inbox.expect("echoed");

const inBrowser = typeof WorkerGlobalScope !== "undefined" || typeof window !== "undefined";

export async function parentPort() {
  if (inBrowser) {
    return {
      post: (message, transfer = []) => self.postMessage(message, transfer),
      listen: (receive) => self.addEventListener("message", (event) => receive(event.data)),
    };
  }
  const { parentPort: port } = await import("node:worker_threads");
  return {
    post: (message, transfer = []) => port.postMessage(message, transfer),
    listen: (receive) => port.on("message", receive),
  };
}

export async function startWorker(url) {
  if (inBrowser) {
    const worker = new Worker(url, { type: "module" });
    return {
      post: (message, transfer = []) => worker.postMessage(message, transfer),
      listen: (receive) => worker.addEventListener("message", (event) => receive(event.data)),
      onError: (fail) => worker.addEventListener("error", (event) => fail(event.message)),
      terminate: () => worker.terminate(),
    };
  }
  const { Worker: NodeWorker } = await import("node:worker_threads");
  const worker = new NodeWorker(url);
  return {
    post: (message, transfer = []) => worker.postMessage(message, transfer),
    listen: (receive) => worker.on("message", receive),
    onError: (fail) => worker.on("error", (error) => fail(error.message)),
    terminate: () => worker.terminate(),
  };
}

// The messages a worker sends, taken in order. A `{ type: "failed" }`
// message, or the worker failing, rejects the next take.
export class Inbox {
  constructor(worker) {
    this.arrived = [];
    this.waiting = null;
    worker.listen((message) => this.arrive(message.type === "failed" ? new Error(message.error) : message));
    worker.onError((message) => this.arrive(new Error(message)));
  }

  arrive(message) {
    if (this.waiting) {
      const { resolve, reject } = this.waiting;
      this.waiting = null;
      if (message instanceof Error) reject(message);
      else resolve(message);
    } else this.arrived.push(message);
  }

  take() {
    if (this.arrived.length > 0) {
      const message = this.arrived.shift();
      return message instanceof Error ? Promise.reject(message) : Promise.resolve(message);
    }
    return new Promise((resolve, reject) => (this.waiting = { resolve, reject }));
  }

  // The next message, which must be of `type`.
  async expect(type) {
    const message = await this.take();
    if (message.type !== type) throw new Error(`expected a "${type}" message, not "${message.type}"`);
    return message;
  }
}
