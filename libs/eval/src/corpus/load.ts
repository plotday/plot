import { readdir, readFile, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { parse as parseYaml } from "yaml";

import {
  CasesFileDocV1Schema,
  CasesFileDocV2Schema,
  EmbeddingsFileDocSchema,
  TrainingSetDocV1Schema,
  TrainingSetDocV2Schema,
  WorldDocV1Schema,
  WorldDocV2Schema,
  type CaseDocV1,
  type CaseDocV2,
  type Corpus,
  type CorpusCase,
  type CorpusEmbedding,
  type CorpusThreadBase,
  type CorpusTrainingSet,
  type CorpusWorld,
  type RawTimestamp,
  type TrainingSetDocV1,
  type TrainingSetDocV2,
  type WorldDocV1,
  type WorldDocV2,
} from "./schema";

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

type SlugLookups = {
  priority: Map<string, string>;
  contact: Map<string, string>;
  group: Map<string, string>;
  priorityIds: Set<string>;
  contactIds: Set<string>;
  groupIds: Set<string>;
  // v2-only (empty for v1 documents):
  team: Map<string, number>;
  teamIds: Set<number>;
  connection: Map<string, string>;
  connectionIds: Set<string>;
};

async function loadYamlText(path: string): Promise<unknown> {
  const text = await readFile(path, "utf-8");
  return parseYaml(text);
}

export async function loadCorpus(rootDir: string): Promise<Corpus> {
  const worldRaw = await loadYamlText(join(rootDir, "world.yaml"));
  const isV2 =
    typeof worldRaw === "object" &&
    worldRaw !== null &&
    (worldRaw as Record<string, unknown>).schema_version === 2;

  let world: CorpusWorld;
  let lookups: SlugLookups;
  if (isV2) {
    const doc = WorldDocV2Schema.parse(worldRaw);
    lookups = buildLookupsV2(doc);
    world = normalizeWorldV2(doc, lookups);
  } else {
    const doc = WorldDocV1Schema.parse(worldRaw);
    lookups = buildLookupsV1(doc);
    world = normalizeWorldV1(doc);
  }

  await mergeSiblingEmbeddings(rootDir, world);

  const trainingSets = isV2
    ? await loadTrainingSetsV2(rootDir, lookups)
    : await loadTrainingSetsV1(rootDir, lookups);
  const cases = isV2
    ? await loadCasesV2(rootDir, lookups)
    : await loadCasesV1(rootDir, lookups);

  const embeddings = new Map<string, CorpusEmbedding>(
    world.embeddings.map((e) => [e.ref, e])
  );

  validateCorpus(trainingSets, cases, embeddings);

  return {
    name: world.name,
    rootDir,
    world,
    trainingSets,
    cases,
    embeddings,
  };
}

// ===========================================================================
// Slug lookups
// ===========================================================================

function buildBaseLookups(world: {
  priorities: { slug: string; id: string }[];
  contacts: { slug: string | null; id: string }[];
  groups: { slug: string | null; id: string }[];
}): SlugLookups {
  const priority = new Map<string, string>();
  for (const p of world.priorities) {
    if (priority.has(p.slug)) {
      throw new Error(`Duplicate priority slug in world.yaml: ${p.slug}`);
    }
    priority.set(p.slug, p.id);
  }

  const contact = new Map<string, string>();
  for (const c of world.contacts) {
    if (c.slug) {
      if (contact.has(c.slug)) {
        throw new Error(`Duplicate contact slug in world.yaml: ${c.slug}`);
      }
      contact.set(c.slug, c.id);
    }
  }

  const group = new Map<string, string>();
  for (const g of world.groups) {
    if (g.slug) {
      if (group.has(g.slug)) {
        throw new Error(`Duplicate group slug in world.yaml: ${g.slug}`);
      }
      group.set(g.slug, g.id);
    }
  }

  return {
    priority,
    contact,
    group,
    priorityIds: new Set(world.priorities.map((p) => p.id)),
    contactIds: new Set(world.contacts.map((c) => c.id)),
    groupIds: new Set(world.groups.map((g) => g.id)),
    team: new Map(),
    teamIds: new Set(),
    connection: new Map(),
    connectionIds: new Set(),
  };
}

function buildLookupsV1(world: WorldDocV1): SlugLookups {
  return buildBaseLookups(world);
}

function buildLookupsV2(world: WorldDocV2): SlugLookups {
  const lookups = buildBaseLookups(world);

  for (const t of world.teams) {
    if (lookups.team.has(t.slug)) {
      throw new Error(`Duplicate team slug in world.yaml: ${t.slug}`);
    }
    if (lookups.teamIds.has(t.id)) {
      throw new Error(`Duplicate team id in world.yaml: ${t.id}`);
    }
    lookups.team.set(t.slug, t.id);
    lookups.teamIds.add(t.id);
  }

  for (const c of world.connections) {
    if (lookups.connection.has(c.slug)) {
      throw new Error(`Duplicate connection slug in world.yaml: ${c.slug}`);
    }
    if (lookups.connectionIds.has(c.id)) {
      throw new Error(`Duplicate connection id in world.yaml: ${c.id}`);
    }
    lookups.connection.set(c.slug, c.id);
    lookups.connectionIds.add(c.id);
  }

  return lookups;
}

// ===========================================================================
// Reference resolution
// ===========================================================================

function resolveRef(
  ref: string,
  kind: "priority" | "contact" | "group",
  lookups: SlugLookups,
  context: string
): string {
  if (UUID_RE.test(ref)) {
    const ids =
      kind === "priority"
        ? lookups.priorityIds
        : kind === "contact"
          ? lookups.contactIds
          : lookups.groupIds;
    if (!ids.has(ref)) {
      throw new Error(`${context}: ${kind} id ${ref} not declared in world.yaml`);
    }
    return ref;
  }
  const map =
    kind === "priority"
      ? lookups.priority
      : kind === "contact"
        ? lookups.contact
        : lookups.group;
  const resolved = map.get(ref);
  if (!resolved) {
    throw new Error(
      `${context}: unknown ${kind} slug "${ref}". Declare it in world.yaml or reference by UUID.`
    );
  }
  return resolved;
}

function resolveConnectionRef(
  ref: string,
  lookups: SlugLookups,
  context: string
): string {
  if (UUID_RE.test(ref)) {
    if (!lookups.connectionIds.has(ref)) {
      throw new Error(
        `${context}: connection id ${ref} not declared in world.yaml`
      );
    }
    return ref;
  }
  const resolved = lookups.connection.get(ref);
  if (!resolved) {
    throw new Error(
      `${context}: unknown connection slug "${ref}". Declare it in world.yaml or reference by UUID.`
    );
  }
  return resolved;
}

function resolveTeamRef(
  ref: string | number | null,
  lookups: SlugLookups,
  context: string
): number | null {
  if (ref === null) return null;
  if (typeof ref === "number") {
    if (!lookups.teamIds.has(ref)) {
      throw new Error(`${context}: team id ${ref} not declared in world.yaml`);
    }
    return ref;
  }
  const resolved = lookups.team.get(ref);
  if (resolved === undefined) {
    throw new Error(
      `${context}: unknown team slug "${ref}". Declare it in world.yaml teams.`
    );
  }
  return resolved;
}

/**
 * v1 `author` / v2 `created_by_override` resolution. Contact slug → contact
 * uuid; `twist:` prefix → deterministic synthetic uuid; arbitrary UUIDs pass
 * through WITHOUT a world-membership check (prod extracts reference
 * twist_instance ids that have no world row — kris relies on this).
 */
function resolveAuthor(
  author: string | null,
  lookups: SlugLookups,
  context: string
): string | null {
  if (author === null) return null;
  if (UUID_RE.test(author)) return author;
  if (author.startsWith("twist:")) {
    // Twist authors are not represented in the eval sandbox. Hash the slug
    // into a deterministic UUID so equality comparisons across neighbors and
    // the candidate still work; the value will never match a real
    // twist_instance row, which is fine — the twist-author shortcut
    // gracefully no-ops when nothing matches.
    return slugToUuid(author);
  }
  const contactId = lookups.contact.get(author);
  if (!contactId) {
    throw new Error(
      `${context}: unknown author "${author}". Declare it as a contact slug in world.yaml, prefix with "twist:" for twist authors, or use a UUID.`
    );
  }
  return contactId;
}

function slugToUuid(slug: string): string {
  let h1 = 0x811c9dc5;
  let h2 = 0xdeadbeef;
  for (let i = 0; i < slug.length; i++) {
    h1 = Math.imul(h1 ^ slug.charCodeAt(i), 16777619) >>> 0;
    h2 = Math.imul(h2 ^ slug.charCodeAt(i), 2654435761) >>> 0;
  }
  const a = h1.toString(16).padStart(8, "0");
  const b = (h2 >>> 16).toString(16).padStart(4, "0");
  const c = ((h1 ^ h2) >>> 16).toString(16).padStart(4, "0");
  const d = (h2 & 0xffff).toString(16).padStart(4, "0");
  const e = (
    (Math.imul(h1, h2) >>> 0).toString(16) +
    (Math.imul(h1 ^ h2, 0x9e3779b1) >>> 0).toString(16)
  )
    .padStart(12, "0")
    .slice(0, 12);
  return `${a}-${b}-4${c.slice(1)}-8${d.slice(1)}-${e}`;
}

/** Normalizes a YAML timestamp (string or JS Date) into a Date. */
function toDate(value: RawTimestamp | null, context: string): Date | null {
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new Error(`${context}: invalid timestamp "${String(value)}"`);
  }
  return date;
}

