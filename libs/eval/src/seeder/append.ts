/**
 * Shared append pipeline for add-prod-cases.ts / add-prod-trainings.ts.
 *
 * Appends curated prod threads to an EXISTING v2 corpus: threads are
 * hydrated through extract.ts, anonymized with the same deterministic
 * primitives buildCorpusFiles uses (so values match a full re-extraction),
 * missing contacts/groups/connections/embeddings are backfilled into
 * world.yaml / embeddings.yaml, everything already in the YAML is preserved,
 * and the leak check runs over every modified document before anything is
 * written.
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import pg from "pg";
import { parse as parseYaml } from "yaml";

import {
  anonymizePerson,
  anonymizeTopic,
  isFreemailDomain,
  scrubGroupName,
} from "./anonymize";
import { leakCheck, type RawPii } from "./leak-check";
import { contactSlugFromEmail, uniqueSlugifier } from "./slugs";
import {
  hydrateThreadsByIds,
  loadConnections,
  loadContactsByIds,
  loadGroupsByIds,
  type ExtractedThread,
} from "./extract";
import {
  connectionSlugBase,
  describeTopic,
  emailShapedOrExampleTest,
  embeddingRefForThread,
  makeCaseId,
  placeholderActorContact,
  stringifyCorpusYaml,
  synthTeam,
} from "./emit";

export type AppendMode = { kind: "cases" } | { kind: "trainings"; set: string };

/**
 * Per-thread case override (cases mode only): replaces the default
 * tags/description/as_of/notes/labels for that thread's emitted case. Used by
 * the decision-log miner, which knows the gold/expected labels up front.
 * Label values are FINAL (priority slugs, not ids) — the caller resolves them.
 */
export type CaseOverride = {
  tags: string[];
  description: string;
  /** Replaces the default as_of (thread.createdAt), ISO. */
  asOf: string;
  notes: string;
  labels: {
    gold: string | null;
    gold_rationale: string;
    gold_source: "human" | "llm-proposed" | null;
    expected: string | null;
    expected_stage: string | null;
    expected_recorded_at: string;
  };
};

export type AppendOptions = {
  corpus: string;
  threadIds: string[];
  mode: AppendMode;
  dbUrl: string;
  /** note-content vectors embed private message bodies; kris-only. */
  allowNoteContentEmbeddings: boolean;
  /** Optional per-thread case overrides keyed by thread id (cases mode only). */
  caseOverrides?: Map<string, CaseOverride>;
};

// Loosely-typed YAML documents: these scripts edit existing files in place
// and must not strip fields they don't know about.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type YamlDoc = any;

