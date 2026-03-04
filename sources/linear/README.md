# Linear Tool for Plot

Sync your Linear teams and issues with Plot.

## Features

- OAuth authentication with Linear
- Sync issues from Linear teams to Plot activities
- Real-time updates via webhooks
- Issue comments synced as activity notes
- Automatic issue state mapping

## Usage

```typescript
import { Linear } from "@plotday/tool-linear";
import { Twist, type ToolBuilder } from "@plotday/twister";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      linear: build(Linear),
    };
  }

  async activate() {
    // Request Linear authorization
    const authLink = await this.tools.linear.requestAuth(this.onAuthComplete);
    // ... show authLink to user
  }

  async onAuthComplete(auth: { authToken: string }) {
    // Get available teams
    const projects = await this.tools.linear.getProjects(auth.authToken);

    // Start syncing a team
    await this.tools.linear.startSync(
      auth.authToken,
      projects[0].id,
      this.onIssue
    );
  }

  async onIssue(issue: NewActivityWithNotes) {
    // Handle synced issue
    await this.tools.plot.createActivity(issue);
  }
}
```

## License

MIT
