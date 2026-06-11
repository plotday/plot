/**
 * Corpus v2 emission — THE single write choke point for prod-extracted data.
 *
 * `buildCorpusFiles` is the only place where extracted rows become YAML text:
 * ALL anonymization (contacts, topics, group names, team names, the user's
 * own email) and the enforced leak check live here, nowhere else. Callers
 * (from-prod, add-prod-*) assemble plain ExtractedWorld/ExtractedThread data
 * and write the returned `files` verbatim; a leak-check violation throws and
 * nothing is returned.
 */
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";

import {
  anonymizeEmail,
  anonymizePerson,
  anonymizeTopic,
  hashShort,
  isFreemailDomain,
  scrubGroupName,
} from "./anonymize";
import { deterministicUuid } from "../corpus/hash";
import { leakCheck, type LeakFinding, type RawPii } from "./leak-check";
import { contactSlugFromEmail, uniqueSlugifier } from "./slugs";
import type {
  ExtractedConnection,
  ExtractedContact,
  ExtractedNegative,
  ExtractedThread,
  ExtractedWorld,
} from "./extract";

// ===========================================================================
// Input types
// ===========================================================================

export type CaseLabelsFresh = {
  /** Priority UUID (resolved to a slug at emission) or null. */
  gold: string | null;
  goldRationale: string;
  goldSource: "human" | "llm-proposed" | null;
  /** Priority UUID (resolved to a slug at emission) or null. */
  expected: string | null;
  expectedStage: string | null;
  expectedRecordedAt: string | null;
};

export type CaseEntryInput =
  | {
      /**
       * A pre-existing case that could not be re-hydrated (missing or
       * ambiguous source thread). Emitted as-is, with slug-migration applied
       * to its refs so the corpus still loads.
       */
      kind: "verbatim";
      raw: Record<string, unknown>;
    }
  | {
      kind: "thread";
      /** Full case id, e.g. "081-019e2c5b". */
      id: string;
      thread: ExtractedThread;
      tags: string[];
      notes: string;
      description: string;
      labels:
        | ({ kind: "fresh" } & CaseLabelsFresh)
        | {
            /**
             * Refresh path: the existing case's labels object, preserved
             * byte-exactly (gold/expected slug-migrated only when the slug
             * itself changed).
             */
            kind: "preserved";
            raw: Record<string, unknown>;
          };
    };

export type CorpusBuildInput = {
  corpusName: string;
  world: ExtractedWorld;
  trainings: ExtractedThread[];
  negatives: ExtractedNegative[];
  negativeThreads: ExtractedThread[];
  cases: CaseEntryInput[];
  /** Existing world.yaml text — drives slug migration + v1 detection. */
  existingWorldYaml?: string;
  /** Existing embeddings.yaml text — verbatim-case vector carry-forward. */
  existingEmbeddingsYaml?: string;
  /** Note-content vectors embed private message bodies; kris-only. */
  allowNoteContentEmbeddings: boolean;
  /** Verbatim command for the README (must not contain raw identity). */
  regenerateCommand: string;
  /** Clock injection for deterministic tests. */
  now?: Date;
};

export type CorpusBuildOutput = {
  files: { path: string; text: string }[];
  /** Leak-check title-scope hits + group-name residue, for human audit. */
  warnings: LeakFinding[];
  report: string[];
  /** old slug -> new slug, for rewriting files this build does not emit. */
  slugMigration: Map<string, string>;
};

// ===========================================================================
// Small shared helpers
// ===========================================================================

/**
 * Corpus-YAML stringify — EVERY seeder write of corpus YAML must go through
 * this. `lineWidth: 0` disables line wrapping so long quoted scalars (titles
 * with raw PII, preserved verbatim by policy) never wrap onto continuation
 * lines: the leak check's title warn-scope is per-LINE, and a wrapped title
 * tail would be misclassified as a hard violation.
 */
export function stringifyCorpusYaml(doc: unknown): string {
  return stringifyYaml(doc, { lineWidth: 0 });
}

/** Topic-shape label used for case tags/descriptions (v1-compatible). */
export function describeTopic(topic: string | null): string {
  if (topic === null) return "null";
  if (/^channel:\d+$/.test(topic)) return "channel:N";
  if (topic.startsWith("priority:")) return "priority:KEY";
  return "other";
}

/** Stable embedding ref for a prod thread (survives re-extraction). */
export function embeddingRefForThread(threadId: string): string {
  return `emb-${hashShort(threadId, 10)}`;
}

/** Deterministic synthesized team entry — team names are NEVER extracted. */
export function synthTeam(teamId: number): {
  slug: string;
  id: number;
  name: string;
} {
  const h = hashShort(`team:${teamId}`, 6);
  return { slug: `team-${h}`, id: teamId, name: `Team ${h}` };
}

/** Deterministic base slug for a connection (provider + id hash). */
export function connectionSlugBase(provider: string, connectionId: string): string {
  return `${provider}-${hashShort(connectionId, 6)}`;
}

