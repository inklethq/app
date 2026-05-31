import { app, BrowserWindow, clipboard, dialog, globalShortcut, ipcMain, screen, shell } from "electron";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let win: BrowserWindow | null = null;
let popup: BrowserWindow | null = null;
let popupBlurLocked = false;
let currentShortcut = "CommandOrControl+Shift+I";
let closeToTray = false;

function runAppleScript(script: string): Promise<string> {
  return new Promise((resolve) => {
    if (process.platform !== "darwin") { resolve(""); return; }
    execFile("osascript", ["-e", script], { timeout: 2000 }, (err, stdout) => {
      resolve(err ? "" : stdout.trim());
    });
  });
}

function delay(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function getSelectedText(): Promise<string> {
  if (process.platform !== "darwin") return "";
  const saved = clipboard.readText();
  clipboard.writeText("");
  await runAppleScript(`tell application "System Events" to keystroke "c" using command down`);
  await delay(80);
  const selected = clipboard.readText();
  clipboard.writeText(saved);
  return selected;
}

function getBrowserUrlScript(appName: string): string | null {
  const chromium = ["Google Chrome", "Google Chrome Canary", "Chromium", "Microsoft Edge", "Brave Browser", "Vivaldi", "Arc"];
  if (chromium.includes(appName)) {
    return `tell application "${appName}" to return URL of active tab of front window`;
  }
  if (appName === "Safari") {
    return `tell application "Safari" to return URL of front document`;
  }
  if (appName === "Firefox") {
    return `tell application "System Events" to tell process "Firefox" to return value of attribute "AXValue" of text field 1 of toolbar 1 of front window`;
  }
  return null;
}

async function getSystemContext(): Promise<{ selectedText: string; browserUrl: string }> {
  const frontApp = await runAppleScript(`
    tell application "System Events" to return name of first application process whose frontmost is true
  `);

  const urlScript = getBrowserUrlScript(frontApp);

  const [selectedText, browserUrl] = await Promise.all([
    getSelectedText(),
    urlScript ? runAppleScript(`try\n${urlScript}\non error\nreturn ""\nend try`) : Promise.resolve(""),
  ]);
  return { selectedText, browserUrl };
}

function registerHotkey(accelerator: string) {
  globalShortcut.unregisterAll();
  if (!accelerator) return;
  try {
    globalShortcut.register(accelerator, async () => {
      if (!win) return;
      if (win.isVisible() && win.isFocused()) {
        win.hide();
      } else {
        const ctx = await getSystemContext();
        win.show();
        win.focus();
        if (ctx.selectedText || ctx.browserUrl) {
          win.webContents.send("system-context", ctx);
        }
        win.webContents.send("window-shown");
      }
    });
    currentShortcut = accelerator;
  } catch {
    if (currentShortcut && currentShortcut !== accelerator) {
      registerHotkey(currentShortcut);
    }
  }
}

function createWindow() {
  win = new BrowserWindow({
    width: 500,
    height: 179,
    icon: path.join(__dirname, "../resources/icon.png"),
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 14, y: 12 },
    transparent: true,
    hasShadow: true,
    alwaysOnTop: false,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.mjs"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.on("close", (e) => {
    if (closeToTray && win) {
      e.preventDefault();
      win.hide();
    }
  });


  if (process.env.VITE_DEV_SERVER_URL) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    win.loadFile(path.join(__dirname, "../dist/index.html"));
  }

  currentShortcut = getHotkey();
  closeToTray = getCloseToTray();
  registerHotkey(currentShortcut);
  initServices(() => win);

  initAutoUpdater(win!, path.join(__dirname, "preload.mjs"));
  if (!process.env.VITE_DEV_SERVER_URL) {
    setTimeout(checkForUpdates, 3000);
  }
}

ipcMain.on("resize-window", (_e, { width, height }: { width: number; height: number }) => {
  if (win) win.setSize(width, height, true);
});

ipcMain.on("resize-self", (e, { width, height }: { width: number; height: number }) => {
  const sender = BrowserWindow.fromWebContents(e.sender);
  if (sender && !sender.isDestroyed()) {
    const [w] = sender.getSize();
    sender.setSize(width || w, Math.round(height), false);
  }
});

ipcMain.on("resize-popup", (_e, { height }: { height: number }) => {
  if (popup && !popup.isDestroyed()) {
    const [w] = popup.getSize();
    popup.setSize(w, Math.round(height), false);
  }
});

ipcMain.on("show-manual-popup", (_e, { x, y, deviceId, duration }: { x: number; y: number; deviceId: string | null; duration: string }) => {
  showPopup("manual", 200, 237, x, y, { deviceId: deviceId ?? "", duration });
});

ipcMain.on("close-manual-popup", () => {
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
});

ipcMain.on("manual-selection", (_e, data: { deviceId: string; duration: string }) => {
  if (win) win.webContents.send("manual-selection", data);
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
});

