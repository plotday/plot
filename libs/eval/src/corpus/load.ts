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

async function loadYaml<T>(path: string, parse: (raw: unknown) => T): Promise<T> {
  const text = await readFile(path, "utf-8");
  const data = parseYaml(text);
  return parse(data);
}

export async function loadCorpus(rootDir: string): Promise<Corpus> {
  const world: CorpusWorld = await loadYaml(
    join(rootDir, "world.yaml"),
    (raw) => CorpusWorldSchema.parse(raw)
  );

  const trainingSets = await loadTrainingSets(rootDir);
  const cases = await loadCases(rootDir);

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

async function loadTrainingSets(rootDir: string): Promise<CorpusTrainingSet[]> {
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
    const ts = await loadYaml(join(trainingsDir, file), (raw) =>
      CorpusTrainingSetSchema.parse(raw)
    );
    out.push({ ...ts, name: ts.name ?? fileStem });
  }
  if (out.length === 0) {
    throw new Error(
      `Corpus at ${rootDir} has no training sets. Add at least one file under trainings/.`
    );
  }
  return out;
}

async function loadCases(rootDir: string): Promise<CorpusCase[]> {
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
  const parsed = await loadYaml(casesFile, (raw) =>
    CorpusCasesFileSchema.parse(raw)
  );
  return parsed.cases;
}

function validateCorpus(
  world: CorpusWorld,
  trainingSets: CorpusTrainingSet[],
  cases: CorpusCase[],
  embeddings: Map<string, CorpusEmbedding>
): void {
  const priorityIds = new Set(world.priorities.map((p) => p.id));
  const contactIds = new Set(world.contacts.map((c) => c.id));
  const groupIds = new Set(world.groups.map((g) => g.id));

  // Training-set names must be unique.
  const seenTs = new Set<string>();
  for (const ts of trainingSets) {
    if (seenTs.has(ts.name)) {
      throw new Error(`Duplicate training set name: ${ts.name}`);
    }
    seenTs.add(ts.name);

    for (const t of ts.threads) {
      if (!priorityIds.has(t.filed_to_priority)) {
        throw new Error(
          `training-set[${ts.name}].threads[${t.id}]: filed_to_priority ${t.filed_to_priority} not declared in world.priorities`
        );
      }
      for (const c of t.contacts) {
        if (!contactIds.has(c)) {
          throw new Error(
            `training-set[${ts.name}].threads[${t.id}]: contact ${c} not declared in world.contacts`
          );
        }
      }
      for (const g of t.groups) {
        if (!groupIds.has(g)) {
          throw new Error(
            `training-set[${ts.name}].threads[${t.id}]: group ${g} not declared in world.groups`
          );
        }
      }
      if (t.embedding_ref && !embeddings.has(t.embedding_ref)) {
        throw new Error(
          `training-set[${ts.name}].threads[${t.id}]: embedding_ref ${t.embedding_ref} not declared in world.embeddings`
        );
      }
    }
  }

  // Case ids unique; refs resolved.
  const seenCaseIds = new Set<string>();
  for (const cs of cases) {
    if (seenCaseIds.has(cs.id)) {
      throw new Error(`Duplicate case id: ${cs.id}`);
    }
    seenCaseIds.add(cs.id);
    for (const c of cs.candidate.contacts) {
      if (!contactIds.has(c)) {
        throw new Error(`case[${cs.id}]: contact ${c} not declared in world.contacts`);
      }
    }
    for (const g of cs.candidate.groups) {
      if (!groupIds.has(g)) {
        throw new Error(`case[${cs.id}]: group ${g} not declared in world.groups`);
      }
    }
    if (cs.candidate.embedding_ref && !embeddings.has(cs.candidate.embedding_ref)) {
      throw new Error(
        `case[${cs.id}]: embedding_ref ${cs.candidate.embedding_ref} not declared in world.embeddings`
      );
    }
    if (cs.labels.gold && !priorityIds.has(cs.labels.gold)) {
      throw new Error(`case[${cs.id}]: gold ${cs.labels.gold} not declared in world.priorities`);
    }
    if (cs.labels.expected && !priorityIds.has(cs.labels.expected)) {
      throw new Error(
        `case[${cs.id}]: expected ${cs.labels.expected} not declared in world.priorities`
      );
    }
  }
}
