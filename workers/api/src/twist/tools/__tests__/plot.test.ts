import { beforeEach, describe, expect, it, vi } from "vitest";

import { ActivityType } from "@plotday/twister/plot";
import { ActivityAccess } from "@plotday/twister/tools/plot";

import { Plot } from "../plot";

vi.mock("../../../rpc", () => ({
  rpc: vi.fn(async (_db: unknown, fn: string) => {
    if (fn === "find_matching_activities_scored") return [];
    if (fn === "get_priority_twist_owner_contact") return "contact-1";
    if (fn === "get_users_with_priority_access") return [];
    return null;
  }),
  rpcUser: vi.fn(async () => {
    throw new Error("rpcUser not expected in plot tests");
  }),
}));

type SelectResult = Record<string, any> | null;

function createSelectQuery(result: SelectResult, executeResult?: any[]) {
  const query: any = {};
  query.select = vi.fn(() => query);
  query.selectAll = vi.fn(() => query);
  query.where = vi.fn(() => query);
  query.orderBy = vi.fn(() => query);
  query.limit = vi.fn(() => query);
  query.execute = vi.fn(async () =>
    executeResult ?? (Array.isArray(result) ? result : result ? [result] : [])
  );
  query.executeTakeFirst = vi.fn(async () => result);
  query.executeTakeFirstOrThrow = vi.fn(async () => {
    if (!result) throw new Error("Not found");
    return result;
  });
  return query;
}

function createInsertQuery(result: any) {
  const query: any = {};
  query._values = undefined as any;
  query._onConflictColumns = undefined as any;
  query.values = vi.fn((values: any) => {
    query._values = values;
    return query;
  });
  query.onConflict = vi.fn((cb: (oc: any) => void) => {
    if (cb) {
      const action: any = {
        doUpdateSet: vi.fn(() => query),
        doNothing: vi.fn(() => query),
      };
      const ocBuilder: any = {
        columns: vi.fn((cols: string[]) => {
          query._onConflictColumns = cols;
          return action;
        }),
      };
      cb(ocBuilder);
    }
    return query;
  });
  query.returningAll = vi.fn(() => query);
  query.returning = vi.fn(() => query);
  query.execute = vi.fn(async () =>
    Array.isArray(result) ? result : result ? [result] : []
  );
  query.executeTakeFirst = vi.fn(async () => result);
  query.executeTakeFirstOrThrow = vi.fn(async () => {
    if (!result) throw new Error("Not found");
    return result;
  });
  return query;
}

// Helper to create a chainable mock for Kysely queries
function createDbMock() {
  return {
    selectFrom: vi.fn(() => createSelectQuery(null)),
    insertInto: vi.fn(() => createInsertQuery(null)),
    updateTable: vi.fn(),
    deleteFrom: vi.fn(),
  } as any;
}

// Helper to create mock env bindings
function createEnvMock() {
  const usageStub = {
    init: vi.fn().mockResolvedValue(undefined),
    track: vi.fn(),
    getUsage: vi.fn().mockResolvedValue({ tokens: 0, cost: 0 }),
  };

  return {
    AI: {
      run: vi.fn().mockResolvedValue({ data: [] }),
    },
    AI_GATEWAY_ACCOUNT_ID: "test-account",
    AI_GATEWAY_ID: "test-gateway",
    AI_GATEWAY_TOKEN: "test-token",
    ANTHROPIC_API_KEY: "test-anthropic-key",
    USAGE: {
      idFromName: vi.fn().mockReturnValue("test-usage-id"),
      get: vi.fn().mockReturnValue(usageStub),
    },
  } as any;
}

