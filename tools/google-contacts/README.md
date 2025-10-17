# Google Contacts Tool

A Plot tool for syncing with Google Contacts.

## Installation

```bash
npm install @plotday/tool-google-contacts @plotday/sdk
```

## Usage

```typescript
import { Agent, Tools, createAgent } from "@plotday/sdk";
import { GoogleContacts } from "@plotday/tool-google-contacts";
import { Auth, AuthLevel, AuthProvider } from "@plotday/sdk/tools/auth";

export default createAgent(
  class extends Agent {
    private googleContacts: GoogleContacts;
    private auth: Auth;

    constructor(tools: Tools) {
      super();
      this.googleContacts = tools.get(GoogleContacts);
      this.auth = tools.get(Auth);
    }

    async activate(priority: { id: string }) {
      // Request Google Contacts access
      const authLink = await this.auth.request(
        {
          provider: AuthProvider.Google,
          level: AuthLevel.User,
          scopes: ["https://www.googleapis.com/auth/contacts.readonly"],
        },
        {
          functionName: "onAuthComplete",
          context: { priorityId: priority.id },
        }
      );

      // User will authenticate via authLink
    }

    async onAuthComplete(authorization: any, context: any) {
      const authToken = await this.auth.get(authorization);

      // Start syncing contacts
      await this.googleContacts.startSync(authToken, "onContact");
    }

    async onContact(contact: any) {
      // Handle contact updates
      console.log("Contact:", contact.names?.[0]?.displayName);
    }
  }
);
```

## API

### `getContacts(authToken: string, options?: object)`

Retrieves contacts from Google Contacts.

### `startSync(authToken: string, callbackName: string)`

Starts syncing contacts from Google Contacts.

### `stopSync(authToken: string)`

Stops syncing contacts from Google Contacts.

## License

MIT © Plot Technologies Inc.
