import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";
import { AuthProvider } from "@plotday/twister/tools/integrations";

import type { Bindings } from "../env";
import { PROVIDER_CONFIGS, type StoredTokenData } from "../provider";
import { createLogger } from "@plotday/worker-util";

// Report every 7 days
const REPORT_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000;
// Batch size for Atlassian API (max 100, use 90 for safety)
const REPORT_BATCH_SIZE = 90;

const SENTINEL_EMAIL = "removed@system.plot.day";

/**
 * PrivacyReporting Durable Object
 *
 * Implements the Atlassian Personal Data Reporting API.
 * Singleton DO triggered by cron to periodically report which Atlassian
 * account IDs have personal data stored in Plot, and handle account
 * closure/update responses.
 *
 * API: POST https://api.atlassian.com/app/report-accounts/
 * Auth: OAuth 2.0 3LO (uses an existing Jira twist's token)
 */
export class PrivacyReporting extends DurableObject<Bindings> {
  private supabase: SupabaseClient;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  }

  private captureException(
    error: Error,
    properties?: Record<string, unknown>
  ) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, undefined, {
      durable_object: "PrivacyReporting",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  async fetch(request: Request): Promise<Response> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "fetch",
    });

    try {
      const url = new URL(request.url);

      if (url.pathname === "/trigger" && request.method === "POST") {
        await this.maybeReport();
        return new Response("OK", { status: 200 });
      }

      return new Response("Not found", { status: 404 });
    } catch (error) {
      logger.error("Error in PrivacyReporting fetch", error as Error);
      this.captureException(error as Error, { operation: "fetch" });
      return new Response("Internal Server Error", { status: 500 });
    }
  }

  /**
   * Check if it's time to report and run if needed.
   */
  private async maybeReport(): Promise<void> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "maybeReport",
    });

    const lastRun = await this.ctx.storage.get<number>("lastReportTime");
    if (lastRun && Date.now() - lastRun < REPORT_INTERVAL_MS) {
      return;
    }

    logger.info("Starting Atlassian privacy reporting");

    try {
      await this.reportAtlassianAccounts();
      await this.ctx.storage.put("lastReportTime", Date.now());
      logger.info("Atlassian privacy reporting completed");
    } catch (error) {
      logger.error("Atlassian privacy reporting failed", error as Error);
      this.captureException(error as Error, {
        operation: "reportAtlassianAccounts",
      });
    }
  }

  /**
   * Main reporting logic:
   * 1. Get unreported Atlassian account IDs from contact_external_account
   * 2. Find a valid Atlassian OAuth token from an active Jira twist
   * 3. Batch report to Atlassian API
   * 4. Handle responses (closed accounts, updated accounts)
   */
  private async reportAtlassianAccounts(): Promise<void> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "reportAtlassianAccounts",
    });

    // 1. Get accounts that need reporting
    const { data: accounts, error: queryError } = await this.supabase
      .from("contact_external_account")
      .select("contact_id, provider, account_id, last_reported_at")
      .eq("provider", "atlassian")
      .or(
        `last_reported_at.is.null,last_reported_at.lt.${new Date(Date.now() - REPORT_INTERVAL_MS).toISOString()}`
      )
      .limit(1000);

    if (queryError) {
      throw new Error(
        `Failed to query contact_external_account: ${queryError.message}`
      );
    }

    if (!accounts || accounts.length === 0) {
      logger.info("No Atlassian accounts to report");
      return;
    }

    logger.info("Found Atlassian accounts to report", {
      count: accounts.length,
    });

    // 2. Find a valid Atlassian OAuth token
    const accessToken = await this.findAtlassianToken();
    if (!accessToken) {
      logger.error(
        "No valid Atlassian OAuth token found",
        new Error("No Atlassian token available for privacy reporting")
      );
      return;
    }

    // 3. Report in batches
    const accountIds = accounts.map((a) => a.account_id);
    const reportedIds: string[] = [];

    for (let i = 0; i < accountIds.length; i += REPORT_BATCH_SIZE) {
      const batch = accountIds.slice(i, i + REPORT_BATCH_SIZE);

      try {
        const statuses = await this.callReportApi(accessToken, batch);
        reportedIds.push(...batch);

        // 4. Handle account statuses
        await this.handleAccountStatuses(statuses, accounts);
      } catch (error) {
        logger.error("Failed to report batch", error as Error, {
          batchStart: i,
          batchSize: batch.length,
        });
        // Stop processing on API error (might be rate limited)
        break;
      }
    }

    // 5. Update last_reported_at for successfully reported accounts
    if (reportedIds.length > 0) {
      const { error: updateError } = await this.supabase
        .from("contact_external_account")
        .update({ last_reported_at: new Date().toISOString() })
        .eq("provider", "atlassian")
        .in("account_id", reportedIds);

      if (updateError) {
        logger.error(
          "Failed to update last_reported_at",
          new Error(updateError.message)
        );
      }

      logger.info("Reported Atlassian accounts", {
        reported: reportedIds.length,
        total: accountIds.length,
      });
    }
  }

  /**
   * Find a valid Atlassian OAuth token from any active Jira twist.
   * Searches priority_twist records for Jira twists, then accesses
   * their Storage DOs for auth tokens keyed by the twist owner's contact.
   */
  private async findAtlassianToken(): Promise<string | null> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "findAtlassianToken",
    });

    // Find active Jira-related priority twists
    const { data: twists, error } = await this.supabase
      .from("priority_twist")
      .select("id, owner_id")
      .is("archived_at", null)
      .ilike("name", "%jira%")
      .limit(20);

    if (error || !twists || twists.length === 0) {
      logger.info("No active Jira twists found");
      return null;
    }

    for (const twist of twists) {
      try {
        const tokenData = await this.findTokenInTwistStorage(
          twist.id,
          twist.owner_id
        );
        if (!tokenData) continue;

        // Check expiration and refresh if needed
        if (tokenData.expires_at && Date.now() > tokenData.expires_at) {
          if (tokenData.refresh_token) {
            try {
              const refreshed = await this.refreshToken(
                tokenData.client_id,
                tokenData.refresh_token
              );
              return refreshed.access_token;
            } catch {
              continue;
            }
          }
          continue;
        }

        return tokenData.access_token;
      } catch (err) {
        logger.error("Error finding token for twist", err as Error, {
          priorityTwistId: twist.id,
        });
        continue;
      }
    }

    return null;
  }

  /**
   * Find an Atlassian auth token in a twist's Storage DO.
   * Tokens are stored as `auth_token:atlassian:{contactId}`.
   * We look up the owner's contact IDs and try each key.
   */
  private async findTokenInTwistStorage(
    priorityTwistId: string,
    ownerId: string
  ): Promise<StoredTokenData | null> {
    // Get all contacts for this user
    const { data: contacts } = await this.supabase
      .from("contact")
      .select("id")
      .eq("user_id", ownerId);

    if (!contacts || contacts.length === 0) return null;

    const storageId = this.env.STORAGE.idFromName(priorityTwistId);
    const storageDO = this.env.STORAGE.get(storageId);

    // Try each contact's auth token key
    for (const contact of contacts) {
      const key = `auth_token:atlassian:${contact.id}`;
      const raw = await storageDO.get(key);
      if (raw) {
        try {
          return JSON.parse(raw) as StoredTokenData;
        } catch {
          continue;
        }
      }
    }

    return null;
  }

  /**
   * Refresh an Atlassian OAuth token.
   */
  private async refreshToken(
    clientId: string,
    refreshToken: string
  ): Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
  }> {
    const config = PROVIDER_CONFIGS[AuthProvider.Atlassian];
    const clientSecret = this.env.AUTH_ATLASSIAN_SECRET;

    const params = new URLSearchParams({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret } : {}),
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token refresh failed: ${response.status} ${errorText}`);
    }

    return (await response.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
    };
  }

  /**
   * Call the Atlassian Personal Data Reporting API.
   * Returns account statuses.
   */
  private async callReportApi(
    accessToken: string,
    accountIds: string[]
  ): Promise<
    Array<{ accountId: string; status: "active" | "closed" | "updated" }>
  > {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "callReportApi",
    });

    const response = await fetch(
      "https://api.atlassian.com/app/report-accounts/",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ accountIds }),
      }
    );

    if (response.status === 429) {
      const retryAfter = response.headers.get("Retry-After");
      throw new Error(
        `Rate limited by Atlassian API. Retry after: ${retryAfter || "unknown"}`
      );
    }

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Atlassian report API failed: ${response.status} ${errorText}`
      );
    }

    const data = (await response.json()) as {
      accounts: Array<{
        accountId: string;
        status: "active" | "closed" | "updated";
      }>;
    };

    logger.info("Atlassian report API response", {
      reported: accountIds.length,
      statuses: data.accounts?.length || 0,
    });

    return data.accounts || [];
  }

  /**
   * Handle account statuses from the Atlassian API response.
   */
  private async handleAccountStatuses(
    statuses: Array<{
      accountId: string;
      status: "active" | "closed" | "updated";
    }>,
    accounts: Array<{
      contact_id: string;
      provider: string;
      account_id: string;
    }>
  ): Promise<void> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "handleAccountStatuses",
    });

    for (const status of statuses) {
      if (status.status === "closed") {
        const account = accounts.find(
          (a) => a.account_id === status.accountId
        );
        if (account) {
          try {
            await this.handleClosedAccount(
              account.contact_id,
              account.account_id
            );
          } catch (error) {
            logger.error("Failed to handle closed account", error as Error, {
              accountId: status.accountId,
              contactId: account.contact_id,
            });
          }
        }
      } else if (status.status === "updated") {
        // Mark for refresh - data will be updated on next Jira sync
        const { error } = await this.supabase
          .from("contact_external_account")
          .update({ data_fetched_at: new Date(0).toISOString() })
          .eq("provider", "atlassian")
          .eq("account_id", status.accountId);

        if (error) {
          logger.error(
            "Failed to mark account for refresh",
            new Error(error.message),
            { accountId: status.accountId }
          );
        }
      }
      // "active" status = no action needed
    }
  }

  /**
   * Handle a closed Atlassian account:
   * 1. Replace Jira-sourced references with sentinel contact
   * 2. If no remaining non-Jira references, clear personal data and archive
   * 3. Delete the contact_external_account row
   */
  private async handleClosedAccount(
    contactId: string,
    accountId: string
  ): Promise<void> {
    const logger = createLogger({
      durable_object: "PrivacyReporting",
      operation: "handleClosedAccount",
    });

    // Get sentinel contact ID
    const { data: sentinel } = await this.supabase
      .from("contact")
      .select("id")
      .eq("email", SENTINEL_EMAIL)
      .single();

    if (!sentinel) {
      throw new Error("Sentinel contact not found");
    }

    const sentinelId = sentinel.id;

    // Replace Jira-sourced activity author references
    await this.supabase
      .from("activity")
      .update({ author_id: sentinelId })
      .eq("author_id", contactId)
      .like("source", "jira:%");

    // Replace Jira-sourced activity assignee references
    await this.supabase
      .from("activity")
      .update({ assignee_id: sentinelId })
      .eq("assignee_id", contactId)
      .like("source", "jira:%");

    // Replace Jira-sourced note author references
    const { data: jiraActivities } = await this.supabase
      .from("activity")
      .select("id")
      .like("source", "jira:%");

    if (jiraActivities && jiraActivities.length > 0) {
      const jiraActivityIds = jiraActivities.map((a) => a.id);

      await this.supabase
        .from("note")
        .update({ author_id: sentinelId })
        .eq("author_id", contactId)
        .in("activity_id", jiraActivityIds);

      // Replace mentions using raw SQL (array_replace not available via PostgREST)
      // This is a best-effort operation
      const { error: mentionError } = await this.supabase.rpc(
        "exec_sql" as any,
        {
          query: `UPDATE note SET mentions = array_replace(mentions, $1::uuid, $2::uuid) WHERE $1::uuid = ANY(mentions) AND activity_id = ANY($3::uuid[])`,
          params: [contactId, sentinelId, jiraActivityIds],
        }
      );
      if (mentionError) {
        // Mentions replacement may not be available via RPC - log and continue
        logger.info("Mention replacement via RPC not available, skipping", {
          contactId,
        });
      }
    }

    // Check if contact has remaining non-Jira references
    const { count: nonJiraAuthorCount } = await this.supabase
      .from("activity")
      .select("id", { count: "exact", head: true })
      .eq("author_id", contactId)
      .not("source", "like", "jira:%");

    const { count: nonJiraAssigneeCount } = await this.supabase
      .from("activity")
      .select("id", { count: "exact", head: true })
      .eq("assignee_id", contactId)
      .not("source", "like", "jira:%");

    const hasNonJiraRefs =
      (nonJiraAuthorCount || 0) > 0 || (nonJiraAssigneeCount || 0) > 0;

    if (!hasNonJiraRefs) {
      // No remaining references - clear personal data and archive
      await this.supabase
        .from("contact")
        .update({
          name: null,
          avatar_url: null,
          archived_at: new Date().toISOString(),
        })
        .eq("id", contactId);

      logger.info(
        "Cleared and archived contact for closed Atlassian account",
        { contactId, accountId }
      );
    } else {
      logger.info(
        "Contact has non-Jira references, preserving contact record",
        { contactId, accountId }
      );
    }

    // Delete the contact_external_account row
    await this.supabase
      .from("contact_external_account")
      .delete()
      .eq("provider", "atlassian")
      .eq("account_id", accountId);
  }
}
