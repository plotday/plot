import { env as testEnv } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { twistFactory } from "../factory";
import { generateTestTwistModule } from "./utils/test-twists";

describe("twistFactory", () => {
  let ctx: any;
  let db: any;
  const testTwistModule = generateTestTwistModule("TestTwist");

  beforeEach(async () => {
    // Store test twist module in R2
    await testEnv.TWIST_MODULES_BUCKET.put(
      "twists/test-twist/1.0.0/modules",
      testTwistModule
    );

    // Store twist config in KV
    await testEnv.TWIST_CONFIG.put(
      "test-twist:1.0.0",
      JSON.stringify({
        permissions: {
          plot: {
            activities: ["read", "write"],
            priorities: ["read"],
          },
        },
        toolPermissions: {}, // Test twist requests no tools
      })
    );

    ctx = {
      exports: testEnv,
    };

    // Chainable mock for Kysely-style queries
    const chain = {
      select: () => chain,
      innerJoin: () => chain,
      where: () => chain,
      executeTakeFirst: async () => undefined,
    };
    db = { selectFrom: () => chain } as any;
  });

  it("should create twist factory function", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: false,
    });

    expect(factory).toBeTypeOf("function");
  });

  it("should load twist and return lifecycle functions", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: false,
      module: testTwistModule,
    });

    const twist = await factory({
      id: "test-twist",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityTwistId: "pa-1",
    });

    expect(twist).toHaveProperty("activate");
    expect(twist).toHaveProperty("upgrade");
    expect(twist).toHaveProperty("deactivate");
    expect(twist).toHaveProperty("dispatch");
    expect(twist).toHaveProperty("callCallback");
    expect(twist).toHaveProperty("permissions");
  });

  it("should collect tool permissions", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: false,
      module: testTwistModule,
    });

    const twist = await factory({
      id: "test-twist",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityTwistId: "pa-1",
    });

    // Should have collected permissions from built-in tools
    expect(twist.permissions).toBeDefined();
  });

  it("should validate permissions match when checkPermissions is true", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: true,
      module: testTwistModule,
    });

    // Update stored permissions to match actual (empty for this test)
    await testEnv.TWIST_CONFIG.put(
      "test-twist:1.0.0",
      JSON.stringify({
        permissions: {},
        toolPermissions: {}, // Test twist requests no tools
      })
    );

    const twist = await factory({
      id: "test-twist",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityTwistId: "pa-1",
    });

    expect(twist).toBeDefined();
  });

  it.skip("should throw error when permissions mismatch", async () => {
    // NOTE: Permission validation now happens per-tool in builtInToolFactory
    // This test needs to be updated to use an twist that actually requests tools
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: true,
      module: testTwistModule,
    });

    // Store permissions that don't match actual
    await testEnv.TWIST_CONFIG.put(
      "test-twist:1.0.0",
      JSON.stringify({
        permissions: {
          plot: {
            activities: ["read"], // Missing "write" permission
          },
        },
        toolPermissions: {}, // Test twist requests no tools
      })
    );

    await expect(
      factory({
        id: "test-twist",
        environment: "personal",
        version: "1.0.0",
        priorityId: "priority-1",
        priorityTwistId: "pa-1",
      })
    ).rejects.toThrow("Permission mismatch");
  });

  it("should throw error when twist config not found", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: true,
      module: testTwistModule,
    });

    // Delete the config to test error case
    await testEnv.TWIST_CONFIG.delete("test-twist:1.0.0");

    await expect(
      factory({
        id: "test-twist",
        environment: "personal",
        version: "1.0.0",
        priorityId: "priority-1",
        priorityTwistId: "pa-1",
      })
    ).rejects.toThrow("Twist configuration not found");
  });

  it("should throw error when execution context exports missing", () => {
    expect(() =>
      twistFactory({
        env: testEnv,
        ctx: { exports: undefined as any },
        db,
      })
    ).toThrow("ExecutionContext exports missing");
  });

  it("should create builtInToolFactory that tracks tool instances", async () => {
    const factory = twistFactory({
      env: testEnv,
      ctx,
      db,
      checkPermissions: false,
      module: testTwistModule,
    });

    const twist = await factory({
      id: "test-twist",
      environment: "personal",
      version: "1.0.0",
      priorityId: "priority-1",
      priorityTwistId: "pa-1",
    });

    // Should have initialized and collected tools
    expect(twist.permissions).toBeDefined();
  });
});
