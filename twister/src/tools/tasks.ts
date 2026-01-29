import { ITool } from "..";
import type { Callback } from "./callbacks";

/**
 * Run background tasks and scheduled jobs.
 *
 * The Tasks tool enables twists and tools to queue callbacks for execution in separate
 * worker contexts. **This is critical for staying under request limits**: each execution
 * has a limit of ~1000 requests (HTTP requests, tool calls, database operations), and
 * running a task creates a NEW execution with a fresh request limit.
 *
 * **Key distinction:**
 * - **Calling a callback** (via `this.run()`) continues the same execution and shares the request count
 * - **Running a task** (via `this.runTask()`) creates a NEW execution with fresh ~1000 request limit
 *
 * **When to use tasks:**
 * - Processing large datasets that would exceed 1000 requests
 * - Breaking loops into chunks where each chunk stays under the request limit
 * - Scheduling operations for future execution
 *
 * **Note:** Tasks tool methods are also available directly on Twist and Tool classes
 * via `this.runTask()`, `this.cancelTask()`, and `this.cancelAllTasks()`.
 * This is the recommended approach for most use cases.
 *
 * **Best Practices:**
 * - Size batches to stay under ~1000 requests per execution
 * - Calculate requests per item to determine safe batch size
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
 *     // Create callback and queue first batch
 *     const callback = await this.callback("processBatch", { batchNumber: 1 });
 *     // runTask creates NEW execution with fresh ~1000 request limit
 *     await this.runTask(callback);
 *   }
 *
 *   async processBatch(args: any, context: { batchNumber: number }) {
 *     // Process one batch of items (sized to stay under request limit)
 *     const progress = await this.get("sync_progress");
 *
 *     // If each item makes ~10 requests, process ~100 items per batch
 *     // 100 items × 10 requests = 1000 requests (at limit)
 *     const batchSize = 100;
 *     const items = await this.fetchItems(progress.processed, batchSize);
 *
 *     for (const item of items) {
 *       await this.processItem(item); // Makes ~10 requests per item
 *     }
 *
 *     await this.set("sync_progress", {
 *       processed: progress.processed + batchSize,
 *       total: progress.total
 *     });
 *
 *     if (progress.processed < progress.total) {
 *       // Queue next batch - creates NEW execution with fresh request limit
 *       const callback = await this.callback("processBatch", {
 *         batchNumber: context.batchNumber + 1
 *       });
 *       await this.runTask(callback);
 *     }
 *   }
 *
 *   async scheduleCleanup() {
 *     const tomorrow = new Date();
 *     tomorrow.setDate(tomorrow.getDate() + 1);
 *
 *     const callback = await this.callback("cleanupOldData");
 *     // Schedule for future execution
 *     return await this.runTask(callback, { runAt: tomorrow });
 *   }
 * }
 * ```
 */
export abstract class Tasks extends ITool {
  /**
   * Queues a callback to execute in a separate worker context with a fresh request limit.
   *
   * **Creates a NEW execution** with its own request limit of ~1000 requests (HTTP requests,
   * tool calls, database operations). This is the primary way to stay under request limits
   * when processing large datasets or making many API calls.
   *
   * The callback will be invoked either immediately or at a scheduled time
   * in an isolated execution environment. Each execution has ~1000 requests and ~60 seconds
   * CPU time. Use this for breaking loops into chunks that stay under the request limit.
   *
   * **Key distinction:**
   * - `this.run(callback)` - Continues same execution, shares request count
   * - `this.runTask(callback)` - NEW execution, fresh request limit
   *
   * @param callback - Callback created with `this.callback()`
   * @param options - Optional configuration for the execution
   * @param options.runAt - If provided, schedules execution at this time; otherwise runs immediately
   * @returns Promise resolving to a cancellation token (only for scheduled executions)
   *
   * @example
   * ```typescript
   * // Break large loop into batches to stay under request limit
   * const callback = await this.callback("syncBatch", { page: 1 });
   * await this.runTask(callback); // Fresh execution with ~1000 requests
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract runTask(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void>;

  /**
   * Cancels a previously scheduled execution.
   *
   * Prevents a scheduled function from executing. No error is thrown
   * if the token is invalid or the execution has already completed.
   *
   * @param token - The cancellation token returned by runTask() with runAt option
   * @returns Promise that resolves when the cancellation is processed
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract cancelTask(token: string): Promise<void>;

  /**
   * Cancels all scheduled executions for this tool/twist.
   *
   * Cancels all pending scheduled executions created by this tool or twist
   * instance. Immediate executions cannot be cancelled.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  abstract cancelAllTasks(): Promise<void>;
}
