import { describe, expect, it, vi } from "vitest";

const requestExtractionMock = vi.fn();
vi.mock("../extract/request", () => ({
  requestExtraction: (...args: unknown[]) => requestExtractionMock(...args),
}));

import extract from "./extract";

function post(body: unknown) {
  return extract.request(
    "/extract",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
    { ARTICLES_BUCKET: {} } as unknown as Record<string, unknown>
  );
}

describe("POST /extract", () => {
  it("returns 400 for a missing or non-http url", async () => {
    requestExtractionMock.mockReset();
    const res = await post({ url: "ftp://nope" });
    expect(res.status).toBe(400);
    expect(requestExtractionMock).not.toHaveBeenCalled();
  });

  it("returns 400 for a private / SSRF target without calling requestExtraction", async () => {
    requestExtractionMock.mockReset();
    for (const url of [
      "http://169.254.169.254/latest/meta-data",
      "http://localhost:8787/x",
      "http://10.0.0.1/",
      "http://[::1]/",
    ]) {
      const res = await post({ url });
      expect(res.status, url).toBe(400);
    }
    expect(requestExtractionMock).not.toHaveBeenCalled();
  });

  it("requests extraction and returns the status", async () => {
    requestExtractionMock.mockReset();
    requestExtractionMock.mockResolvedValue({ status: "pending" });
    const res = await post({ url: "https://example.com/a" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "pending" });
    expect(requestExtractionMock).toHaveBeenCalledWith(
      expect.anything(),
      "https://example.com/a"
    );
  });

  it("returns {status:'error'} (200) when requestExtraction throws", async () => {
    requestExtractionMock.mockReset();
    requestExtractionMock.mockRejectedValue(new Error("db down"));
    const res = await post({ url: "https://example.com/a" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "error" });
  });
});
