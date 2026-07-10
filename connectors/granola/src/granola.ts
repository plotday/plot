import { ActionType } from "@plotday/twister";
import { Connector } from "@plotday/twister/connector";
import type { NewNote } from "@plotday/twister/plot";
import { Options } from "@plotday/twister/options";
import type { ToolBuilder } from "@plotday/twister/tool";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import {
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Store } from "@plotday/twister/tools/store";
import { Tasks } from "@plotday/twister/tools/tasks";

import { GranolaAPI, type GranolaNote } from "./granola-api";

type SyncState = {
  cursor: string | null;
  initialSync: boolean;
  syncHistoryMin?: string;
};

/**
 * Granola connector — syncs AI meeting notes from Granola and attaches them
 * to the matching calendar event thread (Google Calendar, Outlook, or Apple).
 *
 * Auth: API key (Bearer `grn_...`) supplied via Options. Granola's public API
 * does not currently expose third-party OAuth — only Personal/Enterprise API
 * keys (https://docs.granola.ai). WorkOS-based SSO in their docs covers
 * end-user login to the Granola app itself, not programmatic access.
 *
 * Cross-connector bundling: each Granola note attaches to the calendar
 * event's canonical thread (addressed by `note.thread.source =
 * icaluid:<calendar_event_id>`) and carries Granola's own link note-scoped
 * via `note.link`. The note-attached link's `sources` includes the canonical
 * `icaluid:<calendar_event_id>` alias plus Google/Outlook/Apple event-id
 * aliases, so a later calendar `createLink` co-locates onto this thread by
 * sources overlap and becomes the thread's primary canonical link. When no
 * calendar event matches, the note get its own thread keyed by the Granola
 * self source (ad-hoc meeting).
 */
