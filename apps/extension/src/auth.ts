import { PLOT_APP_BASE, PLOT_SITE_BASE } from "./config";
import { clearCachedToken, getCachedToken, setCachedToken } from "./storage";

// Find an open, logged-in Plot tab so the content script can hand us a fresh
// Clerk JWT. Both the site (where users sign in) and the app load Clerk JS
// under the same `clerk.plot.day` frontend domain, so either host works.
async function findClerkHostTab(): Promise<chrome.tabs.Tab | undefined> {
  const patterns = [`${PLOT_SITE_BASE}/*`, `${PLOT_APP_BASE}/*`];
  const tabs = await chrome.tabs.query({ url: patterns });
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
  | { token: null; reason: "no-plot-tab" | "not-signed-in" };

// Returns a fresh JWT or a reason the caller can act on. We don't proactively
// open Plot here — the background script decides whether to do that (and
// where to send the user) based on which action triggered the lookup.
export async function getToken(): Promise<TokenLookup> {
  const cached = await getCachedToken();
  if (cached) return { token: cached };

  const tab = await findClerkHostTab();
  if (!tab?.id) return { token: null, reason: "no-plot-tab" };

  const token = await requestTokenFromTab(tab.id);
  if (!token) return { token: null, reason: "not-signed-in" };

  await setCachedToken(token);
  return { token };
}

export async function invalidateToken(): Promise<void> {
  await clearCachedToken();
}
