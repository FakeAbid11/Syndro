import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { EventEmitter } from "node:events";
import { createServer, type IncomingMessage, type Server } from "node:http";
import * as fsp from "node:fs/promises";
import * as fs from "node:fs";
import * as path from "node:path";
import { toString as qrToSvg } from "qrcode";
import { preferredUrls, pickShareUrl } from "./netx";
import {
  StoreNotFoundError,
  TransferStore,
  UploadConflictError,
  UploadLimitError,
  contentDisposition,
  publicFile,
} from "./store";

export interface ServerOptions {
  token: string;
  deviceName: string;
  /** Path to the static web UI directory. */
  webDir: string;
  /** Where received files are stored. */
  storeDir: string;
  port?: number;
  /** Override the bind address. Defaults to `::` with an IPv4 fallback. */
  host?: string;
  ttlMs?: number;
  maxFileSize?: number;
  maxChunkSize?: number;
  onFileReceived?: (file: { id: string; name: string; size: number }) => void;
}

export interface RunningServer {
  port: number;
  host: string;
  token: string;
  urls: ReturnType<typeof preferredUrls>;
  close: () => Promise<void>;
}

interface TransferEvent {
  type: string;
  [key: string]: unknown;
}

const MAX_JSON_BODY = 64 * 1024;
const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_MAX_CHUNK = 16 * 1024 * 1024;
const AUTH_FAILURE_WINDOW_MS = 60_000;
const AUTH_FAILURE_LIMIT = 12;

function json(res: import("node:http").ServerResponse, status: number, body: unknown): void {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(data.length),
    "cache-control": "no-store",
  });
  res.end(data);
}

function secureEquals(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  // timingSafeEqual requires equal lengths; hash first so length never leaks.
  const leftHash = createHash("sha256").update(left).digest();
  const rightHash = createHash("sha256").update(right).digest();
  return timingSafeEqual(leftHash, rightHash);
}

