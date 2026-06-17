import {
  type Action,
  ActionType,
  type Actor,
  type ActorId,
  ConferencingProvider,
  Connector,
  type NewContact,
  type NewLinkWithNotes,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import { Options } from "@plotday/twister/options";
import type {
  NewSchedule,
  NewScheduleContact,
  NewScheduleOccurrence,
  ScheduleContactStatus,
} from "@plotday/twister/schedule";
import {
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import { CalDAVClient, type CalDAVEvent, toCalDAVTimeString } from "./caldav";
import {
  type ICSEvent,
  parseICSDateTime,
  parseICSEvents,
  parseRRuleCount,
  parseRRuleEnd,
  updateAttendeePartstat,
} from "./ics-parser";

/**
 * Build canonical identifiers for an Apple calendar (ICS) event. First
 * element is the connector-native source; second is the cross-vendor
 * `icaluid:<UID>` alias so other connectors can bundle into this thread.
 * Apple's ICS UID is already the iCalUID by spec.
 */
function buildEventSources(uid: string | null | undefined): string[] {
  if (!uid) return [];
  return [`apple-calendar:${uid}`, `icaluid:${uid}`];
}

type SyncState = {
  calendarHref: string;
  initialSync: boolean;
  batchNumber: number;
  /** Event hrefs remaining to process (for batched multiget) */
  pendingHrefs?: string[];
  /**
   * Initial sync is two-pass:
   *  - `quick` walks `start = now → end = now + 1y` so upcoming meetings
   *    surface immediately.
   *  - `full` walks `start = 2y ago → end = now + 1y` for the historical
   *    backfill. The two passes share one sync lock; phase carries the
   *    transition without releasing.
   * Absent on incremental sync.
   */
  phase?: "quick" | "full";
  /** Range used by the current pass (only set during initial sync). */
  timeRangeStart?: string;
  timeRangeEnd?: string;
};

/**
 * Short stable hash of a string for use in note keys. Same content
 * produces the same key (idempotent upsert on re-sync); edited content
 * produces a different key (new note, prior versions preserved as
 * history on the thread).
 */
async function hashContent(content: string): Promise<string> {
  const data = new TextEncoder().encode(content);
  const buf = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(buf);
  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}

/**
 * Apple Calendar connector — syncs events from iCloud via CalDAV.
 *
 * Uses app-specific password authentication (no OAuth).
 * Polls for changes using ctag/etag change detection since CalDAV
 * does not support push notifications.
 */
export class AppleCalendar extends Connector<AppleCalendar> {
  readonly linkTypes = [
    {
      type: "event",
      label: "Event",
      sharingModel: "thread" as const,
      includesSchedules: true,
      logo: "https://plot.day/assets/logo-apple-calendar.svg",
      logoMono: "https://api.iconify.design/simple-icons/apple.svg",
    },
  ];
  readonly channelNoun = { singular: "calendar", plural: "calendars" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly access = [
    "Reads your iCloud calendar events to add them to your agenda",
    "Writes your event RSVPs",
  ];

  // Lock TTL covering the worst-case full backfill. The framework releases
  // the lock automatically after this window even if a worker crashes, so
  // no stuck-sync recovery is needed.
  private static readonly SYNC_LOCK_TTL_MS = 2 * 60 * 60 * 1000;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        appleId: {
          type: "text" as const,
          label: "Apple ID",
          default: "",
          placeholder: "you@icloud.com",
        },
        appPassword: {
          type: "text" as const,
          secure: true,
          label: "App-Specific Password",
          default: "",
          placeholder: "xxxx-xxxx-xxxx-xxxx",
          description:
            "Generate at appleid.apple.com > Sign-In and Security > App-Specific Passwords",
        },
      }),
      network: build(Network, {
        urls: ["https://caldav.icloud.com/*", "https://*.icloud.com/*"],
      }),
      tasks: build(Tasks),
    };
  }

  // ---- Helpers ----

  private getCalDAV(): CalDAVClient {
    const appleId = this.tools.options.appleId as string;
    const appPassword = this.tools.options.appPassword as string;
    if (!appleId || !appPassword) {
      throw new Error(
        "Apple ID and app-specific password are required. Configure them in the connector options."
      );
    }
    return new CalDAVClient({ appleId, appPassword });
  }

  /**
   * Discover principal and calendar home, caching the results.
   */
  private async discoverCalendarHome(): Promise<string> {
    const cached = await this.get<string>("calendar_home");
    if (cached) return cached;

    const client = this.getCalDAV();
    const principal = await client.discoverPrincipal();
    await this.set("principal_url", principal);

    const calendarHome = await client.discoverCalendarHome(principal);
    await this.set("calendar_home", calendarHome);

    return calendarHome;
  }

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    const appleId = this.tools.options.appleId as string | undefined;
    return appleId && appleId.length > 0 ? appleId : null;
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns available iCloud calendars as channels.
   * Auth params are null since we use Options for credentials.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    const calendarHome = await this.discoverCalendarHome();
    const client = this.getCalDAV();
    const calendars = await client.listCalendars(calendarHome);
    return calendars.map((c) => ({ id: c.href, title: c.displayName }));
  }

  /**
   * Called when a calendar channel is enabled for syncing.
   *
   * Three cases (see SyncContext docs):
   *  - Initial enable: full backfill from scratch.
   *  - Already-enabled history-min refresh: skips when stored window is
   *    already at least as wide.
   *  - Recovery (`context.recovering = true`): the user re-entered their
   *    Apple ID / app-specific password after a credentials change. Drop
   *    the persisted ctag, etag/uid maps, sync state, and any scheduled
   *    poll so the next pass re-walks every event and picks up changes
   *    that landed during the auth gap.
   *
   * Keep this method thin: it must return quickly so the HTTP response
   * boundary doesn't hold the sync lock. All real init work (lock,
   * starting ctag, first batch) is deferred to initChannel which runs
   * inside a queued task.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    if (context?.recovering) {
      // Wipe persisted cursors and per-event state so the next pass
      // re-walks history. Each clear is idempotent. Release any TTL-stuck
      // lock from the pre-recovery outage so initChannel can acquire fresh.
      await this.clear(`ctag_${channel.id}`);
      await this.clear(`etags_${channel.id}`);
      await this.clear(`event_uids_${channel.id}`);
      await this.clear(`sync_state_${channel.id}`);
      await this.tools.store.releaseLock(`sync_${channel.id}`);

      // Cancel any scheduled poll so the post-recovery sync starts cleanly
      // (a stale poll firing concurrently would race against initChannel).
      await this.cancelScheduledTask(`poll:${channel.id}`);

      // Clear any `pending_occ:` / `seen_master:` markers left behind
      // by the crashed pre-recovery sync. Stale markers from a half-done
      // run can otherwise cause the next full-pass orphan flush to
      // materialise empty Untitled threads (leftover `pending_occ`
      // matching leftover `seen_master` whose link no longer exists).
      await this.clearBuffers(channel.id);
    } else if (context?.syncHistoryMin) {
      // Store sync_history_min if provided and not already stored with an
      // equal/earlier value. Skipped on recovery so the recovery pass
      // re-walks even when the window hasn't widened.
      const key = `sync_history_min_${channel.id}`;
      const stored = await this.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await this.set(key, context.syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue all initialization work as a task so the HTTP response returns
    // quickly. initChannel acquires the sync lock, fetches the starting
    // ctag, and queues the first batch.
    const initCallback = await this.callback(this.initChannel, channel.id);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a calendar channel: acquires the sync lock, fetches the
   * starting ctag, initializes sync state, and queues the first sync batch.
   * Runs as a queued task so the lock acquisition doesn't straddle the
   * HTTP-response boundary (where a dropped task could leave the lock held
   * until the TTL expires) and so the first batch's CalDAV multiget runs
   * in its own task.
   */
  async initChannel(channelId: string): Promise<void> {
    // Acquire sync lock. Self-expires after SYNC_LOCK_TTL_MS so a crashed
    // worker can't wedge sync forever. Bails if another sync is in flight
    // (e.g. an in-flight poll or a previous initChannel that hasn't drained).
    const acquired = await this.tools.store.acquireLock(
      `sync_${channelId}`,
      AppleCalendar.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      // Another sync holds the lock (e.g. an in-flight init from a previous
      // enable attempt that hasn't drained, or a stuck TTL'd run). Schedule
      // a poll so the next interval can retry init — otherwise this channel
      // would be stuck with no scheduled work until the user re-enables.
      await this.schedulePoll(channelId);
      return;
    }

    try {
      // Store initial ctag for incremental sync
      const client = this.getCalDAV();
      const ctag = await client.getCalendarCtag(channelId);
      if (ctag) await this.set(`ctag_${channelId}`, ctag);

      // Two-pass initial sync:
      //  - Quick pass: `start = now → end = now + 1y`. Front-loads upcoming
      //    meetings so they appear in the activity feed immediately. Skips
      //    long-running recurring masters whose first instance is in the past
      //    (those land in the full pass).
      //  - Full pass: `start = 2y ago → end = now + 1y`. Walks the historical
      //    backfill. Saves are idempotent by `source`, so the overlap with
      //    the quick window is harmless.
      // The transition queues a fresh syncBatch with phase "full" without
      // releasing the lock; the full pass's terminal batch fires the
      // pending_occ orphan flush, channelSyncCompleted, and lock release.
      const now = new Date();
      const quickStart = toCalDAVTimeString(now);
      const quickEnd = toCalDAVTimeString(
        new Date(now.getFullYear() + 1, 11, 31)
      );

      await this.set(`sync_state_${channelId}`, {
        calendarHref: channelId,
        initialSync: true,
        batchNumber: 1,
        phase: "quick",
        timeRangeStart: quickStart,
        timeRangeEnd: quickEnd,
      } as SyncState);

      // Queue the first batch as a separate task instead of awaiting inline.
      // This mirrors google-calendar's initCalendar pattern: the init task
      // returns immediately after setup, freeing the runtime to schedule
      // syncBatch (which does the heavy CalDAV multiget) on its own.
      const syncCallback = await this.callback(
        this.syncBatch,
        channelId,
        true, // initialSync
        1, // batchNumber
        quickStart,
        quickEnd
      );
      await this.runTask(syncCallback);
    } catch (error) {
      // CalDAV throws here (bad credentials, network outage) would otherwise
      // leave the just-acquired lock held for the full 2-hour TTL. Release
      // it and schedule a poll so the next interval can retry init.
      try {
        await this.tools.store.releaseLock(`sync_${channelId}`);
        await this.clear(`sync_state_${channelId}`);
      } catch (cleanupError) {
        console.error(
          "Cleanup after initChannel failure also failed:",
          cleanupError
        );
      }
      await this.schedulePoll(channelId);
      throw error;
    }
  }

  /**
   * Called when a calendar channel is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    // Cancel scheduled poll (singleton keyed task).
    await this.cancelScheduledTask(`poll:${channel.id}`);

    // Clear all state for this channel
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`ctag_${channel.id}`);
    await this.clear(`etags_${channel.id}`);
    await this.clear(`event_uids_${channel.id}`);

    // Release the framework-managed sync lock so a re-enable can acquire
    // cleanly without waiting for the TTL.
    await this.tools.store.releaseLock(`sync_${channel.id}`);

    // Clear pending occurrences AND seen-master markers for this
    // calendar only. Keys are scoped per calendar (calendar href as
    // prefix) so disabling one calendar doesn't wipe buffers for
    // siblings on the same account that are still enabled.
    await this.clearBuffers(channel.id);
  }

  /**
   * Clear all `pending_occ:` and `seen_master:` markers for one calendar.
   * Used on recovery, disable, and sync-error paths so stale buffers from
   * a crashed run can't combine with leftover seen-master markers to
   * materialise empty Untitled threads on the next initial sync.
   */
  private async clearBuffers(channelHref: string): Promise<void> {
    const pendingKeys = await this.tools.store.list(
      `pending_occ:${channelHref}:`
    );
    for (const key of pendingKeys) {
      await this.clear(key);
    }
    const seenMasterKeys = await this.tools.store.list(
      `seen_master:${channelHref}:`
    );
    for (const key of seenMasterKeys) {
      await this.clear(key);
    }
  }

  // ---- Sync Logic ----

  /**
   * Sync a batch of calendar events.
   */
  async syncBatch(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number,
    timeRangeStart?: string,
    timeRangeEnd?: string
  ): Promise<void> {
    try {
      const client = this.getCalDAV();

      if (batchNumber === 1 && timeRangeStart && timeRangeEnd) {
        // First batch: fetch all events in the time range. Preserve `phase`
        // from any pre-seeded state (initChannel writes phase=quick before
        // queuing this callback; the quick→full transition writes phase=full
        // before queuing again).
        const seeded = await this.get<SyncState>(`sync_state_${calendarHref}`);
        const phase = seeded?.phase;
        const events = await client.fetchEvents(calendarHref, {
          start: timeRangeStart,
          end: timeRangeEnd,
        });

        // Process events in batches. processCalDAVEvents persists the
        // href→uid AND href→etag maps together at end-of-batch so the two
        // stay consistent across worker crashes — see the comment on
        // processCalDAVEvents for why we deliberately don't pre-write
        // etags before processing.
        await this.processCalDAVEvents(
          events.slice(0, 50),
          calendarHref,
          initialSync
        );

        if (events.length > 50) {
          // Store remaining hrefs for next batches
          const remainingHrefs = events.slice(50).map((e) => e.href);
          await this.set(`sync_state_${calendarHref}`, {
            calendarHref,
            initialSync,
            batchNumber: batchNumber + 1,
            pendingHrefs: remainingHrefs,
            phase,
            timeRangeStart,
            timeRangeEnd,
          } as SyncState);

          const nextBatch = await this.callback(
            this.syncBatchContinue,
            calendarHref,
            initialSync,
            batchNumber + 1
          );
          await this.runTask(nextBatch);
        } else {
          await this.finishSync(calendarHref, initialSync, phase);
        }
      }
    } catch (error) {
      console.error(
        `Apple Calendar sync failed for ${calendarHref} in batch ${batchNumber}:`,
        error
      );

      // Release lock and clear state so future syncs aren't permanently
      // blocked. Wrap in its own try/catch so a release/clear failure
      // doesn't mask the original error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`sync_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Clear any `pending_occ:` / `seen_master:` markers buffered by
      // this initial-sync run. Otherwise the next initial sync would
      // inherit them and the full-pass orphan flush could materialise
      // empty Untitled threads from leftover-but-now-stale buffers.
      // Incremental sync doesn't buffer, but the clear is idempotent.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // The runtime auto-clears the "Syncing…" indicator when
      // onChannelEnabled itself throws, but NOT when a queued task
      // throws. Without an explicit signal here, the indicator stays on
      // indefinitely after a mid-sync crash until the user disables and
      // re-enables. Inner try/catch so a signal failure doesn't mask
      // the original error.
      if (initialSync) {
        try {
          await this.tools.integrations.channelSyncCompleted(calendarHref);
        } catch (signalError) {
          console.error(
            "Failed to signal sync completion on error path:",
            signalError
          );
        }
      }

      // Schedule a poll so polling resumes — otherwise a failure here
      // strands the channel (startIncrementalSync's lock-fail bail
      // intentionally relies on the active holder, which is us, to
      // reschedule).
      await this.schedulePoll(calendarHref);

      // Re-throw to let the runtime handle it (PostHog capture, etc.).
      throw error;
    }
  }

  /**
   * Continue processing remaining events using multiget.
   */
  async syncBatchContinue(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number
  ): Promise<void> {
    try {
      const state = await this.get<SyncState>(`sync_state_${calendarHref}`);
      if (!state?.pendingHrefs?.length) {
        await this.finishSync(calendarHref, initialSync, state?.phase);
        return;
      }

      const client = this.getCalDAV();
      const batch = state.pendingHrefs.slice(0, 50);
      const remaining = state.pendingHrefs.slice(50);

      const events = await client.fetchEventsByHref(calendarHref, batch);
      await this.processCalDAVEvents(events, calendarHref, initialSync);

      if (remaining.length > 0) {
        await this.set(`sync_state_${calendarHref}`, {
          calendarHref,
          initialSync,
          batchNumber: batchNumber + 1,
          pendingHrefs: remaining,
          phase: state.phase,
          timeRangeStart: state.timeRangeStart,
          timeRangeEnd: state.timeRangeEnd,
        } as SyncState);

        const nextBatch = await this.callback(
          this.syncBatchContinue,
          calendarHref,
          initialSync,
          batchNumber + 1
        );
        await this.runTask(nextBatch);
      } else {
        await this.finishSync(calendarHref, initialSync, state.phase);
      }
    } catch (error) {
      console.error(
        `Apple Calendar sync continue failed for ${calendarHref} in batch ${batchNumber}:`,
        error
      );

      // Release lock and clear state so future syncs aren't permanently
      // blocked. Wrap cleanup so a release/clear failure doesn't mask the
      // original error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`sync_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Clear any `pending_occ:` / `seen_master:` markers buffered by
      // this initial-sync run — see syncBatch's catch for why.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // The runtime auto-clears the "Syncing…" indicator when
      // onChannelEnabled itself throws, but NOT when a queued task
      // throws — see syncBatch's catch for the full rationale.
      if (initialSync) {
        try {
          await this.tools.integrations.channelSyncCompleted(calendarHref);
        } catch (signalError) {
          console.error(
            "Failed to signal sync completion on error path:",
            signalError
          );
        }
      }

      // Schedule a poll so polling resumes — startIncrementalSync's
      // lock-fail bail relies on the active holder (us) to reschedule.
      await this.schedulePoll(calendarHref);

      throw error;
    }
  }

  /**
   * Clean up after sync completes and schedule polling.
   *
   * On initial sync, this is invoked twice — once for the quick pass and
   * once for the full pass. The quick→full transition queues a fresh
   * syncBatch with `phase = "full"` and returns WITHOUT releasing the
   * lock or signalling completion. The full-pass terminal call performs
   * the orphan flush, ctag bump, channelSyncCompleted, and lock release.
   */
  private async finishSync(
    calendarHref: string,
    initialSync: boolean,
    phase?: "quick" | "full"
  ): Promise<void> {
    // Quick pass done: transition to full pass without releasing the lock
    // or clearing pending_occ buffers. The full pass walks the historical
    // range and any exception instances the quick pass buffered are
    // carried across; orphans (master never appeared in either pass) are
    // cleared by the orphan-flush block on the full-pass terminal below.
    if (initialSync && phase === "quick") {
      const now = new Date();
      const fullStart = toCalDAVTimeString(
        new Date(now.getFullYear() - 2, 0, 1)
      );
      const fullEnd = toCalDAVTimeString(
        new Date(now.getFullYear() + 1, 11, 31)
      );

      await this.set(`sync_state_${calendarHref}`, {
        calendarHref,
        initialSync: true,
        batchNumber: 1,
        phase: "full",
        timeRangeStart: fullStart,
        timeRangeEnd: fullEnd,
      } as SyncState);

      const fullCallback = await this.callback(
        this.syncBatch,
        calendarHref,
        true,
        1,
        fullStart,
        fullEnd
      );
      await this.runTask(fullCallback);
      return;
    }

    // Full-pass terminal (or `phase` absent, e.g. older deployed callbacks):
    // flush leftover pending_occ buffers as standalone occurrence-only
    // links — but ONLY when their master was actually processed during
    // this initial sync (and is therefore in the DB by now).
    // `seen_master:<canonical>` markers, written per batch in
    // processCalDAVEvents, distinguish legitimate cross-batch leftovers
    // (master-in-batch-A, instance-in-batch-B → flushed; saveLinks
    // upserts onto the existing master link) from orphans whose master
    // never came through (master deleted upstream → flushing would
    // create a useless empty Untitled thread, so drop silently).
    if (initialSync) {
      // Scope lookups to this calendar so concurrent syncs of other
      // calendars in the same account aren't affected.
      const seenMasterPrefix = `seen_master:${calendarHref}:`;
      const pendingPrefix = `pending_occ:${calendarHref}:`;
      const seenMasterKeys = await this.tools.store.list(seenMasterPrefix);
      const seenMasters = new Set(
        seenMasterKeys.map((k) => k.slice(seenMasterPrefix.length))
      );
      const pendingKeys = await this.tools.store.list(pendingPrefix);
      const flushLinks: NewLinkWithNotes[] = [];
      let droppedOrphans = 0;
      for (const key of pendingKeys) {
        const pending = await this.get<NewScheduleOccurrence>(key);
        if (!pending) {
          await this.clear(key);
          continue;
        }
        const occurrenceDate =
          pending.occurrence instanceof Date
            ? pending.occurrence
            : new Date(pending.occurrence as unknown as string);
        const suffix = `:${occurrenceDate.toISOString()}`;
        if (!key.startsWith(pendingPrefix) || !key.endsWith(suffix)) {
          // Malformed key — drop it.
          await this.clear(key);
          continue;
        }
        const canonical = key.slice(
          pendingPrefix.length,
          key.length - suffix.length
        );
        if (!seenMasters.has(canonical)) {
          droppedOrphans += 1;
          await this.clear(key);
          continue;
        }
        flushLinks.push({
          type: "event",
          title: undefined,
          source: canonical,
          sources: canonical.startsWith("apple-calendar:")
            ? buildEventSources(canonical.slice("apple-calendar:".length))
            : undefined,
          channelId: calendarHref,
          meta: {
            uid: canonical.startsWith("apple-calendar:")
              ? canonical.slice("apple-calendar:".length)
              : null,
            syncProvider: "apple",
            syncableId: calendarHref,
          },
          scheduleOccurrences: [pending],
          notes: [],
        });
        await this.clear(key);
      }
      if (flushLinks.length > 0 || droppedOrphans > 0) {
        console.log(
          `[AppleCalendar] full-pass flush: calendar=${calendarHref} ` +
            `flushedLinks=${flushLinks.length} ` +
            `droppedOrphans=${droppedOrphans}`
        );
      }
      if (flushLinks.length > 0) {
        await this.tools.integrations.saveLinks(flushLinks);
      }

      // Clear master markers for the next initial sync.
      for (const key of seenMasterKeys) {
        await this.clear(key);
      }
    }

    // Update ctag
    const client = this.getCalDAV();
    const ctag = await client.getCalendarCtag(calendarHref);
    if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

    await this.clear(`sync_state_${calendarHref}`);

    // Initial sync is fully complete — clear the "syncing…" indicator on
    // the connection. Gated on initialSync so incremental polls don't
    // re-fire the signal.
    if (initialSync) {
      await this.tools.integrations.channelSyncCompleted(calendarHref);
    }

    // Release the framework-managed sync lock so the next poll (or a
    // manual re-trigger) can acquire it.
    await this.tools.store.releaseLock(`sync_${calendarHref}`);

    // Schedule next poll in 15 minutes
    await this.schedulePoll(calendarHref);
  }

  /**
   * Schedule a poll for changes in 15 minutes.
   */
  private async schedulePoll(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    // Singleton scheduled task: re-scheduling under this key atomically
    // replaces any pending poll, so the self-rescheduling loop can never
    // stack — even if onChannelEnabled is re-dispatched (auto-enable /
    // recovery) or multiple sync paths each (re)schedule a poll.
    const pollCallback = await this.callback(this.pollForChanges, calendarHref);
    await this.scheduleTask(`poll:${calendarHref}`, pollCallback, {
      runAt: new Date(Date.now() + 15 * 60 * 1000),
    });
  }

  /**
   * Poll for changes using ctag comparison.
   */
  async pollForChanges(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    try {
      const client = this.getCalDAV();
      const currentCtag = await client.getCalendarCtag(calendarHref);
      const storedCtag = await this.get<string>(`ctag_${calendarHref}`);

      if (currentCtag && currentCtag !== storedCtag) {
        // Calendar has changed — run incremental sync
        await this.startIncrementalSync(calendarHref);
      } else {
        // No changes — just schedule next poll
        await this.schedulePoll(calendarHref);
      }
    } catch (error) {
      console.error(`Poll failed for calendar ${calendarHref}:`, error);
      // Schedule next poll even on failure
      await this.schedulePoll(calendarHref);
    }
  }

  /**
   * Incremental sync: compare etags to find changed/new/deleted events.
   */
  private async startIncrementalSync(calendarHref: string): Promise<void> {
    // Acquire sync lock to prevent the 15-min poll from racing an
    // in-progress initial sync, or two polls overlapping if a previous
    // run is still draining batches.
    const acquired = await this.tools.store.acquireLock(
      `sync_${calendarHref}`,
      AppleCalendar.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      // Another sync is in flight. Don't reschedule a poll either — the
      // running sync's finishSync will schedule the next one.
      return;
    }

    try {
      const client = this.getCalDAV();

      // Get current etags
      const currentEtags = await client.getEventEtags(calendarHref);
      const storedEtags =
        (await this.get<Record<string, string>>(`etags_${calendarHref}`)) || {};
      const storedUids =
        (await this.get<Record<string, string>>(
          `event_uids_${calendarHref}`
        )) || {};

      // Find new/changed events
      const changedHrefs: string[] = [];
      const newEtagMap: Record<string, string> = {};

      for (const [href, etag] of currentEtags) {
        newEtagMap[href] = etag;
        if (!storedEtags[href] || storedEtags[href] !== etag) {
          changedHrefs.push(href);
        }
      }

      // Find deleted events (present in stored, absent from current)
      const deletedHrefs: string[] = [];
      for (const href of Object.keys(storedEtags)) {
        if (!currentEtags.has(href)) {
          deletedHrefs.push(href);
        }
      }

      // Archive deleted events selectively, per-uid. Previously this code
      // called archiveLinks with only the channel-level meta — a
      // containment filter that matches every Apple event on the channel.
      // One deleted event would wipe the whole calendar. The href→uid map
      // built in processEvent/processEventInstance lets us resolve each
      // deleted href back to its uid and archive precisely.
      //
      // Hrefs missing from the uid map are skipped (logged): they were
      // synced before this map existed, will be rebuilt on the next batch
      // that touches them, but on this one run we can't safely archive by
      // channel without the data-loss risk above.
      let archivedCount = 0;
      let missingUidCount = 0;
      // Per-uid archive is serial — fine for typical incremental drift
      // (≤handful of deletes per poll), but a bulk delete (user clearing
      // a multi-year backfill) could approach the ~1000-request runtime
      // limit.
      //
      // TODO: extend `integrations.archiveLinks` to accept a `uids[]`
      // filter (or chunk this loop into batched callbacks via runTask)
      // before this becomes a real-world cap. Deferred for now —
      // typical deletion volume is well below the budget.
      for (const href of deletedHrefs) {
        const uid = storedUids[href];
        if (!uid) {
          missingUidCount += 1;
          continue;
        }
        await this.tools.integrations.archiveLinks({
          channelId: calendarHref,
          meta: { syncProvider: "apple", syncableId: calendarHref, uid },
        });
        archivedCount += 1;
      }
      if (deletedHrefs.length > 0) {
        console.log(
          `[AppleCalendar] incremental sync: calendar=${calendarHref} ` +
            `deleted=${deletedHrefs.length} archived=${archivedCount} ` +
            `missingUid=${missingUidCount}`
        );
      }

      // Fetch and process changed events. processCalDAVEvents updates
      // event_uids_<calendarHref> from each event's uid so future
      // incremental syncs can archive them precisely.
      if (changedHrefs.length > 0) {
        const events = await client.fetchEventsByHref(
          calendarHref,
          changedHrefs
        );
        await this.processCalDAVEvents(events, calendarHref, false);
      }

      // Prune the uid map: drop entries whose href is no longer present in
      // the current etag set. Keeps the map bounded as events are deleted.
      const newUidMap: Record<string, string> = {};
      for (const href of Object.keys(newEtagMap)) {
        const uid = storedUids[href];
        if (uid) newUidMap[href] = uid;
      }
      await this.set(`event_uids_${calendarHref}`, newUidMap);

      // Update stored etags and ctag
      await this.set(`etags_${calendarHref}`, newEtagMap);
      const ctag = await client.getCalendarCtag(calendarHref);
      if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

      // Release lock before scheduling the next poll so the poll can
      // re-acquire cleanly.
      await this.tools.store.releaseLock(`sync_${calendarHref}`);

      // Schedule next poll
      await this.schedulePoll(calendarHref);
    } catch (error) {
      console.error(
        `Apple Calendar incremental sync failed for ${calendarHref}:`,
        error
      );

      // Release lock so future syncs aren't permanently blocked. Wrap in
      // its own try/catch so a release failure doesn't mask the real
      // error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar incremental sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Incremental sync doesn't buffer to `pending_occ:`, but the next
      // initial sync (after a fresh enable) might inherit any markers
      // sitting in storage. The clear is idempotent so it's safe to run
      // here even on the incremental error path.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after incremental sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // Reschedule a poll so we recover on the next interval.
      await this.schedulePoll(calendarHref);

      throw error;
    }
  }

  // ---- Event Processing ----

  /**
   * Process CalDAV events (parse ICS and save as links).
   *
   * Also maintains the `event_uids_<calendarHref>` and `etags_<calendarHref>`
   * maps keyed by event href so future incremental syncs can archive deleted
   * events selectively by uid (see startIncrementalSync). Both maps are
   * updated together at end-of-batch as one logical commit per batch — if a
   * worker crashes mid-batch and never reaches this point, neither map is
   * advanced, keeping stored etags and stored uids consistent. Writing etags
   * before this method ran would have stranded hrefs in the etag set with no
   * uid mapping, so a future deletion would silently drop (logged as
   * missingUid).
   *
   * Recurrence-only entries (RECURRENCE-ID overrides) share the same uid
   * as their master, so the master entry already covers them — we record
   * uid once per href.
   */
  private async processCalDAVEvents(
    events: CalDAVEvent[],
    calendarHref: string,
    initialSync: boolean
  ): Promise<void> {
    // Load persisted href→uid and href→etag maps once, merge new entries
    // from this batch in memory, and write back together at the end. Avoids
    // one read+write per event and ensures both maps advance atomically per
    // batch.
    const uidMap =
      (await this.get<Record<string, string>>(
        `event_uids_${calendarHref}`
      )) || {};
    const etagMap =
      (await this.get<Record<string, string>>(`etags_${calendarHref}`)) || {};
    let uidMapDirty = false;
    let etagMapDirty = false;

    // Coalesce everything keyed by canonical source so a master + any number
    // of its exception instances (and multiple exceptions of the same series
    // landing in the same batch) collapse into a single NewLinkWithNotes. The
    // final saveLinks call makes one RPC for the entire batch. Heavy
    // recurring meetings (master + many exception VEVENTs in one ICS file)
    // used to fire N+1 saveLink calls; now they fire one.
    const linksBySource = new Map<string, NewLinkWithNotes>();
    type LinkWithSource = NewLinkWithNotes & { source: string };
    const addLink = (link: LinkWithSource) => {
      const existing = linksBySource.get(link.source) as
        | LinkWithSource
        | undefined;
      if (!existing) {
        linksBySource.set(link.source, link);
        return;
      }
      // Merge occurrences and notes. Prefer the fuller entry (master)
      // when only one side carries the series-level fields (schedules,
      // title, ...).
      existing.scheduleOccurrences = [
        ...(existing.scheduleOccurrences || []),
        ...(link.scheduleOccurrences || []),
      ];
      if (link.notes?.length) {
        existing.notes = [...(existing.notes || []), ...link.notes];
      }
      if (link.schedules && !existing.schedules) {
        existing.schedules = link.schedules;
        existing.title = link.title ?? existing.title;
        existing.type = link.type ?? existing.type;
        existing.status = link.status ?? existing.status;
        existing.actions = link.actions ?? existing.actions;
        existing.sourceUrl = link.sourceUrl ?? existing.sourceUrl;
        existing.preview = link.preview ?? existing.preview;
        existing.access = link.access ?? existing.access;
        existing.accessContacts =
          link.accessContacts ?? existing.accessContacts;
        existing.author = link.author ?? existing.author;
        existing.created = link.created ?? existing.created;
        existing.meta = { ...(existing.meta || {}), ...(link.meta || {}) };
        if (link.unread !== undefined) existing.unread = link.unread;
        if (link.archived !== undefined) existing.archived = link.archived;
      }
    };

    for (const caldavEvent of events) {
      try {
        const icsEvents = parseICSEvents(caldavEvent.icsData);

        for (const icsEvent of icsEvents) {
          // Record href→uid mapping. Apple ICS UID is stable per event
          // (RECURRENCE-ID overrides share the master's uid) so writing
          // it once per href is sufficient.
          if (icsEvent.uid && uidMap[caldavEvent.href] !== icsEvent.uid) {
            uidMap[caldavEvent.href] = icsEvent.uid;
            uidMapDirty = true;
          }

          if (icsEvent.recurrenceId) {
            const instanceLink = await this.prepareEventInstance(
              icsEvent,
              calendarHref,
              initialSync
            );
            if (instanceLink) addLink(instanceLink as LinkWithSource);
          } else {
            const masterLink = await this.prepareEvent(
              icsEvent,
              calendarHref,
              initialSync,
              caldavEvent.href
            );
            if (masterLink) addLink(masterLink as LinkWithSource);
          }
        }

        // Record etag only after the per-event work succeeds so a parse
        // failure can't leave an etag without a uid (which would later
        // surface as a `missingUid` skip on deletion).
        if (etagMap[caldavEvent.href] !== caldavEvent.etag) {
          etagMap[caldavEvent.href] = caldavEvent.etag;
          etagMapDirty = true;
        }
      } catch (error) {
        console.error(
          `Error processing CalDAV event ${caldavEvent.href}:`,
          error
        );
      }
    }

    // Drain pending_occ buffers for any masters present in this batch.
    // Done here (after the events loop) instead of inline at master-
    // processing time so the merge is order-independent within a batch:
    // instances arriving before the master are caught (the original
    // case), and instances arriving after the master are caught too
    // (the case inline draining would miss, silently losing
    // cancellations whose master happened to come first in the
    // CalDAV response).
    let drainedTotal = 0;
    for (const [source, link] of linksBySource.entries()) {
      // Keys are scoped per calendar so concurrent syncs of other
      // calendars in the same account aren't affected.
      const pendingPrefix = `pending_occ:${calendarHref}:${source}:`;
      const pendingKeys = await this.tools.store.list(pendingPrefix);
      if (pendingKeys.length === 0) continue;
      const merged: NewScheduleOccurrence[] = [
        ...(link.scheduleOccurrences || []),
      ];
      for (const key of pendingKeys) {
        const pending = await this.get<NewScheduleOccurrence>(key);
        if (pending) {
          merged.push(pending);
          drainedTotal += 1;
        }
        await this.clear(key);
      }
      link.scheduleOccurrences = merged;
    }
    if (initialSync && drainedTotal > 0) {
      console.log(
        `[AppleCalendar] drain: calendar=${calendarHref} ` +
          `masters=${linksBySource.size} drained=${drainedTotal}`
      );
    }

    // Record every master/regular event saved this batch so the full-pass
    // terminal cleanup in finishSync can distinguish legitimate cross-
    // batch leftovers (master-in-batch-A, instance-in-batch-B → flush is
    // correct, upserts onto the existing master link) from orphans whose
    // master never came through (master deleted upstream → flushing
    // would create a useless empty Untitled thread, so drop silently).
    //
    // Scoped with the calendar href so multi-calendar accounts don't
    // share the seen-master set — without scoping, Calendar A's orphan
    // flush would treat B's buffered occurrences as flushable.
    if (initialSync) {
      for (const source of linksBySource.keys()) {
        await this.set(`seen_master:${calendarHref}:${source}`, true);
      }
    }

    // Single batched save for the whole batch. Collapses what used to be
    // one saveLink RPC per event (and one per exception instance on heavy
    // recurring meetings) into a single cross-runtime call.
    const batch = Array.from(linksBySource.values());
    if (batch.length > 0) {
      await this.tools.integrations.saveLinks(batch);
    }

    if (uidMapDirty) {
      await this.set(`event_uids_${calendarHref}`, uidMap);
    }
    if (etagMapDirty) {
      await this.set(`etags_${calendarHref}`, etagMap);
    }
  }

  /**
   * Transform a master/standalone ICS event into a {@link NewLinkWithNotes}
   * for the caller's batched saveLinks. Returns null when the event should
   * be skipped (e.g. already-cancelled events during initial sync). Never
   * saves directly.
   */
  private async prepareEvent(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean,
    eventHref?: string
  ): Promise<NewLinkWithNotes | null> {
    const source = `apple-calendar:${icsEvent.uid}`;
    const isCancelled = icsEvent.status === "CANCELLED";

    // On initial sync, skip cancelled events
    if (initialSync && isCancelled) return null;

    // Parse start/end
    const start = parseICSDateTime(icsEvent.dtstart);
    const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;

    // Author from organizer
    const authorContact: NewContact | undefined = icsEvent.organizer
      ? {
          email: icsEvent.organizer.email,
          name: icsEvent.organizer.name ?? undefined,
        }
      : undefined;

    // Handle cancelled events
    if (isCancelled) {
      const cancelNote = {
        key: "cancellation" as const,
        content: icsEvent.organizer?.name
          ? `${icsEvent.organizer.name} cancelled this event.`
          : "This event was cancelled.",
        contentType: "text" as const,
        // Apple ICS LAST-MODIFIED on a CANCELLED VEVENT is when the event
        // was cancelled (per RFC 5545); it doesn't drift on later edits
        // because cancelled events aren't edited further. Safe to use as
        // the note `created`.
        created: icsEvent.lastModified
          ? parseICSDateTimeToDate(icsEvent.lastModified)
          : new Date(),
      };

      return {
        source,
        sources: buildEventSources(icsEvent.uid),
        type: "event",
        title: icsEvent.summary ?? undefined,
        status: "Cancelled",
        preview: "Cancelled",
        channelId: calendarHref,
        meta: {
          uid: icsEvent.uid,
          eventHref: eventHref || null,
          syncProvider: "apple",
          syncableId: calendarHref,
        },
        notes: [cancelNote],
        schedules: [
          {
            start: start instanceof Date ? start : new Date(),
            archived: true,
          },
        ],
        ...(initialSync ? { unread: false } : {}),
        ...(initialSync ? { archived: false } : {}),
      };
    }

    // Build schedule
    const schedule: Omit<NewSchedule, "threadId"> = {
      start,
      end: end ?? null,
    };

    // Handle recurrence for master events
    if (icsEvent.rrule) {
      schedule.recurrenceRule = icsEvent.rrule;

      const recurrenceCount = parseRRuleCount(icsEvent.rrule);
      if (recurrenceCount) {
        schedule.recurrenceCount = recurrenceCount;
      } else {
        const recurrenceUntil = parseRRuleEnd(icsEvent.rrule);
        if (recurrenceUntil) {
          schedule.recurrenceUntil = recurrenceUntil;
        }
      }

      if (icsEvent.exdates.length > 0) {
        schedule.recurrenceExdates = icsEvent.exdates;
      }
    }

    // Build schedule occurrences from RDATEs
    let scheduleOccurrences: NewScheduleOccurrence[] | undefined;
    if (icsEvent.rdates.length > 0) {
      scheduleOccurrences = icsEvent.rdates.map((rdate) => ({
        occurrence: rdate,
        start: rdate,
      }));
    }

    // Build attendee contacts on the base schedule so client-generated
    // recurring occurrences inherit attendee data (needed for RSVP buttons).
    // Per-occurrence overrides with their own contacts take precedence.
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    let scheduleContacts: NewScheduleContact[] | undefined;
    if (validAttendees.length > 0) {
      scheduleContacts = validAttendees.map((att) => ({
        contact: { email: att.email, name: att.name ?? undefined },
        status:
          att.partstat === "ACCEPTED"
            ? ("attend" as const)
            : att.partstat === "DECLINED"
            ? ("skip" as const)
            : null,
        role:
          att.role === "CHAIR"
            ? ("organizer" as const)
            : att.role === "OPT-PARTICIPANT"
            ? ("optional" as const)
            : ("required" as const),
      }));
      schedule.contacts = scheduleContacts;
    }

    // Build actions (conferencing links from description/location)
    const actions: Action[] = [];
    const seenUrls = new Set<string>();

    if (icsEvent.location) {
      extractConferencingUrls(icsEvent.location, actions, seenUrls);
    }
    if (icsEvent.description) {
      extractConferencingUrls(icsEvent.description, actions, seenUrls);
    }
    if (icsEvent.url) {
      actions.push({
        type: ActionType.external,
        title: "Open Link",
        url: icsEvent.url,
      });
    }

    // Build description note. The key embeds a hash of the description
    // content so each distinct version produces a separate note:
    // re-syncing the same description is an idempotent no-op upsert
    // (same key + same content), while an edited description gets a new
    // key and a fresh note — preserving prior versions as history on
    // the thread. Apple ICS CREATED is per-spec stable across edits
    // (set once when the event is first created), so we can use it
    // directly as the note `created` without a firstSeenAt anchor
    // (unlike Outlook's lastModifiedDateTime, which drifts on any edit).
    const hasDescription =
      icsEvent.description && icsEvent.description.trim().length > 0;

    const attendeeMentions: NewContact[] = [];
    if (authorContact) attendeeMentions.push(authorContact);
    for (const att of validAttendees) {
      attendeeMentions.push({ email: att.email, name: att.name ?? undefined });
    }

    const descHash =
      hasDescription && icsEvent.description
        ? await hashContent(icsEvent.description)
        : null;
    const descriptionNote =
      hasDescription && descHash
        ? {
            key: `description-${descHash}`,
            content: icsEvent.description!,
            contentType: "text" as const,
            created: icsEvent.created
              ? parseICSDateTimeToDate(icsEvent.created)
              : undefined,
            ...(authorContact ? { author: authorContact } : {}),
          }
        : null;

    const notes = descriptionNote ? [descriptionNote] : [];

    return {
      source,
      sources: buildEventSources(icsEvent.uid),
      type: "event",
      title: icsEvent.summary || "",
      status:
        icsEvent.status === "CONFIRMED"
          ? "Confirmed"
          : icsEvent.status === "TENTATIVE"
          ? "Tentative"
          : "Confirmed",
      access: "private",
      accessContacts: attendeeMentions,
      created: icsEvent.created
        ? parseICSDateTimeToDate(icsEvent.created)
        : undefined,
      author: authorContact,
      channelId: calendarHref,
      meta: {
        uid: icsEvent.uid,
        eventHref: eventHref || null,
        syncProvider: "apple",
        syncableId: calendarHref,
        location: icsEvent.location || null,
      },
      sourceUrl: icsEvent.url ?? null,
      actions: actions.length > 0 ? actions : undefined,
      notes,
      preview: hasDescription ? icsEvent.description!.slice(0, 200) : null,
      schedules: [schedule],
      scheduleOccurrences,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Transform a recurring event instance (RECURRENCE-ID) into either an
   * occurrence-only {@link NewLinkWithNotes} (for the caller's batched
   * saveLinks), or `null` when the occurrence is instead buffered to
   * `pending_occ:` storage for cross-batch merging during initial sync.
   * Never saves directly.
   */
  private async prepareEventInstance(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    if (!icsEvent.recurrenceId) return null;

    const originalStart = parseICSDateTime(icsEvent.recurrenceId);
    const masterSource = `apple-calendar:${icsEvent.uid}`;

    // Handle cancelled instances
    if (icsEvent.status === "CANCELLED") {
      const start = parseICSDateTime(icsEvent.dtstart);
      const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;

      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence:
          originalStart instanceof Date
            ? originalStart
            : new Date(originalStart),
        start: start instanceof Date ? start : new Date(start),
        end: end,
        cancelled: true,
      };

      // During initial sync, buffer the occurrence under a unique key for
      // later merging with its master. Per-occurrence keys keep each write
      // O(1); appending to a single shared list was O(N²) across batches
      // and blew the CF worker CPU limit on calendars with many recurring
      // exceptions.
      //
      // The key is scoped with the calendar href so multi-calendar accounts
      // (e.g. iCloud Home + Work + Family) don't share `pending_occ:`
      // namespace. UIDs are globally unique per iCal spec, but they are
      // shared across one user's calendars whenever a meeting was filed
      // on more than one, so an un-scoped key would cause Calendar A's
      // orphan flush to misclassify B's buffered occurrences and silently
      // drop them.
      if (initialSync) {
        const occurrenceTs =
          originalStart instanceof Date
            ? originalStart.toISOString()
            : new Date(originalStart).toISOString();
        const pendingKey = `pending_occ:${calendarHref}:${masterSource}:${occurrenceTs}`;
        await this.set(pendingKey, cancelledOccurrence);
        return null;
      }

      return {
        type: "event",
        title: undefined,
        source: masterSource,
        sources: buildEventSources(icsEvent.uid),
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };
    }

    // Build contacts from attendees for this occurrence
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    const contacts: NewScheduleContact[] | undefined =
      validAttendees.length > 0
        ? validAttendees.map((att) => ({
            contact: { email: att.email, name: att.name ?? undefined },
            status:
              att.partstat === "ACCEPTED"
                ? ("attend" as const)
                : att.partstat === "DECLINED"
                ? ("skip" as const)
                : null,
            role:
              att.role === "CHAIR"
                ? ("organizer" as const)
                : att.role === "OPT-PARTICIPANT"
                ? ("optional" as const)
                : ("required" as const),
          }))
        : undefined;

    const instanceStart = parseICSDateTime(icsEvent.dtstart);
    const instanceEnd = icsEvent.dtend
      ? parseICSDateTime(icsEvent.dtend)
      : null;

    const occurrence: NewScheduleOccurrence = {
      occurrence:
        originalStart instanceof Date ? originalStart : new Date(originalStart),
      start: instanceStart,
      contacts,
      ...(initialSync ? { unread: false } : {}),
    };

    if (instanceEnd !== undefined && instanceEnd !== null) {
      occurrence.end = instanceEnd;
    }

    // During initial sync, buffer under a unique key for merging with
    // master. See the cancelled branch above for why per-occurrence keys
    // replaced the single-list-append pattern, and why the key is
    // prefixed with the calendar href.
    if (initialSync) {
      const occurrenceTs =
        originalStart instanceof Date
          ? originalStart.toISOString()
          : new Date(originalStart).toISOString();
      const pendingKey = `pending_occ:${calendarHref}:${masterSource}:${occurrenceTs}`;
      await this.set(pendingKey, occurrence);
      return null;
    }

    // Incremental sync: return an occurrence-only link. The caller merges
    // it with the master (if the master is in the same batch) or saves it
    // standalone (master already exists in the DB from a prior sync).
    return {
      type: "event",
      title: undefined,
      source: masterSource,
      sources: buildEventSources(icsEvent.uid),
      channelId: calendarHref,
      meta: { syncProvider: "apple", syncableId: calendarHref },
      scheduleOccurrences: [occurrence],
      notes: [],
    };
  }

  // ---- RSVP Write-Back ----

  /**
   * Called when a user changes their RSVP status in Plot.
   * Updates the ATTENDEE PARTSTAT in the CalDAV event via PUT.
   */
  async onScheduleContactUpdated(
    thread: Thread,
    _scheduleId: string,
    _contactId: ActorId,
    status: ScheduleContactStatus | null,
    _actor: Actor
  ): Promise<void> {
    const meta = thread.meta as Record<string, unknown> | null;
    const linkSource = meta?.linkSource as string | null;
    const calendarHref = meta?.syncableId as string | null;
    const eventHref = meta?.eventHref as string | null;

    if (!linkSource || !calendarHref || !eventHref) return;

    // The connector user's email is the Apple ID
    const appleId = this.tools.options.appleId as string;
    if (!appleId) return;

    // Map Plot status to CalDAV PARTSTAT
    const partstat =
      status === "attend"
        ? "ACCEPTED"
        : status === "skip"
        ? "DECLINED"
        : "NEEDS-ACTION";

    try {
      await this.updateRSVP(calendarHref, eventHref, appleId, partstat);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP to Apple Calendar", {
        eventHref,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Update RSVP status for the connector user on a CalDAV event.
   * Fetches the event ICS, modifies the ATTENDEE PARTSTAT, and PUTs it back.
   */
  private async updateRSVP(
    _calendarHref: string,
    eventHref: string,
    email: string,
    partstat: string
  ): Promise<void> {
    const client = this.getCalDAV();

    // Fetch current ICS
    const icsData = await client.fetchEventICS(eventHref);
    if (!icsData) {
      throw new Error(`Event not found: ${eventHref}`);
    }

    // Update the attendee's PARTSTAT
    const updatedICS = updateAttendeePartstat(icsData, email, partstat);
    if (!updatedICS) {
      console.warn(
        `[RSVP Sync] User ${email} is not an attendee of event ${eventHref}`
      );
      return;
    }

    // PUT the updated ICS back
    const success = await client.updateEventICS(eventHref, updatedICS);
    if (!success) {
      throw new Error(`Failed to update event: ${eventHref}`);
    }
  }
}

// ---- Helpers ----

/**
 * Parse a raw ICS datetime string to a Date (for created/lastModified fields).
 */
function parseICSDateTimeToDate(value: string): Date {
  const d = value.trim();
  if (/^\d{8}T\d{6}Z?$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    const hour = d.slice(9, 11);
    const minute = d.slice(11, 13);
    const second = d.slice(13, 15);
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
  }
  return new Date(d);
}

/**
 * Detect conferencing provider from a URL.
 */
function detectConferencingProvider(url: string): ConferencingProvider | null {
  const lowerUrl = url.toLowerCase();

  if (lowerUrl.includes("zoom.us")) return ConferencingProvider.zoom;
  if (
    lowerUrl.includes("teams.microsoft.com") ||
    lowerUrl.includes("teams.live.com")
  )
    return ConferencingProvider.microsoftTeams;
  if (lowerUrl.includes("webex.com")) return ConferencingProvider.webex;
  if (lowerUrl.includes("meet.google.com"))
    return ConferencingProvider.googleMeet;

  return null;
}

/**
 * Extract conferencing URLs from text and add to actions array.
 */
function extractConferencingUrls(
  text: string,
  actions: Action[],
  seenUrls: Set<string>
): void {
  const urlRegex = /https?:\/\/[^\s<>"{}|\\^`\[\]]+/gi;
  const matches = text.match(urlRegex);
  if (!matches) return;

  for (const url of matches) {
    const provider = detectConferencingProvider(url);
    if (provider && !seenUrls.has(url)) {
      seenUrls.add(url);
      actions.push({
        type: ActionType.conferencing,
        url,
        provider,
      });
    }
  }
}

export default AppleCalendar;
