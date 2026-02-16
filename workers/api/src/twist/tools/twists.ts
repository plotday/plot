import type {
  TwistPermissions,
  Twists as ITwists,
} from "@plotday/twister/tools/twists";
import type { Callback } from "@plotday/twister/tools/callbacks";
import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { type TwistEnvironment, type Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { deployTwist } from "../deployment";
import { generateTwist } from "../generator";
import type { TwistSource } from "../types";
import { Tool } from "./tool";

export class Twists extends Tool implements ITwists {
  private env: Bindings;
  private ctx: { exports: ExecutionContext["exports"] };
  private db: Kysely<DB>;
  private priorityTwistId: string;
  private logSubscriptionsNamespace: DurableObjectNamespace<LogSubscriptions>;

  constructor(options: {
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
    db: Kysely<DB>;
    priorityTwistId: string;
  }) {
    super();
    this.env = options.env;
    this.ctx = options.ctx;
    this.db = options.db;
    this.priorityTwistId = options.priorityTwistId;
    this.logSubscriptionsNamespace = options.env.LOG_SUBSCRIPTIONS;
  }

  /**
   * Verifies that the user has access to the given twist package ID.
   * @throws Error if access is denied
   */
  private async verifyTwistAccess(twistPackageId: string): Promise<void> {
    // Get priority_id and owner_id from priority_twist context
    const priorityTwist = await this.db
      .selectFrom("priority_twist")
      .select(["priority_id", "owner_id"])
      .where("id", "=", this.priorityTwistId)
      .where("archived_at", "is", null)
      .executeTakeFirstOrThrow();

    const userId = priorityTwist.owner_id;
    if (!userId) {
      throw new Error("User not authenticated");
    }

    // Verify user has access to this twist via twist_admin
    // For personal twists, check with user_id; for non-personal, user_id is NULL
    // Try personal first
    let twistAdmin = await this.db
      .selectFrom("twist_admin")
      .select(["priority_id", "user_id", "publisher_id"])
      .where("twist_package_id", "=", twistPackageId)
      .where("user_id", "=", userId)
      .executeTakeFirst();

    // If not found, try non-personal (user_id is NULL)
    if (!twistAdmin) {
      twistAdmin = await this.db
        .selectFrom("twist_admin")
        .select(["priority_id", "user_id", "publisher_id"])
        .where("twist_package_id", "=", twistPackageId)
        .where("user_id", "is", null)
        .executeTakeFirst();
    }

    if (!twistAdmin) {
      throw new Error(
        "Access denied: You do not have permission to access this twist"
      );
    }

    // Check if user can access the twist's priority (if it has one)
    if (twistAdmin.priority_id) {
      const hasAccess = await rpcUser(this.db, "has_priority_access", {
        user_id: userId,
        priority_id: twistAdmin.priority_id!,
      });

      if (!hasAccess) {
        throw new Error(
          "Access denied: You do not have permission to access this twist's priority"
        );
      }
    }
  }

  async create(): Promise<string> {
    // Get priority_id and owner_id from priority_twist context
    const priorityTwist = await this.db
      .selectFrom("priority_twist")
      .select(["priority_id", "owner_id"])
      .where("id", "=", this.priorityTwistId)
      .where("archived_at", "is", null)
      .executeTakeFirstOrThrow();

    const userId = priorityTwist.owner_id;
    if (!userId) {
      throw new Error("User not authenticated");
    }

    // Generate a new twist package UUID
    const twistPackageId = crypto.randomUUID();

    // Insert into twist_admin table (with user_id for personal twist)
    await this.db
      .insertInto("twist_admin")
      .values({
        twist_package_id: twistPackageId,
        user_id: userId,
        publisher_id: null,
        priority_id: priorityTwist.priority_id,
      })
      .execute();

    return twistPackageId;
  }

  async generate(spec: string): Promise<TwistSource> {
    return await generateTwist({ spec, env: this.env });
  }

  async deploy(
    options:
      | {
          twistId: string;
          module: string;
          source?: never;
          environment?: Exclude<TwistEnvironment, "public">;
          name?: string;
          description?: string;
          dryRun?: boolean;
        }
      | {
          twistId: string;
          source: TwistSource;
          module?: never;
          environment?: Exclude<TwistEnvironment, "public">;
          name?: string;
          description?: string;
          dryRun?: boolean;
        }
  ): Promise<{
    version: string;
    permissions: TwistPermissions;
    errors?: string[];
  }> {
    const {
      twistId: twistPackageId,
      module: _module,
      source: _source,
      environment = "personal",
      name,
      description,
      dryRun,
    } = options;
    // Verify user has access to deploy this twist
    await this.verifyTwistAccess(twistPackageId);

    // Get user_id for personal environment
    let userId: string | null = null;
    if (environment === "personal") {
      const priorityTwistOwner = await this.db
        .selectFrom("priority_twist")
        .select("owner_id")
        .where("id", "=", this.priorityTwistId)
        .executeTakeFirstOrThrow();
      userId = priorityTwistOwner.owner_id;
      if (!userId) throw new Error("User not authenticated");
    }

    // Get twist_admin_id based on environment
    let twistAdminId: number;
    if (environment === "personal") {
      // For personal, look up by twist_package_id and user_id
      const twistAdmin = await this.db
        .selectFrom("twist_admin")
        .select("id")
        .where("twist_package_id", "=", twistPackageId)
        .where("user_id", "=", userId!)
        .executeTakeFirstOrThrow();

      twistAdminId = Number(twistAdmin.id);
    } else {
      // For non-personal, user_id should be NULL
      const twistAdmin = await this.db
        .selectFrom("twist_admin")
        .select("id")
        .where("twist_package_id", "=", twistPackageId)
        .where("user_id", "is", null)
        .executeTakeFirstOrThrow();

      twistAdminId = Number(twistAdmin.id);
    }

    // Check if twist already exists to determine if name is required
    const existingTwist = await this.db
      .selectFrom("twist")
      .select(["name", "description"])
      .where("twist_admin_id", "=", String(twistAdminId))
      .where("environment", "=", environment)
      .executeTakeFirst();

    // Require name for first deployment
    if (!existingTwist && !name) {
      throw new Error("name is required for first deployment");
    }

    // Use common deployment implementation
    const result = await deployTwist({
      env: this.env,
      ctx: this.ctx,
      db: this.db,
      twistAdminId,
      input: _module !== undefined ? { module: _module } : { source: _source! },
      environment,
      name: name || existingTwist?.name || "",
      description,
      userId,
      dryRun,
    });

    return {
      version: result.version,
      permissions: result.permissions,
      errors: result.errors,
    };
  }

  async watchLogs(twistPackageId: string, callback: Callback): Promise<void> {
    // Verify user has access to watch logs for this twist
    await this.verifyTwistAccess(twistPackageId);

    // Get the LogSubscriptions DO for this twist (sharded by twistPackageId)
    const logSubscriptionsId =
      this.logSubscriptionsNamespace.idFromName(twistPackageId);
    const logSubscriptions =
      this.logSubscriptionsNamespace.get(logSubscriptionsId);

    // Subscribe to logs for the provided twist package_id
    logSubscriptions.subscribe(twistPackageId, callback);
  }
}
