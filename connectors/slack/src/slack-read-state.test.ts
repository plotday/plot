import { describe, expect, it } from "vitest";
import {
  channelReadVerdict,
  compareSlackTs,
  deriveReadAnchor,
  threadReadVerdict,
} from "./slack-read-state";
import type { SlackMessage } from "./slack-api";

function msg(over: Partial<SlackMessage> & { ts: string }): SlackMessage {
  return { type: "message", text: "", ...over };
}

describe("compareSlackTs", () => {
  it("orders by seconds first", () => {
    expect(compareSlackTs("1700000001.000000", "1700000000.999999")).toBe(1);
    expect(compareSlackTs("1700000000.999999", "1700000001.000000")).toBe(-1);
  });

  it("orders by microseconds within the same second", () => {
    expect(compareSlackTs("1700000000.000002", "1700000000.000001")).toBe(1);
    expect(compareSlackTs("1700000000.000001", "1700000000.000002")).toBe(-1);
    expect(compareSlackTs("1700000000.000001", "1700000000.000001")).toBe(0);
  });

  it("does not lose precision on 16-significant-digit timestamps", () => {
    // parseFloat("1502126650.228446") rounds; a naive numeric compare calls
    // these equal. The micro halves differ by one, so the result must be -1.
    expect(compareSlackTs("1502126650.228446", "1502126650.228447")).toBe(-1);
  });

  it("treats Slack's never-read sentinel as older than everything", () => {
    expect(compareSlackTs("0000000000.000000", "1700000000.000001")).toBe(-1);
  });
});

describe("channelReadVerdict", () => {
  it("is read when the cursor is at or past the newest message", () => {
    expect(channelReadVerdict("1700000000.000001", "1700000000.000001")).toBe("read");
    expect(channelReadVerdict("1700000001.000000", "1700000000.000001")).toBe("read");
  });

  it("is unread when the cursor is behind the newest message", () => {
    expect(channelReadVerdict("1700000000.000000", "1700000000.000001")).toBe("unread");
  });

  it("abstains when Slack did not return a cursor", () => {
    expect(channelReadVerdict(null, "1700000000.000001")).toBe("unknown");
    expect(channelReadVerdict(undefined, "1700000000.000001")).toBe("unknown");
    expect(channelReadVerdict("", "1700000000.000001")).toBe("unknown");
  });
});

describe("threadReadVerdict", () => {
  it("prefers unread_count when present", () => {
    expect(threadReadVerdict(msg({ ts: "1.0", unread_count: 0 }))).toBe("read");
    expect(threadReadVerdict(msg({ ts: "1.0", unread_count: 3 }))).toBe("unread");
  });

  it("falls back to last_read vs latest_reply", () => {
    expect(
      threadReadVerdict(
        msg({ ts: "1.0", last_read: "1700000002.000000", latest_reply: "1700000002.000000" })
      )
    ).toBe("read");
    expect(
      threadReadVerdict(
        msg({ ts: "1.0", last_read: "1700000001.000000", latest_reply: "1700000002.000000" })
      )
    ).toBe("unread");
  });

  it("abstains when the parent carries no thread cursor at all", () => {
    expect(threadReadVerdict(msg({ ts: "1.0" }))).toBe("unknown");
    expect(threadReadVerdict(undefined)).toBe("unknown");
  });

  it("abstains when only one half of the fallback pair is present", () => {
    expect(threadReadVerdict(msg({ ts: "1.0", last_read: "1700000002.000000" }))).toBe(
      "unknown"
    );
    expect(threadReadVerdict(msg({ ts: "1.0", latest_reply: "1700000002.000000" }))).toBe(
      "unknown"
    );
  });
});

describe("deriveReadAnchor", () => {
  it("anchors on the newest message ts", () => {
    const anchor = deriveReadAnchor(
      [msg({ ts: "1700000000.000001" }), msg({ ts: "1700000002.000000" })],
      { direct: false, at: 1000 }
    );
    expect(anchor).toEqual({ newest: "1700000002.000000", threaded: false, at: 1000 });
  });

  it("marks a channel link threaded when it holds a real thread reply", () => {
    const anchor = deriveReadAnchor(
      [
        msg({ ts: "1700000000.000001", thread_ts: "1700000000.000001" }),
        msg({ ts: "1700000002.000000", thread_ts: "1700000000.000001" }),
      ],
      { direct: false, at: 1000 }
    );
    expect(anchor?.threaded).toBe(true);
  });

  it("does not treat a lone parent as threaded", () => {
    const anchor = deriveReadAnchor(
      [msg({ ts: "1700000000.000001", thread_ts: "1700000000.000001" })],
      { direct: false, at: 1000 }
    );
    expect(anchor?.threaded).toBe(false);
  });

  it("never marks a direct conversation threaded — a DM uses the conversation cursor", () => {
    const anchor = deriveReadAnchor(
      [
        msg({ ts: "1700000000.000001", thread_ts: "1700000000.000001" }),
        msg({ ts: "1700000002.000000", thread_ts: "1700000000.000001" }),
      ],
      { direct: true, at: 1000 }
    );
    expect(anchor?.threaded).toBe(false);
  });

  it("returns null for an empty message set", () => {
    expect(deriveReadAnchor([], { direct: false, at: 1000 })).toBeNull();
  });
});
