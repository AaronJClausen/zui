// Serves the page and everything it loads again with the headers that make
// it cross-origin isolated, for a host such as GitHub Pages that cannot set
// them, so the page may share memory with its workers.

const isolationHeaders = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
  const { request } = event;
  // Chromium throws on fetching such a request from a service worker.
  if (request.cache === "only-if-cached" && request.mode !== "same-origin") return;
  event.respondWith(withIsolationHeaders(request));
});

async function withIsolationHeaders(request) {
  const response = await fetch(request);
  // An opaque response's headers cannot be read or rewritten.
  if (response.type === "opaque" || response.type === "opaqueredirect") return response;
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(isolationHeaders)) headers.set(name, value);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
