import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  MAX_ARTICLE_CONTENT_BYTES,
  capArticleContent,
  drainPendingArticleInjections,
  extractArticleUrlsFromActions,
  fulfillArticleInjection,
  handleArticleLinksForNewNote,
  insertArticleNote,
  registerArticleInjection,
} from "./inject";

// getPlotTwistInstanceId is exercised by trial.ts; here we stub it so tests
// don't need to seed the twist/twist_instance graph. The factory must NOT
// reference module-scope consts (vitest hoists vi.mock above them) — each test
// sets the resolved value via vi.mocked(...).mockResolvedValue(...).
vi.mock("../utils/trial", () => ({
  getPlotTwistInstanceId: vi.fn(),
}));
import { getPlotTwistInstanceId } from "../utils/trial";

// requestExtraction hits the extraction queue + a real network fetch path in
// production; here we stub it so handleArticleLinksForNewNote tests control
// the returned extracted_url status without seeding the queue.
const requestExtractionMock = vi.fn();
vi.mock("../extract/request", () => ({
  requestExtraction: (...args: unknown[]) => requestExtractionMock(...args),
}));

const PLOT_INSTANCE_ID = "00000000-0000-0000-0000-0000000000aa";
const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/** Run `fn` inside a transaction that always rolls back; FK/triggers relaxed. */
async function withRollbackTx(
  fn: (trx: Kysely<DB>) => Promise<void>
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await fn(trx as unknown as Kysely<DB>);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe("extractArticleUrlsFromActions", () => {
  it("returns http(s) URLs from external actions", () => {
    const actions = [
      { type: "external", title: "A", url: "https://example.com/a" },
      { type: "external", title: "B", url: "http://example.org/b" },
    ];
    expect(extractArticleUrlsFromActions(actions)).toEqual([
      "https://example.com/a",
      "http://example.org/b",
    ]);
  });

  it("ignores non-external actions and non-http urls", () => {
    const actions = [
      { type: "auth", title: "x", url: "https://nope.com" },
      { type: "external", title: "mailto", url: "mailto:a@b.com" },
      { type: "external", title: "app", url: "plot://thread/1" },
      { type: "external", title: "ok", url: "https://ok.com" },
    ];
    expect(extractArticleUrlsFromActions(actions)).toEqual(["https://ok.com"]);
  });

  it("returns [] for null / non-array / malformed input", () => {
    expect(extractArticleUrlsFromActions(null)).toEqual([]);
    expect(extractArticleUrlsFromActions("nope")).toEqual([]);
    expect(extractArticleUrlsFromActions([{ type: "external" }])).toEqual([]);
  });
});

describe("capArticleContent", () => {
  it("returns short content unchanged", () => {
    expect(capArticleContent("# Hi\n\nshort")).toBe("# Hi\n\nshort");
  });

  it("truncates content larger than the byte cap and appends a marker", () => {
    const big = "x".repeat(MAX_ARTICLE_CONTENT_BYTES + 500);
    const capped = capArticleContent(big);
    expect(capped.length).toBeLessThan(big.length);
    expect(capped.endsWith("… (truncated)")).toBe(true);
  });
});

describe.skipIf(!DATABASE_URL)("registerArticleInjection", () => {
  it("inserts a pending row and is idempotent per (thread_id, url_hash)", async () => {
    await withRollbackTx(async (trx) => {
      const args = {
        urlHash: "hash-" + randomUUID(),
        threadId: randomUUID(),
        priorityId: randomUUID(),
        requestedBy: randomUUID(),
      };
      await registerArticleInjection(trx, args);
      await registerArticleInjection(trx, args); // second call is a no-op

      const rows = await trx
        .selectFrom("extracted_url_injection")
        .selectAll()
        .where("url_hash", "=", args.urlHash)
        .execute();
      expect(rows).toHaveLength(1);
      expect(rows[0].status).toBe("pending");
      expect(rows[0].thread_id).toBe(args.threadId);
    });
  });
});

describe.skipIf(!DATABASE_URL)("insertArticleNote", () => {
  it("inserts a note authored by the Plot instance, idempotent by key", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const threadId = randomUUID();
      const urlHash = "hash-" + randomUUID();

      const first = await insertArticleNote(trx, {
        threadId,
        priorityId: randomUUID(),
        urlHash,
        markdown: "# Title\n\nBody",
      });
      const second = await insertArticleNote(trx, {
        threadId,
        priorityId: randomUUID(),
        urlHash,
        markdown: "# Title\n\nBody",
      });

      expect(first).toBe("inserted");
      expect(second).toBe("exists"); // idempotent

      const notes = await trx
        .selectFrom("note")
        .selectAll()
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .execute();
      expect(notes).toHaveLength(1);
      expect(notes[0].created_by).toBe(PLOT_INSTANCE_ID);
      expect(notes[0].author_id).toBe(PLOT_INSTANCE_ID);
      expect(notes[0].content).toBe("# Title\n\nBody");
      expect(notes[0].link_id).toBeNull();
    });
  });

  it("returns 'no_author' when the user has no Plot instance", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValueOnce(null);
      const result = await insertArticleNote(trx, {
        threadId: randomUUID(),
        priorityId: randomUUID(),
        urlHash: "hash-" + randomUUID(),
        markdown: "x",
      });
      expect(result).toBe("no_author");
    });
  });
});

