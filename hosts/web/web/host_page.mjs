// The page's side of an application on `zui_web.Host`: it starts the
// application's worker (`host_worker.mjs`), transfers the canvas to it,
// sends it the canvas's events, one message for each event the page
// hears, the page's settings and visibility (`page_environment.mjs`), its
// size and `devicePixelRatio` when they change, and shows the cursor the
// application asks for. It places a hidden text field at the caret the
// application asks for (`page_text_field.mjs`), copies to and reads from
// the clipboard, answering each read as a sink call, and opens URLs in a
// new tab. The page must be cross-origin
// isolated, so the worker can share the module's memory with its threads.
//
//   const host = await runOnHost(canvas, new URL("zui-tour.wasm", location.href), (error) => show(error));
//   host.stop(); // ends the worker

import { InputRecorder, messageSink } from "./input_recorder.mjs";
import { followPageEnvironment } from "./page_environment.mjs";
import { HiddenTextField } from "./page_text_field.mjs";
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
  const textField = new HiddenTextField(canvas, sink, () => sink.flush());

  let measured = measure(canvas);
  const offscreen = canvas.transferControlToOffscreen();
  const environment = followPageEnvironment(sink, () => sink.flush());
  const environmentEvents = sink.take();
  worker.post({ type: "start", moduleUrl: String(moduleUrl), canvas: offscreen, canvasId, ...measured, environmentEvents, pageTimeOrigin: performance.timeOrigin }, [offscreen]);

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

  const serviceFailures = { unavailable: 0, denied: 1 };
  async function readClipboard(id) {
    try {
      if (!navigator.clipboard) throw new Error("no clipboard");
      sink.clipboardText(id, await navigator.clipboard.readText());
    } catch (error) {
      sink.clipboardFailed(id, error?.name === "NotAllowedError" ? serviceFailures.denied : serviceFailures.unavailable);
    }
    sink.flush();
  }

  let running = true;
  function stop() {
    if (!running) return;
    running = false;
    resizes.disconnect();
    scaleQuery.removeEventListener("change", scaleChanged);
    recorder.detach();
    textField.detach();
    environment.stop();
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
      else if (message.type === "textInput") textField.place(message.caret);
      else if (message.type === "clipboardWrite") navigator.clipboard?.writeText(message.text).catch(() => {});
      else if (message.type === "clipboardRead") readClipboard(message.id);
      else if (message.type === "openUrl") window.open(message.url, "_blank", "noopener");
    }
  })().catch((error) => {
    stop();
    stopped(error);
  });
  return { canvas, worker, stop };
}
