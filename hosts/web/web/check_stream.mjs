// node check_stream.mjs <client wasm> <stream> <expected> <TrueType font>...
//
// Feeds a wire stream to the browser's client, handed the fonts the stream
// was measured with, in pieces of varying size, as a socket would deliver
// it, and checks that every frame decodes to what the application drew,
// and that a client handed other fonts refuses the stream. Exits with 1 on
// the first difference.

import { readFile } from "node:fs/promises";

const expectedRecordBytes = 8 + 4 + 8;

const [wasmPath, streamPath, expectedPath, ...fontPaths] = process.argv.slice(2);
const wasmBytes = await readFile(wasmPath);
const fonts = await Promise.all(fontPaths.map((path) => readFile(path)));
const wasm = (await WebAssembly.instantiate(wasmBytes, {})).instance.exports;
const stream = await readFile(streamPath);
const expected = await readFile(expectedPath);
const expectedView = new DataView(expected.buffer, expected.byteOffset, expected.byteLength);
const expectedFrameCount = expected.length / expectedRecordBytes;

function fail(message) {
  console.error(`check_stream: ${message}`);
  process.exit(1);
}

function errorName(client = wasm) {
  const memory = new Uint8Array(client.memory.buffer);
  const start = client.zuiWebErrorName();
  const end = memory.indexOf(0, start);
  return new TextDecoder().decode(memory.subarray(start, end));
}

function handOver(client, handed) {
  for (const font of handed) {
    const room = client.zuiWebRoomForFont(font.length) >>> 0;
    if (room === 0) fail(`no room for a font of ${font.length} bytes`);
    new Uint8Array(client.memory.buffer, room, font.length).set(font);
    if (client.zuiWebAddTrueTypeFont(font.length) < 0) fail(`a font was refused: ${errorName(client)}`);
  }
}

if (fonts.length > 1) {
  const other = (await WebAssembly.instantiate(wasmBytes, {})).instance.exports;
  if (!other.zuiWebInit()) fail(`the client could not reserve its memory: ${errorName(other)}`);
  handOver(other, [...fonts].reverse());
  const header = stream.subarray(0, 64);
  new Uint8Array(other.memory.buffer, other.zuiWebRoomFor(header.length) >>> 0, header.length).set(header);
  other.zuiWebReceived(header.length);
  if (other.zuiWebNextFrame() >= 0 || errorName(other) !== "FontsDiffer") fail(`a client handed the fonts in another order did not refuse the stream: ${errorName(other)}`);
}

if (!wasm.zuiWebInit()) fail(`the client could not reserve its memory: ${errorName()}`);
if (!wasm.zuiWebCheckInit()) fail("the check could not reserve its memory");
handOver(wasm, fonts);

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
console.log(`check_stream: ${checked} frames, ${stream.length} bytes in ${pieces} pieces, each decoded to what was drawn with the same fonts; other fonts refused`);
