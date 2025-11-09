<p align="center">
  <a href="https://plot.day" target="_blank" rel="noopener noreferrer">
    <img width="48" height="48" alt="favicon" src="https://github.com/user-attachments/assets/f38501fd-bb37-4671-a0bc-fd35fa25360d" alt="Plot logo" />
  </a>
</p>
<h1 align="center">
  🌪️ Twister, the Plot Twist Creator
</h1>
<p align="center">
  The official package for building <a href="https://plot.day">Plot</a> twists -<br/>
  smart automations that organize and prioritize all your tasks, messages, and documents from all your apps and agents.
</p>

## Packages

- **[@plotday/twister](./twister)** - Core twist creator package with the `plot` command, twist and tool SDK, and built-in tools
- **[tools/](./tools)** - Additional tools for building twists, including integrations with popular services
- **[twists/](./twists)** - Full source code for several twists

## Quick Start

You'll need a [Plot account](https://plot.day) to deploy twists.

```bash
# Create a new twist
npx @plotday/twister create

# Connect your Plot account
npx @plotday/twister login

# Deploy your twist
cd my-twist
npm run deploy
```

## Documentation

See the [Twist Creator documentation](https://build.plot.day) for detailed guides and API reference.

## Changelog

See the [Twister changelog](./twister/CHANGELOG.md) for version history and release notes.

## License

MIT © Plot Technologies Inc.
