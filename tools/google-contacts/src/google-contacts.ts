import { Tool, type Tools } from "@plotday/sdk";
import {
  Auth,
  AuthLevel,
  AuthProvider,
  type AuthToken,
} from "@plotday/sdk/tools/auth";
import { type Callback } from "@plotday/sdk/tools/callback";
import type { Contact, ContactAuth, GoogleContacts } from "./types";

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
    body?: { [key: string]: any },
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
        if ((responseBody as any).status === "FAILED_PRECONDITION") {
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
      !p.default && p.metadata?.primary,
  )?.[0]?.url;
  return { name, avatar };
}

async function getGoogleContacts(
  api: GoogleApi,
  scopes: string[],
  state: ContactSyncState,
): Promise<{
  contacts: Contact[];
  state: ContactSyncState;
}> {
  let tokens = JSON.parse(state.state ?? "{}") as ContactTokens;
  const contacts = {} as Record<string, Contact>;
  let more = false;

  if (!state.more || tokens.connections?.nextPageToken) {
    if (
      scopes?.some?.(
        (scope) =>
          scope === "https://www.googleapis.com/auth/contacts.readonly",
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
          },
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
          scope === "https://www.googleapis.com/auth/contacts.other.readonly",
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
          },
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

export default class extends Tool implements GoogleContacts {
  static readonly id = "google-contacts";

  private auth: Auth;

  constructor(protected tools: Tools) {
    super(tools);
    this.auth = tools.get(Auth);
  }

  async requestAuth(
    callbackFunctionName: string,
    callbackContext?: any,
  ): Promise<any> {
    const contactsScopes = [
      "https://www.googleapis.com/auth/contacts.readonly",
      "https://www.googleapis.com/auth/contacts.other.readonly",
    ];

    // Generate opaque token for this authorization
    const opaqueToken = crypto.randomUUID();

    // Register the callback for auth completion with opaque token
    const callbackToken = await this.callback(
      callbackFunctionName,
      callbackContext,
    );
    await this.set(`auth_callback_token:${opaqueToken}`, callbackToken);

    // Create callback for auth completion
    const authCallback = await this.callback("onAuthSuccess", {
      toolName: "google-contacts",
      opaqueToken,
    });

    // Request auth and return the activity link
    return await this.auth.request(
      {
        provider: AuthProvider.Google,
        level: AuthLevel.User,
        scopes: contactsScopes,
      },
      authCallback,
    );
  }

  async getContacts(authToken: string): Promise<Contact[]> {
    const storedAuthToken = await this.get<AuthToken>(
      `auth_token:${authToken}`,
    );
    if (!storedAuthToken) {
      throw new Error(
        "No Google authentication token available for the provided authToken",
      );
    }

    const api = new GoogleApi(storedAuthToken.token);
    const result = await getGoogleContacts(api, storedAuthToken.scopes, {
      more: false,
    });

    return result.contacts;
  }

  async startSync(
    authToken: string,
    callbackFunctionName: string,
    options?: {
      context?: any;
    },
  ): Promise<void> {
    const storedAuthToken = await this.get<AuthToken>(
      `auth_token:${authToken}`,
    );
    if (!storedAuthToken) {
      throw new Error(
        "No Google authentication token available for the provided authToken",
      );
    }

    // Register the callback
    const callbackToken = await this.callback(
      callbackFunctionName,
      options?.context,
    );
    await this.set(`contacts_callback_token:${authToken}`, callbackToken);

    // Start initial sync
    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${authToken}`, initialState);

    // Start sync batch using run tool for long-running operation
    const callback = await this.callback("syncBatch", {
      batchNumber: 1,
      authToken,
    });
    await this.run(callback);
  }

  async stopSync(authToken: string): Promise<void> {
    // Clear sync state for this specific auth token
    await this.clear(`sync_state:${authToken}`);
    await this.clear(`contacts_callback_token:${authToken}`);
  }

  async syncBatch(context: {
    batchNumber: number;
    authToken: string;
  }): Promise<void> {
    const { batchNumber, authToken } = context;
    console.log(`Starting Google Contacts sync batch ${batchNumber}`);

    try {
      const storedAuthToken = await this.get<AuthToken>(
        `auth_token:${authToken}`,
      );
      if (!storedAuthToken) {
        throw new Error(
          "No authentication token available for the provided authToken",
        );
      }

      const state = await this.get<ContactSyncState>(
        `sync_state:${authToken}`,
      );
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = new GoogleApi(storedAuthToken.token);
      const result = await getGoogleContacts(
        api,
        storedAuthToken.scopes,
        state,
      );

      if (result.contacts.length > 0) {
        await this.processContacts(result.contacts, authToken);
        console.log(
          `Synced ${result.contacts.length} contacts in batch ${batchNumber}`,
        );
      }

      await this.set(`sync_state:${authToken}`, result.state);

      if (result.state.more) {
        const callback = await this.callback("syncBatch", {
          batchNumber: batchNumber + 1,
          authToken,
        });
        await this.run(callback);
      } else {
        console.log(
          `Google Contacts sync completed after ${batchNumber} batches`,
        );
        await this.clear(`sync_state:${authToken}`);
      }
    } catch (error) {
      console.error(`Error in sync batch ${batchNumber}:`, error);

      throw error;
    }
  }

  private async processContacts(
    contacts: Contact[],
    authToken: string,
  ): Promise<void> {
    const callbackToken = await this.get<Callback>(
      `contacts_callback_token:${authToken}`,
    );
    if (callbackToken) {
      await this.call(callbackToken, contacts);
    }
  }

  async onAuthSuccess(authResult: any, context: any): Promise<void> {
    console.log("Google Contacts authentication successful", authResult);

    // Extract opaque token from context
    const opaqueToken = context?.opaqueToken;
    if (!opaqueToken) {
      console.error("No opaque token found in auth context");
      return;
    }

    // Store the actual auth token using opaque token as key
    await this.set(`auth_token:${opaqueToken}`, authResult);

    // Retrieve and call the stored callback
    const callbackToken = await this.get<Callback>(
      `auth_callback_token:${opaqueToken}`,
    );
    if (callbackToken) {
      const authSuccessResult: ContactAuth = {
        authToken: opaqueToken,
      };

      await this.call(callbackToken, authSuccessResult);

      // Clean up the callback token
      await this.clear(`auth_callback_token:${opaqueToken}`);
    }
  }
}
