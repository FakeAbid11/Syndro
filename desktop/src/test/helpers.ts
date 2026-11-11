import assert from "node:assert/strict";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { TestContext } from "node:test";
import { startServer, type RunningServer, type ServerOptions } from "../main/server";
import type { PublicFile } from "../main/store";

export const TOKEN = "ABCD2345";
export const WEB_DIR = path.join(__dirname, "..", "..", "web");

export async function fixture(
  t: TestContext,
  options: Partial<ServerOptions> = {},
  seed?: (dir: string) => Promise<void>,
) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "syndro-test-"));
  let server: RunningServer;
  try {
    await seed?.(dir);
    server = await startServer({
      token: TOKEN,
      deviceName: "Test desktop",
      serverId: "test-desktop-id",
      webDir: WEB_DIR,
      storeDir: dir,
      host: "127.0.0.1",
      port: 0,
      ...options,
    });
  } catch (error) {
    await fsp.rm(dir, { recursive: true, force: true });
    throw error;
  }
  const running = server;
  t.after(async () => {
    await running.close();
    await fsp.rm(dir, { recursive: true, force: true });
  });
  const host = options.host === "::1" ? "[::1]" : "127.0.0.1";
  const base = `http://${host}:${server.port}`;
  return {
    dir,
    server,
    base,
    shareUrl: `${base}/s/${server.token}`,
    url: (pathname: string) => `${base}${pathname}?t=${server.token}`,
  };
}

export type Fixture = Awaited<ReturnType<typeof fixture>>;

export async function listFiles(h: Fixture): Promise<PublicFile[]> {
  const response = await fetch(h.url("/api/files"));
  assert.equal(response.status, 200);
  return ((await response.json()) as { files: PublicFile[] }).files;
}

export async function upload(h: Fixture, name: string, bytes: Uint8Array, shared = false): Promise<PublicFile> {
  const response = await fetch(h.url("/api/uploads"), {
    method: "POST",
    headers: { "content-type": "application/json", ...(shared ? { "x-syndro-purpose": "share" } : {}) },
    body: JSON.stringify({ name, size: bytes.length, mime: "application/octet-stream", origin: "shared" }),
  });
  assert.equal(response.status, 201);
  const created = (await response.json()) as { id: string };
  if (bytes.length > 0) {
    const appended = await fetch(h.url(`/api/uploads/${created.id}`), {
      method: "PUT",
      headers: { "x-syndro-offset": "0" },
      body: Uint8Array.from(bytes),
    });
    assert.equal(appended.status, 200);
  }
  const completed = await fetch(h.url(`/api/uploads/${created.id}/complete`), { method: "POST" });
  assert.equal(completed.status, 201);
  return ((await completed.json()) as { file: PublicFile }).file;
}
