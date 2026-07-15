/**
 * Reusable Google Contacts sync functions extracted from the GoogleContacts
 * connector.
 *
 * These functions implement the channel enable/disable lifecycle and the
 * paginated contact-import backfill (Google People has no push/webhooks for
 * this flow — it walks `connections` + `otherContacts` with sync tokens) —
 * without any connector-level scheduling. They accept a
 * {@link ContactsSyncHost} instead of `this` so they can be invoked from both
 * the standalone GoogleContacts connector and the combined Google connector
 * (which wraps `this` in a key-namespaced host).
 *
 * This is a READ-ONLY import: there is no outbound write-back
 * (no `onCreateLink` / `onLinkUpdated`).
 *
 * Scheduler operations (this.callback / this.runTask) are intentionally NOT
 * performed inline. Where a function genuinely needs to schedule work, it
 * invokes `host.scheduler.*` — a thin set of bound references back to the
 * concrete connector's instance methods — so the connector stays the single
 * owner of scheduling.
 */

import type { NewContact } from "@plotday/twister";

import {
  type ContactSyncState,
  GoogleApi,
  getGoogleContacts,
} from "./people-api";

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that a Google Contacts sync host must satisfy. Both
 * GoogleContacts (using `this` directly via public wrappers) and the combined
 * Google connector (using a key-namespaced host) implement this.
 *
 * `scheduler` carries the operation that CANNOT be extracted — creating a
 * callback and queuing the next backfill batch lives on the concrete connector
 * (it references its own callback method). Extracted functions invoke it
 * through this bound reference so the connector stays the single owner of
 * scheduling.
 */
export interface ContactsSyncHost {
  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
  /** Retrieve a previously persisted value. Returns null if absent. */
  get<T>(key: string): Promise<T | null>;
  /** Delete a persisted value. */
  clear(key: string): Promise<void>;

  tools: {
    integrations: {
      /** Read the OAuth token for a channel. */
      get(
        channelId: string
      ): Promise<{ token: string; scopes: string[] } | null>;
      /** Upsert a batch of contacts. */
      saveContacts(contacts: NewContact[]): Promise<unknown>;
      /** Signal that the initial backfill for a channel has finished. */
      channelSyncCompleted(channelId: string): Promise<void>;
    };
  };

  /**
   * Scheduler boundary — the operation that must stay on the concrete
   * connector. Routes to the connector's own instance method, so extracting the
   * logic that calls it does not move scheduling off the connector.
   */
  scheduler: {
    /** Queue the next contact-import batch as a fresh task. */
    queueSyncBatch(batchNumber: number, syncableId: string): Promise<void>;
  };
}

// ---------------------------------------------------------------------------
// Channel enable / disable + sync start/stop (data-plane state)
// ---------------------------------------------------------------------------

/**
 * Decide whether a newly-enabled channel needs syncing and seed the persisted
 * state. Returns `true` when the caller should kick off the initial backfill
 * batch (the caller owns the scheduling), `false` when there's no token to
 * sync with.
 *
 * Mirrors the original `onChannelEnabled` body: aborts (without throwing) when
 * the auth token is missing so a recovery dispatch doesn't surface as a failed
 * connection — common for the merged-scopes pattern where the parent connector
 * owns the OAuth and GoogleContacts inherits via MergeScopes, so
 * channel.id="contacts" never has its own dedicated token registered.
 */
export async function onChannelEnabledFn(
  host: ContactsSyncHost,
  channelId: string
): Promise<boolean> {
  const token = await host.tools.integrations.get(channelId);
  if (!token) {
    // Auth token not available — abort instead of throwing so the
    // recovery dispatch doesn't surface as a failed connection. Same
    // pattern as syncBatchFn below. Common for the merged-scopes pattern
    // (parent connector owns the OAuth, GoogleContacts inherits via
    // MergeScopes) where channel.id="contacts" never has its own
    // dedicated token registered.
    console.warn(
      `Auth token missing for ${channelId} during onChannelEnabled, skipping`
    );
    return false;
  }

  const initialState: ContactSyncState = {
    more: false,
  };

  await host.set(`sync_state:${channelId}`, initialState);

  return true;
}

/**
 * Tear down all per-channel state for a disabled channel. Mirrors the original
 * `onChannelDisabled` → `stopSync` delegation.
 */
