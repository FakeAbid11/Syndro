import assert from "node:assert/strict";
import { File as NodeFile } from "node:buffer";
import * as fsp from "node:fs/promises";
import * as path from "node:path";
import { test, type TestContext } from "node:test";
import { JSDOM } from "jsdom";
import { NativeSender, type DesktopBridge } from "../main/sender";
import { fixture, listFiles, upload, WEB_DIR, type Fixture } from "./helpers";

interface Hooks {
  enqueue: (files: NodeFile[]) => Promise<void> | undefined;
  refreshInfo: () => Promise<void>;
  connectReceiver: () => Promise<void>;
  disconnectReceiver: () => Promise<void>;
  setMode: (mode: string) => void;
}

function nativeBridge(sender: NativeSender): DesktopBridge {
  return {
    connect: (url) => sender.connect(url),
    disconnect: async () => sender.disconnect(),
    beginUpload: (id, metadata) => sender.beginUpload(id, metadata),
    appendUpload: (id, offset, bytes) => sender.appendUpload(id, offset, bytes),
    completeUpload: (id) => sender.completeUpload(id),
    abortUpload: (id) => sender.abortUpload(id),
  };
}

async function uiFixture(
  t: TestContext,
  host: Fixture,
  options: {
    bridge?: DesktopBridge;
    owned?: string;
    storageBlocked?: boolean;
    beforeCompleteResponse?: () => Promise<void>;
  } = {},
) {
  const [html, script] = await Promise.all([
    fsp.readFile(path.join(WEB_DIR, "index.html"), "utf8"),
    fsp.readFile(path.join(WEB_DIR, "assets", "app.js"), "utf8"),
  ]);
  const dom = new JSDOM(html, { url: host.shareUrl, runScripts: "outside-only" });
  t.after(() => dom.window.close());
  const requests: Array<{ pathname: string; method: string; headers: Headers }> = [];
  Object.defineProperty(dom.window, "fetch", {
    value: async (input: string, init: Parameters<typeof fetch>[1] = {}) => {
      const url = new URL(input, host.base);
      requests.push({ pathname: url.pathname, method: init.method || "GET", headers: new Headers(init.headers) });
      const response = await fetch(url, init);
      if (url.pathname.endsWith("/complete")) await options.beforeCompleteResponse?.();
      return response;
    },
  });
  Object.defineProperty(dom.window, "AbortController", { value: AbortController });
  Object.defineProperty(dom.window, "EventSource", {
    value: class {
      addEventListener(): void { /* Refreshes are driven explicitly in DOM tests. */ }
    },
  });
  if (options.bridge) Object.defineProperty(dom.window, "syndro", { value: options.bridge });
  if (options.storageBlocked) {
    Object.defineProperty(dom.window, "sessionStorage", { get: () => { throw new Error("Storage blocked"); } });
  } else if (options.owned) {
    dom.window.sessionStorage.setItem(`syndro-owned:${host.server.token}`, options.owned);
  }
  // Expected error paths should be asserted through the visible UI, not dumped
  // into the test runner. Actual Electron console errors fail the smoke test.
  dom.window.console.error = () => undefined;
  dom.window.eval(`${script}\nwindow.__syndroTest = { enqueue, refreshInfo, connectReceiver, disconnectReceiver, setMode };`);
  const hooks = (dom.window as unknown as { __syndroTest: Hooks }).__syndroTest;
  await hooks.refreshInfo();
  const document = dom.window.document;
  return {
    dom, document, hooks, requests,
    link: document.getElementById("receiver-link") as HTMLInputElement,
    text: (selector: string) => document.querySelector(selector)?.textContent,
    rows: (selector: string) => [...document.querySelectorAll(selector)],
  };
}

test("desktop sending is disabled until a receiver is verified", async (t) => {
  const host = await fixture(t);
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const ui = await uiFixture(t, host, { bridge: nativeBridge(sender) });
  assert.equal(ui.document.getElementById("desktop-controls")?.hidden, false);
  assert.equal(ui.document.getElementById("mode-send")?.getAttribute("aria-pressed"), "true");
  assert.equal(ui.document.getElementById("drop")?.getAttribute("aria-disabled"), "true");
  await ui.hooks.enqueue([new NodeFile(["x"], "not-sent.txt")]);
  assert.equal(ui.rows("#outgoing .row").length, 0);
  assert.deepEqual(await listFiles(host), []);
  ui.link.value = host.shareUrl;
  await ui.hooks.connectReceiver();
  assert.match(ui.text("#receiver-state") || "", /own link/);
  assert.equal(ui.document.getElementById("drop")?.getAttribute("aria-disabled"), "true");
});

