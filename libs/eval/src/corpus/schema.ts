import { z } from "zod";

// ===========================================================================
// Internal corpus model
//
// The loader accepts BOTH schema_version 1 and 2 YAML documents and
// normalizes them into this single internal model (a superset of v2).
// Later pipeline stages (sandbox, runner, report) consume only this model.
//
// v1 compatibility invariant: v1's `author` field was written into
// thread.created_by by the sandbox, so v1 normalization resolves it into
// `createdByOverride` (NOT `authorContactId`); all v2-only fields get inert
// defaults (null / [] / unset) so v1 corpora behave exactly as before.
// ===========================================================================

export type CorpusTeam = { slug: string; id: number; name: string };

export type CorpusConnection = {
  slug: string;
  id: string;
  provider: string;
  /** Resolved contact uuid (the connection's actor for org-key purposes). */
  accountContactId: string;
  teamId: number | null;
};

export type CorpusSubscription = { plan: string; status: string } | null;

export type CorpusEmbedding = {
  ref: string;
  vector: number[]; // length 384
  /** Embedding provenance; null = legacy/unknown (v1 entries). */
  source: "thread-title" | "note-content" | "local-title" | null;
};

export type CorpusThreadBase = {
  id: string;
  title: string;
  topic: string | null;
  contacts: string[];
  groups: string[];
  embedding_ref: string | null;
  /** Contact uuid → thread.author_id (v2 `author`). Always null for v1. */
  authorContactId: string | null;
  /** Connection uuid → thread.created_by + thread.twist_id. Always null for v1. */
  connectionId: string | null;
  /**
   * Explicit thread.created_by value. v1 normalization puts the resolved v1
   * `author` here (contact uuid, hashed twist:* uuid, or arbitrary uuid
   * passthrough); v2 documents may set it via `created_by_override` as a
   * handcrafted escape hatch. Takes precedence over connectionId.
   */
  createdByOverride: string | null;
  facets: Record<string, string> | null;
  createdAt: Date | null;
};

export type CorpusTrainingThread = CorpusThreadBase & {
  filedToPriority: string;
  movedAt: Date | null;
};

export type CorpusNegative = {
  /** Must be a training or negative thread id in the same training set. */
  threadId: string;
  priorityId: string;
  source: "moved_out" | "deselected";
  createdAt: Date | null;
};

export type CorpusTrainingSet = {
  name: string;
  description: string;
  threads: CorpusTrainingThread[];
  /** Threads that exist only as negative evidence (no thread_priority filing). */
  negativeThreads: CorpusThreadBase[];
  /** Mirror of thread_priority_negative rows. */
  negatives: CorpusNegative[];
};

export type CorpusCase = {
  id: string;
  sourceThreadId: string | null;
  tags: string[];
  asOf: Date | null;
  description: string;
  /**
   * Candidate thread shape. Same as CorpusThreadBase minus `id` (the runner
   * derives the candidate thread id from the case id); `createdAt` is
   * optional and currently never set by the loader (cases use `asOf`).
   */
  candidate: Omit<CorpusThreadBase, "id" | "createdAt"> & {
    createdAt?: Date | null;
  };
  labels: {
    gold: string | null;
    goldRationale: string;
    /** "human" backfilled when gold is set and the YAML field is absent. */
    goldSource: "human" | "llm-proposed" | null;
    expected: string | null;
    expectedStage: string | null;
    expectedRecordedAt: string | null;
  };
  notes: string;
};

export type CorpusPriority = {
  slug: string;
  id: string;
  path: string;
  title: string;
  key: string | null;
  description: string | null;
  /** Free-form jsonb passthrough for priority.facet_filters. */
  facetFilters: Record<string, unknown> | null;
};

export type CorpusWorld = {
  name: string;
  description: string;
  schemaVersion: 1 | 2;
  source: {
    kind: "prod-extract" | "handcrafted";
    extracted_at: string | null;
    anonymized: boolean;
  };
  user: {
    id: string;
    email: string;
    primary_contact_id: string | null;
    subscription: CorpusSubscription;
  };
  teams: CorpusTeam[];
  connections: CorpusConnection[];
  priorities: CorpusPriority[];
  contacts: {
    slug: string | null;
    id: string;
    email: string | null;
    name: string | null;
    linked_to_user: boolean;
  }[];
  groups: { slug: string | null; id: string; title: string }[];
  channels: {
    id: number;
    connectionId: string | null;
    default_priority_id: string | null;
  }[];
  embeddings: CorpusEmbedding[];
};

export type Corpus = {
  name: string;
  rootDir: string;
  world: CorpusWorld;
  trainingSets: CorpusTrainingSet[];
  cases: CorpusCase[];
  embeddings: Map<string, CorpusEmbedding>;
};

// ===========================================================================
// YAML document schemas (zod) — shared building blocks
// ===========================================================================

