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
  sources?: SeedSource[];
  twists?: SeedTwist[];
  threads?: Thread[];
}

export interface Config {
  baseDate: string; // ISO date string (YYYY-MM-DD)
  email: string; // Email address (used as both email and password for local testing)
  userName: string; // Display name for the user
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
}

export interface PrioritySettings {
  color?: number; // Color index 0-7, or omit to inherit from parent priority
  pomodoro_duration?: number; // Minutes
}

// ============================================================================
// Sources (creates twist + twist_instance records for link logos)
// ============================================================================

export interface SeedSource {
  ref: string; // Unique reference for this source
  name: string; // Display name (e.g., "Slack")
  priority_ref: string; // Priority to attach the twist to
  logo?: string; // Logo URL for the source itself
  logo_dark?: string; // Dark mode logo URL
  link_types: SeedLinkType[];
}

export interface SeedLinkType {
  type: string; // e.g., "message", "email", "issue"
  label: string; // e.g., "Message", "Email", "Issue"
  logo: string; // Logo URL for this link type
  logo_dark?: string; // Dark mode logo URL
}

// ============================================================================
// Twists (non-source twists for AI chats, etc.)
// ============================================================================

export interface SeedTwist {
  ref: string; // Unique reference for this twist
  name: string; // Display name (e.g., "Claude")
  priority_ref: string; // Priority to attach the twist to
  logo?: string; // Logo URL
  logo_dark?: string; // Dark mode logo URL
}

// ============================================================================
// Threads (formerly Activities)
// ============================================================================

export interface Thread {
  ref?: string; // Optional unique reference
  title?: string;
  priority_ref: string; // Reference to a priority
  created?: string; // Date offset
  author_ref?: string; // Default: "user" — only used to resolve note author defaults
  draft?: boolean; // Default: false
  private?: boolean; // Default: false
  archived_at?: string; // Date offset
  icon?: string; // Thread icon: "notes", "idea", "goal", "decision", "discussion", "announcement", "ask"
  twist_ref?: string; // Reference to a twist (sets icon to twist logo)
  tags?: Tags;
  notes?: Note[]; // Notes associated with this thread
  schedule?: Schedule; // Schedule block (at/on/recurrence)
  links?: SeedLink[]; // External links
}

export interface Schedule {
  at?: string; // Timestamp range (e.g., "+0d 10:00 / +0d 11:00")
  on?: string; // Date range (e.g., "+3d / +5d")
  duration?: string; // e.g., "30 minutes", "2 hours"
  recurrence_rule?: string; // iCalendar RRULE
  todo?: boolean; // true = to-do (user schedule), false/unset with `at` = event (shared schedule)
}

export interface SeedLink {
  source_ref?: string; // Reference to a source (for logo resolution)
  type?: string; // e.g., "message", "email", "issue"
  status?: string; // e.g., "open", "closed"
  title?: string; // Display title
  source_url?: string; // External URL
  assignee_ref?: string; // Contact ref for assignee
  author_ref?: string; // Contact ref for author
  meta?: Record<string, unknown>; // Arbitrary metadata
}

export interface Note {
  ref?: string; // Optional unique reference
  author_ref?: string; // Default: "user"
  created: string; // Date offset (e.g., "-2d", "+1w 14:30") - REQUIRED
  content?: string; // Markdown content (preferred)
  note?: string; // Markdown content (alias for backward compatibility)
  mentions?: string[]; // Array of contact refs
  actions?: Array<Record<string, unknown>>; // Actions (file attachments, etc.)
  tags?: Tags;
  draft?: boolean; // Default: false
  private?: boolean; // Default: false
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

export interface GeneratedPriorityContact {
  priority_id: string; // UUID
  contact_id: string; // UUID
}

export interface GeneratedThread {
  id: string; // UUID
  created_by: string; // UUID
  priority_id: string; // UUID
  draft: boolean;
  private: boolean;
  title: string | null;
  preview: string | null;
  icon: string | null;
  archived_at: string | null; // ISO timestamp
}

export interface GeneratedLink {
  id: string; // UUID
  thread_id: string; // UUID
  priority_id: string; // UUID
  type: string | null;
  status: string | null;
  title: string | null;
  source_url: string | null;
  assignee_id: string | null; // UUID
  author_id: string | null; // UUID
  created_by: string | null; // UUID (twist_instance_id)
  source_created_at: string; // ISO timestamp
  meta: string | null; // JSONB
}

export interface GeneratedSchedule {
  id: string; // UUID
  thread_id: string | null; // UUID
  link_id: string | null; // UUID
  user_id: string | null; // UUID (for order)
  order: number | null;
  at: string | null; // tstzrange SQL format
  on: string | null; // daterange SQL format
  duration: string | null; // interval SQL format
  recurrence_rule: string | null;
}

export interface GeneratedTwistAdmin {
  id: string; // Will use DEFAULT (bigint identity) — placeholder for ref
  user_id: string; // UUID
}

export interface GeneratedTwist {
  twist_admin_ref: string; // Reference to resolve admin ID
  environment: string;
  name: string;
  version: string;
  is_source: boolean;
  permissions: string | null; // JSONB
  logo_url: string | null;
  logo_url_dark: string | null;
}

export interface GeneratedTwistInstance {
  priority_id: string; // UUID
  twist_ref: string; // Reference to resolve twist ID
  owner_id: string; // UUID
  name: string;
  config: string; // JSONB
}

export interface GeneratedThreadTag {
  actor_id: string; // UUID
  thread_id: string; // UUID
  tag_id: number;
  occurrence: string | null;
}

export interface GeneratedNote {
  id: string; // UUID
  thread_id: string; // UUID
  author_id: string; // UUID
  created_by: string; // UUID
  draft: boolean;
  private: boolean;
  content: string | null;
  actions: string | null; // JSON string for actions JSONB
  mentions: string | null; // Array literal
  source_created_at: string; // ISO timestamp
  updated_at: string; // ISO timestamp
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
  file?: string;
  line?: number;
}
