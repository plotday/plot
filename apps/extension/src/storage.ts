// chrome.storage.local: { [source_url]: shortId } — the local "already saved"
// index. The server is authoritative on duplicate detection (POST
// /sync/capture dedupes by user.link.source_url), so this cache only powers
// the toolbar icon's per-tab state.

const CACHE_KEY = "saved-by-url";

type SavedMap = Record<string, string>;

async function readMap(): Promise<SavedMap> {
  const result = await chrome.storage.local.get(CACHE_KEY);
  const value = result[CACHE_KEY];
  return value && typeof value === "object" ? (value as SavedMap) : {};
}

export async function getSavedShortId(url: string): Promise<string | null> {
  if (!url) return null;
  const map = await readMap();
  return map[url] ?? null;
}

export async function setSavedShortId(
  url: string,
  shortId: string
): Promise<void> {
  if (!url) return;
  const map = await readMap();
  if (map[url] === shortId) return;
  map[url] = shortId;
  await chrome.storage.local.set({ [CACHE_KEY]: map });
}

// JWT cache lives in session storage so it never hits disk. Cleared when the
// browser session ends. Bearer tokens from Clerk typically have ~1h lifetimes;
// we refresh whenever the cached value is missing or stale.
const TOKEN_KEY = "clerk-jwt";
const TOKEN_TTL_MS = 50 * 60 * 1000;

type CachedToken = { token: string; fetchedAt: number };

export async function getCachedToken(): Promise<string | null> {
  const result = await chrome.storage.session.get(TOKEN_KEY);
  const value = result[TOKEN_KEY] as CachedToken | undefined;
  if (!value) return null;
  if (Date.now() - value.fetchedAt > TOKEN_TTL_MS) return null;
  return value.token;
}

export async function setCachedToken(token: string): Promise<void> {
  const value: CachedToken = { token, fetchedAt: Date.now() };
  await chrome.storage.session.set({ [TOKEN_KEY]: value });
}

export async function clearCachedToken(): Promise<void> {
  await chrome.storage.session.remove(TOKEN_KEY);
}
