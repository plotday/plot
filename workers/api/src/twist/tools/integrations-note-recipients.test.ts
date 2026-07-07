import { describe, it, expect, vi } from "vitest";
import { Integrations } from "./integrations";

// Unit tests for Integrations.resolveNoteRecipients — the reply-path resolver
// that populates note.recipients. It gates on the note carrying a curated
// access list and the link type addressing by recipient, then excludes the
// acting user's own contacts before delegating to resolveDispatchRecipients.
// The DB-bound dependencies (resolveComposeLinkType, userContactIds,
// resolveDispatchRecipients) are stubbed so the gating + self-exclusion logic
// is tested in isolation.

const EMAIL = { type: "email", compose: { targets: "addresses" } };
const NO_COMPOSE = { type: "issue" };

function makeThis(opts: {
  linkTypeConfig?: unknown;
  selfIds?: string[];
}) {
  const resolveDispatchRecipients = vi.fn(async (ids: string[]) =>
    ids.map((id) => ({ id, name: null, externalAccountId: id, role: null }))
  );
  return {
    self: {
      resolveComposeLinkType: vi.fn(async () => opts.linkTypeConfig),
      userContactIds: vi.fn(async () => new Set(opts.selfIds ?? [])),
      resolveDispatchRecipients,
      resolveNoteRecipients: (Integrations.prototype as any).resolveNoteRecipients,
    } as any,
    resolveDispatchRecipients,
  };
}

const call = (self: any, args: any) =>
  (Integrations.prototype as any).resolveNoteRecipients.call(self, args);

describe("Integrations.resolveNoteRecipients", () => {
  const base = {
    createdBy: "user-1",
    threadId: "thread-1",
    linkType: "email",
    channelId: "mail:INBOX",
  };

  it("returns null when the note has no access list (reply-all)", async () => {
    const { self } = makeThis({ linkTypeConfig: EMAIL });
    expect(await call(self, { ...base, accessContacts: null })).toBeNull();
    expect(self.resolveComposeLinkType).not.toHaveBeenCalled();
  });

  it("returns null when the link type is missing", async () => {
    const { self } = makeThis({ linkTypeConfig: EMAIL });
    expect(
      await call(self, { ...base, linkType: null, accessContacts: ["c1"] })
    ).toBeNull();
  });

  it("returns null when the link type does not address by recipient", async () => {
    const { self } = makeThis({ linkTypeConfig: NO_COMPOSE });
    expect(
      await call(self, { ...base, accessContacts: ["c1"] })
    ).toBeNull();
  });

  it("resolves curated recipients, excluding the acting user's own contacts", async () => {
    // access list = [self-primary, self-secondary, tobin, beth]; two are the
    // user's own linked contacts and must be dropped before resolution.
    const { self, resolveDispatchRecipients } = makeThis({
      linkTypeConfig: EMAIL,
      selfIds: ["self-primary", "self-secondary"],
    });
    const result = await call(self, {
      ...base,
      accessContacts: ["self-primary", "self-secondary", "tobin", "beth"],
    });
    expect(resolveDispatchRecipients).toHaveBeenCalledWith(
      ["tobin", "beth"],
      "addresses",
      "thread-1"
    );
    expect(result?.map((r: any) => r.externalAccountId)).toEqual([
      "tobin",
      "beth",
    ]);
  });

  it("a private note (access list = only the user's own contacts) resolves to no recipients", async () => {
    const { self, resolveDispatchRecipients } = makeThis({
      linkTypeConfig: EMAIL,
      selfIds: ["self-primary"],
    });
    const result = await call(self, {
      ...base,
      accessContacts: ["self-primary"],
    });
    expect(resolveDispatchRecipients).toHaveBeenCalledWith([], "addresses", "thread-1");
    expect(result).toEqual([]);
  });

  it("passes contacts targets through unchanged", async () => {
    const { self, resolveDispatchRecipients } = makeThis({
      linkTypeConfig: { type: "dm", compose: { targets: "contacts" } },
    });
    await call(self, { ...base, linkType: "dm", accessContacts: ["c1"] });
    expect(resolveDispatchRecipients).toHaveBeenCalledWith(["c1"], "contacts", "thread-1");
  });
});
