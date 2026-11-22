// Turns a canvas's pointer, wheel, key and text events into calls on a
// sink: by default the client's exports, which write records of them with
// the canvas's size and `devicePixelRatio`, and whose newest frame's host
// requests are applied to the canvas.
//
//   const recorder = new InputRecorder(canvas, wasm, () => wake());
//   const record = recorder.takeRecord(); // once a frame
//   if (record) socket.send(record);
//   recorder.applyHostRequests(); // after a frame is decoded
//
// With another sink, such as `messageSink`, the events go where it sends
// them, and the client's calls are not made:
//
//   const sink = messageSink((events) => worker.postMessage({ type: "events", events }));
//   new InputRecorder(canvas, null, () => sink.flush(), { sink });

const pointerKinds = { mouse: 0, touch: 1, pen: 2 };
const modifierBits = { shiftKey: 1, ctrlKey: 2, altKey: 4, metaKey: 8 };
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

// What a sink takes, each with the arguments the client's export of the
// same name takes but for text, which is a string; the time is last.
//
//   pointerDown(pointerId, kind, button, x, y, pressure, tiltX, tiltY, timeStamp)
//   pointerUp(pointerId, kind, button, x, y, pressure, tiltX, tiltY, timeStamp)
//   pointerMove(pointerId, kind, x, y, pressure, tiltX, tiltY, timeStamp)
//   pointerCancel(pointerId, kind)
//   pointerLeave(pointerId, kind)
//   wheel(x, y, deltaX, deltaY, deltaMode, timeStamp)
//   key(down, key, code, modifierBits, repeat, timeStamp)
//   typed(text)
export const sinkCalls = ["pointerDown", "pointerUp", "pointerMove", "pointerCancel", "pointerLeave", "wheel", "key", "typed"];
// The calls whose last argument is an `Event.timeStamp`.
export const timedSinkCalls = ["pointerDown", "pointerUp", "pointerMove", "wheel", "key"];

// A sink calling a module's `zuiWeb*` input exports, encoding text into
// `memoryOf()`'s buffer, where the module reads it. Text is encoded apart
// and copied in, since `encodeInto` refuses shared memory.
export function exportsSink(wasm, memoryOf = () => wasm.memory) {
  const encodeInto = (text, at, most) => {
    const encoded = new Uint8Array(most);
    const { written } = textEncoder.encodeInto(text, encoded);
    new Uint8Array(memoryOf().buffer, at, most).set(encoded.subarray(0, written));
    return written;
  };
  return {
    pointerDown: (...call) => wasm.zuiWebPointerDown(...call),
    pointerUp: (...call) => wasm.zuiWebPointerUp(...call),
    pointerMove: (...call) => wasm.zuiWebPointerMove(...call),
    pointerCancel: (...call) => wasm.zuiWebPointerCancel(...call),
    pointerLeave: (...call) => wasm.zuiWebPointerLeave(...call),
    wheel: (...call) => wasm.zuiWebWheel(...call),
    key(down, key, code, modifiers, repeat, timeStamp) {
      const names = wasm.zuiWebKeyNames() >>> 0;
      const most = wasm.zuiWebKeyNameBytesMost() >>> 0;
      wasm.zuiWebKey(down, encodeInto(key, names, most), encodeInto(code, names + most, most), modifiers, repeat, timeStamp);
    },
    typed(text) {
      wasm.zuiWebTyped(encodeInto(text, wasm.zuiWebTypedText() >>> 0, wasm.zuiWebTypedTextBytesMost() >>> 0));
    },
  };
}

// A sink that keeps its calls, as `[name, ...arguments]`, until `flush`
// hands any it kept to `send` as one list, in order.
export function messageSink(send) {
  let kept = [];
  const sink = Object.fromEntries(sinkCalls.map((name) => [name, (...call) => kept.push([name, ...call])]));
  sink.flush = () => {
    if (kept.length === 0) return;
    const events = kept;
    kept = [];
    send(events);
  };
  return sink;
}

function modifiersOf(event) {
  let bits = 0;
  for (const [held, bit] of Object.entries(modifierBits)) if (event[held]) bits |= bit;
  return bits;
}

// A key that types a character, rather than naming a key or a dead key,
// and that no shortcut modifier turns into a command.
function typedCharacter(event) {
  if (event.ctrlKey || event.metaKey || event.isComposing) return null;
  return [...event.key].length === 1 ? event.key : null;
}

