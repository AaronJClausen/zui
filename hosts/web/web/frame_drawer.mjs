const vertexBytes = 56;
const batchBytes = 24;
const glyphAtlasSide = 1024;
const bitmapGlyphTextureSize = [2048, 48];

const vertexShaderSource = `#version 300 es
in vec2 position;
in vec4 color;
in uint textureKind;
in vec2 textureCoordinates;
in vec4 texturePerUnit;
in vec4 textureBounds;
uniform vec2 viewport;
out vec4 drawnColor;
flat out uint drawnTextureKind;
out vec2 interpolatedTextureCoordinates;
flat out vec2 textureAtOrigin;
flat out vec4 drawnTexturePerUnit;
flat out vec4 drawnTextureBounds;
void main() {
  gl_Position = vec4(2.0 * position.x / viewport.x - 1.0, 1.0 - 2.0 * position.y / viewport.y, 0.0, 1.0);
  drawnColor = color;
  drawnTextureKind = textureKind;
  interpolatedTextureCoordinates = textureCoordinates;
  textureAtOrigin = textureCoordinates;
  drawnTexturePerUnit = texturePerUnit;
  drawnTextureBounds = textureBounds;
}`;

// The atlas holds 1 inside a glyph and 0 between glyphs, then coverage,
// so a texel sampled at a glyph's edge darkens as zui-sokol's white RGBA
// texels do beside its clear ones.
const fragmentShaderSource = `#version 300 es
precision highp float;
uniform highp sampler2D glyphAtlas;
uniform highp sampler2D bitmapGlyphs;
uniform float pixelsPerUnit;
uniform float targetHeight;
in vec4 drawnColor;
flat in uint drawnTextureKind;
in vec2 interpolatedTextureCoordinates;
flat in vec2 textureAtOrigin;
flat in vec4 drawnTexturePerUnit;
flat in vec4 drawnTextureBounds;
out vec4 fragmentColor;
void main() {
  vec4 texel = vec4(1.0);
  if (drawnTextureKind == 1u) {
    vec2 windowPosition = vec2(gl_FragCoord.x, targetHeight - gl_FragCoord.y) / pixelsPerUnit;
    vec2 coordinates = textureAtOrigin + drawnTexturePerUnit.xy * windowPosition.x + drawnTexturePerUnit.zw * windowPosition.y;
    bool inGlyph = all(greaterThanEqual(coordinates, drawnTextureBounds.xy)) && all(lessThan(coordinates, drawnTextureBounds.zw));
    vec2 glyph = texture(glyphAtlas, coordinates).rg;
    texel = inGlyph ? vec4(glyph.rrr, glyph.g) : vec4(0.0);
  } else if (drawnTextureKind == 2u) {
    texel = vec4(1.0, 1.0, 1.0, texture(bitmapGlyphs, interpolatedTextureCoordinates).r);
  }
  fragmentColor = texel * drawnColor;
}`;

function makeTexture(gl, unit, filter) {
  const texture = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return texture;
}

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
 * each under its scissor rectangle, with the glyph atlas uploaded again
 * whenever the client added glyphs to it.
 */
export class FrameDrawer {
  /**
   * @param {HTMLCanvasElement} canvas sized to each frame as it is drawn
   * @param {WebAssembly.Exports} wasm the client's exports, after `zuiWebInit`
   *   and, if bitmap text is to be drawn, `zuiWebLoadBitmapFonts`
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
    this.pixelsPerUnitUniform = gl.getUniformLocation(program, "pixelsPerUnit");
    this.targetHeightUniform = gl.getUniformLocation(program, "targetHeight");

    gl.bindVertexArray(gl.createVertexArray());
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    const attribute = (name) => {
      const location = gl.getAttribLocation(program, name);
      gl.enableVertexAttribArray(location);
      return location;
    };
    gl.vertexAttribPointer(attribute("position"), 2, gl.FLOAT, false, vertexBytes, 0);
    gl.vertexAttribPointer(attribute("color"), 4, gl.UNSIGNED_BYTE, true, vertexBytes, 8);
    gl.vertexAttribIPointer(attribute("textureKind"), 1, gl.UNSIGNED_INT, vertexBytes, 12);
    gl.vertexAttribPointer(attribute("textureCoordinates"), 2, gl.FLOAT, false, vertexBytes, 16);
    gl.vertexAttribPointer(attribute("texturePerUnit"), 4, gl.FLOAT, false, vertexBytes, 24);
    gl.vertexAttribPointer(attribute("textureBounds"), 4, gl.FLOAT, false, vertexBytes, 40);

    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    this.glyphAtlas = makeTexture(gl, 0, gl.LINEAR);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RG8, glyphAtlasSide, glyphAtlasSide);
    gl.uniform1i(gl.getUniformLocation(program, "glyphAtlas"), 0);
    makeTexture(gl, 1, gl.NEAREST);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R8, bitmapGlyphTextureSize[0], bitmapGlyphTextureSize[1]);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, bitmapGlyphTextureSize[0], bitmapGlyphTextureSize[1], gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(wasm.memory.buffer, wasm.zuiWebBitmapGlyphTexels() >>> 0, bitmapGlyphTextureSize[0] * bitmapGlyphTextureSize[1]));
    gl.uniform1i(gl.getUniformLocation(program, "bitmapGlyphs"), 1);

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
    const changedGlyphAtlas = wasm.zuiWebGlyphAtlasTexelsIfChanged() >>> 0;
    if (changedGlyphAtlas !== 0) {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this.glyphAtlas);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, glyphAtlasSide, glyphAtlasSide, gl.RG, gl.UNSIGNED_BYTE, new Uint8Array(memory, changedGlyphAtlas, glyphAtlasSide * glyphAtlasSide * 2));
    }
    gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(memory, wasm.zuiWebVertices() >>> 0, wasm.zuiWebVertexCount() * vertexBytes), gl.STREAM_DRAW);
    gl.uniform2f(this.viewportUniform, viewport[0], viewport[1]);
    gl.uniform1f(this.pixelsPerUnitUniform, pixelsPerUnit);
    gl.uniform1f(this.targetHeightUniform, height);
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
