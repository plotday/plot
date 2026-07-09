/* SPEC:
Connect to my bookmarking service account. Once connected, import my starred
bookmarks as threads (title + link note), and check for new ones every hour.
Imported bookmarks must not duplicate on re-sync.
*/
import { ActionType, Twist, type ToolBuilder, type Uuid } from "@plotday/twister";
import { Options } from "@plotday/twister/options";
import { Network } from "@plotday/twister/tools/network";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class BookmarkSync extends Twist<BookmarkSync> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
      // Plain twists can't hold OAuth tokens — that machinery
      // (provider/scopes/channels) belongs to Connectors. A secure Options
      // field is the twist-safe way to let the user "connect" an account
      // for a twist to call directly.
      options: build(Options, {
        apiKey: {
          type: "text",
          label: "Bookmarking service API key",
          default: "",
          secure: true,
        },
      }),
      network: build(Network, {
        urls: ["https://api.bookmarks.example/*"],
      }),
    };
  }

  async activate() {
    // Re-runs hourly under a stable key; survives restarts and upgrades.
    await this.scheduleRecurring(
      "hourly-sync",
      await this.callback(this.sync),
      { intervalMs: 60 * 60 * 1000 }
    );
    await this.sync();
  }

  async sync(): Promise<void> {
    const { apiKey } = this.tools.options;
    if (!apiKey) {
      return; // Not connected yet; nothing to sync.
    }

    const response = await fetch("https://api.bookmarks.example/v1/starred", {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!response.ok) {
      return;
    }
    const { bookmarks } = (await response.json()) as {
      bookmarks: Array<{ id: string; title: string; url: string }>;
    };

    // Threads a twist creates have no external Link (that's a Connector
    // concept), so dedup is tracked manually: store the bookmark id -> thread
    // id mapping and skip any bookmark that's already been imported.
    for (const bookmark of bookmarks) {
      const mappingKey = `bookmark:${bookmark.id}`;
      if (await this.get<Uuid>(mappingKey)) {
        continue;
      }

      const threadId = await this.tools.plot.createThread({
        title: bookmark.title,
        notes: [
          {
            content: bookmark.url,
            actions: [
              { type: ActionType.external, title: "Open bookmark", url: bookmark.url },
            ],
          },
        ],
      });
      await this.set(mappingKey, threadId);
    }
  }
}
