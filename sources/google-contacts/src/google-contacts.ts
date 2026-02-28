import {
  type NewContact,
  Source,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

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
  extends Source<GoogleContacts>
{
  static readonly id = "google-contacts";

  static readonly PROVIDER = AuthProvider.Google;

  static readonly SCOPES = [
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/contacts.other.readonly",
  ];

  readonly provider = AuthProvider.Google;
  readonly scopes = GoogleContacts.SCOPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://people.googleapis.com/*"],
      }),
    };
  }

  async getChannels(_auth: Authorization, _token: AuthToken): Promise<Channel[]> {
    return [{ id: "contacts", title: "Contacts" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    const token = await this.tools.integrations.get(channel.id);
    if (!token) {
      throw new Error("No Google authentication token available");
    }

    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${channel.id}`, initialState);

    const syncCallback = await this.callback(this.syncBatch, 1, channel.id);
    await this.run(syncCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
  }

  async getContacts(syncableId: string): Promise<NewContact[]> {
    const token = await this.tools.integrations.get(syncableId);
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

  async startSync(syncableId: string): Promise<void> {
    const token = await this.tools.integrations.get(syncableId);
    if (!token) {
      throw new Error(
        "No Google authentication token available for the provided syncableId"
      );
    }

    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${syncableId}`, initialState);

    const syncCallback = await this.callback(this.syncBatch, 1, syncableId);
    await this.run(syncCallback);
  }

  async stopSync(syncableId: string): Promise<void> {
    await this.clear(`sync_state:${syncableId}`);
  }

  async syncBatch(batchNumber: number, syncableId: string): Promise<void> {
    try {
      const token = await this.tools.integrations.get(syncableId);
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
        await this.processContacts(result.contacts);
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
  ): Promise<void> {
    await this.tools.integrations.saveContacts(contacts);
  }
}
