const vertexBytes = 56;
const batchBytes = 28;
const backdropBlurBytes = 28;
const blurTapBytes = 8;
const materialFloats = 16;
const noMaterial = 0xffffffff;
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
// texels do beside its clear ones. A material's pattern is zui-sokol's
// material shader's.
const fragmentShaderSource = `#version 300 es
precision highp float;
uniform highp sampler2D glyphAtlas;
uniform highp sampler2D bitmapGlyphs;
uniform highp sampler2D blurredBackdrop;
uniform float pixelsPerUnit;
uniform float targetHeight;
uniform vec4 materialFirstColor;
uniform vec4 materialSecondColor;
uniform vec4 materialSizeAndScale;
uniform vec4 materialPatternAndPhase;
in vec4 drawnColor;
flat in uint drawnTextureKind;
in vec2 interpolatedTextureCoordinates;
flat in vec2 textureAtOrigin;
flat in vec4 drawnTexturePerUnit;
flat in vec4 drawnTextureBounds;
out vec4 fragmentColor;

const float tau = 6.2831853;

float sheen(vec2 local, vec2 size, float phase) {
  float along = dot(local / max(size, vec2(1.0)), vec2(0.5));
  float fromBand = along - (fract(phase) * 1.6 - 0.3);
  return exp(-fromBand * fromBand * 60.0);
}

float aurora(vec2 local, float scale, float phase) {
  vec2 point = local / max(scale, 1.0);
  float turn = phase * tau;
  float curtain = sin(point.x * 1.7 + turn + 1.3 * sin(point.y * 0.8 - turn * 0.5));
  float ripple = sin(point.y * 2.3 - turn * 0.7 + sin(point.x * 0.9 + turn));
  return clamp(0.5 + 0.3 * curtain + 0.2 * ripple, 0.0, 1.0);
}

vec4 material(vec2 local) {
  float pattern = materialPatternAndPhase.x;
  float phase = materialPatternAndPhase.y;
  float amount = 0.0;
  if (pattern > 1.5) {
    amount = aurora(local, materialSizeAndScale.z, phase);
  } else if (pattern > 0.5) {
    amount = sheen(local, materialSizeAndScale.xy, phase);
  }
  return mix(materialFirstColor, materialSecondColor, amount);
}

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
  } else if (drawnTextureKind == 3u) {
    texel = vec4(texelFetch(blurredBackdrop, ivec2(gl_FragCoord.xy), 0).rgb, 1.0);
  } else if (drawnTextureKind == 4u) {
    texel = material(interpolatedTextureCoordinates);
  }
  fragmentColor = texel * drawnColor;
}`;

// One instance per tap, each a quad over the region adding its weighted
// sample, so the taps sum in the float target as zui-sokol's blending sums
// them. The sample is found per pixel, clamped to the region's edge pixels.
const blurVertexShaderSource = `#version 300 es
uniform vec4 region;
uniform vec2 targetSize;
in vec2 tap;
flat out vec2 drawnTap;
const vec2 corners[6] = vec2[6](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));
void main() {
  vec2 position = mix(region.xy, region.zw, corners[gl_VertexID]);
  gl_Position = vec4(2.0 * position / targetSize - 1.0, 0.0, 1.0);
  drawnTap = tap;
}`;

const blurFragmentShaderSource = `#version 300 es
precision highp float;
uniform highp sampler2D source;
uniform vec4 region;
uniform vec2 targetSize;
uniform vec2 sampleDirection;
flat in vec2 drawnTap;
out vec4 fragmentColor;
void main() {
  vec2 sampled = clamp(gl_FragCoord.xy + sampleDirection * drawnTap.x, region.xy + 0.5, region.zw - 0.5);
  fragmentColor = texture(source, sampled / targetSize) * drawnTap.y;
}`;

const glyphAtlasUnit = 0;
const bitmapGlyphsUnit = 1;
const blurredBackdropUnit = 2;
const blurSourceUnit = 3;

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

function link(gl, vertexSource, fragmentSource) {
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertexSource));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  return program;
}

function uniformsOf(gl, program, names) {
  return Object.fromEntries(names.map((name) => [name, gl.getUniformLocation(program, name)]));
}

/**
 * Where a frame's backdrop blurs run: a copy of what was drawn, and the
 * two RGBA16F targets that zui-sokol's renderer blurs into, along x and
 * then along y, sized to the canvas.
 */
