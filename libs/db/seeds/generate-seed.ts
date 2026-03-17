#!/usr/bin/env node

/**
 * Plot Seed Data Generator
 *
 * Generates SQL INSERT statements from YAML seed data definition.
 * See spec.md for format documentation.
 */
import pg from "pg";

import { createClerkClient } from "@clerk/backend";
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { parse as parseYAML } from "yaml";

import type {
  Contact,
  GeneratedContact,
  GeneratedLink,
  GeneratedNote,
  GeneratedNoteTag,
  GeneratedPriority,
  GeneratedPriorityContact,
  GeneratedPrioritySettings,
  GeneratedPriorityUser,
  GeneratedSchedule,
  GeneratedThread,
  GeneratedThreadTag,
  Note,
  Priority,
  RefMap,
  SeedData,
  SeedLink,
  SeedSource,
  SeedTwist,
  Thread,
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
 * Create or find a Clerk user for the given email.
 * Returns the Clerk user ID, or null if Clerk is not configured.
 */
async function getOrCreateClerkUser(
  email: string,
  userName: string
): Promise<string | null> {
  const secretKey = process.env.CLERK_SECRET_KEY;
  if (!secretKey) {
    console.error(
      "⚠ CLERK_SECRET_KEY not set — skipping Clerk user creation. Set it in .env.development.local"
    );
    return null;
  }

  const clerk = createClerkClient({ secretKey });
  const [firstName, ...lastParts] = userName.split(" ");
  const lastName = lastParts.join(" ") || undefined;

  try {
    const clerkUser = await clerk.users.createUser({
      emailAddress: [email],
      password: email,
      firstName,
      lastName,
      skipPasswordChecks: true,
    });
    console.error(`✓ Created Clerk user: ${email} (${clerkUser.id})`);
    return clerkUser.id;
  } catch (error: any) {
    // 422 with "already exists" means the user is already in Clerk
    if (
      error?.status === 422 &&
      error?.errors?.some((e: any) => e.code === "form_identifier_exists")
    ) {
      // Look up existing Clerk user by email
      const existing = await clerk.users.getUserList({
        emailAddress: [email],
      });
      if (existing.data.length > 0) {
        console.error(
          `✓ Found existing Clerk user: ${email} (${existing.data[0].id})`
        );
        return existing.data[0].id;
      }
    }
    console.error(`⚠ Failed to create Clerk user for ${email}:`, error?.errors ?? error);
    return null;
  }
}

/**
 * Get or create a user by email using direct PostgreSQL queries.
 * Also creates a corresponding Clerk user for authentication.
 * @returns Object with userId and contactId
 */
async function getOrCreateUser(
  email: string,
  userName: string
): Promise<{ userId: string; contactId: string }> {
  // Load from .env.development.local if needed
  loadEnvFromFile();

  // Create Clerk user first (or find existing)
  const clerkId = await getOrCreateClerkUser(email, userName);

  const dbUrl =
    process.env.DATABASE_URL ||
    "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

  const pool = new pg.Pool({ connectionString: dbUrl });

  try {
    // Check if user exists in public."user"
    const existing = await pool.query(
      "SELECT id, clerk_id FROM public.\"user\" WHERE email = $1",
      [email]
    );

    let userId: string;

    if (existing.rows.length > 0) {
      userId = existing.rows[0].id;
      console.error(`✓ Found existing user: ${email} (${userId})`);

      // Update clerk_id if we have one and it's not set
      if (clerkId && existing.rows[0].clerk_id !== clerkId) {
        await pool.query(
          "UPDATE public.\"user\" SET clerk_id = $1 WHERE id = $2",
          [clerkId, userId]
        );
        console.error(`✓ Updated clerk_id for user: ${email}`);
      }
    } else {
      // Create new user with clerk_id
      const result = await pool.query(
        "INSERT INTO public.\"user\" (id, email, name, clerk_id) VALUES (gen_random_uuid(), $1, $2, $3) RETURNING id",
        [email, userName, clerkId]
      );
      userId = result.rows[0].id;
      console.error(`✓ Created new user: ${email} (${userId})`);
    }

    // Set externalId on Clerk user to link back to DB user
    if (clerkId) {
      try {
        const clerk = createClerkClient({
          secretKey: process.env.CLERK_SECRET_KEY!,
        });
        await clerk.users.updateUser(clerkId, { externalId: userId });
      } catch (error: any) {
        console.error(`⚠ Failed to set Clerk externalId:`, error?.errors ?? error);
      }
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

    const { sql, fileUploads } = generateSQL(data, userId, contactId);

    if (values.apply) {
      // Apply mode: execute SQL via psql
      const dbUrl =
        (values["db-url"] as string) ||
        "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

      await applySQL(sql, dbUrl, data);

      // Upload seed files to local R2
      if (fileUploads.length > 0) {
        const assetsDir = join(dirname(yamlFile), "assets");
        await uploadSeedFiles(fileUploads, assetsDir);
      }
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
    // spawn is used here (not exec) — arguments are passed as array, no shell injection risk
    const psql = spawn("psql", ["-v", "ON_ERROR_STOP=1", dbUrl], {
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
        if (stderr.trim()) {
          console.error("⚠️  psql output (warnings/errors):");
          console.error(stderr);
          console.error("");
        }

        console.error("✓ Seed applied successfully");
        console.error("");
        console.error("Summary:");

        const contactCount = data.contacts?.length || 0;
        const priorityCount = countPriorities(data.priorities || []);
        const threadCount = data.threads?.length || 0;
        const sourceCount = data.sources?.length || 0;
        const twistCount = data.twists?.length || 0;
        const noteCount = countNotes(data.threads || []);
        const linkCount = countLinks(data.threads || []);

        if (contactCount > 0) {
          console.error(`  ${contactCount} contact(s)`);
        }
        if (priorityCount > 0) {
          console.error(
            `  ${priorityCount} priorit${priorityCount === 1 ? "y" : "ies"}`
          );
        }
        if (sourceCount > 0) {
          console.error(`  ${sourceCount} source(s)`);
        }
        if (twistCount > 0) {
          console.error(`  ${twistCount} twist(s)`);
        }
        if (threadCount > 0) {
          console.error(`  ${threadCount} thread(s)`);
        }
        if (linkCount > 0) {
          console.error(`  ${linkCount} link(s)`);
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

    psql.stdin.write(sql);
    psql.stdin.end();
  });
}

async function uploadSeedFiles(
  fileUploads: SeedFileUpload[],
  assetsDir: string
): Promise<void> {
  const r2Persist = join(__dirname, "../../../workers/api/.wrangler/state/v3/r2");
  const bucket = "plot-files-development";

  const uploads = fileUploads.filter((file) => {
    const localPath = join(assetsDir, file.fileName);
    if (!existsSync(localPath)) {
      console.error(`  ⚠ Asset not found: ${localPath} (skipping)`);
      return false;
    }
    return true;
  });

  if (uploads.length === 0) return;

  console.error("");
  console.error("Uploading seed files to local R2...");

  const { Miniflare } = await import("miniflare");
  const mf = new Miniflare({
    modules: true,
    script: "export default { fetch() { return new Response('ok'); } }",
    r2Buckets: [bucket],
    r2Persist,
  });

  const r2 = await mf.getR2Bucket(bucket);

  for (const file of uploads) {
    const localPath = join(assetsDir, file.fileName);
    const r2Key = `files/${file.fileId}/${file.fileName}`;
    const buf = readFileSync(localPath);
    const content = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);

    await r2.put(r2Key, content, {
      customMetadata: {
        priorityId: file.priorityId,
        uploadedBy: file.userId,
      },
      httpMetadata: {
        contentType: file.mimeType,
      },
    });

    console.error(`  ✓ ${file.fileName} → ${r2Key}`);
  }

  await mf.dispose();
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

function countNotes(threads: Thread[]): number {
  let count = 0;
  for (const thread of threads) {
    if (thread.notes) {
      count += thread.notes.length;
    }
  }
  return count;
}

function countLinks(threads: Thread[]): number {
  let count = 0;
  for (const thread of threads) {
    if (thread.links) {
      count += thread.links.length;
    }
  }
  return count;
}

// ============================================================================
// Validation
// ============================================================================

/**
 * Find the line number for a given path in the YAML content
 */
function findLineNumber(yamlContent: string, path: string): number | undefined {
  const lines = yamlContent.split("\n");

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

  let currentSection: string | null = null;
  let arrayIndex = -1;
  let targetArrayIndex: number | null = null;
  let searchingForKey: string | null = null;

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

    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    if (trimmed.startsWith(`${currentSection}:`)) {
      inTargetSection = true;
      arrayIndex = -1;
      continue;
    }

    if (inTargetSection) {
      if (trimmed.startsWith("- ")) {
        arrayIndex++;

        if (targetArrayIndex !== null && arrayIndex === targetArrayIndex) {
          inTargetItem = true;
          targetItemLine = i + 1;

          if (!searchingForKey) {
            return targetItemLine;
          }
        } else if (
          targetArrayIndex !== null &&
          arrayIndex > targetArrayIndex
        ) {
          break;
        } else if (inTargetItem && arrayIndex > targetArrayIndex!) {
          break;
        }
      }

      if (inTargetItem && searchingForKey) {
        if (trimmed.startsWith(`${searchingForKey}:`)) {
          return i + 1;
        }
      }

      if (
        line.match(/^[a-zA-Z]/) &&
        !trimmed.startsWith(`${currentSection}:`)
      ) {
        break;
      }
    }
  }

  return targetItemLine;
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

  // Collect all refs
  const contactRefs = new Set<string>();
  const priorityRefs = new Set<string>();
  const sourceRefs = new Set<string>();
  const twistRefs = new Set<string>();
  const threadRefs = new Set<string>();

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
          'The ref "user" is reserved and cannot be used for contacts.'
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

  // Validate sources
  if (data.sources) {
    for (let i = 0; i < data.sources.length; i++) {
      const source = data.sources[i];
      const path = `sources[${i}]`;

      if (!source.ref) {
        addError(`${path}.ref`, "Missing ref");
      } else if (sourceRefs.has(source.ref)) {
        addError(`${path}.ref`, `Duplicate ref: ${source.ref}`);
      } else {
        sourceRefs.add(source.ref);
      }

      if (!source.name) {
        addError(`${path}.name`, "Missing name");
      }

      if (!source.priority_ref) {
        addError(`${path}.priority_ref`, "Missing priority_ref");
      } else if (!priorityRefs.has(source.priority_ref)) {
        addError(
          `${path}.priority_ref`,
          `Unknown priority_ref: ${source.priority_ref}`
        );
      }

      if (!source.link_types || source.link_types.length === 0) {
        addError(`${path}.link_types`, "Missing or empty link_types");
      }
    }
  }

  // Validate twists
  if (data.twists) {
    for (let i = 0; i < data.twists.length; i++) {
      const twist = data.twists[i];
      const path = `twists[${i}]`;

      if (!twist.ref) {
        addError(`${path}.ref`, "Missing ref");
      } else if (twistRefs.has(twist.ref)) {
        addError(`${path}.ref`, `Duplicate ref: ${twist.ref}`);
      } else {
        twistRefs.add(twist.ref);
      }

      if (!twist.name) {
        addError(`${path}.name`, "Missing name");
      }

      if (!twist.priority_ref) {
        addError(`${path}.priority_ref`, "Missing priority_ref");
      } else if (!priorityRefs.has(twist.priority_ref)) {
        addError(
          `${path}.priority_ref`,
          `Unknown priority_ref: ${twist.priority_ref}`
        );
      }
    }
  }

  // Validate threads
  if (data.threads) {
    for (let i = 0; i < data.threads.length; i++) {
      validateThread(
        data.threads[i],
        `threads[${i}]`,
        threadRefs,
        priorityRefs,
        contactRefs,
        sourceRefs,
        twistRefs,
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

function validateThread(
  thread: Thread,
  path: string,
  threadRefs: Set<string>,
  priorityRefs: Set<string>,
  contactRefs: Set<string>,
  sourceRefs: Set<string>,
  twistRefs: Set<string>,
  addError: (path: string, message: string) => void
) {
  if (thread.ref) {
    if (threadRefs.has(thread.ref)) {
      addError(`${path}.ref`, `Duplicate ref: ${thread.ref}`);
    } else {
      threadRefs.add(thread.ref);
    }
  }

  if (!thread.priority_ref) {
    addError(`${path}.priority_ref`, "Missing priority_ref");
  } else if (!priorityRefs.has(thread.priority_ref)) {
    addError(
      `${path}.priority_ref`,
      `Unknown priority_ref: ${thread.priority_ref}`
    );
  }

  // Validate icon
  if (thread.icon) {
    const validIcons = ["notes", "idea", "goal", "decision", "discussion", "announcement", "ask"];
    if (!validIcons.includes(thread.icon)) {
      addError(`${path}.icon`, `Invalid icon: ${thread.icon}. Valid values: ${validIcons.join(", ")}`);
    }
  }

  // Validate twist_ref
  if (thread.twist_ref && !twistRefs.has(thread.twist_ref)) {
    addError(`${path}.twist_ref`, `Unknown twist_ref: ${thread.twist_ref}`);
  }

  // Validate schedule
  if (thread.schedule) {
    const sched = thread.schedule;
    if (sched.at && sched.on) {
      addError(`${path}.schedule`, "Schedule cannot have both 'at' and 'on'");
    }
    if (sched.recurrence_rule && !sched.at && !sched.on) {
      addError(
        `${path}.schedule`,
        "Recurring schedules must have 'at' or 'on'"
      );
    }
  }

  // Validate author_ref
  if (
    thread.author_ref &&
    thread.author_ref !== "user" &&
    !contactRefs.has(thread.author_ref)
  ) {
    addError(
      `${path}.author_ref`,
      `Unknown author_ref: ${thread.author_ref}`
    );
  }

  // Validate tags
  if (thread.tags) {
    for (const tagName of Object.keys(thread.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        addError(`${path}.tags.${tagName}`, `Unknown tag: ${tagName}`);
      }

      const tagId = TAG_IDS[tagName];
      if (tagId && tagId < 100) {
        addError(
          `${path}.tags.${tagName}`,
          `Computed tag "${tagName}" will be ignored`
        );
      }

      const actors = thread.tags[tagName];
      for (const actor of actors) {
        if (actor !== "user" && !contactRefs.has(actor)) {
          addError(`${path}.tags.${tagName}`, `Unknown actor: ${actor}`);
        }
      }
    }
  }

  // Validate links
  if (thread.links) {
    for (let i = 0; i < thread.links.length; i++) {
      const link = thread.links[i];
      const linkPath = `${path}.links[${i}]`;

      if (link.source_ref && !sourceRefs.has(link.source_ref)) {
        addError(
          `${linkPath}.source_ref`,
          `Unknown source_ref: ${link.source_ref}`
        );
      }

      if (
        link.assignee_ref &&
        link.assignee_ref !== "user" &&
        !contactRefs.has(link.assignee_ref)
      ) {
        addError(
          `${linkPath}.assignee_ref`,
          `Unknown assignee_ref: ${link.assignee_ref}`
        );
      }

      if (
        link.author_ref &&
        link.author_ref !== "user" &&
        !contactRefs.has(link.author_ref)
      ) {
        addError(
          `${linkPath}.author_ref`,
          `Unknown author_ref: ${link.author_ref}`
        );
      }
    }
  }

  // Validate notes
  if (thread.notes) {
    for (let i = 0; i < thread.notes.length; i++) {
      validateNote(
        thread.notes[i],
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
  if (!note.created) {
    addError(
      `${path}.created`,
      "Missing required 'created' field"
    );
  }

  if (
    note.author_ref &&
    note.author_ref !== "user" &&
    !contactRefs.has(note.author_ref)
  ) {
    addError(`${path}.author_ref`, `Unknown author_ref: ${note.author_ref}`);
  }

  if (note.mentions) {
    for (const mention of note.mentions) {
      if (mention !== "user" && !contactRefs.has(mention)) {
        addError(`${path}.mentions`, `Unknown mention: ${mention}`);
      }
    }
  }

  if (note.tags) {
    for (const tagName of Object.keys(note.tags)) {
      if (!ALL_TAGS.includes(tagName as any)) {
        addError(`${path}.tags.${tagName}`, `Unknown tag: ${tagName}`);
      }

      const tagId = TAG_IDS[tagName];
      if (tagId && tagId < 100 && tagId !== 1 && tagId !== 3) {
        addError(
          `${path}.tags.${tagName}`,
          `Computed tag "${tagName}" will be ignored`
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

interface SeedFileUpload {
  fileId: string;
  fileName: string;
  mimeType: string;
  priorityId: string;
  userId: string;
}

function generateSQL(
  data: SeedData,
  userId: string,
  contactId: string
): { sql: string; fileUploads: SeedFileUpload[] } {
  const lines: string[] = [];
  const fileUploads: SeedFileUpload[] = [];
  const { baseDate, email, userName } = data.config;

  // Header
  lines.push(`-- Generated by seed-generator on ${new Date().toISOString()}`);
  lines.push(
    `-- Config: baseDate=${baseDate}, email=${email}, userName=${userName}, userId=${userId}, contactId=${contactId}`
  );
  lines.push("");
  lines.push("\\set ON_ERROR_STOP on");
  lines.push("");
  lines.push("BEGIN;");
  lines.push("");
  lines.push("-- Cleanup existing data for this user");
  lines.push(`DELETE FROM thread WHERE created_by = ${sqlString(userId)};`);
  lines.push(
    `DELETE FROM priority_setting WHERE user_id = ${sqlString(userId)};`
  );
  lines.push(`DELETE FROM priority_user WHERE user_id = ${sqlString(userId)};`);
  lines.push(`DELETE FROM priority WHERE created_by = ${sqlString(userId)};`);
  lines.push(
    `DELETE FROM twist_admin WHERE user_id = ${sqlString(userId)};`
  );
  lines.push("");

  // Build reference maps
  const contactIdMap: RefMap<string> = { user: contactId };
  const priorityIdMap: RefMap<string> = {};
  const sourceIdMap: RefMap<string> = {}; // source ref -> priority_twist_id
  const twistIdMap: RefMap<string> = {}; // twist ref -> priority_twist_id
  const threadIdMap: RefMap<string> = {};

  // Generated entity arrays
  const contacts: GeneratedContact[] = [];
  const priorities: GeneratedPriority[] = [];
  const prioritySettings: GeneratedPrioritySettings[] = [];
  const priorityUsers: GeneratedPriorityUser[] = [];
  const priorityContacts: GeneratedPriorityContact[] = [];
  const threads: GeneratedThread[] = [];
  const threadTags: GeneratedThreadTag[] = [];
  const generatedLinks: GeneratedLink[] = [];
  const schedules: GeneratedSchedule[] = [];
  const notes: GeneratedNote[] = [];
  const noteTags: GeneratedNoteTag[] = [];

  // Source SQL is generated inline (due to bigint IDENTITY sequencing)
  const sourceSQLLines: string[] = [];

  // Process contacts
  if (data.contacts) {
    for (const contact of data.contacts) {
      if (contact.ref === "user") {
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
        priorityUsers,
        contactIdMap,
        contacts
      );
    }
  }

  // Link all contacts to the user's root priority for visibility
  const rootPriority = priorities.find((p) => !p.path.includes("."));
  if (rootPriority && contacts.length > 0) {
    for (const contact of contacts) {
      priorityContacts.push({
        priority_id: rootPriority.id,
        contact_id: contact.id,
      });
    }
  }

  // Process sources
  if (data.sources) {
    for (const source of data.sources) {
      processSource(
        source,
        userId,
        priorityIdMap,
        sourceIdMap,
        sourceSQLLines
      );
    }
  }

  // Process twists (non-source twists like Claude, ChatGPT)
  if (data.twists) {
    for (const twist of data.twists) {
      processTwist(
        twist,
        userId,
        priorityIdMap,
        twistIdMap,
        sourceSQLLines
      );
    }
  }

  // Post-insert SQL lines (e.g., twist_ref icon updates)
  const postInsertSQLLines: string[] = [];

  // Process threads
  let threadOrder = Date.now();
  if (data.threads) {
    for (const thread of data.threads) {
      threadOrder = processThread(
        thread,
        userId,
        baseDate,
        threadOrder,
        contactIdMap,
        priorityIdMap,
        sourceIdMap,
        twistIdMap,
        threadIdMap,
        threads,
        threadTags,
        generatedLinks,
        schedules,
        notes,
        noteTags,
        fileUploads,
        postInsertSQLLines
      );
    }
  }

  // Generate SQL

  // Placeholder users (for contacts with user_id that need to exist in the user table)
  const contactsWithUserId = contacts.filter((c) => c.user_id !== null);
  if (contactsWithUserId.length > 0) {
    lines.push("-- Placeholder users for shared priority members");
    for (const c of contactsWithUserId) {
      lines.push(
        `INSERT INTO public."user" (id, email, name) VALUES (${sqlString(c.user_id)}, ${sqlString(c.email)}, ${sqlString(c.name)}) ON CONFLICT (id) DO NOTHING;`
      );
    }
    lines.push("");
  }

  // Contacts
  if (contacts.length > 0) {
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
        )}, NOW() - INTERVAL '1 second', NOW())${comma}`
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

  // Priority settings (key/value format)
  if (prioritySettings.length > 0) {
    lines.push("-- Priority settings");
    lines.push(
      "INSERT INTO priority_setting (priority_id, user_id, key, value, updated_at)"
    );
    lines.push("VALUES");
    const settingRows: string[] = [];
    for (const ps of prioritySettings) {
      if (ps.color !== null) {
        settingRows.push(
          `  (${sqlString(ps.priority_id)}, ${sqlString(ps.user_id)}, 'color', '${ps.color}'::jsonb, NOW())`
        );
      }
      if (ps.path !== null) {
        settingRows.push(
          `  (${sqlString(ps.priority_id)}, ${sqlString(ps.user_id)}, 'path', ${sqlString(JSON.stringify(ps.path))}::jsonb, NOW())`
        );
      }
      if (ps.pomodoro !== null) {
        settingRows.push(
          `  (${sqlString(ps.priority_id)}, ${sqlString(ps.user_id)}, 'pomodoro', '${ps.pomodoro}'::jsonb, NOW())`
        );
      }
    }
    lines.push(settingRows.join(",\n") + ";");
    lines.push("");
  }

  // Sources (twist_admin + twist + priority_twist)
  if (sourceSQLLines.length > 0) {
    lines.push("-- Sources (twist_admin + twist + priority_twist)");
    lines.push(...sourceSQLLines);
    lines.push("");
  }

  // Threads
  if (threads.length > 0) {
    lines.push("-- Threads");
    lines.push(
      "INSERT INTO thread (id, created_by, priority_id, draft, private, title, preview, icon, archived_at, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < threads.length; i++) {
      const t = threads[i];
      const comma = i < threads.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(t.id)}, ${sqlString(t.created_by)}, ${sqlString(
          t.priority_id
        )}, ${t.draft}, ${t.private}, ${sqlString(t.title)}, ${sqlString(
          t.preview
        )}, ${sqlString(t.icon)}, ${sqlString(t.archived_at)}, NOW(), NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Links
  if (generatedLinks.length > 0) {
    lines.push("-- Links");
    lines.push(
      "INSERT INTO link (id, thread_id, priority_id, type, status, title, source_url, assignee_id, author_id, created_by, source_created_at, meta, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < generatedLinks.length; i++) {
      const l = generatedLinks[i];
      const comma = i < generatedLinks.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(l.id)}, ${sqlString(l.thread_id)}, ${sqlString(
          l.priority_id
        )}, ${sqlString(l.type)}, ${sqlString(l.status)}, ${sqlString(
          l.title
        )}, ${sqlString(l.source_url)}, ${sqlString(
          l.assignee_id
        )}, ${sqlString(l.author_id)}, ${sqlString(
          l.created_by
        )}, ${sqlString(l.source_created_at)}, ${
          l.meta ? sqlString(l.meta) : "NULL"
        }, NOW(), NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Schedules
  if (schedules.length > 0) {
    lines.push("-- Schedules");
    lines.push(
      'INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", duration, recurrence_rule, created_at, updated_at)'
    );
    lines.push("VALUES");
    for (let i = 0; i < schedules.length; i++) {
      const s = schedules[i];
      const comma = i < schedules.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(s.id)}, ${sqlString(s.thread_id)}, ${sqlString(
          s.link_id
        )}, ${sqlString(s.user_id)}, ${
          s.order !== null ? s.order : "NULL"
        }, ${s.at ? sqlString(s.at) : "NULL"}, ${
          s.on ? sqlString(s.on) : "NULL"
        }, ${s.duration ? sqlString(s.duration) : "NULL"}, ${sqlString(
          s.recurrence_rule
        )}, NOW(), NOW())${comma}`
      );
    }
    lines.push("");
  }

  // Notes
  if (notes.length > 0) {
    lines.push("-- Notes");
    lines.push(
      "INSERT INTO note (id, thread_id, author_id, created_by, draft, private, content, actions, mentions, source_created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < notes.length; i++) {
      const n = notes[i];
      const comma = i < notes.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(n.id)}, ${sqlString(n.thread_id)}, ${sqlString(
          n.author_id
        )}, ${sqlString(n.created_by)}, ${n.draft}, ${n.private}, ${sqlString(
          n.content
        )}, ${
          n.actions ? sqlString(n.actions) : "NULL"
        }, ${
          n.mentions ? sqlString(n.mentions) : "NULL"
        }, ${sqlString(n.source_created_at)}, ${sqlString(
          n.updated_at
        )})${comma}`
      );
    }
    lines.push("");
  }

  // Thread tags
  if (threadTags.length > 0) {
    lines.push("-- Thread tags");
    lines.push(
      "INSERT INTO thread_tag (actor_id, thread_id, tag_id, occurrence, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < threadTags.length; i++) {
      const tt = threadTags[i];
      const comma = i < threadTags.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(tt.actor_id)}, ${sqlString(tt.thread_id)}, ${
          tt.tag_id
        }, ${sqlString(tt.occurrence)}, NOW())${comma}`
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

  // Post-insert updates (e.g., twist_ref icon resolution)
  if (postInsertSQLLines.length > 0) {
    lines.push("-- Post-insert updates (twist icon resolution)");
    lines.push(...postInsertSQLLines);
    lines.push("");
  }

  lines.push("COMMIT;");

  return { sql: lines.join("\n"), fileUploads };
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
  contactIdMap?: RefMap<string>,
  contacts?: GeneratedContact[]
) {
  const id = generateUUID();
  idMap[priority.ref] = id;

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

  outUsers.push({
    priority_id: id,
    user_id: userId,
  });

  if (priority.settings) {
    outSettings.push({
      priority_id: id,
      user_id: userId,
      color: priority.settings.color ?? null,
      path: priority.settings.path_override ?? null,
      pomodoro: priority.settings.pomodoro_duration ?? null,
    });
  }

  // Handle shared_with — add priority_user rows for contacts with user_ids
  if (priority.shared_with && contactIdMap && contacts) {
    for (const ref of priority.shared_with) {
      const contact = contacts.find((c) => c.id === contactIdMap[ref]);
      if (contact?.user_id) {
        outUsers.push({
          priority_id: id,
          user_id: contact.user_id,
        });
      }
    }
  }

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
        contactIdMap,
        contacts
      );
    }
  }
}

function processSource(
  source: SeedSource,
  userId: string,
  priorityIdMap: RefMap<string>,
  sourceIdMap: RefMap<string>,
  outLines: string[]
) {
  const priorityId = priorityIdMap[source.priority_ref];
  const priorityTwistId = generateUUID();

  sourceIdMap[source.ref] = priorityTwistId;

  // Build permissions JSONB
  const permissions = JSON.stringify({
    _providers: [
      {
        linkTypes: source.link_types.map((lt) => ({
          type: lt.type,
          label: lt.label,
          logo: lt.logo,
          ...(lt.logo_dark ? { logoDark: lt.logo_dark } : {}),
        })),
      },
    ],
  });

  // Use DO block to chain bigint IDENTITY inserts
  outLines.push(`DO $$`);
  outLines.push(`DECLARE`);
  outLines.push(`  v_twist_admin_id bigint;`);
  outLines.push(`  v_twist_id bigint;`);
  outLines.push(`BEGIN`);
  outLines.push(
    `  INSERT INTO twist_admin (user_id) VALUES (${sqlString(userId)}) RETURNING id INTO v_twist_admin_id;`
  );
  outLines.push(
    `  INSERT INTO twist (twist_admin_id, environment, name, version, is_source, permissions, logo_url, logo_url_dark)`
  );
  outLines.push(
    `  VALUES (v_twist_admin_id, 'personal', ${sqlString(source.name)}, '0.0.0', true, ${sqlString(permissions)}::jsonb, ${sqlString(source.logo ?? null)}, ${sqlString(source.logo_dark ?? null)})`
  );
  outLines.push(`  RETURNING id INTO v_twist_id;`);
  outLines.push(
    `  INSERT INTO priority_twist (id, twist_id, owner_id, priority_id, name, config)`
  );
  outLines.push(
    `  VALUES (${sqlString(priorityTwistId)}, v_twist_id, ${sqlString(userId)}, ${sqlString(priorityId)}, ${sqlString(source.name)}, '{}'::jsonb);`
  );
  outLines.push(
    `  INSERT INTO priority_twist_connection (priority_twist_id, user_id, provider, actor_id)`
  );
  outLines.push(
    `  VALUES (${sqlString(priorityTwistId)}, ${sqlString(userId)}, 'seed', ${sqlString(userId)});`
  );
  outLines.push(`END $$;`);
}

function processTwist(
  twist: SeedTwist,
  userId: string,
  priorityIdMap: RefMap<string>,
  twistIdMap: RefMap<string>,
  outLines: string[]
) {
  const priorityId = priorityIdMap[twist.priority_ref];
  const priorityTwistId = generateUUID();

  twistIdMap[twist.ref] = priorityTwistId;

  // Use DO block to chain bigint IDENTITY inserts (same pattern as processSource)
  outLines.push(`DO $$`);
  outLines.push(`DECLARE`);
  outLines.push(`  v_twist_admin_id bigint;`);
  outLines.push(`  v_twist_id bigint;`);
  outLines.push(`BEGIN`);
  outLines.push(
    `  INSERT INTO twist_admin (user_id) VALUES (${sqlString(userId)}) RETURNING id INTO v_twist_admin_id;`
  );
  outLines.push(
    `  INSERT INTO twist (twist_admin_id, environment, name, version, is_source, permissions, logo_url, logo_url_dark)`
  );
  outLines.push(
    `  VALUES (v_twist_admin_id, 'personal', ${sqlString(twist.name)}, '0.0.0', false, NULL, ${sqlString(twist.logo ?? null)}, ${sqlString(twist.logo_dark ?? null)})`
  );
  outLines.push(`  RETURNING id INTO v_twist_id;`);
  outLines.push(
    `  INSERT INTO priority_twist (id, twist_id, owner_id, priority_id, name, config)`
  );
  outLines.push(
    `  VALUES (${sqlString(priorityTwistId)}, v_twist_id, ${sqlString(userId)}, ${sqlString(priorityId)}, ${sqlString(twist.name)}, '{}'::jsonb);`
  );
  outLines.push(`END $$;`);
}

function processThread(
  thread: Thread,
  userId: string,
  baseDate: string,
  order: number,
  contactIdMap: RefMap<string>,
  priorityIdMap: RefMap<string>,
  sourceIdMap: RefMap<string>,
  twistIdMap: RefMap<string>,
  threadIdMap: RefMap<string>,
  outThreads: GeneratedThread[],
  outTags: GeneratedThreadTag[],
  outLinks: GeneratedLink[],
  outSchedules: GeneratedSchedule[],
  outNotes: GeneratedNote[],
  outNoteTags: GeneratedNoteTag[],
  outFileUploads: SeedFileUpload[],
  outPostInsertSQL: string[]
): number {
  const id = generateUUID();
  if (thread.ref) {
    threadIdMap[thread.ref] = id;
  }

  const priorityId = priorityIdMap[thread.priority_ref];

  outThreads.push({
    id,
    created_by: userId,
    priority_id: priorityId,
    draft: thread.draft ?? false,
    private: thread.private ?? false,
    title: thread.title ?? null,
    preview: null,
    icon: thread.icon ?? null,
    archived_at: thread.archived_at
      ? parseDateOffset(baseDate, thread.archived_at).toISOString()
      : null,
  });

  // If twist_ref is set, emit a post-insert UPDATE to resolve the twist icon
  if (thread.twist_ref) {
    const ptId = twistIdMap[thread.twist_ref];
    if (ptId) {
      outPostInsertSQL.push(
        `UPDATE thread SET icon = 'twist:' || (SELECT twist_id::text FROM priority_twist WHERE id = ${sqlString(ptId)}) WHERE id = ${sqlString(id)};`
      );
    }
  }

  // Process schedule
  if (thread.schedule) {
    const sched = thread.schedule;
    const at = sched.at ? parseTimestampRange(baseDate, sched.at) : null;
    const on = sched.on ? parseDateRange(baseDate, sched.on) : null;

    // todo:true or date-only (on without at) -> user schedule (to-do with order)
    // todo:false or timed (at) -> shared schedule (event, no order)
    const isTodo =
      sched.todo === true || (sched.todo !== false && !sched.at && !!sched.on);

    outSchedules.push({
      id: generateUUID(),
      thread_id: id,
      link_id: null,
      user_id: isTodo ? userId : null,
      order: isTodo ? order++ : null,
      at,
      on,
      duration: sched.duration ?? null,
      recurrence_rule: sched.recurrence_rule ?? null,
    });
  }

  // Process links
  if (thread.links) {
    const createdAt = thread.created
      ? parseDateOffset(baseDate, thread.created).toISOString()
      : new Date().toISOString();

    for (const link of thread.links) {
      processLink(
        link,
        id,
        priorityId,
        createdAt,
        contactIdMap,
        sourceIdMap,
        outLinks
      );
    }
  }

  // Process tags
  if (thread.tags) {
    for (const [tagName, actors] of Object.entries(thread.tags)) {
      const tagId = TAG_IDS[tagName];
      if (tagId < 100) {
        continue;
      }
      for (const actorRef of actors) {
        const actorId = contactIdMap[actorRef];
        outTags.push({
          actor_id: actorId,
          thread_id: id,
          tag_id: tagId,
          occurrence: null,
        });
      }
    }
  }

  // Process notes
  if (thread.notes) {
    for (const note of thread.notes) {
      processNote(
        note,
        id,
        userId,
        baseDate,
        contactIdMap,
        outNotes,
        outNoteTags
      );

      // Collect file actions for R2 upload
      if (note.actions) {
        for (const action of note.actions) {
          if (
            action.type === "file" &&
            action.fileId &&
            action.fileName &&
            action.mimeType
          ) {
            outFileUploads.push({
              fileId: action.fileId as string,
              fileName: action.fileName as string,
              mimeType: action.mimeType as string,
              priorityId,
              userId,
            });
          }
        }
      }
    }
  }

  return order;
}

function processLink(
  link: SeedLink,
  threadId: string,
  priorityId: string,
  sourceCreatedAt: string,
  contactIdMap: RefMap<string>,
  sourceIdMap: RefMap<string>,
  outLinks: GeneratedLink[]
) {
  const id = generateUUID();

  const assigneeId = link.assignee_ref
    ? contactIdMap[link.assignee_ref]
    : null;
  const authorId = link.author_ref ? contactIdMap[link.author_ref] : null;
  const createdBy = link.source_ref ? sourceIdMap[link.source_ref] : null;

  outLinks.push({
    id,
    thread_id: threadId,
    priority_id: priorityId,
    type: link.type ?? null,
    status: link.status ?? null,
    title: link.title ?? null,
    source_url: link.source_url ?? null,
    assignee_id: assigneeId,
    author_id: authorId,
    created_by: createdBy,
    source_created_at: sourceCreatedAt,
    meta: link.meta ? JSON.stringify(link.meta) : null,
  });
}

function processNote(
  note: Note,
  threadId: string,
  userId: string,
  baseDate: string,
  contactIdMap: RefMap<string>,
  outNotes: GeneratedNote[],
  outNoteTags: GeneratedNoteTag[]
) {
  const id = generateUUID();

  const authorId = note.author_ref
    ? contactIdMap[note.author_ref]
    : contactIdMap["user"];

  const createdAt = parseDateOffset(baseDate, note.created).toISOString();

  const mentions = note.mentions
    ? `{${note.mentions.map((ref) => contactIdMap[ref]).join(",")}}`
    : null;

  outNotes.push({
    id,
    thread_id: threadId,
    author_id: authorId,
    created_by: userId,
    draft: note.draft ?? false,
    private: note.private ?? false,
    content: note.content ?? note.note ?? null,
    actions: note.actions ? JSON.stringify(note.actions) : null,
    mentions,
    source_created_at: createdAt,
    updated_at: createdAt,
  });

  if (note.tags) {
    for (const [tagName, actors] of Object.entries(note.tags)) {
      const tagId = TAG_IDS[tagName];
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

  if (hoursStr && minutesStr) {
    result.setHours(parseInt(hoursStr, 10));
    result.setMinutes(parseInt(minutesStr, 10));
  }

  return result;
}

function parseTimestampRange(baseDate: string, range: string): string {
  const parts = range.split("/").map((s) => s.trim());
  const start = parts[0];
  const end = parts[1] || start;
  const startDate = parseDateOffset(baseDate, start);
  const endDate = parseDateOffset(baseDate, end);
  return `[${startDate.toISOString()},${endDate.toISOString()})`;
}

function parseDateRange(baseDate: string, range: string): string {
  const parts = range.split("/").map((s) => s.trim());
  const start = parts[0];
  const startDate = parseDateOffset(baseDate, start);

  const startStr = startDate.toISOString().split("T")[0];

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

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ============================================================================
// Run
// ============================================================================

main();
