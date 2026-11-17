const vertexBytes = 12;
const batchBytes = 24;

const vertexShaderSource = `#version 300 es
in vec2 position;
in vec4 color;
uniform vec2 viewport;
out vec4 drawnColor;
void main() {
  gl_Position = vec4(2.0 * position.x / viewport.x - 1.0, 1.0 - 2.0 * position.y / viewport.y, 0.0, 1.0);
  drawnColor = color;
}`;

const fragmentShaderSource = `#version 300 es
precision highp float;
in vec4 drawnColor;
out vec4 fragmentColor;
void main() {
  fragmentColor = drawnColor;
}`;

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
  return shader;
}

/**
 * Draws the client's newest frame on a canvas through WebGL 2: the
 * triangles `zuiWebLayOutNewestFrame` lays out, one draw call per batch,
 * each under its scissor rectangle.
 */
export class FrameDrawer {
  /**
   * @param {HTMLCanvasElement} canvas sized to each frame as it is drawn
   * @param {WebAssembly.Exports} wasm the client's exports, after `zuiWebInit`
   */
  constructor(canvas, wasm) {
    // Edges are not smoothed and nothing is composed with the page's
    // background, as a native target with one sample per pixel draws.
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error("this browser has no WebGL 2");
    this.canvas = canvas;
    this.gl = gl;
    this.wasm = wasm;

    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertexShaderSource));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentShaderSource));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    this.viewportUniform = gl.getUniformLocation(program, "viewport");

    gl.bindVertexArray(gl.createVertexArray());
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    const position = gl.getAttribLocation(program, "position");
    const color = gl.getAttribLocation(program, "color");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, vertexBytes, 0);
    gl.enableVertexAttribArray(color);
    gl.vertexAttribPointer(color, 4, gl.UNSIGNED_BYTE, true, vertexBytes, 8);

    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  }

  /** Draws the newest frame the client decoded, cleared to black. */
  draw() {
    const { gl, wasm } = this;
    const batchCount = wasm.zuiWebLayOutNewestFrame();
    const viewport = [wasm.zuiWebViewportWidth(), wasm.zuiWebViewportHeight()];
    const pixelsPerUnit = wasm.zuiWebPixelsPerUnit();
    const width = Math.round(viewport[0] * pixelsPerUnit);
    const height = Math.round(viewport[1] * pixelsPerUnit);
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }

    gl.viewport(0, 0, width, height);
    gl.disable(gl.SCISSOR_TEST);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (batchCount === 0) return;

    const memory = wasm.memory.buffer;
    gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(memory, wasm.zuiWebVertices() >>> 0, wasm.zuiWebVertexCount() * vertexBytes), gl.STREAM_DRAW);
    gl.uniform2f(this.viewportUniform, viewport[0], viewport[1]);
    gl.enable(gl.SCISSOR_TEST);
    const batches = new Int32Array(memory, wasm.zuiWebBatches() >>> 0, batchCount * batchBytes / 4);
    for (let at = 0; at < batches.length; at += batchBytes / 4) {
      const vertexCount = batches[at + 1];
      if (vertexCount === 0) continue;
      gl.scissor(batches[at + 2], batches[at + 3], batches[at + 4], batches[at + 5]);
      gl.drawArrays(gl.TRIANGLES, batches[at], vertexCount);
    }
  }
}
