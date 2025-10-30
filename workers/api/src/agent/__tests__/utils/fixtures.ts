import type { AgentSource, Priority, Activity } from "@plotday/db/schema";
import type { ToolPermission } from "../../permissions";

/**
 * Sample AgentSource for testing
 */
export const mockAgentSource: AgentSource = {
  id: "test-agent",
  name: "Test Agent",
  description: "A test agent for unit testing",
  icon: "🧪",
  version: "1.0.0",
  module_url: "https://test.com/agent.js",
  permissions: [
    {
      domain: "plot",
      entity: "activities",
      flags: ["read", "write"],
    },
    {
      domain: "plot",
      entity: "priorities",
      flags: ["read"],
    },
  ],
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
};

/**
 * Sample Priority for testing
 */
export const mockPriority: Priority = {
  id: "priority-1",
  title: "Test Priority",
  description: "A test priority",
  status: "active",
  visibility: "private",
  owner: "user-1",
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
  icon: "📝",
  color: "#3b82f6",
  archived_at: null,
  deleted_at: null,
  meta: {},
};

/**
 * Sample Activity for testing
 */
export const mockActivity: Activity = {
  id: "activity-1",
  priority_id: "priority-1",
  title: "Test Activity",
  note: "A test activity",
  type: "task",
  status: "todo",
  start: new Date().toISOString(),
  end: null,
  duration: null,
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
  completed_at: null,
  deleted_at: null,
  recurrence: null,
  importance: 0,
  attachments: [],
  created_by: "user-1",
  meta: {},
};

/**
 * Sample tool permissions for testing
 */
export const mockToolPermissions: ToolPermission[] = [
  {
    domain: "plot",
    entity: "activities",
    flags: ["read", "write", "update"],
  },
  {
    domain: "plot",
    entity: "priorities",
    flags: ["read"],
  },
  {
    domain: "network",
    entity: "https://api.example.com/*",
    flags: ["use"],
  },
];

/**
 * Sample network URL permissions for testing
 */
export const mockNetworkPermissions: ToolPermission[] = [
  {
    domain: "network",
    entity: "https://api.github.com/*",
    flags: ["use"],
  },
  {
    domain: "network",
    entity: "https://api.example.com/v1/*",
    flags: ["use"],
  },
];

/**
 * Helper to create a custom AgentSource
 */
export function createAgentSource(overrides?: Partial<AgentSource>): AgentSource {
  return {
    ...mockAgentSource,
    ...overrides,
  };
}

/**
 * Helper to create a custom Priority
 */
export function createPriority(overrides?: Partial<Priority>): Priority {
  return {
    ...mockPriority,
    ...overrides,
  };
}

/**
 * Helper to create a custom Activity
 */
export function createActivity(overrides?: Partial<Activity>): Activity {
  return {
    ...mockActivity,
    ...overrides,
  };
}

/**
 * Helper to create custom tool permissions
 */
export function createToolPermission(
  domain: string,
  entity: string,
  flags: string[]
): ToolPermission {
  return {
    domain,
    entity,
    flags: flags as any,
  };
}
