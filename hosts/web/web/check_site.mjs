// node check_site.mjs <chromium> <site directory>
//
// Serves the published site as GitHub Pages does, without the headers that
// make a page cross-origin isolated, and opens it in headless Chromium,
// reading the worker the tour runs in on `zui_web.Host` through the DevTools
// protocol. Its service worker must make it isolated, after one reload; the
// worker must then draw the tour, which times its frames above 0 µs as the
// tour's strip shows them. Idle, the worker must sleep as a native host
// does, drawing only the tour's once-a-second heartbeat while the display
// runs on, until input wakes it: the mouse over a row of the rail turns the
// cursor to the pointer the tour asks for, Ctrl+PageDown draws the next
// screen, and Ctrl+5, Log Tail's shortcut, starts its producers' tasks,
// whose frames keep coming without input. On Photo Culling, its photos must all load
// without input, and the worker then sleep again.

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
  page = await openHeadlessPage(chromiumPath, served, { attachWorkers: true });
} catch (error) {
  await fail(error.message);
}
const { evaluate, send } = page;
const inWorkerOrNot = (expression) => page.evaluateInWorker("host_worker.mjs", expression);
const inWorker = (expression) => inWorkerOrNot(expression).catch((error) => fail(`the worker: ${[error.message, ...page.pageErrors].join("\n")}`));

async function failures() {
  const hostFailure = await evaluate("window.hostFailure ?? null");
  return [...page.pageErrors, ...(hostFailure ? [hostFailure] : [])];
}

async function waitUntil(condition, what) {
  const pollMilliseconds = 50;
  for (let waited = 0; !(await condition()); waited += pollMilliseconds) {
    const failed = await failures();
    if (failed.length > 0) await fail(`the page failed: ${failed.join("\n")}`);
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

await waitUntil(() => inWorkerOrNot("zuiHost.framesDrawn > 0").catch(() => false), "the worker drew no frame");
await inWorker(`(() => {
  globalThis.canvasPixels = () => {
    const { gl } = zuiHost.drawers.get(0);
    const pixels = new Uint32Array(gl.drawingBufferWidth * gl.drawingBufferHeight);
    gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(pixels.buffer));
    return pixels;
  };
  globalThis.canvasDigest = () => {
    let hash = 0x811c9dc5;
    for (const pixel of canvasPixels()) hash = Math.imul(hash ^ pixel, 0x01000193);
    return hash >>> 0;
  };
  globalThis.tasks = () => ({ started: zuiHost.module.zuiWebTasksStarted(), finished: zuiHost.module.zuiWebTasksFinished() });
  return true;
})()`);

await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1.25, mobile: false });
await waitUntil(() => inWorker("(({ canvas }) => canvas.width === 1600 && canvas.height === 1000)(zuiHost.drawers.get(0))"), "the canvas was not drawn at its new size");

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
await pause(500);
const distinctColors = await inWorker("new Set(canvasPixels()).size");
const fewestDistinctColors = 64;
if (distinctColors < fewestDistinctColors) await fail(`the canvas shows ${distinctColors} colors, not a frame of the tour`);

await waitUntil(async () => (await inWorker("zuiHost.module.zuiTourNewestFrameMicroseconds()")) > 0, "the tour's strip did not time a frame above 0 µs");
const frameMicroseconds = await inWorker("zuiHost.module.zuiTourNewestFrameMicroseconds()");

await evaluate(`(() => {
  window.animationFramesSeen = 0;
  const count = () => {
    animationFramesSeen += 1;
    requestAnimationFrame(count);
  };
  requestAnimationFrame(count);
  return true;
})()`);

const animationSettleMilliseconds = 1_000;
const idleMilliseconds = 2_000;
// The tour's heartbeat refreshes its strip each whole second, and a wait of
// two seconds can span three.
const idleFramesMost = 3;
const animationFramesFewest = 30;

// The frames the tour drew, and the turns the worker took, while nothing
// happened, which must be its heartbeat's alone while the page's display
// kept running.
async function idleFrames(screen) {
  await pause(animationSettleMilliseconds);
  const counts = async () => ({ ...(await inWorker("({ drawn: zuiHost.framesDrawn, turns: zuiHost.turns })")), animation: await evaluate("animationFramesSeen") });
  const before = await counts();
  await pause(idleMilliseconds);
  const after = await counts();
  const drawn = after.drawn - before.drawn;
  const turns = after.turns - before.turns;
  const animation = after.animation - before.animation;
  const seconds = idleMilliseconds / 1000;
  if (animation < animationFramesFewest) await fail(`the page saw ${animation} animation frames in ${seconds} s, too few to tell whether the tour sleeps`);
  if (drawn > idleFramesMost) await fail(`the tour drew ${drawn} frames in ${seconds} s idle on ${screen}, of the display's ${animation}, so it never sleeps`);
  if (turns > idleFramesMost) await fail(`the worker took ${turns} turns in ${seconds} s idle on ${screen}, of the display's ${animation} frames`);
  return { drawn, animation };
}

