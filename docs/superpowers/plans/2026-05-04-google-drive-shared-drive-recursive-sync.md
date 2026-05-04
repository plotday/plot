# Google Drive Shared Drive Recursive Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user enables a Shared Drive root channel in Google Drive, sync every file in the entire drive (across all subfolders, including ones added later) — without enumerating subfolders.

**Architecture:** Drive's `q=… in parents` is direct-children only, but `corpora=drive&driveId=<id>` returns every file in a Shared Drive in one paginated listing, and the Changes API stamps `driveId` on each change. Branch the connector's sync paths on whether the channel ID is a Shared Drive: drive-rooted channels switch to a new `listFilesInDrive` helper for initial sync and a `change.file.driveId === driveId` filter for incremental sync. Regular My Drive folder channels are untouched — Drive has no transitive-parent query for them and the existing per-subfolder channel pattern (with the UI auto-enabling descendants) continues to handle that case.

**Scope (non-goals):**
- My Drive (non-shared-drive) folder recursion. Drive's API has no recursive folder query; per-subfolder channels remain the mechanism. Newly-created My Drive subfolders still rely on the daily channel refresh + UI auto-enable.
- The `recovery_pending` / suspended-twist unblock work — that's a separate, already-identified one-shot SQL fix (`UPDATE twist_instance SET suspended_at=NULL WHERE suspended_version IS NULL AND suspended_at IS NOT NULL`).

**Tech Stack:**
- TypeScript + Cloudflare Workers (Twist Creator runtime)
- Google Drive REST API v3 (`https://www.googleapis.com/drive/v3`)
- Files: `public/connectors/google-drive/src/google-api.ts`, `public/connectors/google-drive/src/google-drive.ts`, `public/connectors/google-drive/package.json`, `public/connectors/google-drive/CHANGELOG.md`

**Public submodule note:** All edits in this plan land in `public/connectors/google-drive/`. That's the public Git submodule — changes there need a separate branch/PR in the public repo, then a submodule-bump commit in this repo. The plan ends with the submodule-bump and a final integration check.

**Key Drive API references for the engineer:**
- Files list with `corpora=drive`: <https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list>
  - Required combo: `corpora=drive`, `driveId=<id>`, `includeItemsFromAllDrives=true`, `supportsAllDrives=true`. Without all four the call 400s.
- Changes list: <https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list> — `driveId` is on both `change` and `change.file`; we'll select `change.file.driveId`.
- Shared Drive IDs are not formally namespaced in docs but in practice begin with `0A`. We do **not** rely on the prefix; we look up `listSharedDrives()` and check membership.

---

## File Structure

| File | Responsibility | Change Type |
|------|---------------|-------------|
| `public/connectors/google-drive/src/google-api.ts` | Drive REST helpers + `SyncState` type | Add `listFilesInDrive`, add `driveId` to `GoogleDriveFile`, add `driveId` to listChanges/listFilesInFolder field selection, add `driveId?: string` to `SyncState` |
| `public/connectors/google-drive/src/google-drive.ts` | Connector orchestration | Detect shared-drive channels in `initChannel`/`syncBatch`/`incrementalSyncBatch`; lazy-detect on stale state; switch sub-channel iteration for `VIRTUAL_SHARED_DRIVES` to `listFilesInDrive` |
| `public/connectors/google-drive/package.json` | Package metadata | Bump `version` from `0.2.2` to `0.3.0` |
| `public/connectors/google-drive/CHANGELOG.md` | Manual changelog entry (connectors are ignored by changesets) | Prepend `## 0.3.0` section |

The connector package has no test framework; verification is `pnpm build` (typecheck) + `pnpm lint` + manual integration test against a real Drive in dev. Each implementation step uses the same verify-then-commit cadence in lieu of unit tests.

---

## Task 1: Add `driveId` field to types and listing queries

**Files:**
- Modify: `public/connectors/google-drive/src/google-api.ts`

- [ ] **Step 1: Add `driveId` to `GoogleDriveFile`**

In `google-api.ts`, locate the `GoogleDriveFile` type (lines 1-20). Add `driveId?: string;`:

```typescript
export type GoogleDriveFile = {
  id: string;
  name: string;
  mimeType: string;
  description?: string;
  webViewLink?: string;
  iconLink?: string;
  createdTime?: string;
  modifiedTime?: string;
  owners?: Array<{
    emailAddress?: string;
    displayName?: string;
  }>;
  permissions?: Array<{
    emailAddress?: string;
    displayName?: string;
  }>;
  parents?: string[];
  ownedByMe?: boolean;
  driveId?: string;
};
```

