import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";

export class TwistModules extends DurableObject<Bindings> {
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
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "initializeTable",
    });

    try {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS twist_module_versions (
          version INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (version)
        )
      `);
      this.sql.exec(`
        CREATE INDEX IF NOT EXISTS idx_twist_module_latest
        ON twist_module_versions(version DESC)
      `);
    } catch (error) {
      logger.error("Twist module versions table initialization error", error as Error);
      throw error;
    }
  }

  /**
   * Get the latest version number for a twist
   */
  getVersion(): number | null {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "getVersion",
    });

    try {
      const result = this.sql
        .exec(
          `
          SELECT version
          FROM twist_module_versions
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
      logger.error("Error getting twist module version", error as Error);
      throw error;
    }
  }

  /**
   * Get the latest module code for a twist from R2
   */
  async getModule(): Promise<string | null> {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "getModule",
    });

    try {
      const version = this.getVersion();
      if (version === null) {
        return null;
      }

      const key = this.getR2Key(twistId, version);
      const object = await this.env.TWIST_MODULES_BUCKET.get(key);

      if (!object) {
        return null;
      }

      return await object.text();
    } catch (error) {
      logger.error("Error getting twist module", error as Error, { version });
      throw error;
    }
  }

  /**
   * Store a new version of a twist module in R2
   * Returns the new version number (timestamp)
   */
  async storeModule(twistId: string, code: string): Promise<number> {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "storeModule",
    });

    try {
      // Use timestamp as version number
      const version = Date.now();
      const key = this.getR2Key(twistId, version);

      // Store in R2
      await this.env.TWIST_MODULES_BUCKET.put(key, code);

      // Record version in SQLite
      this.sql.exec(
        `
        INSERT INTO twist_module_versions (version, created_at)
        VALUES (?, ?)
      `,
        version,
        version
      );

      return version;
    } catch (error) {
      logger.error("Error storing twist module", error as Error, {
        twist_id: twistId,
      });
      throw error;
    }
  }

  /**
   * Get a specific version of a twist module
   */
  async getModuleVersion(
    twistId: string,
    version: number
  ): Promise<string | null> {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "getModuleVersion",
    });

    try {
      const key = this.getR2Key(twistId, version);
      const object = await this.env.TWIST_MODULES_BUCKET.get(key);

      if (!object) {
        return null;
      }

      return await object.text();
    } catch (error) {
      logger.error("Error getting twist module version", error as Error, {
        twist_id: twistId,
        version,
      });
      throw error;
    }
  }

  /**
   * List all versions for a twist
   */
  listVersions(
    twistId: string
  ): Array<{ version: number; created_at: number }> {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "listVersions",
    });

    try {
      const results = this.sql.exec(
        `
        SELECT version, created_at
        FROM twist_module_versions
        ORDER BY version DESC
      `,
        [twistId]
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
      logger.error("Error listing twist module versions", error as Error, {
        twist_id: twistId,
      });
      throw error;
    }
  }

  /**
   * Delete all versions of a twist module (cleanup)
   */
  async deleteAllVersions(twistId: string): Promise<void> {
    const logger = createLogger({
      durable_object: "TwistModules",
      operation: "deleteAllVersions",
    });

    try {
      const versions = this.listVersions(twistId);

      // Delete from R2
      const deletePromises = versions.map((v) =>
        this.env.TWIST_MODULES_BUCKET.delete(this.getR2Key(twistId, v.version))
      );
      await Promise.all(deletePromises);

      // Delete from SQLite
      this.sql.exec("DELETE FROM twist_module_versions", twistId);
    } catch (error) {
      logger.error("Error deleting twist module versions", error as Error, {
        twist_id: twistId,
      });
      throw error;
    }
  }

  /**
   * Generate R2 key for twist module version
   */
  private getR2Key(twistId: string, version: number): string {
    return `twists/${twistId}/modules/${version}.js`;
  }
}
