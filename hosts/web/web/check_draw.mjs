// [ZUI_WEB_DRAW_FAILURES=<directory>] node check_draw.mjs <chromium> <client wasm> <stream> <reference> <bitmap fonts> <TrueType font>...
// Each frame that fails is written there as PPM, drawn and reference;
// without it, to a new temporary directory.

import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// A pixel matches when each of its colors is within `tolerance` of the
// reference's, or of a reference neighbor's within `edgeReach` pixels,
// since two rasterizers may place an edge a pixel apart.
const tolerance = 2;
const edgeReach = 1;
// A glyph's partial coverage at its edge is a color no neighbor has, and
// two rasterizers decide a pixel whose centre lies that close to the edge
// differently.
const maxUnmatchedPixelsPerFrame = 1;
const watchdogMilliseconds = 300_000;

const [chromiumPath, wasmPath, streamPath, referencePath, bitmapFontsPath, ...trueTypeFontPaths] = process.argv.slice(2);
const webDirectory = dirname(fileURLToPath(import.meta.url));

const served = {
  "/": { path: join(webDirectory, "check_draw.html"), type: "text/html" },
  "/frame_drawer.mjs": { path: join(webDirectory, "frame_drawer.mjs"), type: "text/javascript" },
  "/zui-web.wasm": { path: wasmPath, type: "application/wasm" },
  "/tour.zuiw": { path: streamPath, type: "application/octet-stream" },
  "/bitmap.fonts": { path: bitmapFontsPath, type: "application/octet-stream" },
};
const trueTypeFontUrls = trueTypeFontPaths.map((path, index) => {
  const url = `/truetype-${index}.ttf`;
  served[url] = { path, type: "font/ttf" };
  return url;
});
served["/truetype-fonts.json"] = { body: JSON.stringify(trueTypeFontUrls), type: "application/json" };

let chromium = null;
let profileDirectory = null;
let server = null;

async function cleanUp() {
  if (chromium && chromium.exitCode === null && chromium.signalCode === null) {
    const exited = new Promise((resolve) => chromium.once("exit", resolve));
    chromium.kill("SIGKILL");
    await exited;
  }
  server?.close();
  // Chromium's child processes outlive the one killed, and may still be
  // writing to the profile as it is removed.
  if (profileDirectory) await rm(profileDirectory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}

async function fail(message) {
  console.error(`check_draw: ${message}`);
  await cleanUp();
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

function readReference(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const frames = [];
  for (let at = 0; at < bytes.length;) {
    const number = Number(view.getBigUint64(at, true));
    const width = view.getUint32(at + 8, true);
    const height = view.getUint32(at + 12, true);
    at += 16;
    frames.push({ number, width, height, pixels: bytes.subarray(at, at + width * height * 4) });
    at += width * height * 4;
  }
  return frames;
}

function within(drawn, reference, drawnAt, referenceAt) {
  for (let channel = 0; channel < 3; channel += 1) {
    if (Math.abs(drawn[drawnAt + channel] - reference[referenceAt + channel]) > tolerance) return false;
  }
  return true;
}

function compare(drawn, reference, width, height) {
  let differing = 0;
  let beyondTolerance = 0;
  let unmatched = 0;
  let largestDifference = 0;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const at = (y * width + x) * 4;
      let difference = 0;
      for (let channel = 0; channel < 3; channel += 1) difference = Math.max(difference, Math.abs(drawn[at + channel] - reference[at + channel]));
      if (difference === 0) continue;
      differing += 1;
      largestDifference = Math.max(largestDifference, difference);
      if (difference <= tolerance) continue;
      beyondTolerance += 1;
      let matchedNearby = false;
      for (let dy = -edgeReach; dy <= edgeReach && !matchedNearby; dy += 1) {
        for (let dx = -edgeReach; dx <= edgeReach && !matchedNearby; dx += 1) {
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          matchedNearby = within(drawn, reference, at, (ny * width + nx) * 4);
        }
      }
      if (!matchedNearby) unmatched += 1;
    }
  }
  return { differing, beyondTolerance, unmatched, largestDifference };
}

async function writePortablePixmap(path, pixels, width, height) {
  const header = Buffer.from(`P6\n${width} ${height}\n255\n`);
  const body = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const from = ((height - 1 - y) * width + x) * 4;
      body.set(pixels.subarray(from, from + 3), (y * width + x) * 3);
    }
  }
  await writeFile(path, Buffer.concat([header, body]));
}

