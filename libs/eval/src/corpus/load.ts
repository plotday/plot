import { readdir, readFile, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { parse as parseYaml } from "yaml";

import {
  CorpusCasesFileSchema,
  CorpusTrainingSetSchema,
  CorpusWorldSchema,
  type Corpus,
  type CorpusCase,
  type CorpusEmbedding,
  type CorpusTrainingSet,
  type CorpusWorld,
} from "./schema";

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

type SlugLookups = {
  priority: Map<string, string>;
  contact: Map<string, string>;
  group: Map<string, string>;
  priorityIds: Set<string>;
  contactIds: Set<string>;
  groupIds: Set<string>;
};

async function loadYamlText(path: string): Promise<unknown> {
  const text = await readFile(path, "utf-8");
  return parseYaml(text);
}

export async function loadCorpus(rootDir: string): Promise<Corpus> {
  const worldRaw = await loadYamlText(join(rootDir, "world.yaml"));
  const world: CorpusWorld = CorpusWorldSchema.parse(worldRaw);
  const lookups = buildLookups(world);

  const trainingSets = await loadTrainingSets(rootDir, lookups);
  const cases = await loadCases(rootDir, lookups);

  const embeddings = new Map<string, CorpusEmbedding>(
    world.embeddings.map((e) => [e.ref, e])
  );

  validateCorpus(world, trainingSets, cases, embeddings);

  return {
    name: world.name,
    rootDir,
    world,
    trainingSets,
    cases,
    embeddings,
  };
}

function buildLookups(world: CorpusWorld): SlugLookups {
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
  };
}

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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function resolveTrainingSetRefs(raw: any, lookups: SlugLookups, file: string): any {
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
function resolveCasesRefs(raw: any, lookups: SlugLookups, file: string): any {
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

async function loadTrainingSets(
  rootDir: string,
  lookups: SlugLookups
): Promise<CorpusTrainingSet[]> {
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

  const out: CorpusTrainingSet[] = [];
  for (const file of files) {
    const fileStem = basename(file).replace(/\.ya?ml$/, "");
    const raw = await loadYamlText(join(trainingsDir, file));
    const resolved = resolveTrainingSetRefs(raw, lookups, `trainings/${file}`);
    const ts = CorpusTrainingSetSchema.parse(resolved);
    out.push({ ...ts, name: ts.name ?? fileStem });
  }
  if (out.length === 0) {
    throw new Error(
      `Corpus at ${rootDir} has no training sets. Add at least one file under trainings/.`
    );
  }
  return out;
}

async function loadCases(rootDir: string, lookups: SlugLookups): Promise<CorpusCase[]> {
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
  const raw = await loadYamlText(casesFile);
  const resolved = resolveCasesRefs(raw, lookups, "cases.yaml");
  const parsed = CorpusCasesFileSchema.parse(resolved);
  return parsed.cases;
}

function validateCorpus(
  world: CorpusWorld,
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

  void world; // unused now that resolve handles cross-refs
}