class BlurTargets {
  constructor(gl, width, height) {
    this.gl = gl;
    this.width = width;
    this.height = height;
    this.scene = makeTexture(gl, blurSourceUnit, gl.LINEAR);
    // The canvas has no alpha, and a copy may only take channels its source has.
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGB8, width, height);
    [this.alongX, this.alongXFramebuffer] = this.makeFloatTarget(blurSourceUnit);
    [this.blurred, this.blurredFramebuffer] = this.makeFloatTarget(blurredBackdropUnit);
  }

  makeFloatTarget(unit) {
    const { gl } = this;
    const texture = makeTexture(gl, unit, gl.LINEAR);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, this.width, this.height);
    const framebuffer = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return [texture, framebuffer];
  }

  delete() {
    const { gl } = this;
    for (const texture of [this.scene, this.alongX, this.blurred]) gl.deleteTexture(texture);
    for (const framebuffer of [this.alongXFramebuffer, this.blurredFramebuffer]) gl.deleteFramebuffer(framebuffer);
  }
}

/**
 * Draws the client's newest frame on a canvas through WebGL 2: the
 * triangles `zuiWebLayOutNewestFrame` lays out, one draw call per batch,
 * each under its scissor rectangle and with its material, after the
 * backdrop blurs that run before it, with the glyph atlas uploaded again
 * whenever the client added glyphs to it.
 */
export class FrameDrawer {
  /**
   * @param {HTMLCanvasElement} canvas sized to each frame as it is drawn
   * @param {WebAssembly.Exports} wasm the client's exports, after `zuiWebInit`
   *   and, if bitmap text is to be drawn, `zuiWebLoadBitmapFonts`. Without
   *   float render targets, backdrop blurs are drawn as their tint alone.
   */
  constructor(canvas, wasm) {
    // Edges are not smoothed and nothing is composed with the page's
    // background, as a native target with one sample per pixel draws.
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error("this browser has no WebGL 2");
    this.canvas = canvas;
    this.gl = gl;
    this.wasm = wasm;

    if (!gl.getExtension("EXT_color_buffer_float")) wasm.zuiWebDrawBackdropBlursAsTints();
    this.blurTargets = null;

    const blurProgram = link(gl, blurVertexShaderSource, blurFragmentShaderSource);
    gl.useProgram(blurProgram);
    this.blurProgram = blurProgram;
    this.blurUniforms = uniformsOf(gl, blurProgram, ["region", "targetSize", "sampleDirection"]);
    gl.uniform1i(gl.getUniformLocation(blurProgram, "source"), blurSourceUnit);
    this.blurVertexArray = gl.createVertexArray();
    gl.bindVertexArray(this.blurVertexArray);
    this.blurTapBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.blurTapBuffer);
    this.blurTapLocation = gl.getAttribLocation(blurProgram, "tap");
    gl.enableVertexAttribArray(this.blurTapLocation);
    gl.vertexAttribDivisor(this.blurTapLocation, 1);

    const program = link(gl, vertexShaderSource, fragmentShaderSource);
    gl.useProgram(program);
    this.program = program;
    this.uniforms = uniformsOf(gl, program, ["viewport", "pixelsPerUnit", "targetHeight", "materialFirstColor", "materialSecondColor", "materialSizeAndScale", "materialPatternAndPhase"]);
    gl.uniform1i(gl.getUniformLocation(program, "blurredBackdrop"), blurredBackdropUnit);

