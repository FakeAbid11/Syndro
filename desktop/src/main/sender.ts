import { randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { networkInterfaces } from "node:os";
import { parseShareTarget, type ShareTarget } from "./target";
import { DEFAULT_MAX_FILE_SIZE } from "./store";

export const SEND_CHUNK_SIZE = 4 * 1024 * 1024;
const MAX_REPLY_SIZE = 2 * 1024 * 1024;
const UPLOAD_ID = /^[a-f0-9]{24}$/;

export interface Receiver {
  id: string;
  name: string;
  address: string;
}

export interface UploadMetadata {
  name: string;
  size: number;
  mime: string;
}

export interface DesktopBridge {
  connect: (url: string) => Promise<Receiver>;
  disconnect: () => Promise<void>;
  beginUpload: (receiverId: string, metadata: UploadMetadata) => Promise<{
    id: string; offset: number; chunkSize: number;
  }>;
  appendUpload: (id: string, offset: number, bytes: ArrayBuffer) => Promise<{ offset: number }>;
  completeUpload: (id: string) => Promise<{ receiver: string }>;
  abortUpload: (id: string) => Promise<void>;
}

interface Reply {
  status: number;
  body: Record<string, unknown>;
}

interface SendSession {
  target: ShareTarget;
  receiver: string;
  uploadId: string;
  size: number;
  offset: number;
  busy: boolean;
}

async function requestJson(
  target: ShareTarget,
  method: string,
  pathname: string,
  body?: Buffer,
  headers: Record<string, string> = {},
): Promise<Reply> {
  const request = target.protocol === "https:" ? httpsRequest : httpRequest;
  return new Promise((resolve, reject) => {
    const req = request({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: `${pathname}?t=${target.token}`,
      method,
      agent: false,
      signal: AbortSignal.timeout(method === "PUT" || pathname.endsWith("/complete") ? 60_000 : 8_000),
      headers: { ...headers, "content-length": String(body?.length ?? 0) },
    }, (res) => {
      const chunks: Buffer[] = [];
      let size = 0;
      res.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_REPLY_SIZE) {
          req.destroy(new Error("The receiver returned an oversized response."));
          return;
        }
        chunks.push(chunk);
      });
      res.on("error", reject);
      res.on("end", () => {
        try {
          const text = Buffer.concat(chunks).toString("utf8");
          const parsed: unknown = text ? JSON.parse(text) : {};
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            throw new Error("invalid response");
          }
          resolve({ status: res.statusCode ?? 0, body: parsed as Reply["body"] });
        } catch {
          reject(new Error("The receiver did not return a valid Syndro response."));
        }
      });
    });
    req.on("error", (error) => reject(error.name === "AbortError"
      ? new Error("The receiver timed out. Check its address, Wi-Fi, and firewall.")
      : error));
    req.end(body);
  });
}

function requireSuccess(reply: Reply): Record<string, unknown> {
  if (reply.status < 200 || reply.status >= 300) {
    const message = typeof reply.body.error === "string" ? reply.body.error : `HTTP ${reply.status}`;
    throw new Error(`Receiver rejected the request: ${message}`);
  }
  return reply.body;
}

/** Native-only transport; it is never exposed as a LAN HTTP proxy. */
export class NativeSender {
  private current: { receiver: Receiver; target: ShareTarget } | null = null;
  private readonly sessions = new Map<string, SendSession>();
  private connecting = false;
  private starting = 0;

  constructor(private readonly self: { port: number; serverId: string }) {}

  async connect(input: string): Promise<Receiver> {
    if (this.connecting || this.starting > 0 || this.sessions.size > 0) {
      throw new Error("Wait for the current transfer before changing receivers.");
    }
    // A failed connection must not silently keep sending to the old device.
    this.current = null;
    this.connecting = true;
    try {
      const target = parseShareTarget(input);
      const local = new Set(["127.0.0.1", "localhost", "::1", "::ffff:127.0.0.1"]);
      for (const entries of Object.values(networkInterfaces())) {
        for (const entry of entries ?? []) local.add(entry.address.split("%")[0].toLowerCase());
      }
      if (target.port === this.self.port && local.has(target.hostname.split("%")[0].toLowerCase())) {
        throw new Error("That is this device's own link. Paste the other device's share link.");
      }

      const info = requireSuccess(await requestJson(target, "GET", "/api/info"));
      if (info.serverId && info.serverId === this.self.serverId) {
        throw new Error("That is this device's own link. Paste the other device's share link.");
      }
      if (typeof info.deviceName !== "string" || !info.deviceName.trim() ||
          info.token !== target.token || !Array.isArray(info.files)) {
        throw new Error("That address is not a valid Syndro receiver.");
      }
      const receiver = { id: randomUUID(), name: info.deviceName.slice(0, 120), address: target.address };
      this.current = { receiver, target };
      return receiver;
    } finally {
      this.connecting = false;
    }
  }