- [ ] **Step 2: Add `driveId` to `listFilesInFolder`'s field selection**

In `listFilesInFolder` (lines ~186-202), add `driveId` to the `fields` parameter:

```typescript
export async function listFilesInFolder(
  api: GoogleApi,
  folderId: string,
  pageToken?: string
): Promise<{ files: GoogleDriveFile[]; nextPageToken?: string }> {
  const data = (await api.call("GET", `${DRIVE_API}/files`, {
    q: `'${folderId}' in parents and mimeType!='application/vnd.google-apps.folder' and trashed=false`,
    includeItemsFromAllDrives: true,
    supportsAllDrives: true,
    fields:
      "nextPageToken,files(id,name,mimeType,description,webViewLink,iconLink,createdTime,modifiedTime,owners,permissions(emailAddress,displayName),parents,ownedByMe,driveId)",
    pageSize: 50,
    pageToken,
  })) as { files: GoogleDriveFile[]; nextPageToken?: string } | null;

  return data || { files: [] };
}
```

- [ ] **Step 3: Add `driveId` to `listSharedWithMe`'s field selection**

Same change in `listSharedWithMe` (lines ~207-222) — append `,driveId` to the `files(...)` projection.

- [ ] **Step 4: Add `driveId` to `listChanges`'s field selection**

In `listChanges` (lines ~345-376), update the `fields` to project the file's `driveId`:

```typescript
fields:
  "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,description,webViewLink,iconLink,createdTime,modifiedTime,owners,permissions(emailAddress,displayName),parents,ownedByMe,driveId))",
```

- [ ] **Step 5: Add `driveId` to `SyncState`**

Locate the `SyncState` type (lines 49-62). Add `driveId?: string;` with a doc comment:

```typescript
export type SyncState = {
  folderId: string;
  pageToken?: string;
  changesToken?: string;
  more?: boolean;
  sequence?: number;
  timeMin?: Date;
  /** The virtual channel ID when syncing via a virtual parent (e.g. "my-drive", "shared-drives") */
  virtualChannelId?: string;
  /** Sub-channel (drive/folder) IDs tracked by a virtual channel */
  subChannelIds?: string[];
  /** Index of the sub-channel currently being synced during initial sync */
  currentSubChannelIndex?: number;
  /**
   * Set when the channel root is a Google Shared Drive. Drives the
   * recursive sync codepath: initial backfill uses `listFilesInDrive`
   * (corpora=drive) instead of a parents query, and incremental sync
   * filters changes by `change.file.driveId === driveId`.
   */
  driveId?: string;
  /**
   * One-shot marker stamped by the lazy migration so we don't re-call
   * `listSharedDrives` on every sync batch for non-Shared-Drive
   * folders. New channels skip this entirely — `initChannel` populates
   * `driveId` correctly up front.
   */
  driveChecked?: boolean;
};
```

- [ ] **Step 6: Add `listFilesInDrive` helper**

Append after `listSharedWithMe` (around line 223):

```typescript
/**
 * List every non-folder file in a Shared Drive, recursively. Uses
 * `corpora=drive&driveId=<id>` to get the entire drive in a single
 * paginated listing — no descendant folder enumeration needed.
 */
export async function listFilesInDrive(
  api: GoogleApi,
  driveId: string,
  pageToken?: string
): Promise<{ files: GoogleDriveFile[]; nextPageToken?: string }> {
  const data = (await api.call("GET", `${DRIVE_API}/files`, {
    q: "mimeType!='application/vnd.google-apps.folder' and trashed=false",
    corpora: "drive",
    driveId,
    includeItemsFromAllDrives: true,
    supportsAllDrives: true,
    fields:
      "nextPageToken,files(id,name,mimeType,description,webViewLink,iconLink,createdTime,modifiedTime,owners,permissions(emailAddress,displayName),parents,ownedByMe,driveId)",
    pageSize: 50,
    pageToken,
  })) as { files: GoogleDriveFile[]; nextPageToken?: string } | null;

  return data || { files: [] };
}
```

- [ ] **Step 7: Typecheck**

Run from repo root:

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit, `dist/` regenerated, no TypeScript errors.

- [ ] **Step 8: Commit**

In the `public/` submodule (these are public-repo commits, not main-repo):

