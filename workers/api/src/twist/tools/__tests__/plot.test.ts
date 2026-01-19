import { beforeEach, describe, expect, it, vi } from "vitest";

import { ActivityType } from "@plotday/twister/plot";
import { ActivityAccess } from "@plotday/twister/tools/plot";

import { Plot } from "../plot";

// Helper to create a chainable mock for Supabase queries
function createSupabaseMock() {
  const chainableMock: any = {};
  const methods = [
    "from",
    "select",
    "insert",
    "update",
    "upsert",
    "delete",
    "eq",
    "in",
    "single",
    "maybeSingle",
    "limit",
    "order",
    "rpc",
  ];

  // Make each method return the chainable mock by default
  for (const method of methods) {
    chainableMock[method] = vi.fn(() => chainableMock);
  }

  // Set default response for terminal operations
  chainableMock.single = vi.fn(() =>
    Promise.resolve({ data: null, error: null })
  );
  chainableMock.maybeSingle = vi.fn(() =>
    Promise.resolve({ data: null, error: null })
  );

  return chainableMock;
}

// Helper to create mock env bindings
function createEnvMock() {
  const usageStub = {
    init: vi.fn(),
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
  let supabaseMock: any;
  let envMock: any;

  beforeEach(() => {
    supabaseMock = createSupabaseMock();
    envMock = createEnvMock();
  });

  describe("Permission Validation", () => {
    it("requireActivityAccess throws when no access is granted", () => {
      const plot = new Plot({
        supabase: supabaseMock,
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
        supabase: supabaseMock,
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
        supabase: supabaseMock,
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
        supabase: supabaseMock,
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
      // Setup mocks for the flow before validation
      supabaseMock.rpc = vi.fn(() =>
        Promise.resolve({ data: [], error: null })
      );

      const plot = new Plot({
        supabase: supabaseMock,
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
      ).rejects.toThrow("Event activities must have a start time");
    });

    it("createActivity with Action type auto-assigns start", async () => {
      const now = new Date();
      vi.useFakeTimers();
      vi.setSystemTime(now);

      // Setup the RPC mock for find_matching_activities_scored
      supabaseMock.rpc = vi.fn((fnName: string) => {
        if (fnName === "find_matching_activities_scored") {
          return Promise.resolve({ data: [], error: null });
        }
        return Promise.resolve({ data: null, error: null });
      });

      // Setup the from().insert().select().single() chain for activity insert
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

      const insertSelectSingleMock = vi.fn(() =>
        Promise.resolve({ data: insertedActivity, error: null })
      );
      const insertSelectMock = vi.fn(() => ({
        single: insertSelectSingleMock,
      }));
      const insertMock = vi.fn(() => ({
        select: insertSelectMock,
      }));

      // Setup from() to return different mocks based on table
      supabaseMock.from = vi.fn((table: string) => {
        if (table === "activity") {
          return {
            insert: insertMock,
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({ data: insertedActivity, error: null })
                ),
              })),
            })),
          };
        }
        if (table === "actor") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "pt-1",
                      name: "Test Twist",
                      type: "priority_twist",
                      email: null,
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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
      expect(insertMock).toHaveBeenCalled();

      // Get the inserted data and verify start was assigned
      const insertCall = insertMock.mock.calls[0]?.[0] as any;
      // For Action type, start should be set, which means 'at' should have a value
      expect(insertCall?.at).not.toBeNull();

      vi.useRealTimers();
    });

    it("createActivity returns activity ID", async () => {
      const now = new Date();

      // Setup the RPC mock
      supabaseMock.rpc = vi.fn((fnName: string) => {
        if (fnName === "find_matching_activities_scored") {
          return Promise.resolve({ data: [], error: null });
        }
        return Promise.resolve({ data: null, error: null });
      });

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

      const insertSelectSingleMock = vi.fn(() =>
        Promise.resolve({ data: insertedActivity, error: null })
      );
      const insertSelectMock = vi.fn(() => ({
        single: insertSelectSingleMock,
      }));
      const insertMock = vi.fn(() => ({
        select: insertSelectMock,
      }));

      supabaseMock.from = vi.fn((table: string) => {
        if (table === "activity") {
          return {
            insert: insertMock,
          };
        }
        if (table === "actor") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "pt-1",
                      name: "Test Twist",
                      type: "priority_twist",
                      email: null,
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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
      // Setup mock to return activity data
      supabaseMock.from = vi.fn((table: string) => {
        if (table === "activity") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "activity-123",
                      priority_id: "priority-1",
                      created_by: "pt-1",
                      mentions: null,
                      author: {
                        id: "pt-1",
                        name: "Test",
                        type: "priority_twist",
                      },
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        if (table === "priority_child") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                eq: vi.fn(() => ({
                  single: vi.fn(() =>
                    Promise.resolve({
                      data: { child_id: "priority-1" },
                      error: null,
                    })
                  ),
                })),
              })),
            })),
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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

      // Track the upsert call
      const upsertMock = vi.fn(() => ({
        select: vi.fn(() => ({
          single: vi.fn(() =>
            Promise.resolve({
              data: {
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
              },
              error: null,
            })
          ),
        })),
      }));

      supabaseMock.from = vi.fn((table: string) => {
        if (table === "note") {
          return {
            upsert: upsertMock,
            insert: vi.fn(() => ({
              select: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({ data: null, error: null })
                ),
              })),
            })),
          };
        }
        if (table === "activity") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "activity-123",
                      priority_id: "priority-1",
                      created_by: "pt-1",
                      mentions: null,
                      author: {
                        id: "pt-1",
                        name: "Test",
                        type: "priority_twist",
                        email: null,
                      },
                      assignee: null,
                      type: "note",
                      title: "Test",
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
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        if (table === "actor") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "pt-1",
                      name: "Test Twist",
                      type: "priority_twist",
                      email: null,
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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

      // Verify upsert was called with the correct onConflict option
      expect(upsertMock).toHaveBeenCalled();
      const upsertCall = upsertMock.mock.calls[0] as any[];
      expect(upsertCall?.[1]).toEqual({ onConflict: "activity_id,key" });
    });

    it("createNotes filters out empty notes silently", async () => {
      const now = new Date();

      // Track successful note creations
      const insertMock = vi.fn(() => ({
        select: vi.fn(() => ({
          single: vi.fn(() =>
            Promise.resolve({
              data: {
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
              },
              error: null,
            })
          ),
        })),
      }));

      supabaseMock.from = vi.fn((table: string) => {
        if (table === "note") {
          return {
            insert: insertMock,
          };
        }
        if (table === "activity") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "activity-123",
                      priority_id: "priority-1",
                      created_by: "pt-1",
                      mentions: null,
                      author: {
                        id: "pt-1",
                        name: "Test",
                        type: "priority_twist",
                        email: null,
                      },
                      assignee: null,
                      type: "note",
                      title: "Test",
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
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        if (table === "actor") {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                single: vi.fn(() =>
                  Promise.resolve({
                    data: {
                      id: "pt-1",
                      name: "Test Twist",
                      type: "priority_twist",
                      email: null,
                    },
                    error: null,
                  })
                ),
              })),
            })),
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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
      expect(results[0].content).toBe("Valid content");
    });
  });

  describe("Source-Based Lookup", () => {
    it("getActivity retrieves by source identifier", async () => {
      const now = new Date();

      // Mock the priority path lookup
      const prioritySelectMock = vi.fn(() => ({
        eq: vi.fn(() => ({
          single: vi.fn(() =>
            Promise.resolve({
              data: { path: "work.projects" },
              error: null,
            })
          ),
        })),
      }));

      // Mock the user_activity query
      const userActivitySelectMock = vi.fn(() => ({
        eq: vi.fn((_field: string, _value: string) => ({
          eq: vi.fn((_field2: string, _value2: string) => ({
            limit: vi.fn(() => ({
              maybeSingle: vi.fn(() =>
                Promise.resolve({
                  data: {
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
                    author: {
                      id: "pt-1",
                      name: "Test Twist",
                      type: "priority_twist",
                      email: null,
                    },
                    assignee: null,
                  },
                  error: null,
                })
              ),
            })),
          })),
        })),
      }));

      // Mock the activity_tags query
      const activityTagsSelectMock = vi.fn(() => ({
        eq: vi.fn(() => ({
          single: vi.fn(() =>
            Promise.resolve({
              data: { tags: null },
              error: null,
            })
          ),
        })),
      }));

      supabaseMock.from = vi.fn((table: string) => {
        if (table === "priority") {
          return {
            select: prioritySelectMock,
          };
        }
        if (table === "user_activity") {
          return {
            select: userActivitySelectMock,
          };
        }
        if (table === "activity_tags") {
          return {
            select: activityTagsSelectMock,
          };
        }
        return supabaseMock;
      });

      const plot = new Plot({
        supabase: supabaseMock,
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

      // Verify source and source_priority_root were used in the query
      expect(userActivitySelectMock).toHaveBeenCalled();
    });
  });

  describe("Contact Permissions", () => {
    it("addContacts requires ContactAccess.Write", async () => {
      const plot = new Plot({
        supabase: supabaseMock,
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
