// Reads the page's settings that `zui_web.Host` reports as its environment,
// and whether the page is shown, into calls on a sink: each once at once,
// then again whenever it changes, calling `onChanged` after each change.
//
//   const environment = followPageEnvironment(sink, () => sink.flush());
//   environment.stop();
//
// A setting is `sink.setting(name, value)`, `name` a field of
// `zui_web.PageEnvironment` and `value` the text it parses: a boolean as
// "true" or "false", an enum by its tag name, a locale as its BCP 47 tag.

function fromMedia(name, queries, valueOf) {
  const lists = queries.map((query) => matchMedia(query));
  return {
    name,
    read: () => valueOf(...lists.map((list) => list.matches)),
    watch(changed) {
      for (const list of lists) list.addEventListener("change", changed);
      return () => {
        for (const list of lists) list.removeEventListener("change", changed);
      };
    },
  };
}

function fromEvents(name, read, target, types) {
  return {
    name,
    read,
    watch(changed) {
      for (const type of types) target.addEventListener(type, changed);
      return () => {
        for (const type of types) target.removeEventListener(type, changed);
      };
    },
  };
}

// The page may set `dir` or `lang` on its root, which changes the direction
// its text is laid out in.
function readingDirection() {
  return {
    name: "direction",
    read: () => (getComputedStyle(document.documentElement).direction === "rtl" ? "right_to_left" : "left_to_right"),
    watch(changed) {
      const observer = new MutationObserver(changed);
      observer.observe(document.documentElement, { attributes: true, attributeFilter: ["dir", "lang"] });
      return () => observer.disconnect();
    },
  };
}

const pageSettings = [
  fromMedia("theme", ["(prefers-color-scheme: dark)"], (dark) => (dark ? "dark" : "light")),
  fromMedia("contrast", ["(prefers-contrast: more)", "(forced-colors: active)"], (more, forced) => (more || forced ? "high" : "normal")),
  fromMedia("reduced_motion", ["(prefers-reduced-motion: reduce)"], String),
  fromMedia("reduced_transparency", ["(prefers-reduced-transparency: reduce)"], String),
  fromEvents("locale", () => navigator.language, globalThis, ["languagechange"]),
  readingDirection(),
  fromEvents("window_focused", () => String(document.hasFocus()), globalThis, ["focus", "blur"]),
];

export function followPageEnvironment(sink, onChanged = () => {}) {
  const unwatches = [];
  for (const { name, read, watch } of pageSettings) {
    let reported = read();
    sink.setting(name, reported);
    unwatches.push(
      watch(() => {
        const now = read();
        if (now === reported) return;
        reported = now;
        sink.setting(name, now);
        onChanged();
      }),
    );
  }

  const shown = () => document.visibilityState === "visible";
  let reportedShown = shown();
  sink.pageShown(reportedShown);
  const visibilityChanged = () => {
    if (shown() === reportedShown) return;
    reportedShown = shown();
    sink.pageShown(reportedShown);
    onChanged();
  };
  document.addEventListener("visibilitychange", visibilityChanged);
  unwatches.push(() => document.removeEventListener("visibilitychange", visibilityChanged));

  return {
    stop() {
      for (const unwatch of unwatches) unwatch();
    },
  };
}