```bash
cd public
git checkout -b drive-recursive-shared-drive-sync
git add connectors/google-drive/src/google-api.ts
git commit -m "google-drive: add driveId to file/changes types and listFilesInDrive helper"
```

---

## Task 2: Detect Shared Drive channels in `initChannel` and persist `driveId`

**Files:**
- Modify: `public/connectors/google-drive/src/google-drive.ts`

- [ ] **Step 1: Update `initChannel` to detect shared drives**

Find `initChannel` (lines ~307-353). Currently the `else` branch handles "Individual folder or Shared with me". We split that into "shared drive root" vs "regular folder". Replace the entire body of `initChannel` with:

```typescript
async initChannel(channelId: string, timeMinISO?: string | null): Promise<void> {
  const token = await this.tools.integrations.get(channelId);
  if (!token) {
    // Auth token was cleared (channel disabled, OAuth revoked,
    // integration deleted) — abort instead of throwing to prevent
    // infinite queue retries.
    console.warn(
      `Auth token missing for channel ${channelId} during initChannel, skipping`
    );
    await this.tools.store.releaseLock(`sync_${channelId}`);
    return;
  }
  const api = new GoogleApi(token.token);
  const changesToken = await getChangesStartToken(api);
  const timeMin = timeMinISO ? new Date(timeMinISO) : undefined;

  if (isVirtualChannel(channelId) && channelId !== VIRTUAL_SHARED_WITH_ME) {
    // My Drive / Shared drives: discover sub-channels and iterate
    const subChannelIds = await this.discoverSubChannels(api, channelId);
    const initialState: SyncState = {
      folderId: channelId,
      changesToken,
      sequence: 1,
      virtualChannelId: channelId,
      subChannelIds,
      currentSubChannelIndex: 0,
      timeMin,
    };
    await this.set(`sync_state_${channelId}`, initialState);
  } else if (channelId === VIRTUAL_SHARED_WITH_ME) {
    const initialState: SyncState = {
      folderId: channelId,
      changesToken,
      sequence: 1,
      timeMin,
      virtualChannelId: channelId,
    };
    await this.set(`sync_state_${channelId}`, initialState);
  } else {
    // Individual folder OR a directly-enabled Shared Drive root.
    // Look up the drive list and mark this state with `driveId` if the
    // channel ID is a Shared Drive root — that flips sync to the
    // corpora=drive recursive path.
    const sharedDrives = await listSharedDrives(api);
    const isSharedDriveRoot = sharedDrives.some(d => d.id === channelId);
    const initialState: SyncState = {
      folderId: channelId,
      changesToken,
      sequence: 1,
      timeMin,
      ...(isSharedDriveRoot ? { driveId: channelId } : {}),
    };
    await this.set(`sync_state_${channelId}`, initialState);
  }

  await this.setupDriveWatch(channelId);

  // Run first batch inline (we're already in a task context) to avoid an
  // extra queue cycle delay. Subsequent batches are queued as tasks.
  await this.syncBatch(1, channelId, true);
}
```

- [ ] **Step 2: Typecheck**

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit. `SyncState` already accepts `driveId`, no new symbols beyond `listSharedDrives` (already imported).

- [ ] **Step 3: Commit**

```bash
cd public
git add connectors/google-drive/src/google-drive.ts
git commit -m "google-drive: detect Shared Drive root in initChannel, persist driveId"
```

---

## Task 3: Use `listFilesInDrive` in `syncBatch` for Shared Drive channels

**Files:**
- Modify: `public/connectors/google-drive/src/google-drive.ts`

- [ ] **Step 1: Add `listFilesInDrive` to the imports**

At the top of `google-drive.ts`, in the import block from `./google-api` (lines ~39-56), add `listFilesInDrive`:

```typescript
import {
  GoogleApi,
  type GoogleDriveComment,
  type GoogleDriveFile,
  type SyncState,
  createComment,
  createReply,
  getChangesStartToken,
  getRootFolderId,
  listChanges,
  listComments,
  listFilesInDrive,
  listFilesInFolder,
  listFolders,
  listSharedDrives,
  listSharedWithMe,
  updateComment,
  updateReply,
} from "./google-api";
```

- [ ] **Step 2: Branch `syncBatch`'s non-virtual path on `state.driveId`**

Find `syncBatch` (lines ~829-965). Within it, the bottom `else` branch ("Non-virtual: single folder sync", lines ~929-957) handles both regular folders today. Replace that branch with a driveId check:

