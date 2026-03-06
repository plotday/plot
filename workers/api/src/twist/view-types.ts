/**
 * TypeScript types generated from database views used for twist sync.
 * These types represent enriched entities with JOINed fields from related tables.
 *
 * Source: libs/db/src/types.ts (generated from Supabase views)
 */

import type { Database } from "@plotday/db";

/**
 * Note from priority_twist_note_create view.
 * Used for new note notifications to twists.
 */
export type NoteCreate = Database["public"]["Views"]["priority_twist_note_create"]["Row"];

/**
 * Note from priority_twist_note_update view.
 * Used for note update notifications to twists.
 */
export type NoteUpdate = Database["public"]["Views"]["priority_twist_note_update"]["Row"];

/**
 * Thread from priority_twist_thread_update view.
 * Used for thread update notifications to twists.
 */
export type ThreadUpdate = Database["public"]["Views"]["priority_twist_thread_update"]["Row"];

/**
 * Thread tag change from priority_twist_thread_tag_change view.
 * Used for tracking tag additions/removals on threads.
 */
export type ThreadTagChange = Database["public"]["Views"]["priority_twist_thread_tag_change"]["Row"];

/** @deprecated Use ThreadUpdate */
export type ActivityCreate = ThreadUpdate;
/** @deprecated Use ThreadUpdate */
export type ActivityUpdate = ThreadUpdate;
/** @deprecated Use ThreadTagChange */
export type ActivityTagChange = ThreadTagChange;

/**
 * Union type for all note types used in twist sync.
 */
export type TwistNote = NoteCreate | NoteUpdate;

/**
 * Union type for all thread types used in twist sync.
 */
export type TwistThread = ThreadUpdate;

/** @deprecated Use TwistThread */
export type TwistActivity = TwistThread;

/**
 * Generic enriched note type that represents any note from database views.
 * Can be used when the specific view doesn't matter (create vs update).
 */
export type EnrichedNote = NoteCreate | NoteUpdate;

/**
 * Generic enriched thread type that represents any thread from database views.
 */
export type EnrichedThread = ThreadUpdate;

/** @deprecated Use EnrichedThread */
export type EnrichedActivity = EnrichedThread;

/**
 * Link from priority_twist_channel_link_create view.
 * Used for new link notifications from connected source channels.
 */
export type ChannelLinkCreate = Database["public"]["Views"]["priority_twist_channel_link_create"]["Row"];

/**
 * Link from priority_twist_channel_link_update view.
 * Used for updated link notifications from connected source channels.
 */
export type ChannelLinkUpdate = Database["public"]["Views"]["priority_twist_channel_link_update"]["Row"];

/**
 * Note from priority_twist_channel_note_create view.
 * Used for new note notifications on threads with links from connected channels.
 */
export type ChannelNoteCreate = Database["public"]["Views"]["priority_twist_channel_note_create"]["Row"];

/**
 * Thread read status change from priority_twist_thread_read view.
 * Used for dispatching onThreadRead callbacks to sources.
 */
export type ThreadReadChange = Database["public"]["Views"]["priority_twist_thread_read"]["Row"];

/**
 * Thread schedule change from priority_twist_thread_schedule view.
 * Used for dispatching onThreadToDo callbacks to sources.
 */
export type ThreadScheduleChange = Database["public"]["Views"]["priority_twist_thread_schedule"]["Row"];

/**
 * Schedule contact change from priority_twist_schedule_contact view.
 * Used for dispatching onScheduleContactUpdated callbacks to sources.
 */
export type ScheduleContactChange = Database["public"]["Views"]["priority_twist_schedule_contact"]["Row"];
