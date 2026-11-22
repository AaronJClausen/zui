// The page's side of an application on `zui_web.Host`: it starts the
// application's worker (`host_worker.mjs`), transfers the canvas to it,
// sends it the canvas's events, one message for each event the page
// hears, and its size and `devicePixelRatio` when they change, and shows
// the cursor the application asks for. The page must be cross-origin
// isolated, so the worker can share the module's memory with its threads.
//
//   const host = await runOnHost(canvas, new URL("zui-tour.wasm", location.href), (error) => show(error));
//   host.stop(); // ends the worker

import { InputRecorder, messageSink } from "./input_recorder.mjs";
import { Inbox, startWorker } from "./worker_port.mjs";

const canvasId = 0;

function measure(canvas) {
  const bounds = canvas.getBoundingClientRect();
  return { cssSize: [bounds.width, bounds.height], devicePixelRatio: globalThis.devicePixelRatio ?? 1 };
}

// Resolves once the worker has attached the canvas; `stopped` is called
// with the error if the application fails after that.
export async function runOnHost(canvas, moduleUrl, stopped) {
  if (!globalThis.crossOriginIsolated) throw new Error("the page is not cross-origin isolated, so its worker cannot share the module's memory");
  const worker = await startWorker(new URL("./host_worker.mjs", import.meta.url));
  const inbox = new Inbox(worker);
  const sink = messageSink((events) => worker.post({ type: "events", events }));
  const recorder = new InputRecorder(canvas, null, () => sink.flush(), { sink });

  let measured = measure(canvas);
  const offscreen = canvas.transferControlToOffscreen();
  worker.post({ type: "start", moduleUrl: String(moduleUrl), canvas: offscreen, canvasId, ...measured, pageTimeOrigin: performance.timeOrigin }, [offscreen]);

  function resized() {
    const now = measure(canvas);
    const changed = now.cssSize[0] !== measured.cssSize[0] || now.cssSize[1] !== measured.cssSize[1] || now.devicePixelRatio !== measured.devicePixelRatio;
    measured = now;
    if (changed) worker.post({ type: "resize", ...now });
  }
  // A resize, or a change of scale, is heard before `devicePixelRatio`
  // says the new one, so the canvas is measured on the next animation frame.
  let measuring = false;
  function measureSoon() {
    if (measuring) return;
    measuring = true;
    requestAnimationFrame(() => {
      measuring = false;
      resized();
    });
  }
  const resizes = new ResizeObserver(measureSoon);
  resizes.observe(canvas);
  let scaleQuery = null;
  function followTheScale() {
    scaleQuery = matchMedia(`(resolution: ${globalThis.devicePixelRatio ?? 1}dppx)`);
    scaleQuery.addEventListener("change", scaleChanged, { once: true });
  }
  function scaleChanged() {
    measureSoon();
    followTheScale();
  }
  followTheScale();

  let running = true;
  function stop() {
    if (!running) return;
    running = false;
    resizes.disconnect();
    scaleQuery.removeEventListener("change", scaleChanged);
    recorder.detach();
    worker.terminate();
  }

  try {
    await inbox.expect("started");
  } catch (error) {
    stop();
    throw error;
  }
  canvas.focus();
  (async () => {
    for (;;) {
      const message = await inbox.take();
      if (message.type === "cursor") canvas.style.cursor = message.cursor;
    }
  })().catch((error) => {
    stop();
    stopped(error);
  });
  return { canvas, worker, stop };
}
