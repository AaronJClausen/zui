// node check_host.mjs <chromium> <tour directory>
//
// Serves the tour on `zui_web.Host`, as `zig build tour` writes it,
// cross-origin isolated, and opens it in headless Chromium, reading the
// worker the tour runs in through the DevTools protocol. The worker must
// draw the tour on the canvas the page transferred to it, at the canvas's
// size; idle, take no turns but the tour's once-a-second heartbeat while
// the display runs on; take the input the page sends it, so the mouse over
// the rail shows the pointer the tour asks for on the page's canvas, and
// Ctrl+PageDown draws the next screen; and, when its WebGL context is lost
// through `WEBGL_lose_context` and restored, draw that screen again.

import { readdir } from "node:fs/promises";
import { extname, join, relative, sep } from "node:path";
import { openHeadlessPage } from "./headless_page.mjs";

const watchdogMilliseconds = 120_000;
const settleMilliseconds = 10_000;
const [chromiumPath, tourDirectory] = process.argv.slice(2);

const contentTypes = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".txt": "text/plain",
};
const isolationHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

const served = {};
for (const entry of await readdir(tourDirectory, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile()) continue;
  const path = join(entry.parentPath, entry.name);
  const url = `/${relative(tourDirectory, path).split(sep).join("/")}`;
  served[url === "/index.html" ? "/" : url] = { path, type: contentTypes[extname(path)] ?? "application/octet-stream" };
}

let page = null;

async function fail(message) {
  console.error(`check_host: ${message}`);
  await page?.close();
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

try {
  page = await openHeadlessPage(chromiumPath, served, { headers: isolationHeaders, attachWorkers: true });
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

await waitUntil(() => inWorkerOrNot("zuiHost.framesDrawn > 0").catch(() => false), "the worker drew no frame");

await inWorker(`(() => {
  globalThis.canvasPixels = () => {
    const { gl } = zuiHost.drawers.get(0);
    const pixels = new Uint32Array(gl.drawingBufferWidth * gl.drawingBufferHeight);
    gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(pixels.buffer));
    return pixels;
  };
  globalThis.distinctColors = () => new Set(canvasPixels()).size;
  globalThis.kept = {};
  globalThis.keepPixels = (name) => {
    kept[name] = canvasPixels();
    return kept[name].length;
  };
  // The share of the canvas's pixels that differ from those kept as \`name\`.
  globalThis.differingFrom = (name) => {
    const now = canvasPixels();
    const then = kept[name];
    if (now.length !== then.length) return 1;
    let differing = 0;
    for (let index = 0; index < now.length; index += 1) if (now[index] !== then[index]) differing += 1;
    return differing / now.length;
  };
  return true;
})()`);

await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1.25, mobile: false });
await waitUntil(() => inWorker("(({ canvas }) => canvas.width === 1600 && canvas.height === 1000)(zuiHost.drawers.get(0))"), "the canvas was not drawn at its new size");

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
await pause(500);
const distinctColors = await inWorker("distinctColors()");
const fewestDistinctColors = 64;
if (distinctColors < fewestDistinctColors) await fail(`the canvas shows ${distinctColors} colors, not a frame of the tour`);

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
const idleTurnsMost = 3;
const animationFramesFewest = 30;

async function idleTurns(screen) {
  await pause(animationSettleMilliseconds);
  const counts = async () => ({ ...(await inWorker("({ turns: zuiHost.turns, drawn: zuiHost.framesDrawn })")), animation: await evaluate("animationFramesSeen") });
  const before = await counts();
  await pause(idleMilliseconds);
  const after = await counts();
  const turns = after.turns - before.turns;
  const drawn = after.drawn - before.drawn;
  const animation = after.animation - before.animation;
  const seconds = idleMilliseconds / 1000;
  if (animation < animationFramesFewest) await fail(`the page saw ${animation} animation frames in ${seconds} s, too few to tell whether the tour sleeps`);
  if (turns > idleTurnsMost) await fail(`the worker took ${turns} turns in ${seconds} s idle on ${screen}, of the display's ${animation} frames, so it never sleeps`);
  return { turns, drawn, animation };
}

