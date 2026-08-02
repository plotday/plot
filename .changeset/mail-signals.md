---
"@plotday/twister": minor
---

Added: `NewLink.signals` and the `@plotday/twister/signals` entry point.

Connectors can now emit the raw signals they extract from a source item —
email headers, provider categories, recipient counts — instead of a finished
`facets` verdict. The platform derives classification from those signals, so
classification can improve without redeploying every connector, and can be
combined with recipient-relative context a connector cannot observe.

`facets` continues to work unchanged. When a link carries both, `signals` wins.
