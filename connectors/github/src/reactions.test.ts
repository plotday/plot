import { describe, expect, it } from "vitest";
import { commentEndpointForKey } from "./reactions";

describe("commentEndpointForKey", () => {
  it("routes a comment- key to the issue-comment endpoint", () => {
    expect(commentEndpointForKey("comment-123")).toEqual({
      commentId: "123",
      kind: "issue",
    });
  });

  it("routes a review-comment- key to the review-comment endpoint", () => {
    expect(commentEndpointForKey("review-comment-456")).toEqual({
      commentId: "456",
      kind: "review",
    });
  });

  it("returns null for a description key", () => {
    expect(commentEndpointForKey("description")).toBeNull();
  });

  it("returns null for a review- (summary) key", () => {
    expect(commentEndpointForKey("review-789")).toBeNull();
  });

  it("returns null for a null key", () => {
    expect(commentEndpointForKey(null)).toBeNull();
  });
});
