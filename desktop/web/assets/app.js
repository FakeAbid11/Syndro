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
  links: document.getElementById("links"),
  linksHint: document.getElementById("links-hint"),
  expiry: document.getElementById("expiry"),
  throughput: document.getElementById("throughput"),
  drop: document.getElementById("drop"),
  file: document.getElementById("file"),
  outgoing: document.getElementById("outgoing"),
  received: document.getElementById("received"),
};

const CHUNK_SIZE = 4 * 1024 * 1024;
const MAX_RETRIES = 4;
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

async function fetchJson(url, init) {
  const response = await fetch(url, init);
  const text = await response.text();
  const body = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(body.error || `request failed with ${response.status}`);
  }
  return body;
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

function renderReceived(files) {
  el.received.replaceChildren();

  for (const file of files) {
    const item = document.createElement("li");
    item.className = "row";

    const main = document.createElement("div");
    main.className = "row-main";

    const name = document.createElement("span");
    name.className = "row-name";
    name.textContent = file.name;

    const size = document.createElement("span");
    size.className = "row-size";
    size.textContent = formatBytes(file.size);

    const link = document.createElement("a");
    link.className = "download";
    link.href = api(`/api/files/${file.id}`);
    link.download = file.name;
    link.textContent = "save";

    main.append(name, size, link);
    item.appendChild(main);
    el.received.appendChild(item);
  }
}

function createOutgoingRow(file) {
  const item = document.createElement("li");
  item.className = "row";

  const main = document.createElement("div");
  main.className = "row-main";

  const name = document.createElement("span");
  name.className = "row-name";
  name.textContent = file.name;

  const size = document.createElement("span");
  size.className = "row-size";
  size.textContent = formatBytes(file.size);

  const state = document.createElement("span");
  state.className = "row-state";
  state.textContent = "queued";

  main.append(name, size, state);

  const bar = document.createElement("div");
  bar.className = "bar";
  const fill = document.createElement("i");
  bar.appendChild(fill);

  item.append(main, bar);
  el.outgoing.prepend(item);

  return { item, state, fill };
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

async function sendFile(file) {
  const row = createOutgoingRow(file);
  setProgress(row, 0, "sending");

  try {
    const created = await fetchJson(api("/api/uploads"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        name: file.name,
        size: file.size,
        mime: file.type || "application/octet-stream",
      }),
    });

    let offset = Number(created.offset) || 0;
    const uploadId = created.id;

    while (offset < file.size) {
      const end = Math.min(offset + CHUNK_SIZE, file.size);
      const blob = file.slice(offset, end);
      let attempt = 0;

      while (true) {
        try {
          const response = await fetch(api(`/api/uploads/${uploadId}`), {
            method: "PUT",
            headers: { "x-syndro-offset": String(offset) },
            body: blob,
          });

          if (response.status === 409) {
            const conflict = await response.json();
            offset = Number(conflict.expected) || 0;
            break;
          }

          if (!response.ok) {
            throw new Error(`chunk rejected with ${response.status}`);
          }

          noteThroughput(end - offset);
          offset = end;
          setProgress(row, offset / Math.max(file.size, 1), "sending");
          break;
        } catch (error) {
          attempt += 1;
          if (attempt >= MAX_RETRIES) throw error;
          setProgress(row, offset / Math.max(file.size, 1), `retry ${attempt}`);
          await sleep(400 * attempt);
        }
      }
    }

    await fetchJson(api(`/api/uploads/${uploadId}/complete`), { method: "POST" });
    setProgress(row, 1, "sent");
    row.state.classList.add("done");
  } catch (error) {
    console.error("send failed", error);
    row.state.className = "row-state failed";
    row.state.textContent = "failed";
    row.fill.style.background = "var(--bad)";
  }
}

function enqueue(files) {
  const list = [...files].filter((file) => file.size >= 0);
  for (const file of list) {
    queue = queue.then(() => sendFile(file)).catch(() => undefined);
  }
}

/* ------------------------------------------------------------------- init */

async function refreshInfo() {
  try {
    const info = await fetchJson(api("/api/info"));
    el.peer.textContent = info.deviceName;
    expiresAt = Number(info.expiresAt) || 0;
    el.qr.src = api("/api/qr.svg");
    renderLinks(Array.isArray(info.urls) ? info.urls : []);
    renderReceived(Array.isArray(info.files) ? info.files : []);
    tickExpiry();
    setOnline(true);
  } catch (error) {
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

el.drop.addEventListener("click", () => el.file.click());
el.drop.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    el.file.click();
  }
});
el.file.addEventListener("change", () => {
  if (el.file.files) enqueue(el.file.files);
  el.file.value = "";
});

for (const type of ["dragenter", "dragover"]) {
  el.drop.addEventListener(type, (event) => {
    event.preventDefault();
    el.drop.classList.add("over");
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

void refreshInfo();
connectEvents();
tickExpiry();
setInterval(tickExpiry, 15_000);
setInterval(() => void refreshInfo(), 30_000);
setInterval(() => {
  const last = throughputWindow[throughputWindow.length - 1];
  if (!last || Date.now() - last.at > 2000) el.throughput.textContent = "";
}, 1000);
