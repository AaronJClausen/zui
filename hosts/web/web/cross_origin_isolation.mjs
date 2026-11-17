// Makes the page cross-origin isolated where its host does not serve it so:
// the service worker at `serviceWorkerUrl` re-serves the page with the
// headers that isolate it, which takes effect from the next load, so the
// page reloads once.
//
//   if (!(await becomeCrossOriginIsolated("isolation_service_worker.js"))) return; // reloading

const reloadedForIsolationKey = "zui-web reloaded for cross-origin isolation";

function alreadyReloadedForIsolation() {
  try {
    return sessionStorage.getItem(reloadedForIsolationKey) !== null;
  } catch {
    // Without session storage, a page that cannot be isolated would reload
    // forever.
    return true;
  }
}

function rememberReloadingForIsolation(reloading) {
  try {
    if (reloading) sessionStorage.setItem(reloadedForIsolationKey, "1");
    else sessionStorage.removeItem(reloadedForIsolationKey);
  } catch {}
}

// True once the page is isolated, false while it reloads to become so.
// Throws when it cannot be.
export async function becomeCrossOriginIsolated(serviceWorkerUrl) {
  if (globalThis.crossOriginIsolated) {
    rememberReloadingForIsolation(false);
    return true;
  }
  if (!("serviceWorker" in navigator)) throw new Error("this browser cannot isolate the page: it has no service workers, or the page is not served over HTTPS");
  if (alreadyReloadedForIsolation()) {
    rememberReloadingForIsolation(false);
    throw new Error("the page is not cross-origin isolated, even served through its service worker");
  }
  await navigator.serviceWorker.register(serviceWorkerUrl);
  await navigator.serviceWorker.ready;
  rememberReloadingForIsolation(true);
  location.reload();
  return false;
}