async function expectDrawnAfter(what, act) {
  const before = await inWorker("zuiHost.framesDrawn");
  await act();
  await waitUntil(async () => (await inWorker("zuiHost.framesDrawn")) > before, `the tour drew no frame after ${what}`);
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

const overviewIdle = await idleFrames("the Overview");

// Down the rail's column, wherever its rows lie, until one shows the pointer.
const railColumn = 50;
const railStep = 16;
const cursorPatienceMilliseconds = 500;
async function moveOntoARailRow() {
  const pointerShown = () => evaluate(`host.canvas.style.cursor === "pointer"`);
  for (let y = 80; y < 800; y += railStep) {
    await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: railColumn, y });
    for (let waited = 0; waited < cursorPatienceMilliseconds; waited += 50) {
      if (await pointerShown()) return;
      await pause(50);
    }
  }
  await fail("the canvas did not show the pointer cursor over any row of the rail");
}
await expectDrawnAfter("the mouse moved over the rail", moveOntoARailRow);
await idleFrames("the Overview, under the mouse");

const overviewDigest = await inWorker("canvasDigest()");
await expectDrawnAfter("Ctrl+PageDown", nextScreen);
await waitUntil(async () => (await inWorker("canvasDigest()")) !== overviewDigest, "the canvas still showed the Overview after Ctrl+PageDown");

const tasksBefore = await inWorker("tasks().started");
await chord("5", "Digit5", 53);
await waitUntil(async () => (await inWorker("tasks().started")) > tasksBefore, "the tour started no tasks after Ctrl+5, Log Tail's shortcut");
const logTasks = await inWorker("tasks()");

// How fast the worker draws is the machine's: a runner's software GPU draws
// a few frames a second. What the host decides is not: it must schedule
// the next turn as soon as a task's sleep ends, never wait for input while
// a task is left, and keep drawing what the tasks deliver.
await inWorker(`(globalThis.schedulesSeen = [], zuiHost.onSchedule = (schedule) => schedulesSeen.push({ ...schedule, tasks: tasks() }), true)`);
const schedulesSince = (from) =>
  inWorker(`schedulesSeen.slice(${from}).map(({ now, kind, atMilliseconds, tasks }) => ({
    waitMilliseconds: kind === "timer" ? atMilliseconds - now : kind === "animationFrame" ? 0 : Infinity,
    tasksLeft: tasks.started - tasks.finished,
  }))`);

// Log Tail's rate publishes 30 times a second, so each of the host's waits
// ends by the next publication.
const producerMilliseconds = 2_000;
const producerPeriodMilliseconds = 1000 / 30;
const producedFramesFewest = 2;
const logFramesBefore = await inWorker("zuiHost.framesDrawn");
await pause(producerMilliseconds);
const logFrames = (await inWorker("zuiHost.framesDrawn")) - logFramesBefore;
const logSchedules = await schedulesSince(0);
if (logFrames < producedFramesFewest) await fail(`Log Tail drew ${logFrames} frames in ${producerMilliseconds / 1000} s of its producers publishing`);
const logLongestWait = Math.max(...logSchedules.map((schedule) => schedule.waitMilliseconds));
if (logLongestWait > producerPeriodMilliseconds + 1) await fail(`the host waited ${logLongestWait.toFixed(1)} ms between Log Tail's publications, ${producerPeriodMilliseconds.toFixed(1)} ms apart`);

await expectDrawnAfter("Ctrl+PageUp", previousScreen);
const photoSchedulesFrom = (await inWorker("schedulesSeen.length")) - 1;
const loadsFinished = async () => {
  const { started, finished } = await inWorker("tasks()");
  return started > logTasks.started && finished === started;
};
for (let finishedBefore = -1, unchangedSince = Date.now(); !(await loadsFinished()); await pause(50)) {
  const { started, finished } = await inWorker("tasks()");
  if (finished !== finishedBefore) [finishedBefore, unchangedSince] = [finished, Date.now()];
  if (Date.now() - unchangedSince > settleMilliseconds) await fail(`no task of the photos or Log Tail's producers finished for ${settleMilliseconds / 1000} s, ${finished} of ${started}`);
}
const photoSchedules = await schedulesSince(photoSchedulesFrom);
if (photoSchedules.some((schedule) => schedule.tasksLeft > 0 && schedule.waitMilliseconds === Infinity)) await fail("the host waited for input while the photos or Log Tail's producers were left");
const photoTasks = await inWorker("tasks()");
const photoIdle = await idleFrames("Photo Culling, its photos loaded");
const failed = await failures();
if (failed.length > 0) await fail(`the page failed: ${failed.join("\n")}`);

clearTimeout(watchdog);
await page.close();
const perSecond = ({ drawn, animation }) => `${(drawn / (idleMilliseconds / 1000)).toFixed(1)} frames a second of the display's ${(animation / (idleMilliseconds / 1000)).toFixed(0)}`;
console.log(
  `check_site: isolated by its service worker after one reload; ${distinctColors} colors, the newest frame declared in ${frameMicroseconds.toFixed(0)} µs; ` +
    `idle, ${perSecond(overviewIdle)} on the Overview and ${perSecond(photoIdle)} on Photo Culling; ` +
    `woken and drawn by the mouse over the rail, which shows the pointer, and by Ctrl+PageDown; ` +
    `${logTasks.started} tasks started after Ctrl+5 showed Log Tail, ${(logFrames / (producerMilliseconds / 1000)).toFixed(0)} frames a second of its producers, ` +
    `and ${photoTasks.finished - logTasks.finished} tasks finished without input on Photo Culling`,
);
