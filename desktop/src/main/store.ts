import { randomBytes } from "node:crypto";
import * as fsp from "node:fs/promises";
import * as path from "node:path";

export const DEFAULT_MAX_FILE_SIZE = 64 * 1024 * 1024 * 1024; // 64 GiB

export class StoreNotFoundError extends Error {
  constructor(message = "not found") {
    super(message);
    this.name = "StoreNotFoundError";
  }
}

export class UploadConflictError extends Error {
  constructor(readonly expected: number) {
    super(`expected offset ${expected}`);
    this.name = "UploadConflictError";
  }
}

export class UploadLimitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UploadLimitError";
  }
}

export interface Upload {
  id: string;
  name: string;
  size: number;
  mime: string;
  received: number;
  tempPath: string;
  createdAt: number;
}

export interface StoredFile {
  id: string;
  name: string;
  size: number;
  mime: string;
  receivedAt: number;
  path: string;
}

export interface PublicFile {
  id: string;
  name: string;
  size: number;
  mime: string;
  receivedAt: number;
}

/**
 * The client-supplied name is never used as a filesystem path. It is only kept
 * for display and for Content-Disposition, so this is a cosmetic sanitizer —
 * traversal safety comes from storing every file under a generated ID.
 */
export function sanitizeFilename(name: string): string {
  const base = String(name ?? "").split(/[\\/]/).pop() ?? "";
  const cleaned = base
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[<>:"|?*]/g, "_")
    .replace(/^\.+/, "")
    .trim();
  return (cleaned || "file").slice(0, 180);
}

export function contentDisposition(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_");
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

export function publicFile(file: StoredFile): PublicFile {
  return {
    id: file.id,
    name: file.name,
    size: file.size,
    mime: file.mime,
    receivedAt: file.receivedAt,
  };
}

export class TransferStore {
  private readonly uploads = new Map<string, Upload>();
  private readonly files = new Map<string, StoredFile>();

  constructor(
    private readonly root: string,
    private readonly maxFileSize: number = DEFAULT_MAX_FILE_SIZE,
  ) {}

  get tmpDir(): string {
    return path.join(this.root, "tmp");
  }

  get filesDir(): string {
    return path.join(this.root, "files");
  }

  async init(): Promise<void> {
    await fsp.mkdir(this.tmpDir, { recursive: true });
    await fsp.mkdir(this.filesDir, { recursive: true });

    for (const entry of await fsp.readdir(this.filesDir)) {
      if (!entry.endsWith(".json")) continue;
      try {
        const raw = await fsp.readFile(path.join(this.filesDir, entry), "utf8");
        const parsed = JSON.parse(raw) as StoredFile;
        if (parsed.id && parsed.path) this.files.set(parsed.id, parsed);
      } catch {
        // A sidecar we cannot read is not worth failing startup over.
      }
    }
  }

  async create(input: { name?: unknown; size?: unknown; mime?: unknown }): Promise<Upload> {
    const size = Number(input.size);
    if (!Number.isFinite(size) || size < 0) throw new UploadLimitError("invalid size");
    if (size > this.maxFileSize) throw new UploadLimitError("file exceeds the size limit");

    const id = randomBytes(12).toString("hex");
    const tempPath = path.join(this.tmpDir, `${id}.part`);
    await fsp.writeFile(tempPath, Buffer.alloc(0), { flag: "wx" });

    const upload: Upload = {
      id,
      name: sanitizeFilename(String(input.name ?? "file")),
      size,
      mime: String(input.mime ?? "application/octet-stream").slice(0, 160),
      received: 0,
      tempPath,
      createdAt: Date.now(),
    };
    this.uploads.set(id, upload);
    return upload;
  }

  getUpload(id: string): Upload {
    const upload = this.uploads.get(id);
    if (!upload) throw new StoreNotFoundError("unknown upload");
    return upload;
  }

  async append(id: string, offset: number, chunk: Buffer): Promise<Upload> {
    const upload = this.getUpload(id);
    if (offset !== upload.received) throw new UploadConflictError(upload.received);
    if (upload.received + chunk.length > upload.size) {
      throw new UploadLimitError("chunk exceeds the declared file size");
    }

    await fsp.appendFile(upload.tempPath, chunk);
    upload.received += chunk.length;
    return upload;
  }

  async complete(id: string): Promise<StoredFile> {
    const upload = this.getUpload(id);
    if (upload.received !== upload.size) {
      throw new UploadConflictError(upload.received);
    }

    const finalPath = path.join(this.filesDir, upload.id);
    await fsp.rename(upload.tempPath, finalPath);

    const file: StoredFile = {
      id: upload.id,
      name: upload.name,
      size: upload.size,
      mime: upload.mime,
      receivedAt: Date.now(),
      path: finalPath,
    };
    await fsp.writeFile(`${finalPath}.json`, JSON.stringify(file), "utf8");

    this.uploads.delete(id);
    this.files.set(file.id, file);
    return file;
  }

  async abort(id: string): Promise<void> {
    const upload = this.uploads.get(id);
    if (!upload) return;
    this.uploads.delete(id);
    await fsp.rm(upload.tempPath, { force: true });
  }

  list(): StoredFile[] {
    return [...this.files.values()].sort((a, b) => b.receivedAt - a.receivedAt);
  }

  getFile(id: string): StoredFile {
    const file = this.files.get(id);
    if (!file) throw new StoreNotFoundError("unknown file");
    return file;
  }

  async remove(id: string): Promise<void> {
    const file = this.files.get(id);
    if (!file) return;
    this.files.delete(id);
    await fsp.rm(file.path, { force: true });
    await fsp.rm(`${file.path}.json`, { force: true });
  }

  /** Drops uploads abandoned by a closed tab. */
  async sweep(olderThanMs: number, now = Date.now()): Promise<void> {
    for (const upload of [...this.uploads.values()]) {
      if (now - upload.createdAt < olderThanMs) continue;
      await this.abort(upload.id);
    }
  }
}
