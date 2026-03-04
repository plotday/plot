import {
  Twist,
  type NewThread,
  type Priority,
  type ToolBuilder,
} from "@plotday/twister";
import { Twists, type Log } from "@plotday/twister/tools/twists";
import { Plot } from "@plotday/twister/tools/plot";

export default class TwistCreator extends Twist<TwistCreator> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      twist: build(Twists),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Generate unique Twist ID
    const twistId = await this.tools.twist.create();

    // Post first thread with getting started instructions
    await this.tools.plot.createThread({
      title: "Getting Started",
      notes: [
        {
          content: `Let's build something great!

Plot twists are written in TypeScript and run remotely.

To get started:

1. Run \`npx @plotday/twister twist create\` in your terminal.
2. Edit the generated twist code in the \`src/index.ts\` file.
3. Upload your twist using \`npm deploy\`.
4. Add your twist to a priority in the app to test it.`,
        },
      ],
    });

    const logsCallback = await this.callback(this.onLogs);
    await this.tools.twist.watchLogs(twistId, logsCallback);
  }

  async onLogs(logs: Log[]): Promise<void> {
    // Group logs by environment
    const logsByEnvironment = new Map<string, Log[]>();
    for (const log of logs) {
      if (!logsByEnvironment.has(log.environment)) {
        logsByEnvironment.set(log.environment, []);
      }
      logsByEnvironment.get(log.environment)!.push(log);
    }

    // Get stored parent thread IDs
    const parentIds =
      ((await this.tools.store.get("log_parent_ids")) as Record<
        string,
        string
      > | null) ?? {};

    // Create/update parent threads and child logs for each environment
    for (const [environment, envLogs] of logsByEnvironment.entries()) {
      // Get or create parent thread for this environment
      let parentId = parentIds[environment];
      if (!parentId) {
        parentId = await this.tools.plot.createThread({
          title: `Twist Logs (${environment})`,
          notes: [
            {
              content: `Console logs from ${environment} environment`,
            },
          ],
        });
        parentIds[environment] = parentId;
        await this.tools.store.set("log_parent_ids", parentIds);
      }

      // Create child threads for all logs in this batch
      const childThreads: NewThread[] = envLogs.map((log) => ({
        title: `[${log.severity}] ${log.message.substring(0, 50)}${
          log.message.length > 50 ? "..." : ""
        }`,
        notes: [
          {
            content: log.message,
          },
        ],
        preview: log.message,
        start: log.timestamp,
        parent: { id: parentId },
      }));

      // Batch create all log threads
      await this.tools.plot.createThreads(childThreads);
    }
  }
}
