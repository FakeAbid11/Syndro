import assert from "node:assert/strict";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { test, type TestContext } from "node:test";
import { publicFile, TransferStore } from "../main/store";

async function directory(t: TestContext): Promise<string> {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "syndro-store-test-"));
  t.after(() => fsp.rm(dir, { recursive: true, force: true }));
  return dir;
}

test("persists shared and received origins through a restart", async (t) => {
  const dir = await directory(t);
  const store = new TransferStore(dir);
  await store.init();
  const shared = await store.create({ name: "published.txt", size: 1 }, "shared");
  await store.append(shared.id, 0, Buffer.from("p"));
  await store.complete(shared.id);
  const received = await store.create({ name: "incoming.txt", size: 0 });
  await store.complete(received.id);

  const restarted = new TransferStore(dir);
  await restarted.init();
  assert.equal(publicFile(restarted.getFile(shared.id)).origin, "shared");
  assert.equal(publicFile(restarted.getFile(received.id)).origin, "received");
  assert.equal("path" in publicFile(restarted.getFile(shared.id)), false);
});

test("keeps legacy sidecars intact instead of guessing their direction", async (t) => {
  const dir = await directory(t);
  await fsp.mkdir(path.join(dir, "files"));
  const legacy = {
    id: "a".repeat(24), name: "v0.1.txt", size: 1, mime: "text/plain", receivedAt: 1,
    path: path.join(dir, "files", "a".repeat(24)),
  };
  const sidecar = `${legacy.path}.json`;
  await fsp.writeFile(legacy.path, "x");
  await fsp.writeFile(sidecar, JSON.stringify(legacy));
  const store = new TransferStore(dir);
  await store.init();
  assert.equal(publicFile(store.getFile(legacy.id)).origin, "unknown");
  assert.deepEqual(JSON.parse(await fsp.readFile(sidecar, "utf8")), legacy);
  assert.equal(publicFile({ ...legacy, origin: "sent" } as unknown as Parameters<typeof publicFile>[0]).origin, "unknown");
});
