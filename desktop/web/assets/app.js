const token = decodeURIComponent(
  location.pathname.split("/").filter(Boolean).pop() || "",
);

function api(pathname) {
  return `${pathname}${pathname.includes("?") ? "&" : "?"}t=${encodeURIComponent(token)}`;
}

const el = {
  peer: document.getElementById("peer-name"),
  status: document.getElementById("status"),
  qr: document.getElementById("qr"),
  pairCode: document.getElementById("pair-code"),
  links: document.getElementById("links"),
  linksHint: document.getElementById("links-hint"),
  expiry: document.getElementById("expiry"),
  throughput: document.getElementById("throughput"),
  drop: document.getElementById("drop"),
  file: document.getElementById("file"),
  outgoing: document.getElementById("outgoing"),
  received: document.getElementById("received"),
  filesTitle: document.getElementById("files-title"),
  shared: document.getElementById("shared"),
  sharedSection: document.getElementById("shared-section"),
  earlier: document.getElementById("earlier"),
  earlierSection: document.getElementById("earlier-section"),
  desktopControls: document.getElementById("desktop-controls"),
  modeSend: document.getElementById("mode-send"),
  modeShare: document.getElementById("mode-share"),
  receiverPanel: document.getElementById("receiver-panel"),
  receiverLink: document.getElementById("receiver-link"),
  receiverConnect: document.getElementById("receiver-connect"),
  receiverDisconnect: document.getElementById("receiver-disconnect"),
  receiverState: document.getElementById("receiver-state"),
  transferHint: document.getElementById("transfer-hint"),
  dropTitle: document.getElementById("drop-title"),
  dropSub: document.getElementById("drop-sub"),
};

const CHUNK_SIZE = 4 * 1024 * 1024;
const MAX_RETRIES = 4;
const bridge = window.syndro;
const ownedKey = `syndro-owned:${token}`;
const ownedUploads = loadOwnedUploads();
let mode = bridge ? "send" : "browser";
let receiver = null;
let receiverError = "";
let connecting = false;
let pending = 0;
let hostName = "this device";
let infoReady = false;
let infoRevision = 0;
let availableFiles = [];
let expiresAt = 0;

/* ------------------------------------------------------------------ utils */

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = value >= 100 || unit === 0 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[unit]}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function groupCode(code) {
  return code && code.length === 8 ? `${code.slice(0, 4)} ${code.slice(4)}` : code || "—";
}

async function fetchReply(url, init = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(),
    !init.method || init.method === "GET" || init.method === "DELETE" ? 8000 : 60_000);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    const text = await response.text();
    const body = text ? JSON.parse(text) : {};
    return { response, body };
  } catch (error) {
    if (error.name === "AbortError") {
      throw new Error("Request timed out. Check the receiver, Wi-Fi, and firewall.");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchJson(url, init) {
  const { response, body } = await fetchReply(url, init);
  if (!response.ok) {
    throw new Error(body.error || `request failed with ${response.status}`);
  }
  return body;
}

function errorMessage(error) {
  return String(error.message || error)
    .replace(/^Error invoking remote method '[^']+': Error: /, "").slice(0, 300);
}

function loadOwnedUploads() {
  try {
    const ids = JSON.parse(sessionStorage.getItem(ownedKey) || "[]");
    return new Set(Array.isArray(ids) ? ids.filter((id) => /^[a-f0-9]{24}$/.test(id)) : []);
  } catch {
    return new Set();
  }
}

function rememberUpload(id) {
  // Record ownership before completion can emit file-added or a refresh can
  // list it. sessionStorage survives reloads without hiding other tabs' files.
  ownedUploads.add(id);
  try {
    sessionStorage.setItem(ownedKey, JSON.stringify([...ownedUploads]));
  } catch {
    // Restricted storage still gets in-memory filtering for this page.
  }
  renderFiles();
}

async function copyText(text, button) {
  const restore = () => {
    button.textContent = "copy";
    button.classList.remove("done");
  };

  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
    } else {
      // http:// LAN origins are not secure contexts, so the async clipboard
      // API is unavailable on the exact setup browser mode targets.
      const helper = document.createElement("textarea");
      helper.value = text;
      helper.setAttribute("readonly", "");
      helper.style.position = "fixed";
      helper.style.opacity = "0";
      document.body.appendChild(helper);
      helper.select();
      document.execCommand("copy");
      helper.remove();
    }
    button.textContent = "copied";
    button.classList.add("done");
  } catch {
    button.textContent = "failed";
  }
  setTimeout(restore, 1400);
}

