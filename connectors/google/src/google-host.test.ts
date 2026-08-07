import { describe, expect, it, vi } from "vitest";

import { Google } from "./google";

/**
 * Host-seam tests: the product hosts built by the connector must hand the
 * products an integrations tool that namespaces persisted channel ids
 * (calendar:<id> / tasks:<id>) while leaving token reads untouched.
 */
function makeConnector() {
  const integrations = {
    get: vi.fn().mockResolvedValue({ token: "tok", scopes: [] }),
    saveLink: vi.fn().mockResolvedValue("thread-1"),
    saveLinks: vi.fn().mockResolvedValue(undefined),
    channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
    archiveLinks: vi.fn().mockResolvedValue(undefined),
  };
  const tools = {
    integrations,
    store: {
      acquireLock: vi.fn().mockResolvedValue(true),
      releaseLock: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
      listEntries: vi.fn().mockResolvedValue([]),
      clearMany: vi.fn().mockResolvedValue(undefined),
    },
    tasks: { runTask: vi.fn().mockResolvedValue(undefined) },
    callbacks: { create: vi.fn().mockResolvedValue("cb-token") },
    network: {},
    files: {},
    googleContacts: {},
  };
  const google = new Google("twist-1" as never, {
    getTools: () => tools,
  } as never);
  return { google, integrations };
}

type HostWithIntegrations = {
  tools: {
    integrations: {
      saveLinks?: (links: unknown[]) => Promise<void>;
      saveLink?: (link: unknown) => Promise<string | null>;
      get: (channelId: string) => Promise<unknown>;
      archiveLinks: (filter: Record<string, unknown>) => Promise<void>;
    };
  };
};

describe("makeCalendarHost integrations seam", () => {
  it("saves calendar links under namespaced channel ids", async () => {
    const { google, integrations } = makeConnector();
    const host = (
      google as unknown as { makeCalendarHost: () => HostWithIntegrations }
    ).makeCalendarHost();
    await host.tools.integrations.saveLinks!([
      { channelId: "kris@plot.day", source: "s", type: "event" },
    ]);
    expect(integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ channelId: "calendar:kris@plot.day" }),
    ]);
  });

  it("reads tokens with the raw id the product passed", async () => {
    const { google, integrations } = makeConnector();
    const host = (
      google as unknown as { makeCalendarHost: () => HostWithIntegrations }
    ).makeCalendarHost();
    await host.tools.integrations.get("kris@plot.day");
    expect(integrations.get).toHaveBeenCalledWith("kris@plot.day");
  });
});

describe("makeTasksHost integrations seam", () => {
  it("saves task links under namespaced channel ids", async () => {
    const { google, integrations } = makeConnector();
    const host = (
      google as unknown as { makeTasksHost: () => HostWithIntegrations }
    ).makeTasksHost();
    await host.tools.integrations.saveLink!({
      channelId: "list1",
      source: "s",
      type: "task",
    });
    expect(integrations.saveLink).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "tasks:list1" })
    );
  });

  it("archives BOTH eras when the tasks product archives a list", async () => {
    const { google, integrations } = makeConnector();
    const host = (
      google as unknown as { makeTasksHost: () => HostWithIntegrations }
    ).makeTasksHost();
    await host.tools.integrations.archiveLinks({ channelId: "list1" });
    expect(integrations.archiveLinks).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "tasks:list1" })
    );
    expect(integrations.archiveLinks).toHaveBeenCalledWith(
      expect.objectContaining({ channelId: "list1" })
    );
  });
});