export class Granola extends Connector<Granola> {
  readonly singleChannel = true;
  readonly access = [
    "Reads your meeting notes and transcripts to attach them to the right events in Plot",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        apiKey: {
          type: "text" as const,
          secure: true,
          label: "API key",
          description:
            "Connect Plot to your Granola account so meeting notes attach to the right calendar event.",
          default: "",
          placeholder: "grn_...",
          helpText:
            "In Granola (desktop app), open Settings → Connectors → API keys, click Create new key, then paste it here. On Enterprise workspaces, your admin may need to enable personal API keys first.",
          helpUrl: "https://docs.granola.ai/introduction",
        },
      }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      store: build(Store),
      network: build(Network, {
        urls: ["https://public-api.granola.ai/*"],
      }),
    };
  }

  private getAPI(): GranolaAPI {
    return new GranolaAPI(this.tools.options.apiKey as string);
  }

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    // Granola's list-notes response carries owner.email — fetch one note as a
    // cheap probe to recover the account label.
    try {
      const { data } = await this.getAPI().listNotes({ pageSize: 1 });
      return data[0]?.owner.email ?? null;
    } catch {
      return null;
    }
  }

  /**
   * Single channel for all Granola meeting notes.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    // Probe credentials.
    await this.getAPI().listNotes({ pageSize: 1 });
    return [
      {
        id: "meeting-notes",
        title: "Meeting Notes",
        linkTypes: [
          {
            type: "meeting",
            label: "Notes",
            sharingModel: "thread" as const,
            logo: "/assets/logo-granola.png",
          },
        ],
      },
    ];
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(
        `sync_history_min_${channel.id}`
      );
      if (
        storedMin &&
        new Date(storedMin) <= syncHistoryMin &&
        !context?.recovering
      ) {
        return;
      }
      await this.set(
        `sync_history_min_${channel.id}`,
        syncHistoryMin.toISOString()
      );
    }

    await this.set(`sync_enabled_${channel.id}`, true);
    await this.startBatchSync(channel.id, syncHistoryMin);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.tools.integrations.archiveNotes({ channelId: channel.id });
  }

  private async startBatchSync(
    channelId: string,
    syncHistoryMin?: Date
  ): Promise<void> {
    await this.set(`sync_state_${channelId}`, {
      cursor: null,
      initialSync: true,
      ...(syncHistoryMin
        ? { syncHistoryMin: syncHistoryMin.toISOString() }
        : {}),
    } satisfies SyncState);

    const cb = await this.callback(this.syncBatch, channelId, true);
    await this.tools.tasks.runTask(cb);
  }

  /**
   * Fetch a page of note ids, then for each one fetch full details and emit
   * a note (carrying Granola's link note-scoped) addressed to the calendar
   * event's thread. Pagination chains via tasks.runTask() to respect
   * Granola's 300 req/min rate limit and the worker's ~1000 req/exec budget.
   */
  async syncBatch(channelId: string, initialSync?: boolean): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${channelId}`);
    if (!state) return;
    const isInitial = initialSync ?? state.initialSync;

    const api = this.getAPI();
    const list = await api.listNotes({
      cursor: state.cursor,
      pageSize: 30,
      updatedAfter: state.syncHistoryMin ?? undefined,
    });

    const notes: NewNote[] = [];
    for (const summary of list.data) {
      try {
        const note = await api.getNote(summary.id);
        notes.push(this.transformNote(note, channelId, isInitial));
      } catch (err) {
        // Granola's get-note can fail if the note's AI summary is still
        // pending. Skip and pick it up on the next sync.
        console.error(
          `[Granola] failed to ingest note ${summary.id}:`,
          err
        );
      }
    }
    if (notes.length > 0) {
      await this.tools.integrations.saveNotes(notes);
    }

    if (list.hasMore && list.cursor) {
      await this.set(`sync_state_${channelId}`, {
        cursor: list.cursor,
        initialSync: isInitial,
        ...(state.syncHistoryMin
          ? { syncHistoryMin: state.syncHistoryMin }
          : {}),
      } satisfies SyncState);
      const cb = await this.callback(this.syncBatch, channelId, isInitial);
      await this.tools.tasks.runTask(cb);
    } else {
      // Sync complete — signal so the platform clears the "Syncing…"
      // indicator and the stuck-sync watchdog stops tracking this channel.
      // Gated on isInitial so incremental (webhook-driven) re-syncs, which
      // also flow through this same branch, don't fire it redundantly.
      if (isInitial) {
        await this.tools.integrations.channelSyncCompleted(channelId);
      }
      await this.clear(`sync_state_${channelId}`);
    }
  }

  /**
   * Map a Granola note → NewNote addressed to the calendar event's thread.
   *
   * Instead of creating a thread-level link owned by Granola, we emit a note
   * that attaches to the calendar event's canonical thread (when one exists),
   * carrying Granola's own link note-scoped via `note.link`. The note's
   * `link.sources` carries the connector-native id plus canonical calendar
   * aliases so a later calendar `createLink` co-locates onto this thread via
   * sources overlap. When no calendar event matches, the note gets its own
   * thread keyed by the Granola self source (ad-hoc meeting).
   */
  private transformNote(
    note: GranolaNote,
    channelId: string,
    initialSync: boolean
  ): NewNote {
    const sources: string[] = [`granola:note:${note.id}`];

    // Granola's calendar_event_id is the meeting's calendar identifier. We
    // don't know which calendar produced it (Google vs Outlook vs Apple),
    // so emit aliases for every plausible namespace. Only the matching
    // namespace will overlap with the calendar connector's `sources`.
    const calendarEventId = note.calendar_event?.calendar_event_id;
    if (calendarEventId) {
      sources.push(
        `icaluid:${calendarEventId}`,
        `google-event:${calendarEventId}`,
        `google-calendar:${calendarEventId}`,
        // Apple ICS UID — same UID format as iCalUID.
        `apple-calendar:${calendarEventId}`
      );
    }

    const rawContent = note.summary_markdown ?? note.summary_text ?? "";
    const { content, chatUrl } = stripChatTrailer(rawContent);

    // Prefer the explicit "Chat with meeting transcript" URL from the trailer
    // (it's the deep link Granola itself promotes); fall back to web_url.
    const granolaUrl = chatUrl ?? note.web_url;

    // Address the thread by the cross-connector calendar alias when we have one
    // (so we co-locate with the calendar event's thread); otherwise the Granola
    // note gets its own thread keyed by its self source (ad-hoc meeting).
    const threadSource = calendarEventId
      ? `icaluid:${calendarEventId}`
      : `granola:note:${note.id}`;

    return {
      thread: { source: threadSource },
      // Stable key so re-syncing the same note replaces in place rather than
      // appending a duplicate summary.
      key: "granola-summary",
      content,
      contentType: "markdown",
      created: new Date(note.updated_at),
      ...(initialSync ? { unread: false } : {}),
      link: {
        source: `granola:note:${note.id}`,
        sources,
        title:
          note.title ?? note.calendar_event?.event_title ?? "Meeting notes",
        type: "meeting",
        channelId,
        sourceUrl: granolaUrl,
        actions: [
          {
            type: ActionType.external,
            title: "Chat with meeting transcript",
            url: granolaUrl,
          },
        ],
        created: note.calendar_event?.scheduled_start_time
          ? new Date(note.calendar_event.scheduled_start_time)
          : new Date(note.created_at),
        meta: {
          syncProvider: "granola",
          channelId,
          noteId: note.id,
          ...(calendarEventId ? { calendarEventId } : {}),
        },
      },
    };
  }
}

/**
 * Strip Granola's auto-appended "Chat with meeting transcript: <url>" trailer
 * (preceded by a horizontal rule) from the summary markdown. The URL is
 * promoted to an action button on the link instead, so the note body ends on
 * the real summary content rather than a bare URL.
 */
function stripChatTrailer(markdown: string): {
  content: string;
  chatUrl: string | null;
} {
  const match = markdown.match(
    /\n+(?:---|\*\*\*|___)\s*\n+Chat with meeting transcript:\s*(\S+)\s*$/i
  );
  if (!match || match.index === undefined) {
    return { content: markdown, chatUrl: null };
  }
  return {
    content: markdown.slice(0, match.index).trimEnd(),
    chatUrl: match[1],
  };
}

export default Granola;