/** Normalizes a YAML timestamp into a string (for as-recorded fields). */
function toTimestampString(
  value: RawTimestamp | null,
  context: string
): string | null {
  const date = toDate(value, context);
  if (date === null) return null;
  return typeof value === "string" ? value : date.toISOString();
}

// ===========================================================================
// World normalization
// ===========================================================================

function normalizeWorldV1(doc: WorldDocV1): CorpusWorld {
  return {
    name: doc.name,
    description: doc.description,
    schemaVersion: 1,
    source: doc.source,
    user: {
      id: doc.user.id,
      email: doc.user.email,
      primary_contact_id: doc.user.primary_contact_id,
      subscription: null,
    },
    teams: [],
    connections: [],
    priorities: doc.priorities.map((p) => ({
      ...p,
      description: null,
      facetFilters: null,
    })),
    contacts: doc.contacts,
    groups: doc.groups,
    channels: doc.channels.map((ch) => ({
      id: ch.id,
      // v1 has no connection model; the sandbox keeps its placeholder
      // twist_instance hack for these.
      connectionId: null,
      default_priority_id: ch.default_priority_id,
    })),
    embeddings: doc.embeddings.map((e) => ({ ...e, source: null })),
  };
}

function normalizeWorldV2(doc: WorldDocV2, lookups: SlugLookups): CorpusWorld {
  return {
    name: doc.name,
    description: doc.description,
    schemaVersion: 2,
    source: doc.source,
    user: {
      id: doc.user.id,
      email: doc.user.email,
      primary_contact_id: doc.user.primary_contact_id,
      subscription: doc.user.subscription,
    },
    teams: doc.teams,
    connections: doc.connections.map((c) => ({
      slug: c.slug,
      id: c.id,
      provider: c.provider,
      accountContactId: resolveRef(
        c.account_contact,
        "contact",
        lookups,
        `world.yaml#connections[${c.slug}].account_contact`
      ),
      teamId: resolveTeamRef(
        c.team,
        lookups,
        `world.yaml#connections[${c.slug}].team`
      ),
    })),
    priorities: doc.priorities.map((p) => ({
      slug: p.slug,
      id: p.id,
      path: p.path,
      title: p.title,
      key: p.key,
      description: p.description,
      facetFilters: p.facet_filters,
    })),
    contacts: doc.contacts,
    groups: doc.groups,
    channels: doc.channels.map((ch) => ({
      id: ch.id,
      connectionId: resolveConnectionRef(
        ch.connection,
        lookups,
        `world.yaml#channels[${ch.id}].connection`
      ),
      default_priority_id: ch.default_priority_id,
    })),
    embeddings: doc.embeddings,
  };
}

