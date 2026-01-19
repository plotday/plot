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
 * Activity from priority_twist_activity_create view.
 * Used for new activity notifications to twists.
 */
export type ActivityCreate = Database["public"]["Views"]["priority_twist_activity_create"]["Row"];

/**
 * Activity from priority_twist_activity_update view.
 * Used for activity update notifications to twists.
 */
export type ActivityUpdate = Database["public"]["Views"]["priority_twist_activity_update"]["Row"];

/**
 * Activity tag change from priority_twist_activity_tag_change view.
 * Used for tracking tag additions/removals on activities.
 */
export type ActivityTagChange = Database["public"]["Views"]["priority_twist_activity_tag_change"]["Row"];

/**
 * Union type for all note types used in twist sync.
 */
export type TwistNote = NoteCreate | NoteUpdate;

/**
 * Union type for all activity types used in twist sync.
 */
export type TwistActivity = ActivityCreate | ActivityUpdate;

/**
 * Generic enriched note type that represents any note from database views.
 * Can be used when the specific view doesn't matter (create vs update).
 */
export type EnrichedNote = NoteCreate | NoteUpdate;

/**
 * Generic enriched activity type that represents any activity from database views.
 */
export type EnrichedActivity = ActivityCreate | ActivityUpdate;
