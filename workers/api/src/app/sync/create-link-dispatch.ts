import type { Kysely } from "../../db";
import type { DB } from "../../db-types";
import type { Bindings } from "../../env";
import { twistFactory } from "../../twist/factory";
import { expandGroupsToContactIds } from "./threads";

/** A resolved recipient contact passed to a connector's onCreateLink draft. */
export type CreateLinkContact = {
  id: string;
  type: "contact" | "user";
  email: string | null;
  name: string | null;
};

/** A file attachment carried into a connector's onCreateLink draft (matches
 * the Twister SDK's `CreateLinkDraft.attachments` shape, connector.ts:201). */
export type CreateLinkAttachment = {
  fileId: string;
  fileName: string;
  mimeType: string;
  fileSize: number | null;
};

/**
 * Filter a note's `actions` (jsonb, either the raw client-sent `note_actions`
 * control field or a persisted `note.actions` column) down to file actions
 * and map them to the draft's attachment shape. Defensive/best-effort: any
 * non-array input or entry missing the required fields is dropped rather
 * than throwing, so this is a no-op until callers actually send/store file
 * actions on the composed thread's first note.
 */
export function noteActionsToAttachments(rawActions: unknown): CreateLinkAttachment[] {
  const actions = Array.isArray(rawActions) ? (rawActions as any[]) : [];
  return actions
    .filter((a) => a && a.type === "file" && typeof a.fileId === "string")
    .map((a) => ({
      fileId: a.fileId as string,
      fileName: typeof a.fileName === "string" ? a.fileName : "attachment",
      mimeType: typeof a.mimeType === "string" ? a.mimeType : "application/octet-stream",
      fileSize: typeof a.fileSize === "number" ? a.fileSize : null,
    }));
}

/** The persisted create_link spec (thread.pending_create_link) needed to
 * re-dispatch a compose on retry. Recipients are re-resolved from the thread's
 * contacts; only the parts not derivable from the thread are stored. */
export type PendingCreateLink = {
  twist_instance_id: string;
  channel_id: string | null;
  type: string;
  status: string | null;
  invite_emails: string[];
};

/**
 * Parse a persisted `thread.pending_create_link` value (jsonb or its string
 * form) into a typed spec. Returns null for anything malformed. Shared by the
 * retry path (sync/note-retry-send) and the scheduled-send release sweep.
 */
export function parsePendingCreateLink(value: unknown): PendingCreateLink | null {
  if (value == null) return null;
  const parsed: unknown =
    typeof value === "string" ? safeJsonParse(value) : value;
  if (!parsed || typeof parsed !== "object") return null;
  const p = parsed as Record<string, unknown>;
  if (typeof p.twist_instance_id !== "string" || typeof p.type !== "string") {
    return null;
  }
  return {
    twist_instance_id: p.twist_instance_id,
    channel_id: typeof p.channel_id === "string" ? p.channel_id : null,
    type: p.type,
    status: typeof p.status === "string" ? p.status : null,
    invite_emails: Array.isArray(p.invite_emails)
      ? p.invite_emails.filter((e): e is string => typeof e === "string")
      : [],
  };
}

function safeJsonParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

/** The draft handed to the create_link dispatch (matches the connector side). */
export type CreateLinkDraftPayload = {
  channelId: string;
  type: string;
  // null for status-less link types (e.g. Gmail email) — matches the
  // connector-side CreateLinkDraft.status, which onCreateLink handles.
  status: string | null;
  title: string;
  noteContent: string | null;
  contacts: CreateLinkContact[];
  inviteEmails: string[];
  attachments: CreateLinkAttachment[];
};

/**
 * Resolve a thread's contact + group ids into the contact rows a connector's
 * onCreateLink draft expects, excluding every contact linked to the acting
 * user (so the author isn't passed as a recipient). Shared by the initial
 * compose dispatch (sync/threads) and the retry path (sync/note-retry-send).
 */
export async function resolveCreateLinkContacts(
  db: Kysely<DB>,
  userId: string,
  contactIds: string[],
  groupIds: string[],
  onError: (error: unknown) => void,
): Promise<CreateLinkContact[]> {
  const contacts: CreateLinkContact[] = [];
  const resolveContactIds = await expandGroupsToContactIds(
    db,
    userId,
    contactIds,
    groupIds,
    onError,
  );
  if (resolveContactIds.length === 0) return contacts;

  const rows = await db
    .selectFrom("contact as c")
    .leftJoin("user_contact as uc", (join) =>
      join
        .onRef("uc.contact_id", "=", "c.id")
        .on("uc.user_id", "=", userId)
        .on("uc.linked", "=", true)
        .on("uc.archived_at", "is", null),
    )
    .select(["c.id", "c.email", "c.name", "uc.user_id as linked_user_id"])
    .where("c.id", "in", resolveContactIds)
    .execute();
  for (const row of rows) {
    if (row.linked_user_id) continue;
    contacts.push({
      id: row.id,
      type: "contact",
      email: row.email ?? null,
      name: row.name ?? null,
    });
  }
  return contacts;
}

/**
 * Dispatch a create_link to a connector's onCreateLink via the twist runtime.
 * The runtime resolves draft.recipients from draft.contacts and forwards the
 * returned link to saveCreatedLink (which binds it to the thread).
 */
export async function dispatchCreateLink(
  env: Bindings,
  ctx: ExecutionContext,
  db: Kysely<DB>,
  args: {
    threadId: string;
    twistInstanceId: string;
    draft: CreateLinkDraftPayload;
  },
): Promise<void> {
  const factory = twistFactory({ env, ctx: ctx as any, db });
  const wrapper = await factory({ twistInstanceId: args.twistInstanceId });
  await wrapper.dispatch("Integrations", {
    itemType: "create_link",
    threadId: args.threadId,
    draft: args.draft,
  });
}
