import { type Actor, type ActorId, ActorType } from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";

import type { Plot } from "./index";

function normalizeName(name: string | undefined | null): string | undefined {
  if (!name) return undefined;
  name = name.replace(/<?[^ ]+@[^ ]+>?/, "").trim();
  name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");
  return name;
}

export async function addContacts(
  plot: Plot,
  contacts: Array<{ email: string; name?: string; avatar?: string }>
): Promise<Actor[]> {
  // Validate contact write access permissions
  plot.requireContactAccess(ContactAccess.Write);

  if (contacts.length === 0) return [];

  const normalizedContacts = contacts.map((contact) => ({
    email: contact.email.toLowerCase(),
    name: normalizeName(contact.name),
    avatar: contact.avatar,
  }));

  const contactsToUpsert = normalizedContacts.map((contact) => ({
    email: contact.email,
    name: contact.name || null,
    avatar_url: contact.avatar || null,
  }));

  const result = await plot.supabase
    .from("contact")
    .upsert(contactsToUpsert, { onConflict: "email" })
    .select("id, email, name, user_id");

  if (result.error) {
    throw new Error(`Failed to upsert contacts: ${result.error.message}`);
  }

  // Map the upserted contacts to Actor type
  const actors: Actor[] = (result.data || []).map((contact) => {
    const actor: Actor = {
      id: contact.id as ActorId,
      type: contact.user_id ? ActorType.User : ActorType.Contact,
      name: contact.name || null,
    };
    // Email is always present for contacts (required field)
    if (contact.email) {
      actor.email = contact.email;
    }
    return actor;
  });

  return actors;
}

export async function getActors(
  plot: Plot,
  ids: ActorId[]
): Promise<Actor[]> {
  // Validate contact read access permissions
  plot.requireContactAccess(ContactAccess.Read);

  if (ids.length === 0) return [];

  // Query the actor view to get actors by IDs
  const result = await plot.supabase
    .from("actor")
    .select("id, email, name, type")
    .in("id", ids);

  if (result.error) {
    throw new Error(`Failed to fetch actors: ${result.error.message}`);
  }

  // Map the database results to Actor type
  const actors: Actor[] = (result.data || []).map((actor) => {
    const actorObj: Actor = {
      id: actor.id as ActorId,
      type:
        actor.type === "user"
          ? ActorType.User
          : actor.type === "priority_twist"
          ? ActorType.Twist
          : ActorType.Contact,
      name: actor.name || null,
    };
    // Only include email if it exists
    if (actor.email) {
      actorObj.email = actor.email;
    }
    return actorObj;
  });

  return actors;
}
