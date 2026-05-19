# LinkedIn Messaging Connector

Status: **Blocked, parked.** The connector currently signs the user in successfully but cannot make any actual Voyager API calls from the Plot backend. Resuming work means implementing **Path A: webview-as-proxy** (see below).

## What works today

End-to-end sign-in:

1. User opens "Connect LinkedIn" → `LinkedInLoginModal` hosts an in-app `InAppWebView` pointed at `linkedin.com/login`.
2. User signs in. LinkedIn issues `li_at` + `JSESSIONID` (+ ~17 other cookies) to the webview.
3. The modal observes navigation to a signed-in URL prefix (`/feed`, `/messaging`, `/in/`, …), reads `li_at` + `JSESSIONID` from the webview's cookie store, and POSTs them to `POST /twist/:id/integrations/linkedin/cookie` along with the webview's UA.
4. Server validates by probing `https://www.linkedin.com/voyager/api/me`.

Step 4 is where things break — see below.

## What blocks us

**LinkedIn Voyager refuses requests originating from datacenter IPs**, even with a valid `li_at` + `JSESSIONID` + matching User-Agent. Specifically: `voyager/api/me` returns **403** when called from a Cloudflare Worker, but **200** when the *same* cookies are replayed from inside the user's webview (residential IP).

The 403 happens even after we:

- Pinned the webview to a real-browser UA (`_pinnedUserAgent()` in `linkedin_login_modal.dart`) so LinkedIn issues cookies to a UA that doesn't carry the bare-WKWebView bot signature.
- Forwarded `csrf-token`, `x-restli-protocol-version: 2.0.0`, `x-li-lang`, `x-li-track`, and the `application/vnd.linkedin.normalized+json+2.1` accept header — the headers LinkedIn's own web client sends.
- Used the exact UA the webview reported back to us at capture time.

### How we proved it

A one-time diagnostic (removed in this commit; preserved as a snippet at the bottom of this doc) made the same `/voyager/api/me` call from inside the signed-in webview via injected JS, then bridged the result back to Flutter via `callHandler`.

Result, every time the page was stable:

```
{ status: 200, ok: true, bodyLen: 812,
  bodyHead: '{"data":{"plainId":1755708209,"publicContactInfo":{...},
              "premiumSubscriber":false,
              "*miniProfile":"urn:li:fs_miniProfile:ACoAA..."',
  cookieNames: [bcookie, lidc, sdui_ver, liap, JSESSIONID, aam_uuid,
                lang, visit, li_theme, li_theme_set, li_g_recent_logout,
                timezone, li_sugr,
                AMCV_..., _guid, lms_ads, lms_analytics,
                AnalyticsSyncHistory, AMCVS_...] }
```

Meanwhile the server's identical call: `403`. Same cookies. Same UA. Same headers. Only the IP differs.

### What it is *not*

- **Not a UA problem.** Tested with bare WKWebView UA (88 chars), desktop Safari (117 chars), and desktop Chrome (122 chars). All 403 from the worker; 200 from the webview.
- **Not missing cookies.** The webview has 19 LinkedIn cookies, we forward 2; but the in-webview probe with all 19 cookies *and* the worker probe with 2 cookies behave the same way *from the same IP* — what varies is the origin IP, not the cookie set.
- **Not a missing header.** We sent the canonical Voyager header set.
- **Not the JSESSIONID quote-handling.** Server correctly strips the surrounding quotes for `csrf-token` and re-wraps them for the `Cookie` header.
- **Not response-shape parsing.** We never get a body to parse — the 403 lands at the HTTP layer.

## How competitors do it

Best public information (Unipile docs, Reddit threads about LinkedIn-API providers):

| Tier | Approach | Why it works |
|---|---|---|
| Browser extensions (Kondo, Beeper-LinkedIn) | All Voyager calls execute inside the user's logged-in Chrome. | Real browser, real residential IP, real TLS fingerprint. |
| Unified APIs (Unipile) | Residential proxy pool with stable per-account exit IPs + TLS-fingerprint-spoofed HTTP clients (curl-impersonate, tls-client, etc.). | Looks indistinguishable from real Chrome at TLS+HTTP+IP layers. |
| Aggressive scrapers | Same as above, plus headless-browser farms for the hardest endpoints. | Brute-force evasion. |

What none of them do: make Voyager calls from generic cloud IPs. Cloudflare Worker IPs are at the very top of LinkedIn's deny list.

