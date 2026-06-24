import {
  type NewContact,
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

import { GOOGLE_PEOPLE_SCOPES } from "./people-api";
import {
  type ContactsSyncHost,
  getContactsFn,
  onChannelDisabledFn,
  onChannelEnabledFn,
  startSyncFn,
  stopSyncFn,
  syncBatchFn,
} from "./sync";

/**
 * Google Contacts connector
 *
 * Imports the user's Google Contacts (saved contacts + "other contacts") as
 * Plot contacts. Read-only — there is no outbound write-back. Walks the People
 * API in pages using sync tokens; no webhooks.
 *
 * The channel/sync lifecycle lives in `./sync` as standalone functions over a
 * {@link ContactsSyncHost}; this class is a thin connector that builds a host
 * from `this`, owns all scheduling, and delegates the rest.
 *
 * GoogleContacts is also consumed as a built-in TOOL by other Google
 * connectors (`this.tools.googleContacts`), so the public `getContacts` /
 * `startSync` / `stopSync` methods keep their exact names, signatures, and
 * behavior — they delegate to the extracted functions.
 */
export default class GoogleContacts
  extends Connector<GoogleContacts>
{
  static readonly id = "google-contacts";

  static readonly PROVIDER = AuthProvider.Google;

  static readonly SCOPES = GOOGLE_PEOPLE_SCOPES;

  readonly provider = AuthProvider.Google;
  readonly scopes = GoogleContacts.SCOPES;

  readonly singleChannel = true;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://people.googleapis.com/*"],
      }),
    };
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + public state delegators
  //
  // The Connector base class exposes set/get/clear as `protected`, but
  // ContactsSyncHost requires them as public. We bridge this via a host object
  // that delegates through the public wrapper methods below. The host's
  // `scheduler` section routes back to this connector's own scheduling method
  // (which remains here so it references `this.callback`/`this.runTask`).
  // ---------------------------------------------------------------------------

  /** Public set wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostSet(key: string, value: any): Promise<void> {
    return this.set(key, value);
  }
  /** Public get wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(key);
  }
  /** Public clear wrapper so the host object can expose it. */
  _hostClear(key: string): Promise<void> {
    return this.clear(key);
  }

  /**
   * Returns a ContactsSyncHost backed by this connector instance.
   * Passes through all tool access, exposes set/get/clear as public members,
   * and binds the scheduler section to this connector's own method.
   */
  private makeHost(): ContactsSyncHost {
    const self = this;
    return {
      set: (key, value) => self._hostSet(key, value),
      get: <T>(key: string) => self._hostGet<T>(key),
      clear: (key) => self._hostClear(key),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tools: self.tools as any,
      scheduler: {
        queueSyncBatch: (batchNumber, syncableId) =>
          self.queueSyncBatch(batchNumber, syncableId),
      },
    };
  }

  async getChannels(_auth: Authorization, _token: AuthToken): Promise<Channel[]> {
    return [{ id: "contacts", title: "Contacts" }];
  }

  /**
   * Called when a channel is enabled. Seeds sync state and kicks off the
   * initial backfill. Delegates to {@link onChannelEnabledFn}.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    const start = await onChannelEnabledFn(this.makeHost(), channel.id);
    if (!start) return;
    await this.queueSyncBatch(1, channel.id);
  }

  /**
   * Called when a channel is disabled. Removes state. Delegates to
   * {@link onChannelDisabledFn}.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await onChannelDisabledFn(this.makeHost(), channel.id);
  }

  /**
   * Fetch a single page of the user's Google Contacts. Public TOOL API —
   * consumed by other Google connectors. Delegates to {@link getContactsFn}.
   */
  async getContacts(syncableId: string): Promise<NewContact[]> {
    return getContactsFn(this.makeHost(), syncableId);
  }

  /**
   * Seed sync state and kick off the initial backfill. Public TOOL API —
   * consumed by other Google connectors. Delegates to {@link startSyncFn}.
   */
  async startSync(syncableId: string): Promise<void> {
    const start = await startSyncFn(this.makeHost(), syncableId);
    if (!start) return;
    await this.queueSyncBatch(1, syncableId);
  }

  /**
   * Clear the persisted backfill cursor. Public TOOL API — consumed by other
   * Google connectors. Delegates to {@link stopSyncFn}.
   */
  async stopSync(syncableId: string): Promise<void> {
    await stopSyncFn(this.makeHost(), syncableId);
  }

  // ---------------------------------------------------------------------------
  // Scheduling — stays on the connector
  // ---------------------------------------------------------------------------

  /** Queue the next contact-import batch as a fresh task. */
  private async queueSyncBatch(
    batchNumber: number,
    syncableId: string
  ): Promise<void> {
    const callback = await this.callback(
      this.syncBatch,
      batchNumber,
      syncableId
    );
    await this.runTask(callback);
  }

  // ---------------------------------------------------------------------------
  // Sync batch — delegate to extracted state machine, own the scheduling
  // ---------------------------------------------------------------------------

  /**
   * Process a batch of contacts. Delegates to {@link syncBatchFn}, which
   * schedules the next page (when more remain) through the host scheduler back
   * to {@link queueSyncBatch}.
   */
  async syncBatch(batchNumber: number, syncableId: string): Promise<void> {
    await syncBatchFn(this.makeHost(), batchNumber, syncableId);
  }
}
