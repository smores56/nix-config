/*
 * Kanbei's model-output renderer.
 *
 * The only DOM it creates is one <p> per line, each holding exactly one text node. There is
 * no HTML parsing, no markdown, and no auto-linking: an `![](https://...)` or
 * `[label](https://...)` from model output is displayed literally, so it cannot trigger a
 * request or a navigation. `safeHref` is the single gate any future dynamic href must pass.
 */
(function (global, factory) {
  "use strict";
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    global.KanbeiRender = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const FORBIDDEN_SCHEME = /^(?:javascript|data|vbscript|file|blob):/i;
  const CONTROL = /[\u0000-\u001f\u007f]/;

  function safeHref(raw) {
    if (typeof raw !== "string") return null;
    const value = raw.trim();
    if (!value || CONTROL.test(value)) return null;
    if (FORBIDDEN_SCHEME.test(value)) return null;
    if (value.startsWith("//")) return null;
    if (value.startsWith("/") || value.startsWith("#")) return value;
    let parsed;
    try {
      parsed = new URL(value);
    } catch (_error) {
      return null;
    }
    if (parsed.protocol !== "https:") return null;
    return parsed.href;
  }

  function renderModelText(container, text) {
    if (!container || typeof container.appendChild !== "function") {
      throw new TypeError("renderModelText needs a DOM container");
    }
    const source = text === null || text === undefined ? "" : String(text);
    const lines = source.replace(/\r\n?/g, "\n").split("\n");
    for (const line of lines) {
      const paragraph = document.createElement("p");
      paragraph.appendChild(document.createTextNode(line));
      container.appendChild(paragraph);
    }
  }

  return { safeHref: safeHref, renderModelText: renderModelText };
});
