/**
 * TypeScript types for Plot seed data YAML schema
 */

// ============================================================================
// Top-level structure
// ============================================================================

export interface SeedData {
  config: Config;
  contacts?: Contact[];
  priorities?: Priority[];
  activities?: Activity[];
}

export interface Config {
  baseDate: string; // ISO date string (YYYY-MM-DD)
  userId: string; // UUID of the user to generate data for
}

// ============================================================================
// Contacts
// ============================================================================

export interface Contact {
  ref: string; // Unique reference string
  email: string;
  name?: string;
  avatar_url?: string;
  user_id?: string; // UUID if this contact is also a Plot user
}

// ============================================================================
// Priorities
// ============================================================================

export interface Priority {
  ref: string; // Unique reference string
  title: string;
  root?: boolean; // Default: false
  archived_at?: string; // Date offset
  settings?: PrioritySettings;
  children?: Priority[]; // Nested child priorities
  shared_with?: string[]; // Array of user/contact refs
}

export interface PrioritySettings {
  color?: number; // Color index 0-7, or omit to inherit from parent priority
  path_override?: string;
  pomodoro_duration?: number; // Minutes
}

// ============================================================================
// Activities
// ============================================================================

export type ActivityType = "action" | "event" | "note";

export interface Activity {
  ref?: string; // Optional unique reference
  title?: string;
  type: ActivityType;
  priority_ref: string; // Reference to a priority
  author_ref?: string; // Default: "user"
  assignee_ref?: string;
  draft?: boolean; // Default: false
  private?: boolean; // Default: false
  archived_at?: string; // Date offset
  done_at?: string; // Date offset
  at?: string; // Timestamp range (e.g., "+0d 10:00 / +0d 11:00")
  on?: string; // Date range (e.g., "+3d / +5d")
  duration?: string; // e.g., "30 minutes", "2 hours"
  recurrence_rule?: string; // iCalendar RRULE
  tags?: Tags;
  notes?: Note[]; // Notes associated with this activity
}

export interface Note {
  ref?: string; // Optional unique reference
  author_ref?: string; // Default: "user"
  content?: string; // Markdown content (preferred)
  note?: string; // Markdown content (alias for backward compatibility)
  links?: Link[];
  mentions?: string[]; // Array of contact refs
  tags?: Tags;
  draft?: boolean; // Default: false
  private?: boolean; // Default: false
}

export interface Link {
  url: string;
  title?: string;
  description?: string;
}

export interface Tags {
  [tagName: string]: string[]; // Tag name -> array of actor refs
}

// ============================================================================
// Tag definitions (for validation)
// ============================================================================

export const COMPUTE_TAGS = ["now", "later", "done", "archived"] as const;

export const TOGGLE_TAGS = [
  "pinned",
  "urgent",
  "todo",
  "goal",
  "decision",
  "waiting",
  "blocked",
  "warning",
  "question",
  "star",
  "idea",
] as const;

export const COUNT_TAGS = ["yes", "no", "volunteer", "tada"] as const;

export const ALL_TAGS = [
  ...COMPUTE_TAGS,
  ...TOGGLE_TAGS,
  ...COUNT_TAGS,
] as const;

export type TagName = (typeof ALL_TAGS)[number];

// Map tag names to their numeric IDs (from Flutter app)
export const TAG_IDS: Record<string, number> = {
  // Compute (1-99)
  now: 1,
  later: 2,
  done: 3,
  archived: 4,

  // Toggle (100-999)
  pinned: 100,
  urgent: 101,
  todo: 102,
  goal: 103,
  decision: 104,
  waiting: 105,
  blocked: 106,
  warning: 107,
  question: 108,
  star: 110,
  idea: 111,

  // Count (1000+)
  yes: 1000,
  no: 1001,
  volunteer: 1002,
  tada: 1003,
};

// ============================================================================
// Generated SQL entities (internal types used during generation)
// ============================================================================

export interface GeneratedContact {
  id: string; // UUID
  email: string;
  name: string | null;
  avatar_url: string | null;
  user_id: string | null;
}

export interface GeneratedPriority {
  id: string; // UUID
  created_by: string; // UUID
  title: string;
  path: string; // ltree path
  root: boolean;
  archived_at: string | null; // ISO timestamp
}

export interface GeneratedPrioritySettings {
  priority_id: string; // UUID
  user_id: string; // UUID
  color: number | null;
  path: string | null;
  pomodoro: number | null;
}

export interface GeneratedPriorityUser {
  priority_id: string; // UUID
  user_id: string; // UUID
}

export interface GeneratedActivity {
  id: string; // UUID
  author_id: string; // UUID
  created_by: string; // UUID
  assignee_id: string | null; // UUID
  priority_id: string; // UUID
  type: ActivityType;
  order: number; // Timestamp in milliseconds
  draft: boolean;
  private: boolean;
  title: string | null;
  preview: string | null;
  at: string | null; // tstzrange SQL format
  on: string | null; // daterange SQL format
  duration: string | null; // interval SQL format
  done_at: string | null; // ISO timestamp
  recurrence_rule: string | null;
  archived_at: string | null; // ISO timestamp
}

export interface GeneratedActivityTag {
  actor_id: string; // UUID
  activity_id: string; // UUID
  tag_id: number;
  occurrence: string | null;
}

export interface GeneratedNote {
  id: string; // UUID
  activity_id: string; // UUID
  author_id: string; // UUID
  created_by: string; // UUID
  draft: boolean;
  private: boolean;
  content: string | null;
  links: string | null; // JSONB
  mentions: string | null; // Array literal
}

export interface GeneratedNoteTag {
  actor_id: string; // UUID
  note_id: string; // UUID
  tag_id: number;
}

// ============================================================================
// Utility types
// ============================================================================

export interface RefMap<T> {
  [ref: string]: T;
}

export interface ValidationError {
  path: string;
  message: string;
}