/* -------------------------------------------------------------- rendering */

function kindLabel(kind) {
  switch (kind) {
    case "ipv6-ula":
      return "ula";
    case "ipv6-global":
      return "ipv6";
    case "ipv4-private":
      return "ipv4";
    case "ipv4-public":
      return "ipv4";
    default:
      return "link";
  }
}

function renderLinks(urls) {
  el.links.replaceChildren();
  const usable = urls.filter((entry) => entry.browserReachable);

  for (const entry of usable) {
    const row = document.createElement("div");
    row.className = "link-row";

    const code = document.createElement("code");
    code.textContent = entry.url;

    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = kindLabel(entry.kind);

    const button = document.createElement("button");
    button.className = "copy";
    button.type = "button";
    button.textContent = "copy";
    button.addEventListener("click", () => copyText(entry.url, button));

    row.append(code, tag, button);
    el.links.appendChild(row);
  }

  el.linksHint.classList.toggle("warn", usable.length === 0);
  el.linksHint.textContent =
    usable.length === 0
      ? "No browser-reachable address. Connect to Wi-Fi, or use a router that assigns a ULA or global IPv6 address."
      : "Open one of these in any browser on the same network. No install needed.";
}

function renderFileList(list, files, download, caption = "") {
  list.replaceChildren();
  for (const file of files) {
    const item = document.createElement("li");
    item.className = "row";
    item.dataset.fileId = file.id;

    const main = document.createElement("div");
    main.className = "row-main";

    const details = document.createElement("div");
    details.className = "row-details";
    const name = document.createElement("span");
    name.className = "row-name";
    name.textContent = file.name;
    name.title = file.name;
    details.appendChild(name);
    if (caption) {
      const destination = document.createElement("span");
      destination.className = "row-destination";
      destination.textContent = caption;
      details.appendChild(destination);
    }

    const size = document.createElement("span");
    size.className = "row-size";
    size.textContent = formatBytes(file.size);
    main.append(details, size);

    if (download) {
      const link = document.createElement("a");
      link.className = "download";
      link.href = api(`/api/files/${encodeURIComponent(file.id)}`);
      link.download = file.name;
      link.textContent = "Save";
      main.appendChild(link);
    } else {
      const state = document.createElement("span");
      state.className = "row-state done";
      state.textContent = "Shared";
      main.appendChild(state);
    }
    item.appendChild(main);
    list.appendChild(item);
  }
}

function renderFiles() {
  el.filesTitle.textContent = bridge ? "Received" : "Available to download";
  if (!bridge) {
    renderFileList(el.received, availableFiles.filter((file) => !ownedUploads.has(file.id)), true);
    el.sharedSection.hidden = true;
    el.earlierSection.hidden = true;
    return;
  }
  const shared = availableFiles.filter((file) => file.origin === "shared");
  const received = availableFiles.filter((file) => file.origin === "received");
  const earlier = availableFiles.filter((file) => file.origin !== "shared" && file.origin !== "received");
  renderFileList(el.shared, shared, false);
  renderFileList(el.received, received, true);
  renderFileList(el.earlier, earlier, true, "Direction wasn't recorded in v0.1.");
  el.sharedSection.hidden = mode !== "share" && shared.length === 0;
  el.earlierSection.hidden = earlier.length === 0;
}

function canTransfer() {
  if (connecting) return false;
  return bridge && mode === "send" ? receiver !== null : infoReady;
}

