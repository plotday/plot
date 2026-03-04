import type { NewScheduleContact } from "@plotday/twister/schedule";

import { rpcUser } from "../../../rpc";
import { processNewActorArray } from "./thread-helpers";
import type { Plot } from "./index";

/**
 * Process schedule contacts: resolve NewActors to contact IDs and
 * call upsert_schedule_contacts to persist them.
 *
 * @param plot - The Plot instance (provides db, user context, priority)
 * @param scheduleId - The schedule to attach contacts to
 * @param contacts - Array of NewScheduleContact with NewActor references
 * @param priorityId - The priority ID for contact resolution
 */
export async function processScheduleContacts(
  plot: Plot,
  scheduleId: string,
  contacts: NewScheduleContact[],
  priorityId: string
): Promise<void> {
  if (contacts.length === 0) return;

  // Resolve all NewActors to contact IDs in a single batch
  const newActors = contacts.map((sc) => sc.contact);
  const contactIds = await processNewActorArray(plot, newActors, priorityId);

  // Build the JSONB array for the database function
  const dbContacts = contacts.map((sc, i) => ({
    contact_id: contactIds[i],
    ...(sc.status !== undefined ? { status: sc.status } : {}),
    ...(sc.role !== undefined ? { role: sc.role } : {}),
    archived: sc.archived ?? false,
  }));

  const userId = await plot.getUserId();
  await rpcUser(plot.db, "upsert_schedule_contacts", {
    user_id: userId,
    p_schedule_id: scheduleId,
    p_contacts: dbContacts,
  });
}
