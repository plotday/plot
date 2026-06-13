// libs/db/scripts/onboarding/snapshot.ts
import { createHash } from "node:crypto";
import type { OnboardingModel, ThreadDef } from "./model.ts";

/** Hash of a thread's shared content (title/preview/order). */
function threadContentHash(t: ThreadDef): string {
  return sha(JSON.stringify({ title: t.title, preview: t.preview, order: t.order }));
}
function noteHash(content: string): string {
  return sha(content);
}
function sha(s: string): string {
  return createHash("sha256").update(s).digest("hex").slice(0, 16);
}

export interface Snapshot {
  version: 1;
  /** key -> content hash (shared rows). */
  globalThreads: Record<string, string>;
  /** "threadKey/noteKey" -> content hash (shared rows). */
  globalNotes: Record<string, string>;
  /** Single hash over the entire per-user model (content + state). */
  perUserHash: string;
  /** Hash over all global state blocks — drives function regeneration. */
  globalStateHash: string;
}

export function compileSnapshot(model: OnboardingModel): Snapshot {
  const globalThreads: Record<string, string> = {};
  const globalNotes: Record<string, string> = {};
  for (const t of model.global) {
    globalThreads[t.key] = threadContentHash(t);
    for (const n of t.notes) globalNotes[`${t.key}/${n.key}`] = noteHash(n.content);
  }
  const globalStateHash = sha(
    JSON.stringify(
      model.global.map((t) => ({
        key: t.key,
        order: t.order,
        state: t.state,
        hasTodo: t.notes.some((n) => n.key === "todo"),
      })),
    ),
  );
  const perUserHash = sha(JSON.stringify(model.perUser));
  return { version: 1, globalThreads, globalNotes, perUserHash, globalStateHash };
}

export interface SnapshotDiff {
  threadsUpserted: string[];
  threadsArchived: string[];
  notesUpserted: string[]; // "threadKey/noteKey"
  notesArchived: string[];
  perUserChanged: boolean;
  /** True when any global state block, order, or todo-membership changed. */
  globalStateChanged: boolean;
  hasChanges: boolean;
}

export function diffSnapshots(prev: Snapshot | null, next: Snapshot): SnapshotDiff {
  const p = prev ?? emptySnapshot();
  const threadsUpserted = keysChanged(p.globalThreads, next.globalThreads);
  const threadsArchived = keysRemoved(p.globalThreads, next.globalThreads);
  const notesUpserted = keysChanged(p.globalNotes, next.globalNotes);
  const notesArchived = keysRemoved(p.globalNotes, next.globalNotes);
  const perUserChanged = p.perUserHash !== next.perUserHash;
  const globalStateChanged = p.globalStateHash !== next.globalStateHash;
  const hasChanges =
    threadsUpserted.length > 0 ||
    threadsArchived.length > 0 ||
    notesUpserted.length > 0 ||
    notesArchived.length > 0 ||
    perUserChanged ||
    globalStateChanged;
  return {
    threadsUpserted,
    threadsArchived,
    notesUpserted,
    notesArchived,
    perUserChanged,
    globalStateChanged,
    hasChanges,
  };
}

function emptySnapshot(): Snapshot {
  return { version: 1, globalThreads: {}, globalNotes: {}, perUserHash: "", globalStateHash: "" };
}
function keysChanged(prev: Record<string, string>, next: Record<string, string>): string[] {
  return Object.keys(next)
    .filter((k) => prev[k] !== next[k])
    .sort();
}
function keysRemoved(prev: Record<string, string>, next: Record<string, string>): string[] {
  return Object.keys(prev)
    .filter((k) => !(k in next))
    .sort();
}
