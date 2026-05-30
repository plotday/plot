import type { Database, Json } from "@plotday/db";
import {
  type Thread,
  type ThreadType,
  type ThreadAccessLevel,
  type Link,
  type ThreadMeta,
  type Actor,
  type ActorId,
  ActorType,
  type Action,
  type Focus,
  type Tags,
  type Uuid,
} from "@plotday/twister/plot";
import type { Plot } from "./index";
import { resolveAccessContacts } from "./thread-helpers";

export async function fromDbThread(
  plot: Plot,
  dbThread: Database["public"]["Tables"]["thread"]["Row"] & {
    tags?: Json | null;
  }
): Promise<Thread> {
  return {
    // @ts-ignore - dbThread.id is a string from DB, but Uuid is a branded type
    id: dbThread.id as any,
    created: new Date(dbThread.created_at),
    title: dbThread.title || "",
    access: "members" as ThreadAccessLevel,
    accessContacts: await resolveAccessContacts(plot, dbThread.contacts),
    archived: dbThread.archived_at !== null,
    type: (dbThread.icon as ThreadType) ?? null,
    focus: {
      id: (dbThread as any).priority_id as Uuid ?? ("" as Uuid),
      title: dbThread.title ?? "Untitled",
      archived: false,
      key: null,
      color: null,
      icon: null,
    },
    tags: (dbThread.tags as Tags) || {},
    reactions: {},
  };
}

/** @deprecated Use fromDbThread */
export const fromDbActivity = fromDbThread;

/**
 * Maps a database actor type string to an ActorType enum value.
 */
function mapActorType(type: string | null): number {
  switch (type) {
    case "user":
      return ActorType.User;
    case "contact":
      return ActorType.Contact;
    case "twist_instance":
      return ActorType.Twist;
    default:
      return ActorType.User;
  }
}

/**
 * Converts a database link row (with joined author/assignee) to the SDK Link type.
 */
export function fromDbLink(
  dbLink: {
    id: string;
    thread_id: string;
    source: string | null;
    source_created_at: string | Date;
    created_at: string | Date;
    title: string | null;
    preview: string | null;
    type: string | null;
    status: string | null;
    actions: Json | null;
    meta: Json | null;
    source_url: string | null;
    channel_id?: string | null;
    author_id: string | null;
    assignee_id: string | null;
    sources?: string[] | null;
  } & {
    author?: {
      id: string | null;
      name: string | null;
      type: string | null;
    } | null;
    assignee?: {
      id: string | null;
      name: string | null;
      type: string | null;
    } | null;
  }
): Link {
  // Build author
  let author: Actor | null = null;
  if (dbLink.author && dbLink.author.id) {
    author = {
      id: dbLink.author.id as ActorId,
      name: dbLink.author.name || null,
      type: mapActorType(dbLink.author.type),
    };
  } else if (dbLink.author_id) {
    author = {
      id: dbLink.author_id as ActorId,
      name: null,
      type: ActorType.User,
    };
  }

  // Build assignee
  let assignee: Actor | null = null;
  if (dbLink.assignee && dbLink.assignee.id) {
    assignee = {
      id: dbLink.assignee.id as ActorId,
      name: dbLink.assignee.name || null,
      type: mapActorType(dbLink.assignee.type),
    };
  } else if (dbLink.assignee_id) {
    assignee = {
      id: dbLink.assignee_id as ActorId,
      name: null,
      type: ActorType.User,
    };
  }

  return {
    threadId: dbLink.thread_id as Uuid,
    source: dbLink.source,
    created: dbLink.source_created_at
      ? new Date(dbLink.source_created_at)
      : new Date(dbLink.created_at),
    author,
    title: dbLink.title || "",
    preview: dbLink.preview,
    assignee,
    type: dbLink.type,
    status: dbLink.status,
    actions: dbLink.actions as Action[] | null,
    meta: dbLink.meta as ThreadMeta | null,
    sourceUrl: dbLink.source_url,
    channelId: dbLink.channel_id ?? null,
    relatedSource: (dbLink as any).related_source ?? null,
    sources: dbLink.sources ?? [],
  };
}

export function fromDbPriority(
  dbPriority: {
    id: string;
    title: string;
    archived_at: Date | string | null;
    key: string | null;
    color: number | null;
    icon?: string | null;
  }
): Focus {
  return {
    id: dbPriority.id as Uuid,
    title: dbPriority.title,
    archived: dbPriority.archived_at !== null,
    key: dbPriority.key,
    color: dbPriority.color,
    icon: dbPriority.icon ?? null,
  };
}
