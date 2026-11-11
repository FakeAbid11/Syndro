import { app, type BrowserWindow } from "electron";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fsp from "node:fs/promises";
import * as path from "node:path";
import type { RunningServer } from "../main/server";
import type { PublicFile } from "../main/store";

function loaded(window: BrowserWindow): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("The packaged UI did not load.")), 20_000);
    window.webContents.once("did-finish-load", () => { clearTimeout(timeout); resolve(); });
  });
}

async function waitFor(window: BrowserWindow, expression: string): Promise<void> {
  await window.webContents.executeJavaScript(`new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      observer.disconnect();
      reject(new Error("UI condition timed out: " + ${JSON.stringify(expression)} + "\\n" + document.body.innerText));
    }, 15000);
    const observer = new MutationObserver(check);
    function check() {
      if (${expression}) {
        clearTimeout(timeout);
        observer.disconnect();
        resolve();
      }
    }
    observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    check();
  })`);
}

async function files(server: RunningServer): Promise<PublicFile[]> {
  const response = await fetch(`http://127.0.0.1:${server.port}/api/files?t=${server.token}`);
  assert.equal(response.status, 200);
  return ((await response.json()) as { files: PublicFile[] }).files;
}

async function run(): Promise<void> {
  const [, , archive, webDir, root, screenshot] = process.argv;
  assert.ok(archive && webDir && root && screenshot, "Smoke-test paths must be provided by the runner.");
  // Electron understands asar paths. All runtime modules below come from the
  // same archive as the installer, including the sandbox-compatible preload.
  const { startServer } = require(path.join(archive, "dist/main/server.js")) as typeof import("../main/server");
  const { NativeSender, SEND_CHUNK_SIZE } = require(path.join(archive, "dist/main/sender.js")) as typeof import("../main/sender");
  const { registerSenderBridge } = require(path.join(archive, "dist/main/bridge.js")) as typeof import("../main/bridge");
  const { createWindow } = require(path.join(archive, "dist/main/window.js")) as typeof import("../main/window");
  await fsp.mkdir(path.join(root, "userData"), { recursive: true });
  app.setPath("userData", path.join(root, "userData"));
  app.disableHardwareAcceleration();
  await app.whenReady();

  const servers: RunningServer[] = [];
  const windows: BrowserWindow[] = [];
  const errors: string[] = [];
  let owner: BrowserWindow | null = null;
  let unregister: (() => void) | undefined;
  const observe = (window: BrowserWindow) => {
    windows.push(window);
    window.webContents.on("preload-error", (_event, _preload, error) => errors.push(error.message));
    window.webContents.on("render-process-gone", (_event, details) => errors.push(`Renderer exited: ${details.reason}`));
    window.webContents.on("console-message", (details) => {
      if (details.level === "error") errors.push(details.message);
    });
  };

  try {
    const local = await startServer({ token: "ABCD2345", deviceName: "Smoke desktop", serverId: "desktop-smoke-id",
      host: "127.0.0.1", port: 0, storeDir: path.join(root, "desktop"), webDir });
    servers.push(local);
    const remote = await startServer({ token: "EFGH6789", deviceName: "Selected phone", serverId: "phone-smoke-id",
      host: "127.0.0.1", port: 0, storeDir: path.join(root, "phone"), webDir });
    servers.push(remote);
    const other = await startServer({ token: "JKLM2345", deviceName: "Other phone", serverId: "other-smoke-id",
      host: "127.0.0.1", port: 0, storeDir: path.join(root, "other"), webDir });
    servers.push(other);
    const ownerUrl = `http://127.0.0.1:${local.port}/s/${local.token}`;
    const receiverUrl = `http://127.0.0.1:${remote.port}/s/${remote.token}`;
    unregister = registerSenderBridge(new NativeSender({ port: local.port, serverId: "desktop-smoke-id" }), () => owner, ownerUrl);
    owner = createWindow(local.port, local.token, false);
    observe(owner);
    await loaded(owner);
    await waitFor(owner, `document.querySelector('#peer-name').textContent === 'Smoke desktop'`);
    assert.deepEqual(await owner.webContents.executeJavaScript(`({
      bridge: typeof window.syndro.connect, node: typeof window.require,
      disabled: document.querySelector('#drop').getAttribute('aria-disabled')
    })`), { bridge: "function", node: "undefined", disabled: "true" });
    const renderer = app.getAppMetrics().find((metric) => metric.pid === owner?.webContents.getOSProcessId());
    assert.equal(renderer?.sandboxed, true);

    await owner.webContents.executeJavaScript(`document.querySelector('#receiver-link').value = ${JSON.stringify(ownerUrl)};
      document.querySelector('#receiver-connect').click();`);
    await waitFor(owner, `document.querySelector('#receiver-state').textContent.includes('own link')`);
    await owner.webContents.executeJavaScript(`document.querySelector('#receiver-link').value = ${JSON.stringify(receiverUrl)};
      document.querySelector('#receiver-connect').click();`);
    await waitFor(owner, `document.querySelector('#drop').getAttribute('aria-disabled') === 'false'`);

    // A real Chromium File becomes ArrayBuffer chunks, crosses contextBridge
    // and IPC, and is written by the selected server, not the local one.
    const size = SEND_CHUNK_SIZE + 123;
    await owner.webContents.executeJavaScript(`{
      const bytes = new Uint8Array(${size});
      for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
      const transfer = new DataTransfer();
      transfer.items.add(new File([bytes], 'sent-from-desktop.bin', { type: 'application/octet-stream' }));
      const input = document.querySelector('#file');
      input.files = transfer.files;
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }`);
    await waitFor(owner, `document.querySelector('#outgoing .row-state')?.textContent === 'Sent' &&
      !document.querySelector('#mode-share').disabled`);
    const received = await files(remote);
    assert.equal(received.length, 1);
    assert.equal(received[0]?.size, size);
    assert.equal(received[0]?.origin, "received");
    const download = await fetch(`http://127.0.0.1:${remote.port}/api/files/${received[0]?.id}?t=${remote.token}`);
    const expected = Buffer.alloc(size);
    for (let i = 0; i < size; i++) expected[i] = i % 251;
    assert.equal(createHash("sha256").update(Buffer.from(await download.arrayBuffer())).digest("hex"),
      createHash("sha256").update(expected).digest("hex"));
    assert.deepEqual(await files(local), []);
    assert.deepEqual(await files(other), []);
    assert.equal(await owner.webContents.executeJavaScript(`document.querySelectorAll('#outgoing .download, #received .row').length`), 0);

    await owner.webContents.executeJavaScript(`document.querySelector('#mode-share').click();
      const transfer = new DataTransfer();
      transfer.items.add(new File(['shared locally'], 'shared-link.txt', { type: 'text/plain' }));
      const input = document.querySelector('#file');
      input.files = transfer.files;
      input.dispatchEvent(new Event('change', { bubbles: true }));`);
    await waitFor(owner, `document.querySelector('#shared .row-state')?.textContent === 'Shared' &&
      !document.querySelector('#mode-send').disabled`);
    assert.equal(await owner.webContents.executeJavaScript(`document.querySelectorAll('#shared .download, #outgoing [data-purpose="share"]').length`), 0);
    assert.equal((await files(local))[0]?.origin, "shared");

    const incomingSender = new NativeSender({ port: remote.port, serverId: "phone-smoke-id" });
    const desktop = await incomingSender.connect(ownerUrl);
    const incoming = await incomingSender.beginUpload(desktop.id, { name: "received-from-phone.txt", size: 5, mime: "text/plain" });
    await incomingSender.appendUpload(incoming.id, 0, Uint8Array.from(Buffer.from("hello")).buffer);
    await incomingSender.completeUpload(incoming.id);
    await waitFor(owner, `document.querySelector('#received .row-name')?.textContent === 'received-from-phone.txt'`);
    assert.equal(await owner.webContents.executeJavaScript(`document.querySelectorAll('#received .download').length`), 1);
    assert.equal(await owner.webContents.executeJavaScript(`new Promise((resolve) => {
      const frame = document.createElement('iframe');
      frame.hidden = true;
      frame.src = ${JSON.stringify(ownerUrl)};
      frame.onload = () => { const noBridge = typeof frame.contentWindow.syndro === 'undefined'; frame.remove(); resolve(noBridge); };
      document.body.appendChild(frame);
    })`), true);

    // Even a second window with the real preload and correct URL is rejected.
    const foreign = createWindow(local.port, local.token, false);
    observe(foreign);
    await loaded(foreign);
    const denied = await foreign.webContents.executeJavaScript(`window.syndro.connect(${JSON.stringify(receiverUrl)})
      .then(() => 'allowed', (error) => error.message)`);
    assert.match(denied, /only in Syndro's own window/);
    await owner.webContents.executeJavaScript(`history.pushState({}, '', '?not-the-owner-url=1')`);
    const wrongUrl = await owner.webContents.executeJavaScript(`window.syndro.connect(${JSON.stringify(receiverUrl)})
      .then(() => 'allowed', (error) => error.message)`);
    assert.match(wrongUrl, /only in Syndro's own window/);
    await owner.webContents.executeJavaScript(`history.replaceState({}, '', ${JSON.stringify(ownerUrl)})`);
    assert.deepEqual(errors, []);
    console.log("Packaged Electron smoke passed: sandbox preload, guarded IPC, real File chunks, selected-receiver delivery, and honest file lists.");
  } finally {
    if (owner && !owner.isDestroyed()) {
      await fsp.writeFile(screenshot, (await owner.webContents.capturePage()).toPNG()).catch(() => undefined);
    }
    unregister?.();
    for (const window of windows) if (!window.isDestroyed()) window.destroy();
    for (const server of servers) await server.close();
  }
}

void run().then(() => app.exit(0), (error: unknown) => {
  console.error("Packaged Electron smoke failed:", error);
  app.exit(1);
});
