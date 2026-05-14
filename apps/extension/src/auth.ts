import { PLOT_APP_BASE } from "./config";
import { clearCachedToken, getCachedToken, setCachedToken } from "./storage";

// Find an open, logged-in app.plot.day tab (any subpath, any window) so the
// content script can hand us a fresh Clerk JWT. Falls back to undefined when
// the user has none open — the background opens app.plot.day for them.
async function findAppTab(): Promise<chrome.tabs.Tab | undefined> {
  const tabs = await chrome.tabs.query({
    url: [`${PLOT_APP_BASE}/*`, `${PLOT_APP_BASE.replace(/\/$/, "")}/*`],
  });
  return tabs.find((t) => typeof t.id === "number");
}

async function requestTokenFromTab(tabId: number): Promise<string | null> {
  // The clerk-bridge content script listens for { kind: "plot:getToken" }
  // and replies with { token: string | null, error?: string }.
  try {
    const response = (await chrome.tabs.sendMessage(tabId, {
      kind: "plot:getToken",
    })) as { token: string | null; error?: string } | undefined;
    return response?.token ?? null;
  } catch {
    // Content script not loaded yet (e.g. the tab was opened before the
    // extension was installed). Inject it on demand and retry once.
    try {
      await chrome.scripting.executeScript({
        target: { tabId },
        files: ["content-scripts/clerk-bridge.js"],
      });
    } catch {
      return null;
    }
    try {
      const response = (await chrome.tabs.sendMessage(tabId, {
        kind: "plot:getToken",
      })) as { token: string | null; error?: string } | undefined;
      return response?.token ?? null;
    } catch {
      return null;
    }
  }
}

export type TokenLookup =
  | { token: string }
  | { token: null; reason: "no-app-tab" | "not-signed-in" };

// Returns a fresh JWT or a reason the caller can act on. We don't proactively
// open app.plot.day here — the background script decides whether to do that
// (and surface a toast) based on which user action triggered the lookup.
export async function getToken(): Promise<TokenLookup> {
  const cached = await getCachedToken();
  if (cached) return { token: cached };

  const tab = await findAppTab();
  if (!tab?.id) return { token: null, reason: "no-app-tab" };

  const token = await requestTokenFromTab(tab.id);
  if (!token) return { token: null, reason: "not-signed-in" };

  await setCachedToken(token);
  return { token };
}

export async function invalidateToken(): Promise<void> {
  await clearCachedToken();
}