  disconnect(): void {
    if (this.sessions.size > 0 || this.starting > 0 || this.connecting) {
      throw new Error("Wait for the current transfer before disconnecting.");
    }
    this.current = null;
  }

  async beginUpload(receiverId: string, metadata: UploadMetadata) {
    const destination = this.current;
    if (!destination || receiverId !== destination.receiver.id) {
      throw new Error("Choose and connect to a receiver before sending files.");
    }
    if (!metadata || typeof metadata.name !== "string" || typeof metadata.mime !== "string" ||
        !Number.isSafeInteger(metadata.size) || metadata.size < 0 || metadata.size > DEFAULT_MAX_FILE_SIZE) {
      throw new Error("Invalid file metadata.");
    }
    if (this.sessions.size + this.starting >= 8) throw new Error("Too many active transfers.");
    const body = Buffer.from(JSON.stringify({
      name: metadata.name.slice(0, 180), size: metadata.size, mime: metadata.mime.slice(0, 160),
    }));
    this.starting += 1;
    try {
      const created = requireSuccess(await requestJson(destination.target, "POST", "/api/uploads", body, {
        "content-type": "application/json",
      }));
      if (typeof created.id !== "string" || !UPLOAD_ID.test(created.id) || created.offset !== 0) {
        throw new Error("The receiver returned an invalid upload identifier or offset.");
      }
      const id = randomUUID();
      this.sessions.set(id, {
        target: destination.target,
        receiver: destination.receiver.name,
        uploadId: created.id,
        size: metadata.size,
        offset: 0,
        busy: false,
      });
      const offered = typeof created.chunkSize === "number" && Number.isSafeInteger(created.chunkSize) && created.chunkSize > 0
        ? created.chunkSize : SEND_CHUNK_SIZE;
      return { id, offset: 0, chunkSize: Math.min(offered, SEND_CHUNK_SIZE) };
    } finally {
      this.starting -= 1;
    }
  }

  async appendUpload(id: string, offset: number, bytes: ArrayBuffer): Promise<{ offset: number }> {
    const session = this.session(id);
    if (!(bytes instanceof ArrayBuffer) || !Number.isSafeInteger(offset) || offset < 0 ||
        bytes.byteLength < 1 || bytes.byteLength > SEND_CHUNK_SIZE || offset + bytes.byteLength > session.size) {
      throw new Error("Invalid transfer chunk.");
    }
    if (session.busy) throw new Error("A chunk is already being sent.");
    session.busy = true;
    try {
      const reply = await requestJson(session.target, "PUT", `/api/uploads/${session.uploadId}`,
        Buffer.from(bytes), { "x-syndro-offset": String(offset) });
      const accepted = reply.status === 409 ? reply.body.expected : requireSuccess(reply).offset;
      if (typeof accepted !== "number" || !Number.isSafeInteger(accepted) || accepted < 0 || accepted > session.size ||
          (reply.status !== 409 && accepted !== offset + bytes.byteLength)) {
        throw new Error("The receiver returned an invalid resume offset.");
      }
      session.offset = accepted;
      return { offset: session.offset };
    } finally {
      session.busy = false;
    }
  }

  async completeUpload(id: string): Promise<{ receiver: string }> {
    const session = this.session(id);
    if (session.busy || session.offset !== session.size) throw new Error("The transfer is incomplete.");
    session.busy = true;
    try {
      const body = requireSuccess(await requestJson(session.target, "POST", `/api/uploads/${session.uploadId}/complete`));
      const file = body.file as Record<string, unknown> | undefined;
      if (!file || file.id !== session.uploadId || file.size !== session.size) {
        throw new Error("The receiver did not confirm the completed file.");
      }
      this.sessions.delete(id);
      return { receiver: session.receiver };
    } finally {
      session.busy = false;
    }
  }

  async abortUpload(id: string): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) return;
    if (session.busy) throw new Error("Wait for the active chunk before cancelling.");
    this.sessions.delete(id);
    await requestJson(session.target, "DELETE", `/api/uploads/${session.uploadId}`);
  }

  private session(id: string): SendSession {
    const session = this.sessions.get(id);
    if (!session) throw new Error("Unknown outgoing transfer.");
    return session;
  }
}