const uuid = z.string().uuid();
const slug = z
  .string()
  .min(1)
  .regex(/^[a-z0-9][a-z0-9-]*$/, "lowercase kebab-case slug");
const ltreePath = z
  .string()
  .regex(/^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$/, "ltree-shaped path");

/**
 * YAML timestamps may parse as strings or JS Dates depending on the format
 * and yaml-package schema. Accept both; load.ts normalizes to Date and
 * throws with context on invalid date strings.
 */
const timestamp = z.union([z.string(), z.date()]);
export type RawTimestamp = z.infer<typeof timestamp>;

const ContactSchema = z.object({
  slug: slug.nullable().default(null),
  id: uuid,
  email: z.string().email().nullable().default(null),
  name: z.string().nullable().default(null),
  linked_to_user: z.boolean().default(false),
});

const GroupSchema = z.object({
  slug: slug.nullable().default(null),
  id: uuid,
  title: z.string(),
});

const SourceSchema = z
  .object({
    kind: z.enum(["prod-extract", "handcrafted"]),
    extracted_at: z.string().nullable().default(null),
    anonymized: z.boolean().default(false),
  })
  .default({ kind: "handcrafted", extracted_at: null, anonymized: false });

// ===========================================================================
// v1 document schemas (must stay byte-compatible with existing corpora)
// ===========================================================================

export const EmbeddingDocV1Schema = z.object({
  ref: z.string().min(1),
  vector: z.array(z.number()).length(384),
});

const PriorityDocV1Schema = z.object({
  slug,
  id: uuid,
  path: ltreePath,
  title: z.string(),
  key: z.string().nullable().default(null),
});

const TrainingThreadDocV1Schema = z.object({
  id: uuid,
  title: z.string(),
  topic: z.string().nullable().default(null),
  contacts: z.array(uuid).default([]),
  groups: z.array(uuid).default([]),
  embedding_ref: z.string().nullable().default(null),
  filed_to_priority: uuid,
  author: z.string().nullable().default(null),
});

const ChannelDocV1Schema = z.object({
  id: z.number().int(),
  default_priority_id: uuid.nullable().default(null),
});

export const WorldDocV1Schema = z.object({
  name: z.string().min(1),
  description: z.string().default(""),
  schema_version: z.literal(1),
  source: SourceSchema,
  user: z.object({
    id: uuid,
    email: z.string().email().default("eval-user@example.test"),
    primary_contact_id: uuid.nullable().default(null),
  }),
  priorities: z.array(PriorityDocV1Schema).min(1),
  contacts: z.array(ContactSchema).default([]),
  groups: z.array(GroupSchema).default([]),
  embeddings: z.array(EmbeddingDocV1Schema).default([]),
  channels: z.array(ChannelDocV1Schema).default([]),
});

export const TrainingSetDocV1Schema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().default(""),
  threads: z.array(TrainingThreadDocV1Schema).default([]),
});

export const CaseDocV1Schema = z.object({
  id: z.string().min(1),
  description: z.string().default(""),
  candidate: z.object({
    title: z.string(),
    topic: z.string().nullable().default(null),
    contacts: z.array(uuid).default([]),
    groups: z.array(uuid).default([]),
    embedding_ref: z.string().nullable().default(null),
    author: z.string().nullable().default(null),
  }),
  labels: z.object({
    gold: uuid.nullable().default(null),
    gold_rationale: z.string().default(""),
    expected: uuid.nullable().default(null),
    expected_stage: z
      .enum([
        "topic_shortcircuit",
        "keyed_priority",
        "channel_default",
        "scoring",
        "priority_prefix",
        "root_fallback",
        "none",
      ])
      .nullable()
      .default(null),
    expected_recorded_at: z.string().nullable().default(null),
  }),
  notes: z.string().default(""),
});

export const CasesFileDocV1Schema = z.object({
  cases: z.array(CaseDocV1Schema),
});

export type WorldDocV1 = z.infer<typeof WorldDocV1Schema>;
export type TrainingSetDocV1 = z.infer<typeof TrainingSetDocV1Schema>;
export type CaseDocV1 = z.infer<typeof CaseDocV1Schema>;

// ===========================================================================
// v2 document schemas
//
// Unlike v1 (where slug refs are rewritten in the raw document before zod
// parsing), v2 documents are zod-parsed first with refs as plain strings;
// load.ts resolves refs while mapping into the internal model.
// ===========================================================================

export const EmbeddingDocV2Schema = z.object({
  ref: z.string().min(1),
  vector: z.array(z.number()).length(384),
  source: z
    .enum(["thread-title", "note-content", "local-title"])
    .nullable()
    .default(null),
});

/** Optional sibling embeddings.yaml: { embeddings: [...] }. */
export const EmbeddingsFileDocSchema = z.object({
  embeddings: z.array(EmbeddingDocV2Schema).default([]),
});

