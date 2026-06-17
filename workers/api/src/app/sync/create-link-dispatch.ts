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

/** The draft handed to the create_link dispatch (matches the connector side). */
export type CreateLinkDraftPayload = {
  channelId: string;
  type: string;
  status: string;
  title: string;
  noteContent: string | null;
  contacts: CreateLinkContact[];
  inviteEmails: string[];
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
