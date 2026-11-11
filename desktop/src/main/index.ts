import { app, type BrowserWindow } from "electron";
import { randomUUID } from "node:crypto";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { advertise, type Discovery } from "./discovery";
import { registerSenderBridge } from "./bridge";
import { createShareToken, startServer, type RunningServer } from "./server";
import { NativeSender } from "./sender";
import { createWindow } from "./window";

const PREFERRED_PORT = 47821;

let mainWindow: BrowserWindow | null = null;
let running: RunningServer | null = null;
let discovery: Discovery | null = null;
let unregisterBridge: (() => void) | null = null;

async function installationId(): Promise<string> {
  const file = path.join(app.getPath("userData"), "device-id");
  try {
    const stored = (await fsp.readFile(file, "utf8")).trim();
    if (/^[0-9a-f-]{36}$/i.test(stored)) return stored;
  } catch {
    // First launch, or an unreadable old value: replace it below.
  }

  const id = randomUUID();
  await fsp.mkdir(path.dirname(file), { recursive: true });
  await fsp.writeFile(file, `${id}\n`, "utf8");
  return id;
}

function webDirectory(): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "web");
  }
  // dist/main/index.js -> desktop/web
  return path.join(__dirname, "..", "..", "web");
}

async function main(): Promise<void> {
  await app.whenReady();

  if (process.platform === "win32") {
    app.setAppUserModelId("dev.syndro.app");
  }

  const storeDir = path.join(app.getPath("downloads"), "Syndro");
  await fsp.mkdir(storeDir, { recursive: true });
  const deviceName = process.env.SYNDRO_NAME?.trim() || os.hostname();
  const serverId = await installationId();

  running = await startServer({
    token: createShareToken(),
    deviceName,
    serverId,
    port: PREFERRED_PORT,
    storeDir,
    webDir: webDirectory(),
  });

  discovery = advertise({
    id: serverId,
    name: deviceName,
    port: running.port,
  });
  unregisterBridge = registerSenderBridge(
    new NativeSender({ port: running.port, serverId }),
    () => mainWindow,
    `http://127.0.0.1:${running.port}/s/${running.token}`,
  );

  mainWindow = createWindow(running.port, running.token);
  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  app.on("activate", () => {
    if (!mainWindow && running) {
      mainWindow = createWindow(running.port, running.token);
    }
  });
}

void main().catch((error: unknown) => {
  console.error("Syndro failed to start:", error);
  app.quit();
});

app.on("window-all-closed", () => {
  app.quit();
});

app.on("before-quit", () => {
  unregisterBridge?.();
  unregisterBridge = null;
  discovery?.stop();
  discovery = null;
  if (running) {
    void running.close();
    running = null;
  }
});