```typescript
} else {
  // Non-virtual: single folder OR directly-enabled Shared Drive root.
  // For Shared Drive roots, use corpora=drive (full recursive listing)
  // so subfolders sync without descendant enumeration. For regular
  // folders, fall back to the parent-filtered query (direct children
  // only — subfolders are handled via separate channels).
  const result = state.driveId
    ? await listFilesInDrive(api, state.driveId, state.pageToken)
    : await listFilesInFolder(api, folderId, state.pageToken);

  for (const file of result.files) {
    try {
      const thread = await this.buildThreadFromFile(api, file, folderId, initialSync);
      await this.saveEnrichedLink(thread, folderId);
      if (file.modifiedTime) {
        await this.set(`last_modified_${file.id}`, file.modifiedTime);
      }
    } catch (error) {
      console.error(`Failed to process file ${file.id}:`, error);
    }
  }

  if (result.nextPageToken) {
    await this.set(`sync_state_${folderId}`, { ...state, pageToken: result.nextPageToken });
    const syncCallback = await this.callback(this.syncBatch, batchNumber + 1, folderId, initialSync);
    await this.runTask(syncCallback);
  } else {
    await this.set(`sync_state_${folderId}`, { ...state, pageToken: undefined });
    await this.tools.store.releaseLock(`sync_${folderId}`);
    // Initial backfill done — clear the indicator.
    if (initialSync) {
      await this.tools.integrations.channelSyncCompleted(folderId);
    }
  }
}
```

Leave the upstream branches (virtual channels, shared-with-me, sub-channel iteration) untouched in this task — they're handled in Task 5.

- [ ] **Step 3: Typecheck**

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit.

- [ ] **Step 4: Commit**

```bash
cd public
git add connectors/google-drive/src/google-drive.ts
git commit -m "google-drive: syncBatch uses listFilesInDrive when state.driveId is set"
```

---

## Task 4: Filter incremental changes by `driveId` for Shared Drive channels

**Files:**
- Modify: `public/connectors/google-drive/src/google-drive.ts`

- [ ] **Step 1: Update the change-acceptance logic in `incrementalSyncBatch`**

Find `incrementalSyncBatch` (lines ~967-1083). Find the block computing `trackedFolderIds` and the per-change accept logic (lines ~990-1010). Replace it with a three-way branch on shared-drive vs shared-with-me vs folder-tracked:

```typescript
// Determine which files to accept based on channel type
const isSharedWithMe = state?.virtualChannelId === VIRTUAL_SHARED_WITH_ME;
const isSharedDriveSync = !!state?.driveId;
// For Shared Drive sync, files inside the drive are accepted by driveId
// match — no folder enumeration needed. For folder-tracked sync,
// trackedFolderIds covers the enabled folder (single-folder mode) or
// every sub-channel a virtual parent is iterating.
const trackedFolderIds = state?.subChannelIds
  ? new Set(state.subChannelIds)
  : isSharedWithMe || isSharedDriveSync ? null : new Set([folderId]);

for (const change of result.changes) {
  if (change.removed || !change.file) continue;

  // Skip folders
  if (change.file.mimeType === "application/vnd.google-apps.folder") continue;

  if (isSharedDriveSync) {
    // Shared Drive root: accept any file in this drive (recursive).
    if (change.file.driveId !== state!.driveId) continue;
  } else if (isSharedWithMe) {
    // Shared with me: accept files not owned by the user
    if (change.file.ownedByMe !== false) continue;
  } else if (trackedFolderIds) {
    // Folder-based: check if file is in a tracked folder
    if (!change.file.parents?.some(p => trackedFolderIds.has(p))) {
      continue;
    }
  }

  // Skip files whose modifiedTime hasn't changed since last sync.
  // Reading comments updates viewedByMeTime which shows up as a change
  // but doesn't change modifiedTime — without this check we'd loop.
  const lastModified = await this.get<string>(`last_modified_${change.fileId}`);
  if (lastModified && change.file.modifiedTime === lastModified) {
    continue;
  }

  try {
    // For Shared Drive sync, file the link under state.driveId so meta
    // matches the channel the user enabled. For folder-tracked sync,
    // pick the parent that actually matched.
    const fileFolderId = isSharedDriveSync
      ? state!.driveId!
      : trackedFolderIds
        ? (change.file.parents?.find(p => trackedFolderIds.has(p)) ?? folderId)
        : (change.file.parents?.[0] ?? folderId);
    const thread = await this.buildThreadFromFile(
      api, change.file, fileFolderId, false, authChannelId
    );
    await this.saveEnrichedLink(thread, fileFolderId, authChannelId);
    if (change.file.modifiedTime) {
      await this.set(`last_modified_${change.fileId}`, change.file.modifiedTime);
    }
  } catch (error) {
    console.error(
      `Failed to process changed file ${change.fileId}:`,
      error
    );
  }
}
```

