import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

import { parse as parseYaml } from "yaml";

import { CORPUS_DIR } from "./paths";
import type { CorpusSpec, Difficulty, SpecAssertion, SpecNotMatch } from "./types";

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;
const DIFFICULTIES: readonly Difficulty[] = ["easy", "medium", "hard"];

function fail(filePath: string, message: string): never {
  throw new Error(`${filePath}: ${message}`);
}

function requireString(
  filePath: string,
  meta: Record<string, unknown>,
  key: string
): string {
  const value = meta[key];
  if (typeof value !== "string" || !value.trim()) {
    fail(filePath, `frontmatter field "${key}" must be a non-empty string`);
  }
  return value.trim();
}

function compileOrFail(filePath: string, source: string, where: string): void {
  try {
    new RegExp(source);
  } catch (e) {
    fail(filePath, `invalid regex in ${where}: /${source}/ (${String(e)})`);
  }
}

export function parseSpecFile(raw: string, filePath: string): CorpusSpec {
  const match = raw.match(FRONTMATTER);
  if (!match) fail(filePath, "missing YAML frontmatter (--- ... ---)");
  const meta = (parseYaml(match[1]) ?? {}) as Record<string, unknown>;

  const id = requireString(filePath, meta, "id");
  const category = requireString(filePath, meta, "category");
  const difficulty = requireString(filePath, meta, "difficulty") as Difficulty;
  if (!DIFFICULTIES.includes(difficulty)) {
    fail(filePath, `difficulty must be one of ${DIFFICULTIES.join("/")}`);
  }

  const rawAssertions = (meta.assertions ?? []) as Array<Record<string, unknown>>;
  const assertions: SpecAssertion[] = rawAssertions.map((a, i) => {
    if (typeof a?.match !== "string" || typeof a?.why !== "string") {
      fail(filePath, `assertions[${i}] needs string "match" and "why"`);
    }
    compileOrFail(filePath, a.match, `assertions[${i}].match`);
    return { match: a.match, why: a.why };
  });

  const rawNotMatch = (meta.notMatch ?? []) as Array<Record<string, unknown>>;
  const notMatch: SpecNotMatch[] = rawNotMatch.map((n, i) => {
    if (typeof n?.pattern !== "string" || typeof n?.why !== "string") {
      fail(filePath, `notMatch[${i}] needs string "pattern" and "why"`);
    }
    compileOrFail(filePath, n.pattern, `notMatch[${i}].pattern`);
    return { pattern: n.pattern, why: n.why };
  });

  const allowDeps = ((meta.allowDeps ?? []) as unknown[]).map((d) => String(d));

  const body = raw.slice(match[0].length).trim();
  if (!body) fail(filePath, "spec body is empty");

  return {
    id,
    category,
    difficulty,
    assertions,
    notMatch,
    allowDeps,
    body,
    corpusHash: createHash("sha256").update(raw).digest("hex"),
    filePath,
  };
}

export async function loadCorpus(dir: string = CORPUS_DIR): Promise<CorpusSpec[]> {
  const files = (await readdir(dir)).filter((f) => f.endsWith(".md")).sort();
  const specs: CorpusSpec[] = [];
  for (const file of files) {
    const full = join(dir, file);
    specs.push(parseSpecFile(await readFile(full, "utf-8"), full));
  }
  const seen = new Set<string>();
  for (const spec of specs) {
    if (seen.has(spec.id)) throw new Error(`duplicate corpus id: ${spec.id}`);
    seen.add(spec.id);
  }
  return specs;
}