const PriorityDocV2Schema = PriorityDocV1Schema.extend({
  description: z.string().nullable().default(null),
  facet_filters: z.record(z.string(), z.unknown()).nullable().default(null),
});

const TeamDocSchema = z.object({
  slug,
  id: z.number().int(),
  name: z.string(),
});

const ConnectionDocSchema = z.object({
  slug,
  id: uuid,
  provider: z.string().min(1),
  /** Contact ref (slug or uuid). */
  account_contact: z.string().min(1),
  /** Team ref (slug or numeric id), or null. */
  team: z.union([z.string(), z.number().int()]).nullable().default(null),
});

const ChannelDocV2Schema = z.object({
  id: z.number().int(),
  /** Connection ref (slug or uuid). Required in v2. */
  connection: z.string().min(1),
  default_priority_id: uuid.nullable().default(null),
});

export const WorldDocV2Schema = z.object({
  name: z.string().min(1),
  description: z.string().default(""),
  schema_version: z.literal(2),
  source: SourceSchema,
  user: z.object({
    id: uuid,
    email: z.string().email().default("eval-user@example.test"),
    primary_contact_id: uuid.nullable().default(null),
    subscription: z
      .object({ plan: z.string().min(1), status: z.string().min(1) })
      .nullable()
      .default(null),
  }),
  teams: z.array(TeamDocSchema).default([]),
  connections: z.array(ConnectionDocSchema).default([]),
  priorities: z.array(PriorityDocV2Schema).min(1),
  contacts: z.array(ContactSchema).default([]),
  groups: z.array(GroupSchema).default([]),
  embeddings: z.array(EmbeddingDocV2Schema).default([]),
  channels: z.array(ChannelDocV2Schema).default([]),
});

const threadBaseDocV2Fields = {
  id: uuid,
  title: z.string(),
  topic: z.string().nullable().default(null),
  /** Contact refs (slug or uuid). */
  contacts: z.array(z.string()).default([]),
  /** Group refs (slug or uuid). */
  groups: z.array(z.string()).default([]),
  embedding_ref: z.string().nullable().default(null),
  /** Contact ref → authorContactId (thread.author_id). */
  author: z.string().nullable().default(null),
  /** Connection ref → connectionId (thread.created_by + twist_id). */
  connection: z.string().nullable().default(null),
  /** uuid | twist:slug | contact slug — created_by escape hatch. */
  created_by_override: z.string().nullable().default(null),
  facets: z.record(z.string(), z.string()).nullable().default(null),
  created_at: timestamp.nullable().default(null),
};

const TrainingThreadDocV2Schema = z.object({
  ...threadBaseDocV2Fields,
  filed_to_priority: z.string().min(1),
  moved_at: timestamp.nullable().default(null),
});

const NegativeThreadDocV2Schema = z.object(threadBaseDocV2Fields);

const NegativeDocV2Schema = z.object({
  /** Must be a training or negative thread id in the same file. */
  thread: uuid,
  priority: z.string().min(1),
  source: z.enum(["moved_out", "deselected"]),
  created_at: timestamp.nullable().default(null),
});

export const TrainingSetDocV2Schema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().default(""),
  threads: z.array(TrainingThreadDocV2Schema).default([]),
  negative_threads: z.array(NegativeThreadDocV2Schema).default([]),
  negatives: z.array(NegativeDocV2Schema).default([]),
});

export const CaseDocV2Schema = z.object({
  id: z.string().min(1),
  source_thread_id: uuid.nullable().default(null),
  tags: z.array(z.string()).default([]),
  as_of: timestamp.nullable().default(null),
  description: z.string().default(""),
  candidate: z.object({
    title: z.string(),
    topic: z.string().nullable().default(null),
    contacts: z.array(z.string()).default([]),
    groups: z.array(z.string()).default([]),
    embedding_ref: z.string().nullable().default(null),
    author: z.string().nullable().default(null),
    connection: z.string().nullable().default(null),
    created_by_override: z.string().nullable().default(null),
    facets: z.record(z.string(), z.string()).nullable().default(null),
  }),
  labels: z.object({
    gold: z.string().nullable().default(null),
    gold_rationale: z.string().default(""),
    // `.optional()` (no default): absent → undefined → backfill from gold;
    // explicit null stays null.
    gold_source: z.enum(["human", "llm-proposed"]).nullable().optional(),
    expected: z.string().nullable().default(null),
    /** Widened from the v1 enum: TS-cascade stage names are free strings. */
    expected_stage: z.string().nullable().default(null),
    expected_recorded_at: timestamp.nullable().default(null),
  }),
  notes: z.string().default(""),
});

export const CasesFileDocV2Schema = z.object({
  cases: z.array(CaseDocV2Schema),
});

export type WorldDocV2 = z.infer<typeof WorldDocV2Schema>;
export type TrainingSetDocV2 = z.infer<typeof TrainingSetDocV2Schema>;
export type CaseDocV2 = z.infer<typeof CaseDocV2Schema>;
