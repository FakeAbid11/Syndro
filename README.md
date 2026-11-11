# Syndro

Local-network file sharing for **Android, Linux and Windows**. No cloud, no account, no relay
server, no internet connection required — both devices just have to reach each other on the same
Wi-Fi or hotspot.

**Status: desktop + Android, browser mode.** A desktop app or an Android phone runs a transfer
server and serves a small web UI. Any phone, tablet, PC or laptop on the same network can open it in
a browser and send or receive files without installing anything. The Android app can also send
files to another Syndro share link.

## What works today

- QR pairing plus copyable share URLs, scoped by a random 24-character capability token — the
  Android app both shows a QR code and scans one with CameraX + ZXing (no Play Services)
- Chunked, resumable uploads (4 MiB chunks, automatic retry, server-reported resume offset)
- Downloads with HTTP `Range`, so a dropped transfer resumes instead of restarting
- Live transfer list, refreshed without a page reload
- Filenames are display-only: every file is stored under a generated ID, so a malicious
  `../../etc/passwd` cannot escape the receive directory
- Desktop shares expire after 24 hours with per-client rate limiting on bad tokens; Android shares
  for as long as the foreground service runs
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

## Windows installer

CI builds a real installer, so the target machine needs neither Node nor a build toolchain.

1. Open **Actions**, pick the latest green `CI` run, and download the `syndro-windows-setup`
   artifact. Unzip it to get `Syndro-Setup-0.1.0.exe`.
2. Run the installer. It is a per-user install (no admin prompt) and lets you choose the folder.
3. SmartScreen warns because the build is not code-signed yet: **More info → Run anyway**.

The installer adds Start Menu and desktop shortcuts and registers an uninstaller under
**Apps & features**. Electron and the web UI are bundled; received files still go to
`Downloads/Syndro`. Rebuilding the installer locally is just `npm run dist:win` in `desktop/`
(first run downloads Electron and NSIS, so it needs network and a Windows host).

## Android app

The APK is built in CI, so no local Android toolchain is needed.

1. Open the **Actions** tab, pick the latest green `CI` run, and download the
   `syndro-android-debug` artifact (it contains `app-debug.apk`).
2. Sideload it. Android will ask you to allow installs from your browser or file manager.
3. Tap **Start sharing**. The phone serves the same web UI on port `47821`, so any browser on the
   same Wi-Fi or hotspot can reach it.
4. To send from the phone, paste the other device's share link (`http://…:47821/s/<token>`) or tap
   **Scan QR** and point the camera at the QR code on the other device, then **Choose files**. The
   phone copies the document to cache, uploads it in resumable 4 MiB chunks, and deletes the copy.

Received files live in the app's private storage. Use **Save** to write a copy to
`Downloads/Syndro`, or **Share** to hand it to another app through `FileProvider`.

The share server runs in a `dataSync` foreground service, so a large transfer survives the screen
turning off. Android's foreground-service limit still applies to very long sessions — the
notification is the source of truth for whether the server is alive.

The debug APK is signed with the CI debug key. Release signing, like `linkphone`, needs a keystore
in repository secrets before an in-place update path makes sense.

## Tests

```bash
cd desktop
npm test        # build + node --test
```

Covered: IPv6/IPv4 classification and URL formatting, share-URL ranking, token gating, chunked
upload, resume conflicts, `Range` downloads, path traversal, and link expiry.

## Roadmap

1. **Phase 3 — mDNS discovery.** `_syndro._tcp.local` plus QR fallback, so no URL has to be typed.
2. **Phase 4 — remaining packaging.** AppImage/deb for Linux, code signing for Windows, a release
   keystore for Android, and tagged GitHub releases instead of workflow artifacts.
3. **Phase 5 — hardening.** Optional per-session PIN, encrypted transport between native clients,
   transfer history, and folder sends.

## Design notes

- The Electron window loads the exact same loopback URL that a browser would, so there is one UI
  implementation, one API, and one thing to test.
- The token is the capability. There is no unauthenticated endpoint that reveals device names,
  file names, or file contents.
- `http://` is deliberate for browser mode: a self-signed certificate produces a full-page browser
  warning that ordinary users should not be trained to click through. Transport encryption belongs
  between native Syndro clients in phase 5.
