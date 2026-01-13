import { Tool, type ToolBuilder, type NewContact } from "@plotday/twister";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

import type {
  ContactAuth,
  GoogleContacts as IGoogleContacts,
} from "./types";

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

  static readonly SCOPES = [
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/contacts.other.readonly",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://people.googleapis.com/*"],
      }),
    };
  }

  async requestAuth<
    TCallback extends (auth: ContactAuth, ...args: any[]) => any
  >(callback: TCallback, ...extraArgs: any[]): Promise<any> {
    const opaqueToken = crypto.randomUUID();

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Google,
        level: AuthLevel.User,
        scopes: GoogleContacts.SCOPES,
      },
      this.onAuthSuccess,
      opaqueToken,
      callbackToken
    );
  }

  async getContacts(authToken: string): Promise<NewContact[]> {
    const storedAuthToken = await this.get<AuthToken>(
      `auth_token:${authToken}`
    );
    if (!storedAuthToken) {
      throw new Error(
        "No Google authentication token available for the provided authToken"
      );
    }

    const api = new GoogleApi(storedAuthToken.token);
    const result = await getGoogleContacts(api, storedAuthToken.scopes, {
      more: false,
    });

    return result.contacts;
  }

  async startSync<
    TCallback extends (contacts: NewContact[], ...args: any[]) => any
  >(
    authToken: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void> {
    const storedAuthToken = await this.get<AuthToken>(
      `auth_token:${authToken}`
    );
    if (!storedAuthToken) {
      throw new Error(
        "No Google authentication token available for the provided authToken"
      );
    }

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`contacts_callback_token:${authToken}`, callbackToken);

    // Start initial sync
    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${authToken}`, initialState);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(this.syncBatch, 1, authToken);
    await this.run(syncCallback);
  }

  /**
   * Start contact sync using an existing Authorization and AuthToken from another tool.
   * This enables other Google tools (like calendar) to trigger contact syncing
   * after they've obtained auth with combined scopes.
   *
   * @param authorization - Authorization object containing provider and scopes
   * @param authToken - Actual auth token data retrieved by the calling tool
   * @param callback - Optional callback to invoke with synced contacts
   * @param extraArgs - Additional arguments to pass to the callback
   */
  async syncWithAuth<
    TCallback extends (contacts: NewContact[], ...args: any[]) => any
  >(
    authorization: Authorization,
    authToken: AuthToken,
    callback?: TCallback,
    ...extraArgs: any[]
  ): Promise<void> {
    // Validate authorization has required contacts scopes
    const hasRequiredScopes = GoogleContacts.SCOPES.every((scope) =>
      authorization.scopes.includes(scope)
    );

    if (!hasRequiredScopes) {
      throw new Error(
        `Authorization missing required contacts scopes. Required: ${GoogleContacts.SCOPES.join(
          ", "
        )}. Got: ${authorization.scopes.join(", ")}`
      );
    }

    // Generate opaque token ID for storage
    const authTokenId = crypto.randomUUID();

    // Store the auth token data (passed directly from caller)
    await this.set(`auth_token:${authTokenId}`, authToken);

    // Setup callback if provided
    if (callback) {
      const callbackToken = await this.tools.callbacks.createFromParent(
        callback,
        ...extraArgs
      );
      await this.set(`contacts_callback_token:${authTokenId}`, callbackToken);
    }

    // Initialize sync state
    const initialState: ContactSyncState = {
      more: false,
    };
    await this.set(`sync_state:${authTokenId}`, initialState);

    // Start sync batch
    const syncCallback = await this.callback(this.syncBatch, 1, authTokenId);
    await this.runTask(syncCallback);
  }

  async stopSync(authToken: string): Promise<void> {
    // Clear sync state for this specific auth token
    await this.clear(`sync_state:${authToken}`);
    await this.clear(`contacts_callback_token:${authToken}`);
  }

  async syncBatch(batchNumber: number, authToken: string): Promise<void> {
    console.log(`Starting Google Contacts sync batch ${batchNumber}`);

    try {
      const storedAuthToken = await this.get<AuthToken>(
        `auth_token:${authToken}`
      );
      if (!storedAuthToken) {
        throw new Error(
          "No authentication token available for the provided authToken"
        );
      }

      const state = await this.get<ContactSyncState>(`sync_state:${authToken}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = new GoogleApi(storedAuthToken.token);
      const result = await getGoogleContacts(
        api,
        storedAuthToken.scopes,
        state
      );

      if (result.contacts.length > 0) {
        await this.processContacts(result.contacts, authToken);
        console.log(
          `Synced ${result.contacts.length} contacts in batch ${batchNumber}`
        );
      }

      await this.set(`sync_state:${authToken}`, result.state);

      if (result.state.more) {
        const nextCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          authToken
        );
        await this.run(nextCallback);
      } else {
        console.log(
          `Google Contacts sync completed after ${batchNumber} batches`
        );
        await this.clear(`sync_state:${authToken}`);
      }
    } catch (error) {
      console.error(`Error in sync batch ${batchNumber}:`, error);

      throw error;
    }
  }

  private async processContacts(
    contacts: NewContact[],
    authToken: string
  ): Promise<void> {
    const callbackToken = await this.get<Callback>(
      `contacts_callback_token:${authToken}`
    );
    if (callbackToken) {
      await this.run(callbackToken, contacts);
    }
  }

  async onAuthSuccess(
    authResult: Authorization,
    opaqueToken: string,
    callbackToken: Callback
  ): Promise<void> {
    console.log("Google Contacts authentication successful", authResult);

    // Store the actual auth token using opaque token as key
    await this.set(`auth_token:${opaqueToken}`, authResult);

    const authSuccessResult: ContactAuth = {
      authToken: opaqueToken,
    };

    await this.run(callbackToken, authSuccessResult);
  }
}
