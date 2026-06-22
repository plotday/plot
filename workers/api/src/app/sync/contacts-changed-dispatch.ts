// Direct dispatch of the connector `onContactsChanged` callback when a user
// changes a thread's contact membership/roles. Mirrors the best-effort
// direct-dispatch pattern used for `onThreadToDo` in `schedules.ts`: the change
// is observed at the HTTP boundary (here, by snapshotting the thread before and
// after the mutation), and — only for connector-owned threads — dispatched to
// the owning connector in `waitUntil` with a fresh DB connection.
//
// Used by BOTH endpoints that can change a thread's effective membership:
//   - POST /sync/threads        (adds, non-message removes, role changes)
//   - POST /thread/:id/share    (explicit add/remove/role + message-mode drop/undrop)
// so a group-DM removal (a drop) is not missed.

import type { Context } from "hono";

import { createFrontendDb, type DB, type Kysely } from "../../db";
import type { Bindings } from "../../env";
import { twistFactory } from "../../twist/factory";
import { computeContactsDiff, type ContactsSnapshot } from "./contacts-diff";

export type ThreadContactsSnapshot = ContactsSnapshot & {
  /** thread.created_by — the user_id or twist_instance_id that created the thread. */
  createdBy: string;
};

/**
 * Read the contact-membership snapshot for a thread, or null if it doesn't
 * exist. Callers snapshot once before their mutation and pass the result to
 * {@link dispatchContactsChangedIfNeeded} after it.
 */
export async function snapshotThreadContacts(
  db: Kysely<DB>,
  threadId: string,
): Promise<ThreadContactsSnapshot | null> {
  const row = await db
    .selectFrom("thread")
    .select(["contacts", "dropped_contacts", "contact_meta", "created_by"])
    .where("id", "=", threadId)
    .executeTakeFirst();
  if (!row) return null;
  return {
    contacts: (row.contacts as string[] | null) ?? [],
    droppedContacts: (row.dropped_contacts as string[] | null) ?? [],
    contactMeta: ((row.contact_meta as Record<string, unknown> | null) ?? {}),
    createdBy: row.created_by as string,
  };
}

/**
 * Compute the membership/role diff against `prev` (a pre-mutation snapshot) and,
 * when the thread is owned by a connector and the diff is non-empty, dispatch
 * `onContactsChanged` to that connector. No-op when `prev` is null (e.g. a brand
 * new thread, whose initial contacts are conveyed via `onLinkCreated` instead).
 */
export async function dispatchContactsChangedIfNeeded(
  c: Context<{ Bindings: Bindings }>,
  threadId: string,
  prev: ThreadContactsSnapshot | null,
): Promise<void> {
  if (!prev) return;

  const next = await snapshotThreadContacts(c.var.db, threadId);
  if (!next) return;

  const diff = computeContactsDiff(prev, next);
  if (diff.added.length === 0 && diff.removed.length === 0 && diff.changed.length === 0) {
    return;
  }

  // Only connector-owned threads have a connector to notify. A connector
  // twist_instance has channel rows; a user-created thread does not.
  const createdBy = prev.createdBy;
  const isConnector = await c.var.db
    .selectFrom("channel")
    .select("twist_instance_id")
    .where("twist_instance_id", "=", createdBy)
    .limit(1)
    .executeTakeFirst();
  if (!isConnector) return;

  const item = {
    thread_id: threadId,
    added: diff.added,
    removed: diff.removed,
    changed: diff.changed,
  };
  const tracker = c.var.tracker;

  c.executionCtx.waitUntil(
    (async () => {
      const db = createFrontendDb(c.env);
      try {
        const factory = twistFactory({
          env: c.env,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ctx: c.executionCtx as any,
          db,
        });
        const twistWrapper = await factory({ twistInstanceId: createdBy });
        await twistWrapper.dispatch("Integrations", {
          itemType: "thread_contacts" as const,
          item,
        });
      } catch (error) {
        console.error("[contacts-changed] direct connector dispatch failed:", error);
        try {
          tracker?.captureException?.(error as Error);
        } catch {
          // never let error reporting throw into the background task
        }
      } finally {
        await db.destroy();
      }
    })(),
  );
}
