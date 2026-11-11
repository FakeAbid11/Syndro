import { app, BrowserWindow } from "electron";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fsp from "node:fs/promises";
import * as path from "node:path";
import type { RunningServer } from "../main/server";
import type { PublicFile } from "../main/store";

async function within<T>(promise: Promise<T>, label: string, milliseconds = 20_000): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_resolve, reject) => {
      timeout = setTimeout(() => reject(new Error(`${label} timed out.`)), milliseconds);
    })]);
  } finally {
    clearTimeout(timeout);
  }
}

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

interface Presentation {
  columns: number;
  overflow: boolean;
  labels: Array<{ text: string; size: number; tracking: string; transform: string }>;
  controls: Array<{ text: string; height: number; width: number }>;
}

async function checkPresentation(window: BrowserWindow, columns: number, minimum: number): Promise<void> {
  const presentation = await window.webContents.executeJavaScript(`(() => {
    const visible = (selector) => [...document.querySelectorAll(selector)]
      .filter((element) => element.getClientRects().length > 0);
    return {
      columns: getComputedStyle(document.querySelector('.layout')).gridTemplateColumns.split(' ').length,
      overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      labels: visible('h2, h3, .copy, .download, .tag, .row-state, .row-size, .row-destination, .hint, .drop-sub')
        .map((element) => {
          const style = getComputedStyle(element);
          return { text: element.textContent, size: parseFloat(style.fontSize),
            tracking: style.letterSpacing, transform: style.textTransform };
        }),
      controls: visible('.copy, .download, .transfer-modes button, .receiver button, .receiver input')
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return { text: element.getAttribute('aria-label') || element.textContent || element.id,
            height: rect.height, width: rect.width };
        }),
    };
  })()`) as Presentation;
  assert.equal(presentation.columns, columns);
  assert.equal(presentation.overflow, false, "The UI must not scroll horizontally.");
  assert.ok(presentation.labels.length > 0 && presentation.controls.length > 0);
  for (const label of presentation.labels) {
    assert.ok(label.size >= 12, `Unreadable label: ${label.text}`);
    assert.ok(label.tracking === "normal" || parseFloat(label.tracking) === 0, `Tracked label: ${label.text}`);
    assert.notEqual(label.transform, "uppercase", `Uppercase treatment: ${label.text}`);
  }
  for (const control of presentation.controls) {
    assert.ok(control.height >= minimum && control.width >= minimum, `Small target: ${control.text}`);
  }

  // Use real keyboard input so :focus-visible is exercised, not just :focus.
  window.show();
  window.focus();
  window.webContents.focus();
  window.webContents.sendInputEvent({ type: "keyDown", keyCode: "Tab" });
  window.webContents.sendInputEvent({ type: "keyUp", keyCode: "Tab" });
  const focus = await window.webContents.executeJavaScript(`(() => {
    const elements = [...document.querySelectorAll('.copy, .download, .transfer-modes button, .receiver button, .receiver input, #drop')]
      .filter((element) => element.getClientRects().length > 0 && !element.disabled && element.tabIndex >= 0);
    return elements.map((element) => {
      element.focus({ preventScroll: true });
      const style = getComputedStyle(element);
      const result = { text: element.getAttribute('aria-label') || element.textContent,
        visible: element.matches(':focus-visible'), width: parseFloat(style.outlineWidth), style: style.outlineStyle };
      element.blur();
      return result;
    });
  })()`) as Array<{ text: string; visible: boolean; width: number; style: string }>;
  assert.ok(focus.length > 0);
  for (const control of focus) {
    assert.ok(control.visible && control.width >= 2 && control.style === "solid", `Missing keyboard ring: ${control.text}`);
  }

  const debuggerClient = window.webContents.debugger;
  const attached = debuggerClient.isAttached();
  if (!attached) debuggerClient.attach("1.3");
  try {
    await debuggerClient.sendCommand("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    const durations = await window.webContents.executeJavaScript(`
      [...document.querySelectorAll('.drop, .copy, .download, .bar > i')]
        .map((element) => getComputedStyle(element).transitionDuration)`) as string[];
    assert.ok(durations.every((duration) => duration.split(",").every((part) => parseFloat(part) === 0)),
      "Reduced motion must disable every feedback transition.");
  } finally {
    await debuggerClient.sendCommand("Emulation.setEmulatedMedia", { features: [] });
    if (!attached) debuggerClient.detach();
  }
}

async function captureFullPage(window: BrowserWindow, file: string): Promise<void> {
  window.show();
  window.focus();
  await window.webContents.executeJavaScript(`new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(resolve)))`);
  const debuggerClient = window.webContents.debugger;
  const attached = debuggerClient.isAttached();
  if (!attached) debuggerClient.attach("1.3");
  try {
    // Capture the full actual page, not an old hidden compositor frame or a
    // crop that conceals the Received list below the runner's small display.
    const metrics = await debuggerClient.sendCommand("Page.getLayoutMetrics") as {
      cssContentSize: { width: number; height: number };
    };
    const image = await debuggerClient.sendCommand("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: Math.ceil(metrics.cssContentSize.width),
        height: Math.ceil(metrics.cssContentSize.height), scale: 1 },
    }) as { data: string };
    await fsp.writeFile(file, Buffer.from(image.data, "base64"));
  } finally {
    if (!attached) debuggerClient.detach();
  }
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
  let browser: BrowserWindow | null = null;
  let passed = false;
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
    // CI's inactive/covered windows still need to paint for visual assertions.
    // This changes only the test scheduler, not the shipped window settings.
    owner.webContents.setBackgroundThrottling(false);
    await loaded(owner);
    await waitFor(owner, `document.querySelector('#peer-name').textContent === 'Smoke desktop'`);
    assert.deepEqual(await owner.webContents.executeJavaScript(`({
      bridge: typeof window.syndro.connect, node: typeof window.require,
      disabled: document.querySelector('#drop').getAttribute('aria-disabled'),
      mode: document.querySelector('#mode-send').textContent,
      receiving: document.querySelector('#pair-title').textContent
    })`), { bridge: "function", node: "undefined", disabled: "true", mode: "App to app", receiving: "Receive on this device" });
    const renderer = app.getAppMetrics().find((metric) => metric.pid === owner?.webContents.getOSProcessId());
    assert.equal(renderer?.sandboxed, true);
    // Check the editable receiver field and Connect button before selecting a
    // receiver; the final Share-mode check covers the drop area and Save links.
    await within(checkPresentation(owner, 2, 40), "Desktop presentation before pairing");

    await owner.webContents.executeJavaScript(`document.querySelector('#receiver-link').value = ${JSON.stringify(ownerUrl)};
      document.querySelector('#receiver-connect').click();`);
    await waitFor(owner, `document.querySelector('#receiver-state').textContent.includes('own link')`);
    await owner.webContents.executeJavaScript(`document.querySelector('#receiver-link').value = ${JSON.stringify(receiverUrl)};
      document.querySelector('#receiver-connect').click();`);
    await waitFor(owner, `document.querySelector('#drop').getAttribute('aria-disabled') === 'false' &&
      document.querySelector('#receiver-state').textContent.startsWith('Paired with Selected phone')`);

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
    await owner.webContents.executeJavaScript(`document.querySelector('#mode-send').click()`);
    assert.deepEqual(await owner.webContents.executeJavaScript(`({
      selected: document.querySelector('#mode-send').getAttribute('aria-pressed'),
      pairingHidden: document.querySelector('#receiver-panel').hidden,
      paired: document.querySelector('#receiver-state').textContent.startsWith('Paired with Selected phone')
    })`), { selected: "true", pairingHidden: false, paired: true });
    await within(checkPresentation(owner, 2, 40), "Desktop presentation after transfers");

    // This window has no preload: it is genuinely browser mode, not a second
    // desktop window whose sender bridge merely rejects IPC calls.
    browser = new BrowserWindow({ width: 430, height: 760, show: false,
      backgroundColor: "#0b0b0c",
      webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false } });
    observe(browser);
    // A fresh hidden window has no initialized page/view to acknowledge a
    // viewport override. Load and show it before requesting mobile metrics.
    await within(browser.webContents.loadURL(ownerUrl), "Mobile browser page load");
    browser.show();
    browser.webContents.debugger.attach("1.3");
    await within(browser.webContents.debugger.sendCommand("Emulation.setDeviceMetricsOverride", {
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true,
    }), "Mobile viewport setup");
    await within(waitFor(browser, `document.querySelector('#peer-name').textContent === 'Smoke desktop' &&
      document.querySelectorAll('#received .download').length === 2`), "Mobile file list");
    assert.deepEqual(await browser.webContents.executeJavaScript(`({
      bridge: typeof window.syndro, controlsHidden: document.querySelector('#desktop-controls').hidden,
      title: document.querySelector('#files-title').textContent, code: document.querySelector('#pair-code').textContent
    })`), { bridge: "undefined", controlsHidden: true, title: "Available to download", code: "ABCD 2345" });
    await within(checkPresentation(browser, 1, 44), "Mobile presentation");
    assert.deepEqual(errors, []);
    passed = true;
    console.log("Packaged Electron smoke passed: app-to-app pairing, sandbox preload, guarded IPC, real File chunks, honest lists, desktop/mobile layout, keyboard focus, and reduced motion.");
  } catch (error) {
    // Report assertions now: an unavailable compositor must not conceal the
    // original failure behind the screenshot deadline or runner timeout.
    console.error("Packaged Electron checks failed before capture:", error);
    throw error;
  } finally {
    let captureError: unknown;
    for (const [window, file] of [[owner, screenshot],
      [browser, path.join(path.dirname(screenshot), "electron-smoke-mobile.png")]] as const) {
      if (window && !window.isDestroyed()) {
        try {
          console.log(`Capturing ${path.basename(file)}`);
          await within(captureFullPage(window, file), `Capture ${path.basename(file)}`);
        } catch (error) {
          captureError ??= error;
          console.error("UI capture failed", error);
        }
      }
    }
    unregister?.();
    for (const window of windows) if (!window.isDestroyed()) window.destroy();
    for (const server of servers) await server.close();
    // Preserve an original test failure, but never silently skip screenshots
    // when the checks passed: CI must provide the images for visual review.
    if (passed && captureError) throw captureError;
  }
}

void run().then(() => app.exit(0), (error: unknown) => {
  console.error("Packaged Electron smoke failed:", error);
  app.exit(1);
});
