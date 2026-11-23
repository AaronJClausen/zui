// Opens a page in headless Chromium, served from memory and the disk, and
// drives it over the DevTools protocol, for the checks that need a browser.
//
//   const page = await openHeadlessPage(chromiumPath, { "/": { path, type: "text/html" } });
//   try { await page.evaluate("1 + 1"); } finally { await page.close(); }
//
// With `attachWorkers`, the page's dedicated workers can be evaluated in too:
//
//   const page = await openHeadlessPage(chromiumPath, served, { headers: isolationHeaders, attachWorkers: true });
//   await page.evaluateInWorker("host_worker.mjs", "zuiHost.turns");

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const loadMilliseconds = 30_000;
const evaluateMilliseconds = 20_000;

// `served` maps each path to `{ path, type }`, a file, or `{ body, type }`,
// each served with `headers`. The page sets `window.ready = true` once it
// has loaded what it needs.
export async function openHeadlessPage(chromiumPath, served, { headers = {}, attachWorkers = false } = {}) {
  let chromium = null;
  let profileDirectory = null;
  let socket = null;

  const server = createServer(async (request, response) => {
    const file = served[new URL(request.url, "http://localhost").pathname];
    if (!file) {
      response.writeHead(404).end();
      return;
    }
    const body = file.path ? await readFile(file.path) : file.body;
    response.writeHead(200, { ...headers, "content-type": file.type }).end(body);
  });

  // A launcher, such as Arch's /usr/bin/chromium, runs the browser as its
  // child, which outlives the launcher killed alone; the browser and its
  // processes share the launcher's process group, which is killed whole,
  // also when the check exits without closing the page.
  function killChromium() {
    try {
      process.kill(-chromium.pid, "SIGKILL");
    } catch {}
  }

  async function close() {
    socket?.close();
    if (chromium) {
      const running = chromium.exitCode === null && chromium.signalCode === null;
      const exited = running ? new Promise((resolve) => chromium.once("exit", resolve)) : Promise.resolve();
      killChromium();
      await exited;
    }
    server.close();
    // Chromium's child processes outlive the one killed, and may still be
    // writing to the profile as it is removed.
    if (profileDirectory) await rm(profileDirectory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }

  try {
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const pageUrl = `http://127.0.0.1:${server.address().port}/`;

    profileDirectory = await mkdtemp(join(tmpdir(), "zui-web-chromium-"));
    chromium = spawn(chromiumPath, [
      "--headless",
      `--user-data-dir=${profileDirectory}`,
      "--remote-debugging-port=0",
      // The same software rasterizer on every machine, whatever its GPU.
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "about:blank",
    ], { stdio: ["ignore", "ignore", "pipe"], detached: true });
    process.once("exit", killChromium);
    for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit(1));

    const debuggerUrl = await new Promise((resolve, reject) => {
      let output = "";
      chromium.once("error", (error) => reject(new Error(`${chromiumPath} did not start: ${error.message}`)));
      const exitedEarly = (code) => reject(new Error(`${chromiumPath} exited with ${code} before it listened:\n${output}`));
      chromium.once("exit", exitedEarly);
      chromium.stderr.on("data", (chunk) => {
        output += chunk;
        const announced = output.match(/DevTools listening on (ws:\S+)/);
        if (!announced) return;
        chromium.off("exit", exitedEarly);
        output = "";
        resolve(announced[1]);
      });
    });

    socket = new WebSocket(debuggerUrl);
    await new Promise((resolve, reject) => {
      socket.onopen = resolve;
      socket.onerror = () => reject(new Error("the DevTools socket did not open"));
    });
    let nextRequestId = 1;
    const pending = new Map();
    const pageErrors = [];
    const workers = [];
    socket.onmessage = ({ data }) => {
      const message = JSON.parse(data);
      if (message.id && pending.has(message.id)) {
        const { resolve, reject } = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) reject(new Error(message.error.message));
        else resolve(message.result);
      } else if (message.method === "Runtime.exceptionThrown") {
        pageErrors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
      } else if (message.method === "Target.attachedToTarget" && message.params.targetInfo.type === "worker") {
        const worker = { url: message.params.targetInfo.url, sessionId: message.params.sessionId };
        workers.push(worker);
        sendToBrowser("Runtime.enable", {}, worker.sessionId).catch(() => {});
        sendToBrowser("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, worker.sessionId).catch(() => {});
      } else if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
        pageErrors.push(message.params.args.map((argument) => argument.value ?? argument.description).join(" "));
      }
    };

    function sendToBrowser(method, params = {}, sessionId = undefined) {
      const id = nextRequestId;
      nextRequestId += 1;
      socket.send(JSON.stringify({ id, method, params, sessionId }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    }

    const { targetId } = await sendToBrowser("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await sendToBrowser("Target.attachToTarget", { targetId, flatten: true });
    const send = (method, params = {}) => sendToBrowser(method, params, sessionId);
    await send("Runtime.enable");
    if (attachWorkers) await send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await send("Page.navigate", { url: pageUrl });

    // A worker blocked in a wait never answers.
    async function evaluateIn(sessionId, expression) {
      let timer = null;
      const unanswered = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`no answer to ${expression.slice(0, 80)} within ${evaluateMilliseconds / 1000} s`)), evaluateMilliseconds);
      });
      const evaluated = sendToBrowser("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
      const { result, exceptionDetails } = await Promise.race([evaluated, unanswered]).finally(() => clearTimeout(timer));
      if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
      return result.value;
    }
    const evaluate = (expression) => evaluateIn(sessionId, expression);

    // In the newest worker whose script's URL ends with `scriptName`.
    function evaluateInWorker(scriptName, expression) {
      const worker = workers.findLast(({ url }) => url.endsWith(scriptName));
      if (!worker) return Promise.reject(new Error(`no worker runs ${scriptName}`));
      return evaluateIn(worker.sessionId, expression);
    }

    const pollMilliseconds = 50;
    for (let waited = 0; !(await evaluate("window.ready === true").catch(() => false)); waited += pollMilliseconds) {
      if (pageErrors.length > 0) throw new Error(`the page failed: ${pageErrors.join("\n")}`);
      if (waited >= loadMilliseconds) throw new Error(`the page did not load within ${loadMilliseconds / 1000} s`);
      await new Promise((resolve) => setTimeout(resolve, pollMilliseconds));
    }
    return { evaluate, evaluateInWorker, send, sendToBrowser, pageUrl, pageErrors, close };
  } catch (error) {
    await close();
    throw error;
  }
}