describe("Plot", () => {
  let dbMock: any;
  let envMock: any;

  beforeEach(() => {
    dbMock = createDbMock();
    envMock = createEnvMock();
  });

  describe("Permission Validation", () => {
    it("requireActivityAccess throws when no access is granted", () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {}, // No activity access configured
        env: envMock,
      });

      expect(() => plot.requireActivityAccess(ActivityAccess.Create)).toThrow(
        "Activity access not requested"
      );
    });

    it("requireActivityAccess allows Create when Create is granted", () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      // Should not throw
      expect(() =>
        plot.requireActivityAccess(ActivityAccess.Create)
      ).not.toThrow();
    });

    it("ActivityAccess.Create includes Respond permissions", () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      // Create permission (1) should include Respond permission (0)
      expect(() =>
        plot.requireActivityAccess(ActivityAccess.Respond)
      ).not.toThrow();
    });
  });

  describe("Activity Creation", () => {
    it("createActivity requires ActivityAccess.Create permission", async () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {}, // No activity access
        env: envMock,
      });

      await expect(
        plot.createActivity({
          type: ActivityType.Note,
          title: "Test Activity",
        })
      ).rejects.toThrow("Activity access not requested");
    });

    it("createActivity with Event type requires start time", async () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      await expect(
        plot.createActivity({
          type: ActivityType.Event,
          title: "Test Event",
          // No start time provided
        })
      ).rejects.toThrow("Events must have a start and end.");
    });

    it("createActivity with Action type auto-assigns start", async () => {
      const now = new Date();
      vi.useFakeTimers();
      vi.setSystemTime(now);

      // Setup the insert chain for activity insert
      const insertedActivity = {
        id: "activity-123",
        author_id: "pt-1",
        created_by: "pt-1",
        priority_id: "priority-1",
        type: "action",
        title: "Test Action",
        created_at: now.toISOString(),
        updated_at: now.toISOString(),
      };

      const activityInsert = createInsertQuery(insertedActivity);
      dbMock.insertInto = vi.fn((table: string) => {
        if (table === "activity") return activityInsert;
        return createInsertQuery(null);
      });

      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      await plot.createActivity({
        type: ActivityType.Action,
        title: "Test Action",
        // No start time provided - should be auto-assigned
      });

      // Verify insert was called
      expect(activityInsert.values).toHaveBeenCalled();

      // Get the inserted data and verify start was assigned
      const insertCall = activityInsert._values as any;
      // For Action type, start should be set, which means 'at' should have a value
      expect(insertCall?.at).not.toBeNull();

      vi.useRealTimers();
    });

    it("createActivity returns activity ID", async () => {
      const now = new Date();

      // Setup the activity that will be "inserted"
      const insertedActivity = {
        id: "activity-123",
        author_id: "pt-1",
        created_by: "pt-1",
        priority_id: "priority-1",
        type: "note",
        title: "Test Activity",
        created_at: now.toISOString(),
        source_created_at: now.toISOString(),
        updated_at: now.toISOString(),
        private: false,
        draft: false,
        at: null,
        on: null,
        duration: null,
        done_at: null,
        meta: null,
        archived_at: null,
        recurrence_rule: null,
        recurrence_exdates: null,
      };

      const activityInsert = createInsertQuery(insertedActivity);
      dbMock.insertInto = vi.fn((table: string) => {
        if (table === "activity") return activityInsert;
        return createInsertQuery(null);
      });

      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      const result = await plot.createActivity({
        type: ActivityType.Note,
        title: "Test Activity",
      });

      // Verify the returned value is the activity ID
      expect(result).toBe("activity-123");
    });
  });

  describe("Note Operations", () => {
    it("createNote rejects fully empty notes", async () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      await expect(
        plot.createNote({
          activity: { id: "activity-123" as any },
          content: "", // Empty content
          // No links
          // No mentions
        })
      ).rejects.toThrow("Cannot create fully empty note");
    });

    it("createNote with key performs upsert", async () => {
      const now = new Date();

      const insertedNote = {
        id: "note-123",
        activity_id: "activity-123",
        author_id: "pt-1",
        created_by: "pt-1",
        content: "Test content",
        key: "test-key",
        created_at: now.toISOString(),
        source_created_at: now.toISOString(),
        private: false,
        links: null,
        mentions: null,
        archived_at: null,
      };

      const noteInsert = createInsertQuery(insertedNote);
      dbMock.insertInto = vi.fn((table: string) => {
        if (table === "note") return noteInsert;
        return createInsertQuery(null);
      });
      dbMock.selectFrom = vi.fn((table: string) => {
        if (table === "activity") {
          return createSelectQuery({ priority_id: "priority-1" });
        }
        return createSelectQuery(null);
      });

      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      await plot.createNote({
        activity: { id: "activity-123" as any },
        content: "Test content",
        key: "test-key",
      });

      // Verify onConflict was configured for activity_id,key
      expect(noteInsert._onConflictColumns).toEqual(["activity_id", "key"]);
    });

    it("createNotes filters out empty notes silently", async () => {
      const now = new Date();

      const insertedNote = {
        id: "note-123",
        activity_id: "activity-123",
        author_id: "pt-1",
        created_by: "pt-1",
        content: "Valid content",
        key: null,
        created_at: now.toISOString(),
        source_created_at: now.toISOString(),
        private: false,
        links: null,
        mentions: null,
        archived_at: null,
      };

      dbMock.insertInto = vi.fn((table: string) => {
        if (table === "note") return createInsertQuery(insertedNote);
        return createInsertQuery(null);
      });
      dbMock.selectFrom = vi.fn((table: string) => {
        if (table === "activity") {
          return createSelectQuery({ priority_id: "priority-1" });
        }
        return createSelectQuery(null);
      });

      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      // Call createNotes with a mix of valid and empty notes
      const results = await plot.createNotes([
        {
          activity: { id: "activity-123" as any },
          content: "", // Empty - should be filtered out
        },
        {
          activity: { id: "activity-123" as any },
          content: "Valid content", // Valid - should be created
        },
        {
          activity: { id: "activity-123" as any },
          content: "   ", // Whitespace only - should be filtered out
        },
      ]);

      // Only the valid note should be returned
      expect(results.length).toBe(1);
      expect(results[0]).toBe("note-123");
    });
  });

  describe("Source-Based Lookup", () => {
    it("getActivity retrieves by source identifier", async () => {
      const now = new Date();
      const userActivityRow = {
        id: "activity-123",
        source: "external://item-456",
        source_priority_root: "work",
        priority_id: "priority-1",
        author_id: "pt-1",
        created_by: "pt-1",
        type: "note",
        title: "Test Activity",
        at: null,
        on: null,
        duration: null,
        done_at: null,
        meta: null,
        private: false,
        draft: false,
        created_at: now.toISOString(),
        source_created_at: now.toISOString(),
        updated_at: now.toISOString(),
        archived_at: null,
      };

      const authorRow = {
        id: "pt-1",
        name: "Test Twist",
        type: "priority_twist",
        email: null,
        archived_at: null,
        avatar_url: null,
        created_at: now.toISOString(),
        updated_at: now.toISOString(),
      };

      dbMock.selectFrom = vi.fn((table: string) => {
        if (table === "priority_twist") {
          return createSelectQuery({ owner_id: "user-1" });
        }
        if (table === "priority") {
          return createSelectQuery({ path: "work.projects" });
        }
        if (table === "activity") {
          return createSelectQuery({ id: "activity-123" });
        }
        if (table === "user.activity") {
          return createSelectQuery(userActivityRow);
        }
        if (table === "actor") {
          return createSelectQuery(authorRow);
        }
        if (table === "activity_tags") {
          return createSelectQuery({ tags: null });
        }
        return createSelectQuery(null);
      });

      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          activity: {
            access: ActivityAccess.Create,
          },
        },
        env: envMock,
      });

      const result = await plot.getActivity({ source: "external://item-456" });

      // Verify the result
      expect(result).not.toBeNull();
      expect(result!.id).toBe("activity-123");

      // Verify user activity lookup was performed
      expect(dbMock.selectFrom).toHaveBeenCalledWith("user.activity");
    });
  });

  describe("Contact Permissions", () => {
    it("addContacts requires ContactAccess.Write", async () => {
      const plot = new Plot({
        db: dbMock,
        priorityId: "priority-1",
        priorityTwistId: "pt-1",
        options: {
          // No contact access configured
        },
        env: envMock,
      });

      await expect(
        plot.addContacts([{ email: "test@example.com", name: "Test User" }])
      ).rejects.toThrow("Contact access not requested. Required: Write");
    });
  });
});