/**
 * Merges an optional sibling embeddings.yaml ({ embeddings: [...] }) into
 * world.embeddings. Seeders write bulky vectors there so world.yaml stays
 * reviewable. A ref declared in both files is an error.
 */
async function mergeSiblingEmbeddings(
  rootDir: string,
  world: CorpusWorld
): Promise<void> {
  const siblingPath = join(rootDir, "embeddings.yaml");
  let raw: unknown;
  try {
    raw = await loadYamlText(siblingPath);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return;
    throw err;
  }
  const parsed = EmbeddingsFileDocSchema.parse(raw);
  const known = new Set(world.embeddings.map((e) => e.ref));
  for (const e of parsed.embeddings) {
    if (known.has(e.ref)) {
      throw new Error(
        `embeddings.yaml: duplicate embedding ref "${e.ref}" (also declared in world.yaml)`
      );
    }
    known.add(e.ref);
    world.embeddings.push(e);
  }
}

// ===========================================================================
// v1 loading (resolve refs in the raw document, then zod-parse — preserved
// exactly from the original v1 loader so v1 corpora behave identically)
// ===========================================================================

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function resolveTrainingSetRefsV1(raw: any, lookups: SlugLookups, file: string): any {
  if (!raw || typeof raw !== "object") return raw;
  return {
    ...raw,
    threads: Array.isArray(raw.threads)
      ? raw.threads.map((t: Record<string, unknown>, i: number) => ({
          ...t,
          contacts: Array.isArray(t.contacts)
            ? (t.contacts as string[]).map((c) =>
                resolveRef(c, "contact", lookups, `${file}#threads[${i}].contacts`)
              )
            : t.contacts,
          groups: Array.isArray(t.groups)
            ? (t.groups as string[]).map((g) =>
                resolveRef(g, "group", lookups, `${file}#threads[${i}].groups`)
              )
            : t.groups,
          filed_to_priority:
            typeof t.filed_to_priority === "string"
              ? resolveRef(
                  t.filed_to_priority,
                  "priority",
                  lookups,
                  `${file}#threads[${i}].filed_to_priority`
                )
              : t.filed_to_priority,
          author:
            typeof t.author === "string"
              ? resolveAuthor(
                  t.author,
                  lookups,
                  `${file}#threads[${i}].author`
                )
              : (t.author ?? null),
        }))
      : raw.threads,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function resolveCasesRefsV1(raw: any, lookups: SlugLookups, file: string): any {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.cases)) return raw;
  return {
    ...raw,
    cases: raw.cases.map((cs: Record<string, unknown>, i: number) => {
      const candidate = (cs.candidate ?? {}) as Record<string, unknown>;
      const labels = (cs.labels ?? {}) as Record<string, unknown>;
      const caseRef = `${file}#cases[${i}](${(cs.id as string) ?? "?"})`;
      return {
        ...cs,
        candidate: {
          ...candidate,
          contacts: Array.isArray(candidate.contacts)
            ? (candidate.contacts as string[]).map((c) =>
                resolveRef(c, "contact", lookups, `${caseRef}.candidate.contacts`)
              )
            : candidate.contacts,
          groups: Array.isArray(candidate.groups)
            ? (candidate.groups as string[]).map((g) =>
                resolveRef(g, "group", lookups, `${caseRef}.candidate.groups`)
              )
            : candidate.groups,
          author:
            typeof candidate.author === "string"
              ? resolveAuthor(
                  candidate.author,
                  lookups,
                  `${caseRef}.candidate.author`
                )
              : (candidate.author ?? null),
        },
        labels: {
          ...labels,
          gold:
            typeof labels.gold === "string"
              ? resolveRef(labels.gold, "priority", lookups, `${caseRef}.labels.gold`)
              : labels.gold,
          expected:
            typeof labels.expected === "string"
              ? resolveRef(
                  labels.expected,
                  "priority",
                  lookups,
                  `${caseRef}.labels.expected`
                )
              : labels.expected,
        },
      };
    }),
  };
}