- [ ] **Step 2: Typecheck**

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit.

- [ ] **Step 3: Commit**

```bash
cd public
git add connectors/google-drive/src/google-drive.ts
git commit -m "google-drive: incrementalSyncBatch filters by driveId for Shared Drive sync"
```

---

## Task 5: Use `listFilesInDrive` in `VIRTUAL_SHARED_DRIVES` sub-channel iteration

When the user enables the `shared-drives` virtual channel, `discoverSubChannels` returns drive IDs as `subChannelIds`. Today the iteration calls `listFilesInFolder` for each drive (direct children only). Switch to `listFilesInDrive` so virtual `shared-drives` is also fully recursive.

**Files:**
- Modify: `public/connectors/google-drive/src/google-drive.ts`

- [ ] **Step 1: Branch the `VIRTUAL_SHARED_DRIVES` sub-channel sync**

Find the sub-channel iteration in `syncBatch` (lines ~886-928). The current code calls `listFilesInFolder` for the current sub. Add a branch on `state.virtualChannelId === VIRTUAL_SHARED_DRIVES` to use `listFilesInDrive`:

```typescript
} else if (state.subChannelIds) {
  // My Drive / Shared drives: iterate sub-channels
  const subIndex = state.currentSubChannelIndex ?? 0;
  if (subIndex >= state.subChannelIds.length) {
    await this.set(`sync_state_${folderId}`, {
      ...state, pageToken: undefined, currentSubChannelIndex: undefined,
    });
    await this.tools.store.releaseLock(`sync_${folderId}`);
    // All sub-channels processed — initial backfill complete.
    if (initialSync) {
      await this.tools.integrations.channelSyncCompleted(folderId);
    }
    return;
  }

  const currentSubId = state.subChannelIds[subIndex];
  // Each sub-channel of `shared-drives` is a Shared Drive ID, so use
  // the recursive corpora=drive listing. Sub-channels of `my-drive`
  // are folder IDs and stay on the parent-filtered listing.
  const result = state.virtualChannelId === VIRTUAL_SHARED_DRIVES
    ? await listFilesInDrive(api, currentSubId, state.pageToken)
    : await listFilesInFolder(api, currentSubId, state.pageToken);

  for (const file of result.files) {
    try {
      const thread = await this.buildThreadFromFile(
        api, file, currentSubId, initialSync, state.virtualChannelId
      );
      await this.saveEnrichedLink(thread, currentSubId, state.virtualChannelId);
      if (file.modifiedTime) {
        await this.set(`last_modified_${file.id}`, file.modifiedTime);
      }
    } catch (error) {
      console.error(`Failed to process file ${file.id}:`, error);
    }
  }

  if (result.nextPageToken) {
    await this.set(`sync_state_${folderId}`, { ...state, pageToken: result.nextPageToken });
  } else {
    // Move to next sub-channel
    await this.set(`sync_state_${folderId}`, {
      ...state, pageToken: undefined, currentSubChannelIndex: subIndex + 1,
    });
  }

  const syncCallback = await this.callback(this.syncBatch, batchNumber + 1, folderId, initialSync);
  await this.runTask(syncCallback);
}
```

- [ ] **Step 2: Branch `syncNewSubChannel` for newly-discovered drives**

`syncNewSubChannel` (lines ~436-474) is invoked when `incrementalSyncBatch` discovers a new drive added to the `VIRTUAL_SHARED_DRIVES` set. It calls `listFilesInFolder` today; switch to `listFilesInDrive` when the parent is the shared-drives virtual channel:

