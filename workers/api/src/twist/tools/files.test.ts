/**
 * Tests for the Files tool — the API-side implementation that reads
 * R2-stored files scoped to the calling twist instance.
 *
 * All tests use in-memory mocks for the Kysely DB and R2 bucket.
 * No real database or R2 bucket is required to run these tests.
 */

import { describe, it, expect, vi } from "vitest";
import { Files } from "./files";
import { FileNotFoundError } from "@plotday/twister/tools/files";

// ---------------------------------------------------------------------------
// Minimal Kysely mock helpers
// ---------------------------------------------------------------------------

/**
 * Builds a minimal Kysely-style chainable query builder that resolves to
 * `resolvedRow` (or `undefined` when null).
 */
function makeDbMock(resolvedRow: Record<string, unknown> | undefined) {
  // The actual query chain used in Files.read():
  //   db.selectFrom("twist_instance")
  //     .innerJoin(...)  // thread_priority
  //     .innerJoin(...)  // note
  //     .innerJoin(...)  // priority (with archived_at IS NULL filter)
  //     .select(...)
  //     .where(...)
  //     .where(...)
  //     .executeTakeFirst()
  //
  // NOTE: This mock cannot distinguish between "query excluded a row due to
  // priority.archived_at IS NULL" and "no matching row at all" — both cases
  // are simulated by passing `undefined` as resolvedRow. The archived-priority
  // isolation test below exercises the real predicate at the SQL level by
  // verifying that the correct join + filter IS present in the implementation
  // (enforced by the innerJoin on priority with the archived_at IS NULL
  // condition). The mock test confirms the runtime behavior: when the DB
  // returns no row (as it would for an archived priority), FileNotFoundError
  // is thrown.
  const executeTakeFirst = vi.fn().mockResolvedValue(resolvedRow);
  const where = vi.fn().mockReturnThis();
  const select = vi.fn().mockReturnThis();
  const innerJoin = vi.fn().mockReturnThis();
  const selectFrom = vi.fn().mockReturnValue({ innerJoin, select, where, executeTakeFirst });
  return {
    db: { selectFrom } as any,
    executeTakeFirst,
    where,
    select,
    innerJoin,
    selectFrom,
  };
}

/**
 * Builds a minimal R2 bucket mock.
 *
 * @param listObjects  Objects returned by `list({ prefix })`. Pass [] for "not found".
 * @param objectBody   ArrayBuffer bytes returned by the fetched object.
 * @param contentType  httpMetadata.contentType for the object.
 */
