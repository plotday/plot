import {
  ActivityType,
  Twist,
  type NewActivity,
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

    // Post first activity with getting started instructions
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
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

    // Get stored parent activity IDs
    const parentIds =
      ((await this.tools.store.get("log_parent_ids")) as Record<
        string,
        string
      > | null) ?? {};

    // Create/update parent activities and child logs for each environment
    for (const [environment, envLogs] of logsByEnvironment.entries()) {
      // Get or create parent activity for this environment
      let parentId = parentIds[environment];
      if (!parentId) {
        parentId = await this.tools.plot.createActivity({
          type: ActivityType.Note,
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

      // Create child activities for all logs in this batch
      const childActivities: NewActivity[] = envLogs.map((log) => ({
        type: ActivityType.Note,
        title: `[${log.severity}] ${log.message.substring(0, 50)}${
          log.message.length > 50 ? "..." : ""
        }`,
        notes: [
          {
            content: log.message,
          },
        ],
        start: log.timestamp,
        parent: { id: parentId },
      }));

      // Batch create all log activities
      await this.tools.plot.createActivities(childActivities);
    }
  }
}
