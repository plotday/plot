// Content script: lives on app.plot.day tabs. The Clerk SDK is only accessible
// in the page world (window.Clerk), so we inject a tiny page-world script and
// ferry the token back via window.postMessage. The background script's auth
// module calls into this via chrome.tabs.sendMessage(tabId, { kind: ... }).

export default defineContentScript({
  matches: [
    "https://app.plot.day/*",
    "https://plot.day/*",
    "http://localhost:8788/*",
    "http://localhost:5173/*",
  ],
  runAt: "document_idle",
  main() {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      if (!msg || msg.kind !== "plot:getToken") return undefined;

      const requestId = `plot-token-${Date.now()}-${Math.random()
        .toString(36)
        .slice(2)}`;

      const onMessage = (event: MessageEvent) => {
        if (event.source !== window) return;
        const data = event.data;
        if (
          !data ||
          typeof data !== "object" ||
          data.kind !== "plot:token-result" ||
          data.requestId !== requestId
        )
          return;
        window.removeEventListener("message", onMessage);
        clearTimeout(timeout);
        sendResponse({ token: data.token ?? null, error: data.error });
      };

      window.addEventListener("message", onMessage);

      const timeout = setTimeout(() => {
        window.removeEventListener("message", onMessage);
        sendResponse({ token: null, error: "timeout" });
      }, 5000);

      // Inject the page-world bridge. Clerk attaches to window asynchronously,
      // so we poll briefly for it.
      const code = `(${pageWorldScript.toString()})(${JSON.stringify(requestId)});`;
      const script = document.createElement("script");
      script.textContent = code;
      (document.head || document.documentElement).appendChild(script);
      script.remove();

      return true; // keep sendResponse alive for the async path
    });
  },
});

// Runs in the page world. Polls for window.Clerk, asks the active session
// for a fresh JWT, posts the result back to the content script.
function pageWorldScript(requestId: string) {
  const post = (token: string | null, error?: string) => {
    window.postMessage({ kind: "plot:token-result", requestId, token, error }, "*");
  };

  const start = Date.now();
  const poll = () => {
    const clerk = (window as any).Clerk;
    if (clerk?.session?.getToken) {
      clerk
        .session.getToken()
        .then((token: string | null) => post(token ?? null))
        .catch((err: unknown) =>
          post(null, err instanceof Error ? err.message : String(err))
        );
      return;
    }
    if (Date.now() - start > 4000) {
      post(null, "clerk-unavailable");
      return;
    }
    setTimeout(poll, 100);
  };
  poll();
}