Cost-of-implementation for the Unipile-style approach: residential proxy pool (~$5–15/GB; ~$0.15–$5/user/month at Plot's likely traffic), plus a TLS-impersonating fetch library, plus ops work for IP rotation, per-account pinning, and 403-rate monitoring. Realistic but not free.

## Decided path forward: Path A — webview-as-proxy

The user's device already has a residential IP, a real WebKit/Chromium TLS stack, and (after sign-in) a logged-in LinkedIn session in an `InAppWebView`. We piggyback on that.

**Architecture sketch:**

1. **Persistent background webview, one per LinkedIn-connected account.** Owned by the Flutter app, not the modal. Survives the modal closing. Loads `https://www.linkedin.com/` once at startup (or on demand) and stays there with the captured session cookies installed.
2. **`voyagerCall(method, path, query, body)` Dart API.** Inside the background webview, executes:
   ```js
   fetch('https://www.linkedin.com/voyager/api' + path + query, {
     method, headers: {...standardVoyagerHeaders, 'csrf-token': csrfFromCookie()},
     credentials: 'include',
     body
   }).then(r => r.text()).then(body =>
     window.flutter_inappwebview.callHandler('voyagerResult',
       {requestId, status: r.status, headers: [...r.headers], body})
   )
   ```
   then bridges the result back to Dart through a `requestId` → `Completer<VoyagerResponse>` map.
3. **Server stops calling Voyager.** The `LinkedIn` built-in tool (`workers/api/src/twist/tools/linkedin.ts`) currently makes Voyager calls server-side. That code moves to the device. The server's role shrinks to:
   - Cookie storage (so we can rehydrate webview cookies on app start without forcing re-sign-in)
   - Sync scheduling (when to ask the device to fetch conversations, threads, messages)
   - Persisting normalized results into `thread`/`note`/`contact`/`link`/`schedule_contact`
4. **Sync orchestration.** The connector's `syncBatch` and per-channel sync callbacks run on the server as today, but instead of `this.tools.linkedin.fetch(...)` they enqueue a "fetch this URL" instruction the device picks up next time it's online. Plot is local-first already, so devices already poll/sync continuously — this fits the existing model.

**Cost / friction:**

- Sync is only live while the app is open on at least one device (or running in background — possible on macOS/Windows/Linux + iOS background fetch + Android foreground service). Acceptable for personal messaging since the user is typically on their own device when they care about messages anyway.
- Multi-device: only one device needs to be the executor at a time. Can use existing presence/locking patterns.
- Web: a Flutter-web build can't host an `InAppWebView`; the LinkedIn channel is desktop+mobile-only. Document this in the connector's channel list.

## Implementation checklist (when we come back)

1. **`apps/plot/lib/integration/linkedin_proxy.dart`** (new). Owns the background `HeadlessInAppWebView`, the `voyagerCall(...)` API, cookie rehydration on app start, and the `voyagerResult` JS handler.
2. **`apps/plot/lib/integration/linkedin_proxy_bloc.dart`** (new). Lifecycle: spin up the proxy when a `twist_instance_connection` row for `provider=linkedin` exists, tear down when removed.
3. **`workers/api/src/twist/tools/linkedin.ts`** (refactor). Strip the Voyager-calling code. Replace with a "schedule fetch on device" mechanism. The tool's API surface (the methods the connector calls) stays the same; the implementation routes through a per-device durable queue.
4. **New endpoint** `GET /twist/:id/integrations/linkedin/work` (long-poll or SSE). Device asks for pending Voyager calls. Server returns a batch.
5. **New endpoint** `POST /twist/:id/integrations/linkedin/work/:requestId` (device posts the result). Server feeds it back to the in-flight tool call (Durable Object holds a `Completer` keyed on `requestId`).
6. **`POST /twist/:id/integrations/linkedin/cookie`** changes. Stop probing Voyager from the server (we know it'll fail). Trust the client's report that sign-in succeeded; persist the cookies; rely on the next device-side call to verify the session actually works.
7. **Connector retains its current code** (`public/connectors/linkedin-messaging/`) — none of its `getChannels` / `syncBatch` / `sendMessage` logic changes, because the abstraction `this.tools.linkedin.*` is the seam where on-device routing happens.

## Files touched during the investigation that landed in this commit

- `apps/plot/lib/widget/linkedin_login_modal.dart`
  - Pin a real-browser UA via `_pinnedUserAgent()` (Chrome per-platform; Safari UA caused a passkey-chip overlay on macOS that blocked clicking the email input).
  - `_retry()` now wipes the webview's LinkedIn cookies before reloading `/login`, so "Try again" forces a fresh sign-in instead of silently resubmitting a rejected cookie.
- `workers/api/src/app/twist-integrations.ts`
  - LinkedIn cookie endpoint returns **400** (not 401) when Voyager rejects the cookie. Returning 401 was tripping the Flutter API client's session-expiration handler and force-signing the user out of Plot entirely.

## Diagnostic snippet to keep handy

If we ever need to re-confirm the in-webview probe works (e.g. before flipping the Path A switch in production), this is the JS to inject from `_maybeCaptureCookies` and a `linkedinDiagnosticResult` callHandler that logs the result:

```js
(function () {
  const m = document.cookie.match(/JSESSIONID=("?)([^;]*?)\1(;|$)/);
  const csrf = m ? m[2] : '';
  fetch('https://www.linkedin.com/voyager/api/me', {
    method: 'GET',
    credentials: 'include',
    headers: {
      'csrf-token': csrf,
      'x-restli-protocol-version': '2.0.0',
      'accept': 'application/vnd.linkedin.normalized+json+2.1',
    },
  }).then(r => r.text().then(b =>
    window.flutter_inappwebview.callHandler('linkedinDiagnosticResult',
      { status: r.status, bodyHead: b.slice(0, 200) })
  )).catch(e =>
    window.flutter_inappwebview.callHandler('linkedinDiagnosticResult',
      { status: 0, error: String(e) })
  );
})();
```

Expected from inside webview: `status: 200`, body starts with `{"data":{"plainId":...`.
Expected from a server: `status: 403`.
