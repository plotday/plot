import { AuthRequiredError, capturePage } from "@/src/api";
import { getToken, invalidateToken } from "@/src/auth";
import { PLOT_APP_BASE } from "@/src/config";
import { getSavedShortId, setSavedShortId } from "@/src/storage";

export default defineBackground(() => {
  chrome.action.onClicked.addListener(async (tab) => {
    if (!tab.id || !tab.url || !isCapturable(tab.url)) {
      await setBadge(tab.id, "", "");
      return;
    }

    // Already-saved tab → open the existing thread instead of saving again.
    const saved = await getSavedShortId(tab.url);
    if (saved) {
      await chrome.tabs.create({ url: `${PLOT_APP_BASE}/t/${saved}` });
      return;
    }

    await setBadge(tab.id, "…", "#3a9e7e");

    const lookup = await getToken();
    if (lookup.token === null) {
      await setBadge(tab.id, "!", "#d04646");
      // Open Plot so the user can sign in. The badge clears next time they
      // navigate back to this tab.
      await chrome.tabs.create({ url: PLOT_APP_BASE });
      return;
    }

    try {
      const result = await capturePage(lookup.token, {
        source_url: tab.url,
        title: tab.title ?? undefined,
      });
      await setSavedShortId(tab.url, result.short_id);
      await markTabSaved(tab.id);
    } catch (err) {
      if (err instanceof AuthRequiredError) {
        await invalidateToken();
        await setBadge(tab.id, "!", "#d04646");
        await chrome.tabs.create({ url: PLOT_APP_BASE });
        return;
      }
      console.error("[plot] capture failed:", err);
      await setBadge(tab.id, "!", "#d04646");
    }
  });

  // Reflect the saved state on the toolbar icon as tabs change.
  chrome.tabs.onActivated.addListener(async ({ tabId }) => {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (tab) await refreshTabIndicator(tab);
  });

  chrome.tabs.onUpdated.addListener(async (_tabId, changeInfo, tab) => {
    if (!changeInfo.url && changeInfo.status !== "complete") return;
    await refreshTabIndicator(tab);
  });
});

function isCapturable(url: string): boolean {
  return /^https?:\/\//i.test(url);
}

async function refreshTabIndicator(tab: chrome.tabs.Tab): Promise<void> {
  if (!tab.id) return;
  const url = tab.url;
  if (!url || !isCapturable(url)) {
    await setBadge(tab.id, "", "");
    await chrome.action.setTitle({
      tabId: tab.id,
      title: "Save this page to Plot",
    });
    return;
  }
  const saved = await getSavedShortId(url);
  if (saved) {
    await markTabSaved(tab.id);
  } else {
    await setBadge(tab.id, "", "");
    await chrome.action.setTitle({
      tabId: tab.id,
      title: "Save this page to Plot",
    });
  }
}

async function markTabSaved(tabId: number): Promise<void> {
  await setBadge(tabId, "✓", "#3a9e7e");
  await chrome.action.setTitle({
    tabId,
    title: "Saved to Plot — click to open the thread",
  });
}

async function setBadge(
  tabId: number | undefined,
  text: string,
  color: string
): Promise<void> {
  if (!tabId) return;
  await chrome.action.setBadgeText({ tabId, text });
  if (color) {
    await chrome.action.setBadgeBackgroundColor({ tabId, color });
  }
}