export class InputRecorder {
  constructor(canvas, wasm, onEventHeard = () => {}, { sink = exportsSink(wasm) } = {}) {
    this.canvas = canvas;
    this.wasm = wasm;
    this.sink = sink;
    this.onEventHeard = onEventHeard;
    this.listeners = [];
    if (canvas.tabIndex < 0) canvas.tabIndex = 0;
    canvas.style.touchAction = "none";
    this.listen("pointerdown", (event) => this.pointerButton(event, true));
    this.listen("pointerup", (event) => this.pointerButton(event, false));
    this.listen("pointermove", (event) => this.pointerMoved(event));
    this.listen("pointercancel", (event) => this.sink.pointerCancel(event.pointerId, this.kindOf(event)));
    this.listen("pointerleave", (event) => {
      if (event.pointerType !== "touch") this.sink.pointerLeave(event.pointerId, this.kindOf(event));
    });
    this.listen("wheel", (event) => {
      event.preventDefault();
      const [x, y] = this.positionOf(event);
      this.sink.wheel(x, y, event.deltaX, event.deltaY, event.deltaMode, event.timeStamp);
    });
    this.listen("keydown", (event) => {
      event.preventDefault();
      this.key(event, true);
      const character = typedCharacter(event);
      if (character !== null) this.sink.typed(character);
    });
    this.listen("keyup", (event) => {
      event.preventDefault();
      this.key(event, false);
    });
    this.listen("contextmenu", (event) => event.preventDefault());
  }

  listen(type, handle) {
    const handleAndTell = (event) => {
      handle(event);
      this.onEventHeard();
    };
    this.canvas.addEventListener(type, handleAndTell, { passive: false });
    this.listeners.push([type, handleAndTell]);
  }

  detach() {
    for (const [type, handle] of this.listeners) this.canvas.removeEventListener(type, handle);
    this.listeners = [];
  }

  // The bytes to send since the last record, or null when nothing changed
  // the application has to hear of: the stream's header comes first. They
  // are copied, since the client writes the next record in their place.
  takeRecord(now = performance.now()) {
    const bounds = this.canvas.getBoundingClientRect();
    this.wasm.zuiWebMeasure(bounds.width, bounds.height, globalThis.devicePixelRatio ?? 1);
    const count = this.wasm.zuiWebTakeRecord(now);
    if (count < 0) throw new Error(`a record was too large to send: ${this.errorName()}`);
    if (count === 0) return null;
    return new Uint8Array(this.wasm.memory.buffer, this.wasm.zuiWebRecordBytes() >>> 0, count).slice();
  }

  applyHostRequests() {
    const cursor = this.cString(this.wasm.zuiWebCursorName());
    if (this.canvas.style.cursor !== cursor) this.canvas.style.cursor = cursor;
  }

  pointerButton(event, down) {
    if (down) {
      this.canvas.focus({ preventScroll: true });
      this.canvas.setPointerCapture(event.pointerId);
    }
    const report = down ? this.sink.pointerDown : this.sink.pointerUp;
    const [x, y] = this.positionOf(event);
    report(event.pointerId, this.kindOf(event), event.button, x, y, event.pressure, event.tiltX, event.tiltY, event.timeStamp);
  }

  // A press of a second mouse button while one is held arrives as a move
  // whose `button` names it.
  pointerMoved(event) {
    if (event.button >= 0) {
      const pressed = (event.buttons & buttonsBit(event.button)) !== 0;
      this.pointerButton(event, pressed);
      return;
    }
    const coalesced = event.getCoalescedEvents?.() ?? [];
    for (const moved of coalesced.length > 0 ? coalesced : [event]) {
      const [x, y] = this.positionOf(moved);
      this.sink.pointerMove(moved.pointerId, this.kindOf(moved), x, y, moved.pressure, moved.tiltX, moved.tiltY, moved.timeStamp);
    }
  }

  key(event, down) {
    this.sink.key(down, event.key, event.code, modifiersOf(event), event.repeat, event.timeStamp);
  }

  kindOf(event) {
    return pointerKinds[event.pointerType] ?? pointerKinds.mouse;
  }

  positionOf(event) {
    const bounds = this.canvas.getBoundingClientRect();
    return [event.clientX - bounds.left, event.clientY - bounds.top];
  }

  cString(start) {
    const memory = new Uint8Array(this.wasm.memory.buffer);
    const at = start >>> 0;
    return textDecoder.decode(memory.subarray(at, memory.indexOf(0, at)));
  }

  errorName() {
    return this.cString(this.wasm.zuiWebErrorName());
  }
}

// `MouseEvent.buttons` holds the secondary button in bit 1 and the middle
// in bit 2, the other way round from `MouseEvent.button`.
function buttonsBit(button) {
  return [1, 4, 2, 8, 16][button] ?? 0;
}
