---
"@plotday/twister": patch
---

Fixed: package lint and editor type resolution for the exemplar sources' package self-imports (bundler moduleResolution now applies package-wide; the CommonJS CLI build uses its own standalone config).
