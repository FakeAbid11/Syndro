import { BrowserWindow, shell } from "electron";
import * as path from "node:path";

export function createWindow(port: number, token: string, show = true): BrowserWindow {
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
      nodeIntegrationInSubFrames: false,
      preload: path.join(__dirname, "preload.js"),
    },
  });

  if (show) window.once("ready-to-show", () => window.show());
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url);
    return { action: "deny" };
  });

  // The same UI serves browsers; only the guarded native bridge can send to
  // another device. Never give a remote page this window's IPC privileges.
  const ownerUrl = `http://127.0.0.1:${port}/s/${token}`;
  window.webContents.on("will-navigate", (event, url) => {
    if (url !== ownerUrl) event.preventDefault();
  });
  window.webContents.on("will-redirect", (event, url) => {
    if (url !== ownerUrl) event.preventDefault();
  });
  void window.loadURL(ownerUrl);
  return window;
}
