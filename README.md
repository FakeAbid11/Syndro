# Syndro

Local-network file sharing for **Android, Linux and Windows**. No cloud, no account, no relay
server, no internet connection required — both devices just have to reach each other on the same
Wi-Fi or hotspot.

**Status: desktop + Android, with browser mode.** A desktop app or Android phone runs a transfer
server and serves a small web UI. Any phone, tablet, PC or laptop on the same network can open it in
a browser and transfer files without installing anything. Both native apps can also send directly
to another Syndro device after its share link has been verified.

## What works today

- QR pairing plus copyable share URLs, scoped by an 8-character code from the LinkPhone alphabet
  (`A–Z` without `I`/`O`, plus `2–9`), shown as `ABCD 2345` — the Android app both shows a QR code
  and scans one with CameraX + ZXing (no Play Services)
- Zero-typing host discovery over `_syndro._tcp.local`: desktop and Android advertise, while
  Android lists nearby devices and asks only for the 8-character code. The code is never put in
  the mDNS TXT record; QR remains the fallback when multicast discovery is blocked
- Chunked, resumable uploads (4 MiB chunks, automatic retry, server-reported resume offset)
- Downloads with HTTP `Range`, so a dropped transfer resumes instead of restarting
- Explicit **App to app** sending to a verified receiver on Windows and Android; desktop
  **Share a link** publishes on this device for someone else to download
- Honest completion states: **Sent** appears only after the receiver confirms the exact file;
  publishing says **Shared** and never masquerades as an incoming transfer
- Separate Shared, Received, and legacy-file lists, refreshed without a page reload
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
a browser as if it were usable. Android's native sender can pass that zone to a scoped IPv6 socket,
so `fe80::` remains a real fallback when a router isolates IPv4 clients but still forwards IPv6.

mDNS is the normal no-typing route. A service advertises only its stable device ID, display name,
protocol version, and port — never the capability code. Tap **Find nearby devices**, choose one,
and enter the code shown on its screen. If the router blocks multicast DNS, scan the full share URL
from its QR code instead.

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

## Send versus share

The desktop app deliberately keeps these as two different operations. The current Android screen
starts with a plain **Receive** or **Send** choice, then reveals only the next pairing action.

### App to app

1. Put both devices on the same Wi-Fi or hotspot. Open Syndro on the receiving Windows PC. On a
   receiving Android phone, choose **Receive**, then **Start receiving**. Its receiving panel shows
   the QR code, grouped pairing code, and a copyable receiver link.
2. On the sending Windows PC, choose **App to app**, paste the receiver's full
   `http://…/s/ABCD2345` link, and select **Connect**.
3. On a sending Android phone, choose **Send**, then use **Find nearby devices**, choose the receiver
   and enter its code, or **Scan receiver QR code**. Either route verifies the receiver automatically.
   **Enter a receiver link instead** reveals manual link entry only when it is needed.
4. Wait for **Paired with** and the receiver's name, then choose files (or drop them on Windows).
   To send back, swap the sending/receiving roles and pair with the other device's link.

This supports Windows-to-Windows, Windows-to-Android, and Android-to-Android transfers in either
direction. Native transports send chunks directly to the selected receiver, not to the sender's
own server or a LAN proxy. The destination stays fixed while files are queued or transferred;
Android also locks pairing while its file picker is open. **Sent** appears only after the receiver
confirms the file ID and size. Outgoing files do not appear in the sender's **Received** list with
a redundant Save button.

### Share a link

Choose **Share a link** to keep a file on this device and make it available through this device's
QR/share URL. The app labels it **Shared**, not Sent. Open the sender's share link on the other
device, then use **Save** there. Sharing a link makes a file available; it does not itself deliver
the file to another device.

In ordinary browser mode, the device hosting the page is always the receiver. The page names that
destination before upload and hides that browser tab's own completed uploads from its download
list, including after a refresh.

## Windows installer

CI builds a real installer, so the target machine needs neither Node nor a build toolchain.

