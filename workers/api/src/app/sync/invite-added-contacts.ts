// Send Plot invitation emails to non-Plot contacts that a user newly added to a
// thread via POST /sync/threads.
//
// Background: the typed-email path (`invite_emails`) already invites people via
// upsert_contacts -> share_thread -> sendInvitation. But selecting an existing
// contact in the share/compose picker writes a contact UUID into thread.contacts
// (handled by upsert_thread), which never computed a "needs invitation" set — so
// a non-Plot person you picked from your contacts was silently never invited,
// on a new thread or an existing-thread share. This closes that gap by diffing
// the thread's membership around the upsert and inviting the newly-added members
// that don't yet have a Plot account.
//
// The membership diff (see newlyAddedMemberIds) is what keeps routine saves from
// re-inviting: only contacts that became members in THIS save are considered, so
// title edits / priority moves / re-syncs of an unchanged roster invite nobody.
// Per-contact dedup + the 24h cooldown in sendInvitation bound the blast radius.

import { type DB, type Kysely } from "../../db";
import type { MailRequest } from "../../env";
import { sendInvitation } from "../invitation";
import { newlyAddedMemberIds } from "./contacts-diff";
import {
  snapshotThreadContacts,
  type ThreadContactsSnapshot,
} from "./contacts-changed-dispatch";

/**
 * Invite the non-Plot contacts a user newly added to a thread. Best-effort:
 * never throws — every failure is logged/captured and the loop continues.
 */
export async function inviteNewlyAddedContacts(
  db: Kysely<DB>,
  params: {
    threadId: string;
    prevContacts: ThreadContactsSnapshot | null;
    inviterUserId: string;
    mailQueue: Queue<MailRequest>;
    appRoot: string;
    captureException?: (error: Error, context?: Record<string, unknown>) => void;
  },
): Promise<void> {
  const { threadId, prevContacts, inviterUserId, mailQueue, appRoot } = params;

  // Snapshot the post-upsert membership and diff against the pre-upsert
  // snapshot. Runs before the invite_emails block adds its own contacts, so the
  // two paths never overlap.
  const next = await snapshotThreadContacts(db, threadId);
  if (!next) return;

  const candidateIds = newlyAddedMemberIds(prevContacts, next);
  if (candidateIds.length === 0) return;

  // Narrow to contacts that actually warrant an invitation: not already a Plot
  // account (no linked user_contact), inviteable (filters no-reply/bot/system
  // addresses), with an email, and not archived. Mirrors share_thread's
  // needs_invitation detection plus the inviteable/email guards.
  const needInvitation = await db
    .selectFrom("contact")
    .select("id")
    .where("id", "in", candidateIds)
    .where("archived_at", "is", null)
    .where("inviteable", "=", true)
    .where("email", "is not", null)
    .where((eb) =>
      eb.not(
        eb.exists(
          eb
            .selectFrom("user_contact")
            .select("user_contact.contact_id")
            .whereRef("user_contact.contact_id", "=", "contact.id")
            .where("user_contact.linked", "=", true)
            .where("user_contact.archived_at", "is", null),
        ),
      ),
    )
    .execute();

  for (const { id: contactId } of needInvitation) {
    try {
      await sendInvitation(db, {
        contactId,
        threadId,
        inviterUserId,
        mailQueue,
        appRoot,
      });
    } catch (error) {
      console.error(
        "[sync/threads] Invitation for added contact failed:",
        error,
      );
      params.captureException?.(error as Error, {
        contact_id: contactId,
        thread_id: threadId,
        error_context: "sync_thread_added_contact_invitation_failed",
      });
    }
  }
}
