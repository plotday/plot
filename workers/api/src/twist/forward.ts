import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { getLinkTypesForLink } from "../app/sync/link-tags";

/** Markdown-blockquote every line (blank lines become a bare ">"). */
export function blockquote(markdown: string): string {
  if (markdown === "") return "";
  return markdown
    .split("\n")
    .map((line) => (line.length === 0 ? ">" : `> ${line}`))
    .join("\n");
}

export type ForwardSource = {
  key: string | null;
  sourceConnectionId: string | null;
  supportsForward: boolean;
  snapshot: {
    sourceTitle: string;
    sourceAuthorName: string;
    quotedContent: string;
    sourceThreadId: string;
  };
};

/**
 * Resolve everything the forward pipeline needs from the source note id:
 * its connector key, the connection (twist_instance) that owns its thread,
 * whether that connection's link type supports native forward, and a
 * snapshot of the original content (blockquoted) for the recipient view.
 * Returns null if the source note no longer exists, OR if `userId` cannot
 * see it.
 *
 * `fwdNoteId` is client-controlled (POST /sync/notes `fwd_note`, POST
 * /sync/threads `note_fwd_note`), so it must never be trusted to name a note
 * the caller actually has access to.
 *
 * `targetConnectionId` is the connection the forward is being composed
 * through. When provided and that connection has its own link on the source
 * thread, we resolve `key`/`sourceConnectionId`/`supportsForward` from THAT
 * link rather than the thread's earliest connector link. This is what lets a
 * native forward survive a reconnect: reconnecting an account archives the old
 * connection and mints a new one, so the source thread's earliest link belongs
 * to the now-archived connection (whose `twist_instance_id` no longer matches
 * the compose target, and whose stored channel snapshot may predate
 * `supportsForward`). Preferring the target connection's own link — which
 * proves that connection synced this thread — makes `decideForward`'s
 * same-connection check pass and reads the live channel config.
 */
export async function resolveForwardSource(
  db: Kysely<DB>,
  userId: string,
  fwdNoteId: string,
  targetConnectionId: string | null = null
): Promise<ForwardSource | null> {
  // AUTHORIZATION: only resolve a source note the requesting user can
  // actually see (thread- AND note-level visibility), via the canonical
  // user.note view. Fail closed — a note the user can't see (or that's
  // gone) yields null, so no content is ever disclosed or forwarded across
  // users.
  const visible = await db
    .selectFrom("user.note")
    .select(["id", "content", "thread_id", "author_id"])
    .where("id", "=", fwdNoteId)
    .where("user_id", "=", userId)
    .executeTakeFirst();
  if (!visible || !visible.thread_id) return null;

  // key isn't exposed by user.note; safe to read from the base row now that
  // access has been verified above.
  const keyRow = await db
    .selectFrom("note")
    .select(["key"])
    .where("id", "=", fwdNoteId)
    .executeTakeFirst();

  const thread = await db
    .selectFrom("thread")
    .select(["id", "title"])
    .where("id", "=", visible.thread_id)
    .executeTakeFirst();

  // Connector links on the source thread (created_by is the owning
  // twist_instance). Empty for a plain Plot thread.
  const links = await db
    .selectFrom("link")
    .select(["id", "created_by", "type"])
    .where("thread_id", "=", visible.thread_id)
    .where("created_by", "is not", null)
    .orderBy("created_at", "asc")
    .execute();

  // Prefer the link owned by the compose target connection (only that
  // connection can natively rebuild the item, and after a reconnect the
  // earliest link belongs to the archived old connection). Fall back to the
  // earliest connector link when the target has no link here (or wasn't given).
  const link =
    (targetConnectionId
      ? links.find((l) => l.created_by === targetConnectionId)
      : undefined) ?? links[0];

  // author_id is NOT NULL on the base note table; user.note types it nullable
  // only because it's a view. resolveActorName already returns "" for an
  // empty/unresolvable id, so this coalesce is a type-safe no-op.
  const authorName = await resolveActorName(db, visible.author_id ?? "");

  return {
    key: keyRow?.key ?? null,
    sourceConnectionId: link?.created_by ?? null,
    supportsForward: await linkTypeSupportsForward(db, link ?? null),
    snapshot: {
      sourceTitle: thread?.title ?? "",
      sourceAuthorName: authorName,
      quotedContent: blockquote(visible.content ?? ""),
      sourceThreadId: visible.thread_id,
    },
  };
}

async function resolveActorName(db: Kysely<DB>, actorId: string): Promise<string> {
  const contact = await db
    .selectFrom("contact")
    .select(["name"])
    .where("id", "=", actorId)
    .executeTakeFirst();
  return contact?.name ?? "";
}

/**
 * Read the connector's declared linkTypes for the source thread's primary
 * link and return whether its type declares `supportsForward`. Reuses
 * `getLinkTypesForLink` (workers/api/src/app/sync/link-tags.ts) — the same
 * channel-level-then-twist-level resolution that `propagateLinkStatusTagsFromDb`
 * and `isLinkStatusDone` already use to read other per-linkType flags (like
 * `statuses`/`sharingModel`) off a connector's declared `linkTypes` config —
 * so this stays in sync with however the runtime resolves that config.
 * `supportsForward` isn't in that module's local `LinkTypeConfig` projection
 * (it only declares the fields that module consumes), so the found entry is
 * cast to read the extra flag off the same underlying JSON. Returns false
 * when unknown (-> fallback forward).
 */
async function linkTypeSupportsForward(
  db: Kysely<DB>,
  link: { id: string; created_by: string | null; type: string | null } | null
): Promise<boolean> {
  if (!link?.created_by || !link.type) return false;
  const linkTypes = await getLinkTypesForLink(db, link.id, link.created_by);
  const typeConfig = linkTypes.find((lt) => lt.type === link.type);
  return (typeConfig as { supportsForward?: boolean } | undefined)?.supportsForward === true;
}

/**
 * Fallback forward body: the forwarder's own message, a separator, an
 * attribution line, then the blockquoted original. Used verbatim as the
 * outbound item's content on connectors without native forward, and as the
 * plain-Plot note content.
 *
 * `sourceAuthorName` is empty when the source note was twist-authored (the
 * actor resolver returns "" when `author_id` isn't a contact) — in that case
 * the "from {name}" clause is dropped rather than rendering "Forwarded from
 * — Title".
 */
export function buildFallbackContent(
  userMessage: string,
  snapshot: ForwardSource["snapshot"],
): string {
  const attribution =
    snapshot.sourceAuthorName.length > 0
      ? `Forwarded from ${snapshot.sourceAuthorName} — ${snapshot.sourceTitle}`
      : `Forwarded — ${snapshot.sourceTitle}`;
  const head = userMessage.length > 0 ? `${userMessage}\n\n` : "";
  return `${head}---\n\n${attribution}\n\n${snapshot.quotedContent}`;
}

/** ForwardUserAction JSON (matches the Flutter `ForwardUserAction.fromJson`). */
export function buildSnapshotAction(
  snapshot: ForwardSource["snapshot"],
): Record<string, unknown> {
  return {
    type: "forward",
    sourceTitle: snapshot.sourceTitle,
    sourceAuthorName: snapshot.sourceAuthorName,
    quotedContent: snapshot.quotedContent,
    sourceThreadId: snapshot.sourceThreadId,
  };
}
