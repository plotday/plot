# Google Contacts Tool

A Plot tool for syncing with Google Contacts.

## Installation

```bash
npm install @plotday/tool-google-contacts @plotday/twister
```

## Usage

```typescript
import { Twist, Tools } from "@plotday/twister";
import { GoogleContacts } from "@plotday/tool-google-contacts";
import { Integrations, AuthProvider } from "@plotday/twister/tools/integrations";

export default class extends Twist {
  private googleContacts: GoogleContacts;
  private auth: Integrations;

  constructor(id: string, tools: Tools) {
    super();
    this.googleContacts = tools.get(GoogleContacts);
    this.integrations = tools.get(Integrations);
  }

  async activate(priority: { id: string }) {
    // Request Google Contacts access
    const authLink = await this.integrations.request(
      {
        provider: AuthProvider.Google,
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
    const authToken = await this.integrations.get(authorization);

    // Start syncing contacts
    await this.googleContacts.startSync(authToken, "onContact");
  }

  async onContact(contact: any) {
    // Handle contact updates
    console.log("Contact:", contact.names?.[0]?.displayName);
  }
}
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