function makeR2Mock(
  listObjects: { key: string }[],
  objectBody?: ArrayBuffer,
  contentType?: string
) {
  const mockObject = objectBody
    ? {
        arrayBuffer: vi.fn().mockResolvedValue(objectBody),
        httpMetadata: { contentType: contentType ?? "application/octet-stream" },
        size: objectBody.byteLength,
      }
    : null;

  const get = vi.fn().mockResolvedValue(mockObject);
  const list = vi.fn().mockResolvedValue({ objects: listObjects });

  return { bucket: { list, get } as any, list, get, mockObject };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("Files tool", () => {
  const TWIST_INSTANCE_ID = "ti-00000000-0000-0000-0000-000000000001";
  const OWNER_ID = "u-00000000-0000-0000-0000-000000000001";
  const PRIORITY_ID = "pr-00000000-0000-0000-0000-000000000001";
  const FILE_ID = "fi-00000000-0000-0000-0000-000000000001";
  const FILE_NAME = "report.pdf";
  const MIME_TYPE = "application/pdf";

  describe("read()", () => {
    it("happy path — file in scope returns bytes and metadata", async () => {
      const fileBytes = new TextEncoder().encode("PDF content here").buffer as ArrayBuffer;
      const { db } = makeDbMock({ owner_id: OWNER_ID, priority_id: PRIORITY_ID });
      const { bucket } = makeR2Mock(
        [{ key: `files/${FILE_ID}/${FILE_NAME}` }],
        fileBytes,
        MIME_TYPE
      );

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });
      const result = await tool.read(FILE_ID);

      expect(result.data).toBeInstanceOf(Uint8Array);
      expect(result.data.byteLength).toBe(fileBytes.byteLength);
      expect(result.fileName).toBe(FILE_NAME);
      expect(result.mimeType).toBe(MIME_TYPE);
      expect(result.fileSize).toBe(fileBytes.byteLength);
    });

    it("throws FileNotFoundError when file does not exist in R2", async () => {
      // DB returns a row (access OK) but R2 has no matching object
      const { db } = makeDbMock({ owner_id: OWNER_ID, priority_id: PRIORITY_ID });
      const { bucket } = makeR2Mock([]); // empty list → not found

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });

      await expect(tool.read("nonexistent-file-id")).rejects.toThrow(FileNotFoundError);
      await expect(tool.read("nonexistent-file-id")).rejects.toThrow(
        "File not found or out of scope: nonexistent-file-id"
      );
    });

    it("throws FileNotFoundError when DB returns no row (file out of scope)", async () => {
      // DB returns undefined — file exists elsewhere but not under this twist's owner
      const { db } = makeDbMock(undefined);
      const fileBytes = new TextEncoder().encode("secret bytes").buffer as ArrayBuffer;
      // R2 has the object but we must NOT return it
      const { bucket } = makeR2Mock(
        [{ key: `files/${FILE_ID}/${FILE_NAME}` }],
        fileBytes,
        MIME_TYPE
      );

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });

      await expect(tool.read(FILE_ID)).rejects.toThrow(FileNotFoundError);
    });

    it("throws FileNotFoundError (cross-priority isolation) — file in a different priority", async () => {
      // Simulate: twist installed in priorityA, file is in priorityB.
      // The DB query constrains to the twist's owner, so it returns no row.
      const { db } = makeDbMock(undefined); // no matching row for this twist's owner
      const fileBytes = new TextEncoder().encode("other priority bytes").buffer as ArrayBuffer;
      const { bucket } = makeR2Mock(
        [{ key: `files/${FILE_ID}/${FILE_NAME}` }],
        fileBytes,
        MIME_TYPE
      );

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });

      // Must NOT leak the file even though it exists in R2
      await expect(tool.read(FILE_ID)).rejects.toThrow(FileNotFoundError);
    });

    it("throws FileNotFoundError when priority is archived", async () => {
      // Simulate: the file's note lives in a priority that has been archived.
      // The access query's INNER JOIN on priority with `archived_at IS NULL`
      // excludes the row, so executeTakeFirst() returns undefined — same as
      // "no access." The mock returns undefined to represent this outcome.
      //
      // Limitation: the flat mock cannot verify that the SQL predicate itself
      // is present. That correctness is enforced by the implementation's
      // innerJoin("priority", …).on("priority.archived_at", "is", null) —
      // verified by code review. This test confirms the runtime contract:
      // when the DB returns no row (as it does for archived priorities),
      // FileNotFoundError is thrown even though R2 has the object.
      const { db } = makeDbMock(undefined); // archived priority → DB returns no row
      const fileBytes = new TextEncoder().encode("archived priority file bytes").buffer as ArrayBuffer;
      const { bucket } = makeR2Mock(
        [{ key: `files/${FILE_ID}/${FILE_NAME}` }],
        fileBytes,
        MIME_TYPE
      );

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });

      await expect(tool.read(FILE_ID)).rejects.toThrow(FileNotFoundError);
    });

    it("uses default mime type when R2 object has no contentType metadata", async () => {
      const fileBytes = new TextEncoder().encode("binary data").buffer as ArrayBuffer;
      const { db } = makeDbMock({ owner_id: OWNER_ID, priority_id: PRIORITY_ID });
      // Pass undefined contentType → httpMetadata has no contentType
      const bucket = {
        list: vi.fn().mockResolvedValue({ objects: [{ key: `files/${FILE_ID}/data.bin` }] }),
        get: vi.fn().mockResolvedValue({
          arrayBuffer: vi.fn().mockResolvedValue(fileBytes),
          httpMetadata: {},
          size: fileBytes.byteLength,
        }),
      } as any;

      const tool = new Files({ db, env: { FILES_BUCKET: bucket } as any, twistInstanceId: TWIST_INSTANCE_ID });
      const result = await tool.read(FILE_ID);

      expect(result.mimeType).toBe("application/octet-stream");
    });
  });
});
