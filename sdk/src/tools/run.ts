import { ITool, type Tools } from "..";
import type { Callback } from "./callback";

/**
 * Run background tasks and scheduled jobs.
 *
 * The Run tool enables agents and tools to queue callbacks. This is especially
 * iportant for long-running operations and batch processing, since agents
 * operate within runtime limits. Run callbacks also benefit from automatic
 * retries on failure.
 *
 * **Note:** Run methods are also available directly on Agent and Tool classes
 * via `this.run()`, `this.cancel()`, and `this.cancelAll()`.
 * This is the recommended approach for most use cases.
 *
 * **Best Practices:**
 * - Break long operations into smaller batches
 * - Create callbacks first using `this.callback()`
 * - Store intermediate state using the Store tool
 *
 * @example
 * ```typescript
 * class SyncTool extends Tool {
 *   async startBatchSync(totalItems: number) {
 *     // Store initial state using built-in set method
 *     await this.set("sync_progress", { processed: 0, total: totalItems });
 *
 *     // Create callback and queue first batch using built-in methods
 *     const callback = await this.callback("processBatch", { batchNumber: 1 });
 *     await this.run(callback);
 *   }
 *
 *   async processBatch(args: any, context: { batchNumber: number }) {
 *     // Process one batch of items
 *     const progress = await this.get("sync_progress");
 *
 *     // ... process items ...
 *
 *     if (progress.processed < progress.total) {
 *       // Queue next batch using built-in methods
 *       const callback = await this.callback("processBatch", {
 *         batchNumber: context.batchNumber + 1
 *       });
 *       await this.run(callback);
 *     }
 *   }
 *
 *   async scheduleCleanup() {
 *     const tomorrow = new Date();
 *     tomorrow.setDate(tomorrow.getDate() + 1);
 *
 *     const callback = await this.callback("cleanupOldData");
 *     return await this.run(callback, { runAt: tomorrow });
 *   }
 * }
 * ```
 */
export abstract class Run extends ITool {
  /**
   * Queues a callback to execute in a separate worker context.
   *
   * The callback will be invoked either immediately or at a scheduled time
   * in an isolated execution environment with limited resources. Use this
   * for breaking up long-running operations into manageable chunks.
   *
   * @param callback - The callback token created with `this.callback()`
   * @param options - Optional configuration for the execution
   * @param options.runAt - If provided, schedules execution at this time; otherwise runs immediately
   * @returns Promise resolving to a cancellation token (only for scheduled executions)
   */
  abstract run(
    _callback: Callback,
    _options?: { runAt?: Date },
  ): Promise<string | void>;

  /**
   * Cancels a previously scheduled execution.
   *
   * Prevents a scheduled function from executing. No error is thrown
   * if the token is invalid or the execution has already completed.
   *
   * @param token - The cancellation token returned by run() with runAt option
   * @returns Promise that resolves when the cancellation is processed
   */
  abstract cancel(_token: string): Promise<void>;

  /**
   * Cancels all scheduled executions for this tool/agent.
   *
   * Cancels all pending scheduled executions created by this tool or agent
   * instance. Immediate executions cannot be cancelled.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  abstract cancelAll(): Promise<void>;
}
