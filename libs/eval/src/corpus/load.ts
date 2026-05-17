import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { parse as parseYaml } from "yaml";

import {
  CorpusCaseSchema,
  CorpusWorldSchema,
  type Corpus,
  type CorpusCase,
  type CorpusEmbedding,
  type CorpusWorld,
} from "./schema";

async function loadYaml<T>(path: string, parse: (raw: unknown) => T): Promise<T> {
  const text = await readFile(path, "utf-8");
  const data = parseYaml(text);
  return parse(data);
}

export async function loadCorpus(rootDir: string): Promise<Corpus> {
  const worldPath = join(rootDir, "world.yaml");
  const world: CorpusWorld = await loadYaml(worldPath, (raw) =>
    CorpusWorldSchema.parse(raw)
  );

  const casesDir = join(rootDir, "cases");
  let cases: CorpusCase[] = [];
  try {
    const dirStat = await stat(casesDir);
    if (dirStat.isDirectory()) {
      const files = (await readdir(casesDir))
        .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"))
        .sort();
      cases = await Promise.all(
        files.map((file) =>
          loadYaml(join(casesDir, file), (raw) => CorpusCaseSchema.parse(raw))
        )
      );
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }

  const embeddings = new Map<string, CorpusEmbedding>(
    world.embeddings.map((e) => [e.ref, e])
  );

  validateCorpus(world, cases, embeddings);

  return { name: world.name, rootDir, world, cases, embeddings };
}

function validateCorpus(
  world: CorpusWorld,
  cases: CorpusCase[],
  embeddings: Map<string, CorpusEmbedding>
): void {
  const priorityIds = new Set(world.priorities.map((p) => p.id));
  const contactIds = new Set(world.contacts.map((c) => c.id));
  const groupIds = new Set(world.groups.map((g) => g.id));

  // Every training thread filed_to_priority must reference a known priority.
  for (const t of world.training_threads) {
    if (!priorityIds.has(t.filed_to_priority)) {
      throw new Error(
        `world.training_threads[${t.id}]: filed_to_priority ${t.filed_to_priority} not declared in priorities`
      );
    }
    for (const c of t.contacts) {
      if (!contactIds.has(c)) {
        throw new Error(
          `world.training_threads[${t.id}]: contact ${c} not declared in contacts`
        );
      }
    }
    for (const g of t.groups) {
      if (!groupIds.has(g)) {
        throw new Error(
          `world.training_threads[${t.id}]: group ${g} not declared in groups`
        );
      }
    }
    if (t.embedding_ref && !embeddings.has(t.embedding_ref)) {
      throw new Error(
        `world.training_threads[${t.id}]: embedding_ref ${t.embedding_ref} not declared in embeddings`
      );
    }
  }

  // Every case's referenced ids must exist.
  const seenCaseIds = new Set<string>();
  for (const cs of cases) {
    if (seenCaseIds.has(cs.id)) {
      throw new Error(`Duplicate case id: ${cs.id}`);
    }
    seenCaseIds.add(cs.id);
    for (const c of cs.candidate.contacts) {
      if (!contactIds.has(c)) {
        throw new Error(`case[${cs.id}]: contact ${c} not declared in contacts`);
      }
    }
    for (const g of cs.candidate.groups) {
      if (!groupIds.has(g)) {
        throw new Error(`case[${cs.id}]: group ${g} not declared in groups`);
      }
    }
    if (cs.candidate.embedding_ref && !embeddings.has(cs.candidate.embedding_ref)) {
      throw new Error(
        `case[${cs.id}]: embedding_ref ${cs.candidate.embedding_ref} not declared in embeddings`
      );
    }
    if (cs.labels.gold && !priorityIds.has(cs.labels.gold)) {
      throw new Error(`case[${cs.id}]: gold ${cs.labels.gold} not declared in priorities`);
    }
    if (cs.labels.expected && !priorityIds.has(cs.labels.expected)) {
      throw new Error(
        `case[${cs.id}]: expected ${cs.labels.expected} not declared in priorities`
      );
    }
  }
}