/**
 * v1 → internal model. The v1 `author` was written into thread.created_by by
 * the sandbox, so it maps to createdByOverride; authorContactId stays null
 * (v1 never modeled thread.author_id). All other v2 fields get inert
 * defaults so a normalized v1 corpus behaves exactly as before.
 */
function normalizeTrainingSetV1(
  doc: TrainingSetDocV1,
  name: string
): CorpusTrainingSet {
  return {
    name,
    description: doc.description,
    threads: doc.threads.map((t) => ({
      id: t.id,
      title: t.title,
      topic: t.topic,
      contacts: t.contacts,
      groups: t.groups,
      embedding_ref: t.embedding_ref,
      authorContactId: null,
      connectionId: null,
      createdByOverride: t.author,
      facets: null,
      createdAt: null,
      filedToPriority: t.filed_to_priority,
      movedAt: null,
    })),
    negativeThreads: [],
    negatives: [],
  };
}

function normalizeCaseV1(doc: CaseDocV1): CorpusCase {
  return {
    id: doc.id,
    sourceThreadId: null,
    tags: [],
    asOf: null,
    description: doc.description,
    candidate: {
      title: doc.candidate.title,
      topic: doc.candidate.topic,
      contacts: doc.candidate.contacts,
      groups: doc.candidate.groups,
      embedding_ref: doc.candidate.embedding_ref,
      authorContactId: null,
      connectionId: null,
      createdByOverride: doc.candidate.author,
      facets: null,
    },
    labels: {
      gold: doc.labels.gold,
      goldRationale: doc.labels.gold_rationale,
      goldSource: doc.labels.gold !== null ? "human" : null,
      expected: doc.labels.expected,
      expectedStage: doc.labels.expected_stage,
      expectedRecordedAt: doc.labels.expected_recorded_at,
    },
    notes: doc.notes,
  };
}