function fakeEnvWithMarkdown(markdown: string | null) {
  const fetchMock = vi.fn(async () => new Response("ok"));
  return {
    env: {
      ARTICLES_BUCKET: {
        get: vi.fn(async () =>
          markdown === null ? null : { text: async () => markdown }
        ),
      },
      SYNC_NOTIFY: {
        idFromName: () => "fake-do-id",
        get: () => ({ fetch: fetchMock }),
      },
    } as unknown as Bindings,
    fetchMock,
  };
}

describe.skipIf(!DATABASE_URL)("fulfillArticleInjection", () => {
  it("injects the note and marks completed rows fulfilled, then notifies", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      const priorityId = randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://example.com/a",
          url_hash: urlHash,
          status: "completed",
          r2_key: `${urlHash}.md`,
        })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: threadId,
          priority_id: priorityId,
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env, fetchMock } = fakeEnvWithMarkdown("# Hello\n\nWorld");
      await fulfillArticleInjection(env, trx, urlHash);

      const note = await trx
        .selectFrom("note")
        .selectAll()
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .executeTakeFirst();
      expect(note?.content).toBe("# Hello\n\nWorld");

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("fulfilled");
      expect(fetchMock).toHaveBeenCalledOnce();
    });
  });

  it("marks pending rows skipped on a terminal failure (no note)", async () => {
    await withRollbackTx(async (trx) => {
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://paywall.com/a",
          url_hash: urlHash,
          status: "paywalled",
        })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: threadId,
          priority_id: randomUUID(),
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env } = fakeEnvWithMarkdown(null);
      await fulfillArticleInjection(env, trx, urlHash);

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("skipped");
      const note = await trx
        .selectFrom("note")
        .select("id")
        .where("thread_id", "=", threadId)
        .executeTakeFirst();
      expect(note).toBeUndefined();
    });
  });

  it("isolates a failing row so it doesn't block the rest of the batch", async () => {
    await withRollbackTx(async (trx) => {
      const urlHash = "hash-" + randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://example.com/isolation",
          url_hash: urlHash,
          status: "completed",
          r2_key: `${urlHash}.md`,
        })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values([
          {
            url_hash: urlHash,
            thread_id: randomUUID(),
            priority_id: randomUUID(),
            requested_by: randomUUID(),
            status: "pending",
          },
          {
            url_hash: urlHash,
            thread_id: randomUUID(),
            priority_id: randomUUID(),
            requested_by: randomUUID(),
            status: "pending",
          },
        ])
        .execute();

      vi.mocked(getPlotTwistInstanceId)
        .mockResolvedValueOnce(PLOT_INSTANCE_ID)
        .mockRejectedValueOnce(new Error("insert boom"));

      const { env } = fakeEnvWithMarkdown("# A\n\ntext");
      await expect(
        fulfillArticleInjection(env, trx, urlHash)
      ).resolves.not.toThrow();

      const rows = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .execute();
      expect(rows.filter((r) => r.status === "fulfilled")).toHaveLength(1);
      expect(rows.filter((r) => r.status === "pending")).toHaveLength(1);
    });
  });

  it("is a no-op while extraction is still in progress", async () => {
    await withRollbackTx(async (trx) => {
      const urlHash = "hash-" + randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({ url: "https://x.com", url_hash: urlHash, status: "extracting" })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: randomUUID(),
          priority_id: randomUUID(),
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env } = fakeEnvWithMarkdown(null);
      await fulfillArticleInjection(env, trx, urlHash);

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("pending");
    });
  });
});