```typescript
private async syncNewSubChannel(
  virtualChannelId: string,
  subChannelId: string,
  pageToken?: string
): Promise<void> {
  const token = await this.tools.integrations.get(virtualChannelId);
  if (!token) {
    console.warn(
      `Auth token missing for virtual channel ${virtualChannelId} during syncNewSubChannel, skipping`
    );
    return;
  }
  const api = new GoogleApi(token.token);
  // sub-channels of shared-drives are Shared Drive IDs — recursive.
  // sub-channels of my-drive are folder IDs — direct children only.
  const result = virtualChannelId === VIRTUAL_SHARED_DRIVES
    ? await listFilesInDrive(api, subChannelId, pageToken)
    : await listFilesInFolder(api, subChannelId, pageToken);

  for (const file of result.files) {
    try {
      const thread = await this.buildThreadFromFile(
        api, file, subChannelId, false, virtualChannelId
      );
      await this.saveEnrichedLink(thread, subChannelId, virtualChannelId);
      if (file.modifiedTime) {
        await this.set(`last_modified_${file.id}`, file.modifiedTime);
      }
    } catch (error) {
      console.error(`Failed to process file ${file.id}:`, error);
    }
  }

  if (result.nextPageToken) {
    const nextCallback = await this.callback(
      this.syncNewSubChannel, virtualChannelId, subChannelId, result.nextPageToken
    );
    await this.runTask(nextCallback);
  }
}
```

- [ ] **Step 3: Filter incremental changes inside `VIRTUAL_SHARED_DRIVES` by driveId**

In `incrementalSyncBatch`, the current `trackedFolderIds` for a `VIRTUAL_SHARED_DRIVES` state contains the drive IDs themselves. The current accept check `change.file.parents?.some(p => trackedFolderIds.has(p))` only catches files whose direct parent IS the drive ID (i.e., top-level files in a drive). After this change a file in a subfolder won't have the drive ID in `parents`, but it WILL have `change.file.driveId` matching. Add a driveId check before the parents check:

In the per-change loop in `incrementalSyncBatch` (the same block updated in Task 4), update the `else if (trackedFolderIds)` branch:

```typescript
} else if (trackedFolderIds) {
  // For VIRTUAL_SHARED_DRIVES, sub-channels are drive IDs — match by
  // driveId (recursive). For VIRTUAL_MY_DRIVE, sub-channels are folder
  // IDs — match by direct parent.
  const matchedByDrive = state?.virtualChannelId === VIRTUAL_SHARED_DRIVES
    && change.file.driveId
    && trackedFolderIds.has(change.file.driveId);
  const matchedByParent = change.file.parents?.some(p => trackedFolderIds.has(p));
  if (!matchedByDrive && !matchedByParent) continue;
}
```

And update `fileFolderId` resolution accordingly so a file matched by drive is filed under the drive ID:

```typescript
const fileFolderId = isSharedDriveSync
  ? state!.driveId!
  : state?.virtualChannelId === VIRTUAL_SHARED_DRIVES
      && change.file.driveId
      && trackedFolderIds?.has(change.file.driveId)
    ? change.file.driveId
    : trackedFolderIds
      ? (change.file.parents?.find(p => trackedFolderIds.has(p)) ?? folderId)
      : (change.file.parents?.[0] ?? folderId);
```

- [ ] **Step 4: Typecheck**

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit.

- [ ] **Step 5: Commit**

```bash
cd public
git add connectors/google-drive/src/google-drive.ts
git commit -m "google-drive: VIRTUAL_SHARED_DRIVES uses recursive corpora=drive listing"
```

---

## Task 6: Lazy migration for stale `SyncState` rows

