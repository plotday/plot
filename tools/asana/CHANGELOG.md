# @plotday/tool-asana

## 0.4.1

### Changed

- Updated dependencies:
- @plotday/twister@0.29.0

## 0.4.0

### Changed

- Use Activity.source with canonical URLs for upserting ([`8053f7a`](https://github.com/plotday/plot/commit/8053f7a49ca0dc871bd4e1ef8edb4dd54f1abaef))
- Updated dependencies:
- @plotday/twister@0.28.0

## 0.3.0

### Added

- created_at for item's original creation time in the source system ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

### Changed

- BREAKING: Replace Activity.source for linking with source items with generated and stored UUIDs ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- BREAKING: Support either IDs or email for contact fields ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- Updated dependencies:
- @plotday/twister@0.27.0

### Fixed

- Set author and assignee ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

## 0.2.0

### Added

- Two-way sync in project management tools ([`b0c756d`](https://github.com/plotday/plot/commit/b0c756ddd3b2f334f1a19248dbe9279b2777a5ec))

### Changed

- BREAKING: Moved unread flag for new activity and notes into those items ([`c72a690`](https://github.com/plotday/plot/commit/c72a6902bf9798b666abc8d9cc652a18973920f1))
- Updated dependencies:
- @plotday/twister@0.26.0
