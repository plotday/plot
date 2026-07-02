import { Type } from "typebox";

import { ActorType, type Uuid } from "@plotday/twister";
import type { Plot } from "@plotday/twister/tools/plot";

export type AgentToolContext = {
  plot: Plot;
  currentFocusId: Uuid;
  currentThreadId: string;
  referencedThreadIds: Set<string>;
  /** Progress sink; wired in Task 8. No-op default. */
  onProgress: (message: string) => Promise<void>;
  /** Posts a plan card; wired in Task 6. Returns status text for the model. */
  proposePlan: (request: string) => Promise<string>;
};

export function truncateText(s: string | null | undefined, max: number): string | null {
  if (s == null) return null;
  if (s.length <= max) return s;
  return s.slice(0, max) + "…";
}

export function formatThreadNotes(
  notes: Array<{ author: string; content: string }>,
  perNoteMax = 2000,
  totalMax = 15000
): { notes: Array<{ author: string; content: string }>; truncated: boolean; totalNotes: number } {
  const out: Array<{ author: string; content: string }> = [];
  let budget = totalMax;
  let truncated = false;
  for (const n of notes) {
    const content = truncateText(n.content, perNoteMax)!;
    if (content !== n.content) truncated = true;
    if (content.length > budget) {
      truncated = true;
      break;
    }
    budget -= content.length;
    out.push({ author: n.author, content });
  }
  return { notes: out, truncated, totalNotes: notes.length };
}

export function buildAgentTools(ctx: AgentToolContext): Record<string, unknown> {
  return {
    searchPlotData: {
      description:
        "Semantically search the user's ENTIRE workspace (all focuses) — notes, threads, and links. Returns threadId for each hit so you can follow up with readThreadNotes. Pass focusId (from listFocuses) to narrow to one focus. Call this FIRST whenever the answer could involve the user's own content.",
      inputSchema: Type.Object({
        query: Type.String({ description: "What to search for." }),
        focusId: Type.Optional(
          Type.String({ description: "Limit to one focus. Omit to search everything." })
        ),
      }),
      execute: async ({ query, focusId }: { query: string; focusId?: string }) => {
        await ctx.onProgress(`Searching your workspace for “${query}”…`);
        const results = await ctx.plot.search(query, {
          focusId: focusId as Uuid | undefined,
          limit: 10,
        });
        for (const r of results) {
          if (r.thread?.id) ctx.referencedThreadIds.add(r.thread.id);
        }
        return results.map((r) => ({
          threadId: r.thread.id,
          kind: r.type,
          title: r.thread.title ?? (r.type === "link" ? r.title : null),
          focus: r.focus.title ?? null,
          content: truncateText(r.content ?? (r.type === "link" ? r.title : null), 700),
          url: r.type === "link" ? r.sourceUrl ?? null : null,
        }));
      },
    },
    listThreads: {
      description:
        "List threads in a focus (default: the current focus). Returns id, title, archived, focus. Use offset to page through more than 50.",
      inputSchema: Type.Object({
        focusId: Type.Optional(
          Type.String({ description: "Focus id from listFocuses. Defaults to the current focus." })
        ),
        includeArchived: Type.Optional(Type.Boolean({ description: "Include archived threads (default false)." })),
        offset: Type.Optional(Type.Number({ description: "Pagination offset (default 0)." })),
      }),
      execute: async ({
        focusId,
        includeArchived,
        offset,
      }: {
        focusId?: string;
        includeArchived?: boolean;
        offset?: number;
      }) => {
        const threads = await ctx.plot.getThreads({
          focusId: (focusId as Uuid | undefined) ?? ctx.currentFocusId,
          includeArchived: includeArchived ?? false,
          limit: 50,
          offset: offset ?? 0,
        });
        return threads.map((t) => ({
          id: t.id,
          title: t.title,
          archived: t.archived,
          focus: t.focus.title,
        }));
      },
    },
    listFocuses: {
      description: "List the user's focuses (projects/folders) with their ids.",
      inputSchema: Type.Object({}),
      execute: async () => {
        const focuses = await ctx.plot.getFocuses();
        return focuses.map((p) => ({ id: p.id, title: p.title }));
      },
    },
    readThreadNotes: {
      description:
        "Read the conversation of a specific thread by id (from searchPlotData or listThreads). Long threads are truncated.",
      inputSchema: Type.Object({
        threadId: Type.String({ description: "The thread id to read." }),
      }),
      execute: async ({ threadId }: { threadId: string }) => {
        const target = await ctx.plot.getThread({ id: threadId as Uuid });
        if (!target) return { error: "Thread not found." };
        ctx.referencedThreadIds.add(target.id);
        await ctx.onProgress(`Reading “${target.title ?? "thread"}”…`);
        const notes = await ctx.plot.getNotes(target);
        const mapped = notes
          .filter((n) => n.content?.trim())
          .map((n) => ({
            author: n.author.type === ActorType.Twist ? "assistant" : "user",
            content: n.content as string,
          }));
        const formatted = formatThreadNotes(mapped);
        return { title: target.title, ...formatted };
      },
    },
    proposeOperations: {
      description:
        "Propose a reorganization plan (move/archive/rename/create threads and focuses). The plan is shown to the user for approval — NOTHING changes until they approve. Only use when the user explicitly asks to reorganize.",
      inputSchema: Type.Object({
        request: Type.String({
          description: "The organization request in the user's words, e.g. 'archive all done threads'.",
        }),
      }),
      execute: async ({ request }: { request: string }) => {
        await ctx.onProgress("Drafting a reorganization plan…");
        return await ctx.proposePlan(request);
      },
    },
  };
}
