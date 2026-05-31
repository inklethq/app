// scripts/build-native.mjs —— 针对 Electron ABI 构建原生 addon
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

if (process.platform !== "darwin") {
  console.log("[build-native] non-macOS, skipping");
  process.exit(0);
}

const require = createRequire(import.meta.url);
const electronVer = require("electron/package.json").version;
const nodeGyp = require.resolve("node-gyp/bin/node-gyp.js");
const dir = path.join(__dirname, "../native/services");
const arch = process.env.NATIVE_ARCH || process.arch;

console.log(`[build-native] electron ${electronVer}, arch ${arch}`);
execFileSync(
  process.execPath,
  [
    nodeGyp, "rebuild",
    `--target=${electronVer}`,
    "--dist-url=https://electronjs.org/headers",
    `--arch=${arch}`,
  ],
  { cwd: dir, stdio: "inherit", env: process.env },
);
console.log("[build-native] done");
