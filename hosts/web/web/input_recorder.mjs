// Turns a canvas's pointer, wheel, key and text events, its size and
// `devicePixelRatio` into the records the client writes for the
// application, and applies the newest frame's host requests to the canvas.
//
//   const recorder = new InputRecorder(canvas, wasm, () => wake());
//   const record = recorder.takeRecord(); // once a frame
//   if (record) socket.send(record);
//   recorder.applyHostRequests(); // after a frame is decoded

const pointerKinds = { mouse: 0, touch: 1, pen: 2 };
const modifierBits = { shiftKey: 1, ctrlKey: 2, altKey: 4, metaKey: 8 };
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

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
  constructor(canvas, wasm, onEventHeard = () => {}) {
    this.canvas = canvas;
    this.wasm = wasm;
    this.onEventHeard = onEventHeard;
    this.listeners = [];
    if (canvas.tabIndex < 0) canvas.tabIndex = 0;
    canvas.style.touchAction = "none";
    this.listen("pointerdown", (event) => this.pointerButton(event, true));
    this.listen("pointerup", (event) => this.pointerButton(event, false));
    this.listen("pointermove", (event) => this.pointerMoved(event));
    this.listen("pointercancel", (event) => this.wasm.zuiWebPointerCancel(event.pointerId, this.kindOf(event)));
    this.listen("pointerleave", (event) => {
      if (event.pointerType !== "touch") this.wasm.zuiWebPointerLeave(event.pointerId, this.kindOf(event));
    });
    this.listen("wheel", (event) => {
      event.preventDefault();
      const [x, y] = this.positionOf(event);
      this.wasm.zuiWebWheel(x, y, event.deltaX, event.deltaY, event.deltaMode, event.timeStamp);
    });
    this.listen("keydown", (event) => {
      event.preventDefault();
      this.key(event, true);
      const character = typedCharacter(event);
      if (character !== null) this.typed(character);
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
    const report = down ? this.wasm.zuiWebPointerDown : this.wasm.zuiWebPointerUp;
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
      this.wasm.zuiWebPointerMove(moved.pointerId, this.kindOf(moved), x, y, moved.pressure, moved.tiltX, moved.tiltY, moved.timeStamp);
    }
  }

  key(event, down) {
    const names = this.wasm.zuiWebKeyNames() >>> 0;
    const most = this.wasm.zuiWebKeyNameBytesMost() >>> 0;
    const memory = new Uint8Array(this.wasm.memory.buffer);
    const key = textEncoder.encodeInto(event.key, memory.subarray(names, names + most));
    const code = textEncoder.encodeInto(event.code, memory.subarray(names + most, names + 2 * most));
    this.wasm.zuiWebKey(down, key.written, code.written, modifiersOf(event), event.repeat, event.timeStamp);
  }

  typed(text) {
    const room = this.wasm.zuiWebTypedText() >>> 0;
    const most = this.wasm.zuiWebTypedTextBytesMost() >>> 0;
    const { written } = textEncoder.encodeInto(text, new Uint8Array(this.wasm.memory.buffer, room, most));
    this.wasm.zuiWebTyped(written);
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
