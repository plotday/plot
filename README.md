<p align="center">
  <a href="https://linear.app" target="_blank" rel="noopener noreferrer">
    <img width="48" height="48" alt="favicon" src="https://github.com/user-attachments/assets/f38501fd-bb37-4671-a0bc-fd35fa25360d" alt="Plot logo" />
  </a>
</p>
<h1 align="center">
  Plot Agent Builder
</h1>
<p align="center">
  The official package for building <a href="https://plot.day">Plot</a> agents -<br/>
  custom code that organizes and prioritizes all your messages, tasks, and apps.
</p>

## Packages

- **[@plotday/agent](./agent)** - Core agent builder package with the `plot` command, agent and tool SDK, and built-in tools
- **[tools/](./tools)** - Additional tools for building agents, including integrations with popular services
- **[agents/](./agents)** - Full source code for several agents

## Quick Start

You'll need a [Plot account](https://plot.day) to deploy agents.

```bash
# Create a new agent
npx @plotday/agent create

# Connect your Plot account
npx @plotday/agent login

# Deploy your agent
cd my-agent
npm run deploy
```

## Documentation

See the [Plot Agent Builder documentation](https://build.plot.day) for detailed guides and API reference.

## Changelog

See the [builder changelog](./agent/CHANGELOG.md) for version history and release notes.

## License

MIT © Plot Technologies Inc.