function updateControls() {
  const locked = pending > 0 || connecting;
  el.desktopControls.hidden = !bridge;
  el.modeSend.setAttribute("aria-pressed", String(mode === "send"));
  el.modeShare.setAttribute("aria-pressed", String(mode === "share"));
  el.modeSend.disabled = locked;
  el.modeShare.disabled = locked;
  el.receiverPanel.hidden = mode !== "send";
  el.receiverLink.disabled = locked || receiver !== null;
  el.receiverConnect.disabled = locked;
  el.receiverConnect.hidden = receiver !== null;
  el.receiverDisconnect.disabled = locked;
  el.receiverDisconnect.hidden = receiver === null;
  el.receiverState.classList.toggle("error", !!receiverError);
  el.receiverState.textContent = connecting ? "Checking receiver…" : receiverError ||
    (receiver ? `Connected to ${receiver.name} · ${receiver.address}` : "No receiver selected.");

  if (mode === "share") {
    el.transferHint.textContent = `Files stay on ${hostName}. Open this device's share link on the other device to download. Sharing is not delivery.`;
    el.dropTitle.textContent = "Drop files to share";
  } else if (bridge) {
    el.transferHint.textContent = receiver
      ? `Files will be sent directly to ${receiver.name}. Keep the receiver's sharing service running.`
      : "Start sharing on the other device, then paste its share link above. Connect before choosing files.";
    el.dropTitle.textContent = receiver ? `Drop files to send to ${receiver.name}` : "Connect a receiver first";
  } else {
    el.transferHint.textContent = infoReady
      ? `Files will be sent to ${hostName}, the device hosting this share. Your own uploads are hidden from the download list.`
      : "Checking the device hosting this share…";
    el.dropTitle.textContent = infoReady ? `Drop files to send to ${hostName}` : "Waiting for this share";
  }
  const ready = canTransfer();
  el.drop.setAttribute("aria-disabled", String(!ready));
  el.drop.setAttribute("aria-label", mode === "share" ? "Choose files to share locally" : "Choose files to send");
  el.drop.tabIndex = ready ? 0 : -1;
  el.file.disabled = !ready;
  el.dropSub.textContent = ready ? "or tap to choose" : "No files will be sent until connected";
}

function setMode(next) {
  if (!bridge || pending > 0 || connecting || !["send", "share"].includes(next)) return;
  mode = next;
  updateControls();
  renderFiles();
}

async function connectReceiver() {
  if (!bridge || pending > 0 || connecting) return;
  receiver = null;
  receiverError = "";
  connecting = true;
  updateControls();
  try {
    receiver = await bridge.connect(el.receiverLink.value);
  } catch (error) {
    receiverError = errorMessage(error);
  } finally {
    connecting = false;
    updateControls();
  }
}

async function disconnectReceiver() {
  if (!bridge || pending > 0 || connecting) return;
  connecting = true;
  updateControls();
  try {
    await bridge.disconnect();
    receiver = null;
    receiverError = "";
  } catch (error) {
    receiverError = errorMessage(error);
  } finally {
    connecting = false;
    updateControls();
  }
}

function createOutgoingRow(file, destination) {
  const item = document.createElement("li");
  item.className = "row";
  item.dataset.purpose = destination.kind;

  const main = document.createElement("div");
  main.className = "row-main";

  const details = document.createElement("div");
  details.className = "row-details";
  const name = document.createElement("span");
  name.className = "row-name";
  name.textContent = file.name;
  name.title = file.name;
  const target = document.createElement("span");
  target.className = "row-destination";
  target.textContent = destination.kind === "share" ? `Shared from ${destination.name}` : `To ${destination.name}`;
  details.append(name, target);

  const size = document.createElement("span");
  size.className = "row-size";
  size.textContent = formatBytes(file.size);

  const state = document.createElement("span");
  state.className = "row-state";
  state.textContent = "Queued";

  main.append(details, size, state);

  const bar = document.createElement("div");
  bar.className = "bar";
  const fill = document.createElement("i");
  bar.appendChild(fill);
  const error = document.createElement("p");
  error.className = "row-error";
  error.hidden = true;

  item.append(main, bar, error);
  el.outgoing.prepend(item);

  return { item, state, fill, bar, error };
}

function setProgress(row, fraction, label) {
  const pct = Math.max(0, Math.min(1, fraction)) * 100;
  row.fill.style.width = `${pct.toFixed(1)}%`;
  if (label) {
    row.state.className = "row-state";
    row.state.textContent = label;
  }
}

/* -------------------------------------------------------------- transfers */

let queue = Promise.resolve();
const throughputWindow = [];

function noteThroughput(bytes) {
  const now = Date.now();
  throughputWindow.push({ at: now, bytes });
  while (throughputWindow.length > 0 && now - throughputWindow[0].at > 2000) {
    throughputWindow.shift();
  }
  const total = throughputWindow.reduce((sum, entry) => sum + entry.bytes, 0);
  const span = Math.max(
    (now - throughputWindow[0].at) / 1000,
    0.5,
  );
  el.throughput.textContent = total > 0 ? `${formatBytes(total / span)}/s` : "";
}

