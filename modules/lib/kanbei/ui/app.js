/*
 * Kanbei shell behaviour: plain fetch calls, text-node rendering, passkey stub.
 * No HTML is ever built from server data and no remote origin is contacted.
 */
(function () {
  "use strict";

  const render = window.KanbeiRender;
  const form = document.getElementById("chat-form");
  const input = document.getElementById("message");
  const transcript = document.getElementById("transcript");
  const status = document.getElementById("status");
  const passkeyButton = document.getElementById("passkey");

  function setStatus(text) {
    if (status) status.textContent = text;
  }

  function appendMessage(role, text) {
    if (!transcript) return;
    const article = document.createElement("article");
    article.className = "message message-" + role;
    const heading = document.createElement("p");
    heading.className = "who";
    heading.appendChild(document.createTextNode(role === "user" ? "You" : "Kanbei"));
    article.appendChild(heading);
    const body = document.createElement("div");
    body.className = "body";
    render.renderModelText(body, text);
    article.appendChild(body);
    transcript.appendChild(article);
  }

  async function sendMessage(message) {
    const response = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: message }),
      credentials: "same-origin",
      redirect: "error",
    });
    if (!response.ok) {
      throw new Error("Kanbei returned " + response.status);
    }
    const data = await response.json();
    if (!data || typeof data.reply !== "string") {
      throw new Error("Kanbei returned no text");
    }
    return data.reply;
  }

  if (form && input && transcript) {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const message = input.value.trim();
      if (!message) return;
      appendMessage("user", message);
      input.value = "";
      setStatus("Waiting for Kanbei...");
      try {
        const reply = await sendMessage(message);
        appendMessage("kanbei", reply);
        setStatus("");
      } catch (error) {
        setStatus(String(error && error.message ? error.message : error));
      }
    });
  }

  function base64urlToBytes(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/");
    const raw = window.atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  function bytesToBase64url(buffer) {
    const bytes = new Uint8Array(buffer);
    let raw = "";
    for (let i = 0; i < bytes.length; i += 1) raw += String.fromCharCode(bytes[i]);
    return window.btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  async function postJson(path, body) {
    const response = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
      redirect: "error",
    });
    return response.json();
  }

  if (passkeyButton) {
    passkeyButton.addEventListener("click", async () => {
      setStatus("Requesting a passkey challenge...");
      try {
        const options = await postJson("/api/passkey/register/options", {});
        if (!window.PublicKeyCredential || !navigator.credentials) {
          setStatus("This browser cannot create a passkey; the server stub is ready.");
          return;
        }
        const credential = await navigator.credentials.create({
          publicKey: {
            challenge: base64urlToBytes(options.challenge),
            rp: options.rp,
            user: {
              id: base64urlToBytes(options.user.id),
              name: options.user.name,
              displayName: options.user.displayName,
            },
            pubKeyCredParams: options.pubKeyCredParams,
            authenticatorSelection: options.authenticatorSelection,
            timeout: options.timeout,
            attestation: options.attestation,
          },
        });
        const verified = await postJson("/api/passkey/register/verify", {
          challenge: options.challenge,
          credential: {
            id: credential.id,
            type: credential.type,
            clientDataJSON: bytesToBase64url(credential.response.clientDataJSON),
          },
        });
        setStatus(verified.ok ? "Passkey stored (server-side stub)." : "Passkey was refused.");
      } catch (error) {
        setStatus(String(error && error.message ? error.message : error));
      }
    });
  }

  window.KanbeiShell = { appendMessage: appendMessage, setStatus: setStatus };
})();
