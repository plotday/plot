import { describe, expect, it } from "vitest";

import { singleThreadPushNotification } from "./notification-summary";

describe("singleThreadPushNotification", () => {
  it("leads with the author and uses the title as the body for a new thread", () => {
    expect(
      singleThreadPushNotification({
        title: "Workshop ideas",
        preview: "Hey, here are some thoughts...",
        has_been_read: false,
        original_author_name: "Phil Lee",
        unread_author_names: "Phil Lee",
      })
    ).toEqual({ title: "Phil Lee", body: "Workshop ideas" });
  });

  it("credits the REPLIER (not the originator) on a reply to an already-read thread", () => {
    // Phil started the thread; the user read it; Stacy replied. The heading
    // must be Stacy, never Phil.
    expect(
      singleThreadPushNotification({
        title: "Workshop ideas",
        preview: "one more thing",
        has_been_read: true,
        original_author_name: "Phil Lee",
        unread_author_names: "Stacy Chen",
      })
    ).toEqual({ title: "Stacy Chen", body: "Workshop ideas" });
  });

  it("joins multiple repliers in the heading", () => {
    expect(
      singleThreadPushNotification({
        title: "Workshop ideas",
        preview: null,
        has_been_read: true,
        original_author_name: "Phil Lee",
        unread_author_names: "Stacy Chen, Bob Ng",
      })
    ).toEqual({ title: "Stacy Chen & Bob Ng", body: "Workshop ideas" });
  });

  it("uses only the first name when several original authors are present", () => {
    expect(
      singleThreadPushNotification({
        title: "Workshop ideas",
        preview: null,
        has_been_read: false,
        original_author_name: "Phil Lee, Stacy Chen",
        unread_author_names: "Phil Lee, Stacy Chen",
      })
    ).toEqual({ title: "Phil Lee", body: "Workshop ideas" });
  });

  it("leads with the title when there is no human author (automated mail)", () => {
    expect(
      singleThreadPushNotification({
        title: "Your statement is ready",
        preview: "View your latest statement online",
        has_been_read: false,
        original_author_name: null,
        unread_author_names: null,
      })
    ).toEqual({
      title: "Your statement is ready",
      body: "View your latest statement online",
    });
  });

  it("falls back to the preview as body when the author is known but the thread has no title", () => {
    expect(
      singleThreadPushNotification({
        title: null,
        preview: "Running 5 min late",
        has_been_read: false,
        original_author_name: "Stacy Chen",
        unread_author_names: "Stacy Chen",
      })
    ).toEqual({ title: "Stacy Chen", body: "Running 5 min late" });
  });
});
