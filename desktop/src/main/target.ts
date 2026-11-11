import { isIP } from "node:net";
import { normalizeCode } from "./code";

export interface ShareTarget {
  protocol: "http:" | "https:";
  /** No brackets; a link-local scope is decoded for the native socket. */
  hostname: string;
  port: number;
  token: string;
  /** Safe to display: never contains the capability code. */
  address: string;
}

/** Parse explicitly, since WHATWG URL rejects scoped IPv6 literals. */
export function parseShareTarget(input: string): ShareTarget {
  const match = /^(https?):\/\/(\[[^\]]+\]|[a-z0-9.-]+)(?::([0-9]+))?\/s\/([^/?#]+)\/?$/i.exec(
    input.trim(),
  );
  if (!match) throw new Error("Paste the receiver's full http://…/s/CODE share link.");

  const protocol = `${match[1].toLowerCase()}:` as ShareTarget["protocol"];
  const rawHost = match[2];
  let hostname = rawHost.toLowerCase();
  if (rawHost.startsWith("[")) {
    try {
      hostname = decodeURIComponent(rawHost.slice(1, -1));
    } catch {
      throw new Error("The receiver's IPv6 address is invalid.");
    }
    const [literal, zone, ...extra] = hostname.split("%");
    if (isIP(literal) !== 6 || extra.length > 0 ||
        (zone !== undefined && !/^[a-z0-9_.-]+$/i.test(zone))) {
      throw new Error("The receiver's IPv6 address or interface zone is invalid.");
    }
  } else if (!hostname || hostname.startsWith(".") || hostname.endsWith("..")) {
    throw new Error("The receiver's hostname is invalid.");
  }

  const port = match[3] ? Number(match[3]) : protocol === "https:" ? 443 : 80;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("The receiver's port must be between 1 and 65535.");
  }
  let token: string | null;
  try {
    token = normalizeCode(decodeURIComponent(match[4]));
  } catch {
    token = null;
  }
  if (!token) throw new Error("The link must contain a valid 8-character Syndro code.");

  const host = hostname.includes(":") ? `[${hostname.replace("%", "%25")}]` : hostname;
  return { protocol, hostname, port, token, address: `${protocol}//${host}:${port}` };
}