1. Download [`Syndro-Setup-0.2.1.exe`](https://github.com/FakeAbid11/Syndro/releases/download/v0.2.1/Syndro-Setup-0.2.1.exe)
   from the [v0.2.1 release](https://github.com/FakeAbid11/Syndro/releases/tag/v0.2.1).
2. Run the installer. It is a per-user install (no admin prompt) and lets you choose the folder.
3. SmartScreen warns because the build is not code-signed yet: **More info → Run anyway**.

The installer adds Start Menu and desktop shortcuts and registers an uninstaller under
**Apps & features**. Electron and the web UI are bundled; received files still go to
`Downloads/Syndro`. Rebuilding the installer locally is just `npm run dist:win` in `desktop/`
(first run downloads Electron and NSIS, so it needs network and a Windows host).

## Android app

The APK is built in CI, so no local Android toolchain is needed.

1. Download [`Syndro-0.2.1-android-debug.apk`](https://github.com/FakeAbid11/Syndro/releases/download/v0.2.1/Syndro-0.2.1-android-debug.apk)
   from the [v0.2.1 release](https://github.com/FakeAbid11/Syndro/releases/tag/v0.2.1).
2. Sideload it. Android will ask you to allow installs from your browser or file manager.
3. Choose **Receive**, then **Start receiving**. The phone serves the same web UI on port `47821`,
   so any browser or native Syndro sender on the same Wi-Fi or hotspot can reach it.
4. To send from the phone, choose **Send**. Tap **Find nearby devices**, choose the receiver, and type
   its displayed code, or use **Scan receiver QR code** when discovery is blocked. Manual link entry
   remains available as a fallback. Wait for the verified receiver card before tapping **Choose files**.
   The phone copies each document to cache, uploads it in resumable 4 MiB chunks, and deletes the
   copy.

Received files live in the app's private storage. Use **Save** to write a copy to
`Downloads/Syndro`, or **Share** to hand it to another app through `FileProvider`.

The share server runs in a `dataSync` foreground service, so a large transfer survives the screen
turning off. Android's foreground-service limit still applies to very long sessions — the
notification is the source of truth for whether the server is alive.

The debug APK is signed with the CI debug key. Release signing, like `linkphone`, needs a keystore
in repository secrets before an in-place update path makes sense.

### Upgrading from earlier versions

- The Windows installer is still unsigned. Installing v0.2.1 over an earlier release preserves the
  app's local data and stable device identity.
- v0.1 did not record whether an existing desktop file was locally shared or received. v0.2.1
  preserves those files without guessing and shows them under **Earlier files**.
- The Android APK remains debug-signed. If Android reports that the package conflicts with the
  installed app because CI signing keys differ, first use **Save**/**Share** to export any received
  files, then uninstall the older version and install v0.2.1. Uninstalling without exporting deletes
  files in the app's private storage.

## Tests

```bash
cd desktop
npm test        # build + node --test
```

Covered: IPv6/IPv4 classification and scoped URL formatting, share-URL ranking, mDNS advertisement
metadata (including code non-disclosure), token gating, chunked upload, resume conflicts, `Range`
downloads, path traversal, link expiry, persisted file direction, self-link rejection, receiver
confirmation, failed-connection clearing, real two-server native sends, and DOM regressions for the
duplicate Save bug. Windows CI also launches the packaged Electron app and verifies its sandboxed
preload, guarded IPC, Chromium `File`/`ArrayBuffer` chunks, selected-receiver delivery, and separate
Shared/Received lists. UI regressions also cover full copyable links, grouped pairing codes,
accessible transform-based progress, shared muted-text contrast, desktop/mobile layout, keyboard
focus, and reduced motion. The packaged smoke test saves full-page desktop and mobile-browser
screenshots for visual review.

Android CI also runs JVM tests for app-to-app link parsing, confirmed receiver identity, own-link
rejection, and exact completed-file confirmation before building the APK. Physical-device pairing
and native Android rendering still need device testing.

## Roadmap

1. **Phase 4 — remaining packaging.** AppImage/deb for Linux, code signing for Windows, and a
   release keystore for Android.
2. **Phase 5 — hardening.** Optional per-session PIN, encrypted transport between native clients,
   transfer history, and folder sends.

## Design notes

- The interface keeps graphite surfaces, restrained amber, and system fonts across web and Android.
  Pairing codes stay grouped as `ABCD 2345`; file direction and confirmed completion remain explicit.
- UI polish follows **unslop**, created by [Damir Sokolovsky (@heydamir)](https://x.com/heydamir),
  licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- The Electron window loads the same loopback UI that a browser would. Only that exact top-level
  owner window receives a sandbox-compatible preload bridge; remote pages, child frames, other
  windows, and navigated URLs cannot invoke native sending.
- The token is the capability, and it is now a short voice-friendly code: 8 symbols from a
  32-character alphabet (40 bits), with the same lowercase/grouped input accepted on Android.
  Desktop rate-limits bad tokens per client; there is no unauthenticated endpoint that reveals
  device names, file names, or file contents.
- `http://` is deliberate for browser mode: a self-signed certificate produces a full-page browser
  warning that ordinary users should not be trained to click through. Transport encryption belongs
  between native Syndro clients in phase 5.