function showPopup(type: string, w: number, h: number, anchorX: number, anchorY: number, extraParams?: Record<string, string>) {
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
  const display = screen.getDisplayNearestPoint({ x: anchorX, y: anchorY });
  let px = Math.round(anchorX - w);
  let py = Math.round(anchorY + 8);
  if (py + h > display.workArea.y + display.workArea.height) py = Math.round(anchorY - h - 8);

  popup = new BrowserWindow({
    width: w, height: h, x: px, y: py,
    frame: false, transparent: true, hasShadow: true,
    alwaysOnTop: true, resizable: false, skipTaskbar: true, focusable: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.mjs"),
      contextIsolation: true, nodeIntegration: false,
    },
  });

  const params = new URLSearchParams({ popup: type, ...extraParams });
  if (process.env.VITE_DEV_SERVER_URL) {
    popup.loadURL(`${process.env.VITE_DEV_SERVER_URL}?${params}`);
  } else {
    popup.loadFile(path.join(__dirname, "../dist/index.html"), { search: params.toString() });
  }

  popup.on("blur", () => {
    if (popupBlurLocked) return;
    if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
  });
  popup.on("closed", () => { popup = null; });
}

ipcMain.on("show-login-popup", (_e, { x, y }: { x: number; y: number }) => {
  showPopup("login", 260, 265, x, y);
});

ipcMain.on("show-settings-popup", (_e, { x, y }: { x: number; y: number }) => {
  showPopup("settings", 240, 215, x, y, {
    hotkey: currentShortcut,
    closeToTray: closeToTray ? "true" : "false",
  });
});

ipcMain.handle("auth-login", async (_e, email: string, password: string) => {
  const user = await login(email, password);
  if (win) win.webContents.send("auth-changed", user);
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
  return user;
});

ipcMain.handle("auth-register", async (_e, email: string, username: string, password: string) => {
  const user = await register(email, username, password);
  if (win) win.webContents.send("auth-changed", user);
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
  return user;
});

ipcMain.handle("auth-logout", async () => {
  await logout();
  if (win) win.webContents.send("auth-changed", null);
});

ipcMain.handle("auth-me", async () => {
  return getMe();
});

ipcMain.handle("auth-restore", async () => {
  return tryRestore();
});

ipcMain.handle("auth-stored-user", () => {
  return getStoredUser();
});

ipcMain.handle("auth-google", async () => {
  const user = await startGoogleOAuth();
  if (user && win) win.webContents.send("auth-changed", user);
  return user;
});

ipcMain.on("login-success", (_e, data: { username: string }) => {
  if (win) win.webContents.send("auth-changed", data);
  if (popup && !popup.isDestroyed()) { popup.close(); popup = null; }
});

ipcMain.handle("upload-content", async (_e, data: any) => {
  return uploadContent(data);
});

ipcMain.on("check-for-updates", () => {
  checkForUpdates();
});

ipcMain.on("open-external", (_e, url: string) => {
  shell.openExternal(url);
});

ipcMain.on("update-hotkey", (_e, accelerator: string) => {
  registerHotkey(accelerator);
  if (accelerator) storeHotkey(accelerator);
});

ipcMain.on("update-close-to-tray", (_e, value: boolean) => {
  closeToTray = value;
  storeCloseToTray(value);
});

ipcMain.on("quit-app", () => {
  closeToTray = false;
  app.quit();
});

ipcMain.on("set-open-at-login", (_e, value: boolean) => {
  app.setLoginItemSettings({ openAtLogin: value });
});

ipcMain.handle("get-open-at-login", () => {
  return app.getLoginItemSettings().openAtLogin;
});

ipcMain.handle("fetch-og", async (_e, url: string) => {
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; InkletPortal/1.0)" },
      signal: AbortSignal.timeout(8000),
    });
    const html = await res.text();

    function getMetaContent(property: string): string | null {
      const patterns = [
        new RegExp(`<meta[^>]+property=["']${property}["'][^>]+content=["']([^"']*)["']`, "i"),
        new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+property=["']${property}["']`, "i"),
        new RegExp(`<meta[^>]+name=["']${property}["'][^>]+content=["']([^"']*)["']`, "i"),
        new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+name=["']${property}["']`, "i"),
      ];
      for (const p of patterns) {
        const m = html.match(p);
        if (m?.[1]) return m[1];
      }
      return null;
    }

    const titleMatch = html.match(/<title[^>]*>([^<]*)<\/title>/i);
    const hostname = new URL(url).hostname;

    return {
      title: getMetaContent("og:title") || titleMatch?.[1]?.trim() || hostname,
      description: getMetaContent("og:description") || getMetaContent("description") || "",
      image: getMetaContent("og:image") || null,
      url,
      hostname,
    };
  } catch {
    const hostname = new URL(url).hostname;
    return { title: hostname, description: "", image: null, url, hostname };
  }
});

// --- Source management (Obsidian / Logseq) ---