async function loadTrainingSetsV1(
  rootDir: string,
  lookups: SlugLookups
): Promise<CorpusTrainingSet[]> {
  const out: CorpusTrainingSet[] = [];
  for (const { file, fileStem, raw } of await readTrainingFiles(rootDir)) {
    const resolved = resolveTrainingSetRefsV1(raw, lookups, `trainings/${file}`);
    const ts = TrainingSetDocV1Schema.parse(resolved);
    out.push(normalizeTrainingSetV1(ts, ts.name ?? fileStem));
  }
  requireTrainingSets(rootDir, out);
  return out;
}

async function loadCasesV1(
  rootDir: string,
  lookups: SlugLookups
): Promise<CorpusCase[]> {
  const raw = await readCasesFile(rootDir);
  const resolved = resolveCasesRefsV1(raw, lookups, "cases.yaml");
  const parsed = CasesFileDocV1Schema.parse(resolved);
  return parsed.cases.map(normalizeCaseV1);
}

// ===========================================================================
// v2 loading (zod-parse first, resolve refs while mapping)
// ===========================================================================

type ThreadDocV2 = TrainingSetDocV2["negative_threads"][number];

function normalizeThreadBaseV2(
  t: ThreadDocV2,
  lookups: SlugLookups,
  context: string
): CorpusThreadBase {
  return {
    id: t.id,
    title: t.title,
    topic: t.topic,
    contacts: t.contacts.map((c) =>
      resolveRef(c, "contact", lookups, `${context}.contacts`)
    ),
    groups: t.groups.map((g) =>
      resolveRef(g, "group", lookups, `${context}.groups`)
    ),
    embedding_ref: t.embedding_ref,
    authorContactId:
      t.author !== null
        ? resolveRef(t.author, "contact", lookups, `${context}.author`)
        : null,
    connectionId:
      t.connection !== null
        ? resolveConnectionRef(t.connection, lookups, `${context}.connection`)
        : null,
    createdByOverride: resolveAuthor(
      t.created_by_override,
      lookups,
      `${context}.created_by_override`
    ),
    facets: t.facets,
    createdAt: toDate(t.created_at, `${context}.created_at`),
  };
}

