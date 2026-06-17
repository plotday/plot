/**
 * TypeScript types for Plot seed data YAML schema
 */

// ============================================================================
// Top-level structure
// ============================================================================

export interface SeedData {
  config: Config;
  contacts?: Contact[];
  roles?: Role[];
  priorities?: Priority[];
  sources?: SeedSource[];
  twists?: SeedTwist[];
  threads?: Thread[];
  priority_blocks?: SeedPriorityBlock[];
  groups?: SeedGroup[];
}

/**
 * Seed entry for `public.priority_block` — a temporal override of a
 * priority's sort order. Each row says "from effective_at onwards, this
 * priority sorts at order_value". The agenda uses these rows when ranking
 * priorities within a gap that contains multiple priorities, so the
 * relative order matches what Margot would have arranged when filling
 * the gap. Without any rows the agenda falls back to the priority's
 * intrinsic order.
 */
export interface SeedPriorityBlock {
  priority_ref: string;
  effective_at: string; // Date offset (e.g., "+0d 10:30")
  order_value: number; // Lower sorts earlier within the gap
  duration?: string; // Postgres interval string (e.g., "1 hour", "30 minutes")
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
// Roles (group focuses; provide colour + notification template)
// ============================================================================

export interface Role {
  ref: string; // Unique reference string; priorities point at it via role_ref
  name: string;
  color?: number; // Theme colour index 0-7 (default 0). The role's Inbox + FYI
  // follow this colour.
}

// ============================================================================
// Priorities
// ============================================================================

export interface Priority {
  ref: string; // Unique reference string
  title: string;
  icon?: string; // Curated kFocusIcons key (e.g. "rocket"). Written to priority.icon.
  root?: boolean; // Default: false
  // Role this focus belongs to (must reference a `roles[].ref`). Required for
  // every seeded focus so the priority_role_or_fyi CHECK is satisfied and the
  // sidebar groups it under the right role.
  role_ref?: string;
  // Marks this focus as its role's Inbox (is_inbox = TRUE). Exactly one inbox
  // per role. The Inbox's colour follows the role; its icon/name are fixed by
  // the app, so omit `icon`/`settings.color` here.
  inbox?: boolean;
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
  channels?: SeedChannel[]; // Enabled connection channels (e.g. Slack channels)
}

export interface SeedLinkType {
  type: string; // e.g., "message", "email", "issue"
  label: string; // e.g., "Message", "Email", "Issue"
  logo: string; // Logo URL for this link type
  logo_dark?: string; // Dark mode logo URL
  // Marks this link type as producing time-anchored calendar events. Drives
  // whether the app shows the agenda (TwistInstance.watchHasCalendarConnection
  // → LinkTypeConfig.includesSchedules). Set on calendar sources so the agenda
  // works even when the real connector hasn't been deployed (the seed's
  // personal-fallback twist carries the flag).
  includes_schedules?: boolean;
}

export interface SeedChannel {
  channel_id: string; // Provider channel id (e.g. "C04general")
  title: string; // Display title (e.g. "#general")
  enabled?: boolean; // default true
  link_types?: unknown; // Optional override; defaults to a Slack-style compose link type
}

// ============================================================================
// Groups (reusable contact sets for the new-thread picker)
// ============================================================================

export interface SeedGroup {
  ref: string;
  name: string;
  privacy?: "open" | "private"; // default "open"
  members: string[]; // contact refs (the user is admin automatically)
  admins?: string[]; // extra user refs to make admins (rarely needed)
}

export interface GeneratedGroup {
  id: string; // UUID
  name: string;
  privacy: string;
  created_by: string; // UUID (seed user)
}

export interface GeneratedGroupMember {
  group_id: string;
  contact_id: string;
}

export interface GeneratedGroupAdmin {
  group_id: string;
  user_id: string;
}

export interface GeneratedChannel {
  twist_instance_id: string;
  channel_id: string;
  title: string;
  enabled: boolean;
  link_types: string; // JSON string
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
  archived_at?: string; // Date offset
  // Unified-feed section this thread lands in. Drives an emitted thread_state
  // row: active/scheduled → active=true (read); unread → active=true (unread);
  // omitted/done → no thread_state row (thread reads as Done).
  state?: "active" | "scheduled" | "unread" | "done";
  // Per-user "do on this date" to-do intent (thread_state.on), date-only (no
  // time). Use for prep to-dos dated before an event. Implies an active state.
  do_on?: string;
  icon?: string; // Thread icon: "notes", "idea", "goal", "decision", "discussion", "announcement", "ask"
  twist_ref?: string; // Reference to a twist (sets icon to twist logo)
  shared_with?: string[]; // Contact refs the thread is shared with (in addition to refs auto-derived from author_ref / note authors / mentions)
  tags?: Tags;
  notes?: Note[]; // Notes associated with this thread
  schedule?: Schedule; // Schedule block (at/on/recurrence)
  links?: SeedLink[]; // External links
  associated_with?: string; // ref of a parent thread (typically an event) — emits a thread_association row so this thread renders nested under the parent in the agenda
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
  author_ref?: string; // Default: "user". Contact ref, "user", or a twist ref (e.g. the Plot AI twist authoring a reply — its note is also created_by that twist instance)
  created: string; // Date offset (e.g., "-2d", "+1w 14:30") - REQUIRED
  // Markdown content. At-mentions use `[Display](#@<ref>)` markup where <ref>
  // is a contact or twist ref; the generator rewrites it to the resolved actor
  // UUID and adds that id to `mentions` (matching the real editor's storage
  // format and the app's mention auto-extraction).
  content?: string; // Markdown content (preferred)
  note?: string; // Markdown content (alias for backward compatibility)
  mentions?: string[]; // Extra contact/twist refs to mention (merged with refs parsed from content markup)
  actions?: Array<Record<string, unknown>>; // Actions (file attachments, etc.)
  tags?: Tags;
  draft?: boolean; // Default: false
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

// Curated focus-icon keys. Mirrors kFocusIcons in
// apps/plot/lib/widget/icon.dart. Used for a soft (warn-only) validation so
// the seed never hard-fails when the app's icon set drifts.
export const FOCUS_ICONS = [
  "user", "family", "briefcase", "house", "code", "receipt", "bullhorn",
  "handshake", "rocket", "building", "lightbulb", "heart", "flask",
  "paintbrush", "dumbbell", "seedling", "balloons", "music", "plane",
  "mountain", "globe", "billboard",
] as const;

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

export interface GeneratedRole {
  id: string; // UUID (deterministic via stableUUID)
  user_id: string; // UUID
  name: string;
  color: number;
  order: number; // Sidebar order (lower sorts higher)
}

export interface GeneratedPriority {
  id: string; // UUID
  created_by: string; // UUID
  title: string;
  icon: string | null;
  path: string; // ltree path
  archived_at: string | null; // ISO timestamp
  role_id: string; // UUID — the role this focus groups under
  is_inbox: boolean; // role's Inbox focus
  color: number | null; // priority.color column; set for inboxes (= role colour),
  // null for ordinary focuses (which carry colour via priority_setting)
}

export interface GeneratedPrioritySettings {
  priority_id: string; // UUID
  user_id: string; // UUID
  color: number | null;
  pomodoro: number | null;
  order: number | null; // sidebar order (key 'order'); set for ordinary focuses
  // so they sort in YAML order. Inboxes/FYIs get sentinel orders elsewhere.
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
  priority_id: string; // UUID — used to populate the user's thread_priority filing (not a column on thread)
  draft: boolean;
  title: string | null;
  preview: string | null;
  icon: string | null;
  archived_at: string | null; // ISO timestamp
  contacts: string[]; // Contact UUIDs visible on this thread (always includes the seed user's primary contact)
}

export interface GeneratedThreadPriority {
  thread_id: string; // UUID
  user_id: string; // UUID
  priority_id: string; // UUID
}

export interface GeneratedThreadState {
  user_id: string; // UUID
  thread_id: string; // UUID
  active: boolean;
  read_at: string | null; // ISO timestamp; NULL = unread
  bumped_at: string | null; // ISO timestamp (feed ordering for Doing/Done)
  importance: number;
  on: string | null; // daterange literal for a per-user "do on" date, or null
}

export interface GeneratedUserContact {
  user_id: string; // UUID
  contact_id: string; // UUID
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

export interface GeneratedThreadAssociation {
  id: string; // UUID
  parent_thread_id: string; // UUID
  child_thread_id: string; // UUID
  order: number;
}

export interface GeneratedPriorityBlock {
  id: string; // UUID
  user_id: string; // UUID
  priority_id: string; // UUID
  order_value: number;
  effective_at: string; // ISO timestamp
  duration: string | null; // interval SQL format
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
