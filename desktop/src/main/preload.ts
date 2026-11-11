import { contextBridge, ipcRenderer } from "electron";
import type { DesktopBridge } from "./sender";

// Sandbox-compatible preload: its only runtime dependency is Electron.
const bridge: DesktopBridge = {
  connect: (url) => ipcRenderer.invoke("syndro:connect", url),
  disconnect: () => ipcRenderer.invoke("syndro:disconnect"),
  beginUpload: (receiverId, metadata) => ipcRenderer.invoke("syndro:begin", receiverId, metadata),
  appendUpload: (id, offset, bytes) => ipcRenderer.invoke("syndro:append", id, offset, bytes),
  completeUpload: (id) => ipcRenderer.invoke("syndro:complete", id),
  abortUpload: (id) => ipcRenderer.invoke("syndro:abort", id),
};

contextBridge.exposeInMainWorld("syndro", bridge);
