// node check_site.mjs <chromium> <site directory>
//
// Serves the published site as GitHub Pages does, without the headers that
// make a page cross-origin isolated, and opens it in headless Chromium. Its
// service worker must make it isolated, after one reload; the page must
// then draw the tour's frames from its worker, which times them above 0 µs
// as the tour's strip shows them. Idle, the page must sleep as a native
// host does, drawing only the tour's once-a-second heartbeat while the
// display runs on, until input wakes it: the mouse over the rail turns the
// cursor to the pointer the tour asks for, Ctrl+PageDown draws the next
// screen, and a click on Mission Control's entry starts its producers'
// tasks, whose frames keep coming without input. On the Gallery, its
// tiles must all load without input, and the page then sleep again.

import { readdir } from "node:fs/promises";
import { extname, join, relative, sep } from "node:path";
import { openHeadlessPage } from "./headless_page.mjs";

const watchdogMilliseconds = 120_000;
const settleMilliseconds = 10_000;
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

const distinctColors = await evaluate(`(() => {
  const { gl } = tour.drawer;
  const pixels = new Uint32Array(gl.drawingBufferWidth * gl.drawingBufferHeight);
  gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(pixels.buffer));
  return new Set(pixels).size;
})()`);
const fewestDistinctColors = 64;
if (distinctColors < fewestDistinctColors) await fail(`the canvas shows ${distinctColors} colors, not a frame of the tour`);

await waitUntil("tour.frameMicroseconds > 0", "the tour's strip did not time a frame above 0 µs");
const frameMicroseconds = await evaluate("tour.frameMicroseconds");

await evaluate(`(() => {
  window.animationFramesSeen = 0;
  const count = () => {
    animationFramesSeen += 1;
    requestAnimationFrame(count);
  };
  requestAnimationFrame(count);
  window.canvasDigest = () => {
    const { gl } = tour.drawer;
    const pixels = new Uint32Array(gl.drawingBufferWidth * gl.drawingBufferHeight);
    gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(pixels.buffer));
    let hash = 0x811c9dc5;
    for (const pixel of pixels) hash = Math.imul(hash ^ pixel, 0x01000193);
    return hash >>> 0;
  };
})()`);

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const animationSettleMilliseconds = 1_000;
const idleMilliseconds = 2_000;
// The tour's heartbeat refreshes its strip each whole second, and a wait of
// two seconds can span three.
const idleFramesMost = 3;
const animationFramesFewest = 30;

// The frames the tour drew, and the times the page stepped it, while
// nothing happened, which must be its heartbeat's alone while the page's
// display kept running.
async function idleFrames(screen) {
  await pause(animationSettleMilliseconds);
  const counts = "({ drawn: tour.framesDrawn, wakes: tour.wakes, animation: animationFramesSeen })";
  const before = await evaluate(counts);
  await pause(idleMilliseconds);
  const after = await evaluate(counts);
  const drawn = after.drawn - before.drawn;
  const wakes = after.wakes - before.wakes;
  const animation = after.animation - before.animation;
  const seconds = idleMilliseconds / 1000;
  if (animation < animationFramesFewest) await fail(`the page saw ${animation} animation frames in ${seconds} s, too few to tell whether the tour sleeps`);
  if (drawn > idleFramesMost) await fail(`the tour drew ${drawn} frames in ${seconds} s idle on ${screen}, of the display's ${animation}, so it never sleeps`);
  if (wakes > idleFramesMost) await fail(`the page stepped the tour ${wakes} times in ${seconds} s idle on ${screen}, of the display's ${animation} frames`);
  return { drawn, animation };
}

async function expectDrawnAfter(what, act) {
  const before = await evaluate("tour.framesDrawn");
  await act();
  await waitUntil(`tour.framesDrawn > ${before}`, `the tour drew no frame after ${what}`);
}

const control = 2;
async function chord(key, code, windowsVirtualKeyCode) {
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, windowsVirtualKeyCode, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17 });
}
const nextScreen = () => chord("PageDown", "PageDown", 34);
const previousScreen = () => chord("PageUp", "PageUp", 33);

const welcomeIdle = await idleFrames("Welcome");

await expectDrawnAfter("the mouse moved over the rail", () => send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 50, y: 266 }));
await waitUntil(`tour.drawer.canvas.style.cursor === "pointer"`, "the canvas did not show the pointer cursor over the rail");
await idleFrames("Welcome, under the mouse");

const welcomeDigest = await evaluate("canvasDigest()");
await expectDrawnAfter("Ctrl+PageDown", nextScreen);
await waitUntil(`canvasDigest() !== ${welcomeDigest}`, "the canvas still showed Welcome after Ctrl+PageDown");

const tasksBefore = await evaluate("tour.tasks.started");
await send("Input.dispatchMouseEvent", { type: "mousePressed", x: 50, y: 266, button: "left", buttons: 1, clickCount: 1 });
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 50, y: 266, button: "left", buttons: 0, clickCount: 1 });
await waitUntil(`tour.tasks.started > ${tasksBefore}`, "the tour started no tasks after the click on Mission Control's entry");
const missionTasks = await evaluate("tour.tasks");

// Mission Control's telemetry publishes 30 times a second, and the page
// sleeps between: its producers' sleeps must still end on time.
const producerMilliseconds = 2_000;
const producedFramesFewest = 10;
const missionFramesBefore = await evaluate("tour.framesDrawn");
await pause(producerMilliseconds);
const missionFrames = (await evaluate("tour.framesDrawn")) - missionFramesBefore;
if (missionFrames < producedFramesFewest) await fail(`Mission Control drew ${missionFrames} frames in ${producerMilliseconds / 1000} s of its producers publishing`);

await expectDrawnAfter("Ctrl+PageUp", previousScreen);
await waitUntil(`tour.tasks.started > ${missionTasks.started} && tour.tasks.finished === tour.tasks.started`, "the Gallery's tiles and Mission Control's producers did not all finish without input");
const galleryTasks = await evaluate("tour.tasks");
const galleryIdle = await idleFrames("the Gallery, its tiles loaded");
if (page.pageErrors.length > 0) await fail(`the page failed: ${page.pageErrors.join("\n")}`);

clearTimeout(watchdog);
await page.close();
const perSecond = ({ drawn, animation }) => `${(drawn / (idleMilliseconds / 1000)).toFixed(1)} frames a second of the display's ${(animation / (idleMilliseconds / 1000)).toFixed(0)}`;
console.log(
  `check_site: isolated by its service worker after one reload; ${distinctColors} colors, the newest frame declared in ${frameMicroseconds.toFixed(0)} µs; ` +
    `idle, ${perSecond(welcomeIdle)} on Welcome and ${perSecond(galleryIdle)} on the Gallery; ` +
    `woken and drawn by the mouse over the rail, which shows the pointer, and by Ctrl+PageDown; ` +
    `${missionTasks.started} tasks started after the click on Mission Control, ${(missionFrames / (producerMilliseconds / 1000)).toFixed(0)} frames a second of its producers, ` +
    `and ${galleryTasks.finished - missionTasks.finished} tasks finished without input on the Gallery`,
);