/**
 * Placeholder actor contact for a tic-less connection — a prod
 * twist_instance with ZERO twist_instance_connection rows (verified live:
 * many of kris's instances, e.g. team-owned ones, have no tic row).
 *
 * WHY a placeholder instead of dropping the connection: in prod,
 * connection_org_key's actor lateral finds no tic row for these instances,
 * so acct.domain is NULL and the key falls through to `team:<id>` (or NULL
 * when personal). The sandbox, however, ALWAYS inserts a
 * twist_instance_connection row with actor_id = account_contact, so the
 * faithful corpus representation is a synthesized contact whose email AND
 * name are both NULL: the lateral then matches the row, but its
 * `c.email IS NOT NULL` predicate excludes it — yielding the exact same
 * org-key outcome (team branch or NULL) as prod. Keeping the connection also
 * keeps every channel it parents (channel topics drive the
 * channel_default/topic stages) and the threads' `connection` refs (the
 * origin exact-match signal).
 */
export function placeholderActorContact(connectionId: string): {
  id: string;
  slugBase: string;
} {
  return {
    id: deterministicUuid(`conn-actor:${connectionId}`),
    slugBase: `conn-actor-${hashShort(connectionId, 6)}`,
  };
}

/**
 * Contact emails whose anonymized form is not email-shaped (the anonymizer
 * falls back to an opaque `c-<hash>` token for non-email-shaped input) get an
 * example.test domain so the corpus zod schema (`z.string().email()`) still
 * loads them.
 */
export function emailShapedOrExampleTest(anonEmail: string | null): string | null {
  if (!anonEmail) return anonEmail;
  return anonEmail.includes("@") ? anonEmail : `${anonEmail}@example.test`;
}

/**
 * Deduplicates anonymized contact emails across a collection of contacts to
 * prevent `contact_email_unique` constraint violations when the sandbox loads
 * the corpus.
 *
 * WHY THIS IS NEEDED: The anonymizer maps contacts to a realistic fake name
 * derived from a finite name pool (~200 first × 200 last names = 40 000
 * combinations) and a small freemail domain pool (6 entries). With ~1 000
 * contacts, birthday-paradox collisions are near-certain — two distinct prod
 * contacts can anonymize to the same fake name AND the same freemail domain,
 * producing an identical anonymized email.
 *
 * STRATEGY: group contacts by their (lowercased) anonymized email, then
 * within each collision group sort by contact id lexicographically and leave
 * the first member unsuffixed. Every other member gets a plus-address suffix
 * derived from its contact UUID: `local+<hashShort(contactId, 4)>@domain`.
 * That keeps the domain intact (org-key semantics are domain-based) and is a
 * realistic, parseable email shape. An absurdly unlikely secondary collision
 * (4-hex suffix still collides) is resolved by extending to 8 chars.
 *
 * ORDER-INDEPENDENCE: the unsuffixed slot is always the lexicographically-
 * smallest contact id, not the first one encountered in iteration order, so
 * the output is the same regardless of which order the caller iterates.
 */
export function dedupeContactEmails(
  contacts: { id: string; email: string | null }[]
): Map<string, string | null> {
  // Group by lowercased email (null emails never collide — each is unique).
  const groups = new Map<string, string[]>(); // lowercased email -> [contactId]
  for (const c of contacts) {
    if (c.email === null) continue;
    const key = c.email.toLowerCase();
    const group = groups.get(key);
    if (group) {
      group.push(c.id);
    } else {
      groups.set(key, [c.id]);
    }
  }

  // Build the final email map: no-collision entries pass through; collision
  // groups assign the unsuffixed email to the lex-smallest id, and plus-
  // address suffixes to the rest.
  const result = new Map<string, string | null>();
  const usedEmails = new Set<string>();

  // First, assign all non-colliding emails (and mark the unsuffixed winner
  // in each collision group).
  for (const c of contacts) {
    if (c.email === null) {
      result.set(c.id, null);
      continue;
    }
    const key = c.email.toLowerCase();
    const group = groups.get(key)!;
    if (group.length === 1) {
      // No collision — pass through.
      result.set(c.id, c.email);
      usedEmails.add(key);
    } else {
      // Collision group: assign unsuffixed slot to the lex-smallest id.
      const winner = group.slice().sort()[0]!;
      if (c.id === winner) {
        result.set(c.id, c.email);
        usedEmails.add(key);
      }
      // Non-winners are handled in the suffix pass below.
    }
  }

  // Second pass: assign plus-address suffixes to the non-winners.
  for (const c of contacts) {
    if (result.has(c.id)) continue; // already assigned (winner or null)
    // c is a non-winner in a collision group — it has a non-null email.
    const baseEmail = c.email!;
    const at = baseEmail.lastIndexOf("@");
    const local = baseEmail.slice(0, at);
    const domain = baseEmail.slice(at + 1);

    // Try 4-char suffix first; extend to 8 on the (extremely unlikely) chance
    // that suffix itself still collides with another contact's final email.
    let suffixedEmail: string | undefined;
    for (const suffixLen of [4, 8]) {
      const suffix = hashShort(c.id, suffixLen);
      const candidate = `${local}+${suffix}@${domain}`;
      if (!usedEmails.has(candidate.toLowerCase())) {
        suffixedEmail = candidate;
        usedEmails.add(candidate.toLowerCase());
        break;
      }
    }
    // If both 4 and 8-char suffixes collide (astronomically unlikely), fall
    // back to the full 16-char hash to guarantee uniqueness.
    if (!suffixedEmail) {
      const suffix = hashShort(c.id, 16);
      suffixedEmail = `${local}+${suffix}@${domain}`;
      usedEmails.add(suffixedEmail.toLowerCase());
    }
    result.set(c.id, suffixedEmail);
  }

  return result;
}

