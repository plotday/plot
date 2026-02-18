import {
  type NewContact,
  Serializable,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Syncable,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

import type { GoogleContacts as IGoogleContacts, GoogleContactsOptions } from "./types";

type ContactTokens = {
  connections?: {
    nextPageToken?: string;
    nextSyncToken?: string;
  };
  other?: {
    nextPageToken?: string;
    nextSyncToken?: string;
  };
};

type ContactSyncState = {
  more?: boolean;
  state?: string;
};

type GoogleContact = {
  names?: Array<{
    displayName?: string;
  }>;
  emailAddresses?: Array<{
    value?: string;
  }>;
  photos?: Array<{
    url?: string;
    default?: boolean;
    metadata?: {
      primary?: boolean;
    };
  }>;
};

type ListResponse = {
  connections?: GoogleContact[];
  nextPageToken?: string;
  nextSyncToken?: string;
};

type ListOtherResponse = {
  otherContacts?: GoogleContact[];
  nextPageToken?: string;
  nextSyncToken?: string;
};

class GoogleApi {
  constructor(public accessToken: string) {}

  public async call(
    method: string,
    url: string,
    params?: { [key: string]: any },
    body?: { [key: string]: any }
  ) {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    const headers = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };
    const response = await fetch(url + query, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    switch (response.status) {
      case 400:
        const responseBody = await response.json();
        if (responseBody.status === "FAILED_PRECONDITION") {
          return null;
        }
        throw new Error("Invalid request", { cause: responseBody });
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 410:
        return null;
      case 200:
        return await response.json();
      default:
        throw new Error(await response.text());
    }
  }
}

function parseContact(contact: GoogleContact) {
  const name = contact.names?.[0]?.displayName;
  const avatar = contact.photos?.filter(
    (p: NonNullable<GoogleContact["photos"]>[number]) =>
      !p.default && p.metadata?.primary
  )?.[0]?.url;
  return { name, avatar };
}

async function getGoogleContacts(
  api: GoogleApi,
  scopes: string[],
  state: ContactSyncState
): Promise<{
  contacts: NewContact[];
  state: ContactSyncState;
}> {
  let tokens = JSON.parse(state.state ?? "{}") as ContactTokens;
  const contacts = {} as Record<string, NewContact>;
  let more = false;

  if (!state.more || tokens.connections?.nextPageToken) {
    if (
      scopes?.some?.(
        (scope) => scope === "https://www.googleapis.com/auth/contacts.readonly"
      )
    ) {
      let response: ListResponse | undefined;
      while (true) {
        response = (await api.call(
          "GET",
          "https://people.googleapis.com/v1/people/me/connections",
          {
            requestSyncToken: true,
            ...(tokens.connections?.nextPageToken
              ? {
                  pageToken: tokens.connections?.nextPageToken,
                }
              : tokens.connections?.nextSyncToken
              ? {
                  syncToken: tokens.connections?.nextSyncToken,
                }
              : {}),
            personFields: "names,emailAddresses,photos",
          }
        )) as ListResponse;
        if (response !== null) break;
        if (!tokens.connections) break;
        tokens.connections = undefined;
        continue;
      }
      if (response) {
        for (const c of response.connections ?? []) {
          for (const e of c.emailAddresses ?? []) {
            if (!e.value) continue;
            const { name, avatar } = parseContact(c);
            contacts[e.value] = {
              ...contacts[e.value],
              email: e.value,
              ...(name ? { name } : {}),
              ...(avatar ? { avatar } : {}),
            };
          }
        }
        more = true;
        tokens = {
          ...tokens,
          connections: {
            nextPageToken: response.nextPageToken ?? undefined,
            nextSyncToken: response.nextSyncToken ?? undefined,
          },
        };
      }
    } else {
      more = true;
      tokens = {
        ...tokens,
        connections: {},
      };
    }
  } else {
    if (
      scopes?.some?.(
        (scope) =>
          scope === "https://www.googleapis.com/auth/contacts.other.readonly"
      )
    ) {
      let response: ListOtherResponse | undefined;
      while (true) {
        response = (await api.call(
          "GET",
          "https://people.googleapis.com/v1/otherContacts",
          {
            requestSyncToken: true,
            ...(tokens.other?.nextPageToken
              ? {
                  pageToken: tokens.other?.nextPageToken,
                }
              : tokens.other?.nextSyncToken
              ? {
                  syncToken: tokens.other?.nextSyncToken,
                }
              : {}),
            readMask: "names,emailAddresses,photos",
          }
        )) as ListOtherResponse;
        if (response !== null) break;
        if (!tokens.other) break;
        tokens.other = undefined;
        continue;
      }
      if (response) {
        for (const c of response.otherContacts ?? []) {
          for (const e of c.emailAddresses ?? []) {
            if (!e.value) continue;
            const { name, avatar } = parseContact(c);
            contacts[e.value] = {
              ...contacts[e.value],
              email: e.value,
              ...(name ? { name } : {}),
              ...(avatar ? { avatar } : {}),
            };
          }
        }
        more = !!response.nextPageToken;
        tokens = {
          ...tokens,
          other: {
            nextPageToken: response.nextPageToken ?? undefined,
            nextSyncToken: response.nextSyncToken ?? undefined,
          },
        };
      }
    } else {
      more = false;
      tokens = {
        ...tokens,
        other: {},
      };
    }
  }

  return {
    contacts: Object.values(contacts),
    state: {
      more,
      state: JSON.stringify(tokens),
    },
  };
}

export default class GoogleContacts
  extends Tool<GoogleContacts>
  implements IGoogleContacts
{
  static readonly id = "google-contacts";

  static readonly PROVIDER = AuthProvider.Google;
  static readonly Options: GoogleContactsOptions;
  declare readonly Options: GoogleContactsOptions;

  static readonly SCOPES = [
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/contacts.other.readonly",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: GoogleContacts.PROVIDER,
          scopes: GoogleContacts.SCOPES,
          getSyncables: this.getSyncables,
          onSyncEnabled: this.onSyncEnabled,
          onSyncDisabled: this.onSyncDisabled,
        }],
      }),
      network: build(Network, {
        urls: ["https://people.googleapis.com/*"],
      }),
    };
  }

  async getSyncables(_auth: Authorization, _token: AuthToken): Promise<Syncable[]> {
    return [{ id: "contacts", title: "Contacts" }];
  }

  async onSyncEnabled(syncable: Syncable): Promise<void> {
    // Create item callback token from parent's onItem handler
    const itemCallbackToken = await this.tools.callbacks.createFromParent(
      this.options.onItem
    );
    await this.set(`item_callback_${syncable.id}`, itemCallbackToken);

    // Auto-start sync
    const token = await this.tools.integrations.get(
      GoogleContacts.PROVIDER,
      syncable.id
    );
    if (!token) {
      throw new Error("No Google authentication token available");
    }

    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${syncable.id}`, initialState);

    const syncCallback = await this.callback(this.syncBatch, 1, syncable.id);
    await this.run(syncCallback);
  }

  async onSyncDisabled(syncable: Syncable): Promise<void> {
    await this.stopSync(syncable.id);

    // Clean up item callback
    const itemCallbackToken = await this.get<Callback>(
      `item_callback_${syncable.id}`
    );
    if (itemCallbackToken) {
      await this.deleteCallback(itemCallbackToken);
      await this.clear(`item_callback_${syncable.id}`);
    }
  }

  async getContacts(syncableId: string): Promise<NewContact[]> {
    const token = await this.tools.integrations.get(
      GoogleContacts.PROVIDER,
      syncableId
    );
    if (!token) {
      throw new Error(
        "No Google authentication token available for the provided syncableId"
      );
    }

    const api = new GoogleApi(token.token);
    const result = await getGoogleContacts(api, token.scopes, {
      more: false,
    });

    return result.contacts;
  }

  async startSync<
    TArgs extends Serializable[],
    TCallback extends (contacts: NewContact[], ...args: TArgs) => any
  >(syncableId: string, callback: TCallback, ...extraArgs: TArgs): Promise<void> {
    const token = await this.tools.integrations.get(
      GoogleContacts.PROVIDER,
      syncableId
    );
    if (!token) {
      throw new Error(
        "No Google authentication token available for the provided syncableId"
      );
    }

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`item_callback_${syncableId}`, callbackToken);

    // Start initial sync
    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${syncableId}`, initialState);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(this.syncBatch, 1, syncableId);
    await this.run(syncCallback);
  }

  async stopSync(syncableId: string): Promise<void> {
    // Clear sync state for this specific syncable
    await this.clear(`sync_state:${syncableId}`);
    await this.clear(`item_callback_${syncableId}`);
  }

  async syncBatch(batchNumber: number, syncableId: string): Promise<void> {
    try {
      const token = await this.tools.integrations.get(
        GoogleContacts.PROVIDER,
        syncableId
      );
      if (!token) {
        throw new Error(
          "No authentication token available for the provided syncableId"
        );
      }

      const state = await this.get<ContactSyncState>(`sync_state:${syncableId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = new GoogleApi(token.token);
      const result = await getGoogleContacts(
        api,
        token.scopes,
        state
      );

      if (result.contacts.length > 0) {
        await this.processContacts(result.contacts, syncableId);
      }

      await this.set(`sync_state:${syncableId}`, result.state);

      if (result.state.more) {
        const nextCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          syncableId
        );
        await this.run(nextCallback);
      } else {
        await this.clear(`sync_state:${syncableId}`);
      }
    } catch (error) {
      console.error(`Error in sync batch ${batchNumber}:`, error);

      throw error;
    }
  }

  private async processContacts(
    contacts: NewContact[],
    syncableId: string
  ): Promise<void> {
    const callbackToken = await this.get<Callback>(
      `item_callback_${syncableId}`
    );
    if (callbackToken) {
      await this.run(callbackToken, contacts);
    }
  }
}