describe.skipIf(!DATABASE_URL)("drainPendingArticleInjections", () => {
  it("fulfills completed and skips failed, leaving in-progress pending", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const mk = async (status: string) => {
        const urlHash = "hash-" + randomUUID();
        const threadId = randomUUID();
        await trx
          .insertInto("extracted_url")
          .values({
            url: `https://x.com/${urlHash}`,
            url_hash: urlHash,
            status,
            r2_key: `${urlHash}.md`,
          })
          .execute();
        await trx
          .insertInto("extracted_url_injection")
          .values({
            url_hash: urlHash,
            thread_id: threadId,
            priority_id: randomUUID(),
            requested_by: randomUUID(),
            status: "pending",
          })
          .execute();
        return urlHash;
      };
      const done = await mk("completed");
      const failed = await mk("failed");
      const busy = await mk("extracting");

      const { env } = fakeEnvWithMarkdown("# Body\n\ntext");
      await drainPendingArticleInjections(env, trx);

      const status = async (h: string) =>
        (
          await trx
            .selectFrom("extracted_url_injection")
            .select("status")
            .where("url_hash", "=", h)
            .executeTakeFirst()
        )?.status;
      expect(await status(done)).toBe("fulfilled");
      expect(await status(failed)).toBe("skipped");
      expect(await status(busy)).toBe("pending");
    });
  });
});

describe.skipIf(!DATABASE_URL)("handleArticleLinksForNewNote", () => {
  it("registers + injects when the URL is already completed", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      requestExtractionMock.mockReset();
      requestExtractionMock.mockResolvedValue({
        status: "completed",
        url_hash: urlHash,
      });
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://example.com/a",
          url_hash: urlHash,
          status: "completed",
          r2_key: `${urlHash}.md`,
        })
        .execute();

      const { env } = fakeEnvWithMarkdown("# Article\n\ntext");
      await handleArticleLinksForNewNote(env, trx, {
        noteId: randomUUID(),
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [
          { type: "external", title: "A", url: "https://example.com/a" },
        ],
      });

      const note = await trx
        .selectFrom("note")
        .select("content")
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .executeTakeFirst();
      expect(note?.content).toBe("# Article\n\ntext");
    });
  });

  it("skips terminal-failed URLs without registering", async () => {
    await withRollbackTx(async (trx) => {
      const threadId = randomUUID();
      requestExtractionMock.mockReset();
      requestExtractionMock.mockResolvedValue({
        status: "auth_required",
        url_hash: "hash-" + randomUUID(),
      });
      const { env } = fakeEnvWithMarkdown(null);
      await handleArticleLinksForNewNote(env, trx, {
        noteId: randomUUID(),
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [{ type: "external", title: "x", url: "https://jira.example/x" }],
      });
      const rows = await trx
        .selectFrom("extracted_url_injection")
        .select("id")
        .where("thread_id", "=", threadId)
        .execute();
      expect(rows).toHaveLength(0);
    });
  });

  it("does nothing when the note is not the first note of its thread", async () => {
    await withRollbackTx(async (trx) => {
      const threadId = randomUUID();
      const noteId = randomUUID();
      requestExtractionMock.mockReset();
      // Pre-existing earlier note on the thread.
      await trx
        .insertInto("note")
        .values({
          thread_id: threadId,
          content: "earlier",
          created_by: randomUUID(),
          author_id: randomUUID(),
        })
        .execute();
      const { env } = fakeEnvWithMarkdown(null);
      await handleArticleLinksForNewNote(env, trx, {
        noteId,
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [{ type: "external", title: "A", url: "https://example.com/a" }],
      });
      expect(requestExtractionMock).not.toHaveBeenCalled();
    });
  });

  it("filters out an SSRF-target URL before calling requestExtraction", async () => {
    requestExtractionMock.mockReset();
    await withRollbackTx(async (trx) => {
      const { env } = fakeEnvWithMarkdown(null);
      await handleArticleLinksForNewNote(env, trx, {
        noteId: randomUUID(),
        threadId: randomUUID(),
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [
          {
            type: "external",
            title: "meta",
            url: "http://169.254.169.254/latest/meta-data",
          },
        ],
      });
    });
    expect(requestExtractionMock).not.toHaveBeenCalled();
  });
});