/**
 * Splits training threads into the emitted training set and the N most
 * recent user-moved threads (by movedAt desc) — the move holdout. Training
 * order is preserved; the holdout keeps most-recent-first order.
 */
export function splitHoldout(
  threads: ExtractedThread[],
  n: number
): { training: ExtractedThread[]; holdout: ExtractedThread[] } {
  if (n <= 0) return { training: [...threads], holdout: [] };
  const sorted = [...threads].sort((a, b) => {
    const am = a.movedAt ?? "";
    const bm = b.movedAt ?? "";
    return am < bm ? 1 : am > bm ? -1 : a.id < b.id ? -1 : 1;
  });
  const holdout = sorted.slice(0, n);
  const holdoutIds = new Set(holdout.map((t) => t.id));
  return {
    training: threads.filter((t) => !holdoutIds.has(t.id)),
    holdout,
  };
}

export type CaseResolution =
  | { status: "hydrated"; thread: ExtractedThread }
  | { status: "ambiguous"; matches: number }
  | { status: "missing" };

/**
 * Refresh-preserving-labels merge: every existing case either becomes a
 * `thread` entry with a freshly hydrated candidate and byte-exactly
 * preserved labels/tags/notes/description, or (when its source thread cannot
 * be resolved) a `verbatim` entry that is kept entirely as-is and reported.
 */
export function mergeExistingCases(
  existingCases: Record<string, unknown>[],
  resolution: Map<string, CaseResolution>
): {
  entries: CaseEntryInput[];
  report: string[];
  maxCaseNumber: number;
  resolvedThreadIds: Set<string>;
} {
  const entries: CaseEntryInput[] = [];
  const report: string[] = [];
  const resolvedThreadIds = new Set<string>();
  let maxCaseNumber = 0;

  for (const raw of existingCases) {
    const id = String(raw.id ?? "");
    const numMatch = /^(\d+)-/.exec(id);
    if (numMatch) maxCaseNumber = Math.max(maxCaseNumber, Number(numMatch[1]));

    const res = resolution.get(id) ?? { status: "missing" as const };
    if (res.status === "hydrated") {
      resolvedThreadIds.add(res.thread.id);
      entries.push({
        kind: "thread",
        id,
        thread: res.thread,
        tags: Array.isArray(raw.tags) ? (raw.tags as string[]) : [],
        notes: typeof raw.notes === "string" ? raw.notes : "",
        description: typeof raw.description === "string" ? raw.description : "",
        labels: {
          kind: "preserved",
          raw: (raw.labels ?? {}) as Record<string, unknown>,
        },
      });
    } else {
      entries.push({ kind: "verbatim", raw });
      report.push(
        res.status === "ambiguous"
          ? `case ${id}: thread-id prefix matched ${res.matches} threads — kept verbatim`
          : `case ${id}: source thread not found — kept verbatim`
      );
    }
  }
  return { entries, report, maxCaseNumber, resolvedThreadIds };
}

/** Case id: zero-padded sequence number + 8-hex thread-id prefix. */
export function makeCaseId(n: number, threadId: string): string {
  return `${String(n).padStart(3, "0")}-${threadId.slice(0, 8)}`;
}

/**
 * Holdout cases (`--holdout-recent-moves`): gold = the user's own filing,
 * gold_source human, tag `holdout-move`. These threads are ALSO excluded
 * from the emitted training set (see splitHoldout) so sibling holdout cases
 * cannot see them as contemporaneous training.
 */
export function holdoutCaseEntries(
  holdout: ExtractedThread[],
  startNumber: number,
  recordedAtIso: string
): CaseEntryInput[] {
  return holdout.map((t, i) => ({
    kind: "thread" as const,
    id: makeCaseId(startNumber + i, t.id),
    thread: t,
    tags: ["holdout-move"],
    notes: "",
    description:
      "Holdout: recent user-moved thread; gold is the user's own filing.",
    labels: {
      kind: "fresh" as const,
      gold: t.filedToPriority,
      goldRationale: "User moved this thread here (holdout-move).",
      goldSource: "human" as const,
      expected: t.filedToPriority,
      expectedStage: null,
      expectedRecordedAt: recordedAtIso,
    },
  }));
}

/** Freshly sampled cases: expected = current prod filing, gold unset. */
export function sampledCaseEntries(
  sampled: ExtractedThread[],
  startNumber: number,
  recordedAtIso: string
): CaseEntryInput[] {
  return sampled.map((t, i) => ({
    kind: "thread" as const,
    id: makeCaseId(startNumber + i, t.id),
    thread: t,
    tags: [describeTopic(t.topic)],
    notes: "",
    description: `Sampled from prod (topic-shape: ${describeTopic(t.topic)}).`,
    labels: {
      kind: "fresh" as const,
      gold: null,
      goldRationale: "",
      goldSource: null,
      expected: t.filedToPriority,
      expectedStage: null,
      expectedRecordedAt: recordedAtIso,
    },
  }));
}

/**
 * Rewrites slug references in YAML text (whole-token matches only) using the
 * migration map. Longest-first so overlapping slugs cannot partially match.
 */
