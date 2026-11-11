import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import * as fsp from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import electron from "electron";

// Run against the archive and web assets that electron-builder actually ships,
// not a duplicate preload or a mocked renderer bridge. CI builds them first.
const resources = path.resolve("release", "win-unpacked", "resources");
const archive = path.join(resources, "app.asar");
const web = path.join(resources, "web");
const entry = path.resolve("dist", "test", "electron-smoke.js");
if (!existsSync(archive) || !existsSync(path.join(web, "index.html")) || !existsSync(entry)) {
  throw new Error("The packaged Windows app is missing. Run this smoke test after dist:win in CI.");
}

const root = await fsp.mkdtemp(path.join(os.tmpdir(), "syndro-electron-smoke-"));
try {
  const code = await new Promise((resolve, reject) => {
    const child = spawn(electron, [entry, archive, web, root, path.resolve("release", "electron-smoke.png")], {
      stdio: "inherit",
      env: { ...process.env, ELECTRON_DISABLE_SECURITY_WARNINGS: "true" },
    });
    const timeout = setTimeout(() => {
      console.error("Electron smoke test timed out.");
      child.kill();
    }, 120_000);
    child.once("error", (error) => { clearTimeout(timeout); reject(error); });
    child.once("exit", (exitCode) => { clearTimeout(timeout); resolve(exitCode ?? 1); });
  });
  process.exitCode = Number(code);
} finally {
  await fsp.rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 200 });
}
