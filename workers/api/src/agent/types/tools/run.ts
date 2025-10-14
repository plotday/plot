import { ITool, type Tools } from "..";

/**
 * Built-in tool for executing functions in separate worker contexts.
 *
 * The Run tool enables agents and tools to queue work for execution in
 * isolated worker environments with limited resources. This is essential
 * for long-running operations, batch processing, and scheduled tasks that
 * need to respect runtime limits.
 *
 * **Runtime Limitations:**
 * - Each execution has limited CPU time (typically 10 seconds)
 * - Memory is limited (128MB)
 * - No persistent state between executions
 * - Use Store tool for persistence between runs
 *
 * **Best Practices:**
 * - Break long operations into smaller batches
 * - Use context parameter to track progress
 * - Store intermediate state using the Store tool
 * - Handle failures gracefully with retry logic
 *
 * @example
 * ```typescript
 * class SyncTool extends Tool {
 *   private run: Run;
 *   private store: Store;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.run = tools.get(Run);
 *     this.store = tools.get(Store);
 *   }
 *
 *   async startBatchSync(totalItems: number) {
 *     // Store initial state
 *     await this.store.set("sync_progress", { processed: 0, total: totalItems });
 *
 *     // Queue first batch
 *     await this.run.now("processBatch", { batchNumber: 1 });
 *   }
 *
 *   async processBatch(context: { batchNumber: number }) {
 *     // Process one batch of items
 *     const progress = await this.store.get("sync_progress");
 *
 *     // ... process items ...
 *
 *     if (progress.processed < progress.total) {
 *       // Queue next batch
 *       await this.run.now("processBatch", {
 *         batchNumber: context.batchNumber + 1
 *       });
 *     }
 *   }
 *
 *   async scheduleCleanup() {
 *     const tomorrow = new Date();
 *     tomorrow.setDate(tomorrow.getDate() + 1);
 *
 *     return await this.run.later("cleanupOldData", tomorrow);
 *   }
 * }
 * ```
 */
export class Run extends ITool {
  static readonly id = "run";

  constructor(_tools: Tools) {
    super();
  }

  call(_name: string, _args: any, _context: any): Promise<any> {
    throw new Error("Method not implemented.");
  }

  /**
   * Queues a function to execute immediately in a separate worker context.
   *
   * The specified callback function will be invoked on the parent tool/agent
   * in an isolated execution environment with limited resources. Use this
   * for breaking up long-running operations into manageable chunks.
   *
   * @param callbackName - Name of the function to call on the parent
   * @param context - Optional context data to pass to the function
   * @returns Promise that resolves when the execution is queued
   */
  now(_callbackName: string, _context?: any): Promise<void> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Schedules a function to execute at a specific time in the future.
   *
   * The function will be executed at the specified time in an isolated
   * worker context. Returns a token that can be used to cancel the
   * scheduled execution before it runs.
   *
   * @param callbackName - Name of the function to call on the parent
   * @param executeAt - The date/time when the function should execute
   * @param context - Optional context data to pass to the function
   * @returns Promise resolving to a cancellation token
   */
  later(
    _callbackName: string,
    _executeAt: Date,
    _context?: any
  ): Promise<string> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Cancels a previously scheduled execution.
   *
   * Prevents a scheduled function from executing. No error is thrown
   * if the token is invalid or the execution has already completed.
   *
   * @param token - The cancellation token returned by later()
   * @returns Promise that resolves when the cancellation is processed
   */
  cancel(_token: string): Promise<void> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Cancels all scheduled executions for this tool/agent.
   *
   * Cancels all pending scheduled executions created by this tool or agent
   * instance. Immediate executions (created with now()) cannot be cancelled.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  cancelAll(): Promise<void> {
    throw new Error("Method implemented remotely.");
  }
}
