import { ipcMain, type BrowserWindow, type IpcMainInvokeEvent } from "electron";
import type { NativeSender, UploadMetadata } from "./sender";

const CHANNELS = ["syndro:connect", "syndro:disconnect", "syndro:begin", "syndro:append", "syndro:complete", "syndro:abort"];

/** A remote browser, child frame, or another Electron window is not an owner. */
export function registerSenderBridge(
  sender: NativeSender,
  owner: () => BrowserWindow | null,
  ownerUrl: string,
): () => void {
  function requireOwner(event: IpcMainInvokeEvent): NativeSender {
    const frame = event.senderFrame;
    if (!frame || event.sender !== owner()?.webContents || frame.url !== ownerUrl || frame.parent !== null) {
      throw new Error("Desktop sending is available only in Syndro's own window.");
    }
    return sender;
  }

  ipcMain.handle("syndro:connect", (event, url: string) => {
    const native = requireOwner(event);
    if (typeof url !== "string" || url.length > 2048) throw new Error("Invalid receiver link.");
    return native.connect(url);
  });
  ipcMain.handle("syndro:disconnect", (event) => requireOwner(event).disconnect());
  ipcMain.handle("syndro:begin", (event, receiverId: string, metadata: UploadMetadata) =>
    requireOwner(event).beginUpload(receiverId, metadata));
  ipcMain.handle("syndro:append", (event, id: string, offset: number, bytes: ArrayBuffer) =>
    requireOwner(event).appendUpload(id, offset, bytes));
  ipcMain.handle("syndro:complete", (event, id: string) => requireOwner(event).completeUpload(id));
  ipcMain.handle("syndro:abort", (event, id: string) => requireOwner(event).abortUpload(id));

  return () => CHANNELS.forEach((channel) => ipcMain.removeHandler(channel));
}