test("direct sending never creates a local received file or a redundant Save action", async (t) => {
  const host = await fixture(t);
  const remote = await fixture(t, { deviceName: "Test phone", serverId: "phone-id" });
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const ui = await uiFixture(t, host, { bridge: nativeBridge(sender) });
  ui.link.value = remote.shareUrl;
  await ui.hooks.connectReceiver();
  assert.equal(ui.document.getElementById("drop")?.getAttribute("aria-disabled"), "false");
  await ui.hooks.enqueue([new NodeFile(["to phone"], "sent.txt", { type: "text/plain" })]);
  assert.equal(ui.text("#outgoing .row-state"), "Sent");
  assert.equal(ui.text("#outgoing .row-destination"), "To Test phone");
  assert.equal(ui.rows("#outgoing .download, #received .row, #shared .row").length, 0);
  assert.equal(ui.requests.filter((request) => request.method !== "GET").length, 0);
  assert.deepEqual(await listFiles(host), []);
  assert.equal((await listFiles(remote))[0]?.name, "sent.txt");
});

test("queued transfers keep the same destination and show Sent only after confirmation", async (t) => {
  const host = await fixture(t);
  const remote = await fixture(t, { deviceName: "Selected phone", serverId: "phone-id" });
  const other = await fixture(t, { deviceName: "Other phone", serverId: "other-id" });
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const bridge = nativeBridge(sender);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let confirming!: () => void;
  const confirmationStarted = new Promise<void>((resolve) => { confirming = resolve; });
  bridge.completeUpload = async (id) => {
    confirming();
    await gate;
    return sender.completeUpload(id);
  };
  t.after(release);
  const ui = await uiFixture(t, host, { bridge });
  ui.link.value = remote.shareUrl;
  await ui.hooks.connectReceiver();
  const transfers = ui.hooks.enqueue([new NodeFile(["one"], "one.txt"), new NodeFile(["two"], "two.txt")]);
  await confirmationStarted;
  assert.equal(ui.rows("#outgoing .done").length, 0);
  assert.equal(ui.text("#outgoing .row:last-child .row-state"), "Confirming");
  assert.equal((ui.document.getElementById("mode-share") as HTMLButtonElement).disabled, true);
  assert.equal((ui.document.getElementById("receiver-disconnect") as HTMLButtonElement).disabled, true);
  ui.hooks.setMode("share");
  ui.link.value = other.shareUrl;
  await ui.hooks.connectReceiver();
  await ui.hooks.disconnectReceiver();
  assert.equal(ui.document.getElementById("mode-send")?.getAttribute("aria-pressed"), "true");
  release();
  await transfers;
  assert.equal(ui.rows("#outgoing .done").length, 2);
  assert.deepEqual((await listFiles(remote)).map((file) => file.name).sort(), ["one.txt", "two.txt"]);
  assert.deepEqual(await listFiles(other), []);
  assert.deepEqual(await listFiles(host), []);
});

test("a failed connection clears the UI destination instead of keeping the previous one", async (t) => {
  const host = await fixture(t);
  const remote = await fixture(t, { serverId: "remote-id" });
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const ui = await uiFixture(t, host, { bridge: nativeBridge(sender) });
  ui.link.value = remote.shareUrl;
  await ui.hooks.connectReceiver();
  ui.link.value = "not a share link";
  await ui.hooks.connectReceiver();
  assert.equal(ui.document.getElementById("drop")?.getAttribute("aria-disabled"), "true");
  assert.match(ui.text("#receiver-state") || "", /full http/);
  await ui.hooks.enqueue([new NodeFile(["x"], "not-sent.txt")]);
  assert.deepEqual(await listFiles(remote), []);
});

test("local publishing says Shared, appears once, and has no Save action", async (t) => {
  const host = await fixture(t);
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const ui = await uiFixture(t, host, { bridge: nativeBridge(sender) });
  ui.hooks.setMode("share");
  await ui.hooks.enqueue([new NodeFile(["local"], "published.txt")]);
  assert.match(ui.text("#transfer-hint") || "", /Sharing is not delivery/);
  assert.equal(ui.text("#shared .row-state"), "Shared");
  assert.equal(ui.rows("#shared .row").length, 1);
  assert.equal(ui.rows("#outgoing .row, #received .row, #shared .download").length, 0);
  assert.equal(ui.requests.find((request) => request.method === "POST")?.headers.get("x-syndro-purpose"), "share");
  assert.equal((await listFiles(host))[0]?.origin, "shared");
  await ui.hooks.refreshInfo();
  assert.equal(ui.rows("#shared .row").length, 1);
});