import { loadSources, saveSource, removeSource, updateSourceConfig, syncSource, getSyncFrequency, setSyncFrequency, getHotkey, setHotkey as storeHotkey, getCloseToTray, setCloseToTray as storeCloseToTray, detectObsidianVaults, detectLogseqGraphs } from "./sync.js";
import { login, register, logout, getMe, tryRestore, startGoogleOAuth, getStoredUser, handleOAuthCallback, registerProtocol } from "./auth.js";
import { initAutoUpdater, checkForUpdates } from "./updater.js";
import { uploadContent } from "./upload.js";
import { initServices } from "./services.js";

let syncTimer: ReturnType<typeof setInterval> | null = null;

function startSyncTimer() {
  if (syncTimer) clearInterval(syncTimer);
  const freq = getSyncFrequency();
  if (freq === "Manual") return;
  const ms = { "12h": 43200000, "1d": 86400000, "1w": 604800000 }[freq];
  if (!ms) return;
  syncTimer = setInterval(() => {
    const store = loadSources();
    for (const type of Object.keys(store.sources)) {
      const result = syncSource(type);
      if (result) {
        const { diff } = result;
        console.log(`[sync:${type}] +${diff.added.length} ~${diff.modified.length} -${diff.deleted.length}`);
      }
    }
  }, ms);
}

ipcMain.handle("detect-vaults", () => {
  return { obsidian: detectObsidianVaults(), logseq: detectLogseqGraphs() };
});

ipcMain.handle("select-folder", async () => {
  const parent = popup ?? win;
  if (!parent) return null;
  popupBlurLocked = true;
  const result = await dialog.showOpenDialog(parent, {
    properties: ["openDirectory"],
    message: "Select vault or graph folder",
  });
  popupBlurLocked = false;
  if (popup) popup.focus();
  if (result.canceled || !result.filePaths[0]) return null;
  return result.filePaths[0];
});

ipcMain.handle("connect-source", (_e, type: string, folderPath: string) => {
  const state = saveSource(type, folderPath);
  return { totalDocs: state.files.length, syncedDocs: state.files.length, syncing: false };
});

ipcMain.on("disconnect-source", (_e, type: string) => {
  removeSource(type);
});

ipcMain.on("update-source-config", (_e, type: string, config: Record<string, any>) => {
  updateSourceConfig(type, config);
});

ipcMain.handle("get-sources", () => {
  const store = loadSources();
  const result: Record<string, any> = { obsidian: null, logseq: null };
  for (const [type, state] of Object.entries(store.sources)) {
    result[type] = {
      path: state.path,
      name: state.name,
      totalDocs: state.files.length,
      syncedDocs: state.files.length,
      autoSyncNew: state.autoSyncNew,
      syncing: false,
      lastSynced: state.lastSynced,
    };
  }
  return result;
});

ipcMain.handle("sync-now", (_e, type: string) => {
  const result = syncSource(type);
  if (!result) return null;
  const { diff, contents } = result;
  console.log(`[sync:${type}] +${diff.added.length} ~${diff.modified.length} -${diff.deleted.length}`);
  console.log(`[sync:${type}] payload: ${Object.keys(contents).length} files, ${JSON.stringify(contents).length} bytes`);
  return { added: diff.added.length, modified: diff.modified.length, deleted: diff.deleted.length };
});

ipcMain.handle("sync-all", () => {
  const store = loadSources();
  const results: Record<string, any> = {};
  for (const type of Object.keys(store.sources)) {
    const result = syncSource(type);
    if (result) {
      const { diff } = result;
      results[type] = { added: diff.added.length, modified: diff.modified.length, deleted: diff.deleted.length };
      console.log(`[sync:${type}] +${diff.added.length} ~${diff.modified.length} -${diff.deleted.length}`);
    }
  }
  return results;
});

ipcMain.on("set-sync-frequency", (_e, freq: string) => {
  setSyncFrequency(freq);
  startSyncTimer();
});

ipcMain.handle("get-sync-frequency", () => getSyncFrequency());

ipcMain.on("show-sources-popup", (_e, { x, y }: { x: number; y: number }) => {
  showPopup("sources", 260, 200, x, y);
});

registerProtocol();

async function handleDeepLink(url: string) {
  if (url.startsWith("inklet://")) {
    const user = await handleOAuthCallback(url);
    if (user && win) {
      win.webContents.send("auth-changed", user);
      win.show();
      win.focus();
    }
  }
}

app.on("open-url", (_e, url) => handleDeepLink(url));

app.on("second-instance", (_e, argv) => {
  const url = argv.find((a) => a.startsWith("inklet://"));
  if (url) handleDeepLink(url);
  if (win) { win.show(); win.focus(); }
});

if (!app.requestSingleInstanceLock()) {
  app.quit();
}

app.whenReady().then(() => {
  createWindow();
  startSyncTimer();
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  } else if (win && !win.isVisible()) {
    win.show();
  }
});
