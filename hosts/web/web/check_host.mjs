// node check_host.mjs <chromium> <tour directory>
//
// Serves the tour on `zui_web.Host`, as `zig build tour` writes it,
// cross-origin isolated, and opens it in headless Chromium, reading the
// worker the tour runs in through the DevTools protocol. The worker must
// draw the tour on the canvas the page transferred to it, at the canvas's
// size; idle, take no turns but the tour's once-a-second heartbeat while
// the display runs on; take the input the page sends it, so the mouse over
// the rail shows the pointer the tour asks for on the page's canvas, and
// Ctrl+PageDown draws the next screen; when its WebGL context is lost
// through `WEBGL_lose_context` and restored, draw that screen again; hear
// the page's settings first, its system accent color among them, then
// each change: an emulated dark scheme darkens the canvas and a light one
// lightens it, more contrast and a right-to-left document change it, and
// reduced motion stills Clickable Chaos's wall; while another tab hides the page, draw nothing; place the
// page's hidden text field at the caret of Settings' Port field, through
// which a typed key and an IME's composition reach the tour once each; and
// copy to and read from the page's clipboard, with the permission granted.

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
const sendToBrowserOrFail = (method, params) => page.sendToBrowser(method, params).catch((error) => fail(`${method}: ${error.message}`));
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