export async function appendProdThreads(opts: AppendOptions): Promise<void> {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const corpusDir = resolve(scriptDir, "..", "..", "corpora", opts.corpus);
  const worldPath = join(corpusDir, "world.yaml");
  const embeddingsPath = join(corpusDir, "embeddings.yaml");
  const targetPath =
    opts.mode.kind === "cases"
      ? join(corpusDir, "cases.yaml")
      : join(corpusDir, "trainings", `${opts.mode.set}.yaml`);

  const world: YamlDoc = parseYaml(await readFile(worldPath, "utf-8"));
  if (world?.schema_version !== 2) {
    throw new Error(
      `Corpus '${opts.corpus}' is schema v${world?.schema_version ?? 1}; the append seeders ` +
        `require v2. Re-extract it first: pnpm exec tsx src/seeder/from-prod.ts --out ${opts.corpus} ...`
    );
  }
  const target: YamlDoc = parseYaml(await readFile(targetPath, "utf-8"));

  let embeddingsDoc: YamlDoc = { embeddings: [] };
  let embeddingsFileExisted = false;
  try {
    embeddingsDoc = parseYaml(await readFile(embeddingsPath, "utf-8")) ?? {
      embeddings: [],
    };
    embeddingsFileExisted = true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
  embeddingsDoc.embeddings ??= [];

  const userId: string = world.user.id;

  // Lookup maps over the existing world.
  const prioritySlugById = new Map<string, string>(
    (world.priorities ?? []).map((p: YamlDoc) => [p.id, p.slug])
  );
  const contactSlugById = new Map<string, string>(
    (world.contacts ?? []).map((c: YamlDoc) => [c.id, c.slug])
  );
  const groupSlugById = new Map<string, string>(
    (world.groups ?? []).map((g: YamlDoc) => [g.id, g.slug])
  );
  const connectionSlugById = new Map<string, string>(
    (world.connections ?? []).map((c: YamlDoc) => [c.id, c.slug])
  );
  const teamSlugById = new Map<number, string>(
    (world.teams ?? []).map((t: YamlDoc) => [t.id, t.slug])
  );
  const embRefs = new Set<string>([
    ...((world.embeddings ?? []) as YamlDoc[]).map((e) => e.ref as string),
    ...(embeddingsDoc.embeddings as YamlDoc[]).map((e) => e.ref as string),
  ]);

  // Slugifiers preseeded with existing slugs so backfills cannot collide.
  const contactSlugify = uniqueSlugifier(contactSlugById.values());
  const groupSlugify = uniqueSlugifier(groupSlugById.values());
  const connectionSlugify = uniqueSlugifier(connectionSlugById.values());

  // Raw PII seen during this run (newly fetched contacts) for the leak check.
  const pii: RawPii = { emails: [], names: [], orgDomains: [] };
  const rawNamesThisRun: string[] = [];

  const client = new pg.Client({ connectionString: opts.dbUrl });
  await client.connect();
  let added = 0;
  let droppedNoteEmbeddings = 0;
  try {
    const ensureContact = async (contactId: string): Promise<string | null> => {
      const known = contactSlugById.get(contactId);
      if (known) return known;
      const [contact] = await loadContactsByIds(client, userId, [contactId]);
      if (!contact) {
        console.warn(`  ! contact ${contactId} not found in prod; ref dropped`);
        return null;
      }
      pii.emails.push(contact.email ?? "");
      if (contact.name) {
        pii.names.push(contact.name);
        rawNamesThisRun.push(contact.name);
      }
      const at = (contact.email ?? "").lastIndexOf("@");
      if (at > 0) {
        const domain = contact.email!.slice(at + 1).toLowerCase();
        if (domain && !isFreemailDomain(domain)) pii.orgDomains.push(domain);
      }
      const anon = anonymizePerson({ name: contact.name, email: contact.email });
      const email = emailShapedOrExampleTest(anon.email);
      const slug = contactSlugify(
        contactSlugFromEmail(email, contactId),
        `c-${contactId.replace(/-/g, "").slice(0, 8)}`
      );
      (world.contacts ??= []).push({
        slug,
        id: contactId,
        email,
        name: anon.name,
        linked_to_user: contact.linkedToUser,
      });
      contactSlugById.set(contactId, slug);
      return slug;
    };

    const ensureGroup = async (groupId: string): Promise<string | null> => {
      const known = groupSlugById.get(groupId);
      if (known) return known;
      const [group] = await loadGroupsByIds(client, [groupId]);
      if (!group) {
        console.warn(`  ! group ${groupId} not found in prod; ref dropped`);
        return null;
      }
      // LIMITATION: scrubGroupName only checks rawNamesThisRun — names of
      // contacts already in world.yaml at append time are unavailable (they
      // were anonymized during the original extraction and the mapping was
      // never persisted). A new group whose title happens to match a
      // pre-existing contact's real name therefore survives this scrub
      // unscrubbed. We cannot recover the original names, so we always emit
      // the audit warning below regardless of whether residueTokens is
      // non-empty — the fail-safe is to flag every new group title for manual
      // review.
      const { scrubbed, residueTokens } = scrubGroupName(
        group.title,
        rawNamesThisRun
      );
      if (residueTokens.length > 0) {
        console.warn(
          `  ! group ${groupId} title has unscrubbed tokens — audit: "${scrubbed}"`
        );
      }
      // Always warn: the scrub cannot check against pre-existing contacts whose
      // real names are no longer recoverable. Audit every new group title.
      console.warn(
        `  append: group "${scrubbed}" added — title could not be checked against pre-existing contact names; audit manually`
      );
      const slug = groupSlugify(
        scrubbed,
        `g-${groupId.replace(/-/g, "").slice(0, 8)}`
      );
      (world.groups ??= []).push({ slug, id: groupId, title: scrubbed });
      groupSlugById.set(groupId, slug);
      return slug;
    };

    // Tic-less connections get a synthesized placeholder actor (NULL email +
    // name) so the connection — and its channels / org-key fall-through —
    // survives in the corpus. See placeholderActorContact in emit.ts.
    const ensurePlaceholderActor = (connectionId: string): string => {
      const { id, slugBase } = placeholderActorContact(connectionId);
      const known = contactSlugById.get(id);
      if (known) return known;
      const slug = contactSlugify(
        slugBase,
        `c-${id.replace(/-/g, "").slice(0, 8)}`
      );
      (world.contacts ??= []).push({
        slug,
        id,
        email: null,
        name: null,
        linked_to_user: false,
      });
      contactSlugById.set(id, slug);
      return slug;
    };

    const ensureConnection = async (
      connectionId: string | null
    ): Promise<string | null> => {
      if (connectionId === null) return null;
      const known = connectionSlugById.get(connectionId);
      if (known) return known;
      const { connections } = await loadConnections(client, [connectionId]);
      const conn = connections[0];
      if (!conn) {
        console.warn(
          `  ! connection ${connectionId} no longer exists in prod (no twist_instance row); thread emitted without one`
        );
        return null;
      }
      const actorSlug =
        conn.actorContactId !== null
          ? await ensureContact(conn.actorContactId)
          : ensurePlaceholderActor(conn.id);
      if (!actorSlug) return null;
      let teamSlug: string | null = null;
      if (conn.teamId !== null) {
        teamSlug = teamSlugById.get(conn.teamId) ?? null;
        if (!teamSlug) {
          const team = synthTeam(conn.teamId);
          (world.teams ??= []).push(team);
          teamSlugById.set(team.id, team.slug);
          teamSlug = team.slug;
        }
      }
      const slug = connectionSlugify(
        connectionSlugBase(conn.provider, conn.id),
        `conn-${conn.id.replace(/-/g, "").slice(0, 8)}`
      );
      (world.connections ??= []).push({
        slug,
        id: conn.id,
        provider: conn.provider,
        account_contact: actorSlug,
        team: teamSlug,
      });
      connectionSlugById.set(conn.id, slug);
      return slug;
    };

    const addEmbedding = (t: ExtractedThread): string | null => {
      if (!t.embedding || t.embedding.length !== 384) return null;
      if (
        t.embeddingSource === "note-content" &&
        !opts.allowNoteContentEmbeddings
      ) {
        droppedNoteEmbeddings++;
        return null;
      }
      const ref = embeddingRefForThread(t.id);
      if (!embRefs.has(ref)) {
        embeddingsDoc.embeddings.push({
          ref,
          source: t.embeddingSource,
          vector: t.embedding,
        });
        embRefs.add(ref);
      }
      return ref;
    };

    // Existing entries (dedupe + case numbering).
    const existingThreadIds = new Set<string>(
      opts.mode.kind === "trainings"
        ? ((target.threads ?? []) as YamlDoc[]).map((t) => t.id as string)
        : []
    );
    const existingCaseIds = new Set<string>(
      opts.mode.kind === "cases"
        ? ((target.cases ?? []) as YamlDoc[]).map((c) => c.id as string)
        : []
    );
    let nextN =
      opts.mode.kind === "cases"
        ? ((target.cases ?? []) as YamlDoc[]).reduce((max: number, c: YamlDoc) => {
            const m = /^(\d+)-/.exec(String(c.id ?? ""));
            return m ? Math.max(max, Number(m[1])) : max;
          }, 0) + 1
        : 0;

    const threads = await hydrateThreadsByIds(client, userId, opts.threadIds);
    const foundIds = new Set(threads.map((t) => t.id));
    for (const id of opts.threadIds) {
      if (!foundIds.has(id)) console.warn(`  ! thread ${id} not found for user`);
    }

    for (const t of threads) {
      if (opts.mode.kind === "trainings" && existingThreadIds.has(t.id)) {
        console.log(`  = ${t.id} already in training set; skipping`);
        continue;
      }
      const override =
        opts.mode.kind === "cases" ? opts.caseOverrides?.get(t.id) : undefined;
      const expectedSlug = t.filedToPriority
        ? prioritySlugById.get(t.filedToPriority)
        : undefined;
      // An override carries its own labels, so the current prod filing does
      // not need to resolve to a known priority slug.
      if (!expectedSlug && !override) {
        console.warn(
          `  ! thread ${t.id} filed in archived/unknown priority ${t.filedToPriority}; skipping`
        );
        continue;
      }

      const contactSlugs = (
        await Promise.all(t.contacts.map((id) => ensureContact(id)))
      ).filter((s): s is string => s !== null);
      const groupSlugs = (
        await Promise.all(t.groups.map((id) => ensureGroup(id)))
      ).filter((s): s is string => s !== null);
      const authorSlug = t.authorContactId
        ? await ensureContact(t.authorContactId)
        : null;
      const connectionSlug = await ensureConnection(t.connectionId);
      const embeddingRef = addEmbedding(t);

      if (opts.mode.kind === "trainings") {
        (target.threads ??= []).push({
          id: t.id,
          title: t.title ?? "",
          topic: anonymizeTopic(t.topic),
          contacts: contactSlugs,
          groups: groupSlugs,
          embedding_ref: embeddingRef,
          filed_to_priority: expectedSlug,
          author: authorSlug,
          connection: connectionSlug,
          facets: t.facets,
          created_at: t.createdAt,
          moved_at: t.movedAt,
        });
        existingThreadIds.add(t.id);
      } else {
        let id = makeCaseId(nextN, t.id);
        while (existingCaseIds.has(id)) {
          nextN++;
          id = makeCaseId(nextN, t.id);
        }
        existingCaseIds.add(id);
        nextN++;
        (target.cases ??= []).push({
          id,
          source_thread_id: t.id,
          tags: override?.tags ?? [describeTopic(t.topic)],
          as_of: override?.asOf ?? t.createdAt,
          description:
            override?.description ??
            `Curated from prod (manual pick, ${describeTopic(t.topic)}).`,
          candidate: {
            title: t.title ?? "",
            topic: anonymizeTopic(t.topic),
            contacts: contactSlugs,
            groups: groupSlugs,
            embedding_ref: embeddingRef,
            author: authorSlug,
            connection: connectionSlug,
            facets: t.facets,
          },
          labels: override
            ? { ...override.labels }
            : {
                gold: null,
                gold_rationale: "",
                expected: expectedSlug,
                expected_stage: null,
                expected_recorded_at: new Date().toISOString(),
              },
          notes: override?.notes ?? "",
        });
      }
      added++;
      console.log(
        `  + ${t.id} → ${override?.labels.gold ?? expectedSlug}  ${t.title?.slice(0, 60) ?? "(no title)"}`
      );
    }
  } finally {
    await client.end();
  }

  if (droppedNoteEmbeddings > 0) {
    console.log(
      `  excluded ${droppedNoteEmbeddings} note-content embedding vector(s) (kris-only data)`
    );
  }

  // Leak check over EVERY document we are about to (re)write — abort writes
  // entirely on a violation.
  const writeEmbeddings =
    embeddingsFileExisted || embeddingsDoc.embeddings.length > 0;
  const docs = [
    { path: "world.yaml", text: stringifyCorpusYaml(world) },
    {
      path:
        opts.mode.kind === "cases"
          ? "cases.yaml"
          : `trainings/${opts.mode.set}.yaml`,
      text: stringifyCorpusYaml(target),
    },
    ...(writeEmbeddings
      ? [{ path: "embeddings.yaml", text: stringifyCorpusYaml(embeddingsDoc) }]
      : []),
  ];
  const leak = leakCheck(docs, pii);
  if (leak.violations.length > 0) {
    const lines = leak.violations
      .slice(0, 50)
      .map((v) => `  ${v.path}:${v.line} [${v.kind}] "${v.value}" — ${v.context}`);
    throw new Error(
      `Leak check failed: ${leak.violations.length} raw PII value(s) outside title scope. Nothing was written.\n${lines.join("\n")}`
    );
  }
  for (const w of leak.warnings) {
    console.warn(
      `  leak-check warning: ${w.path}:${w.line} [${w.kind}] "${w.value}" — ${w.context}`
    );
  }

  await writeFile(worldPath, docs[0]!.text, "utf-8");
  await writeFile(targetPath, docs[1]!.text, "utf-8");
  if (writeEmbeddings) await writeFile(embeddingsPath, docs[2]!.text, "utf-8");
  console.log(
    `Added ${added}/${opts.threadIds.length} thread(s) to ${opts.corpus} (${
      opts.mode.kind === "cases" ? "cases.yaml" : `trainings/${opts.mode.set}.yaml`
    })`
  );
}
