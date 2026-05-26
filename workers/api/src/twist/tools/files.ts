import { sql } from "kysely";

import {
  type Files as IFiles,
  FileNotFoundError,
} from "@plotday/twister/tools/files";
import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import type { Bindings } from "../../env";
import { Tool } from "./tool";

/**
 * API-side implementation of the Files built-in tool.
 *
 * Provides connectors and twists read access to R2-stored files that were
 * attached to notes in priorities where this twist instance is installed.
 *
 * Access control mirrors the GET /files/:fileId handler in app/files.ts but
 * constrains to the calling twist instance's owner rather than an HTTP user.
 * The twist instance's owner is the user who installed the twist; only files
 * reachable through that user's thread_priority rows are returned.
 */
export class Files extends Tool implements IFiles {
  private db: Kysely<DB>;
  private env: Pick<Bindings, "FILES_BUCKET">;
  private twistInstanceId: string;

  constructor({
    db,
    env,
    twistInstanceId,
  }: {
    db: Kysely<DB>;
    env: Pick<Bindings, "FILES_BUCKET">;
    twistInstanceId: string;
  }) {
    super();
    this.db = db;
    this.env = env;
    this.twistInstanceId = twistInstanceId;
  }

  /**
   * Read a file that was uploaded by a client and attached to a note in a
   * priority where this twist is installed.
   *
   * Access check: the file must be referenced in a note whose thread is
   * filed under a priority accessible to this twist instance's owner.
   * This prevents cross-twist or cross-user file leakage.
   *
   * @param fileId The id from an ActionType.file action on a note.
   * @throws FileNotFoundError if the file does not exist in R2 or is out of scope.
   */
  async read(fileId: string): Promise<{
    data: Uint8Array;
    fileName: string;
    mimeType: string;
    fileSize: number;
  }> {
    // Step 1: Look up the R2 object key by listing with the fileId prefix.
    // The key format is `files/{fileId}/{fileName}` (set by POST /files).
    const listed = await this.env.FILES_BUCKET.list({
      prefix: `files/${fileId}/`,
    });

    if (!listed.objects.length) {
      throw new FileNotFoundError(fileId);
    }

    const objectKey = listed.objects[0].key;

    // Step 2: Verify access — the file must be referenced by a note whose
    // thread is filed under a priority accessible to this twist instance's owner.
    //
    // Query joins:
    //   twist_instance (this twist) → owner_id
    //   note.actions @> [{fileId}]  → find note containing this fileId
    //   thread_priority             → confirm the thread is in the owner's scope
    //   priority                    → confirm the priority is not archived
    //
    // This is the same pattern as GET /files/:fileId but scoped to the
    // twist's owner rather than the HTTP request user.
    // The priority join mirrors rpcUser("has_priority_access") which enforces
    // priority.archived_at IS NULL — archived priorities are inaccessible.
    const accessRow = await this.db
      .selectFrom("twist_instance")
      .innerJoin("thread_priority", (join) =>
        join.onRef("thread_priority.user_id", "=", "twist_instance.owner_id")
      )
      .innerJoin("note", (join) =>
        join.onRef("note.thread_id", "=", "thread_priority.thread_id")
      )
      .innerJoin("priority", (join) =>
        join
          .onRef("priority.id", "=", "thread_priority.priority_id")
          .on("priority.archived_at", "is", null)
      )
      .select(["thread_priority.priority_id"])
      .where("twist_instance.id", "=", this.twistInstanceId)
      .where(sql<boolean>`note.actions @> ${JSON.stringify([{ fileId }])}::jsonb`)
      .executeTakeFirst();

    if (!accessRow) {
      throw new FileNotFoundError(fileId);
    }

    // Step 3: Fetch the object from R2.
    const object = await this.env.FILES_BUCKET.get(objectKey);
    if (!object) {
      throw new FileNotFoundError(fileId);
    }

    // Step 4: Extract filename from key (files/{fileId}/{fileName}).
    const fileName = objectKey.split("/").pop() ?? "download";
    const mimeType =
      object.httpMetadata?.contentType ?? "application/octet-stream";
    const rawBuffer = await object.arrayBuffer();
    const data = new Uint8Array(rawBuffer);
    const fileSize = data.byteLength;

    return { data, fileName, mimeType, fileSize };
  }
}
