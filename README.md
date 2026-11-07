# Syndro

Local-network file sharing for **Android, Linux and Windows**. No cloud, no account, no relay
server, no internet connection required — both devices just have to reach each other on the same
Wi-Fi or hotspot.

**Status: browser mode, phase 1.** A desktop app runs a transfer server and serves a small web UI.
Any phone, tablet, PC or laptop on the same network can open it in a browser and send or receive
files without installing anything.

## What works today

- QR pairing plus copyable share URLs, scoped by a random 24-character capability token
- Chunked, resumable uploads (4 MiB chunks, automatic retry, server-reported resume offset)
- Downloads with HTTP `Range`, so a dropped transfer resumes instead of restarting
- Live transfer list over Server-Sent Events
- Filenames are display-only: every file is stored under a generated ID, so a malicious
  `../../etc/passwd` cannot escape the receive directory
- Share links expire after 24 hours; repeated bad tokens are rate-limited per client
- IPv6-first address selection with an honest IPv4 fallback

## Networking policy: IPv6-first, not IPv6-only

Addresses are ranked by how likely a **browser** is to open them:

| Rank | Kind | Browser-reachable |
| --- | --- | --- |
| 1 | IPv6 ULA (`fc00::/7`) | yes |
| 2 | IPv6 global (`2000::/3`) | yes |
| 3 | IPv4 private (`10/8`, `172.16/12`, `192.168/16`) | yes |
| 4 | IPv4 public | yes |
| 5 | IPv6 link-local (`fe80::/10`) | **no** |

Link-local IPv6 needs a zone ID, and the encoded form `http://[fe80::1%25WiFi]:47821/` is rejected
by Chrome and only half-supported by Firefox. Syndro therefore never hands a link-local address to
a browser as if it were usable; those addresses are kept for native clients that can pass a zone ID
to the socket.

The server binds `::` (dual-stack) and falls back to `0.0.0.0` only if the host has no IPv6 stack.
That fallback matters in practice: Windows Mobile Hotspot does not provide IPv6, and a machine with
only link-local addresses has no browser-usable IPv6 at all.

## Run it

```bash
cd desktop
npm install
npm start
```

Requires Node 22+. The app binds port `47821` (falls back to an ephemeral port if taken) and writes
received files to your Downloads folder under `Syndro/`.

Then open the displayed URL from another device on the same network, or scan the QR code. Allow
Syndro through Windows Firewall on **private** networks when prompted — on public-profile networks
Windows blocks inbound connections before Syndro ever sees them.

## Tests

```bash
cd desktop
npm test        # build + node --test
```

Covered: IPv6/IPv4 classification and URL formatting, share-URL ranking, token gating, chunked
upload, resume conflicts, `Range` downloads, path traversal, and link expiry.

## Roadmap

1. **Phase 2 — native Android app.** Gradle + Kotlin, mirroring the `linkphone` layout, with a
   foreground service so a large transfer survives screen-off.
2. **Phase 3 — mDNS discovery.** `_syndro._tcp.local` plus QR fallback, so no URL has to be typed.
3. **Phase 4 — packaging.** NSIS installer for Windows, AppImage/deb for Linux, signed APK, and
   release artifacts from CI.
4. **Phase 5 — hardening.** Optional per-session PIN, encrypted transport between native clients,
   transfer history, and folder sends.

## Design notes

- The Electron window loads the exact same loopback URL that a browser would, so there is one UI
  implementation, one API, and one thing to test.
- The token is the capability. There is no unauthenticated endpoint that reveals device names,
  file names, or file contents.
- `http://` is deliberate for browser mode: a self-signed certificate produces a full-page browser
  warning that ordinary users should not be trained to click through. Transport encryption belongs
  between native Syndro clients in phase 5.