export async function onChannelDisabledFn(
  host: ContactsSyncHost,
  channelId: string
): Promise<void> {
  await stopSyncFn(host, channelId);
}

/**
 * Fetch a single page of the user's Google Contacts. Returns an empty list
 * (without throwing) when the auth token is missing. Mirrors the original
 * `getContacts` body.
 */
export async function getContactsFn(
  host: ContactsSyncHost,
  syncableId: string
): Promise<NewContact[]> {
  const token = await host.tools.integrations.get(syncableId);
  if (!token) {
    console.warn(
      `Auth token missing for syncableId ${syncableId} during getContacts, returning empty list`
    );
    return [];
  }

  const api = new GoogleApi(token.token);
  const result = await getGoogleContacts(api, token.scopes, {
    more: false,
  });

  return result.contacts;
}

/**
 * Seed the backfill cursor and report whether the caller should kick off the
 * first import batch. Returns `false` (without throwing) when the auth token is
 * missing. Mirrors the original `startSync` body.
 */
export async function startSyncFn(
  host: ContactsSyncHost,
  syncableId: string
): Promise<boolean> {
  const token = await host.tools.integrations.get(syncableId);
  if (!token) {
    console.warn(
      `Auth token missing for syncableId ${syncableId} during startSync, skipping`
    );
    return false;
  }

  const initialState: ContactSyncState = {
    more: false,
  };

  await host.set(`sync_state:${syncableId}`, initialState);

  return true;
}

/**
 * Clear the persisted backfill cursor for a syncable. Mirrors the original
 * `stopSync` body.
 */
export async function stopSyncFn(
  host: ContactsSyncHost,
  syncableId: string
): Promise<void> {
  await host.clear(`sync_state:${syncableId}`);
}

// ---------------------------------------------------------------------------
// Sync state machine
// ---------------------------------------------------------------------------

/**
 * Process a single page of the paginated contact import. Walks the People API
 * (`connections` then `otherContacts`) via {@link getGoogleContacts}, saves any
 * contacts found, and advances the cursor.
 *
 * The auth-token guard aborts (clearing state) instead of throwing to prevent
 * infinite queue retries when the token was cleared mid-sync (channel disabled,
 * OAuth revoked, integration deleted). Any other error is rethrown after
 * logging, exactly as the original `syncBatch` did, so the task queue can retry.
 *
 * Scheduling the next page is the caller's job: when more pages remain this
 * invokes `host.scheduler.queueSyncBatch`. (The state machine keeps the
 * scheduling boundary inline here — mirroring tasks' descriptor approach but
 * routing through the host — because the original recursed via `this.callback`
 * + `this.runTask`.)
 */
export async function syncBatchFn(
  host: ContactsSyncHost,
  batchNumber: number,
  syncableId: string
): Promise<void> {
  try {
    const token = await host.tools.integrations.get(syncableId);
    if (!token) {
      // Auth token was cleared (channel disabled, OAuth revoked,
      // integration deleted) — abort instead of throwing to prevent
      // infinite queue retries.
      console.warn(
        `Auth token missing for syncableId ${syncableId} at batch ${batchNumber}, skipping`
      );
      await host.clear(`sync_state:${syncableId}`);
      return;
    }

    const state = await host.get<ContactSyncState>(`sync_state:${syncableId}`);
    if (!state) {
      throw new Error("No sync state found");
    }

    const api = new GoogleApi(token.token);
    const result = await getGoogleContacts(api, token.scopes, state);

    if (result.contacts.length > 0) {
      await processContactsFn(host, result.contacts);
    }

    await host.set(`sync_state:${syncableId}`, result.state);

    if (result.state.more) {
      await host.scheduler.queueSyncBatch(batchNumber + 1, syncableId);
    } else {
      await host.clear(`sync_state:${syncableId}`);
      // No further pages — initial backfill is complete.
      await host.tools.integrations.channelSyncCompleted(syncableId);
    }
  } catch (error) {
    console.error(`Error in sync batch ${batchNumber}:`, error);

    throw error;
  }
}

/**
 * Upsert a batch of imported contacts. Mirrors the original private
 * `processContacts`.
 */
export async function processContactsFn(
  host: ContactsSyncHost,
  contacts: NewContact[]
): Promise<void> {
  await host.tools.integrations.saveContacts(contacts);
}
