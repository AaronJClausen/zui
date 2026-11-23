// A text field the page places, unseen, over the caret of the element that
// takes text, so the browser's IME composes there, as it would in a field of
// the page's own. While the field has the focus, the canvas hears no keys:
// the field sends each key to the sink as the canvas would, but a key's text
// comes only from what the field took (`input`, or `compositionend` for an
// IME's), so a printable key's text reaches the sink once.
//
//   const field = new HiddenTextField(canvas, sink, () => sink.flush());
//   field.place([x, y, width, height]); // the caret, in CSS pixels from the canvas's top-left
//   field.place(null); // the canvas takes the focus back

import { modifiersOf } from "./input_recorder.mjs";

// The keys the field must not act on itself: what would move the focus away,
// break a line, or reach the browser's own shortcuts.
function keepsFromField(event) {
  if (event.key === "Tab" || event.key === "Enter" || event.key === "Escape") return true;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() !== "v") return true;
  return false;
}

export class HiddenTextField {
  constructor(canvas, sink, onEventHeard = () => {}) {
    this.canvas = canvas;
    this.sink = sink;
    this.onEventHeard = onEventHeard;
    this.caret = null;
    this.field = document.createElement("textarea");
    this.field.setAttribute("aria-hidden", "true");
    this.field.autocomplete = "off";
    this.field.spellcheck = false;
    Object.assign(this.field.style, {
      position: "fixed",
      left: "-10000px",
      top: "0",
      opacity: "0",
      pointerEvents: "none",
      resize: "none",
      border: "0",
      padding: "0",
      margin: "0",
      overflow: "hidden",
      caretColor: "transparent",
      background: "transparent",
      color: "transparent",
    });
    document.body.append(this.field);
    this.listeners = [];
    this.listen(this.field, "keydown", (event) => this.key(event, true));
    this.listen(this.field, "keyup", (event) => this.key(event, false));
    this.listen(this.field, "input", (event) => this.input(event));
    this.listen(this.field, "compositionend", (event) => this.compositionEnded(event));
    // A press on the canvas takes the focus, which the field takes back while
    // a caret is still placed.
    this.listen(canvas, "pointerup", () => this.focusWhilePlaced());
  }

  listen(target, type, handle) {
    const handleAndTell = (event) => {
      handle(event);
      this.onEventHeard();
    };
    target.addEventListener(type, handleAndTell);
    this.listeners.push([target, type, handleAndTell]);
  }

  detach() {
    for (const [target, type, handle] of this.listeners) target.removeEventListener(type, handle);
    this.listeners = [];
    this.field.remove();
  }

  // `caret` is `[x, y, width, height]` in CSS pixels from the canvas's
  // top-left, or null.
  place(caret) {
    this.caret = caret;
    if (caret === null) {
      this.field.style.left = "-10000px";
      if (document.activeElement === this.field) this.canvas.focus({ preventScroll: true });
      return;
    }
    const bounds = this.canvas.getBoundingClientRect();
    const [x, y, width, height] = caret;
    Object.assign(this.field.style, {
      left: `${bounds.left + x}px`,
      top: `${bounds.top + y}px`,
      width: `${Math.max(1, width)}px`,
      height: `${Math.max(1, height)}px`,
      fontSize: `${Math.max(1, height)}px`,
    });
    this.focusWhilePlaced();
  }

  focusWhilePlaced() {
    if (this.caret !== null && document.activeElement !== this.field) this.field.focus({ preventScroll: true });
  }

  key(event, down) {
    if (event.isComposing || event.keyCode === 229) return;
    if (keepsFromField(event)) event.preventDefault();
    this.sink.key(down, event.key, event.code, modifiersOf(event), event.repeat, event.timeStamp);
  }

  // A composition's text arrives whole at its end, so its steps are left out.
  input(event) {
    if (event.isComposing || event.inputType === "insertCompositionText") return;
    if (["insertText", "insertFromPaste", "insertFromDrop", "insertReplacementText"].includes(event.inputType)) {
      const text = event.data ?? this.field.value;
      if (text) this.sink.typed(text);
    }
    this.field.value = "";
  }

  compositionEnded(event) {
    if (event.data) this.sink.typed(event.data);
    this.field.value = "";
  }
}