async function appendBrowserUpload(id, offset, blob) {
  const { response, body } = await fetchReply(api(`/api/uploads/${id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": String(offset) },
    body: blob,
  });
  if (response.status === 409) return body.expected;
  if (!response.ok) throw new Error(body.error || `chunk rejected with ${response.status}`);
  if (body.offset !== offset + blob.size) throw new Error("The receiver returned an invalid chunk offset.");
  return body.offset;
}

async function sendFile(file, destination, row) {
  const direct = destination.kind === "send";
  const action = destination.kind === "share" ? "Sharing" : "Sending";
  let uploadId = null;
  let confirmed = false;
  setProgress(row, 0, action);
  try {
    const metadata = { name: file.name, size: file.size, mime: file.type || "application/octet-stream" };
    const created = direct
      ? await bridge.beginUpload(destination.receiverId, metadata)
      : await fetchJson(api("/api/uploads"), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(destination.kind === "share" ? { "x-syndro-purpose": "share" } : {}),
        },
        body: JSON.stringify(metadata),
      });
    if (typeof created.id !== "string" || (!direct && !/^[a-f0-9]{24}$/.test(created.id)) ||
        !Number.isSafeInteger(created.offset) || created.offset < 0 || created.offset > file.size) {
      throw new Error("The receiver returned an invalid upload identifier or offset.");
    }
    uploadId = created.id;
    if (!direct) rememberUpload(uploadId);
    const chunkSize = Number.isSafeInteger(created.chunkSize) && created.chunkSize > 0
      ? Math.min(created.chunkSize, CHUNK_SIZE) : CHUNK_SIZE;
    let offset = created.offset;
    let stalled = 0;
    while (offset < file.size) {
      const end = Math.min(offset + chunkSize, file.size);
      const blob = file.slice(offset, end);
      const bytes = direct ? await blob.arrayBuffer() : null;
      let attempt = 0;
      let next;
      while (true) {
        try {
          next = direct
            ? (await bridge.appendUpload(uploadId, offset, bytes)).offset
            : await appendBrowserUpload(uploadId, offset, blob);
          if (!Number.isSafeInteger(next) || next < 0 || next > file.size) {
            throw new Error("The receiver returned an invalid resume offset.");
          }
          break;
        } catch (error) {
          attempt += 1;
          if (attempt >= MAX_RETRIES) throw error;
          setProgress(row, offset / Math.max(file.size, 1), `Retry ${attempt}`);
          await sleep(400 * attempt);
        }
      }
      stalled = next <= offset ? stalled + 1 : 0;
      if (stalled >= MAX_RETRIES) throw new Error("The receiver is not accepting any more data.");
      noteThroughput(Math.max(next - offset, 0));
      offset = next;
      setProgress(row, offset / Math.max(file.size, 1), action);
    }
    setProgress(row, 1, "Confirming");
    if (direct) {
      await bridge.completeUpload(uploadId);
    } else {
      const result = await fetchJson(api(`/api/uploads/${uploadId}/complete`), { method: "POST" });
      if (!result.file || result.file.id !== uploadId || result.file.size !== file.size) {
        throw new Error("The receiver did not confirm the completed file.");
      }
      // A late pre-completion refresh must not erase the just-confirmed file.
      infoRevision += 1;
      availableFiles = [result.file, ...availableFiles.filter((entry) => entry.id !== uploadId)];
      renderFiles();
    }
    confirmed = true;
    setProgress(row, 1, destination.kind === "share" ? "Shared" : "Sent");
    row.state.classList.add("done");
    row.bar.hidden = true;
    // Publishing belongs in Shared files, not in two lists at once.
    if (destination.kind === "share") row.item.remove();
    if (!direct) void refreshInfo();
  } catch (error) {
    console.error("transfer failed", error);
    row.state.className = "row-state failed";
    row.state.textContent = "Failed";
    row.fill.style.background = "var(--bad)";
    row.error.textContent = errorMessage(error);
    row.error.hidden = false;
    if (uploadId && !confirmed) {
      try {
        if (direct) await bridge.abortUpload(uploadId);
        else await fetchJson(api(`/api/uploads/${uploadId}`), { method: "DELETE" });
      } catch {
        // The receiver may be offline. It will sweep abandoned partial files.
      }
    }
  }
}

function enqueue(files) {
  if (!canTransfer()) return;
  const list = [...files].filter((file) => Number.isSafeInteger(file.size) && file.size >= 0);
  // Capture the destination now, not when a queued file eventually starts.
  const destination = mode === "send"
    ? { kind: mode, name: receiver.name, receiverId: receiver.id }
    : { kind: mode, name: hostName };
  pending += list.length;
  updateControls();
  for (const file of list) {
    const row = createOutgoingRow(file, destination);
    queue = queue.then(async () => {
      try {
        await sendFile(file, destination, row);
      } finally {
        pending -= 1;
        updateControls();
      }
    }).catch(() => undefined);
  }
  return queue;
}

/* ------------------------------------------------------------------- init */

async function refreshInfo() {
  const revision = ++infoRevision;
  try {
    const info = await fetchJson(api("/api/info"));
    if (revision !== infoRevision) return;
    hostName = info.deviceName;
    infoReady = true;
    availableFiles = Array.isArray(info.files) ? info.files : [];
    el.peer.textContent = info.deviceName;
    el.pairCode.textContent = groupCode(info.token || token);
    expiresAt = Number(info.expiresAt) || 0;
    el.qr.src = api("/api/qr.svg");
    renderLinks(Array.isArray(info.urls) ? info.urls : []);
    renderFiles();
    updateControls();
    tickExpiry();
    setOnline(true);
  } catch (error) {
    if (revision !== infoRevision) return;
    infoReady = false;
    updateControls();
    console.error("info failed", error);
    setOnline(false);
  }
}

function setOnline(online) {
  el.status.classList.toggle("offline", !online);
  el.status.lastElementChild.textContent = online ? "live" : "offline";
}

function tickExpiry() {
  if (!expiresAt) {
    el.expiry.textContent = "while sharing";
    return;
  }
  const remaining = expiresAt - Date.now();
  if (remaining <= 0) {
    el.expiry.textContent = "expired";
    return;
  }
  const totalMinutes = Math.floor(remaining / 60000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  el.expiry.textContent = hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
}

function connectEvents() {
  const source = new EventSource(api("/api/events"));

  source.addEventListener("open", () => setOnline(true));
  source.addEventListener("error", () => setOnline(false));

  source.addEventListener("file-added", (event) => {
    try {
      const payload = JSON.parse(event.data);
      if (payload && payload.file) void refreshInfo();
    } catch {
      // Ignore malformed events; the periodic refresh will catch up.
    }
  });

  source.addEventListener("upload-progress", (event) => {
    try {
      JSON.parse(event.data);
    } catch {
      // Non-fatal.
    }
  });
}

el.modeSend.addEventListener("click", () => setMode("send"));
el.modeShare.addEventListener("click", () => setMode("share"));
el.receiverConnect.addEventListener("click", () => void connectReceiver());
el.receiverDisconnect.addEventListener("click", () => void disconnectReceiver());
el.receiverLink.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    void connectReceiver();
  }
});

el.drop.addEventListener("click", (event) => {
  if (canTransfer() && event.target !== el.file) el.file.click();
});
el.drop.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    if (canTransfer()) el.file.click();
  }
});
el.file.addEventListener("change", () => {
  if (el.file.files) enqueue(el.file.files);
  el.file.value = "";
});

for (const type of ["dragenter", "dragover"]) {
  el.drop.addEventListener(type, (event) => {
    event.preventDefault();
    if (canTransfer()) el.drop.classList.add("over");
  });
}
for (const type of ["dragleave", "drop"]) {
  el.drop.addEventListener(type, (event) => {
    event.preventDefault();
    el.drop.classList.remove("over");
  });
}
el.drop.addEventListener("drop", (event) => {
  if (event.dataTransfer?.files?.length) enqueue(event.dataTransfer.files);
});

updateControls();
renderFiles();
void refreshInfo();
connectEvents();
tickExpiry();
setInterval(tickExpiry, 15_000);
setInterval(() => void refreshInfo(), 30_000);
setInterval(() => {
  const last = throughputWindow[throughputWindow.length - 1];
  if (!last || Date.now() - last.at > 2000) el.throughput.textContent = "";
}, 1000);