const pageMeasured = await evaluate(`(() => {
  const probe = document.createElement("span");
  probe.style.cssText = "display: none; color: AccentColor";
  document.documentElement.append(probe);
  const [red, green, blue] = getComputedStyle(probe).color.match(/\\d+/g).map((channel) => Number(channel).toString(16).padStart(2, "0"));
  probe.remove();
  return { locale: navigator.language, window_focused: String(document.hasFocus()), accent: \`#\${red}\${green}\${blue}\` };
})()`);
if (!/^#[0-9a-f]{6}$/.test(pageMeasured.accent)) await fail(`the page's AccentColor read as ${JSON.stringify(pageMeasured.accent)}, not a color`);
const firstSettings = { theme: "light", contrast: "normal", reduced_motion: "false", reduced_transparency: "false", direction: "left_to_right", ...pageMeasured };
const deliveredFirst = await inWorker("zuiHost.settings");
for (const [name, value] of Object.entries(firstSettings)) {
  if (deliveredFirst[name] !== value) await fail(`the worker's first settings had ${name} ${JSON.stringify(deliveredFirst[name])}, not the page's ${JSON.stringify(value)}`);
}

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
  // From 0, black, to 255, white, over the canvas.
  globalThis.meanLuminance = () => {
    const pixels = canvasPixels();
    let sum = 0;
    for (const pixel of pixels) sum += 0.2126 * (pixel & 0xff) + 0.7152 * ((pixel >>> 8) & 0xff) + 0.0722 * ((pixel >>> 16) & 0xff);
    return sum / pixels.length;
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
// two seconds can span three, and of one second two.
const idleTurnsMost = 3;
const quietMilliseconds = 1_000;
const quietTurnsMost = 2;
const animationFramesFewest = 30;

// A frame drawn after a key proves nothing on a screen that runs live, so on
// a busy machine the worker can take the last screen change, and animate it,
// after the check has moved on. A worker that never sleeps never goes quiet,
// and fails the measurement that follows.
async function untilWorkerQuiet() {
  for (let waited = 0; waited < settleMilliseconds; waited += quietMilliseconds) {
    const before = await inWorker("zuiHost.turns");
    await pause(quietMilliseconds);
    if ((await inWorker("zuiHost.turns")) - before <= quietTurnsMost) return;
  }
}

async function idleTurns(screen) {
  await untilWorkerQuiet();
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

// `Emulation.setEmulatedMedia` replaces every feature it was given before.
const emulatedMedia = { "prefers-color-scheme": "light", "prefers-contrast": "no-preference", "prefers-reduced-motion": "no-preference", "prefers-reduced-transparency": "no-preference" };
async function emulateMedia(changes) {
  Object.assign(emulatedMedia, changes);
  await send("Emulation.setEmulatedMedia", { features: Object.entries(emulatedMedia).map(([name, value]) => ({ name, value })) });
}

async function expectSetting(name, value, act) {
  const before = await inWorker("zuiHost.framesDrawn");
  await act();
  await waitUntil(async () => (await inWorker(`zuiHost.settings[${JSON.stringify(name)}]`)) === value, `the worker did not hear the page's ${name} become ${value}`);
  await waitUntil(async () => (await inWorker("zuiHost.framesDrawn")) > before, `the worker drew no frame after the page's ${name} became ${value}`);
}

const luminanceChangeFewest = 20;
await expectSetting("theme", "dark", () => emulateMedia({ "prefers-color-scheme": "dark" }));
await pause(300);
const darkLuminance = await inWorker("meanLuminance()");
await expectSetting("theme", "light", () => emulateMedia({ "prefers-color-scheme": "light" }));
await waitUntil(async () => (await inWorker("meanLuminance()")) > darkLuminance + luminanceChangeFewest, "the canvas did not lighten when the page preferred a light scheme");
const lightLuminance = await inWorker("meanLuminance()");
await expectSetting("theme", "dark", () => emulateMedia({ "prefers-color-scheme": "dark" }));
await waitUntil(async () => (await inWorker("meanLuminance()")) < lightLuminance - luminanceChangeFewest, "the canvas did not darken again when the page preferred a dark scheme");

// High contrast draws the muted text and the borders in the text's color.
const contrastChangeFewest = 0.005;
await pause(300);
await inWorker("keepPixels('normal contrast')");
await expectSetting("contrast", "high", () => emulateMedia({ "prefers-contrast": "more" }));
await waitUntil(async () => (await inWorker("differingFrom('normal contrast')")) > contrastChangeFewest, "the canvas did not change when the page preferred more contrast");
const contrastChange = await inWorker("differingFrom('normal contrast')");
await expectSetting("contrast", "normal", () => emulateMedia({ "prefers-contrast": "no-preference" }));
await waitUntil(async () => (await inWorker("differingFrom('normal contrast')")) < keptScreenChangeMost, "the canvas did not return to normal contrast");

await inWorker("keepPixels('left to right')");
await expectSetting("direction", "right_to_left", () => evaluate(`(document.documentElement.dir = "rtl", true)`));
await waitUntil(async () => (await inWorker("differingFrom('left to right')")) > screenChangeFewest, "the canvas was not mirrored when the page's direction became right to left");
const mirroredChange = await inWorker("differingFrom('left to right')");
await expectSetting("direction", "left_to_right", () => evaluate(`(document.documentElement.removeAttribute("dir"), true)`));
await waitUntil(async () => (await inWorker("differingFrom('left to right')")) < keptScreenChangeMost, "the canvas did not return to left to right");

// The tour shows neither, so they are checked as far as the worker.
await expectSetting("reduced_transparency", "true", () => emulateMedia({ "prefers-reduced-transparency": "reduce" }));
await expectSetting("reduced_transparency", "false", () => emulateMedia({ "prefers-reduced-transparency": "no-preference" }));
// Nothing in the protocol changes `navigator.language` for a page already
// loaded, so the page's is replaced, as a change of the user's would be.
const otherLanguage = "ar-EG";
await expectSetting("locale", otherLanguage, () => evaluate(`(Object.defineProperty(navigator, "language", { value: ${JSON.stringify(otherLanguage)}, configurable: true }), dispatchEvent(new Event("languagechange")), true)`));
await expectSetting("locale", pageMeasured.locale, () => evaluate(`(delete navigator.language, dispatchEvent(new Event("languagechange")), true)`));

// Another tab in front hides the page and takes the window's focus.
await pause(300);
await inWorker("keepPixels('before hidden')");
const { targetId: otherTab } = await send("Target.createTarget", { url: "about:blank" });
await waitUntil(() => inWorker(`zuiHost.pageShown === false && zuiHost.settings.window_focused === "false"`), "the worker did not hear the page was hidden and lost the focus");
await pause(animationSettleMilliseconds);
const hiddenMilliseconds = 1_500;
const beforeHidden = await inWorker("({ turns: zuiHost.turns, drawn: zuiHost.framesDrawn })");
await pause(hiddenMilliseconds);
const afterHidden = await inWorker("({ turns: zuiHost.turns, drawn: zuiHost.framesDrawn })");
const drawnWhileHidden = afterHidden.drawn - beforeHidden.drawn;
const turnsWhileHidden = afterHidden.turns - beforeHidden.turns;
if (drawnWhileHidden > 0) await fail(`the worker drew ${drawnWhileHidden} frames in ${hiddenMilliseconds / 1000} s while the page was hidden`);
await send("Page.bringToFront");
await waitUntil(() => inWorker(`zuiHost.pageShown === true && zuiHost.settings.window_focused === "true"`), "the worker did not hear the page was shown and had the focus");
await waitUntil(async () => (await inWorker("zuiHost.framesDrawn")) > afterHidden.drawn, "the worker drew no frame once the page was shown again");
await pause(500);
const shownChange = await inWorker("differingFrom('before hidden')");
if (shownChange > keptScreenChangeMost) await fail(`once the page was shown again, ${(shownChange * 100).toFixed(1)}% of the canvas differs from before it was hidden`);
await send("Target.closeTarget", { targetId: otherTab });

// Clickable Chaos, the rail's last screen, moves its wall in a wave unless
// motion is reduced.
const clickableChaosOnTheRail = { x: 64, y: 706 };
await expectDrawnAfter("a click on Clickable Chaos in the rail", async () => {
  for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, ...clickableChaosOnTheRail, button: "left", buttons: type === "mousePressed" ? 1 : 0, clickCount: 1 });
});
// Software rendering draws the wall at a fraction of the display's rate,
// under load at a fifth of it.
const movingTurnsFewest = 3 * idleTurnsMost;
async function turnsInIdleTime() {
  await pause(animationSettleMilliseconds);
  const before = await inWorker("zuiHost.turns");
  await pause(idleMilliseconds);
  return (await inWorker("zuiHost.turns")) - before;
}
const movingTurns = await turnsInIdleTime();
if (movingTurns < movingTurnsFewest) await fail(`the worker took ${movingTurns} turns in ${idleMilliseconds / 1000} s on Clickable Chaos, so its wall does not move`);
await expectSetting("reduced_motion", "true", () => emulateMedia({ "prefers-reduced-motion": "reduce" }));
const reducedMotionIdle = await idleTurns("Clickable Chaos, with reduced motion");
await expectSetting("reduced_motion", "false", () => emulateMedia({ "prefers-reduced-motion": "no-preference" }));
const movingAgainTurns = await turnsInIdleTime();
if (movingAgainTurns < movingTurnsFewest) await fail(`the worker took ${movingAgainTurns} turns in ${idleMilliseconds / 1000} s on Clickable Chaos once motion was no longer reduced`);

// Back on Settings, through its entry on the rail, a click in its Port
// field gives it the focus, and the page its hidden field.
const settingsOnTheRail = { x: 70, y: 348 };
const portField = { x: 540, y: 434 };
async function click({ x, y }) {
  await send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1 });
  await send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1 });
}
await expectDrawnAfter("a click on Settings in the rail", () => click(settingsOnTheRail));
await pause(animationSettleMilliseconds);
await expectDrawnAfter("a click in the Port field", () => click(portField));
await waitUntil(() => evaluate(`document.activeElement?.tagName === "TEXTAREA"`), "the page did not focus its hidden text field after a click in the Port field");
const placedField = await evaluate(`(({ left, top }, bounds) => [parseFloat(left) - bounds.left, parseFloat(top) - bounds.top])(document.activeElement.style, host.canvas.getBoundingClientRect())`);
const portFieldReach = 200;
if (Math.abs(placedField[0] - portField.x) > portFieldReach || Math.abs(placedField[1] - portField.y) > 20) await fail(`the hidden text field is at ${placedField}, not at the Port field's caret near ${[portField.x, portField.y]}`);