function normalizeTrainingSetV2(
  doc: TrainingSetDocV2,
  name: string,
  lookups: SlugLookups,
  file: string
): CorpusTrainingSet {
  const threads = doc.threads.map((t, i) => ({
    ...normalizeThreadBaseV2(t, lookups, `${file}#threads[${i}]`),
    filedToPriority: resolveRef(
      t.filed_to_priority,
      "priority",
      lookups,
      `${file}#threads[${i}].filed_to_priority`
    ),
    movedAt: toDate(t.moved_at, `${file}#threads[${i}].moved_at`),
  }));

  const negativeThreads = doc.negative_threads.map((t, i) =>
    normalizeThreadBaseV2(t, lookups, `${file}#negative_threads[${i}]`)
  );

  const knownThreadIds = new Set<string>([
    ...threads.map((t) => t.id),
    ...negativeThreads.map((t) => t.id),
  ]);
  const negatives = doc.negatives.map((n, i) => {
    if (!knownThreadIds.has(n.thread)) {
      throw new Error(
        `${file}#negatives[${i}]: thread ${n.thread} is not a training thread or negative_thread in this file`
      );
    }
    return {
      threadId: n.thread,
      priorityId: resolveRef(
        n.priority,
        "priority",
        lookups,
        `${file}#negatives[${i}].priority`
      ),
      source: n.source,
      createdAt: toDate(n.created_at, `${file}#negatives[${i}].created_at`),
    };
  });

  return {
    name,
    description: doc.description,
    threads,
    negativeThreads,
    negatives,
  };
}

function normalizeCaseV2(doc: CaseDocV2, lookups: SlugLookups): CorpusCase {
  const context = `cases.yaml#case(${doc.id})`;
  const gold =
    doc.labels.gold !== null
      ? resolveRef(doc.labels.gold, "priority", lookups, `${context}.labels.gold`)
      : null;
  return {
    id: doc.id,
    sourceThreadId: doc.source_thread_id,
    tags: doc.tags,
    asOf: toDate(doc.as_of, `${context}.as_of`),
    description: doc.description,
    candidate: {
      title: doc.candidate.title,
      topic: doc.candidate.topic,
      contacts: doc.candidate.contacts.map((c) =>
        resolveRef(c, "contact", lookups, `${context}.candidate.contacts`)
      ),
      groups: doc.candidate.groups.map((g) =>
        resolveRef(g, "group", lookups, `${context}.candidate.groups`)
      ),
      embedding_ref: doc.candidate.embedding_ref,
      authorContactId:
        doc.candidate.author !== null
          ? resolveRef(
              doc.candidate.author,
              "contact",
              lookups,
              `${context}.candidate.author`
            )
          : null,
      connectionId:
        doc.candidate.connection !== null
          ? resolveConnectionRef(
              doc.candidate.connection,
              lookups,
              `${context}.candidate.connection`
            )
          : null,
      createdByOverride: resolveAuthor(
        doc.candidate.created_by_override,
        lookups,
        `${context}.candidate.created_by_override`
      ),
      facets: doc.candidate.facets,
    },
    labels: {
      gold,
      goldRationale: doc.labels.gold_rationale,
      // Absent (undefined) backfills from gold: every pre-v2 label was
      // human-recorded. Explicit null stays null.
      goldSource:
        doc.labels.gold_source !== undefined
          ? doc.labels.gold_source
          : gold !== null
            ? "human"
            : null,
      expected:
        doc.labels.expected !== null
          ? resolveRef(
              doc.labels.expected,
              "priority",
              lookups,
              `${context}.labels.expected`
            )
          : null,
      expectedStage: doc.labels.expected_stage,
      expectedRecordedAt: toTimestampString(
        doc.labels.expected_recorded_at,
        `${context}.labels.expected_recorded_at`
      ),
    },
    notes: doc.notes,
  };
}

