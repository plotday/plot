import { env as testEnv } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { agentFactory } from "../factory";
import { createAgentSource, mockPriority } from "./utils/fixtures";
import { createMockSupabase } from "./utils/mocks";
import { generateTestAgentModule } from "./utils/test-agents";

describe("agentFactory", () => {
  let ctx: any;
  let supabase: any;
  const testAgentModule = generateTestAgentModule("TestAgent");

  beforeEach(async () => {
    // Store test agent module in R2
    await testEnv.AGENT_MODULES_BUCKET.put(
      "agents/test-agent/1.0.0/modules",
      testAgentModule
    );

    // Store agent config in KV
    await testEnv.AGENT_CONFIG.put(
      "test-agent:1.0.0",
      JSON.stringify({
        permissions: {
          plot: {
            activities: ["read", "write"],
            priorities: ["read"],
          },
        },
        toolPermissions: {}, // Test agent requests no tools
      })
    );

    ctx = {
      exports: testEnv,
    };

    supabase = createMockSupabase({
      agents: [
        createAgentSource({
          id: "test-agent",
          version: "1.0.0",
          module_url: "test-agent/1.0.0/module.js",
        }),
      ],
      priorities: [mockPriority],
    });
  });

  it("should create agent factory function", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: false,
    });

    expect(factory).toBeTypeOf("function");
  });

  it("should load agent and return lifecycle functions", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: false,
      module: testAgentModule,
    });

    const agent = await factory({
      id: "test-agent",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityAgentId: "pa-1",
    });

    expect(agent).toHaveProperty("activate");
    expect(agent).toHaveProperty("upgrade");
    expect(agent).toHaveProperty("deactivate");
    expect(agent).toHaveProperty("dispatch");
    expect(agent).toHaveProperty("callCallback");
    expect(agent).toHaveProperty("permissions");
  });

  it("should collect tool permissions", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: false,
      module: testAgentModule,
    });

    const agent = await factory({
      id: "test-agent",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityAgentId: "pa-1",
    });

    // Should have collected permissions from built-in tools
    expect(agent.permissions).toBeDefined();
  });

  it("should validate permissions match when checkPermissions is true", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: true,
      module: testAgentModule,
    });

    // Update stored permissions to match actual (empty for this test)
    await testEnv.AGENT_CONFIG.put(
      "test-agent:1.0.0",
      JSON.stringify({
        permissions: {},
        toolPermissions: {}, // Test agent requests no tools
      })
    );

    const agent = await factory({
      id: "test-agent",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityAgentId: "pa-1",
    });

    expect(agent).toBeDefined();
  });

  it.skip("should throw error when permissions mismatch", async () => {
    // NOTE: Permission validation now happens per-tool in builtInToolFactory
    // This test needs to be updated to use an agent that actually requests tools
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: true,
      module: testAgentModule,
    });

    // Store permissions that don't match actual
    await testEnv.AGENT_CONFIG.put(
      "test-agent:1.0.0",
      JSON.stringify({
        permissions: {
          plot: {
            activities: ["read"], // Missing "write" permission
          },
        },
        toolPermissions: {}, // Test agent requests no tools
      })
    );

    await expect(
      factory({
        id: "test-agent",
        environment: "personal",
        version: "1.0.0",
        priorityId: "priority-1",
        priorityAgentId: "pa-1",
      })
    ).rejects.toThrow("Permission mismatch");
  });

  it("should throw error when agent config not found", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: true,
      module: testAgentModule,
    });

    // Delete the config to test error case
    await testEnv.AGENT_CONFIG.delete("test-agent:1.0.0");

    await expect(
      factory({
        id: "test-agent",
        environment: "personal",
        version: "1.0.0",
        priorityId: "priority-1",
        priorityAgentId: "pa-1",
      })
    ).rejects.toThrow("Agent configuration not found");
  });

  it("should throw error when execution context exports missing", () => {
    expect(() =>
      agentFactory({
        env: testEnv,
        ctx: { exports: undefined as any },
        supabase,
      })
    ).toThrow("ExecutionContext exports missing");
  });

  it("should create builtInToolFactory that tracks tool instances", async () => {
    const factory = agentFactory({
      env: testEnv,
      ctx,
      supabase,
      checkPermissions: false,
      module: testAgentModule,
    });

    const agent = await factory({
      id: "test-agent",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityAgentId: "pa-1",
    });

    // Should have initialized and collected tools
    expect(agent.permissions).toBeDefined();
  });
});