const textReceived = () =>
  inWorker(`new TextDecoder().decode(new Uint8Array(zuiHost.memory.buffer, zuiHost.module.zuiTourTextReceived() >>> 0, zuiHost.module.zuiTourTextReceivedBytes() >>> 0).slice())`);
const receivedBefore = await textReceived();
await send("Input.dispatchKeyEvent", { type: "keyDown", key: "7", code: "Digit7", windowsVirtualKeyCode: 55, text: "7" });
await send("Input.dispatchKeyEvent", { type: "keyUp", key: "7", code: "Digit7", windowsVirtualKeyCode: 55 });
const composed = "日本語";
await send("Input.imeSetComposition", { text: "日本", selectionStart: 2, selectionEnd: 2 });
await send("Input.insertText", { text: composed });
const expectedText = `${receivedBefore}7${composed}`;
await waitUntil(async () => (await textReceived()).length >= expectedText.length, "the tour did not receive the typed key's and the composition's text");
await pause(500);
const receivedText = await textReceived();
if (receivedText !== expectedText) await fail(`the tour received the text ${JSON.stringify(receivedText)}, not ${JSON.stringify(expectedText)}, once each`);

await sendToBrowserOrFail("Browser.grantPermissions", { origin: new URL(page.pageUrl).origin, permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"] });
const copiedByTheWorker = "zui \u2713 copied from the worker";
if (!(await inWorker("zuiHost.module.zuiTourCopyForCheck()"))) await fail("the host refused to copy to the clipboard");
await waitUntil(async () => (await evaluate("navigator.clipboard.readText()")) === copiedByTheWorker, "the page's clipboard did not hold what the worker copied");
const copiedByThePage = "zui \u2713 copied by the page";
await evaluate(`navigator.clipboard.writeText(${JSON.stringify(copiedByThePage)}).then(() => true)`);
const pasted = () => inWorker(`(() => {
  const at = zuiHost.module.zuiTourPastedForCheck() >>> 0;
  const bytes = new Uint8Array(zuiHost.memory.buffer);
  return new TextDecoder().decode(bytes.slice(at, bytes.indexOf(0, at)));
})()`);
if (!(await inWorker("zuiHost.module.zuiTourPasteForCheck()"))) await fail("the host refused to read the clipboard");
await waitUntil(async () => (await pasted()) !== "", "the host did not answer the clipboard read");
const pastedText = await pasted();
if (pastedText !== copiedByThePage) await fail(`the clipboard read answered ${JSON.stringify(pastedText)}, not what the page copied, ${JSON.stringify(copiedByThePage)}`);

const failed = await failures();
if (failed.length > 0) await fail(`the page failed: ${failed.join("\n")}`);

clearTimeout(watchdog);
await page.close();
const perSecond = ({ turns, animation }) => `${(turns / (idleMilliseconds / 1000)).toFixed(1)} turns a second of the display's ${(animation / (idleMilliseconds / 1000)).toFixed(0)}`;
console.log(
  `check_host: the worker drew ${distinctColors} colors at 1600×1000; idle, ${perSecond(overviewIdle)} on the Overview and ${perSecond(settingsIdle)} on Settings; ` +
    `the mouse over the rail showed the pointer and Ctrl+PageDown changed ${(nextScreenChange * 100).toFixed(0)}% of the canvas; ` +
    `after a lost context came back, ${(restoredChange * 100).toFixed(2)}% of Settings differs from before; ` +
    `the canvas's luminance went from ${darkLuminance.toFixed(0)} dark to ${lightLuminance.toFixed(0)} light, more contrast changed ${(contrastChange * 100).toFixed(1)}% of it ` +
    `and right to left ${(mirroredChange * 100).toFixed(0)}%; hidden, the worker drew no frame and took ${turnsWhileHidden} turns in ${hiddenMilliseconds / 1000} s; ` +
    `on Clickable Chaos it took ${movingTurns} turns in ${idleMilliseconds / 1000} s, ${reducedMotionIdle.turns} with reduced motion and ${movingAgainTurns} after; ` +
    `the Port field's hidden text field took ${JSON.stringify(receivedText.slice(receivedBefore.length))} once, and the clipboard went both ways`,
);
