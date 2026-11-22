// [ZUI_WEB_DRAW_FAILURES=<directory>] node check_draw.mjs <chromium> <client wasm> <frame drawer> <stream>
//     <one-sample reference> <four-sample reference without text> <TrueType font>...
// Each frame that fails is written there as PPM, drawn and reference;
// without it, to a new temporary directory.
//
// Each frame is drawn twice. With one sample per pixel, everything is
// compared, text too. With the four samples a pixel that zui-sokol's demo
// window has, which smooth every edge, text is left out: where a glyph's
// quad covers part of a pixel, a GPU may sample the glyph anywhere in the
// pixel, and SwiftShader and zui-sokol's GPU choose differently.

import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { openHeadlessPage } from "./headless_page.mjs";

// A pixel matches when each of its colors is within the tolerance of the
// other image's, or of a neighbor's there within `edgeReach` pixels, since
// two rasterizers may place an edge a pixel apart. With four samples, each
// reference pixel must also match the drawing that way: an edge smoothed
// in one image alone is a blend that the other has nowhere, though each of
// its unsmoothed pixels matches a neighbor across the edge. With one, a
// glyph's edge pixel may be in the glyph in one image and not the other.
// With four, a pixel also matches when each of its colors is within one
// sample's share of their range within `sampleShareReach` pixels:
// SwiftShader snaps vertices to a sixteenth of a pixel, so a sample that
// close to an edge is decided differently. An edge left unsmoothed still
// differs by half that range where the edge halves a pixel.
const gpuTolerance = 2;
// Mesa's llvmpipe, which draws the reference where there is no GPU, as in
// CI, blends into 8 bits rounding `src * alpha` and `dst * (1 - alpha)`
// each, so each translucent layer may leave a color a step below a GPU's,
// which rounds their sum. A label under a fade at alpha 1/255 is 3 steps
// off, and text stacked dozens of lines deep 5.
const llvmpipeTolerance = 5;
const edgeReach = 1;
const sampleShareReach = 2;
// With one sample, a glyph's partial coverage at its edge is a color no
// neighbor has, and two rasterizers decide a pixel whose centre lies that
// close to the edge differently. With four, a pixel of a line thinner than
// a pixel is crossed by both its edges, so two of its samples may be
// decided differently; a frame whose edges are not smoothed has hundreds
// of pixels that match nothing.
const maxUnmatchedPixelsPerFrame = { 1: 1, 4: 4 };
const watchdogMilliseconds = 300_000;

const [chromiumPath, wasmPath, frameDrawerPath, streamPath, oneSampleReferencePath, fourSampleReferencePath, ...trueTypeFontPaths] = process.argv.slice(2);
const webDirectory = dirname(fileURLToPath(import.meta.url));

const served = {
  "/": { path: join(webDirectory, "check_draw.html"), type: "text/html" },
  "/client.mjs": { path: join(webDirectory, "client.mjs"), type: "text/javascript" },
  "/frame_drawer.mjs": { path: frameDrawerPath, type: "text/javascript" },
  "/zui-web.wasm": { path: wasmPath, type: "application/wasm" },
  "/tour.zuiw": { path: streamPath, type: "application/octet-stream" },
};
const trueTypeFontUrls = trueTypeFontPaths.map((path, index) => {
  const url = `/truetype-${index}.ttf`;
  served[url] = { path, type: "font/ttf" };
  return url;
});
served["/truetype-fonts.json"] = { body: JSON.stringify(trueTypeFontUrls), type: "application/json" };

let page = null;

async function cleanUp() {
  await page?.close();
}

