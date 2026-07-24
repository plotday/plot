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
      listId: draft.channelId,
      syncProvider: "apple-reminders",
      channelId: draft.channelId,
    },
    ...(draft.status !== "done" ? { todo: true } : {}),
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
 */
export async function onLinkUpdatedFn(host: RemindersHost, link: Link): Promise<void> {
  const uid = link.meta?.todoUid as string | undefined;
  const listId = link.meta?.listId as string | undefined;
  if (!uid || !listId) return;

  const rawListHref = parse(listId).rawId;
  const href = `${rawListHref}${uid}.ics`;

  const current = await host.caldav.fetchEventICS(href);
  if (!current) return; // Deleted upstream — nothing to write back.

  const isDone = link.status === "done";

  try {
    await host.caldav.updateEventICS(
      href,
      setTodoStatus(current.icsData, isDone),
      current.etag ?? undefined
    );
  } catch (error) {
    if (error instanceof PreconditionFailedError) {
      const fresh = await host.caldav.fetchEventICS(href);
      if (!fresh) return;
      await host.caldav.updateEventICS(
        href,
        setTodoStatus(fresh.icsData, isDone),
        fresh.etag ?? undefined
      );
      return;
    }
    throw error;
  }
}
