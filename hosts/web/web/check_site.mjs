// node check_site.mjs <chromium> <site directory>
//
// Serves the published site as GitHub Pages does, without the headers that
// make a page cross-origin isolated, and opens it in headless Chromium. Its
// service worker must make it isolated, after one reload; the page must
// then draw the tour's frames from its worker, and the canvas's input must
// reach the tour: the mouse over the rail turns the cursor to the pointer
// the tour asks for, and a click on Mission Control's entry starts its
// producers' tasks.

import { readdir } from "node:fs/promises";
import { extname, join, relative, sep } from "node:path";
import { openHeadlessPage } from "./headless_page.mjs";

const watchdogMilliseconds = 120_000;
const settleMilliseconds = 10_000;
const frameRateMilliseconds = 2_000;
const [chromiumPath, siteDirectory] = process.argv.slice(2);

const contentTypes = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".ttf": "font/ttf",
  ".txt": "text/plain",
};

const served = {};
for (const entry of await readdir(siteDirectory, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile()) continue;
  const path = join(entry.parentPath, entry.name);
  const url = `/${relative(siteDirectory, path).split(sep).join("/")}`;
  served[url === "/index.html" ? "/" : url] = { path, type: contentTypes[extname(path)] ?? "application/octet-stream" };
}

let page = null;

async function fail(message) {
  console.error(`check_site: ${message}`);
  await page?.close();
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

try {
  page = await openHeadlessPage(chromiumPath, served);
} catch (error) {
  await fail(error.message);
}
const { evaluate, send } = page;

async function waitUntil(condition, what) {
  const pollMilliseconds = 50;
  for (let waited = 0; !(await evaluate(condition)); waited += pollMilliseconds) {
    if (page.pageErrors.length > 0) await fail(`the page failed: ${page.pageErrors.join("\n")}`);
    if (waited >= settleMilliseconds) await fail(`${what} within ${settleMilliseconds / 1000} s`);
    await new Promise((resolve) => setTimeout(resolve, pollMilliseconds));
  }
}

const isolation = await evaluate(`({
  isolated: crossOriginIsolated,
  serviceWorker: navigator.serviceWorker.controller?.scriptURL ?? null,
  loadedBy: performance.getEntriesByType("navigation")[0]?.type,
})`);
if (!isolation.isolated) await fail("the page is not cross-origin isolated");
if (!isolation.serviceWorker?.endsWith("/isolation_service_worker.js")) await fail(`the page is served by ${isolation.serviceWorker ?? "no service worker"}, not its own`);
if (isolation.loadedBy !== "reload") await fail(`the page was isolated on a ${isolation.loadedBy}, not on the one reload its service worker needs`);

await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1.25, mobile: false });
await waitUntil("tour.drawer.canvas.width === 1600 && tour.drawer.canvas.height === 1000", "the canvas was not drawn at its new size");

const framesBefore = await evaluate("tour.framesDrawn");
await new Promise((resolve) => setTimeout(resolve, frameRateMilliseconds));
const framesPerSecond = ((await evaluate("tour.framesDrawn")) - framesBefore) / (frameRateMilliseconds / 1000);
if (framesPerSecond === 0) await fail("the page drew no frames");

const distinctColors = await evaluate(`(() => {
  const { gl } = tour.drawer;
  const pixels = new Uint32Array(gl.drawingBufferWidth * gl.drawingBufferHeight);
  gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(pixels.buffer));
  return new Set(pixels).size;
})()`);
const fewestDistinctColors = 64;
if (distinctColors < fewestDistinctColors) await fail(`the canvas shows ${distinctColors} colors, not a frame of the tour`);

await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 50, y: 266 });
await waitUntil(`tour.drawer.canvas.style.cursor === "pointer"`, "the canvas did not show the pointer cursor over the rail");

const tasksBefore = await evaluate("tour.tasks.started");
await send("Input.dispatchMouseEvent", { type: "mousePressed", x: 50, y: 266, button: "left", buttons: 1, clickCount: 1 });
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 50, y: 266, button: "left", buttons: 0, clickCount: 1 });
await waitUntil(`tour.tasks.started > ${tasksBefore}`, "the tour started no tasks after the click on Mission Control's entry");
const tasks = await evaluate("tour.tasks");
if (page.pageErrors.length > 0) await fail(`the page failed: ${page.pageErrors.join("\n")}`);

clearTimeout(watchdog);
await page.close();
console.log(
  `check_site: isolated by its service worker after one reload; ${framesPerSecond.toFixed(0)} frames a second drawn from the worker, ${distinctColors} colors; ` +
    `the pointer shown over the rail, and ${tasks.started} tasks started after the click`,
);