test("received and legacy files are separate from files this desktop shared", async (t) => {
  const id = "a".repeat(24);
  const host = await fixture(t, {}, async (dir) => {
    const filePath = path.join(dir, "files", id);
    await fsp.mkdir(path.dirname(filePath));
    await fsp.writeFile(filePath, "old");
    await fsp.writeFile(`${filePath}.json`, JSON.stringify({
      id, name: "old.txt", size: 3, mime: "text/plain", path: filePath, receivedAt: 1,
    }));
  });
  await upload(host, "incoming.txt", new Uint8Array());
  await upload(host, "published.txt", new Uint8Array(), true);
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const ui = await uiFixture(t, host, { bridge: nativeBridge(sender) });
  assert.equal(ui.text("#files-title"), "Received");
  assert.equal(ui.text("#received .row-name"), "incoming.txt");
  assert.equal(ui.rows("#received .download").length, 1);
  assert.equal(ui.text("#shared .row-name"), "published.txt");
  assert.equal(ui.rows("#shared .download").length, 0);
  assert.equal(ui.text("#earlier .row-name"), "old.txt");
  assert.match(ui.text("#earlier .row-destination") || "", /wasn't recorded/);
  assert.equal(ui.rows("#received .row, #shared .row, #earlier .row").length, 3);
});

test("browser uploads are hidden before completion refresh and remain hidden after reload", async (t) => {
  const host = await fixture(t, { deviceName: "Hosting PC" });
  await upload(host, "from-host.txt", new Uint8Array(), true);
  let ui!: Awaited<ReturnType<typeof uiFixture>>;
  let checkedEarly = false;
  ui = await uiFixture(t, host, {
    beforeCompleteResponse: async () => {
      await ui.hooks.refreshInfo();
      assert.equal(ui.text("#received .row-name"), "from-host.txt");
      assert.equal(ui.rows("#received .row").length, 1);
      assert.equal(ui.text("#outgoing .row-state"), "Confirming");
      checkedEarly = true;
    },
  });
  assert.equal(ui.text("#files-title"), "Available to download");
  assert.equal(ui.document.getElementById("desktop-controls")?.hidden, true);
  await ui.hooks.enqueue([new NodeFile(["browser upload"], "from-browser.txt")]);
  assert.equal(checkedEarly, true);
  assert.equal(ui.text("#outgoing .row-state"), "Sent");
  assert.equal(ui.text("#outgoing .row-destination"), "To Hosting PC");
  assert.equal(ui.rows("#outgoing .download").length, 0);
  assert.equal(ui.requests.find((request) => request.method === "POST")?.headers.has("x-syndro-purpose"), false);
  const owned = ui.dom.window.sessionStorage.getItem(`syndro-owned:${host.server.token}`) || "[]";
  assert.equal(JSON.parse(owned).length, 1);
  const reloaded = await uiFixture(t, host, { owned });
  assert.equal(reloaded.rows("#received .row").length, 1);
  assert.equal(reloaded.text("#received .row-name"), "from-host.txt");
  assert.equal((await listFiles(host)).length, 2);
});

test("blocked browser storage still hides this page's own upload", async (t) => {
  const host = await fixture(t);
  const ui = await uiFixture(t, host, { storageBlocked: true });
  await ui.hooks.enqueue([new NodeFile(["x"], "mine.txt")]);
  await ui.hooks.refreshInfo();
  assert.equal(ui.text("#outgoing .row-state"), "Sent");
  assert.equal(ui.rows("#received .row").length, 0);
});

test("unconfirmed delivery is Failed, not Sent, with a visible explanation", async (t) => {
  const host = await fixture(t);
  const remote = await fixture(t, { serverId: "remote-id" });
  const sender = new NativeSender({ port: host.server.port, serverId: "test-desktop-id" });
  const bridge = nativeBridge(sender);
  bridge.completeUpload = async () => { throw new Error("The receiver did not confirm the completed file."); };
  const ui = await uiFixture(t, host, { bridge });
  ui.link.value = remote.shareUrl;
  await ui.hooks.connectReceiver();
  await ui.hooks.enqueue([new NodeFile(["x"], "unconfirmed.txt")]);
  assert.equal(ui.text("#outgoing .row-state"), "Failed");
  assert.match(ui.text("#outgoing .row-error") || "", /did not confirm/);
  assert.equal(ui.rows("#outgoing .done").length, 0);
  assert.deepEqual(await listFiles(remote), []);
  assert.deepEqual(await listFiles(host), []);
  await ui.hooks.disconnectReceiver();
  assert.equal(ui.document.getElementById("drop")?.getAttribute("aria-disabled"), "true");
});