async function expectDrawnAfter(what, act) {
  const before = await inWorker("zuiHost.framesDrawn");
  await act();
  await waitUntil(async () => (await inWorker("zuiHost.framesDrawn")) > before, `the worker drew no frame after ${what}`);
}

const control = 2;
async function chord(key, code, windowsVirtualKeyCode) {
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, windowsVirtualKeyCode, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode, modifiers: control });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17 });
}

const overviewIdle = await idleTurns("the Overview");

await expectDrawnAfter("the mouse moved over the rail", () => send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 50, y: 266 }));
await waitUntil(() => evaluate(`host.canvas.style.cursor === "pointer"`), "the canvas did not show the pointer cursor over the rail");
await idleTurns("the Overview, under the mouse");

await inWorker("keepPixels('overview')");
await expectDrawnAfter("Ctrl+PageDown", () => chord("PageDown", "PageDown", 34));
const screenChangeFewest = 0.05;
await waitUntil(async () => (await inWorker("differingFrom('overview')")) > screenChangeFewest, "the canvas still showed the Overview after Ctrl+PageDown");
const nextScreenChange = await inWorker("differingFrom('overview')");

// Harbor, the next screen, runs live; Settings, five screens on, waits
// for its user.
const pageDownsToSettings = 5;
for (let screen = 0; screen < pageDownsToSettings; screen += 1) await expectDrawnAfter("Ctrl+PageDown", () => chord("PageDown", "PageDown", 34));
const settingsIdle = await idleTurns("Settings");

await inWorker("keepPixels('before the loss')");
await inWorker("(globalThis.loseContext = zuiHost.drawers.get(0).gl.getExtension('WEBGL_lose_context'), loseContext.loseContext(), true)");
await waitUntil(() => inWorker("zuiHost.contextsLost === 1"), "the worker did not hear its context was lost");
await pause(200);
const drawnWhileLost = await inWorker("zuiHost.framesDrawn");
await inWorker("(loseContext.restoreContext(), true)");
await waitUntil(() => inWorker("zuiHost.contextsRestored === 1"), "the worker did not hear its context was restored");
await waitUntil(async () => (await inWorker("zuiHost.framesDrawn")) > drawnWhileLost, "the worker drew no frame after its context was restored");
await pause(500);
const restoredChange = await inWorker("differingFrom('before the loss')");
const restoredFromOverview = await inWorker("differingFrom('overview')");
const keptScreenChangeMost = 0.02;
if (restoredChange > keptScreenChangeMost) await fail(`after the context came back, ${(restoredChange * 100).toFixed(1)}% of the canvas differs from the screen before it was lost`);
if (restoredFromOverview <= screenChangeFewest) await fail("after the context came back, the canvas shows the Overview, not the screen the tour was on");
const restoredColors = await inWorker("distinctColors()");
if (restoredColors < fewestDistinctColors) await fail(`after the context came back, the canvas shows ${restoredColors} colors`);

const failed = await failures();
if (failed.length > 0) await fail(`the page failed: ${failed.join("\n")}`);

clearTimeout(watchdog);
await page.close();
const perSecond = ({ turns, animation }) => `${(turns / (idleMilliseconds / 1000)).toFixed(1)} turns a second of the display's ${(animation / (idleMilliseconds / 1000)).toFixed(0)}`;
console.log(
  `check_host: the worker drew ${distinctColors} colors at 1600×1000; idle, ${perSecond(overviewIdle)} on the Overview and ${perSecond(settingsIdle)} on Settings; ` +
    `the mouse over the rail showed the pointer and Ctrl+PageDown changed ${(nextScreenChange * 100).toFixed(0)}% of the canvas; ` +
    `after a lost context came back, ${(restoredChange * 100).toFixed(2)}% of Settings differs from before`,
);