    this.vertexArray = gl.createVertexArray();
    gl.bindVertexArray(this.vertexArray);
    this.vertexBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
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
    this.glyphAtlas = makeTexture(gl, glyphAtlasUnit, gl.LINEAR);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RG8, glyphAtlasSide, glyphAtlasSide);
    gl.uniform1i(gl.getUniformLocation(program, "glyphAtlas"), glyphAtlasUnit);
    makeTexture(gl, bitmapGlyphsUnit, gl.NEAREST);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R8, bitmapGlyphTextureSize[0], bitmapGlyphTextureSize[1]);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, bitmapGlyphTextureSize[0], bitmapGlyphTextureSize[1], gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(wasm.memory.buffer, wasm.zuiWebBitmapGlyphTexels() >>> 0, bitmapGlyphTextureSize[0] * bitmapGlyphTextureSize[1]));
    gl.uniform1i(gl.getUniformLocation(program, "bitmapGlyphs"), bitmapGlyphsUnit);

    gl.enable(gl.BLEND);
    this.blendOver();
  }

  blendOver() {
    this.gl.blendFuncSeparate(this.gl.SRC_ALPHA, this.gl.ONE_MINUS_SRC_ALPHA, this.gl.ONE, this.gl.ONE_MINUS_SRC_ALPHA);
  }

  /**
   * Blurs what the canvas holds inside the blur's region, as zui-sokol's
   * renderer does, into the texture that `.backdrop_blur` vertices sample.
   */
  runBackdropBlur(blur, width, height) {
    const { gl } = this;
    if (this.blurTargets?.width !== width || this.blurTargets?.height !== height) {
      this.blurTargets?.delete();
      this.blurTargets = new BlurTargets(gl, width, height);
    }
    const targets = this.blurTargets;
    gl.activeTexture(gl.TEXTURE0 + blurSourceUnit);
    gl.bindTexture(gl.TEXTURE_2D, targets.scene);
    gl.copyTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 0, 0, width, height);

    gl.disable(gl.SCISSOR_TEST);
    gl.useProgram(this.blurProgram);
    gl.bindVertexArray(this.blurVertexArray);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.blurTapBuffer);
    gl.vertexAttribPointer(this.blurTapLocation, 2, gl.FLOAT, false, blurTapBytes, blur.firstTap * blurTapBytes);
    gl.blendFunc(gl.ONE, gl.ONE);
    gl.clearColor(0, 0, 0, 0);
    const [left, top, right, bottom] = blur.region;
    gl.uniform4f(this.blurUniforms.region, left, height - bottom, right, height - top);
    gl.uniform2f(this.blurUniforms.targetSize, width, height);
    const passes = [
      { into: targets.alongXFramebuffer, source: targets.scene, direction: [1, 0] },
      // The region is laid out from the top, the target's rows from the bottom.
      { into: targets.blurredFramebuffer, source: targets.alongX, direction: [0, -1] },
    ];
    for (const pass of passes) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, pass.into);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.bindTexture(gl.TEXTURE_2D, pass.source);
      gl.uniform2f(this.blurUniforms.sampleDirection, ...pass.direction);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, blur.tapCount);
    }

    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.useProgram(this.program);
    gl.bindVertexArray(this.vertexArray);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
    this.blendOver();
    gl.enable(gl.SCISSOR_TEST);
  }

  backdropBlursOf(memory) {
    const count = this.wasm.zuiWebBackdropBlurCount();
    const start = this.wasm.zuiWebBackdropBlurs() >>> 0;
    const words = new Uint32Array(memory, start, count * backdropBlurBytes / 4);
    const floats = new Float32Array(memory, start, count * backdropBlurBytes / 4);
    return Array.from({ length: count }, (_, index) => {
      const at = index * backdropBlurBytes / 4;
      return { beforeBatch: words[at], firstTap: words[at + 1], tapCount: words[at + 2], region: floats.subarray(at + 3, at + 7) };
    });
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
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(memory, wasm.zuiWebVertices() >>> 0, wasm.zuiWebVertexCount() * vertexBytes), gl.STREAM_DRAW);
    gl.uniform2f(this.uniforms.viewport, viewport[0], viewport[1]);
    gl.uniform1f(this.uniforms.pixelsPerUnit, pixelsPerUnit);
    gl.uniform1f(this.uniforms.targetHeight, height);

    const blurs = this.backdropBlursOf(memory);
    if (blurs.length > 0) {
      const tapCount = blurs.reduce((count, blur) => Math.max(count, blur.firstTap + blur.tapCount), 0);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.blurTapBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(memory, wasm.zuiWebBlurTaps() >>> 0, tapCount * blurTapBytes), gl.STREAM_DRAW);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
    }
    const materials = new Float32Array(memory, wasm.zuiWebMaterials() >>> 0);
    gl.enable(gl.SCISSOR_TEST);
    const batches = new Uint32Array(memory, wasm.zuiWebBatches() >>> 0, batchCount * batchBytes / 4);
    const scissors = new Int32Array(batches.buffer, batches.byteOffset, batches.length);
    let nextBlur = 0;
    for (let batch = 0, at = 0; batch < batchCount; batch += 1, at += batchBytes / 4) {
      for (; nextBlur < blurs.length && blurs[nextBlur].beforeBatch === batch; nextBlur += 1) this.runBackdropBlur(blurs[nextBlur], width, height);
      const vertexCount = batches[at + 1];
      if (vertexCount === 0) continue;
      const material = batches[at + 6];
      if (material !== noMaterial) {
        const uniforms = materials.subarray(material * materialFloats, (material + 1) * materialFloats);
        gl.uniform4fv(this.uniforms.materialFirstColor, uniforms.subarray(0, 4));
        gl.uniform4fv(this.uniforms.materialSecondColor, uniforms.subarray(4, 8));
        gl.uniform4fv(this.uniforms.materialSizeAndScale, uniforms.subarray(8, 12));
        gl.uniform4fv(this.uniforms.materialPatternAndPhase, uniforms.subarray(12, 16));
      }
      gl.scissor(scissors[at + 2], scissors[at + 3], scissors[at + 4], scissors[at + 5]);
      gl.drawArrays(gl.TRIANGLES, batches[at], vertexCount);
    }
  }
}
