---
"@plotday/twister": minor
---

Added: `LinkTypeConfig.targets` and `CreateLinkDraft.recipients` / `ResolvedRecipient` to support contact-targeted link types (e.g. messaging DMs) where the runtime pre-resolves Plot contacts to platform account IDs before dispatching `onCreateLink`.