server = createServer(async (request, response) => {
  const file = served[new URL(request.url, "http://localhost").pathname];
  if (!file) {
    response.writeHead(404).end();
    return;
  }
  const body = file.path ? await readFile(file.path) : file.body;
  response.writeHead(200, { "content-type": file.type }).end(body);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/`;

profileDirectory = await mkdtemp(join(tmpdir(), "zui-web-chromium-"));
chromium = spawn(chromiumPath, [
  "--headless",
  `--user-data-dir=${profileDirectory}`,
  "--remote-debugging-port=0",
  // The same software rasterizer on every machine, whatever its GPU.
  "--use-angle=swiftshader",
  "--enable-unsafe-swiftshader",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-extensions",
  "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });
chromium.on("error", (error) => fail(`${chromiumPath} did not start: ${error.message}`));

const debuggerUrl = await new Promise((resolve) => {
  let output = "";
  const exitedEarly = (code) => fail(`${chromiumPath} exited with ${code} before it listened:\n${output}`);
  chromium.once("exit", exitedEarly);
  chromium.stderr.on("data", (chunk) => {
    output += chunk;
    const announced = output.match(/DevTools listening on (ws:\S+)/);
    if (!announced) return;
    chromium.off("exit", exitedEarly);
    output = "";
    resolve(announced[1]);
  });
});

const socket = new WebSocket(debuggerUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = () => reject(new Error("the DevTools socket did not open"));
});
let nextRequestId = 1;
const pending = new Map();
const pageErrors = [];
socket.onmessage = ({ data }) => {
  const message = JSON.parse(data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result);
  } else if (message.method === "Runtime.exceptionThrown") {
    pageErrors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
  }
};

function send(method, params = {}, sessionId = undefined) {
  const id = nextRequestId;
  nextRequestId += 1;
  socket.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
await send("Runtime.enable", {}, sessionId);
await send("Page.navigate", { url: pageUrl }, sessionId);

async function evaluate(expression) {
  const { result, exceptionDetails } = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
  return result.value;
}

for (let attempt = 0; !(await evaluate("window.ready === true").catch(() => false)); attempt += 1) {
  if (pageErrors.length > 0) await fail(`the page failed: ${pageErrors.join("\n")}`);
  if (attempt === 600) await fail("the page did not load within 30 s");
  await new Promise((resolve) => setTimeout(resolve, 50));
}

async function directoryForFailedImages() {
  const named = process.env.ZUI_WEB_DRAW_FAILURES;
  if (!named) return mkdtemp(join(tmpdir(), "zui-web-draw-"));
  await mkdir(named, { recursive: true });
  return named;
}

const reference = readReference(await readFile(referencePath));
// A step that succeeds has its output dropped by `zig build`, and one that
// fails shows only its stderr.
const failedFrameLines = [];
let failedImages = null;
for (const expected of reference) {
  const drawn = await evaluate(`drawFrame(${expected.number})`).catch((error) => fail(`frame ${expected.number}: ${error.message}`));
  if (drawn.width !== expected.width || drawn.height !== expected.height) {
    await fail(`frame ${expected.number}: drawn ${drawn.width}×${drawn.height}, the reference is ${expected.width}×${expected.height}`);
  }
  if (drawn.overflows !== 0) await fail(`frame ${expected.number}: the draw list was full ${drawn.overflows} times`);
  if (drawn.glyphOverflows !== 0) await fail(`frame ${expected.number}: glyphs were left out ${drawn.glyphOverflows} times`);
  const pixels = Buffer.from(drawn.pixels, "base64");
  const result = compare(pixels, expected.pixels, expected.width, expected.height);
  const total = expected.width * expected.height;
  const line = `check_draw: frame ${expected.number}: ${result.differing} of ${total} pixels differ, by at most ${result.largestDifference}; ${result.beyondTolerance} by more than ${tolerance}, ${result.unmatched} of them matching no reference pixel within ${edgeReach} (at most ${maxUnmatchedPixelsPerFrame} allowed)`;
  console.log(line);
  if (result.unmatched > maxUnmatchedPixelsPerFrame) {
    failedFrameLines.push(line);
    failedImages ??= await directoryForFailedImages();
    await writePortablePixmap(join(failedImages, `${expected.number}-drawn.ppm`), pixels, expected.width, expected.height);
    await writePortablePixmap(join(failedImages, `${expected.number}-reference.ppm`), expected.pixels, expected.width, expected.height);
  }
}

clearTimeout(watchdog);
socket.close();
await cleanUp();
if (failedFrameLines.length > 0) {
  for (const line of failedFrameLines) console.error(line);
  console.error(`check_draw: ${failedFrameLines.length} of ${reference.length} frames do not match zui-sokol's; each frame drawn and its reference are in ${failedImages}`);
  process.exit(1);
}
console.log(`check_draw: ${reference.length} frames drawn in Chromium match zui-sokol's renderer`);
