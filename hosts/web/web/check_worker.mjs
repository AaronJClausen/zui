// node check_worker.mjs <client wasm> <tour worker wasm> <tour-frames>
//
// Runs zui-sokol's tour in a worker, as the page will: on each tick, the
// page's clock and the records the client wrote of the mouse crossing each
// of the tour's thirteen screens, with Ctrl+PageDown between them. Then
// `tour-frames` runs the tour natively on the same ticks, and the worker's
// frames must be its bytes, the tour's tasks must have run alike, and the
// client must decode every frame. Exits with 1 on the first difference.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Inbox, startWorker } from "./worker_port.mjs";

const watchdogMilliseconds = 300_000;
const screens = 13;
const framesPerScreen = 24;
const canvas = [1440, 900];
const mouse = { id: 1, kind: 0 };
const control = 2;

const [clientPath, tourPath, tourFramesPath] = process.argv.slice(2);
let worker = null;
let workDirectory = null;

async function fail(message) {
  console.error(`check_worker: ${message}`);
  await worker?.terminate();
  if (workDirectory) await rm(workDirectory, { recursive: true, force: true });
  process.exit(1);
}

const watchdog = setTimeout(() => fail(`not done after ${watchdogMilliseconds / 1000} s`), watchdogMilliseconds);

const { instance } = await WebAssembly.instantiate(await readFile(clientPath), {});
const client = instance.exports;
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

function clientError() {
  const memory = new Uint8Array(client.memory.buffer);
  const start = client.zuiWebErrorName() >>> 0;
  return textDecoder.decode(memory.subarray(start, memory.indexOf(0, start)));
}

if (!client.zuiWebInit()) await fail(`the client could not reserve its memory: ${clientError()}`);

function key(down, name, now) {
  const names = client.zuiWebKeyNames() >>> 0;
  const most = client.zuiWebKeyNameBytesMost() >>> 0;
  const memory = new Uint8Array(client.memory.buffer);
  const written = textEncoder.encodeInto(name, memory.subarray(names, names + most)).written;
  textEncoder.encodeInto(name, memory.subarray(names + most, names + 2 * most));
  client.zuiWebKey(down, written, written, down || name !== "Control" ? control : 0, false, now);
}

function takeRecord(now) {
  client.zuiWebMeasure(canvas[0], canvas[1], 1);
  const count = client.zuiWebTakeRecord(now);
  if (count < 0) throw new Error(`a record was too large to send: ${clientError()}`);
  return new Uint8Array(client.memory.buffer, client.zuiWebRecordBytes() >>> 0, count).slice();
}

// Decodes `bytes`, the next of the worker's stream, and returns how many
// frames they completed.
function decodeInClient(bytes) {
  const room = client.zuiWebRoomFor(bytes.length) >>> 0;
  if (room === 0) throw new Error(`the client had no room for ${bytes.length} bytes: ${clientError()}`);
  new Uint8Array(client.memory.buffer, room, bytes.length).set(bytes);
  client.zuiWebReceived(bytes.length);
  let decoded = 0;
  for (let status = client.zuiWebNextFrame(); status !== 0; status = client.zuiWebNextFrame()) {
    if (status < 0) throw new Error(`the client could not decode a frame: ${clientError()}`);
    decoded += 1;
  }
  return decoded;
}

worker = await startWorker(new URL("./tour_worker.mjs", import.meta.url));
const inbox = new Inbox(worker);
const ticks = [];
const frames = [];
let decodedFrames = 0;
let tasks = null;
const startedAt = performance.now();
try {
  worker.post({ type: "start", wasm: await readFile(tourPath) });
  await inbox.expect("ready");
  for (let tick = 1; tick <= screens * framesPerScreen; tick += 1) {
    const now = (tick * 1000) / 60;
    const step = (tick - 1) % framesPerScreen;
    if (step === 0 && tick > 1) {
      key(true, "Control", now);
      key(true, "PageDown", now);
      key(false, "PageDown", now);
      key(false, "Control", now);
    }
    const across = step / framesPerScreen;
    client.zuiWebPointerMove(mouse.id, mouse.kind, across * canvas[0], across * canvas[1], 0, 0, 0, now);
    const records = takeRecord(now);
    ticks.push({ now, records });
    worker.post({ type: "frame", now, records });
    const answer = await inbox.expect("frame");
    frames.push(answer.bytes);
    tasks = answer.tasks;
    decodedFrames += decodeInClient(answer.bytes);
  }
} catch (error) {
  await fail(error.message);
}
const workerMilliseconds = performance.now() - startedAt;
await worker.terminate();
worker = null;

const expectedFrames = screens * framesPerScreen;
if (decodedFrames !== expectedFrames) await fail(`the client decoded ${decodedFrames} frames of the ${expectedFrames} the worker drew`);
if (tasks.finished === 0) await fail(`the tour started ${tasks.started} tasks in the worker and finished none`);

workDirectory = await mkdtemp(join(tmpdir(), "zui-web-worker-"));
const ticksPath = join(workDirectory, "tour.ticks");
const nativePath = join(workDirectory, "tour.zuiw");
const tickBytes = Buffer.concat(
  ticks.flatMap(({ now, records }) => {
    const head = Buffer.alloc(12);
    head.writeDoubleLE(now, 0);
    head.writeUInt32LE(records.length, 8);
    return [head, Buffer.from(records)];
  }),
);
await writeFile(ticksPath, tickBytes);

const native = spawn(tourFramesPath, [ticksPath, nativePath], { stdio: ["ignore", "inherit", "pipe"] });
let nativeOutput = "";
native.stderr.on("data", (chunk) => (nativeOutput += chunk));
const nativeExit = await new Promise((resolve) => native.on("exit", resolve));
if (nativeExit !== 0) await fail(`tour-frames failed:\n${nativeOutput}`);
const [nativeStarted, nativeFinished, nativeRefused] = nativeOutput.trim().split(/\s+/).map(Number);
const nativeStream = await readFile(nativePath);

let offset = 0;
for (const [index, bytes] of frames.entries()) {
  const nativeBytes = nativeStream.subarray(offset, offset + bytes.length);
  if (Buffer.compare(nativeBytes, Buffer.from(bytes)) !== 0) await fail(`frame ${index + 1} differs from the one the tour drew natively on the same tick`);
  offset += bytes.length;
}
if (offset !== nativeStream.length) await fail(`the tour wrote ${nativeStream.length} bytes natively, the worker ${offset}`);
const nativeTasks = { started: nativeStarted, finished: nativeFinished, refused: nativeRefused };
if (JSON.stringify(nativeTasks) !== JSON.stringify(tasks)) await fail(`the worker's tasks ${JSON.stringify(tasks)} are not the native tour's ${JSON.stringify(nativeTasks)}`);

clearTimeout(watchdog);
await rm(workDirectory, { recursive: true, force: true });
console.log(
  `check_worker: ${expectedFrames} frames, ${offset} bytes, drawn in a worker in ${(workerMilliseconds / 1000).toFixed(1)} s as natively, ` +
    `${tasks.started} tasks started, ${tasks.finished} finished, ${tasks.refused} refused`,
);
