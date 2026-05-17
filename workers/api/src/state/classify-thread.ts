import { type Kysely } from "kysely";

import type { DB } from "../db-types";
import { rpc } from "../rpc";

export type ClassifyArgs = {
  userId: string;
  threadId?: string;
  embedding?: string | null;
  topic?: string | null;
  contacts?: string[] | null;
  groups?: string[] | null;
};

export type ClassifyExplanation = {
  priorityId: string | null;
  stage: string;
  scores: Record<string, unknown>;
};

function toRpcArgs(args: ClassifyArgs) {
  return {
    p_user_id: args.userId,
    p_thread_id: args.threadId ?? undefined,
    p_embedding: (args.embedding ?? undefined) as unknown,
    p_topic: args.topic ?? undefined,
    p_contacts: args.contacts ?? undefined,
    p_groups: args.groups ?? undefined,
  };
}

export async function classifyThreadForUser(
  db: Kysely<DB>,
  args: ClassifyArgs
): Promise<string | null> {
  const matched = await rpc(db, "classify_thread_for_user", toRpcArgs(args) as never);
  return (matched as string | null) ?? null;
}

export async function classifyThreadForUserExplain(
  db: Kysely<DB>,
  args: ClassifyArgs
): Promise<ClassifyExplanation> {
  // rpc() returns the first row when the function returns ≤1 row, and
  // classify_thread_for_user_explain is guaranteed to return exactly one row.
  // The kysely-codegen type is `{...}[]`, so cast through unknown.
  const result = (await rpc(
    db,
    "classify_thread_for_user_explain",
    toRpcArgs(args) as never
  )) as unknown as
    | { priority_id: string | null; stage: string; scores: Record<string, unknown> }
    | null
    | undefined;
  return {
    priorityId: result?.priority_id ?? null,
    stage: result?.stage ?? "none",
    scores: result?.scores ?? {},
  };
}
