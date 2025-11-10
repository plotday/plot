import { z } from "zod";

// Define base schema for non-recursive fields
const BaseActivityItemSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
  author_id: z.string(),
  created_by: z.string(),
  assignee_id: z.string().nullable(),
  updated_by: z.number(),
  archived_at: z.string().nullable(),
  priority_id: z.string(),
  type: z.enum(["task", "event", "note"]),
  path: z.string(),
  order: z.number(),
  draft: z.boolean(),
  private: z.boolean(),
  title: z.string().nullable(),
  note: z.string().nullable(),
  links: z.array(z.record(z.string(), z.any())).nullable(),
  at: z.string().nullable(),
  on: z.string().nullable(),
  duration: z.string().nullable(),
  done_at: z.string().nullable(),
  recurrence_rule: z.string().nullable(),
  recurrence_exdates: z.array(z.string()).nullable(),
  recurrence_dates: z.array(z.string()).nullable(),
  meta: z.record(z.string(), z.any()).nullable(),
  mentions: z.array(z.string()).nullable(),
  // Enriched fields from database JOINs
  author_name: z.string().nullable(),
  author_type: z.enum(["user", "contact", "priority_twist"]),
  priority_title: z.string(),
  tags: z.record(z.string(), z.any()).nullable(),
});

// Activity item schema (with enriched fields and recursive thread_root)
export const ActivityItemSchema: z.ZodType<any> = BaseActivityItemSchema.extend({
  // Thread root (recursive, only present for nested activities)
  thread_root: z.lazy(() => ActivityItemSchema).optional(),
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

// Union schema for all item types - the type discrimination happens at the request level
export const ItemSchema = z.union([
  ActivityItemSchema,
  PriorityItemSchema,
  SessionItemSchema,
]);

// TypeScript types generated from zod schemas
export type ActivityItem = z.infer<typeof ActivityItemSchema>;
export type PriorityItem = z.infer<typeof PriorityItemSchema>;
export type SessionItem = z.infer<typeof SessionItemSchema>;
export type UpdateItem = z.infer<typeof ItemSchema>;
