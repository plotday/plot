import type { Nonlinearity, OriginBonus, SignalWeights } from "./ts-hybrid.defaults";

export type SignalValues = {
  sem: number;
  con: number;
  grp: number;
  author: number;
  topic_fuzzy: number;
  title: number;
};

export function jaccard(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const setA = new Set(a);
  const setB = new Set(b);
  let inter = 0;
  for (const x of setA) if (setB.has(x)) inter++;
  const union = setA.size + setB.size - inter;
  if (union === 0) return 0;
  return inter / union;
}

export function sem(a: number[] | null, b: number[] | null): number {
  if (a === null || b === null) return 0;
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    normA += a[i]! * a[i]!;
    normB += b[i]! * b[i]!;
  }
  if (normA === 0 || normB === 0) return 0;
  const cos = dot / (Math.sqrt(normA) * Math.sqrt(normB));
  return Math.max(0, (cos - 0.5) * 2);
}

export function con(a: string[], b: string[]): number {
  return jaccard(a, b);
}

export function grp(a: string[], b: string[]): number {
  return jaccard(a, b);
}

export function author(a: string | null, b: string | null): number {
  if (a === null || b === null) return 0;
  return a === b ? 1 : 0;
}

export function topicFuzzy(
  a: string | null,
  b: string | null,
  prefixWeight: number
): number {
  if (a === null || b === null) return 0;
  if (a === b) return 1;
  if (!a.includes(":") || !b.includes(":")) return 0;
  const segA = a.split(":")[0] ?? "";
  const segB = b.split(":")[0] ?? "";
  if (segA === "" || segB === "") return 0;
  return segA === segB ? prefixWeight : 0;
}

export function titleTrigramJaccard(a: string, b: string): number {
  const tA = trigrams(a.toLowerCase());
  const tB = trigrams(b.toLowerCase());
  if (tA.size === 0 || tB.size === 0) return 0;
  let inter = 0;
  for (const t of tA) if (tB.has(t)) inter++;
  const union = tA.size + tB.size - inter;
  if (union === 0) return 0;
  return inter / union;
}

function trigrams(s: string): Set<string> {
  const out = new Set<string>();
  if (s.length < 3) return out;
  for (let i = 0; i <= s.length - 3; i++) {
    out.add(s.slice(i, i + 3));
  }
  return out;
}

const STOPWORDS = new Set([
  "the",
  "and",
  "for",
  "with",
  "from",
  "this",
  "that",
  "are",
  "was",
  "but",
  "not",
  "you",
  "your",
  "our",
  "their",
  "his",
  "her",
  "its",
  "all",
  "any",
  "can",
  "will",
  "has",
  "have",
  "had",
  "into",
  "out",
  "via",
  "per",
  "more",
  "less",
  "than",
  "then",
  "now",
  "new",
  "old",
  "get",
  "got",
  "use",
  "via",
]);

/** Lowercased word tokens of length ≥ 3, stop-words removed. */
export function tokenize(text: string): Set<string> {
  const out = new Set<string>();
  for (const raw of text.toLowerCase().split(/[^a-z0-9]+/)) {
    if (raw.length < 3) continue;
    if (STOPWORDS.has(raw)) continue;
    out.add(raw);
  }
  return out;
}

/**
 * Token-level Jaccard between a candidate's text (title + topic) and a
 * priority's text (title + colon-joined path segments). Stop-words are
 * removed before comparison so common filler ("the", "with") doesn't inflate
 * the score.
 */
export function priorityTitleMatch(
  candidateText: string,
  priorityText: string
): number {
  const a = tokenize(candidateText);
  const b = tokenize(priorityText);
  if (a.size === 0 || b.size === 0) return 0;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter++;
  const union = a.size + b.size - inter;
  if (union === 0) return 0;
  return inter / union;
}

export function applyNonlinearity(x: number, mode: Nonlinearity): number {
  switch (mode) {
    case "identity":
      return x;
    case "square":
      return x * x;
    case "sigmoid":
      return 1 / (1 + Math.exp(-x));
  }
}

export function combineSignals(
  values: SignalValues,
  weights: SignalWeights,
  nl: Nonlinearity
): number {
  const keys: (keyof SignalValues)[] = [
    "sem",
    "con",
    "grp",
    "author",
    "topic_fuzzy",
    "title",
  ];
  let total = 0;
  for (const k of keys) {
    total += weights[k] * applyNonlinearity(values[k], nl);
  }
  return total;
}

/**
 * Connection-origin bonus for one neighbor (mirrors the SQL scorer's origin
 * CASE in classify_thread_for_user): exact when the neighbor came from the
 * SAME connection as the candidate, org when both connections share an org
 * key (connection_org_key), else 0.
 */
export function originBonus(
  neighborConnId: string | null,
  neighborOrgKey: string | null,
  candidateConnId: string | null,
  candidateOrgKey: string | null,
  bonus: OriginBonus
): number {
  if (candidateConnId === null) return 0;
  if (neighborConnId !== null && neighborConnId === candidateConnId) return bonus.exact;
  if (
    candidateOrgKey !== null &&
    neighborOrgKey !== null &&
    neighborOrgKey === candidateOrgKey
  ) {
    return bonus.org;
  }
  return 0;
}
