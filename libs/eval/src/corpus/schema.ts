import { z } from "zod";

const uuid = z.string().uuid();
const slug = z
  .string()
  .min(1)
  .regex(/^[a-z0-9][a-z0-9-]*$/, "lowercase kebab-case slug");

export const CorpusEmbeddingSchema = z.object({
  ref: z.string().min(1),
  vector: z.array(z.number()).length(384),
});

const PrioritySchema = z.object({
  slug,
  id: uuid,
  path: z.string().regex(/^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$/, "ltree-shaped path"),
  title: z.string(),
  key: z.string().nullable().default(null),
});

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

const TrainingThreadSchema = z.object({
  id: uuid,
  title: z.string(),
  topic: z.string().nullable().default(null),
  contacts: z.array(uuid).default([]),
  groups: z.array(uuid).default([]),
  embedding_ref: z.string().nullable().default(null),
  filed_to_priority: uuid,
});

const ChannelSchema = z.object({
  id: z.number().int(),
  default_priority_id: uuid.nullable().default(null),
});

export const CorpusWorldSchema = z.object({
  name: z.string().min(1),
  description: z.string().default(""),
  schema_version: z.literal(1),
  source: z
    .object({
      kind: z.enum(["prod-extract", "handcrafted"]),
      extracted_at: z.string().nullable().default(null),
      anonymized: z.boolean().default(false),
    })
    .default({ kind: "handcrafted", extracted_at: null, anonymized: false }),
  user: z.object({
    id: uuid,
    email: z.string().email().default("eval-user@example.test"),
    primary_contact_id: uuid.nullable().default(null),
  }),
  priorities: z.array(PrioritySchema).min(1),
  contacts: z.array(ContactSchema).default([]),
  groups: z.array(GroupSchema).default([]),
  embeddings: z.array(CorpusEmbeddingSchema).default([]),
  channels: z.array(ChannelSchema).default([]),
});

/**
 * A named training set. Lives in trainings/<name>.yaml. World data
 * (priorities, contacts, etc.) is shared across all training sets.
 */
export const CorpusTrainingSetSchema = z.object({
  name: z.string().min(1).optional(),
  description: z.string().default(""),
  threads: z.array(TrainingThreadSchema).default([]),
});

export const CorpusCaseSchema = z.object({
  id: z.string().min(1),
  description: z.string().default(""),
  candidate: z.object({
    title: z.string(),
    topic: z.string().nullable().default(null),
    contacts: z.array(uuid).default([]),
    groups: z.array(uuid).default([]),
    embedding_ref: z.string().nullable().default(null),
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

/** cases.yaml — a single file holding all cases for the corpus. */
export const CorpusCasesFileSchema = z.object({
  cases: z.array(CorpusCaseSchema),
});

export type CorpusEmbedding = z.infer<typeof CorpusEmbeddingSchema>;
export type CorpusWorld = z.infer<typeof CorpusWorldSchema>;
export type CorpusCase = z.infer<typeof CorpusCaseSchema>;
export type CorpusTrainingSet = z.infer<typeof CorpusTrainingSetSchema> & {
  /** Filled in by the loader from the file stem when not declared inline. */
  name: string;
};

export type Corpus = {
  name: string;
  rootDir: string;
  world: CorpusWorld;
  trainingSets: CorpusTrainingSet[];
  cases: CorpusCase[];
  embeddings: Map<string, CorpusEmbedding>;
};
