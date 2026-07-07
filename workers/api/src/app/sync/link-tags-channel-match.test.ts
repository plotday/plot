import { describe, it, expect } from "vitest";

import { matchChannelByLinkId } from "./link-tags";

describe("matchChannelByLinkId", () => {
  it("exact match wins (standalone connector: bare id in both link and channel)", () => {
    const channels = [{ channel_id: "INBOX", n: 1 }, { channel_id: "SENT", n: 2 }];
    expect(matchChannelByLinkId(channels, "INBOX")).toEqual({ channel_id: "INBOX", n: 1 });
  });

  it("matches a namespaced channel row from a bare link id (composite Google mail)", () => {
    const channels = [
      { channel_id: "mail:INBOX", n: 1 },
      { channel_id: "mail:SENT", n: 2 },
      { channel_id: "calendar:kris@plot.day", n: 3 },
    ];
    expect(matchChannelByLinkId(channels, "INBOX")).toEqual({ channel_id: "mail:INBOX", n: 1 });
  });

  it("matches namespaced calendar/task ids that themselves contain ':' (splits on first ':')", () => {
    const channels = [
      { channel_id: "tasks:MTY1:0:0", n: 1 },
      { channel_id: "calendar:kris@plot.day", n: 2 },
    ];
    expect(matchChannelByLinkId(channels, "MTY1:0:0")).toEqual({ channel_id: "tasks:MTY1:0:0", n: 1 });
    expect(matchChannelByLinkId(channels, "kris@plot.day")).toEqual({
      channel_id: "calendar:kris@plot.day",
      n: 2,
    });
  });

  it("prefers an exact match over a namespaced suffix match", () => {
    const channels = [{ channel_id: "mail:INBOX", n: 1 }, { channel_id: "INBOX", n: 2 }];
    expect(matchChannelByLinkId(channels, "INBOX")).toEqual({ channel_id: "INBOX", n: 2 });
  });

  it("returns undefined when nothing matches", () => {
    const channels = [{ channel_id: "mail:INBOX", n: 1 }];
    expect(matchChannelByLinkId(channels, "STARRED")).toBeUndefined();
  });
});
