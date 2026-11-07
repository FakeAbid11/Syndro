import assert from "node:assert/strict";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { test, type TestContext } from "node:test";
import { startServer, type RunningServer, type ServerOptions } from "../main/server";

const TOKEN = "0123456789abcdef01234567";
const WEB_DIR = path.join(__dirname, "..", "..", "web");

interface Harness {
  server: RunningServer;
  dir: string;
  base: string;
  url: (pathname: string) => string;
}

async function harness(
  t: TestContext,
  overrides: Partial<ServerOptions> = {},
): Promise<Harness> {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "syndro-test-"));
  const server = await startServer({
    token: TOKEN,
    deviceName: "test-device",
    webDir: WEB_DIR,
    storeDir: dir,
    host: "127.0.0.1",
    port: 0,
    ...overrides,
  });

  t.after(async () => {
    await server.close();
    await fsp.rm(dir, { recursive: true, force: true });
  });

  const base = `http://127.0.0.1:${server.port}`;
  return {
    server,
    dir,
    base,
    url: (pathname: string) =>
      `${base}${pathname}${pathname.includes("?") ? "&" : "?"}t=${TOKEN}`,
  };
}

test("serves the page shell only for a valid token", async (t) => {
  const h = await harness(t);

  const redirect = await fetch(`${h.base}/`, { redirect: "manual" });
  assert.equal(redirect.status, 302);
  assert.equal(redirect.headers.get("location"), `/s/${TOKEN}`);

  const page = await fetch(`${h.base}/s/${TOKEN}`);
  assert.equal(page.status, 200);
  assert.match((await page.text()).toLowerCase(), /syndro/);

  const wrong = await fetch(`${h.base}/s/ffffffffffffffffffffffff`);
  assert.equal(wrong.status, 401);
});

test("rejects API calls without a token and reports info with one", async (t) => {
  const h = await harness(t);

  assert.equal((await fetch(`${h.base}/api/info`)).status, 401);
  assert.equal((await fetch(`${h.base}/api/files`)).status, 401);

  const info = await fetch(h.url("/api/info"));
  assert.equal(info.status, 200);
  const body = (await info.json()) as { deviceName: string; files: unknown[] };
  assert.equal(body.deviceName, "test-device");
  assert.deepEqual(body.files, []);
});

test("uploads a file in chunks, completes it and downloads it", async (t) => {
  const h = await harness(t);
  const payload = Buffer.from("hello world", "utf8");

  const created = await fetch(h.url("/api/uploads"), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: "hello.txt", size: payload.length, mime: "text/plain" }),
  });
  assert.equal(created.status, 201);
  const upload = (await created.json()) as { id: string; offset: number };
  assert.equal(upload.offset, 0);
  assert.match(upload.id, /^[a-f0-9]{24}$/);

  const first = await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "0" },
    body: payload.subarray(0, 5),
  });
  assert.equal(first.status, 200);
  assert.equal(((await first.json()) as { offset: number }).offset, 5);

  const second = await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "5" },
    body: payload.subarray(5),
  });
  assert.equal(second.status, 200);

  const complete = await fetch(h.url(`/api/uploads/${upload.id}/complete`), { method: "POST" });
  assert.equal(complete.status, 201);
  const stored = ((await complete.json()) as { file: { id: string; name: string } }).file;
  assert.equal(stored.name, "hello.txt");

  const download = await fetch(h.url(`/api/files/${stored.id}`));
  assert.equal(download.status, 200);
  assert.equal(download.headers.get("accept-ranges"), "bytes");
  assert.equal(Buffer.from(await download.arrayBuffer()).toString("utf8"), "hello world");

  const listed = (await (await fetch(h.url("/api/files"))).json()) as {
    files: Array<{ id: string }>;
  };
  assert.equal(listed.files.length, 1);
  assert.equal(listed.files[0]?.id, stored.id);
});

test("supports range requests for resumable downloads", async (t) => {
  const h = await harness(t);
  const payload = Buffer.from("0123456789", "utf8");

  const upload = (await (
    await fetch(h.url("/api/uploads"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "digits.bin", size: payload.length }),
    })
  ).json()) as { id: string };

  await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "0" },
    body: payload,
  });
  const stored = (await (
    await fetch(h.url(`/api/uploads/${upload.id}/complete`), { method: "POST" })
  ).json()) as { file: { id: string } };

  const range = await fetch(h.url(`/api/files/${stored.file.id}`), {
    headers: { range: "bytes=3-6" },
  });
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("content-range"), "bytes 3-6/10");
  assert.equal(Buffer.from(await range.arrayBuffer()).toString("utf8"), "3456");

  const unsatisfiable = await fetch(h.url(`/api/files/${stored.file.id}`), {
    headers: { range: "bytes=99-120" },
  });
  assert.equal(unsatisfiable.status, 416);
});

test("rejects an out-of-order chunk with the expected offset", async (t) => {
  const h = await harness(t);

  const upload = (await (
    await fetch(h.url("/api/uploads"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "a.bin", size: 4 }),
    })
  ).json()) as { id: string };

  await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "0" },
    body: Buffer.from("ab"),
  });

  const conflict = await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "0" },
    body: Buffer.from("cd"),
  });
  assert.equal(conflict.status, 409);
  assert.equal(((await conflict.json()) as { expected: number }).expected, 2);
});

test("never uses a client-supplied path as a filesystem location", async (t) => {
  const h = await harness(t);
  const payload = Buffer.from("x", "utf8");

  const upload = (await (
    await fetch(h.url("/api/uploads"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "../../etc/passwd", size: payload.length }),
    })
  ).json()) as { id: string };

  await fetch(h.url(`/api/uploads/${upload.id}`), {
    method: "PUT",
    headers: { "x-syndro-offset": "0" },
    body: payload,
  });
  const stored = (await (
    await fetch(h.url(`/api/uploads/${upload.id}/complete`), { method: "POST" })
  ).json()) as { file: { id: string; name: string } };

  assert.equal(stored.file.name, "passwd");
  const entries = await fsp.readdir(path.join(h.dir, "files"));
  assert.ok(entries.includes(stored.file.id));
  assert.ok(!entries.some((entry) => entry.includes("..")));
});

test("rejects traffic after the share link expires", async (t) => {
  const h = await harness(t, { ttlMs: 1 });
  await new Promise((resolve) => setTimeout(resolve, 20));

  const response = await fetch(h.url("/api/info"));
  assert.equal(response.status, 410);
});
