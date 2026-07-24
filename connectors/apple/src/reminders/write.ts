import type { Link, NewLinkWithNotes } from "@plotday/twister";
import type { CreateLinkDraft } from "@plotday/twister/connector";

import { PreconditionFailedError } from "../calendar/caldav";
import { parse } from "../product-channel";
import { remindersSource } from "./transform";
import type { RemindersHost } from "./sync";

function escapeICSText(text: string): string {
  return text
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n");
}

function toICSDateTimeUTC(date: Date): string {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

/**
 * Create a new iCloud reminder from a Plot thread. `draft.channelId` is the
 * NAMESPACED reminders-list channel id; de-namespaced here to the raw
 * collection href to build the new resource's URL (same convention as
 * reminders/sync.ts's `rawHref`).
 *
 * Returns `null` for any non-`reminder` draft so the combined connector can
 * route `onCreateLink` across mail/reminders by type without double-handling.
 */
export async function onCreateLinkFn(
  host: RemindersHost,
  draft: CreateLinkDraft
): Promise<NewLinkWithNotes | null> {
  if (draft.type !== "reminder") return null;

  const uid = crypto.randomUUID();
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Plot//Reminders//EN",
    "BEGIN:VTODO",
    `UID:${uid}`,
    `DTSTAMP:${toICSDateTimeUTC(new Date())}`,
    `SUMMARY:${escapeICSText(draft.title)}`,
    ...(draft.noteContent ? [`DESCRIPTION:${escapeICSText(draft.noteContent)}`] : []),
    `STATUS:${draft.status === "done" ? "COMPLETED" : "NEEDS-ACTION"}`,
    "END:VTODO",
    "END:VCALENDAR",
  ];
  const icsData = lines.join("\r\n");

  const rawListHref = parse(draft.channelId).rawId;
  const href = `${rawListHref}${uid}.ics`;
  const ok = await host.caldav.updateEventICS(href, icsData);
  if (!ok) return null;

  return {
    source: remindersSource(uid),
    type: "reminder",
    title: draft.title,
    status: draft.status ?? "open",
    channelId: draft.channelId,
    meta: {
      todoUid: uid,
      todoHref: href,
      listId: draft.channelId,
      syncProvider: "apple-reminders",
      channelId: draft.channelId,
    },
    ...(draft.status !== "done" ? { todo: true } : {}),
    // Binds the composed opening note to a key so the next sync-in
    // recognizes it as the SAME note (transformTodo emits `key: "description"`
    // whenever DESCRIPTION is non-empty) instead of appending a second,
    // duplicate description note. externalContent must equal exactly what
    // transformTodo will read back from DESCRIPTION — draft.noteContent
    // round-trips through escapeICSText/unescapeText unchanged.
    ...(draft.noteContent
      ? { originatingNote: { key: "description", externalContent: draft.noteContent } }
      : {}),
  };
}

/** Rewrite a VTODO's STATUS line (and COMPLETED timestamp) in raw ICS text. */
function setTodoStatus(icsData: string, done: boolean): string {
  const unfolded = icsData.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "");
  const lines = unfolded.split("\n");
  const withoutStatusOrCompleted = lines.filter(
    (line) => !/^STATUS[:;]/i.test(line) && !/^COMPLETED[:;]/i.test(line)
  );
  const endIdx = withoutStatusOrCompleted.findIndex((l) => l.trim() === "END:VTODO");
  const insertion = done
    ? [`STATUS:COMPLETED`, `COMPLETED:${toICSDateTimeUTC(new Date())}`]
    : [`STATUS:NEEDS-ACTION`];
  const insertAt = endIdx === -1 ? withoutStatusOrCompleted.length : endIdx;
  const result = [...withoutStatusOrCompleted];
  result.splice(insertAt, 0, ...insertion);
  return result.join("\r\n");
}

/**
 * Write back a Plot status change (done <-> reopen) to the reminder's VTODO
 * STATUS. No-ops for links this connector didn't create (no `todoUid`/
 * `listId` meta) or that were deleted upstream. On a concurrent-edit
 * conflict (`PreconditionFailedError`), re-fetches and retries once —
 * mirrors the pattern `caldav.ts` already documents for calendar event
 * writes.
 *
 * Targets `link.meta.todoHref` — the real CalDAV resource href persisted by
 * `transformTodo`/`onCreateLinkFn` — when present, falling back to the
 * `<uid>.ics` reconstruction only for links saved before this field existed.
 * The reconstruction is provably correct for a reminder created via Plot
 * (`onCreateLinkFn` PUTs to exactly that href) but is an unverified
 * assumption for anything synced in from Apple's own app, whose resource
 * paths are server-assigned and not guaranteed to follow that convention.
 *
 * `updateEventICS`'s boolean return is checked on BOTH the initial attempt
 * and the retry: it only THROWS for a 412 (handled below as the retry
 * trigger), but resolves to `false` for any other non-2xx response (a
 * transient 5xx, the item having been deleted between the read and the
 * write). Ignoring that `false` would silently drop the user's action —
 * the next regular sync unconditionally re-derives `status` from iCloud's
 * live VTODO (see `transformTodo`), so a swallowed failure gets invisibly
 * reverted with no error surfaced anywhere. Throwing here instead lets it
 * propagate like Google Tasks' equivalent write-back does (its REST client
 * throws on failure rather than returning a boolean) — the runtime's normal
 * unexpected-callback-error handling takes over from there.
 */
export async function onLinkUpdatedFn(host: RemindersHost, link: Link): Promise<void> {
  const uid = link.meta?.todoUid as string | undefined;
  const listId = link.meta?.listId as string | undefined;
  if (!uid || !listId) return;

  const rawListHref = parse(listId).rawId;
  const href = (link.meta?.todoHref as string | undefined) ?? `${rawListHref}${uid}.ics`;

  const current = await host.caldav.fetchEventICS(href);
  if (!current) return; // Deleted upstream — nothing to write back.

  const isDone = link.status === "done";
  let ok: boolean;

  try {
    ok = await host.caldav.updateEventICS(
      href,
      setTodoStatus(current.icsData, isDone),
      current.etag ?? undefined
    );
  } catch (error) {
    if (!(error instanceof PreconditionFailedError)) throw error;
    const fresh = await host.caldav.fetchEventICS(href);
    if (!fresh) return; // Deleted upstream between the conflict and the retry.
    ok = await host.caldav.updateEventICS(
      href,
      setTodoStatus(fresh.icsData, isDone),
      fresh.etag ?? undefined
    );
  }

  if (!ok) {
    throw new Error(`Failed to write back reminder status for ${href}`);
  }
}