export function applySlugMigrationToYamlText(
  text: string,
  migration: Map<string, string>
): { text: string; replacements: number } {
  let out = text;
  // `replacements` is a logging-only count. It is accumulated against the
  // progressively-transformed `out` string (i.e. after earlier slug
  // replacements have already been applied), so the count is not guaranteed
  // to equal the number of replacements in the original text. This is
  // acceptable because the value is only used for human-readable reporting.
  let replacements = 0;
  const entries = [...migration.entries()].sort(
    (a, b) => b[0].length - a[0].length
  );
  for (const [oldSlug, newSlug] of entries) {
    const escaped = oldSlug.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(
      `(?<![A-Za-z0-9_-])${escaped}(?![A-Za-z0-9_-])`,
      "g"
    );
    const before = out;
    out = out.replace(re, newSlug);
    if (out !== before) {
      replacements += (before.match(re) ?? []).length;
    }
  }
  return { text: out, replacements };
}

// ===========================================================================
// buildCorpusFiles
// ===========================================================================

export function buildCorpusFiles(input: CorpusBuildInput): CorpusBuildOutput {
  const now = input.now ?? new Date();
  const nowIso = now.toISOString();
  const today = nowIso.slice(0, 10);
  const { world } = input;
  const report: string[] = [];
  const warnings: LeakFinding[] = [];

  // ---- Raw PII catalog: every real email (incl. the user's), every contact
  //      name, every non-freemail email domain seen during extraction.
  const pii: RawPii = { emails: [], names: [], orgDomains: [] };
  const addEmailPii = (email: string | null) => {
    if (!email) return;
    pii.emails.push(email);
    const at = email.lastIndexOf("@");
    if (at > 0) {
      const domain = email.slice(at + 1).toLowerCase();
      if (domain && !isFreemailDomain(domain)) pii.orgDomains.push(domain);
    }
  };
  addEmailPii(world.userEmail);
  for (const c of world.contacts) {
    addEmailPii(c.email);
    if (c.name) pii.names.push(c.name);
  }

  // ---- Anonymized identities + slugs ---------------------------------------
  const anonUserEmail =
    emailShapedOrExampleTest(anonymizeEmail(world.userEmail)) ??
    "eval-user@example.test";

  const prioritySlug = new Map<string, string>();
  {
    const slugify = uniqueSlugifier();
    for (const p of world.priorities) {
      const lastSegment = p.path.split(".").pop() ?? "";
      prioritySlug.set(p.id, slugify(p.title, lastSegment));
    }
  }

  const contactAnon = new Map<string, { email: string | null; name: string | null }>();
  const contactSlug = new Map<string, string>();
  const contactSlugify = uniqueSlugifier();
  {
    // First, compute each contact's raw anonymized email (before dedup).
    const rawAnonByContactId = new Map<string, { email: string | null; name: string | null }>();
    for (const c of world.contacts) {
      if (rawAnonByContactId.has(c.id)) continue;
      const anon = anonymizePerson({ name: c.name, email: c.email });
      rawAnonByContactId.set(c.id, {
        email: emailShapedOrExampleTest(anon.email),
        name: anon.name,
      });
    }
    // Deduplicate anonymized emails across all contacts to prevent
    // contact_email_unique constraint violations when the sandbox loads the
    // corpus. Two distinct prod contacts can anonymize to the same fake name
    // AND the same freemail domain (birthday-paradox collisions in a ~40 000-
    // element name space are near-certain at ~1 000 contacts). See
    // dedupeContactEmails for the full strategy.
    const dedupedEmails = dedupeContactEmails(
      [...rawAnonByContactId.entries()].map(([id, a]) => ({ id, email: a.email }))
    );
    for (const c of world.contacts) {
      if (contactAnon.has(c.id)) continue;
      const raw = rawAnonByContactId.get(c.id)!;
      const email = dedupedEmails.get(c.id) ?? raw.email;
      contactAnon.set(c.id, { email, name: raw.name });
      contactSlug.set(
        c.id,
        contactSlugify(
          contactSlugFromEmail(email, c.id),
          `c-${c.id.replace(/-/g, "").slice(0, 8)}`
        )
      );
    }
  }

  // Tic-less connections (actorContactId null) get a synthesized placeholder
  // actor with NULL email/name so the sandbox's twist_instance_connection
  // insert reproduces prod's connection_org_key fall-through (team:<id> or
  // NULL) — see placeholderActorContact for the full rationale. The
  // placeholder shares the contact slug namespace so refs stay unambiguous.
  const placeholderActorIdByConnection = new Map<string, string>();
  const placeholderContacts: ExtractedContact[] = [];
  for (const conn of world.connections) {
    if (conn.actorContactId !== null) continue;
    if (placeholderActorIdByConnection.has(conn.id)) continue;
    const { id, slugBase } = placeholderActorContact(conn.id);
    placeholderActorIdByConnection.set(conn.id, id);
    if (contactAnon.has(id)) continue;
    contactAnon.set(id, { email: null, name: null });
    contactSlug.set(
      id,
      contactSlugify(slugBase, `c-${id.replace(/-/g, "").slice(0, 8)}`)
    );
    placeholderContacts.push({ id, email: null, name: null, linkedToUser: false });
  }
  const emittedContacts = [...world.contacts, ...placeholderContacts];

  const rawContactNames = world.contacts
    .map((c) => c.name)
    .filter((n): n is string => !!n);
  const groupTitle = new Map<string, string>();
  const groupSlug = new Map<string, string>();
  {
    const slugify = uniqueSlugifier();
    for (const g of world.groups) {
      if (groupTitle.has(g.id)) continue;
      const { scrubbed, residueTokens } = scrubGroupName(
        g.title,
        rawContactNames
      );
      groupTitle.set(g.id, scrubbed);
      groupSlug.set(
        g.id,
        slugify(scrubbed, `g-${g.id.replace(/-/g, "").slice(0, 8)}`)
      );
      if (residueTokens.length > 0) {
        warnings.push({
          path: "world.yaml",
          line: 0,
          kind: "name",
          value: residueTokens.join(" "),
          context: `group ${g.id} title after scrub: "${scrubbed}" — residual tokens for manual audit`,
        });
      }
    }
  }

  // Teams are synthesized from connection team ids; names never extracted.
  const teamIds = [
    ...new Set(
      world.connections
        .map((c) => c.teamId)
        .filter((t): t is number => t !== null)
    ),
  ].sort((a, b) => a - b);
  const teams = teamIds.map(synthTeam);
  const teamSlugById = new Map(teams.map((t) => [t.id, t.slug]));

  // Connections: dedupe by id; drop (with report) when the actor contact is
  // not part of the world — the caller should have hydrated it. Tic-less
  // connections resolve their actor to the synthesized placeholder above.
  const connSlug = new Map<string, string>();
  const emittedConnections: Array<
    Omit<ExtractedConnection, "actorContactId"> & { actorContactId: string }
  > = [];
  {
    const slugify = uniqueSlugifier();
    const seen = new Set<string>();
    for (const conn of world.connections) {
      if (seen.has(conn.id)) continue;
      seen.add(conn.id);
      const actorContactId =
        conn.actorContactId ?? placeholderActorIdByConnection.get(conn.id)!;
      if (!contactSlug.has(actorContactId)) {
        report.push(
          `dropped connection ${conn.id} (${conn.provider}): actor contact ${actorContactId} not in world.contacts`
        );
        continue;
      }
      connSlug.set(
        conn.id,
        slugify(
          connectionSlugBase(conn.provider, conn.id),
          `conn-${conn.id.replace(/-/g, "").slice(0, 8)}`
        )
      );
      emittedConnections.push({ ...conn, actorContactId });
    }
  }

  // Channels must reference a declared connection in v2.
  const emittedChannels: {
    id: number;
    connection: string;
    default_priority_id: string | null;
  }[] = [];
  for (const ch of world.channels) {
    const slug = connSlug.get(ch.twistInstanceId);
    if (!slug) {
      report.push(
        `dropped channel ${ch.id}: parent connection ${ch.twistInstanceId} could not be resolved`
      );
      continue;
    }
    emittedChannels.push({
      id: ch.id,
      connection: slug,
      default_priority_id: ch.defaultPriorityId,
    });
  }

  // ---- Embedding catalog ----------------------------------------------------
  const embeddings: {
    ref: string;
    source: "thread-title" | "note-content" | null;
    vector: number[];
  }[] = [];
  const embRefOf = new Map<string, string>();
  const embSeen = new Set<string>();
  let droppedNoteEmbeddings = 0;
  const caseThreads = input.cases.flatMap((c) =>
    c.kind === "thread" ? [c.thread] : []
  );
  for (const t of [...input.trainings, ...input.negativeThreads, ...caseThreads]) {
    if (embSeen.has(t.id)) continue;
    embSeen.add(t.id);
    if (!t.embedding || t.embedding.length !== 384) continue;
    if (t.embeddingSource === "note-content" && !input.allowNoteContentEmbeddings) {
      droppedNoteEmbeddings++;
      continue;
    }
    const ref = embeddingRefForThread(t.id);
    embRefOf.set(t.id, ref);
    embeddings.push({ ref, source: t.embeddingSource, vector: t.embedding });
  }
  if (droppedNoteEmbeddings > 0) {
    report.push(
      `excluded ${droppedNoteEmbeddings} note-content embedding vector(s) (allowNoteContentEmbeddings=false)`
    );
  }

  // Old embeddings (for verbatim-case carry-forward).
  const oldEmbeddings = new Map<
    string,
    { vector: number[]; source: "thread-title" | "note-content" | "local-title" | null }
  >();
  for (const text of [input.existingWorldYaml, input.existingEmbeddingsYaml]) {
    if (!text) continue;
    const doc = parseYaml(text) as { embeddings?: unknown } | null;
    if (!doc || !Array.isArray(doc.embeddings)) continue;
    for (const e of doc.embeddings as {
      ref?: unknown;
      vector?: unknown;
      source?: unknown;
    }[]) {
      if (typeof e?.ref !== "string" || !Array.isArray(e.vector)) continue;
      oldEmbeddings.set(e.ref, {
        vector: e.vector as number[],
        source:
          e.source === "thread-title" ||
          e.source === "note-content" ||
          e.source === "local-title"
            ? e.source
            : null,
      });
    }
  }

  // ---- Slug migration (old slug -> new slug) --------------------------------
  const slugMigration = new Map<string, string>();
  let existingWasV1 = false;
  if (input.existingWorldYaml) {
    const oldWorld = parseYaml(input.existingWorldYaml) as Record<string, unknown> | null;
    existingWasV1 = (oldWorld?.schema_version ?? 1) !== 2;
    const collect = (
      list: unknown,
      newSlugById: Map<string, string>
    ): void => {
      if (!Array.isArray(list)) return;
      for (const e of list as { slug?: unknown; id?: unknown }[]) {
        if (typeof e?.slug !== "string" || typeof e?.id !== "string") continue;
        const ns = newSlugById.get(e.id);
        if (ns && ns !== e.slug) slugMigration.set(e.slug, ns);
      }
    };
    collect(oldWorld?.contacts, contactSlug);
    collect(oldWorld?.groups, groupSlug);
    collect(oldWorld?.priorities, prioritySlug);
  }
  const migrateSlug = (s: unknown): unknown =>
    typeof s === "string" && slugMigration.has(s) ? slugMigration.get(s)! : s;

  // Valid priority slugs in the NEW world (for stale-label detection).
  const validPrioritySlugs = new Set(prioritySlug.values());

  // ---- Ref resolution (throws on caller bugs: missing world entities) -------
  const contactRef = (id: string, ctx: string): string => {
    const s = contactSlug.get(id);
    if (!s) {
      throw new Error(
        `buildCorpusFiles: contact ${id} referenced by ${ctx} is not in world.contacts — hydrate it first (loadContactsByIds)`
      );
    }
    return s;
  };
  const groupRef = (id: string, ctx: string): string => {
    const s = groupSlug.get(id);
    if (!s) {
      throw new Error(
        `buildCorpusFiles: group ${id} referenced by ${ctx} is not in world.groups — hydrate it first (loadGroupsByIds)`
      );
    }
    return s;
  };
  const connectionRef = (id: string | null, ctx: string): string | null => {
    if (id === null) return null;
    const s = connSlug.get(id);
    if (!s) {
      report.push(
        `thread ${ctx}: connection ${id} could not be resolved — emitted without a connection`
      );
      return null;
    }
    return s;
  };
  const requiredPriorityRef = (id: string | null, ctx: string): string => {
    const s = id ? prioritySlug.get(id) : undefined;
    if (!s) {
      throw new Error(
        `buildCorpusFiles: priority ${id} referenced by ${ctx} is not in world.priorities — filter to active priorities first`
      );
    }
    return s;
  };

  const threadFields = (t: ExtractedThread, ctx: string) => ({
    id: t.id,
    title: t.title ?? "",
    topic: anonymizeTopic(t.topic),
    contacts: t.contacts.map((id) => contactRef(id, ctx)),
    groups: t.groups.map((id) => groupRef(id, ctx)),
    embedding_ref: embRefOf.get(t.id) ?? null,
    author: t.authorContactId
      ? contactRef(t.authorContactId, `${ctx}.author`)
      : null,
    connection: t.connectionId ? connectionRef(t.connectionId, ctx) : null,
    facets: t.facets,
    created_at: t.createdAt,
  });

  // ---- trainings/full.yaml ---------------------------------------------------
  const trainingThreadIds = new Set(input.trainings.map((t) => t.id));
  const negativeThreadIds = new Set(input.negativeThreads.map((t) => t.id));
  const negativesOut: {
    thread: string;
    priority: string;
    source: string;
    created_at: string;
  }[] = [];
  for (const n of input.negatives) {
    if (n.source !== "moved_out" && n.source !== "deselected") {
      report.push(
        `dropped negative (thread ${n.threadId}): unknown source "${n.source}"`
      );
      continue;
    }
    const pSlug = n.priorityId ? prioritySlug.get(n.priorityId) : undefined;
    if (!pSlug) {
      report.push(
        `dropped negative (thread ${n.threadId}): priority ${n.priorityId} not in world.priorities`
      );
      continue;
    }
    if (!trainingThreadIds.has(n.threadId) && !negativeThreadIds.has(n.threadId)) {
      report.push(
        `dropped negative (thread ${n.threadId}): thread is neither a training thread nor a negative_thread`
      );
      continue;
    }
    negativesOut.push({
      thread: n.threadId,
      priority: pSlug,
      source: n.source,
      created_at: n.createdAt,
    });
  }

  const trainingsDoc = {
    name: "full",
    description:
      `All ${input.trainings.length} user_moved=TRUE threads for ${anonUserEmail} ` +
      `as of ${today}. Re-generated by from-prod (schema v2).`,
    threads: input.trainings.map((t) => ({
      ...threadFields(t, `training thread ${t.id}`),
      filed_to_priority: requiredPriorityRef(
        t.filedToPriority,
        `training thread ${t.id}.filed_to_priority`
      ),
      moved_at: t.movedAt,
    })),
    negative_threads: input.negativeThreads.map((t) =>
      threadFields(t, `negative thread ${t.id}`)
    ),
    negatives: negativesOut,
  };

  // ---- cases.yaml --------------------------------------------------------------
  const casesOut: Record<string, unknown>[] = [];
  const verbatimRefsNeeded: string[] = [];
  let staleGoldCount = 0;
  let staleExpectedCount = 0;
  for (const entry of input.cases) {
    if (entry.kind === "verbatim") {
      const c = structuredClone(entry.raw);
      const cand = c.candidate as Record<string, unknown> | undefined;
      if (cand) {
        // A topic is CANDIDATE data, not a preserved label: even when the
        // case is kept verbatim (un-rehydratable), email-bearing topics
        // (e.g. Gmail's `channel:<address>`) must still be anonymized.
        // Label fields (gold_rationale, notes) remain byte-preserved.
        if (typeof cand.topic === "string") {
          cand.topic = anonymizeTopic(cand.topic);
        }
        if (Array.isArray(cand.contacts)) {
          cand.contacts = cand.contacts.map(migrateSlug);
        }
        if (Array.isArray(cand.groups)) {
          cand.groups = cand.groups.map(migrateSlug);
        }
        if (typeof cand.author === "string" && cand.author) {
          if (existingWasV1) {
            // v1 `author` semantics = thread.created_by; preserve them
            // exactly via the v2 escape hatch (created_by_override) instead
            // of v2's author (= thread.author_id, contacts only).
            cand.created_by_override = migrateSlug(cand.author);
            cand.author = null;
          } else {
            cand.author = migrateSlug(cand.author);
          }
        }
        if (typeof cand.connection === "string") {
          cand.connection = migrateSlug(cand.connection);
        }
        if (typeof cand.embedding_ref === "string" && cand.embedding_ref) {
          verbatimRefsNeeded.push(cand.embedding_ref);
        }
      }
      const labels = c.labels as Record<string, unknown> | undefined;
      if (labels) {
        if ("gold" in labels) labels.gold = migrateSlug(labels.gold);
        if ("expected" in labels) labels.expected = migrateSlug(labels.expected);
      }
      casesOut.push(c);
      continue;
    }

    const t = entry.thread;
    const fields = threadFields(t, `case ${entry.id}`);
    const candidate = {
      title: fields.title,
      topic: fields.topic,
      contacts: fields.contacts,
      groups: fields.groups,
      embedding_ref: fields.embedding_ref,
      author: fields.author,
      connection: fields.connection,
      facets: fields.facets,
    };
    let labels: Record<string, unknown>;
    let staleNotes: string[] = [];
    if (entry.labels.kind === "preserved") {
      labels = { ...entry.labels.raw };
      if ("gold" in labels) labels.gold = migrateSlug(labels.gold);
      if ("expected" in labels) labels.expected = migrateSlug(labels.expected);
      // Stale-label detection: if a gold/expected ref no longer resolves to a
      // priority in the NEW world, null it rather than emitting a dangling slug
      // that will fail corpus load. gold_rationale is kept as a record of the
      // old judgment; a note is appended to the case's top-level notes field
      // explaining what happened.
      if (
        "gold" in labels &&
        typeof labels.gold === "string" &&
        labels.gold !== null &&
        !validPrioritySlugs.has(labels.gold)
      ) {
        staleNotes.push(
          `stale gold label: was "${labels.gold}" — priority no longer active in prod`
        );
        labels.gold = null;
        if ("gold_source" in labels) labels.gold_source = null;
        staleGoldCount++;
      }
      if (
        "expected" in labels &&
        typeof labels.expected === "string" &&
        labels.expected !== null &&
        !validPrioritySlugs.has(labels.expected)
      ) {
        staleNotes.push(
          `stale expected: was "${labels.expected}" — priority no longer active in prod`
        );
        labels.expected = null;
        staleExpectedCount++;
      }
    } else {
      labels = {
        gold:
          entry.labels.gold !== null
            ? requiredPriorityRef(entry.labels.gold, `case ${entry.id}.labels.gold`)
            : null,
        gold_rationale: entry.labels.goldRationale,
        // gold_source key is OMITTED when null so a later human gold label
        // still gets the loader's absent->human backfill.
        ...(entry.labels.goldSource !== null
          ? { gold_source: entry.labels.goldSource }
          : {}),
        expected:
          entry.labels.expected !== null
            ? requiredPriorityRef(
                entry.labels.expected,
                `case ${entry.id}.labels.expected`
              )
            : null,
        expected_stage: entry.labels.expectedStage,
        expected_recorded_at: entry.labels.expectedRecordedAt,
      };
    }
    const caseNotes = [entry.notes, ...staleNotes].filter(Boolean).join("\n");
    casesOut.push({
      id: entry.id,
      source_thread_id: t.id,
      tags: entry.tags,
      as_of: t.createdAt,
      description: entry.description,
      candidate,
      labels,
      notes: caseNotes,
    });
  }

  if (staleGoldCount > 0) {
    report.push(
      `${staleGoldCount} stale gold label(s) nulled — priority no longer active in prod`
    );
  }
  if (staleExpectedCount > 0) {
    report.push(
      `${staleExpectedCount} stale expected label(s) nulled — priority no longer active in prod`
    );
  }

  // Verbatim-case embedding refs: carry old vectors forward so refs don't
  // dangle; null the ref (with a report) when the vector is unrecoverable.
  {
    const known = new Set(embeddings.map((e) => e.ref));
    for (const ref of new Set(verbatimRefsNeeded)) {
      if (known.has(ref)) continue;
      const old = oldEmbeddings.get(ref);
      if (old) {
        embeddings.push({
          ref,
          source:
            old.source === "local-title" ? null : (old.source as
              | "thread-title"
              | "note-content"
              | null),
          vector: old.vector,
        });
        known.add(ref);
        report.push(`carried forward embedding ${ref} for a verbatim case`);
      } else {
        for (const c of casesOut) {
          const cand = c.candidate as Record<string, unknown> | undefined;
          if (cand?.embedding_ref === ref) cand.embedding_ref = null;
        }
        report.push(
          `embedding ${ref} referenced by a verbatim case is unrecoverable — ref nulled`
        );
      }
    }
  }

  // ---- world.yaml ----------------------------------------------------------------
  const worldDoc = {
    name: input.corpusName,
    description:
      `Snapshot of ${anonUserEmail} extracted ${today} by libs/eval seeder (schema v2). ` +
      `Emails, contact names, group-name contact tokens, team names, and topic emails ` +
      `are anonymized; priority/thread titles are preserved verbatim.`,
    schema_version: 2,
    source: {
      kind: "prod-extract",
      extracted_at: nowIso,
      anonymized: true,
    },
    user: {
      id: world.userId,
      email: anonUserEmail,
      primary_contact_id: null,
      subscription: world.subscription,
    },
    teams,
    connections: emittedConnections.map((c) => ({
      slug: connSlug.get(c.id)!,
      id: c.id,
      provider: c.provider,
      account_contact: contactSlug.get(c.actorContactId)!,
      team: c.teamId !== null ? (teamSlugById.get(c.teamId) ?? null) : null,
    })),
    priorities: world.priorities.map((p) => ({
      slug: prioritySlug.get(p.id)!,
      id: p.id,
      path: p.path,
      title: p.title,
      key: p.key,
      description: p.description,
      facet_filters: p.facetFilters,
    })),
    contacts: emittedContacts.map((c) => ({
      slug: contactSlug.get(c.id)!,
      id: c.id,
      email: contactAnon.get(c.id)!.email,
      name: contactAnon.get(c.id)!.name,
      linked_to_user: c.linkedToUser,
    })),
    groups: world.groups.map((g) => ({
      slug: groupSlug.get(g.id)!,
      id: g.id,
      title: groupTitle.get(g.id)!,
    })),
    channels: emittedChannels,
  };

  // ---- README.md ------------------------------------------------------------------
  const holdoutCount = input.cases.filter(
    (c) => c.kind === "thread" && c.tags.includes("holdout-move")
  ).length;
  const readme = [
    `# Corpus: ${input.corpusName}`,
    "",
    `Anonymized snapshot of \`${anonUserEmail}\` extracted on ${today} (corpus schema v2).`,
    "",
    `World: ${world.priorities.length} priorities, ${emittedContacts.length} contacts, ` +
      `${world.groups.length} groups, ${emittedConnections.length} connections, ` +
      `${emittedChannels.length} channels, ${teams.length} teams, ${embeddings.length} embeddings ` +
      `(in embeddings.yaml).`,
    "",
    `Training sets: trainings/full.yaml holds ${input.trainings.length} user_moved=TRUE threads, ` +
      `${input.negativeThreads.length} negative-evidence threads, and ${negativesOut.length} ` +
      `thread_priority_negative rows pulled from prod. Other files under trainings/ are ` +
      `maintained by hand and only get slug rewrites on refresh.`,
    "",
    `Cases: ${casesOut.length} in cases.yaml` +
      (holdoutCount > 0
        ? ` (including ${holdoutCount} \`holdout-move\` cases — excluded from runs by default; see --include-holdout)`
        : "") +
      `. Each case's \`expected\` is the prod filing at extraction time; \`gold\` is the human ` +
      `(or llm-proposed) label. Re-running the seeder preserves gold/expected labels, tags, and ` +
      `notes byte-for-byte for cases that can be re-hydrated by source_thread_id.`,
    "",
    "Anonymization: emails, contact names, group-name contact tokens, and team names are",
    "deterministically anonymized (shape-preserving: freemail stays freemail, org domains stay",
    "org-shaped and equal-where-equal). Thread/priority titles and topics-without-emails are",
    "preserved verbatim by policy. A leak check runs before every write; title-scope hits are",
    "warnings listed by the seeder for manual audit.",
    "",
    "## Re-generating",
    "",
    "```bash",
    "pnpm prod-db-connect  # if the readonly proxy isn't running",
    input.regenerateCommand,
    "```",
    "",
  ].join("\n");

  // ---- Serialize + leak check (the enforcement gate) --------------------------------
  const files = [
    { path: "world.yaml", text: stringifyCorpusYaml(worldDoc) },
    { path: "embeddings.yaml", text: stringifyCorpusYaml({ embeddings }) },
    { path: "trainings/full.yaml", text: stringifyCorpusYaml(trainingsDoc) },
    { path: "cases.yaml", text: stringifyCorpusYaml({ cases: casesOut }) },
    { path: "README.md", text: readme },
  ];

  const leak = leakCheck(files, pii);
  if (leak.violations.length > 0) {
    const lines = leak.violations
      .slice(0, 50)
      .map(
        (v) => `  ${v.path}:${v.line} [${v.kind}] "${v.value}" — ${v.context}`
      );
    throw new Error(
      `Leak check failed: ${leak.violations.length} raw PII value(s) outside title scope. ` +
        `Nothing was written.\n${lines.join("\n")}`
    );
  }
  warnings.push(...leak.warnings);

  report.push(
    `emitted: ${world.priorities.length} priorities, ${emittedContacts.length} contacts, ` +
      `${world.groups.length} groups, ${emittedConnections.length} connections, ` +
      `${emittedChannels.length} channels, ${teams.length} teams, ` +
      `${input.trainings.length} training threads, ${input.negativeThreads.length} negative threads, ` +
      `${negativesOut.length} negatives, ${casesOut.length} cases, ${embeddings.length} embeddings`
  );
  if (slugMigration.size > 0) {
    report.push(`slug migration: ${slugMigration.size} slug(s) changed`);
  }

  return { files, warnings, report, slugMigration };
}
