// libs/db/scripts/onboarding/parse.ts
import { readFileSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";
import { parse as parseYaml } from "yaml";
import type { NoteDef, ThreadDef, OnboardingModel } from "./model.ts";

const FRONTMATTER_RE = /^---\n([\s\S]*?)\n---\n?/;
const ORDER_RE = /^(\d+)-/;
const NOTE_HEADING_RE = /^## note:\s*(\S+)\s*$/;

export function parseThreadFile(filename: string, raw: string): ThreadDef {
  const fmMatch = FRONTMATTER_RE.exec(raw);
  if (!fmMatch) {
    throw new Error(`${filename}: missing frontmatter (--- block)`);
  }
  const fm = parseYaml(fmMatch[1]) as {
    key?: string;
    title?: string;
    preview?: string;
    state?: { active?: boolean; importance?: number; dateOffset?: number };
  };
  if (!fm.key) throw new Error(`${filename}: frontmatter missing 'key'`);
  if (!fm.title) throw new Error(`${filename}: frontmatter missing 'title'`);
  if (fm.preview == null) throw new Error(`${filename}: frontmatter missing 'preview'`);

  const orderMatch = ORDER_RE.exec(basename(filename));
  if (!orderMatch) {
    throw new Error(`${filename}: filename must start with a numeric order prefix (e.g. 02-)`);
  }
  const order = Number(orderMatch[1]);

  const state = {
    active: fm.state?.active ?? false,
    importance: fm.state?.importance ?? null,
    dateOffset: fm.state?.dateOffset ?? null,
  };

  const body = raw.slice(fmMatch[0].length);
  const notes = parseNotes(filename, body);
  if (notes.length === 0) throw new Error(`${filename}: no '## note: <key>' sections found`);

  return { key: fm.key, order, title: fm.title, preview: fm.preview, state, notes };
}

function parseNotes(filename: string, body: string): NoteDef[] {
  const lines = body.split("\n");
  const notes: NoteDef[] = [];
  let currentKey: string | null = null;
  let buffer: string[] = [];
  const flush = () => {
    if (currentKey !== null) {
      notes.push({ key: currentKey, content: buffer.join("\n").trim() });
    }
  };
  for (const line of lines) {
    const h = NOTE_HEADING_RE.exec(line);
    if (h) {
      flush();
      currentKey = h[1];
      buffer = [];
    } else {
      buffer.push(line);
    }
  }
  flush();
  const seen = new Set<string>();
  for (const n of notes) {
    if (seen.has(n.key)) throw new Error(`${filename}: duplicate note key '${n.key}'`);
    seen.add(n.key);
  }
  return notes;
}

export function parseDir(dir: string): ThreadDef[] {
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".md") && /^\d+-/.test(f))
    .sort();
  const threads = files.map((f) => parseThreadFile(f, readFileSync(join(dir, f), "utf-8")));
  threads.sort((a, b) => a.order - b.order);
  const seen = new Set<string>();
  for (const t of threads) {
    if (seen.has(t.key)) throw new Error(`${dir}: duplicate thread key '${t.key}'`);
    seen.add(t.key);
  }
  return threads;
}

export function parseModel(rootDir: string): OnboardingModel {
  return {
    global: parseDir(join(rootDir, "global")),
    perUser: parseDir(join(rootDir, "per-user")),
  };
}
