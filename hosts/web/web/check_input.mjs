// node check_input.mjs <chromium> <client wasm> <replay-input>
//
// Gives the page input through Chromium, as a user would, also through the
// hidden text field the page places at a caret, where a key's text and an
// IME's composition must each be written once, takes the records the
// client writes of it, and runs zui-sokol's tour on them with
// `replay-input`, which checks each record and what the tour did with it.
// The frames the tour drew then come back to the page, which must show
// the cursor each asks for.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { openHeadlessPage } from "./headless_page.mjs";

const watchdogMilliseconds = 120_000;
const [chromiumPath, wasmPath, replayPath] = process.argv.slice(2);
const webDirectory = dirname(fileURLToPath(import.meta.url));

let page = null;
let workDirectory = null;

async function cleanUp() {
  await page?.close();
  if (workDirectory) await rm(workDirectory, { recursive: true, force: true });
}

async function fail(message) {
  console.error(`check_input: ${message}`);
  await cleanUp();
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

try {
  page = await openHeadlessPage(chromiumPath, {
    "/": { path: join(webDirectory, "check_input.html"), type: "text/html" },
    "/input_recorder.mjs": { path: join(webDirectory, "input_recorder.mjs"), type: "text/javascript" },
    "/page_text_field.mjs": { path: join(webDirectory, "page_text_field.mjs"), type: "text/javascript" },
    "/zui-web.wasm": { path: wasmPath, type: "application/wasm" },
  });
} catch (error) {
  await fail(error.message);
}
const { evaluate, send } = page;

const records = [];
async function takeRecord(what) {
  const record = await evaluate("takeRecord()");
  if (page.pageErrors.length > 0) await fail(`the page failed: ${page.pageErrors.join("\n")}`);
  if (record === null) await fail(`no record was sent after ${what}`);
  records.push(Buffer.from(record, "base64"));
}

async function expectNoRecord(what) {
  if ((await evaluate("takeRecord()")) !== null) await fail(`a record was sent after ${what}`);
}

const control = 2;
const keys = {
  Control: { code: "ControlLeft", windowsVirtualKeyCode: 17 },
  3: { code: "Digit3", windowsVirtualKeyCode: 51 },
  PageDown: { code: "PageDown", windowsVirtualKeyCode: 34 },
  a: { code: "KeyA", windowsVirtualKeyCode: 65, text: "a" },
  b: { code: "KeyB", windowsVirtualKeyCode: 66, text: "b" },
  // On a French layout, the key that types 2 with Shift.
  é: { code: "Digit2", windowsVirtualKeyCode: 50, text: "é" },
};

async function key(name, type, modifiers = 0) {
  const { text, ...place } = keys[name];
  await send("Input.dispatchKeyEvent", { type, key: name, modifiers, ...place, ...(type === "keyDown" && text ? { text } : {}) });
}

async function chord(name) {
  await key("Control", "keyDown", control);
  await key(name, "keyDown", control);
  await key(name, "keyUp", control);
  await key("Control", "keyUp");
}

async function mouse(type, x, y, extra = {}) {
  await send("Input.dispatchMouseEvent", { type, x, y, ...extra });
}

await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1.25, mobile: false });
await send("Emulation.setTouchEmulationEnabled", { enabled: true });
await takeRecord("the page opened");
await expectNoRecord("nothing happened");

await mouse("mouseMoved", 50, 266);
await takeRecord("the mouse moved onto the rail");
await mouse("mousePressed", 50, 266, { button: "left", buttons: 1, clickCount: 1 });
await mouse("mouseReleased", 50, 266, { button: "left", buttons: 0, clickCount: 1 });
await takeRecord("a click on the rail");
await expectNoRecord("the click was sent");

await chord("3");
await takeRecord("Ctrl+3");
await chord("PageDown");
await takeRecord("Ctrl+PageDown");

await key("a", "keyDown");
await key("a", "keyUp");
await key("é", "keyDown");
await key("é", "keyUp");
await takeRecord("typing");

await evaluate("(textField.place([100, 100, 2, 16]), true)");
if ((await evaluate("document.activeElement?.tagName")) !== "TEXTAREA") await fail("the page did not focus its hidden text field at the caret");
await expectNoRecord("the text field was placed");
await key("b", "keyDown");
await key("b", "keyUp");
await takeRecord("typing into the text field");
await send("Input.imeSetComposition", { text: "日本", selectionStart: 2, selectionEnd: 2 });
await send("Input.insertText", { text: "日本語" });
await takeRecord("an IME's composition in the text field");
await evaluate("(textField.place(null), true)");
if ((await evaluate("document.activeElement?.id")) !== "frame") await fail("the canvas did not take the focus back from the text field");
await expectNoRecord("the text field was taken away");

// The protocol's deltas are in device pixels, the page's in CSS pixels.
await mouse("mouseWheel", 640, 400, { deltaX: 0, deltaY: 120 * 1.25 });
await takeRecord("the wheel turned");

await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: 300, y: 300 }] });
await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
await takeRecord("a tap");

await send("Emulation.setDeviceMetricsOverride", { width: 1024, height: 768, deviceScaleFactor: 2, mobile: false });
await takeRecord("the window was resized");
await expectNoRecord("the resize was sent");

workDirectory = await mkdtemp(join(tmpdir(), "zui-web-input-"));
const recordsPath = join(workDirectory, "records.zuiw");
const streamPath = join(workDirectory, "frames.zuiw");
await writeFile(recordsPath, Buffer.concat(records));

const replayOutput = [];
const replayExit = await new Promise((resolve) => {
  const replay = spawn(replayPath, [recordsPath, streamPath], { stdio: ["ignore", "pipe", "pipe"] });
  replay.stdout.on("data", (chunk) => replayOutput.push(chunk));
  replay.stderr.on("data", (chunk) => replayOutput.push(chunk));
  replay.on("error", (error) => resolve(error.message));
  replay.on("exit", (code, signal) => resolve(signal ?? code));
});
if (replayExit !== 0) await fail(`the tour did not take the records as given (${replayExit}):\n${Buffer.concat(replayOutput)}`);

const cursors = await evaluate(`receiveFrames("${(await readFile(streamPath)).toString("base64")}")`).catch((error) => fail(`the tour's frames: ${error.message}`));
if (cursors.length !== records.length) await fail(`${cursors.length} frames came back for ${records.length} records`);
const expectedCursors = { 0: "default", 1: "pointer" };
for (const [index, cursor] of Object.entries(expectedCursors)) {
  if (cursors[index] !== cursor) await fail(`after frame ${index} the canvas shows the ${cursors[index] || "unset"} cursor, not ${cursor}`);
}

clearTimeout(watchdog);
await cleanUp();
console.log(`check_input: ${records.length} records, ${records.reduce((total, record) => total + record.length, 0)} bytes, taken by the tour as given; its frames' cursors shown`);
