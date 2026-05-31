// electron/services.ts
import { BrowserWindow } from "electron";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { normalizeServicePayload } from "./service-normalize.js";
import type { ServicePayload } from "./service-types.js";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

interface ServicesAddon {
  register(cb: (payload: ServicePayload) => void): void;
}

function loadAddon(): ServicesAddon | null {
  if (process.platform !== "darwin") return null;
  const candidates = [
    ...(process.resourcesPath ? [path.join(process.resourcesPath, "inklet_services.node")] : []),
    path.join(__dirname, "../native/services/build/Release/inklet_services.node"),
  ];
  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) return require(p) as ServicesAddon;
    } catch (e) {
      console.error("[services] failed to load addon at", p, e);
    }
  }
  console.warn("[services] native addon not found; Services menu disabled");
  return null;
}

export function initServices(getWindow: () => BrowserWindow | null) {
  const addon = loadAddon();
  if (!addon) return;

  addon.register((payload: ServicePayload) => {
    const items = normalizeServicePayload(payload, (p) => fs.readFileSync(p));
    if (items.length === 0) return;
    const win = getWindow();
    if (!win || win.isDestroyed()) return;
    win.show();
    win.focus();
    const send = () => {
      if (win.isDestroyed()) return;
      win.webContents.send("service-content", items);
      // mirror the hotkey path: focus the input on activation
      win.webContents.send("window-shown");
    };
    if (win.webContents.isLoading()) {
      win.webContents.once("did-finish-load", send);
    } else {
      send();
    }
  });
}
