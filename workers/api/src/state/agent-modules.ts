import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";

export class AgentModules extends DurableObject<Bindings> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.initializeTable();
  }

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  private initializeTable() {
    try {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS agent_module_versions (
          version INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (version)
        )
      `);
      this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_agent_module_latest
        ON agent_module_versions(version DESC)
      `);
    } catch (error) {
      console.error("Agent module versions table initialization error:", error);
      throw error;
    }
  }

  /**
   * Get the latest version number for an agent
   */
  getVersion(): number | null {
    try {
      const result = this.sql
        .exec(
          `
          SELECT version
          FROM agent_module_versions
          ORDER BY version DESC
          LIMIT 1
        `
        )
        .next();

      if (result.done) {
        return null;
      }

      return result.value.version as number;
    } catch (error) {
      console.error("Error getting agent module version:", error);
      throw error;
    }
  }

  /**
   * Get the latest module code for an agent from R2
   */
  async getModule(): Promise<string | null> {
    try {
      const version = this.getVersion();
      if (version === null) {
        return null;
      }

      const key = this.getR2Key(agentId, version);
      const object = await this.env.AGENT_MODULES_BUCKET.get(key);

      if (!object) {
        return null;
      }

      return await object.text();
    } catch (error) {
      console.error("Error getting agent module:", error);
      throw error;
    }
  }

  /**
   * Store a new version of an agent module in R2
   * Returns the new version number (timestamp)
   */
  async storeModule(agentId: string, code: string): Promise<number> {
    try {
      // Use timestamp as version number
      const version = Date.now();
      const key = this.getR2Key(agentId, version);

      // Store in R2
      await this.env.AGENT_MODULES_BUCKET.put(key, code);

      // Record version in SQLite
      this.sql.exec(
        `
        INSERT INTO agent_module_versions (version, created_at)
        VALUES (?, ?)
      `,
        version,
        version
      );

      return version;
    } catch (error) {
      console.error("Error storing agent module:", error);
      throw error;
    }
  }

  /**
   * Get a specific version of an agent module
   */
  async getModuleVersion(
    agentId: string,
    version: number
  ): Promise<string | null> {
    try {
      const key = this.getR2Key(agentId, version);
      const object = await this.env.AGENT_MODULES_BUCKET.get(key);

      if (!object) {
        return null;
      }

      return await object.text();
    } catch (error) {
      console.error("Error getting agent module version:", error);
      throw error;
    }
  }

  /**
   * List all versions for an agent
   */
  listVersions(
    agentId: string
  ): Array<{ version: number; created_at: number }> {
    try {
      const results = this.sql.exec(
        `
        SELECT version, created_at
        FROM agent_module_versions
        ORDER BY version DESC
      `,
        [agentId]
      );

      const versions: Array<{ version: number; created_at: number }> = [];
      for (const row of results) {
        versions.push({
          version: row.version as number,
          created_at: row.created_at as number,
        });
      }

      return versions;
    } catch (error) {
      console.error("Error listing agent module versions:", error);
      throw error;
    }
  }

  /**
   * Delete all versions of an agent module (cleanup)
   */
  async deleteAllVersions(agentId: string): Promise<void> {
    try {
      const versions = this.listVersions(agentId);

      // Delete from R2
      const deletePromises = versions.map((v) =>
        this.env.AGENT_MODULES_BUCKET.delete(this.getR2Key(agentId, v.version))
      );
      await Promise.all(deletePromises);

      // Delete from SQLite
      this.sql.exec("DELETE FROM agent_module_versions", agentId);
    } catch (error) {
      console.error("Error deleting agent module versions:", error);
      throw error;
    }
  }

  /**
   * Generate R2 key for agent module version
   */
  private getR2Key(agentId: string, version: number): string {
    return `agents/${agentId}/modules/${version}.js`;
  }
}
