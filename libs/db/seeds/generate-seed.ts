#!/usr/bin/env node

/**
 * Plot Seed Data Generator
 *
 * Generates SQL INSERT statements from YAML seed data definition.
 * See YAML_SPEC.md for format documentation.
 */
import pg from "pg";

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { parse as parseYAML } from "yaml";

import type {
  Activity,
  Contact,
  GeneratedActivity,
  GeneratedActivityTag,
  GeneratedContact,
  GeneratedNote,
  GeneratedNoteTag,
  GeneratedPriority,
  GeneratedPriorityContact,
  GeneratedPrioritySettings,
  GeneratedPriorityUser,
  Note,
  Priority,
  RefMap,
  SeedData,
  ValidationError,
} from "./types.js";
import { ALL_TAGS, TAG_IDS } from "./types.js";

// ============================================================================
// User Management
// ============================================================================

/**
 * Load environment variables from .env.development.local if they exist
 * and the environment variables aren't already set.
 */
function loadEnvFromFile() {
  const envFile = join(__dirname, "../../../.env.development.local");

  if (!existsSync(envFile)) {
    return;
  }

  try {
    const envContent = readFileSync(envFile, "utf-8");
    const lines = envContent.split("\n");

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith("#") || !trimmed.includes("=")) {
        continue;
      }

      const [key, ...valueParts] = trimmed.split("=");
      const value = valueParts.join("=");

      // Only set if not already in environment
      if (key.trim() && !process.env[key.trim()]) {
        process.env[key.trim()] = value.trim();
      }
    }
  } catch (error) {
    // Silently ignore errors reading the file
  }
}

/**
 * Get or create a user by email using direct PostgreSQL queries.
 * @returns Object with userId and contactId
 */
async function getOrCreateUser(
  email: string,
  userName: string
): Promise<{ userId: string; contactId: string }> {
  // Load from .env.development.local if needed
  loadEnvFromFile();

  const dbUrl =
    process.env.DATABASE_URL ||
    "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

  const pool = new pg.Pool({ connectionString: dbUrl });

  try {
    // Check if user exists in public."user"
    const existing = await pool.query(
      "SELECT id FROM public.\"user\" WHERE email = $1",
      [email]
    );

    let userId: string;

    if (existing.rows.length > 0) {
      userId = existing.rows[0].id;
      console.error(`✓ Found existing user: ${email} (${userId})`);
    } else {
      // Create new user
      const result = await pool.query(
        "INSERT INTO public.\"user\" (id, email, name) VALUES (gen_random_uuid(), $1, $2) RETURNING id",
        [email, userName]
      );
      userId = result.rows[0].id;
      console.error(`✓ Created new user: ${email} (${userId})`);
    }

    // Get contact for this user
    const contactResult = await pool.query(
      "SELECT id FROM contact WHERE user_id = $1 LIMIT 1",
      [userId]
    );

    let contactId: string;

    if (contactResult.rows.length > 0) {
      contactId = contactResult.rows[0].id;
    } else {
      // Create contact if it doesn't exist
      const newContact = await pool.query(
        "INSERT INTO contact (email, name, user_id) VALUES ($1, $2, $3) RETURNING id",
        [email, userName, userId]
      );
      contactId = newContact.rows[0].id;
      console.error(`✓ Created contact for user: ${email}`);
    }

    return { userId, contactId };
  } finally {
    await pool.end();
  }
}

// ============================================================================
// Main entry point
// ============================================================================

