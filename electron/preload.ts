import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("electronAPI", {
  platform: process.platform,
  resizeWindow: (width: number, height: number) => {
    ipcRenderer.send("resize-window", { width, height });
  },
  fetchOg: (url: string) => ipcRenderer.invoke("fetch-og", url),
  showManualPopup: (x: number, y: number, deviceId: string | null, duration: string) => {
    ipcRenderer.send("show-manual-popup", { x, y, deviceId, duration });
  },
  closeManualPopup: () => {
    ipcRenderer.send("close-manual-popup");
  },
  sendManualSelection: (deviceId: string, duration: string) => {
    ipcRenderer.send("manual-selection", { deviceId, duration });
  },
  onManualSelection: (cb: (data: { deviceId: string; duration: string }) => void) => {
    ipcRenderer.on("manual-selection", (_e, data) => cb(data));
  },
  onManualPopupClosed: (cb: () => void) => {
    ipcRenderer.on("manual-popup-closed", () => cb());
  },
  showLoginPopup: (x: number, y: number) => {
    ipcRenderer.send("show-login-popup", { x, y });
  },
  showSettingsPopup: (x: number, y: number) => {
    ipcRenderer.send("show-settings-popup", { x, y });
  },
  authLogin: (email: string, password: string) => ipcRenderer.invoke("auth-login", email, password),
  authRegister: (email: string, username: string, password: string) => ipcRenderer.invoke("auth-register", email, username, password),
  authLogout: () => ipcRenderer.invoke("auth-logout"),
  authMe: () => ipcRenderer.invoke("auth-me"),
  authRestore: () => ipcRenderer.invoke("auth-restore"),
  authStoredUser: () => ipcRenderer.invoke("auth-stored-user"),
  authGoogle: () => ipcRenderer.invoke("auth-google"),
  onAuthChanged: (cb: (user: any) => void) => {
    ipcRenderer.on("auth-changed", (_e, user) => cb(user));
  },
  sendLogin: (username: string) => {
    ipcRenderer.send("login-success", { username });
  },
  openExternal: (url: string) => {
    ipcRenderer.send("open-external", url);
  },
  updateHotkey: (accelerator: string) => {
    ipcRenderer.send("update-hotkey", accelerator);
  },
  updateCloseToTray: (value: boolean) => {
    ipcRenderer.send("update-close-to-tray", value);
  },
  quitApp: () => {
    ipcRenderer.send("quit-app");
  },
  setOpenAtLogin: (value: boolean) => {
    ipcRenderer.send("set-open-at-login", value);
  },
  getOpenAtLogin: () => ipcRenderer.invoke("get-open-at-login"),
  uploadContent: (data: any) => ipcRenderer.invoke("upload-content", data),
  updateSkip: (version: string) => ipcRenderer.send("update-skip", version),
  updateLater: () => ipcRenderer.send("update-later"),
  updateInstall: () => ipcRenderer.send("update-install"),
  updateRestart: () => ipcRenderer.send("update-restart"),
  checkForUpdates: () => ipcRenderer.send("check-for-updates"),
  onUpdateProgress: (cb: (pct: number) => void) => {
    ipcRenderer.on("update-download-progress", (_e, pct) => cb(pct));
  },
  onUpdateDownloaded: (cb: () => void) => {
    ipcRenderer.on("update-downloaded", () => cb());
  },
  showSourcesPopup: (x: number, y: number) => {
    ipcRenderer.send("show-sources-popup", { x, y });
  },
  detectVaults: () => ipcRenderer.invoke("detect-vaults"),
  selectFolder: () => ipcRenderer.invoke("select-folder"),
  connectSource: (type: string, folderPath: string) => ipcRenderer.invoke("connect-source", type, folderPath),
  disconnectSource: (type: string) => ipcRenderer.send("disconnect-source", type),
  updateSourceConfig: (type: string, config: any) => ipcRenderer.send("update-source-config", type, config),
  getSources: () => ipcRenderer.invoke("get-sources"),
  syncNow: (type: string) => ipcRenderer.invoke("sync-now", type),
  syncAll: () => ipcRenderer.invoke("sync-all"),
  setSyncFrequency: (freq: string) => ipcRenderer.send("set-sync-frequency", freq),
  getSyncFrequency: () => ipcRenderer.invoke("get-sync-frequency"),
  resizeSelf: (width: number, height: number) => {
    ipcRenderer.send("resize-self", { width, height });
  },
  resizePopup: (height: number) => {
    ipcRenderer.send("resize-popup", { height });
  },
  onSystemContext: (cb: (ctx: { selectedText: string; browserUrl: string }) => void) => {
    ipcRenderer.on("system-context", (_e, ctx) => cb(ctx));
  },
  onWindowShown: (cb: () => void) => {
    ipcRenderer.on("window-shown", () => cb());
  },
});
