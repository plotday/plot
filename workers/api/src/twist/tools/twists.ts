import type {
  TwistPermissions,
  Twists as ITwists,
} from "@plotday/twister/tools/twists";
import type { Callback } from "@plotday/twister/tools/callbacks";
import type { SupabaseClient } from "@plotday/db";

import { type TwistEnvironment, type Bindings } from "../../env";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { getUser } from "../../utils/auth";
import { deployTwist } from "../deployment";
import { generateTwist } from "../generator";
import type { TwistSource } from "../types";
import { Tool } from "./tool";

export class Twists extends Tool implements ITwists {
  private env: Bindings;
  private ctx: { exports: ExecutionContext["exports"] };
  private supabase: SupabaseClient;
  private priorityTwistId: string;
  private logSubscriptionsNamespace: DurableObjectNamespace<LogSubscriptions>;

  constructor(options: {
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
    supabase: SupabaseClient;
    priorityTwistId: string;
  }) {
    super();
    this.env = options.env;
    this.ctx = options.ctx;
    this.supabase = options.supabase;
    this.priorityTwistId = options.priorityTwistId;
    this.logSubscriptionsNamespace = options.env.LOG_SUBSCRIPTIONS;
  }

  /**
   * Verifies that the user has access to the given twist package ID.
   * @throws Error if access is denied
   */
  private async verifyTwistAccess(twistPackageId: string): Promise<void> {
    // Get priority_id from priority_twist context
    const { data: priorityTwist, error: fetchError } = await this.supabase
      .from("priority_twist")
      .select("priority_id")
      .eq("id", this.priorityTwistId)
      .is("archived_at", null)
      .single();

    if (fetchError || !priorityTwist) {
      throw new Error(
        `Failed to fetch priority context: ${fetchError?.message}`
      );
    }

    // Get user info to check which twist_admin entry to query
    const { user } = await getUser(this.supabase);
    if (!user) {
      throw new Error("User not authenticated");
    }

    // Verify user has access to this twist via twist_admin
    // For personal twists, check with user_id; for non-personal, user_id is NULL
    // Try personal first
    let twistAdmin = await this.supabase
      .from("twist_admin")
      .select("priority_id, user_id, publisher_id")
      .eq("twist_package_id", twistPackageId)
      .eq("user_id", user.id)
      .maybeSingle();

    // If not found, try non-personal (user_id is NULL)
    if (!twistAdmin.data) {
      twistAdmin = await this.supabase
        .from("twist_admin")
        .select("priority_id, user_id, publisher_id")
        .eq("twist_package_id", twistPackageId)
        .is("user_id", null)
        .maybeSingle();
    }

    if (twistAdmin.error || !twistAdmin.data) {
      throw new Error(
        "Access denied: You do not have permission to access this twist"
      );
    }

    // Check if user can access the twist's priority (if it has one)
    if (twistAdmin.data.priority_id) {
      const { data: hasAccess } = await this.supabase.rpc(
        "can_access_priority",
        {
          _priority_id: twistAdmin.data.priority_id,
        }
      );

      if (!hasAccess) {
        throw new Error(
          "Access denied: You do not have permission to access this twist's priority"
        );
      }
    }
  }

  async create(): Promise<string> {
    // Get priority_id from priority_twist context
    const { data: priorityTwist, error: fetchError } = await this.supabase
      .from("priority_twist")
      .select("priority_id")
      .eq("id", this.priorityTwistId)
      .is("archived_at", null)
      .single();

    if (fetchError || !priorityTwist) {
      throw new Error(
        `Failed to fetch priority context: ${fetchError?.message}`
      );
    }

    // Get user info
    const { user } = await getUser(this.supabase);
    if (!user) {
      throw new Error("User not authenticated");
    }

    // Generate a new twist package UUID
    const twistPackageId = crypto.randomUUID();

    // Insert into twist_admin table (with user_id for personal twist)
    const { error } = await this.supabase.from("twist_admin").insert({
      twist_package_id: twistPackageId,
      user_id: user.id,
      publisher_id: null,
      priority_id: priorityTwist.priority_id,
    });

    if (error) {
      throw new Error(`Failed to create twist admin: ${error.message}`);
    }

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
      const { user } = await getUser(this.supabase);
      if (!user) {
        throw new Error("User not authenticated");
      }
      userId = user.id;
    }

    // Get twist_admin_id based on environment
    let twistAdminId: number;
    if (environment === "personal") {
      // For personal, look up by twist_package_id and user_id
      const { data: twistAdmin, error: adminError } = await this.supabase
        .from("twist_admin")
        .select("id")
        .eq("twist_package_id", twistPackageId)
        .eq("user_id", userId!)
        .single();

      if (adminError || !twistAdmin) {
        throw new Error(
          `Failed to fetch twist_admin for personal environment: ${adminError?.message}`
        );
      }
      twistAdminId = twistAdmin.id;
    } else {
      // For non-personal, user_id should be NULL
      const { data: twistAdmin, error: adminError } = await this.supabase
        .from("twist_admin")
        .select("id")
        .eq("twist_package_id", twistPackageId)
        .is("user_id", null)
        .single();

      if (adminError || !twistAdmin) {
        throw new Error(
          `Failed to fetch twist_admin for non-personal environment: ${adminError?.message}`
        );
      }
      twistAdminId = twistAdmin.id;
    }

    // Check if twist already exists to determine if name is required
    const { data: existingTwist, error: existingError } = await this.supabase
      .from("twist")
      .select("name, description")
      .eq("twist_admin_id", twistAdminId)
      .eq("environment", environment)
      .maybeSingle();

    if (existingError) {
      throw new Error(
        `Failed to check existing twist: ${existingError.message}`
      );
    }

    // Require name for first deployment
    if (!existingTwist && !name) {
      throw new Error("name is required for first deployment");
    }

    // Use common deployment implementation
    const result = await deployTwist({
      env: this.env,
      ctx: this.ctx,
      supabase: this.supabase,
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
