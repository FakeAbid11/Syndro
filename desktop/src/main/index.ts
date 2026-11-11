import { app, BrowserWindow, shell } from "electron";
import { randomUUID } from "node:crypto";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { advertise, type Discovery } from "./discovery";
import { createShareToken, startServer, type RunningServer } from "./server";

const PREFERRED_PORT = 47821;

let mainWindow: BrowserWindow | null = null;
let running: RunningServer | null = null;
let discovery: Discovery | null = null;

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

function createWindow(port: number, token: string): BrowserWindow {
  const window = new BrowserWindow({
    width: 1120,
    height: 780,
    minWidth: 420,
    minHeight: 560,
    backgroundColor: "#0b0b0c",
    title: "Syndro",
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  window.once("ready-to-show", () => window.show());
  window.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });

  // A loopback URL keeps the window identical to browser mode, so there is
  // exactly one UI implementation and one API to test.
  void window.loadURL(`http://127.0.0.1:${port}/s/${token}`);
  return window;
}

async function main(): Promise<void> {
  await app.whenReady();

  if (process.platform === "win32") {
    app.setAppUserModelId("dev.syndro.app");
  }

  const storeDir = path.join(app.getPath("downloads"), "Syndro");
  await fsp.mkdir(storeDir, { recursive: true });
  const deviceName = process.env.SYNDRO_NAME?.trim() || os.hostname();

  running = await startServer({
    token: createShareToken(),
    deviceName,
    port: PREFERRED_PORT,
    storeDir,
    webDir: webDirectory(),
  });

  discovery = advertise({
    id: await installationId(),
    name: deviceName,
    port: running.port,
  });

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
  discovery?.stop();
  discovery = null;
  if (running) {
    void running.close();
    running = null;
  }
});
