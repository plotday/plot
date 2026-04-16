import type {
  TwistPermissions,
  Twists as ITwists,
} from "@plotday/twister/tools/twists";
import type { Callback } from "@plotday/twister/tools/callbacks";
import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { type TwistEnvironment, type Bindings } from "../../env";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { deployTwist } from "../deployment";
import { generateTwist } from "../generator";
import type { TwistSource } from "../types";
import { Tool } from "./tool";
import { getEffectivePlan } from "../../utils/plan";

export class Twists extends Tool implements ITwists {
  private env: Bindings;
  private ctx: { exports: ExecutionContext["exports"] };
  private db: Kysely<DB>;
  private twistInstanceId: string;
  private logSubscriptionsNamespace: DurableObjectNamespace<LogSubscriptions>;

  constructor(options: {
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
    db: Kysely<DB>;
    twistInstanceId: string;
  }) {
    super();
    this.env = options.env;
    this.ctx = options.ctx;
    this.db = options.db;
    this.twistInstanceId = options.twistInstanceId;
    this.logSubscriptionsNamespace = options.env.LOG_SUBSCRIPTIONS;
  }

  /**
   * Verifies that the user has access to the given twist package ID.
   * @throws Error if access is denied
   */
  private async verifyTwistAccess(twistPackageId: string): Promise<void> {
    // Get owner_id from twist_instance context
    const twistInstance = await this.db
      .selectFrom("twist_instance")
      .select(["owner_id"])
      .where("id", "=", this.twistInstanceId)
      .where("archived_at", "is", null)
      .executeTakeFirstOrThrow();

    const userId = twistInstance.owner_id;
    if (!userId) {
      throw new Error("User not authenticated");
    }

    // Check ownership: personal twist owned by this user, or non-personal
    // twist whose publisher topic this user is a member of.
    const hasPersonal = await this.db
      .selectFrom("twist")
      .select("id")
      .where("twist_package_id", "=", twistPackageId)
      .where("environment", "=", "personal")
      .where("user_id", "=", userId)
      .executeTakeFirst();

    if (hasPersonal) return;

    const hasPublisher = await this.db
      .selectFrom("twist")
      .innerJoin("topic", (join) =>
        join
          .onRef("topic.auto_publisher_id", "=", "twist.publisher_id")
          .on("topic.auto_maintained", "=", true)
      )
      .innerJoin("topic_member", "topic_member.topic_id", "topic.id")
      .innerJoin("user_contact", (join) =>
        join
          .onRef("user_contact.contact_id", "=", "topic_member.contact_id")
          .on("user_contact.linked", "=", true)
          .on("user_contact.archived_at", "is", null)
      )
      .select("twist.id")
      .where("twist.twist_package_id", "=", twistPackageId)
      .where("twist.environment", "!=", "personal")
      .where("user_contact.user_id", "=", userId)
      .executeTakeFirst();

    if (!hasPublisher) {
      throw new Error(
        "Access denied: You do not have permission to access this twist"
      );
    }
  }

  async create(): Promise<string> {
    // Get owner_id from twist_instance context
    const twistInstance = await this.db
      .selectFrom("twist_instance")
      .select(["owner_id"])
      .where("id", "=", this.twistInstanceId)
      .where("archived_at", "is", null)
      .executeTakeFirstOrThrow();

    const userId = twistInstance.owner_id;
    if (!userId) {
      throw new Error("User not authenticated");
    }

    // Generate a new twist package UUID. The package id is claimed lazily on
    // first deploy — the twist row for this package_id + environment is what
    // pins ownership. No upfront registration is required.
    return crypto.randomUUID();
  }

  async generate(spec: string): Promise<TwistSource> {
    // Plan check: twist builder requires Pro or Team
    const twistInstance = await this.db
      .selectFrom("twist_instance")
      .select("owner_id")
      .where("id", "=", this.twistInstanceId)
      .executeTakeFirstOrThrow();
    if (twistInstance.owner_id) {
      const { plan } = await getEffectivePlan(this.db, twistInstance.owner_id);
      if (plan !== "pro" && plan !== "team") {
        throw new Error("Twist builder requires a Pro or Team plan");
      }
    }
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
    let publisherId: number | null = null;
    if (environment === "personal") {
      const twistInstanceOwner = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirstOrThrow();
      userId = twistInstanceOwner.owner_id;
      if (!userId) throw new Error("User not authenticated");
    } else {
      // Look up the existing twist row to find the publisher that owns this
      // package. verifyTwistAccess already confirmed the caller is a member.
      const existing = await this.db
        .selectFrom("twist")
        .select("publisher_id")
        .where("twist_package_id", "=", twistPackageId)
        .where("environment", "!=", "personal")
        .where("publisher_id", "is not", null)
        .limit(1)
        .executeTakeFirst();
      if (!existing?.publisher_id) {
        throw new Error(
          "This twist package has no publisher yet — use the CLI to do the first non-personal deploy."
        );
      }
      publisherId = Number(existing.publisher_id);
    }

    // Check if twist already exists to determine if name is required
    let existingQuery = this.db
      .selectFrom("twist")
      .select(["name", "description"])
      .where("twist_package_id", "=", twistPackageId)
      .where("environment", "=", environment);
    if (environment === "personal") {
      existingQuery = existingQuery.where("user_id", "=", userId);
    }
    const existingTwist = await existingQuery.executeTakeFirst();

    // Require name for first deployment
    if (!existingTwist && !name) {
      throw new Error("name is required for first deployment");
    }

    // Use common deployment implementation
    const result = await deployTwist({
      env: this.env,
      ctx: this.ctx,
      db: this.db,
      twistPackageId,
      publisherId,
      userId,
      input: _module !== undefined ? { module: _module } : { source: _source! },
      environment,
      name: name || existingTwist?.name || "",
      description,
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
    await logSubscriptions.subscribe(twistPackageId, callback);
  }
}