async function main() {
  const { values, positionals } = parseArgs({
    options: {
      help: { type: "boolean", short: "h" },
      apply: { type: "boolean" },
      "db-url": { type: "string" },
    },
    allowPositionals: true,
  });

  if (values.help || positionals.length === 0) {
    console.error(`Usage: generate-seed.ts <yaml-file> [options]

Generates SQL INSERT statements from YAML seed data definition.

Options:
  -h, --help              Show this help message
  --apply                 Apply the seed directly to the database
  --db-url <url>          Database connection string
                          (default: postgresql://postgres:postgres@127.0.0.1:54322/postgres)

Examples:
  # Generate SQL and output to stdout
  pnpm gen-seed seeds/screenshot-data.yaml > seed.sql

  # Pipe SQL directly to psql
  pnpm gen-seed my-data.yaml | psql -d plot_local

  # Apply seed directly to default local database
  pnpm gen-seed my-data.yaml --apply

  # Apply seed to custom database
  pnpm gen-seed my-data.yaml --apply --db-url postgresql://user:pass@host:port/db
`);
    process.exit(values.help ? 0 : 1);
  }

  const yamlFile = positionals[0];

  try {
    const yamlContent = await readFile(yamlFile, "utf-8");
    const data = parseYAML(yamlContent) as SeedData;

    const errors = validate(data, yamlFile, yamlContent);
    if (errors.length > 0) {
      console.error("Validation errors:");
      for (const error of errors) {
        const location = error.line
          ? `${error.file}:${error.line}`
          : error.file || "";
        const prefix = location ? `${location} - ` : "";
        console.error(`  ${prefix}${error.path}: ${error.message}`);
      }
      process.exit(1);
    }

    // Get or create user
    const { userId, contactId } = await getOrCreateUser(
      data.config.email,
      data.config.userName
    );

    const sql = generateSQL(data, userId, contactId);

    if (values.apply) {
      // Apply mode: execute SQL via psql
      const dbUrl =
        (values["db-url"] as string) ||
        "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

      await applySQL(sql, dbUrl, data);
    } else {
      // Default mode: output SQL to stdout
      console.log(sql);
    }
  } catch (error) {
    console.error("Error:", error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

// ============================================================================
// Apply SQL
// ============================================================================

async function applySQL(
  sql: string,
  dbUrl: string,
  data: SeedData
): Promise<void> {
  console.error(`Applying seed to database: ${dbUrl}`);
  console.error("");

  return new Promise((resolve, reject) => {
    const psql = spawn("psql", [dbUrl], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    psql.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    psql.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    psql.on("error", (error) => {
      if (error.message.includes("ENOENT")) {
        console.error(
          "Error: psql command not found. Please install PostgreSQL client tools."
        );
        reject(new Error("psql not found"));
      } else {
        console.error("Error spawning psql:", error.message);
        reject(error);
      }
    });

    psql.on("close", (code) => {
      if (code === 0) {
        // Show stderr even on success - it may contain important warnings or errors
        if (stderr.trim()) {
          console.error("⚠️  psql output (warnings/errors):");
          console.error(stderr);
          console.error("");
        }

        console.error("✓ Seed applied successfully");
        console.error("");
        console.error("Summary:");

        // Count entities from data
        const contactCount = data.contacts?.length || 0;
        const priorityCount = countPriorities(data.priorities || []);
        const activityCount = data.activities?.length || 0;
        const noteCount = countNotes(data.activities || []);

        if (contactCount > 0) {
          console.error(`  ${contactCount} contact(s)`);
        }
        if (priorityCount > 0) {
          console.error(
            `  ${priorityCount} priorit${priorityCount === 1 ? "y" : "ies"}`
          );
        }
        if (activityCount > 0) {
          console.error(
            `  ${activityCount} activit${activityCount === 1 ? "y" : "ies"}`
          );
        }
        if (noteCount > 0) {
          console.error(`  ${noteCount} note(s)`);
        }

        resolve();
      } else {
        console.error("✗ Failed to apply seed");
        console.error("");
        if (stderr) {
          console.error("Error output:");
          console.error(stderr);
        }
        reject(new Error(`psql exited with code ${code}`));
      }
    });

    // Write SQL to stdin
    psql.stdin.write(sql);
    psql.stdin.end();
  });
}

function countPriorities(priorities: Priority[]): number {
  let count = 0;
  for (const priority of priorities) {
    count++;
    if (priority.children) {
      count += countPriorities(priority.children);
    }
  }
  return count;
}

function countNotes(activities: Activity[]): number {
  let count = 0;
  for (const activity of activities) {
    if (activity.notes) {
      count += activity.notes.length;
    }
  }
  return count;
}

// ============================================================================
// Validation
// ============================================================================

/**
 * Find the line number for a given path in the YAML content
 * Example paths: "activities[12].created", "contacts[0].email"
 */
function findLineNumber(yamlContent: string, path: string): number | undefined {
  const lines = yamlContent.split("\n");

  // Parse the path to extract indices and keys
  // e.g., "activities[12].created" -> ["activities", "12", "created"]
  const pathParts: (string | number)[] = [];
  const regex = /([a-zA-Z_]+)|\[(\d+)\]/g;
  let match;

  while ((match = regex.exec(path)) !== null) {
    if (match[1]) {
      pathParts.push(match[1]);
    } else if (match[2]) {
      pathParts.push(parseInt(match[2], 10));
    }
  }

  if (pathParts.length === 0) {
    return undefined;
  }

  // Track current indentation level and array index
  let currentIndent = 0;
  let currentSection: string | null = null;
  let arrayIndex = -1;
  let targetArrayIndex: number | null = null;
  let searchingForKey: string | null = null;

  // Determine what we're searching for
  if (pathParts.length >= 2 && typeof pathParts[1] === "number") {
    currentSection = pathParts[0] as string;
    targetArrayIndex = pathParts[1] as number;
    if (pathParts.length > 2) {
      searchingForKey = pathParts[2] as string;
    }
  } else {
    currentSection = pathParts[0] as string;
    if (pathParts.length > 1) {
      searchingForKey = pathParts[1] as string;
    }
  }

  let inTargetSection = false;
  let inTargetItem = false;
  let targetItemLine: number | undefined;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();

    // Skip empty lines and comments
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    // Check if we're entering the target section
    if (trimmed.startsWith(`${currentSection}:`)) {
      inTargetSection = true;
      arrayIndex = -1;
      continue;
    }

    // If we're in the target section
    if (inTargetSection) {
      // Check for array items (lines starting with -)
      if (trimmed.startsWith("- ")) {
        arrayIndex++;

        if (targetArrayIndex !== null && arrayIndex === targetArrayIndex) {
          inTargetItem = true;
          targetItemLine = i + 1; // 1-indexed

          // If we're not searching for a specific key, return this line
          if (!searchingForKey) {
            return targetItemLine;
          }
        } else if (targetArrayIndex !== null && arrayIndex > targetArrayIndex) {
          // We've passed the target index
          break;
        } else if (inTargetItem && arrayIndex > targetArrayIndex!) {
          // We've moved to the next array item
          break;
        }
      }

      // If we're in the target item and searching for a key
      if (inTargetItem && searchingForKey) {
        if (trimmed.startsWith(`${searchingForKey}:`)) {
          return i + 1; // 1-indexed
        }
      }

      // Check if we've left the section (dedent)
      if (
        line.match(/^[a-zA-Z]/) &&
        !trimmed.startsWith(`${currentSection}:`)
      ) {
        break;
      }
    }
  }

  return targetItemLine; // Return the item line if we found it but not the specific key
}

function validate(
  data: SeedData,
  yamlFile?: string,
  yamlContent?: string
): ValidationError[] {
  const errors: ValidationError[] = [];

  const addError = (path: string, message: string) => {
    const error: ValidationError = { path, message };
    if (yamlFile) {
      error.file = yamlFile;
    }
    if (yamlContent) {
      error.line = findLineNumber(yamlContent, path);
    }
    errors.push(error);
  };

  // Validate config
  if (!data.config) {
    addError("config", "Missing config section");
    return errors;
  }

  if (!data.config.baseDate) {
    addError("config.baseDate", "Missing baseDate");
  } else if (!/^\d{4}-\d{2}-\d{2}$/.test(data.config.baseDate)) {
    addError("config.baseDate", "Invalid date format (expected YYYY-MM-DD)");
  }

  if (!data.config.email) {
    addError("config.email", "Missing email");
  } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.config.email)) {
    addError("config.email", "Invalid email format");
  }

  if (!data.config.userName) {
    addError("config.userName", "Missing userName");
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
        addError(`${path}.ref`, "Missing ref");
      } else if (contact.ref === "user") {
        addError(
          `${path}.ref`,
          'The ref "user" is reserved and cannot be used for contacts. Remove this contact from the YAML - the user contact is created automatically from config.email.'
        );
      } else if (contactRefs.has(contact.ref)) {
        addError(`${path}.ref`, `Duplicate ref: ${contact.ref}`);
      } else {
        contactRefs.add(contact.ref);
      }

      if (!contact.email) {
        addError(`${path}.email`, "Missing email");
      } else if (!isValidEmail(contact.email)) {
        addError(`${path}.email`, "Invalid email");
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
        addError
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
        addError
      );
    }
  }

  return errors;
}

