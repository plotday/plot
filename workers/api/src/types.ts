import { z } from "zod";

// Activity item schema
export const ActivityItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  author_id: z.string(),
  created_by: z.string(),
  assignee_id: z.string().nullable(),
  updated_by: z.number(),
  sync_depth: z.number().nullable(),
  archived_at: z.string().nullable(),
  priority_id: z.string(),
  type: z.enum(["action", "event", "note"]),
  order: z.number(),
  draft: z.boolean(),
  private: z.boolean(),
  title: z.string().nullable(),
  preview: z.string().nullable(),
  at: z.string().nullable(),
  on: z.string().nullable(),
  duration: z.string().nullable(),
  done_at: z.string().nullable(),
  recurrence_rule: z.string().nullable(),
  recurrence_exdates: z.array(z.string()).nullable(),
  recurrence_dates: z.array(z.string()).nullable(),
  source: z.string().nullable(),
  meta: z.record(z.string(), z.any()).nullable(),
  mentions: z.array(z.string()).nullable(),
  // Enriched fields from database JOINs
  author_name: z.string().nullable(),
  author_type: z.enum(["user", "contact", "priority_twist"]),
  priority_title: z.string(),
  tags: z.record(z.string(), z.any()).nullable(),
});

// Note item schema
export const NoteItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  author_id: z.string(),
  created_by: z.string(),
  updated_by: z.number(),
  sync_depth: z.number().nullable(),
  archived_at: z.string().nullable(),
  activity_id: z.string(),
  priority_id: z.string(),
  draft: z.boolean(),
  private: z.boolean(),
  content: z.string().nullable(),
  key: z.string().nullable(),
  links: z.array(z.record(z.string(), z.any())).nullable(),
  mentions: z.array(z.string()).nullable(),
  // Enriched fields from database JOINs
  author_name: z.string().nullable(),
  author_type: z.enum(["user", "contact", "priority_twist"]),
  activity_title: z.string().nullable(),
  tags: z.record(z.string(), z.any()).nullable(),
  // Parent activity metadata (only present in current item, not previous)
  activity_created_by: z.string().optional(),
  activity_meta: z.record(z.string(), z.any()).nullable().optional(),
  activity_mentions: z.array(z.string()).nullable().optional(),
});

// Priority item schema
export const PriorityItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  created_by: z.string(),
  root: z.boolean(),
  archived_at: z.string().nullable(),
  title: z.string(),
  path: z.string(),
  updated_by: z.number(),
  sync_depth: z.number().nullable(),
  key: z.string().nullable(),
});

// Session item schema
export const SessionItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  archived_at: z.string().nullable(),
  user_id: z.string(),
  priority_id: z.string().nullable(),
  at: z.string(),
  precedence: z.number(),
  pomodoro: z.number().nullable(),
  pomodoro_at: z.string().nullable(),
  updated_by: z.number(),
});

// Priority twist item schema
export const PriorityTwistItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  archived_at: z.string().nullable(),
  priority_id: z.string(),
  twist_id: z.number(), // Changed from UUID to bigint in migration 20251227165305
  twist_environment: z.string().optional(), // Not on priority_twist table, on twist table
  owner_id: z.string(),
  name: z.string(),
  config: z.record(z.string(), z.any()),
});

// Activity read item schema
export const ActivityReadItemSchema = z.object({
  user_id: z.string(),
  activity_id: z.string(),
  read_at: z.string(),
  updated_at: z.string(),
});

// Priority contact item schema (minimal - just used for actor view sync notifications)
export const PriorityContactItemSchema = z.object({
  priority_id: z.string(),
});

// Union schema for all item types - the type discrimination happens at the request level
export const ItemSchema = z.union([
  ActivityItemSchema,
  NoteItemSchema,
  PriorityItemSchema,
  SessionItemSchema,
  PriorityTwistItemSchema,
  ActivityReadItemSchema,
  PriorityContactItemSchema,
]);

// TypeScript types generated from zod schemas
export type ActivityItem = z.infer<typeof ActivityItemSchema>;
export type NoteItem = z.infer<typeof NoteItemSchema>;
export type PriorityItem = z.infer<typeof PriorityItemSchema>;
export type SessionItem = z.infer<typeof SessionItemSchema>;
export type PriorityTwistItem = z.infer<typeof PriorityTwistItemSchema>;
export type ActivityReadItem = z.infer<typeof ActivityReadItemSchema>;
export type PriorityContactItem = z.infer<typeof PriorityContactItemSchema>;
export type UpdateItem = z.infer<typeof ItemSchema>;
