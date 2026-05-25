import { app, shell } from "electron";
import fs from "node:fs";
import path from "node:path";

const AUTH_URL = "https://auth.iminklet.com";

interface AuthUser {
  id: string;
  email: string;
  username: string;
  plan: string;
}

interface AuthState {
  accessToken: string | null;
  refreshToken: string | null;
  user: AuthUser | null;
}

const authFile = () => path.join(app.getPath("userData"), "inklet-auth.json");

function readAuth(): AuthState {
  try {
    return JSON.parse(fs.readFileSync(authFile(), "utf-8"));
  } catch {
    return { accessToken: null, refreshToken: null, user: null };
  }
}

function writeAuth(state: AuthState) {
  fs.writeFileSync(authFile(), JSON.stringify(state, null, 2));
}

async function request<T>(
  endpoint: string,
  options?: RequestInit & { token?: string }
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(options?.token ? { Authorization: `Bearer ${options.token}` } : {}),
  };
  const res = await fetch(`${AUTH_URL}${endpoint}`, {
    ...options,
    headers: { ...headers, ...options?.headers as Record<string, string> },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`${res.status}: ${body}`);
  }
  return res.json();
}

async function refreshTokens(): Promise<boolean> {
  const state = readAuth();
  if (!state.refreshToken) return false;
  try {
    const data = await request<{ accessToken: string; refreshToken: string }>(
      "/auth/refresh",
      { method: "POST", body: JSON.stringify({ refreshToken: state.refreshToken }) }
    );
    state.accessToken = data.accessToken;
    state.refreshToken = data.refreshToken;
    writeAuth(state);
    return true;
  } catch {
    state.accessToken = null;
    state.refreshToken = null;
    state.user = null;
    writeAuth(state);
    return false;
  }
}

async function authedRequest<T>(endpoint: string, options?: RequestInit): Promise<T> {
  let state = readAuth();
  if (!state.accessToken) throw new Error("Not authenticated");

  try {
    return await request<T>(endpoint, { ...options, token: state.accessToken });
  } catch (e: any) {
    if (e.message?.startsWith("401")) {
      const refreshed = await refreshTokens();
      if (!refreshed) throw new Error("Session expired");
      state = readAuth();
      return request<T>(endpoint, { ...options, token: state.accessToken! });
    }
    throw e;
  }
}

export async function login(email: string, password: string): Promise<AuthUser> {
  const data = await request<{
    accessToken: string; refreshToken: string;
    user: AuthUser;
  }>("/auth/login", {
    method: "POST",
    body: JSON.stringify({ email, password }),
  });
  writeAuth({ accessToken: data.accessToken, refreshToken: data.refreshToken, user: data.user });
  return data.user;
}

export async function register(email: string, username: string, password: string): Promise<AuthUser> {
  const data = await request<{
    accessToken: string; refreshToken: string;
    user: AuthUser;
  }>("/auth/register", {
    method: "POST",
    body: JSON.stringify({ email, username, password }),
  });
  writeAuth({ accessToken: data.accessToken, refreshToken: data.refreshToken, user: data.user });
  return data.user;
}

export async function logout(): Promise<void> {
  const state = readAuth();
  if (state.accessToken && state.refreshToken) {
    try {
      await request("/auth/logout", {
        method: "POST",
        token: state.accessToken,
        body: JSON.stringify({ refreshToken: state.refreshToken }),
      });
    } catch { /* best effort */ }
  }
  writeAuth({ accessToken: null, refreshToken: null, user: null });
}

export async function getMe(): Promise<AuthUser | null> {
  try {
    const user = await authedRequest<AuthUser>("/auth/me");
    const state = readAuth();
    state.user = { id: user.id, email: user.email, username: user.username, plan: (user as any).plan || "free" };
    writeAuth(state);
    return state.user;
  } catch {
    return null;
  }
}

export function getStoredUser(): AuthUser | null {
  return readAuth().user;
}

export function getStoredTokens() {
  const state = readAuth();
  return { accessToken: state.accessToken, refreshToken: state.refreshToken };
}

export async function tryRestore(): Promise<AuthUser | null> {
  const state = readAuth();
  if (!state.accessToken && !state.refreshToken) return null;
  if (state.accessToken) {
    const user = await getMe();
    if (user) return user;
  }
  const refreshed = await refreshTokens();
  if (!refreshed) return null;
  return getMe();
}

let oauthResolve: ((user: AuthUser | null) => void) | null = null;

export function startGoogleOAuth(): Promise<AuthUser | null> {
  return new Promise((resolve) => {
    oauthResolve = resolve;
    shell.openExternal(`${AUTH_URL}/auth/oauth/google?client=desktop`);
  });
}

export async function handleOAuthCallback(url: string): Promise<AuthUser | null> {
  try {
    const parsed = new URL(url);
    const accessToken = parsed.searchParams.get("accessToken");
    const refreshToken = parsed.searchParams.get("refreshToken");

    if (accessToken && refreshToken) {
      writeAuth({ accessToken, refreshToken, user: null });
      const user = await getMe();
      if (oauthResolve) {
        oauthResolve(user);
        oauthResolve = null;
      }
      return user;
    }
  } catch { /* invalid url */ }
  return null;
}

export function registerProtocol() {
  app.setAsDefaultProtocolClient("inklet");
}