function validatePriority(
  priority: Priority,
  path: string,
  refs: Set<string>,
  addError: (path: string, message: string) => void
) {
  if (!priority.ref) {
    addError(`${path}.ref`, "Missing ref");
  } else if (refs.has(priority.ref)) {
    addError(`${path}.ref`, `Duplicate ref: ${priority.ref}`);
  } else {
    refs.add(priority.ref);
  }

  if (!priority.title) {
    addError(`${path}.title`, "Missing title");
  }

  // Validate children recursively
  if (priority.children) {
    for (let i = 0; i < priority.children.length; i++) {
      validatePriority(
        priority.children[i],
        `${path}.children[${i}]`,
        refs,
        addError
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
  addError: (path: string, message: string) => void,
  isChild = false
) {
  if (activity.ref) {
    if (activityRefs.has(activity.ref)) {
      addError(`${path}.ref`, `Duplicate ref: ${activity.ref}`);
    } else {
      activityRefs.add(activity.ref);
    }
  }

  if (!activity.type) {
    addError(`${path}.type`, "Missing type");
  } else if (!["action", "event", "note"].includes(activity.type)) {
    addError(`${path}.type`, "Invalid type");
  }

  // Validate activity type 'note' requirements
  if (activity.type === "note") {
    // 'created' field is required for notes
    if (!activity.created) {
      addError(
        `${path}.created`,
        "Activity type 'note' must have 'created' field (date offset, e.g., '-2d', '+1w 14:30')"
      );
    }

    // For notes, 'on' and 'at' are only for future reminders (positive offsets)
    if (activity.on) {
      const match = activity.on.match(/^([+-]?\d+)[dwMy]/);
      if (match && match[1].startsWith("-")) {
        addError(
          `${path}.on`,
          "For activity type 'note', 'on' field must use positive offsets (future dates only). Use 'created' field for when the note was created."
        );
      }
    }

    if (activity.at) {
      const match = activity.at.match(/^([+-]?\d+)[dwMy]/);
      if (match && match[1].startsWith("-")) {
        addError(
          `${path}.at`,
          "For activity type 'note', 'at' field must use positive offsets (future dates only). Use 'created' field for when the note was created."
        );
      }
    }
  }

  // priority_ref is required for top-level activities, optional for children (inherited)
  if (!isChild && !activity.priority_ref) {
    addError(`${path}.priority_ref`, "Missing priority_ref");
  } else if (
    activity.priority_ref &&
    !priorityRefs.has(activity.priority_ref)
  ) {
    addError(
      `${path}.priority_ref`,
      `Unknown priority_ref: ${activity.priority_ref}`
    );
  }

  // Validate at XOR on
  if (activity.at && activity.on) {
    addError(path, "Activity cannot have both 'at' and 'on' fields");
  }

  // Validate recurring activities have schedule
  if (activity.recurrence_rule && !activity.at && !activity.on) {
    addError(path, "Recurring activities must have 'at' or 'on' field");
  }

  // Validate events have schedule (database constraint: activity_scheduled)
  // Actions without schedule will auto-default to base date
  if (
    activity.type === "event" &&
    !activity.recurrence_rule &&
    !activity.at &&
    !activity.on
  ) {
    addError(
      path,
      "Events must have a schedule: use 'on' for all-day (e.g., 'on: \"+0d\"') or 'at' for timed events (e.g., 'at: \"+0d 09:00 / +0d 10:00\"')"
    );
  }

  // Validate recurring activities cannot be marked done (database constraint: activity_no_complete_recurrence)
  if (activity.recurrence_rule && activity.done_at) {
    addError(
      path,
      "Recurring activities cannot be marked as done (done_at must be null). Remove either 'recurrence_rule' or 'done_at'."
    );
  }

  // Validate author_ref
  if (
    activity.author_ref &&
    activity.author_ref !== "user" &&
    !contactRefs.has(activity.author_ref)
  ) {
    addError(
      `${path}.author_ref`,
      `Unknown author_ref: ${activity.author_ref}`
    );
  }

  // Validate assignee_ref
  if (
    activity.assignee_ref &&
    activity.assignee_ref !== "user" &&
    !contactRefs.has(activity.assignee_ref)
  ) {
    addError(
      `${path}.assignee_ref`,
      `Unknown assignee_ref: ${activity.assignee_ref}`
    );
  }

  // Validate action activities have assignee (database constraint: activity_action_assignee)
  if (activity.type === "action" && !activity.assignee_ref) {
    addError(
      `${path}.assignee_ref`,
      "Action activities must have an assignee_ref (use 'user' for self-assigned tasks)"
    );
  }

  // Validate tags
  if (activity.tags) {
    for (const tagName of Object.keys(activity.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        addError(`${path}.tags.${tagName}`, `Unknown tag: ${tagName}`);
      }

      // Warn about computed tags for activities - they will be filtered out during seed generation
      // Activities compute all tags < 100 from their state properties
      const tagId = TAG_IDS[tagName];
      if (tagId && tagId < 100) {
        addError(
          `${path}.tags.${tagName}`,
          `Computed tag "${tagName}" will be ignored - activity tags are calculated from activity state (doNow, doLater, done, archivedAt) and should not be in seed data`
        );
      }

      const actors = activity.tags[tagName];
      for (const actor of actors) {
        if (actor !== "user" && !contactRefs.has(actor)) {
          addError(`${path}.tags.${tagName}`, `Unknown actor: ${actor}`);
        }
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
        addError
      );
    }
  }
}

function validateNote(
  note: Note,
  path: string,
  contactRefs: Set<string>,
  addError: (path: string, message: string) => void
) {
  // Validate created field (required)
  if (!note.created) {
    addError(
      `${path}.created`,
      "Missing required 'created' field (date offset, e.g., '-2d', '+1w 14:30')"
    );
  }

  // Validate author_ref
  if (
    note.author_ref &&
    note.author_ref !== "user" &&
    !contactRefs.has(note.author_ref)
  ) {
    addError(`${path}.author_ref`, `Unknown author_ref: ${note.author_ref}`);
  }

  // Validate mentions
  if (note.mentions) {
    for (const mention of note.mentions) {
      if (mention !== "user" && !contactRefs.has(mention)) {
        addError(`${path}.mentions`, `Unknown mention: ${mention}`);
      }
    }
  }

  // Validate tags
  if (note.tags) {
    for (const tagName of Object.keys(note.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        addError(`${path}.tags.${tagName}`, `Unknown tag: ${tagName}`);
      }

      // Warn about computed tags for notes - they will be filtered out during seed generation
      // Notes can have 'now' (1) and 'done' (3) for per-user assignment/completion
      // But not 'later' (2), 'archived' (4), 'attachment' (5), 'link' (6)
      const tagId = TAG_IDS[tagName];
      if (tagId && tagId < 100 && tagId !== 1 && tagId !== 3) {
        addError(
          `${path}.tags.${tagName}`,
          `Computed tag "${tagName}" will be ignored - this tag is calculated from note state and should not be in seed data. Notes can only have 'now' and 'done' tags.`
        );
      }

      const actors = note.tags[tagName];
      for (const actor of actors) {
        if (actor !== "user" && !contactRefs.has(actor)) {
          addError(`${path}.tags.${tagName}`, `Unknown actor: ${actor}`);
        }
      }
    }
  }
}

// ============================================================================
// SQL Generation
// ============================================================================

function generateSQL(
  data: SeedData,
  userId: string,
  contactId: string
): string {
  const lines: string[] = [];
  const { baseDate, email, userName } = data.config;

  // Header
  lines.push(`-- Generated by seed-generator on ${new Date().toISOString()}`);
  lines.push(
    `-- Config: baseDate=${baseDate}, email=${email}, userName=${userName}, userId=${userId}, contactId=${contactId}`
  );
  lines.push("");
  lines.push("BEGIN;");
  lines.push("");
  lines.push("-- Cleanup existing data for this user");
  lines.push(`DELETE FROM activity WHERE created_by = ${sqlString(userId)};`);
  lines.push(
    `DELETE FROM priority_settings WHERE user_id = ${sqlString(userId)};`
  );
  lines.push(`DELETE FROM priority_user WHERE user_id = ${sqlString(userId)};`);
  lines.push(`DELETE FROM priority WHERE created_by = ${sqlString(userId)};`);
  lines.push("");

  // Build reference maps
  const contactIdMap: RefMap<string> = { user: contactId };
  const priorityIdMap: RefMap<string> = {};
  const activityIdMap: RefMap<string> = {};

  // Generate entities
  const contacts: GeneratedContact[] = [];
  const priorities: GeneratedPriority[] = [];
  const prioritySettings: GeneratedPrioritySettings[] = [];
  const priorityUsers: GeneratedPriorityUser[] = [];
  const priorityContacts: GeneratedPriorityContact[] = [];
  const activities: GeneratedActivity[] = [];
  const activityTags: GeneratedActivityTag[] = [];
  const notes: GeneratedNote[] = [];
  const noteTags: GeneratedNoteTag[] = [];

  // Process contacts
  if (data.contacts) {
    for (const contact of data.contacts) {
      // Skip "user" ref - it's reserved for the user's own contact_id from app_metadata
      if (contact.ref === "user") {
        console.error(
          `⚠️  Skipping contact with reserved ref "user" (validation should have caught this)`
        );
        continue;
      }

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
        priorityUsers
      );
    }
  }

  // Link all contacts to the user's root priority for visibility
  // Root priorities have paths with no dots (single level path)
  const rootPriority = priorities.find((p) => !p.path.includes("."));
  if (rootPriority && contacts.length > 0) {
    for (const contact of contacts) {
      priorityContacts.push({
        priority_id: rootPriority.id,
        contact_id: contact.id,
      });
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
        noteTags
      );
    }
  }

  // Auto-set 'on' for actions without scheduling
  for (const activity of activities) {
    if (activity.type === "action" && !activity.on && !activity.at) {
      activity.on = `[${baseDate},)`;
    }
  }

  // Generate SQL

  // Contacts
  if (contacts.length > 0) {
    // Delete existing contacts with these emails first
    const contactEmails = contacts.map((c) => sqlString(c.email)).join(", ");
    lines.push("-- Cleanup existing contacts");
    lines.push(`DELETE FROM contact WHERE email IN (${contactEmails});`);
    lines.push("");

    lines.push("-- Contacts");
    lines.push(
      "INSERT INTO contact (id, email, name, avatar_url, user_id, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < contacts.length; i++) {
      const c = contacts[i];
      const comma = i < contacts.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(c.id)}, ${sqlString(c.email)}, ${sqlString(
          c.name
        )}, ${sqlString(c.avatar_url)}, ${sqlString(
          c.user_id
        )}, NOW(), NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Priorities
  if (priorities.length > 0) {
    lines.push("-- Priorities");
    lines.push(
      "INSERT INTO priority (id, created_by, title, path, archived_at, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < priorities.length; i++) {
      const p = priorities[i];
      const comma = i < priorities.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(p.id)}, ${sqlString(p.created_by)}, ${sqlString(
          p.title
        )}, ${sqlString(p.path)}, ${sqlString(
          p.archived_at
        )}, NOW(), NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Priority users
  if (priorityUsers.length > 0) {
    lines.push("-- Priority users");
    lines.push(
      "INSERT INTO priority_user (priority_id, user_id, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < priorityUsers.length; i++) {
      const pu = priorityUsers[i];
      const comma = i < priorityUsers.length - 1 ? "," : "";
      lines.push(
        `  (${sqlString(pu.priority_id)}, ${sqlString(
          pu.user_id
        )}, NOW(), NOW())${comma}`
      );
    }
    lines.push("ON CONFLICT (user_id, priority_id) DO NOTHING;");
    lines.push("");
  }

  // Priority contacts
  if (priorityContacts.length > 0) {
    lines.push("-- Priority contacts");
    lines.push(
      "INSERT INTO priority_contact (priority_id, contact_id, created_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < priorityContacts.length; i++) {
      const pc = priorityContacts[i];
      const comma = i < priorityContacts.length - 1 ? "," : "";
      lines.push(
        `  (${sqlString(pc.priority_id)}, ${sqlString(
          pc.contact_id
        )}, NOW())${comma}`
      );
    }
    lines.push("ON CONFLICT (priority_id, contact_id) DO NOTHING;");
    lines.push("");
  }

  // Priority settings
  if (prioritySettings.length > 0) {
    lines.push("-- Priority settings");
    lines.push(
      "INSERT INTO priority_settings (priority_id, user_id, color, path, pomodoro, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < prioritySettings.length; i++) {
      const ps = prioritySettings[i];
      const comma = i < prioritySettings.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(ps.priority_id)}, ${sqlString(ps.user_id)}, ${
          ps.color !== null ? ps.color : "NULL"
        }, ${sqlString(ps.path)}, ${
          ps.pomodoro !== null ? ps.pomodoro : "NULL"
        }, NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Activities
  if (activities.length > 0) {
    lines.push("-- Activities");
    lines.push(
      'INSERT INTO activity (id, author_id, created_by, assignee_id, priority_id, type, kind, "order", draft, private, title, preview, at, "on", duration, done_at, recurrence_rule, archived_at, source_created_at, updated_at)'
    );
    lines.push("VALUES");
    for (let i = 0; i < activities.length; i++) {
      const a = activities[i];
      const comma = i < activities.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(a.id)}, ${sqlString(a.author_id)}, ${sqlString(
          a.created_by
        )}, ${sqlString(a.assignee_id)}, ${sqlString(
          a.priority_id
        )}, ${sqlString(a.type)}, ${a.kind ? sqlString(a.kind) : "NULL"}, ${
          a.order
        }, ${a.draft}, ${a.private}, ${sqlString(a.title)}, ${sqlString(
          a.preview
        )}, ${a.at ? sqlString(a.at) : "NULL"}, ${
          a.on ? sqlString(a.on) : "NULL"
        }, ${a.duration ? sqlString(a.duration) : "NULL"}, ${sqlString(
          a.done_at
        )}, ${sqlString(a.recurrence_rule)}, ${sqlString(
          a.archived_at
        )}, ${sqlString(a.source_created_at)}, ${sqlString(
          a.updated_at
        )})${comma}`
      );
    }
    lines.push("");
  }

  // Activity tags
  if (activityTags.length > 0) {
    lines.push("-- Activity tags");
    lines.push(
      "INSERT INTO activity_tag (actor_id, activity_id, tag_id, occurrence, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < activityTags.length; i++) {
      const at = activityTags[i];
      const comma = i < activityTags.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(at.actor_id)}, ${sqlString(at.activity_id)}, ${
          at.tag_id
        }, ${sqlString(at.occurrence)}, NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Notes
  if (notes.length > 0) {
    lines.push("-- Notes");
    lines.push(
      "INSERT INTO note (id, activity_id, author_id, created_by, draft, private, content, links, mentions, source_created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < notes.length; i++) {
      const n = notes[i];
      const comma = i < notes.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(n.id)}, ${sqlString(n.activity_id)}, ${sqlString(
          n.author_id
        )}, ${sqlString(n.created_by)}, ${n.draft}, ${n.private}, ${sqlString(
          n.content
        )}, ${n.links ? sqlString(n.links) : "NULL"}, ${
          n.mentions ? sqlString(n.mentions) : "NULL"
        }, ${sqlString(n.source_created_at)}, ${sqlString(
          n.updated_at
        )})${comma}`
      );
    }
    lines.push("");
  }

  // Note tags
  if (noteTags.length > 0) {
    lines.push("-- Note tags");
    lines.push("INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at)");
    lines.push("VALUES");
    for (let i = 0; i < noteTags.length; i++) {
      const nt = noteTags[i];
      const comma = i < noteTags.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(nt.actor_id)}, ${sqlString(nt.note_id)}, ${
          nt.tag_id
        }, NOW())${comma}`
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
  outUsers: GeneratedPriorityUser[]
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
      path: priority.settings.path_override ?? null,
      pomodoro: priority.settings.pomodoro_duration ?? null,
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
        outUsers
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
  outNoteTags: GeneratedNoteTag[]
): number {
  const id = generateUUID();
  if (activity.ref) {
    activityIdMap[activity.ref] = id;
  }

  // Resolve refs
  const authorId = activity.author_ref
    ? contactIdMap[activity.author_ref]
    : contactIdMap["user"]; // Default to user's contact ID
  const assigneeId = activity.assignee_ref
    ? contactIdMap[activity.assignee_ref]
    : null;
  const priorityId = priorityIdMap[activity.priority_ref];

  // Parse schedule
  const at = activity.at ? parseTimestampRange(baseDate, activity.at) : null;
  const on = activity.on ? parseDateRange(baseDate, activity.on) : null;

  // Parse created timestamp
  const createdAt = activity.created
    ? parseDateOffset(baseDate, activity.created).toISOString()
    : new Date().toISOString();

  outActivities.push({
    id,
    author_id: authorId,
    created_by: userId,
    assignee_id: assigneeId,
    priority_id: priorityId,
    type: activity.type,
    kind: activity.kind ?? null,
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
    source_created_at: createdAt,
    updated_at: createdAt,
  });

  // Process tags
  if (activity.tags) {
    for (const [tagName, actors] of Object.entries(activity.tags)) {
      const tagId = TAG_IDS[tagName];
      // Skip all computed tags (tag_id 1-99) for activities
      // Activities compute now, later, done, archived from their state properties
      if (tagId < 100) {
        continue;
      }
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
        baseDate,
        contactIdMap,
        outNotes,
        outNoteTags
      );
    }
  }

  return order;
}

function processNote(
  note: Note,
  activityId: string,
  userId: string,
  baseDate: string,
  contactIdMap: RefMap<string>,
  outNotes: GeneratedNote[],
  outNoteTags: GeneratedNoteTag[]
) {
  const id = generateUUID();

  // Resolve refs
  const authorId = note.author_ref
    ? contactIdMap[note.author_ref]
    : contactIdMap["user"]; // Default to user's contact ID

  // Parse created timestamp
  const createdAt = parseDateOffset(baseDate, note.created).toISOString();

  // Parse links
  const links = note.links ? JSON.stringify(note.links) : null;

  // Parse mentions
  const mentions = note.mentions
    ? `{${note.mentions.map((ref) => contactIdMap[ref]).join(",")}}`
    : null;

  outNotes.push({
    id,
    activity_id: activityId,
    author_id: authorId,
    created_by: userId,
    draft: note.draft ?? false,
    private: note.private ?? false,
    content: note.content ?? note.note ?? null,
    links,
    mentions,
    source_created_at: createdAt,
    updated_at: createdAt,
  });

  // Process tags
  if (note.tags) {
    for (const [tagName, actors] of Object.entries(note.tags)) {
      const tagId = TAG_IDS[tagName];
      // Skip most computed tags for notes, but allow 'now' (1) and 'done' (3)
      // Notes use now/done tags for per-user assignment/completion tracking
      // Block: later (2), archived (4), attachment (5), link (6)
      if (tagId < 100 && tagId !== 1 && tagId !== 3) {
        continue;
      }
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
  if (typeof offset !== "string") {
    throw new Error(
      `Date offset must be a string, got ${typeof offset}: ${offset}`
    );
  }

  const base = new Date(baseDate + "T00:00:00");

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
      result.setDate(result.getDate() + amount);
      break;
    case "w":
      result.setDate(result.getDate() + amount * 7);
      break;
    case "M":
      result.setMonth(result.getMonth() + amount);
      break;
    case "y":
      result.setFullYear(result.getFullYear() + amount);
      break;
  }

  // Set time if provided
  if (hoursStr && minutesStr) {
    result.setHours(parseInt(hoursStr, 10));
    result.setMinutes(parseInt(minutesStr, 10));
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

  const startStr = startDate.toISOString().split("T")[0];

  // If no end date, create an open-ended range
  if (parts[1]) {
    const endDate = parseDateOffset(baseDate, parts[1]);
    const endStr = endDate.toISOString().split("T")[0];
    return `[${startStr},${endStr})`;
  } else {
    return `[${startStr},)`;
  }
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
  const chars =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
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
    uuid
  );
}

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ============================================================================
// Run
// ============================================================================

main();
