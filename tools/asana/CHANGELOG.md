# @plotday/tool-asana

## 0.8.0

### Added

- Activity.links, better for activity-scoped links such as the link to the original item ([#100](https://github.com/plotday/plot/pull/100) [`76cac5a`](https://github.com/plotday/plot/commit/76cac5a562b4bb9dcb1dfe5571d6e8ae325316ef))

### Changed

- Updated dependencies:
- @plotday/twister@0.37.0

## 0.7.1

### Changed

- Updated dependencies:
- @plotday/twister@0.36.0

## 0.7.0

### Changed

- BREAKING: Rewrite of the Integrations tool and all sync tools to support much improved sync configuration when installing or editing a twist ([#93](https://github.com/plotday/plot/pull/93) [`f3ccb2f`](https://github.com/plotday/plot/commit/f3ccb2f91344b927536d367cea467e4cc2efefe3))
- Updated dependencies:
- @plotday/twister@0.35.0

## 0.6.1

### Changed

- Tightened types so Activity.done only available when type == Action ([`6ab1839`](https://github.com/plotday/plot/commit/6ab18392520eb6ef69a43212d2b66d599c9443e4))
- Updated dependencies:
- @plotday/twister@0.34.0

## 0.6.0

### Changed

- BREAKING: All integrations are now individual, always acting on behalf of a particular user. ([`2208632`](https://github.com/plotday/plot/commit/22086320eb79c3cbe6c95aeaeb34472e4c3d7b50))
- Updated dependencies:
- @plotday/twister@0.33.0

### Fixed

- Duplicate comments when commenting inside Plot ([`0004e24`](https://github.com/plotday/plot/commit/0004e241ea1c61a74141671a014788d4f96b9383))

## 0.5.1

### Changed

- Removed debugging logging ([`d8f07cd`](https://github.com/plotday/plot/commit/d8f07cd82d7db91fbb99c3e6b6b751980566e9b7))

### Fixed

- Always use event IDs rather than URL for source ([`b438aa3`](https://github.com/plotday/plot/commit/b438aa30240875c731d038df92e94f9435601637))

## 0.5.0

### Added

- Provide an activity preview ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))

### Changed

- BREAKING: Improve immutability of Activity.source and Note.key by using IDs rather than URLs ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))
- Explicitly set Activity.archived = false on initial syncs ([`6a0aec1`](https://github.com/plotday/plot/commit/6a0aec11ad1745c3b2500269de0335907b610e58))
- Updated dependencies:
- @plotday/twister@0.32.0

## 0.4.3

### Changed

- Updated dependencies:
- @plotday/twister@0.31.0

## 0.4.2

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))
- Updated dependencies:
- @plotday/twister@0.30.0

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