async function loadTrainingSetsV2(
  rootDir: string,
  lookups: SlugLookups
): Promise<CorpusTrainingSet[]> {
  const out: CorpusTrainingSet[] = [];
  for (const { file, fileStem, raw } of await readTrainingFiles(rootDir)) {
    const doc = TrainingSetDocV2Schema.parse(raw);
    out.push(
      normalizeTrainingSetV2(doc, doc.name ?? fileStem, lookups, `trainings/${file}`)
    );
  }
  requireTrainingSets(rootDir, out);
  return out;
}

async function loadCasesV2(
  rootDir: string,
  lookups: SlugLookups
): Promise<CorpusCase[]> {
  const raw = await readCasesFile(rootDir);
  const parsed = CasesFileDocV2Schema.parse(raw);
  return parsed.cases.map((c) => normalizeCaseV2(c, lookups));
}

// ===========================================================================
// Shared file IO + validation
// ===========================================================================

async function readTrainingFiles(
  rootDir: string
): Promise<{ file: string; fileStem: string; raw: unknown }[]> {
  const trainingsDir = join(rootDir, "trainings");
  let files: string[] = [];
  try {
    const dirStat = await stat(trainingsDir);
    if (!dirStat.isDirectory()) return [];
    files = (await readdir(trainingsDir))
      .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"))
      .sort();
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    return [];
  }

  const out: { file: string; fileStem: string; raw: unknown }[] = [];
  for (const file of files) {
    const fileStem = basename(file).replace(/\.ya?ml$/, "");
    const raw = await loadYamlText(join(trainingsDir, file));
    out.push({ file, fileStem, raw });
  }
  return out;
}

function requireTrainingSets(rootDir: string, sets: CorpusTrainingSet[]): void {
  if (sets.length === 0) {
    throw new Error(
      `Corpus at ${rootDir} has no training sets. Add at least one file under trainings/.`
    );
  }
}

async function readCasesFile(rootDir: string): Promise<unknown> {
  const casesFile = join(rootDir, "cases.yaml");
  try {
    await stat(casesFile);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(
        `Corpus at ${rootDir} is missing cases.yaml. Expected a top-level { cases: [...] } document.`
      );
    }
    throw err;
  }
  return loadYamlText(casesFile);
}

function validateCorpus(
  trainingSets: CorpusTrainingSet[],
  cases: CorpusCase[],
  embeddings: Map<string, CorpusEmbedding>
): void {
  // Slugs and IDs are already cross-checked during resolve. This pass only
  // catches embedding refs and duplicate names/case-ids.
  const seenTs = new Set<string>();
  for (const ts of trainingSets) {
    if (seenTs.has(ts.name)) {
      throw new Error(`Duplicate training set name: ${ts.name}`);
    }
    seenTs.add(ts.name);
    for (const t of ts.threads) {
      if (t.embedding_ref && !embeddings.has(t.embedding_ref)) {
        throw new Error(
          `training-set[${ts.name}].threads[${t.id}]: embedding_ref ${t.embedding_ref} not declared in world.embeddings`
        );
      }
    }
    for (const t of ts.negativeThreads) {
      if (t.embedding_ref && !embeddings.has(t.embedding_ref)) {
        throw new Error(
          `training-set[${ts.name}].negative_threads[${t.id}]: embedding_ref ${t.embedding_ref} not declared in world.embeddings`
        );
      }
    }
  }

  const seenCaseIds = new Set<string>();
  for (const cs of cases) {
    if (seenCaseIds.has(cs.id)) {
      throw new Error(`Duplicate case id: ${cs.id}`);
    }
    seenCaseIds.add(cs.id);
    if (cs.candidate.embedding_ref && !embeddings.has(cs.candidate.embedding_ref)) {
      throw new Error(
        `case[${cs.id}]: embedding_ref ${cs.candidate.embedding_ref} not declared in world.embeddings`
      );
    }
  }
}
