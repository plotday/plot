#!/usr/bin/env node

/**
 * Plot Seed Data Generator
 *
 * Generates SQL INSERT statements from YAML seed data definition.
 * See YAML_SPEC.md for format documentation.
 */

import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { parse as parseYAML } from "yaml";
import type {
  SeedData,
  Contact,
  Priority,
  Activity,
  Note,
  GeneratedContact,
  GeneratedPriority,
  GeneratedPrioritySettings,
  GeneratedPriorityUser,
  GeneratedActivity,
  GeneratedActivityTag,
  GeneratedNote,
  GeneratedNoteTag,
  RefMap,
  ValidationError,
} from "./types.js";
import { TAG_IDS, ALL_TAGS } from "./types.js";

// ============================================================================
// Main entry point
// ============================================================================

async function main() {
  const { values, positionals } = parseArgs({
    options: {
      help: { type: "boolean", short: "h" },
    },
    allowPositionals: true,
  });

  if (values.help || positionals.length === 0) {
    console.error(`Usage: generate-seed.ts <yaml-file>

Generates SQL INSERT statements from YAML seed data definition.

Options:
  -h, --help    Show this help message

Examples:
  pnpm gen-seed seeds/screenshot-data.yaml > seed.sql
  pnpm gen-seed my-data.yaml | psql -d plot_local
`);
    process.exit(values.help ? 0 : 1);
  }

  const yamlFile = positionals[0];

  try {
    const yamlContent = await readFile(yamlFile, "utf-8");
    const data = parseYAML(yamlContent) as SeedData;

    const errors = validate(data);
    if (errors.length > 0) {
      console.error("Validation errors:");
      for (const error of errors) {
        console.error(`  ${error.path}: ${error.message}`);
      }
      process.exit(1);
    }

    const sql = generateSQL(data);
    console.log(sql);
  } catch (error) {
    console.error("Error:", error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

// ============================================================================
// Validation
// ============================================================================

function validate(data: SeedData): ValidationError[] {
  const errors: ValidationError[] = [];

  // Validate config
  if (!data.config) {
    errors.push({ path: "config", message: "Missing config section" });
    return errors;
  }

  if (!data.config.baseDate) {
    errors.push({ path: "config.baseDate", message: "Missing baseDate" });
  } else if (!/^\d{4}-\d{2}-\d{2}$/.test(data.config.baseDate)) {
    errors.push({
      path: "config.baseDate",
      message: "Invalid date format (expected YYYY-MM-DD)",
    });
  }

  if (!data.config.userId) {
    errors.push({ path: "config.userId", message: "Missing userId" });
  } else if (!isValidUUID(data.config.userId)) {
    errors.push({ path: "config.userId", message: "Invalid UUID" });
  }

  // Collect all refs to check for duplicates and build reference maps
  const contactRefs = new Set<string>();
  const priorityRefs = new Set<string>();
  const activityRefs = new Set<string>();

  // Validate contacts
  if (data.contacts) {
    for (let i = 0; i < data.contacts.length; i++) {
      const contact = data.contacts[i];
      const path = `contacts[${i}]`;

      if (!contact.ref) {
        errors.push({ path: `${path}.ref`, message: "Missing ref" });
      } else if (contactRefs.has(contact.ref)) {
        errors.push({
          path: `${path}.ref`,
          message: `Duplicate ref: ${contact.ref}`,
        });
      } else {
        contactRefs.add(contact.ref);
      }

      if (!contact.email) {
        errors.push({ path: `${path}.email`, message: "Missing email" });
      } else if (!isValidEmail(contact.email)) {
        errors.push({ path: `${path}.email`, message: "Invalid email" });
      }
    }
  }

  // Validate priorities (recursive)
  if (data.priorities) {
    for (let i = 0; i < data.priorities.length; i++) {
      validatePriority(
        data.priorities[i],
        `priorities[${i}]`,
        priorityRefs,
        errors,
      );
    }
  }

  // Validate activities (recursive)
  if (data.activities) {
    for (let i = 0; i < data.activities.length; i++) {
      validateActivity(
        data.activities[i],
        `activities[${i}]`,
        activityRefs,
        priorityRefs,
        contactRefs,
        errors,
      );
    }
  }

  return errors;
}

function validatePriority(
  priority: Priority,
  path: string,
  refs: Set<string>,
  errors: ValidationError[],
) {
  if (!priority.ref) {
    errors.push({ path: `${path}.ref`, message: "Missing ref" });
  } else if (refs.has(priority.ref)) {
    errors.push({
      path: `${path}.ref`,
      message: `Duplicate ref: ${priority.ref}`,
    });
  } else {
    refs.add(priority.ref);
  }

  if (!priority.title) {
    errors.push({ path: `${path}.title`, message: "Missing title" });
  }

  // Validate children recursively
  if (priority.children) {
    for (let i = 0; i < priority.children.length; i++) {
      validatePriority(
        priority.children[i],
        `${path}.children[${i}]`,
        refs,
        errors,
      );
    }
  }
}

function validateActivity(
  activity: Activity,
  path: string,
  activityRefs: Set<string>,
  priorityRefs: Set<string>,
  contactRefs: Set<string>,
  errors: ValidationError[],
  isChild = false,
) {
  if (activity.ref) {
    if (activityRefs.has(activity.ref)) {
      errors.push({
        path: `${path}.ref`,
        message: `Duplicate ref: ${activity.ref}`,
      });
    } else {
      activityRefs.add(activity.ref);
    }
  }

  if (!activity.type) {
    errors.push({ path: `${path}.type`, message: "Missing type" });
  } else if (!["action", "event", "note"].includes(activity.type)) {
    errors.push({ path: `${path}.type`, message: "Invalid type" });
  }

  // priority_ref is required for top-level activities, optional for children (inherited)
  if (!isChild && !activity.priority_ref) {
    errors.push({
      path: `${path}.priority_ref`,
      message: "Missing priority_ref",
    });
  } else if (activity.priority_ref && !priorityRefs.has(activity.priority_ref)) {
    errors.push({
      path: `${path}.priority_ref`,
      message: `Unknown priority_ref: ${activity.priority_ref}`,
    });
  }

  // Validate at XOR on
  if (activity.at && activity.on) {
    errors.push({
      path,
      message: "Activity cannot have both 'at' and 'on' fields",
    });
  }

  // Validate recurring activities have schedule
  if (activity.recurrence_rule && !activity.at && !activity.on) {
    errors.push({
      path,
      message: "Recurring activities must have 'at' or 'on' field",
    });
  }

  // Validate author_ref
  if (
    activity.author_ref &&
    activity.author_ref !== "user" &&
    !contactRefs.has(activity.author_ref)
  ) {
    errors.push({
      path: `${path}.author_ref`,
      message: `Unknown author_ref: ${activity.author_ref}`,
    });
  }

  // Validate assignee_ref
  if (
    activity.assignee_ref &&
    activity.assignee_ref !== "user" &&
    !contactRefs.has(activity.assignee_ref)
  ) {
    errors.push({
      path: `${path}.assignee_ref`,
      message: `Unknown assignee_ref: ${activity.assignee_ref}`,
    });
  }

  // Validate tags
  if (activity.tags) {
    for (const tagName of Object.keys(activity.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        errors.push({
          path: `${path}.tags.${tagName}`,
          message: `Unknown tag: ${tagName}`,
        });
      }

      const actors = activity.tags[tagName];
      for (const actor of actors) {
        if (actor !== "user" && !contactRefs.has(actor)) {
          errors.push({
            path: `${path}.tags.${tagName}`,
            message: `Unknown actor: ${actor}`,
          });
        }
      }
    }
  }

  // Validate mentions
  if (activity.mentions) {
    for (const mention of activity.mentions) {
      if (mention !== "user" && !contactRefs.has(mention)) {
        errors.push({
          path: `${path}.mentions`,
          message: `Unknown mention: ${mention}`,
        });
      }
    }
  }

  // Validate notes
  if (activity.notes) {
    for (let i = 0; i < activity.notes.length; i++) {
      validateNote(
        activity.notes[i],
        `${path}.notes[${i}]`,
        contactRefs,
        errors,
      );
    }
  }
}

function validateNote(
  note: Note,
  path: string,
  contactRefs: Set<string>,
  errors: ValidationError[],
) {
  // Validate author_ref
  if (
    note.author_ref &&
    note.author_ref !== "user" &&
    !contactRefs.has(note.author_ref)
  ) {
    errors.push({
      path: `${path}.author_ref`,
      message: `Unknown author_ref: ${note.author_ref}`,
    });
  }

  // Validate mentions
  if (note.mentions) {
    for (const mention of note.mentions) {
      if (mention !== "user" && !contactRefs.has(mention)) {
        errors.push({
          path: `${path}.mentions`,
          message: `Unknown mention: ${mention}`,
        });
      }
    }
  }

  // Validate tags
  if (note.tags) {
    for (const tagName of Object.keys(note.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        errors.push({
          path: `${path}.tags.${tagName}`,
          message: `Unknown tag: ${tagName}`,
        });
      }

      const actors = note.tags[tagName];
      for (const actor of actors) {
        if (actor !== "user" && !contactRefs.has(actor)) {
          errors.push({
            path: `${path}.tags.${tagName}`,
            message: `Unknown actor: ${actor}`,
          });
        }
      }
    }
  }
}

// ============================================================================
// SQL Generation
// ============================================================================

function generateSQL(data: SeedData): string {
  const lines: string[] = [];
  const { baseDate, userId } = data.config;

  // Header
  lines.push(`-- Generated by seed-generator on ${new Date().toISOString()}`);
  lines.push(`-- Config: baseDate=${baseDate}, userId=${userId}`);
  lines.push("");
  lines.push("BEGIN;");
  lines.push("");

  // Build reference maps
  const contactIdMap: RefMap<string> = { user: userId };
  const priorityIdMap: RefMap<string> = {};
  const activityIdMap: RefMap<string> = {};

  // Generate entities
  const contacts: GeneratedContact[] = [];
  const priorities: GeneratedPriority[] = [];
  const prioritySettings: GeneratedPrioritySettings[] = [];
  const priorityUsers: GeneratedPriorityUser[] = [];
  const activities: GeneratedActivity[] = [];
  const activityTags: GeneratedActivityTag[] = [];
  const notes: GeneratedNote[] = [];
  const noteTags: GeneratedNoteTag[] = [];

  // Process contacts
  if (data.contacts) {
    for (const contact of data.contacts) {
      const id = generateUUID();
      contactIdMap[contact.ref] = id;
      contacts.push({
        id,
        email: contact.email.toLowerCase(),
        name: contact.name ?? null,
        avatar_url: contact.avatar_url ?? null,
        user_id: contact.user_id ?? null,
      });
    }
  }

  // Process priorities (recursive)
  if (data.priorities) {
    for (const priority of data.priorities) {
      processPriority(
        priority,
        null,
        userId,
        baseDate,
        priorityIdMap,
        priorities,
        prioritySettings,
        priorityUsers,
      );
    }
  }

  // Process activities (with notes)
  let activityOrder = Date.now();
  if (data.activities) {
    for (const activity of data.activities) {
      activityOrder = processActivity(
        activity,
        userId,
        baseDate,
        activityOrder,
        contactIdMap,
        priorityIdMap,
        activityIdMap,
        activities,
        activityTags,
        notes,
        noteTags,
      );
    }
  }

  // Generate SQL

  // Contacts
  if (contacts.length > 0) {
    lines.push("-- Contacts");
    lines.push(
      "INSERT INTO contact (id, email, name, avatar_url, user_id, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < contacts.length; i++) {
      const c = contacts[i];
      const comma = i < contacts.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(c.id)}, ${sqlString(c.email)}, ${sqlString(c.name)}, ${sqlString(c.avatar_url)}, ${sqlString(c.user_id)}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Priorities
  if (priorities.length > 0) {
    lines.push("-- Priorities");
    lines.push(
      "INSERT INTO priority (id, created_by, title, path, root, archived_at, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < priorities.length; i++) {
      const p = priorities[i];
      const comma = i < priorities.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(p.id)}, ${sqlString(p.created_by)}, ${sqlString(p.title)}, ${sqlString(p.path)}, ${p.root}, ${sqlString(p.archived_at)}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Priority users
  if (priorityUsers.length > 0) {
    lines.push("-- Priority users");
    lines.push(
      "INSERT INTO priority_user (priority_id, user_id, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < priorityUsers.length; i++) {
      const pu = priorityUsers[i];
      const comma = i < priorityUsers.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(pu.priority_id)}, ${sqlString(pu.user_id)}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Priority settings
  if (prioritySettings.length > 0) {
    lines.push("-- Priority settings");
    lines.push(
      "INSERT INTO priority_settings (priority_id, user_id, color, path_override, pomodoro_duration, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < prioritySettings.length; i++) {
      const ps = prioritySettings[i];
      const comma = i < prioritySettings.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(ps.priority_id)}, ${sqlString(ps.user_id)}, ${sqlString(ps.color)}, ${sqlString(ps.path_override)}, ${sqlString(ps.pomodoro_duration)}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Activities
  if (activities.length > 0) {
    lines.push("-- Activities");
    lines.push(
      "INSERT INTO activity (id, author_id, created_by, assignee_id, priority_id, type, \"order\", draft, private, title, preview, at, \"on\", duration, done_at, recurrence_rule, archived_at, mentions, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < activities.length; i++) {
      const a = activities[i];
      const comma = i < activities.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(a.id)}, ${sqlString(a.author_id)}, ${sqlString(a.created_by)}, ${sqlString(a.assignee_id)}, ${sqlString(a.priority_id)}, ${sqlString(a.type)}, ${a.order}, ${a.draft}, ${a.private}, ${sqlString(a.title)}, ${sqlString(a.preview)}, ${a.at ? sqlString(a.at) : "NULL"}, ${a.on ? sqlString(a.on) : "NULL"}, ${a.duration ? sqlString(a.duration) : "NULL"}, ${sqlString(a.done_at)}, ${sqlString(a.recurrence_rule)}, ${sqlString(a.archived_at)}, ${a.mentions ? a.mentions : "NULL"}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Activity tags
  if (activityTags.length > 0) {
    lines.push("-- Activity tags");
    lines.push(
      "INSERT INTO activity_tag (actor_id, activity_id, tag_id, occurrence, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < activityTags.length; i++) {
      const at = activityTags[i];
      const comma = i < activityTags.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(at.actor_id)}, ${sqlString(at.activity_id)}, ${at.tag_id}, ${sqlString(at.occurrence)}, NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Notes
  if (notes.length > 0) {
    lines.push("-- Notes");
    lines.push(
      "INSERT INTO note (id, activity_id, author_id, created_by, draft, private, note, links, mentions, created_at, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < notes.length; i++) {
      const n = notes[i];
      const comma = i < notes.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(n.id)}, ${sqlString(n.activity_id)}, ${sqlString(n.author_id)}, ${sqlString(n.created_by)}, ${n.draft}, ${n.private}, ${sqlString(n.note)}, ${n.links ? sqlString(n.links) : "NULL"}, ${n.mentions ? n.mentions : "NULL"}, NOW(), NOW())${comma}`,
      );
    }
    lines.push("");
  }

  // Note tags
  if (noteTags.length > 0) {
    lines.push("-- Note tags");
    lines.push(
      "INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at)",
    );
    lines.push("VALUES");
    for (let i = 0; i < noteTags.length; i++) {
      const nt = noteTags[i];
      const comma = i < noteTags.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(nt.actor_id)}, ${sqlString(nt.note_id)}, ${nt.tag_id}, NOW())${comma}`,
      );
    }
    lines.push("");
  }

  lines.push("COMMIT;");

  return lines.join("\n");
}

// ============================================================================
// Entity processing
// ============================================================================

function processPriority(
  priority: Priority,
  parentPath: string | null,
  userId: string,
  baseDate: string,
  idMap: RefMap<string>,
  outPriorities: GeneratedPriority[],
  outSettings: GeneratedPrioritySettings[],
  outUsers: GeneratedPriorityUser[],
) {
  const id = generateUUID();
  idMap[priority.ref] = id;

  // Generate path
  const path = parentPath
    ? `${parentPath}.${generateRandomPath(4)}`
    : generateRandomPath(12);

  outPriorities.push({
    id,
    created_by: userId,
    title: priority.title,
    path,
    root: priority.root ?? false,
    archived_at: priority.archived_at
      ? parseDateOffset(baseDate, priority.archived_at).toISOString()
      : null,
  });

  // Add priority_user entry for creator
  outUsers.push({
    priority_id: id,
    user_id: userId,
  });

  // Add settings if present
  if (priority.settings) {
    outSettings.push({
      priority_id: id,
      user_id: userId,
      color: priority.settings.color ?? null,
      path_override: priority.settings.path_override ?? null,
      pomodoro_duration: priority.settings.pomodoro_duration ?? null,
    });
  }

  // Process children
  if (priority.children) {
    for (const child of priority.children) {
      processPriority(
        child,
        path,
        userId,
        baseDate,
        idMap,
        outPriorities,
        outSettings,
        outUsers,
      );
    }
  }
}

function processActivity(
  activity: Activity,
  userId: string,
  baseDate: string,
  order: number,
  contactIdMap: RefMap<string>,
  priorityIdMap: RefMap<string>,
  activityIdMap: RefMap<string>,
  outActivities: GeneratedActivity[],
  outTags: GeneratedActivityTag[],
  outNotes: GeneratedNote[],
  outNoteTags: GeneratedNoteTag[],
): number {
  const id = generateUUID();
  if (activity.ref) {
    activityIdMap[activity.ref] = id;
  }

  // Resolve refs
  const authorId = activity.author_ref
    ? contactIdMap[activity.author_ref]
    : userId;
  const assigneeId = activity.assignee_ref
    ? contactIdMap[activity.assignee_ref]
    : null;
  const priorityId = priorityIdMap[activity.priority_ref];

  // Parse schedule
  const at = activity.at ? parseTimestampRange(baseDate, activity.at) : null;
  const on = activity.on ? parseDateRange(baseDate, activity.on) : null;

  // Parse mentions
  const mentions = activity.mentions
    ? `{${activity.mentions.map((ref) => sqlString(contactIdMap[ref])).join(",")}}`
    : null;

  outActivities.push({
    id,
    author_id: authorId,
    created_by: userId,
    assignee_id: assigneeId,
    priority_id: priorityId,
    type: activity.type,
    order: order++,
    draft: activity.draft ?? false,
    private: activity.private ?? false,
    title: activity.title ?? null,
    preview: null, // Preview can be set to null for now
    at,
    on,
    duration: activity.duration ?? null,
    done_at: activity.done_at
      ? parseDateOffset(baseDate, activity.done_at).toISOString()
      : null,
    recurrence_rule: activity.recurrence_rule ?? null,
    archived_at: activity.archived_at
      ? parseDateOffset(baseDate, activity.archived_at).toISOString()
      : null,
    mentions,
  });

  // Process tags
  if (activity.tags) {
    for (const [tagName, actors] of Object.entries(activity.tags)) {
      const tagId = TAG_IDS[tagName];
      for (const actorRef of actors) {
        const actorId = contactIdMap[actorRef];
        outTags.push({
          actor_id: actorId,
          activity_id: id,
          tag_id: tagId,
          occurrence: null,
        });
      }
    }
  }

  // Process notes
  if (activity.notes) {
    for (const note of activity.notes) {
      processNote(
        note,
        id,
        userId,
        contactIdMap,
        outNotes,
        outNoteTags,
      );
    }
  }

  return order;
}

function processNote(
  note: Note,
  activityId: string,
  userId: string,
  contactIdMap: RefMap<string>,
  outNotes: GeneratedNote[],
  outNoteTags: GeneratedNoteTag[],
) {
  const id = generateUUID();

  // Resolve refs
  const authorId = note.author_ref
    ? contactIdMap[note.author_ref]
    : userId;

  // Parse links
  const links = note.links ? JSON.stringify(note.links) : null;

  // Parse mentions
  const mentions = note.mentions
    ? `{${note.mentions.map((ref) => sqlString(contactIdMap[ref])).join(",")}}`
    : null;

  outNotes.push({
    id,
    activity_id: activityId,
    author_id: authorId,
    created_by: userId,
    draft: note.draft ?? false,
    private: note.private ?? false,
    content: note.content ?? null,
    links,
    mentions,
  });

  // Process tags
  if (note.tags) {
    for (const [tagName, actors] of Object.entries(note.tags)) {
      const tagId = TAG_IDS[tagName];
      for (const actorRef of actors) {
        const actorId = contactIdMap[actorRef];
        outNoteTags.push({
          actor_id: actorId,
          note_id: id,
          tag_id: tagId,
        });
      }
    }
  }
}

// ============================================================================
// Date parsing
// ============================================================================

/**
 * Parse date offset like "+7d 14:00" or "-2w 09:30"
 */
function parseDateOffset(baseDate: string, offset: string): Date {
  if (!offset) {
    throw new Error(`Date offset is undefined or null`);
  }
  if (typeof offset !== 'string') {
    throw new Error(`Date offset must be a string, got ${typeof offset}: ${offset}`);
  }

  const base = new Date(baseDate + "T00:00:00Z");

  // Parse offset
  const match = offset.match(/^([+-]?\d+)([dwMy])(?:\s+(\d{2}):(\d{2}))?$/);
  if (!match) {
    throw new Error(`Invalid date offset: ${offset}`);
  }

  const [, amountStr, unit, hoursStr, minutesStr] = match;
  const amount = parseInt(amountStr, 10);

  const result = new Date(base);

  switch (unit) {
    case "d":
      result.setUTCDate(result.getUTCDate() + amount);
      break;
    case "w":
      result.setUTCDate(result.getUTCDate() + amount * 7);
      break;
    case "M":
      result.setUTCMonth(result.getUTCMonth() + amount);
      break;
    case "y":
      result.setUTCFullYear(result.getUTCFullYear() + amount);
      break;
  }

  // Set time if provided
  if (hoursStr && minutesStr) {
    result.setUTCHours(parseInt(hoursStr, 10));
    result.setUTCMinutes(parseInt(minutesStr, 10));
  }

  return result;
}

/**
 * Parse timestamp range like "+0d 10:00 / +0d 11:00"
 * Returns PostgreSQL tstzrange format
 */
function parseTimestampRange(baseDate: string, range: string): string {
  const parts = range.split("/").map((s) => s.trim());
  const start = parts[0];
  const end = parts[1] || start; // If no end, use start
  const startDate = parseDateOffset(baseDate, start);
  const endDate = parseDateOffset(baseDate, end);
  return `[${startDate.toISOString()},${endDate.toISOString()})`;
}

/**
 * Parse date range like "+3d / +5d" or "+3d" (single day)
 * Returns PostgreSQL daterange format
 */
function parseDateRange(baseDate: string, range: string): string {
  const parts = range.split("/").map((s) => s.trim());
  const start = parts[0];
  const startDate = parseDateOffset(baseDate, start);

  // If no end date, create a single-day range (start to start+1 day)
  let endDate: Date;
  if (parts[1]) {
    endDate = parseDateOffset(baseDate, parts[1]);
  } else {
    endDate = new Date(startDate);
    endDate.setUTCDate(endDate.getUTCDate() + 1);
  }

  const startStr = startDate.toISOString().split("T")[0];
  const endStr = endDate.toISOString().split("T")[0];
  return `[${startStr},${endStr})`;
}

// ============================================================================
// Utilities
// ============================================================================

function generateUUID(): string {
  // Simple UUID v4 generation
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function generateRandomPath(length: number): string {
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let result = "";
  for (let i = 0; i < length; i++) {
    result += chars[Math.floor(Math.random() * chars.length)];
  }
  return result;
}

function sqlString(value: string | number | null): string {
  if (value === null || value === undefined) {
    return "NULL";
  }
  if (typeof value === "number") {
    return value.toString();
  }
  return `'${value.replace(/'/g, "''")}'`;
}

function isValidUUID(uuid: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    uuid,
  );
}

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ============================================================================
// Run
// ============================================================================

main();
