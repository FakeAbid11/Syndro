import * as os from "node:os";

/**
 * Syndro is IPv6-first, but not IPv6-only.
 *
 * The reason is practical, not ideological: browsers cannot reliably open a
 * link-local URL (`http://[fe80::1%25WiFi]:47821/`). Chrome refuses scope IDs
 * outright and Firefox support is inconsistent, so a link-local address is
 * only usable between native Syndro clients that can carry the zone ID in the
 * socket, never in the browser-mode URL we hand out.
 *
 * So we rank addresses by how likely they are to work for a *browser*, and we
 * mark the ones that are native-only instead of pretending they are shareable.
 */

export type AddressKind =
  | "ipv6-ula"
  | "ipv6-global"
  | "ipv4-private"
  | "ipv4-public"
  | "ipv6-link-local";

export interface LocalAddress {
  address: string;
  interfaceName: string;
  kind: AddressKind;
  /** Zone index for link-local IPv6, when the OS reports one. */
  scopeId: number | null;
  /** False when the address needs a zone ID that a browser cannot supply. */
  browserReachable: boolean;
  /** Lower sorts first. */
  rank: number;
}

export interface ShareUrl {
  url: string;
  address: string;
  interfaceName: string;
  kind: AddressKind;
  browserReachable: boolean;
}

const RANK: Record<AddressKind, number> = {
  "ipv6-ula": 0,
  "ipv6-global": 10,
  "ipv4-private": 20,
  "ipv4-public": 30,
  "ipv6-link-local": 40,
};

function firstHextet(address: string): number {
  const head = address.split(":")[0] ?? "";
  const value = Number.parseInt(head, 16);
  return Number.isNaN(value) ? -1 : value;
}

export function classifyAddress(address: string): AddressKind | null {
  const addr = address.trim().toLowerCase();
  if (addr.includes(":")) {
    if (addr === "::1" || addr === "::") return null;

    const head = firstHextet(addr);
    if (head < 0) return null;

    // fe80::/10 -> fe80 .. febf
    if (head >= 0xfe80 && head <= 0xfebf) return "ipv6-link-local";
    // fc00::/7 -> fc00 .. fdff
    if ((head & 0xfe00) === 0xfc00) return "ipv6-ula";
    // 2000::/3 -> 2000 .. 3fff
    if (head >= 0x2000 && head <= 0x3fff) return "ipv6-global";
    return null;
  }

  const parts = addr.split(".");
  if (parts.length !== 4) return null;
  const octets = parts.map((p) => Number.parseInt(p, 10));
  if (octets.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return null;

  const [a = 0, b = 0] = octets;
  if (a === 0 || a === 127) return null;
  if (a === 10) return "ipv4-private";
  if (a === 172 && b >= 16 && b <= 31) return "ipv4-private";
  if (a === 192 && b === 168) return "ipv4-private";
  if (a === 169 && b === 254) return "ipv4-private";
  return "ipv4-public";
}

/** Formats a host for a URL: IPv6 needs brackets, IPv4 does not. */
export function formatHost(address: string): string {
  return address.includes(":") ? `[${address}]` : address;
}

/**
 * Builds an absolute URL. Link-local IPv6 needs a zone ID; in a URL the `%` is
 * percent-encoded as `%25`, which is what native clients expect.
 */
export function formatUrl(
  address: string,
  port: number,
  zone?: string | number | null,
): string {
  if (zone !== undefined && zone !== null && zone !== "" && address.includes(":")) {
    // The zone belongs *inside* the brackets: [fe80::1%25wlan0]. Percent-
    // encoding the `%` is what browsers and native HTTP clients expect.
    const encoded = encodeURIComponent(String(zone));
    return `http://[${address}%25${encoded}]:${port}`;
  }
  return `http://${formatHost(address)}:${port}`;
}

export function listLocalAddresses(
  interfaces: NodeJS.Dict<os.NetworkInterfaceInfo[]> = os.networkInterfaces(),
): LocalAddress[] {
  const seen = new Set<string>();
  const out: LocalAddress[] = [];

  for (const [interfaceName, entries] of Object.entries(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue;

      const kind = classifyAddress(entry.address);
      if (!kind) continue;

      const scopeId =
        kind === "ipv6-link-local" && typeof entry.scopeid === "number" && entry.scopeid > 0
          ? entry.scopeid
          : null;

      const dedupeKey = `${entry.address}/${interfaceName}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);

      out.push({
        address: entry.address,
        interfaceName,
        kind,
        scopeId,
        browserReachable: kind !== "ipv6-link-local",
        rank: RANK[kind],
      });
    }
  }

  // Also collapse the same address reported on several pseudo-interfaces
  // (common on Windows with WLAN/Wi-Fi Direct adapters).
  const byAddress = new Map<string, LocalAddress>();
  for (const item of out) {
    const current = byAddress.get(item.address);
    if (!current || item.rank < current.rank) byAddress.set(item.address, item);
  }

  return [...byAddress.values()].sort((a, b) => a.rank - b.rank || a.address.localeCompare(b.address));
}

export function preferredUrls(
  port: number,
  interfaces: NodeJS.Dict<os.NetworkInterfaceInfo[]> = os.networkInterfaces(),
  pathSuffix = "",
): ShareUrl[] {
  return listLocalAddresses(interfaces)
    .map((item) => ({
      url:
        formatUrl(
          item.address,
          port,
          item.kind === "ipv6-link-local" ? (item.scopeId ?? item.interfaceName) : null,
        ) + pathSuffix,
      address: item.address,
      interfaceName: item.interfaceName,
      kind: item.kind,
      browserReachable: item.browserReachable,
    }))
    .sort((a, b) => {
      if (a.browserReachable !== b.browserReachable) return a.browserReachable ? -1 : 1;
      return RANK[a.kind] - RANK[b.kind] || a.address.localeCompare(b.address);
    });
}

/** Picks the URL a browser on the same network has the best chance of opening. */
export function pickShareUrl(
  port: number,
  interfaces: NodeJS.Dict<os.NetworkInterfaceInfo[]> = os.networkInterfaces(),
  pathSuffix = "",
): ShareUrl | null {
  return preferredUrls(port, interfaces, pathSuffix).find((u) => u.browserReachable) ?? null;
}