async function readBody(req: IncomingMessage, limit: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;

    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > limit) {
        reject(new UploadLimitError("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function listen(server: Server, host: string, port: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const onError = (error: Error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      const address = server.address();
      if (address && typeof address === "object") resolve(address.port);
      else reject(new Error("server did not report a port"));
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen({ host, port, ipv6Only: false });
  });
}

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  const ttlMs = options.ttlMs ?? DEFAULT_TTL_MS;
  const maxChunkSize = options.maxChunkSize ?? DEFAULT_MAX_CHUNK;
  const store = new TransferStore(options.storeDir, options.maxFileSize);
  await store.init();

  const events = new EventEmitter();
  events.setMaxListeners(64);

  const expiresAt = Date.now() + ttlMs;
  const authFailures = new Map<string, { count: number; resetAt: number }>();

  const requestPathSuffix = `/s/${options.token}`;

  function emit(event: TransferEvent): void {
    events.emit("event", event);
  }

  function clientKey(req: IncomingMessage): string {
    return req.socket.remoteAddress ?? "unknown";
  }

  function tooManyFailures(req: IncomingMessage): boolean {
    const key = clientKey(req);
    const entry = authFailures.get(key);
    if (!entry) return false;
    if (Date.now() > entry.resetAt) {
      authFailures.delete(key);
      return false;
    }
    return entry.count >= AUTH_FAILURE_LIMIT;
  }

  function recordFailure(req: IncomingMessage): void {
    const key = clientKey(req);
    const now = Date.now();
    const entry = authFailures.get(key);
    if (!entry || now > entry.resetAt) {
      authFailures.set(key, { count: 1, resetAt: now + AUTH_FAILURE_WINDOW_MS });
      return;
    }
    entry.count += 1;
  }

  function tokenFrom(req: IncomingMessage, url: URL): string | null {
    const header = req.headers["x-syndro-token"];
    if (typeof header === "string" && header.length > 0) return header;
    return url.searchParams.get("t");
  }

  function authorized(req: IncomingMessage, url: URL): boolean {
    const provided = tokenFrom(req, url);
    if (!provided) return false;
    if (!secureEquals(provided, options.token)) {
      recordFailure(req);
      return false;
    }
    return true;
  }

  function expired(): boolean {
    return Date.now() > expiresAt;
  }

  function localUrls(): ReturnType<typeof preferredUrls> {
    return preferredUrls(currentPort, undefined, requestPathSuffix);
  }

  let currentPort = options.port ?? 0;

  const server = createServer((req, res) => {
    void handle(req, res).catch((error: unknown) => {
      if (res.headersSent) {
        res.end();
        return;
      }
      if (error instanceof UploadLimitError) {
        json(res, 413, { error: error.message });
        return;
      }
      if (error instanceof UploadConflictError) {
        json(res, 409, { error: "offset mismatch", expected: error.expected });
        return;
      }
      if (error instanceof StoreNotFoundError) {
        json(res, 404, { error: error.message });
        return;
      }
      json(res, 500, { error: "internal error" });
    });
  });

  async function handle(req: IncomingMessage, res: import("node:http").ServerResponse) {
    const url = new URL(req.url ?? "/", "http://localhost");
    const method = req.method ?? "GET";
    const pathname = decodeURIComponent(url.pathname);

    // ---- unauthenticated: page shell and its static assets -----------------
    if (method === "GET" && pathname === "/") {
      res.writeHead(302, { location: requestPathSuffix });
      res.end();
      return;
    }

    if (method === "GET" && pathname === "/favicon.ico") {
      res.writeHead(204);
      res.end();
      return;
    }

    if (method === "GET" && pathname.startsWith("/assets/")) {
      const name = pathname.slice("/assets/".length);
      if (!/^[a-zA-Z0-9._-]+$/.test(name) || name.includes("..")) {
        json(res, 404, { error: "not found" });
        return;
      }
      const filePath = path.join(options.webDir, "assets", name);
      const ext = path.extname(name).toLowerCase();
      const type =
        ext === ".js"
          ? "text/javascript; charset=utf-8"
          : ext === ".css"
            ? "text/css; charset=utf-8"
            : ext === ".svg"
              ? "image/svg+xml"
              : "application/octet-stream";
      try {
        const data = await fsp.readFile(filePath);
        res.writeHead(200, {
          "content-type": type,
          "content-length": String(data.length),
          "cache-control": "no-cache",
        });
        res.end(data);
      } catch {
        json(res, 404, { error: "not found" });
      }
      return;
    }

    if (method === "GET" && pathname === requestPathSuffix) {
      // The token is the capability. An unauthenticated visitor sees nothing.
      try {
        const html = await fsp.readFile(path.join(options.webDir, "index.html"));
        res.writeHead(200, {
          "content-type": "text/html; charset=utf-8",
          "content-length": String(html.length),
          "cache-control": "no-store",
          "referrer-policy": "no-referrer",
          "x-content-type-options": "nosniff",
        });
        res.end(html);
      } catch {
        json(res, 500, { error: "web UI is missing" });
      }
      return;
    }

    // ---- everything below requires the token -------------------------------
    if (tooManyFailures(req)) {
      json(res, 429, { error: "too many failed attempts, try again shortly" });
      return;
    }

    if (!authorized(req, url)) {
      json(res, 401, { error: "invalid or missing token" });
      return;
    }

    if (expired()) {
      json(res, 410, { error: "this share link has expired" });
      return;
    }

    if (method === "GET" && pathname === "/api/info") {
      json(res, 200, {
        deviceName: options.deviceName,
        token: options.token,
        expiresAt,
        urls: localUrls(),
        files: store.list().map(publicFile),
        ipv6First: true,
      });
      return;
    }

    if (method === "GET" && pathname === "/api/qr.svg") {
      const target =
        pickShareUrl(currentPort, undefined, requestPathSuffix)?.url ??
        `http://127.0.0.1:${currentPort}${requestPathSuffix}`;
      const svg = await qrToSvg(target, {
        type: "svg",
        margin: 1,
        width: 260,
        errorCorrectionLevel: "M",
        color: { dark: "#0b0b0c", light: "#ffffff" },
      });
      res.writeHead(200, {
        "content-type": "image/svg+xml; charset=utf-8",
        "cache-control": "no-store",
      });
      res.end(svg);
      return;
    }

    if (method === "GET" && pathname === "/api/events") {
      res.writeHead(200, {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform",
        connection: "keep-alive",
        "x-accel-buffering": "no",
      });
      res.write(": connected\n\n");

      const onEvent = (event: TransferEvent) => {
        res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      };
      events.on("event", onEvent);

      const heartbeat = setInterval(() => res.write(": ping\n\n"), 20_000);
      heartbeat.unref?.();

      const stop = () => {
        clearInterval(heartbeat);
        events.off("event", onEvent);
      };
      req.on("close", stop);
      res.on("close", stop);
      return;
    }

    if (method === "GET" && pathname === "/api/files") {
      json(res, 200, { files: store.list().map(publicFile) });
      return;
    }

    if (method === "POST" && pathname === "/api/uploads") {
      const body = await readBody(req, MAX_JSON_BODY);
      let parsed: { name?: unknown; size?: unknown; mime?: unknown };
      try {
        parsed = JSON.parse(body.toString("utf8") || "{}") as typeof parsed;
      } catch {
        json(res, 400, { error: "invalid JSON" });
        return;
      }

      const upload = await store.create(parsed);
      emit({ type: "upload-started", id: upload.id, name: upload.name, size: upload.size });
      json(res, 201, {
        id: upload.id,
        name: upload.name,
        size: upload.size,
        offset: upload.received,
        chunkSize: maxChunkSize,
      });
      return;
    }

    const uploadMatch = /^\/api\/uploads\/([a-f0-9]{24})$/.exec(pathname);
    if (uploadMatch) {
      const id = uploadMatch[1] ?? "";

      if (method === "GET") {
        const upload = store.getUpload(id);
        json(res, 200, { id, offset: upload.received, size: upload.size });
        return;
      }

      if (method === "PUT") {
        const rawOffset = req.headers["x-syndro-offset"];
        const offset = Number(Array.isArray(rawOffset) ? rawOffset[0] : rawOffset);
        if (!Number.isInteger(offset) || offset < 0) {
          json(res, 400, { error: "x-syndro-offset header is required" });
          return;
        }

        const chunk = await readBody(req, maxChunkSize);
        const upload = await store.append(id, offset, chunk);
        emit({
          type: "upload-progress",
          id: upload.id,
          name: upload.name,
          received: upload.received,
          size: upload.size,
        });
        json(res, 200, { id, offset: upload.received, size: upload.size });
        return;
      }

      if (method === "DELETE") {
        await store.abort(id);
        json(res, 200, { ok: true });
        return;
      }
    }

    const completeMatch = /^\/api\/uploads\/([a-f0-9]{24})\/complete$/.exec(pathname);
    if (method === "POST" && completeMatch) {
      const id = completeMatch[1] ?? "";
      const file = await store.complete(id);
      emit({
        type: "upload-complete",
        id: file.id,
        name: file.name,
        size: file.size,
      });
      emit({ type: "file-added", file: publicFile(file) });
      options.onFileReceived?.({ id: file.id, name: file.name, size: file.size });
      json(res, 201, { file: publicFile(file) });
      return;
    }

    const downloadMatch = /^\/api\/files\/([a-f0-9]{24})$/.exec(pathname);
    if (method === "GET" && downloadMatch) {
      const id = downloadMatch[1] ?? "";
      const file = store.getFile(id);
      const stat = await fsp.stat(file.path);

      let start = 0;
      let end = stat.size - 1;
      let status = 200;

      const range = req.headers.range;
      if (typeof range === "string" && range.startsWith("bytes=")) {
        const [from, to] = range.slice("bytes=".length).split("-");
        const parsedStart = from && from.length > 0 ? Number(from) : Number.NaN;
        const parsedEnd = to && to.length > 0 ? Number(to) : Number.NaN;

        if (!Number.isNaN(parsedStart)) start = parsedStart;
        if (!Number.isNaN(parsedEnd)) end = Math.min(parsedEnd, stat.size - 1);

        if (Number.isNaN(start) || start >= stat.size || start > end) {
          res.writeHead(416, { "content-range": `bytes */${stat.size}` });
          res.end();
          return;
        }
        status = 206;
      }

      const length = Math.max(end - start + 1, 0);
      res.writeHead(status, {
        "content-type": file.mime || "application/octet-stream",
        "content-length": String(length),
        "content-disposition": contentDisposition(file.name),
        "accept-ranges": "bytes",
        "cache-control": "no-store",
        ...(status === 206
          ? { "content-range": `bytes ${start}-${end}/${stat.size}` }
          : {}),
      });

      if (length === 0) {
        res.end();
        return;
      }

      const stream = fs.createReadStream(file.path, { start, end });
      stream.on("error", () => res.destroy());
      stream.pipe(res);
      return;
    }

    json(res, 404, { error: "not found" });
  }

  const hosts = options.host ? [options.host] : ["::", "0.0.0.0"];
  const requestedPort = options.port ?? 0;
  let boundHost = "";
  let lastError: unknown = null;

  outer: for (const host of hosts) {
    for (const port of [requestedPort, 0]) {
      try {
        currentPort = await listen(server, host, port);
        boundHost = host;
        break outer;
      } catch (error) {
        lastError = error;
      }
    }
  }

  if (!boundHost) {
    throw lastError instanceof Error ? lastError : new Error("could not bind a socket");
  }

  const sweeper = setInterval(() => {
    void store.sweep(60 * 60 * 1000);
  }, 10 * 60 * 1000);
  sweeper.unref?.();

  return {
    port: currentPort,
    host: boundHost,
    token: options.token,
    urls: localUrls(),
    close: async () => {
      clearInterval(sweeper);
      server.closeAllConnections?.();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

export function createShareToken(): string {
  return randomBytes(12).toString("hex");
}
