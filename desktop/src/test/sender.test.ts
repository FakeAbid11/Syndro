import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { test, type TestContext } from "node:test";
import { NativeSender, SEND_CHUNK_SIZE } from "../main/sender";
import { fixture, listFiles, TOKEN, type Fixture } from "./helpers";

const UPLOAD_ID = "f".repeat(24);

function json(res: ServerResponse, body: unknown, status = 200): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

async function mockReceiver(
  t: TestContext,
  handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>,
): Promise<string> {
  const server = createServer((req, res) => {
    req.resume();
    if (req.url === `/api/info?t=${TOKEN}`) {
      json(res, { deviceName: "Mock receiver", token: TOKEN, files: [] });
    } else {
      void Promise.resolve(handler(req, res)).catch(() => json(res, { error: "mock failed" }, 500));
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return `http://127.0.0.1:${address.port}/s/${TOKEN}`;
}

test("requires a verified receiver and rejects this desktop's own link", async (t) => {
  const local = await fixture(t);
  const sender = new NativeSender({ port: local.server.port, serverId: "test-desktop-id" });
  await assert.rejects(sender.beginUpload("not-connected", { name: "x", size: 0, mime: "text/plain" }), /connect to a receiver/);
  await assert.rejects(sender.connect(local.shareUrl), /own link/);
  assert.deepEqual(await listFiles(local), []);
});

test("sends real chunks only to the selected receiver and confirms delivery", async (t) => {
  const local = await fixture(t);
  const remote = await fixture(t, { deviceName: "Test phone", serverId: "phone-id", token: "EFGH6789", maxChunkSize: 3 });
  const sender = new NativeSender({ port: local.server.port, serverId: "test-desktop-id" });
  const receiver = await sender.connect(remote.shareUrl);
  assert.equal(receiver.name, "Test phone");
  assert.ok(!receiver.address.includes("EFGH6789"));
  const payload = Uint8Array.from(Buffer.from("hello phone"));
  const created = await sender.beginUpload(receiver.id, { name: "hello.txt", size: payload.length, mime: "text/plain" });
  assert.equal(created.chunkSize, 3);
  let offset = 0;
  while (offset < payload.length) {
    offset = (await sender.appendUpload(created.id, offset, payload.slice(offset, offset + created.chunkSize).buffer)).offset;
  }
  assert.deepEqual(await listFiles(remote), []);
  assert.deepEqual(await sender.completeUpload(created.id), { receiver: "Test phone" });
  const files = await listFiles(remote);
  assert.equal(files.length, 1);
  assert.equal(files[0]?.origin, "received");
  assert.equal(files[0]?.name, "hello.txt");
  const downloaded = await fetch(remote.url(`/api/files/${files[0]?.id}`));
  assert.deepEqual(new Uint8Array(await downloaded.arrayBuffer()), payload);
  assert.deepEqual(await listFiles(local), []);
});

test("a failed connection clears the previous receiver and rejects stale receiver IDs", async (t) => {
  const remote = await fixture(t, { serverId: "remote-id" });
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const first = await sender.connect(remote.shareUrl);
  await assert.rejects(sender.connect(remote.shareUrl.replace(TOKEN, "EFGH6789")), /invalid or missing token/);
  await assert.rejects(sender.beginUpload(first.id, { name: "x", size: 0, mime: "text/plain" }), /connect to a receiver/);
  const second = await sender.connect(remote.shareUrl);
  assert.notEqual(second.id, first.id);
  await assert.rejects(sender.beginUpload(first.id, { name: "x", size: 0, mime: "text/plain" }), /connect to a receiver/);
});

test("rejects self identity even when reached through another address or port", async (t) => {
  const alias = await fixture(t, { serverId: "same-installation-id" });
  const sender = new NativeSender({ port: 1, serverId: "same-installation-id" });
  await assert.rejects(sender.connect(alias.shareUrl), /own link/);
});

test("resumes an acknowledged chunk without writing it twice", async (t) => {
  const remote = await fixture(t, { serverId: "remote-id" });
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(remote.shareUrl);
  const created = await sender.beginUpload(receiver.id, { name: "resume.txt", size: 4, mime: "text/plain" });
  const first = Uint8Array.from(Buffer.from("ab")).buffer;
  assert.deepEqual(await sender.appendUpload(created.id, 0, first), { offset: 2 });
  assert.deepEqual(await sender.appendUpload(created.id, 0, first), { offset: 2 });
  await sender.appendUpload(created.id, 2, Uint8Array.from(Buffer.from("cd")).buffer);
  await sender.completeUpload(created.id);
  const files = await listFiles(remote);
  assert.equal(await (await fetch(remote.url(`/api/files/${files[0]?.id}`))).text(), "abcd");
});

test("does not accept HTTP success without confirmation of the exact file", async (t) => {
  const url = await mockReceiver(t, (req, res) => {
    if (req.method === "POST" && req.url?.startsWith("/api/uploads?")) json(res, { id: UPLOAD_ID, offset: 0 }, 201);
    else if (req.method === "POST") json(res, { file: { id: "e".repeat(24), size: 0 } }, 201);
    else json(res, { ok: true });
  });
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(url);
  const created = await sender.beginUpload(receiver.id, { name: "empty.txt", size: 0, mime: "text/plain" });
  await assert.rejects(sender.completeUpload(created.id), /did not confirm/);
  await sender.abortUpload(created.id);
  sender.disconnect();
});

test("rejects invalid resume offsets and oversized IPC chunks", async (t) => {
  const url = await mockReceiver(t, (req, res) => {
    if (req.method === "POST") json(res, { id: UPLOAD_ID, offset: 0, chunkSize: SEND_CHUNK_SIZE * 2 }, 201);
    else if (req.method === "PUT") json(res, { expected: -1 }, 409);
    else json(res, { ok: true });
  });
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(url);
  const created = await sender.beginUpload(receiver.id, { name: "x", size: SEND_CHUNK_SIZE * 2, mime: "text/plain" });
  assert.equal(created.chunkSize, SEND_CHUNK_SIZE);
  await assert.rejects(sender.appendUpload(created.id, 0, new ArrayBuffer(SEND_CHUNK_SIZE + 1)), /Invalid transfer chunk/);
  await assert.rejects(sender.appendUpload(created.id, 0, new ArrayBuffer(1)), /invalid resume offset/);
  await assert.rejects(sender.completeUpload(created.id), /incomplete/);
  await sender.abortUpload(created.id);
});

test("locks the receiver during the upload-creation handshake as well as active chunks", async (t) => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let requested!: () => void;
  const requestSeen = new Promise<void>((resolve) => { requested = resolve; });
  const url = await mockReceiver(t, async (req, res) => {
    if (req.method === "POST") {
      requested();
      await gate;
      json(res, { id: UPLOAD_ID, offset: 0 }, 201);
    } else json(res, { ok: true });
  });
  t.after(release);
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(url);
  const beginning = sender.beginUpload(receiver.id, { name: "x", size: 0, mime: "text/plain" });
  await requestSeen;
  assert.throws(() => sender.disconnect(), /Wait for the current transfer/);
  await assert.rejects(sender.connect(url), /Wait for the current transfer/);
  release();
  const created = await beginning;
  await sender.abortUpload(created.id);
  sender.disconnect();
});

test("supports empty files and cancellation without leaving a local copy", async (t) => {
  const remote = await fixture(t, { serverId: "remote-id" });
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(remote.shareUrl);
  const cancelled = await sender.beginUpload(receiver.id, { name: "cancelled.txt", size: 1, mime: "text/plain" });
  await sender.abortUpload(cancelled.id);
  const empty = await sender.beginUpload(receiver.id, { name: "empty.txt", size: 0, mime: "text/plain" });
  await sender.completeUpload(empty.id);
  assert.deepEqual((await listFiles(remote)).map((file) => [file.name, file.size]), [["empty.txt", 0]]);
  sender.disconnect();
});

test("can send through a native IPv6 literal", async (t) => {
  let remote: Fixture;
  try {
    remote = await fixture(t, { host: "::1", serverId: "ipv6-receiver-id" });
  } catch (error) {
    if (["EAFNOSUPPORT", "EADDRNOTAVAIL"].includes((error as NodeJS.ErrnoException).code ?? "")) {
      t.skip("Runner has no IPv6 loopback");
      return;
    }
    throw error;
  }
  const sender = new NativeSender({ port: 1, serverId: "local-id" });
  const receiver = await sender.connect(remote.shareUrl);
  const created = await sender.beginUpload(receiver.id, { name: "ipv6.txt", size: 0, mime: "text/plain" });
  await sender.completeUpload(created.id);
  assert.equal((await listFiles(remote))[0]?.name, "ipv6.txt");
});
