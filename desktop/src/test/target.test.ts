import assert from "node:assert/strict";
import { test } from "node:test";
import { parseShareTarget } from "../main/target";

test("parses a receiver link and accepts grouped lowercase codes", () => {
  const target = parseShareTarget(" http://Phone.local:47821/s/abcd%202345/ ");
  assert.deepEqual(target, {
    protocol: "http:", hostname: "phone.local", port: 47821, token: "ABCD2345",
    address: "http://phone.local:47821",
  });
  assert.equal(parseShareTarget("https://phone.local/s/ABCD2345").port, 443);
  assert.equal(parseShareTarget("http://192.168.1.2/s/ABCD-2345").port, 80);
  assert.ok(!target.address.includes(target.token));
});

test("parses IPv6 without sending its interface zone through WHATWG URL", () => {
  assert.equal(parseShareTarget("http://[fd00::1]:47821/s/ABCD2345").hostname, "fd00::1");
  const scoped = parseShareTarget("http://[fe80::1%25Wi-Fi]:47821/s/ABCD2345");
  assert.equal(scoped.hostname, "fe80::1%Wi-Fi");
  assert.equal(scoped.address, "http://[fe80::1%25Wi-Fi]:47821");
  assert.equal(parseShareTarget("http://[fe80::1%2512]:47821/s/ABCD2345").hostname, "fe80::1%12");
});

test("rejects credentials, unrelated paths, invalid codes, and invalid endpoints", () => {
  for (const input of [
    "192.168.1.2:47821/s/ABCD2345", "file:///s/ABCD2345", "ftp://host/s/ABCD2345",
    "http://user:password@host/s/ABCD2345", "http://host/upload/ABCD2345",
    "http://host/s/ABCD2345?redirect=other", "http://host/s/ABCD2345#extra",
    "http://host/s/ABCD2345/more", "http://host/s/ABCD1234", "http://host/s/ABCDEFGHI",
    "http://host:0/s/ABCD2345", "http://host:65536/s/ABCD2345", "http://[nope]/s/ABCD2345",
    "http://[fe80::1%25]/s/ABCD2345", "http://[fe80::1%25eth%250]/s/ABCD2345",
    "http://[fe80::1%25eth%200]/s/ABCD2345",
  ]) assert.throws(() => parseShareTarget(input), Error, input);
});
