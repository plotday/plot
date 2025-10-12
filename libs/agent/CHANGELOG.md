# Changelog

All notable changes to the Plot Agent SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-01-XX

### Added

- Initial public release of the Plot Agent SDK
- Core agent framework with `Agent` base class
- Tool system with dependency injection
- Built-in tools:
  - `Plot` - Create and manage activities and priorities
  - `Store` - Persistent key-value storage
  - `Auth` - OAuth authentication for external services
  - `Run` - Background task scheduling
  - `Webhook` - Real-time webhook registration
  - `Callback` - Persistent function references
  - `AI` - AI integration capabilities
- Regular tools:
  - `GoogleCalendar` - Google Calendar integration
  - `GoogleContacts` - Google Contacts integration
  - `OutlookCalendar` - Microsoft Outlook/365 Calendar integration
- Plot CLI (`plot` command)
  - `plot login` - Authenticate with Plot
  - `plot agent create` - Scaffold new agents
  - `plot agent lint` - Type check agents
  - `plot agent deploy` - Build and deploy agents
  - `plot agent link` - Link agents to priorities
  - `plot priority list` - List priorities
  - `plot priority create` - Create new priorities
- Comprehensive TypeScript support with full type definitions
- Cross-platform support (Windows, macOS, Linux)
- Package manager detection (npm, yarn, pnpm)
- Documentation and examples

### Security

- Secure token storage with platform-specific permissions
- OAuth 2.0 authentication flows
- Sandboxed execution environment

[0.1.0]: https://github.com/plotday/plot/releases/tag/v0.1.0
