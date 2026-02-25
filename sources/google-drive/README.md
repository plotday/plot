# Google Drive Tool

A Plot tool for syncing documents comments from Google Drive.

## Installation

```bash
npm install @plotday/tool-google-drive @plotday/twister
```

## Usage

```typescript
import { GoogleDrive } from "@plotday/tool-google-drive";
import { Tools, Twist } from "@plotday/twister";
import {
  AuthProvider,
  Integrations,
} from "@plotday/twister/tools/integrations";

export default class extends Twist {
  private googleDrive: GoogleDrive;
  private integrations: Integrations;

  constructor(id: string, tools: Tools) {
    super();
    this.googleDrive = tools.get(GoogleDrive);
    this.integrations = tools.get(Integrations);
  }

  async activate(priority: { id: string }) {
    // Request Google Drive access
    const authLink = await this.integrations.request(
      {
        provider: AuthProvider.Google,
        scopes: GoogleDrive.SCOPES,
      },
      {
        functionName: "onAuthComplete",
        context: { priorityId: priority.id },
      }
    );

    // User will authenticate via authLink
  }
}
```

## Features

- OAuth 2.0 authentication with Google
- Folder-based document synchronization
- Comment and reply syncing
- Webhook-based change notifications
- Batch processing for large folders
- Bidirectional comment sync

## License

MIT © Plot Technologies Inc.