Existing connections (e.g. kris's Drive `019dbfd7-…`) have `sync_state_<channel>` rows persisted by the OLD code path — they have `folderId` set but NO `driveId`. When sync resumes, those state rows would still take the parent-filtered path. The clean fix is to detect this on the first incremental run and lazily populate `driveId`.

**Files:**
- Modify: `public/connectors/google-drive/src/google-drive.ts`

- [ ] **Step 1: Lazy-detect inside `incrementalSyncBatch`**

Find `incrementalSyncBatch` (line ~967). Right after the `state` is fetched and the token check passes, before the change-acceptance branching, lazily back-fill `driveId` if the channel ID matches a known Shared Drive:

```typescript
async incrementalSyncBatch(
  folderId: string,
  changesToken: string
): Promise<void> {
  try {
    let state = await this.get<SyncState>(`sync_state_${folderId}`);
    const authChannelId = state?.virtualChannelId;
    const token = await this.tools.integrations.get(authChannelId ?? folderId);
    if (!token) {
      console.warn(
        `Auth token missing for folder ${folderId} during incremental sync, skipping`
      );
      return;
    }
    const api = new GoogleApi(token.token);

    // Lazy migration: a state persisted by older code lacks `driveId`
    // even when the channel is a Shared Drive root. Detect once and
    // stamp `driveChecked` so we don't re-call listSharedDrives on
    // every batch for non-Shared-Drive folders.
    if (
      state &&
      !state.driveId &&
      !state.driveChecked &&
      !state.virtualChannelId &&
      !state.subChannelIds &&
      folderId !== VIRTUAL_SHARED_WITH_ME
    ) {
      const sharedDrives = await listSharedDrives(api);
      const isDrive = sharedDrives.some(d => d.id === folderId);
      state = {
        ...state,
        driveChecked: true,
        ...(isDrive ? { driveId: folderId } : {}),
      };
      await this.set(`sync_state_${folderId}`, state);
    }

    const result = await listChanges(api, changesToken);
    // ...rest unchanged
```

(Leave the rest of the function as updated in Task 4 / Task 5.)

- [ ] **Step 2: Lazy-detect inside `syncBatch` (covers the case where sync resumes mid-backfill)**

Initial backfill is paginated across `syncBatch` calls. If `initChannel` ran under the OLD code, the existing state lacks `driveId` and subsequent batches will continue down the parent path. Add the same lazy back-fill at the top of `syncBatch`'s state-load:

```typescript
async syncBatch(
  batchNumber: number,
  folderId: string,
  initialSync: boolean
): Promise<void> {
  try {
    let state = await this.get<SyncState>(`sync_state_${folderId}`);
    if (!state) {
      await this.tools.store.releaseLock(`sync_${folderId}`);
      return;
    }

    const authChannelId = state.virtualChannelId;
    const token = await this.tools.integrations.get(authChannelId ?? folderId);
    if (!token) {
      console.warn(
        `Auth token missing for folder ${folderId} at batch ${batchNumber}, skipping`
      );
      await this.tools.store.releaseLock(`sync_${folderId}`);
      return;
    }
    const api = new GoogleApi(token.token);

    // Lazy migration: see incrementalSyncBatch comment above.
    if (
      !state.driveId &&
      !state.driveChecked &&
      !state.virtualChannelId &&
      !state.subChannelIds &&
      folderId !== VIRTUAL_SHARED_WITH_ME
    ) {
      const sharedDrives = await listSharedDrives(api);
      const isDrive = sharedDrives.some(d => d.id === folderId);
      state = {
        ...state,
        driveChecked: true,
        ...(isDrive ? { driveId: folderId } : {}),
      };
      await this.set(`sync_state_${folderId}`, state);
    }

    // ...rest unchanged
```

- [ ] **Step 3: Typecheck**

```bash
cd public/connectors/google-drive && pnpm build
```

Expected: clean exit. Also confirm `state` is now `let` not `const` in both functions.

- [ ] **Step 4: Commit**

```bash
cd public
git add connectors/google-drive/src/google-drive.ts
git commit -m "google-drive: lazy-detect Shared Drive root on stale SyncState rows"
```

---

## Task 7: Bump connector version and changelog

Connectors are listed under `ignore` in `public/.changeset/config.json` (no changeset required) but the package version still needs a bump — `plot deploy` reads it.

**Files:**
- Modify: `public/connectors/google-drive/package.json`
- Modify: `public/connectors/google-drive/CHANGELOG.md`

- [ ] **Step 1: Bump version in `package.json`**

Change `"version": "0.2.2"` to `"version": "0.3.0"`.

- [ ] **Step 2: Prepend a `0.3.0` entry in `CHANGELOG.md`**

Insert above the `## 0.2.2` section:

```markdown
## 0.3.0

### Changed

- Shared Drive root channels now sync recursively (every file in the drive across all subfolders, including ones added later) using `corpora=drive`. Previously only top-level files of an enabled Shared Drive were synced; users had to enable each subfolder separately. Existing `SyncState` rows are upgraded lazily on the next sync.
```

- [ ] **Step 3: Run `pnpm lint` on the connector**

```bash
cd public/connectors/google-drive && pnpm lint
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd public
git add connectors/google-drive/package.json connectors/google-drive/CHANGELOG.md
git commit -m "google-drive: 0.3.0 — recursive Shared Drive sync"
```

---

## Task 8: Local integration verification

The connector package has no automated tests. Run it against a real Drive in dev to confirm behavior. Use a personal/test Google account whose Drive has at least one Shared Drive with a non-trivial subfolder.

**Files:**
- None (verification only)

- [ ] **Step 1: Bring up the local stack**

In repo root:

```bash
pnpm --filter @plotday/api dev   # terminal 1
pnpm tunnel:start                 # terminal 2 (background)
pnpm tunnel:status                # confirm tunnel up
```

Expected: API worker on `localhost:8787`; tunnel proxies `https://api-kris.plot.day` → local.

- [ ] **Step 2: Connect a Drive in the Plot client**

In the local app (`localhost:8788`), open Connections → Google Drive → connect a test account. In the channel picker, enable a Shared Drive root that has files in subfolders. Do **not** manually enable any of its subfolders.

- [ ] **Step 3: Verify recursive backfill**

Wait ~30 seconds for `initChannel` + `syncBatch` to run. Then in psql against the worktree DB:

```bash
psql "$DATABASE_URL" <<'SQL'
SELECT title, source, channel_id
FROM link
WHERE created_by = (
  SELECT id FROM twist_instance
   WHERE owner_id = (SELECT id FROM "user" WHERE email = '<test-user-email>')
     AND twist_id = 609
   ORDER BY created_at DESC LIMIT 1
)
ORDER BY created_at DESC
LIMIT 50;
SQL
```

Expected: links from across the entire Shared Drive — including titles you can confirm live in subfolders. Compare against the file tree in the Drive UI.

- [ ] **Step 4: Verify incremental sync via webhook**

Create a new Google Doc inside a *deeply nested* subfolder of the same Shared Drive. Watch the API worker logs for `[google-drive] onDriveWebhook` and `[google-drive] incrementalSyncBatch`. Re-run the SQL above and confirm the new doc appears within ~1 minute.

- [ ] **Step 5: Verify regular My Drive folder is untouched**

Disable the Shared Drive channel, enable a regular My Drive folder (one with a subfolder containing files). Confirm only top-level files sync — that the subfolder's files do **not** appear (regression check; My Drive folder behavior is intentionally unchanged).

- [ ] **Step 6: Confirm lazy migration path**

This step is optional but valuable if a test connection from before the deploy is around. For an existing Shared Drive channel with state predating this change, trigger an incremental sync (e.g. edit any file in the drive) and confirm the next webhook log shows the recursive listing kick in. The state row should now have `driveId` set; you can read it from the runtime store via `wrangler tail` / connector logs.

---

## Task 9: Land in the public submodule and bump the parent repo

**Files:**
- Modify (parent repo): `public` (submodule pointer)

- [ ] **Step 1: Push the public branch and open a PR**

```bash
cd public
git push origin drive-recursive-shared-drive-sync
gh pr create --title "google-drive: recursive Shared Drive sync (0.3.0)" --body "$(cat <<'EOF'
## Summary
- Shared Drive root channels now sync the entire drive recursively, including files in subfolders and new files added later, by switching to `corpora=drive&driveId=<id>`.
- Incremental sync filters by `change.file.driveId` for Shared Drive channels, so subfolder edits propagate.
- Existing `SyncState` rows without `driveId` are lazy-migrated on the next sync.
- Regular My Drive folder channels are unchanged (Drive has no transitive-parent query — the per-subfolder channel pattern remains).

## Test plan
- [ ] Enable a Shared Drive in dev, confirm files in subfolders backfill.
- [ ] Add a doc to a deep subfolder, confirm it appears within ~1 min via webhook.
- [ ] Confirm regular My Drive folder still syncs only direct children.
- [ ] Confirm lazy migration upgrades a pre-existing state row.
EOF
)"
```

- [ ] **Step 2: Once merged, bump the submodule pointer in this repo**

```bash
cd /Users/kris.braun/code/plot
cd public && git checkout main && git pull && cd ..
git add public
git commit -m "public: bump submodule for google-drive 0.3.0 recursive Shared Drive sync"
```

- [ ] **Step 3: Final smoke test in the parent repo**

```bash
pnpm install
cd public/connectors/google-drive && pnpm build && cd -
pnpm --filter @plotday/api lint
```

Expected: install resolves cleanly, connector builds, API worker lint passes.

- [ ] **Step 4: Operational follow-up (separate, do this AFTER landing)**

Clear the suspended Drive twist instances so the new code actually runs for affected users:

```sql
UPDATE twist_instance
   SET suspended_at = NULL,
       suspended_version = NULL
 WHERE suspended_at IS NOT NULL
   AND suspended_version IS NULL
   AND archived_at IS NULL
   AND draft = false;
```

Two rows expected (kris's Drive, Veronica's Airtable). After this, the next `recoverPendingConnections` cron pass dispatches `onChannelEnabled(recovering: true)` for each enabled channel — for kris's Drive, that runs the new recursive code path.
