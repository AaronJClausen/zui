// node check_stream.mjs <client wasm> <stream> <expected>
//
// Feeds a wire stream to the browser's client in pieces of varying size,
// as a socket would deliver it, and checks that every frame decodes to
// what the application drew. Exits with 1 on the first difference.

import { readFile } from "node:fs/promises";

const expectedRecordBytes = 8 + 4 + 8;

const [wasmPath, streamPath, expectedPath] = process.argv.slice(2);
const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const wasm = instance.exports;
const stream = await readFile(streamPath);
const expected = await readFile(expectedPath);
const expectedView = new DataView(expected.buffer, expected.byteOffset, expected.byteLength);
const expectedFrameCount = expected.length / expectedRecordBytes;

function fail(message) {
  console.error(`check_stream: ${message}`);
  process.exit(1);
}

function errorName() {
  const memory = new Uint8Array(wasm.memory.buffer);
  const start = wasm.zuiWebErrorName();
  const end = memory.indexOf(0, start);
  return new TextDecoder().decode(memory.subarray(start, end));
}

if (!wasm.zuiWebInit()) fail(`the client could not reserve its memory: ${errorName()}`);
if (!wasm.zuiWebCheckInit()) fail("the check could not reserve its memory");

let seed = 0x2545f491;
function pieceSize() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  seed >>>= 0;
  const smallPieces = seed % 4 === 0;
  return 1 + (seed >>> 2) % (smallPieces ? 16 : 16384);
}

let checked = 0;
let pieces = 0;
for (let offset = 0; offset < stream.length; pieces += 1) {
  const piece = stream.subarray(offset, offset + pieceSize());
  offset += piece.length;
  const room = wasm.zuiWebRoomFor(piece.length) >>> 0;
  if (room === 0) fail(`no room for ${piece.length} bytes: ${errorName()}`);
  new Uint8Array(wasm.memory.buffer, room, piece.length).set(piece);
  wasm.zuiWebReceived(piece.length);

  for (let status = wasm.zuiWebNextFrame(); status !== 0; status = wasm.zuiWebNextFrame()) {
    if (status < 0) fail(`frame ${checked}: ${errorName()}`);
    if (checked === expectedFrameCount) fail(`more frames than the ${expectedFrameCount} drawn`);
    const at = checked * expectedRecordBytes;
    const number = expectedView.getBigUint64(at, true);
    const commandCount = expectedView.getUint32(at + 8, true);
    const digest = expectedView.getBigUint64(at + 12, true);
    const decodedNumber = BigInt.asUintN(64, wasm.zuiWebFrameNumber());
    if (decodedNumber !== number) fail(`frame ${checked}: number ${decodedNumber}, drawn ${number}`);
    if (wasm.zuiWebCommandCount() >>> 0 !== commandCount) fail(`frame ${number}: ${wasm.zuiWebCommandCount()} commands, drawn ${commandCount}`);
    const decodedDigest = BigInt.asUintN(64, wasm.zuiWebNewestFrameDigest());
    if (decodedDigest !== digest) fail(`frame ${number}: decoded to other values than were drawn`);
    checked += 1;
  }
}
if (checked !== expectedFrameCount) fail(`${checked} frames decoded of the ${expectedFrameCount} drawn`);
console.log(`check_stream: ${checked} frames, ${stream.length} bytes in ${pieces} pieces, each decoded to what was drawn`);