async function fail(message) {
  console.error(`check_draw: ${message}`);
  await cleanUp();
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

function readReference(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const rendererNameLength = view.getUint32(0, true);
  const rendererName = Buffer.from(bytes.subarray(4, 4 + rendererNameLength)).toString("utf8");
  const frames = [];
  for (let at = 4 + rendererNameLength; at < bytes.length;) {
    const number = Number(view.getBigUint64(at, true));
    const width = view.getUint32(at + 8, true);
    const height = view.getUint32(at + 12, true);
    at += 16;
    frames.push({ number, width, height, pixels: bytes.subarray(at, at + width * height * 4) });
    at += width * height * 4;
  }
  return { rendererName, frames };
}

function toleranceOfRenderer(rendererName) {
  return rendererName.includes("llvmpipe") ? llvmpipeTolerance : gpuTolerance;
}

function within(drawn, reference, drawnAt, referenceAt, tolerance) {
  for (let channel = 0; channel < 3; channel += 1) {
    if (Math.abs(drawn[drawnAt + channel] - reference[referenceAt + channel]) > tolerance) return false;
  }
  return true;
}

function colorRangeAround(pixels, x, y, width, height, channel) {
  let least = 255;
  let most = 0;
  for (let ny = Math.max(0, y - sampleShareReach); ny <= Math.min(height - 1, y + sampleShareReach); ny += 1) {
    for (let nx = Math.max(0, x - sampleShareReach); nx <= Math.min(width - 1, x + sampleShareReach); nx += 1) {
      const value = pixels[(ny * width + nx) * 4 + channel];
      least = Math.min(least, value);
      most = Math.max(most, value);
    }
  }
  return most - least;
}

function withinOneSample(drawn, reference, x, y, width, height, samplesPerPixel, tolerance) {
  const at = (y * width + x) * 4;
  for (let channel = 0; channel < 3; channel += 1) {
    const range = Math.max(colorRangeAround(drawn, x, y, width, height, channel), colorRangeAround(reference, x, y, width, height, channel));
    if (Math.abs(drawn[at + channel] - reference[at + channel]) > tolerance + range / samplesPerPixel) return false;
  }
  return true;
}

function matchesNearby(pixels, other, x, y, width, height, tolerance) {
  const at = (y * width + x) * 4;
  for (let dy = -edgeReach; dy <= edgeReach; dy += 1) {
    for (let dx = -edgeReach; dx <= edgeReach; dx += 1) {
      const nx = x + dx;
      const ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
      if (within(pixels, other, at, (ny * width + nx) * 4, tolerance)) return true;
    }
  }
  return false;
}

function compare(drawn, reference, width, height, samplesPerPixel, tolerance) {
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
      const smoothed = samplesPerPixel > 1;
      const matched = matchesNearby(drawn, reference, x, y, width, height, tolerance) && (!smoothed || matchesNearby(reference, drawn, x, y, width, height, tolerance));
      if (matched || (smoothed && withinOneSample(drawn, reference, x, y, width, height, samplesPerPixel, tolerance))) continue;
      unmatched += 1;
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

try {
  page = await openHeadlessPage(chromiumPath, served);
} catch (error) {
  await fail(error.message);
}
const { evaluate } = page;

async function directoryForFailedImages() {
  const named = process.env.ZUI_WEB_DRAW_FAILURES;
  if (!named) return mkdtemp(join(tmpdir(), "zui-web-draw-"));
  await mkdir(named, { recursive: true });
  return named;
}

const blurAccumulationFormat = await evaluate("window.blurAccumulationFormat");
if (blurAccumulationFormat !== "RGBA32F") {
  await fail(`the page sums backdrop blurs in ${blurAccumulationFormat ?? "nothing, drawing their tint alone"}, not RGBA32F as the reference does, so they cannot be compared`);
}

const drawings = [
  { name: "oneSample", description: "with one sample per pixel", samplesPerPixel: 1, referencePath: oneSampleReferencePath },
  { name: "fourSamplesWithoutText", description: "with four samples per pixel, without text", samplesPerPixel: 4, referencePath: fourSampleReferencePath },
];
// A step that succeeds has its output dropped by `zig build`, and one that
// fails shows only its stderr.
const failedFrameLines = [];
let failedImages = null;
let framesCompared = 0;
for (const drawing of drawings) {
  const { rendererName, frames } = readReference(await readFile(drawing.referencePath));
  const tolerance = toleranceOfRenderer(rendererName);
  for (const expected of frames) {
    const frame = `frame ${expected.number} ${drawing.description}`;
    const drawn = await evaluate(`drawFrame("${drawing.name}", ${expected.number})`).catch((error) => fail(`${frame}: ${error.message}`));
    if (drawn.width !== expected.width || drawn.height !== expected.height) {
      await fail(`${frame}: drawn ${drawn.width}×${drawn.height}, the reference is ${expected.width}×${expected.height}`);
    }
    if (drawn.overflows !== 0) await fail(`${frame}: the draw list was full ${drawn.overflows} times`);
    if (drawn.glyphOverflows !== 0) await fail(`${frame}: glyphs were left out ${drawn.glyphOverflows} times`);
    const pixels = Buffer.from(drawn.pixels, "base64");
    const result = compare(pixels, expected.pixels, expected.width, expected.height, drawing.samplesPerPixel, tolerance);
    const total = expected.width * expected.height;
    const line = `check_draw: ${frame}: ${result.differing} of ${total} pixels differ, by at most ${result.largestDifference}; ${result.beyondTolerance} by more than ${tolerance}, as ${rendererName} drew it, ${result.unmatched} of them matching no pixel of the other image within ${edgeReach} (at most ${maxUnmatchedPixelsPerFrame[drawing.samplesPerPixel]} allowed)`;
    console.log(line);
    framesCompared += 1;
    if (result.unmatched > maxUnmatchedPixelsPerFrame[drawing.samplesPerPixel]) {
      failedFrameLines.push(line);
      failedImages ??= await directoryForFailedImages();
      const imageName = `${expected.number}-${drawing.samplesPerPixel}-samples`;
      await writePortablePixmap(join(failedImages, `${imageName}-drawn.ppm`), pixels, expected.width, expected.height);
      await writePortablePixmap(join(failedImages, `${imageName}-reference.ppm`), expected.pixels, expected.width, expected.height);
    }
  }
}

clearTimeout(watchdog);
await cleanUp();
if (failedFrameLines.length > 0) {
  for (const line of failedFrameLines) console.error(line);
  console.error(`check_draw: ${failedFrameLines.length} of ${framesCompared} frames do not match zui-sokol's; each frame drawn and its reference are in ${failedImages}`);
  process.exit(1);
}
console.log(`check_draw: ${framesCompared} frames drawn in Chromium match zui-sokol's renderer`);
