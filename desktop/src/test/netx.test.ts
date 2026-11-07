import assert from "node:assert/strict";
import * as os from "node:os";
import { test } from "node:test";
import {
  classifyAddress,
  formatHost,
  formatUrl,
  listLocalAddresses,
  pickShareUrl,
  preferredUrls,
} from "../main/netx";

function iface(overrides: Partial<os.NetworkInterfaceInfo>): os.NetworkInterfaceInfo {
  return {
    address: "0.0.0.0",
    netmask: "255.255.255.0",
    family: "IPv4",
    mac: "00:00:00:00:00:00",
    internal: false,
    cidr: null,
    ...overrides,
  } as os.NetworkInterfaceInfo;
}

test("classifies IPv6 address scopes", () => {
  assert.equal(classifyAddress("fd12:3456::1"), "ipv6-ula");
  assert.equal(classifyAddress("fc00::1"), "ipv6-ula");
  assert.equal(classifyAddress("2001:db8::1"), "ipv6-global");
  assert.equal(classifyAddress("2a01:4f8::1"), "ipv6-global");
  assert.equal(classifyAddress("fe80::1"), "ipv6-link-local");
  assert.equal(classifyAddress("febf::1"), "ipv6-link-local");
  assert.equal(classifyAddress("::1"), null);
  assert.equal(classifyAddress("::"), null);
});

test("classifies IPv4 address scopes", () => {
  assert.equal(classifyAddress("192.168.1.20"), "ipv4-private");
  assert.equal(classifyAddress("10.0.0.5"), "ipv4-private");
  assert.equal(classifyAddress("172.16.4.2"), "ipv4-private");
  assert.equal(classifyAddress("172.32.4.2"), "ipv4-public");
  assert.equal(classifyAddress("8.8.8.8"), "ipv4-public");
  assert.equal(classifyAddress("127.0.0.1"), null);
});

test("formats hosts and URLs correctly for each family", () => {
  assert.equal(formatHost("fd12::1"), "[fd12::1]");
  assert.equal(formatHost("192.168.1.4"), "192.168.1.4");
  assert.equal(formatUrl("fd12::1", 47821), "http://[fd12::1]:47821");
  assert.equal(formatUrl("192.168.1.4", 47821), "http://192.168.1.4:47821");
  assert.equal(
    formatUrl("fe80::1", 47821, 12),
    "http://[fe80::1]%2512:47821",
  );
});

test("prefers ULA over global IPv6 and marks link-local as native-only", () => {
  const interfaces = {
    "Wi-Fi": [
      iface({ address: "fe80::abcd", family: "IPv6", scopeid: 12 }),
      iface({ address: "2001:db8::20", family: "IPv6" }),
      iface({ address: "fd42:1::20", family: "IPv6" }),
      iface({ address: "192.168.1.20" }),
    ],
    Ethernet: [iface({ address: "fe80::abcd", family: "IPv6", scopeid: 7 })],
  };

  const addresses = listLocalAddresses(interfaces);
  assert.deepEqual(
    addresses.map((entry) => entry.kind),
    ["ipv6-ula", "ipv6-global", "ipv4-private", "ipv6-link-local"],
  );

  const linkLocal = addresses.find((entry) => entry.kind === "ipv6-link-local");
  assert.ok(linkLocal);
  assert.equal(linkLocal.browserReachable, false);

  const urls = preferredUrls(47821, interfaces, "/s/abc");
  assert.equal(urls[0]?.url, "http://[fd42:1::20]:47821/s/abc");
  assert.equal(pickShareUrl(47821, interfaces, "/s/abc")?.kind, "ipv6-ula");
});

test("returns no share URL when only link-local addresses exist", () => {
  const interfaces = {
    "Wi-Fi": [iface({ address: "fe80::abcd", family: "IPv6", scopeid: 12 })],
  };
  assert.equal(pickShareUrl(47821, interfaces), null);
});
