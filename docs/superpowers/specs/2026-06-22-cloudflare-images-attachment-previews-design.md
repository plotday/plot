# Cloudflare Images for note attachment previews

**Date:** 2026-06-22
**Status:** Approved design — pending implementation plan

## Problem

Note image attachments are stored full-size in R2 and served back through a
single auth-gated endpoint, `GET /files/:fileId`
(`workers/api/src/app/files.ts`). Both the **inline timeline preview** and the
**download button** hit that same endpoint, so rendering a ≤200pt-tall inline
preview pulls the entire multi-MB original every time
(`FileImageWidget._loadImage()` →
`api.getFileBytes(fileId)` → `GET /files/:fileId`, in
`apps/plot/lib/widget/note_action.dart` and `apps/plot/lib/api/api.dart`).

We want the timeline to fetch a small, resized image for inline display while
**full-size originals are still downloaded for explicit zoom and download**.

## Approach (chosen)

**Worker-side transformation via the Cloudflare Images binding.** Transform R2
originals on the fly inside the *existing* auth-gated `/files` endpoint and
serve a small WebP variant for inline display. Originals stay in R2 only.

### Why not the Cloudflare Images storage product

These attachments are **private** — `/files/:fileId` checks Clerk auth and
`has_priority_access` per request. The storage product serves from public
`imagedelivery.net` URLs, which would force signed-URL tokens (downgrading
"checked against priority access" to "valid until token expiry"), duplicate
every image across R2 + Images, require an upload-time push + backfill + a new
image-ID field, and still not cover connector images. The worker-transform
approach preserves the access model unchanged, adds no storage, and needs only
a near-trivial client change. The storage product's one advantage — edge
delivery with the worker out of the path — is exactly what creates the
signed-token problem, and isn't worth it at our scale.

## Scope

- **In scope:** user-uploaded note attachments served by `GET /files/:fileId`
  (R2-backed).
- **Out of scope (this pass):** connector `fileRef` images
  (`GET /files/ref/:noteId/:actionIndex`). Some connectors return a redirect
  URL rather than bytes, so they can't be uniformly transformed; deferred.
- **No backfill:** transformation is on-demand at view time, so existing
  images need no migration.

## Image sizes

Two sizes total — there is no separate "medium" tier:

| Use | Source | Size |
| --- | --- | --- |
| Inline timeline preview | resized variant | small bucket (default **800px** longest edge) |
| Tap-to-zoom full viewer | original | full size |
| Download button | original | full size |

The big fetch only happens when the user explicitly zooms or downloads — the
expected moment for it.

## Server design (`workers/api`)

### Binding & config

- Add the Images binding to `workers/api/wrangler.jsonc` for both dev and prod
  environments: `"images": { "binding": "IMAGES" }`.
- Add `IMAGES` to the `Bindings` type in `workers/api/src/env.ts`.

### `GET /files/:fileId` — add an optional `?w=<px>` branch

The handler keeps its current behavior and gains one branch keyed on the
optional `w` query parameter.

1. **Auth and access check run first, always.** Clerk user + the existing
   `has_priority_access` lookup. This is never cached and never bypassed.
2. **`?w` absent** → return the R2 original exactly as today
   (`Content-Disposition: attachment`). This is the zoom/download path.
3. **`?w` present AND object is an image:**
   - Clamp `w` to a small allow-list of buckets (e.g. `400`, `800`) to bound
     transform cost and maximize cache reuse. Reject/round anything else to the
     nearest bucket.
   - After auth passes, check the **Workers Cache API** (`caches.default`),
     keyed on the full request URL (which includes `?w`). On hit, serve the
     cached variant.
   - On miss: read the R2 original body and run
     `env.IMAGES.input(object.body).transform({ width, height: width, fit: "scale-down" }).output({ format: "image/webp", quality: 80 })`,
     then `cache.put(...)` the result and return it with
     `Content-Disposition: inline` and a cache header.
   - `fit: "scale-down"` never upscales, so originals smaller than the bucket
     pass through at their own size.
4. **`?w` present but transform fails, OR object is not an image** → fall back
   to streaming the R2 original. Never return a broken image.

### Auth-before-cache ordering (security)

The access check executes on **every** request before any Cache-API hit, so
caching the transformed bytes under the (random-UUID) URL key cannot leak an
image across users. The cache stores only the expensive transform result, not
an auth decision.

### Cost

`env.IMAGES.transform` runs only on a Cache-API miss; repeat views are served
from the edge cache. Cloudflare bills unique transformations per month, so a
viewed image costs roughly 1–2 transforms total for its lifetime.

## Client design (`apps/plot`)

1. `api.getFileBytes(fileId, {int? width})` — when `width` is set, append
   `?w=<width>` to the request; otherwise unchanged.
2. `FileImageWidget._loadImage()` requests the small variant (default
   `width: 800`, a fixed bucket sized for a ~200pt-tall preview at 3× DPR).
   `FilePreviewCache` stores the **small** variant under `fileId`.
3. **Zoom viewer** (`_openViewer` / `_showFullImageViewer`) and the **download
   button** call `getFileBytes(fileId)` with **no width** → full original. The
   viewer may cache the original under a distinct key so a follow-up download
   reuses it (avoids colliding with the small-variant entry in
   `FilePreviewCache`).
4. Non-image attachments: unchanged.
5. WebP decoding: `Image.memory` decodes WebP on all target platforms
   (mobile, desktop, web).

## Backwards compatibility

No schema change, no payload change, no new fields on `FileUserAction`. Old app
clients keep calling `/files/:fileId` with no `?w` and receive the original
exactly as today. The change is purely additive: a new query-param branch on
the server and an optional argument on the client.

## Error handling

- The transform path wraps `env.IMAGES` in a `try/catch`; on unexpected failure
  it calls `tracker.captureException` (or `postHog.captureException`) and falls
  back to streaming the original. Expected non-image cases pass through without
  capture.

## Testing

Server (vitest):

- `?w` present on an image → response is `image/webp` with a smaller
  `content-length` than the original.
- `?w` absent → original bytes and content type, `Content-Disposition:
  attachment`.
- Access denied still returns 403 even with `?w` present (auth runs first).
- Non-image object with `?w` → passes through as the original.
- Transform failure → falls back to original bytes (no broken image).
- `w` outside the allow-list is clamped to the nearest bucket.

Client (Flutter): `getFileBytes` appends `?w=` only when `width` is provided;
inline widget requests the bucket width; zoom/download omit it.

## To verify during implementation

- Confirm the Images binding runs under local `wrangler dev` (it may require
  remote bindings). Document the local-dev story in the plan, and ensure tests
  don't depend on a live transform service (mock `env.IMAGES` if needed).
