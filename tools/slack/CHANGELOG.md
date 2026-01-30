# @plotday/tool-slack

## 0.7.1

### Changed

- Removed debugging logging ([`d8f07cd`](https://github.com/plotday/plot/commit/d8f07cd82d7db91fbb99c3e6b6b751980566e9b7))

## 0.7.0

### Added

- Provide an activity preview ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))

### Changed

- BREAKING: Improve immutability of Activity.source and Note.key by using IDs rather than URLs ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))
- Updated dependencies:
- @plotday/twister@0.32.0

## 0.6.3

### Changed

- Use new return values from create functions ([`9428f5b`](https://github.com/plotday/plot/commit/9428f5bdca0221984836a67f902c8e7e691223b8))
- Updated dependencies:
- @plotday/twister@0.31.0

## 0.6.2

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))
- Updated dependencies:
- @plotday/twister@0.30.0

## 0.6.1

### Changed

- Updated dependencies:
- @plotday/twister@0.29.0

## 0.6.0

### Changed

- Use Activity.source with canonical URLs for upserting ([`8053f7a`](https://github.com/plotday/plot/commit/8053f7a49ca0dc871bd4e1ef8edb4dd54f1abaef))
- Updated dependencies:
- @plotday/twister@0.28.0

## 0.5.0

### Added

- created_at for item's original creation time in the source system ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

### Changed

- BREAKING: Replace Activity.source for linking with source items with generated and stored UUIDs ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- BREAKING: Support either IDs or email for contact fields ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- Updated dependencies:
- @plotday/twister@0.27.0

### Fixed

- Set author and assignee ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

## 0.4.2

### Changed

- Updated dependencies:
- @plotday/twister@0.26.0

## 0.4.1

### Changed

- Updated dependencies:
- @plotday/twister@0.25.0

## 0.4.0

### Added

- Activity.source upsert behaviour ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))

### Changed

- Updated dependencies:
- @plotday/twister@0.24.0

## 0.3.0

### Changed

- BREAKING: Note content field renamed for clarity ([`e66e968`](https://github.com/plotday/plot/commit/e66e968776c67afd376354317d94656b773b2d9f))
- Updated dependencies:
- @plotday/twister@0.23.0

## 0.2.0

### Changed

- BREAKING: Refactored Activity and Note types for clarity and type safety. ([#67](https://github.com/plotday/plot/pull/67) [`2aa5b8f`](https://github.com/plotday/plot/commit/2aa5b8fe57fe785bdc41f8347e62ba4beab0c3c5))
- Updated dependencies:
- @plotday/twister@0.22.0

## 0.1.2

### Changed

- Update to ActivityType.Action ([`dd13fed`](https://github.com/plotday/plot/commit/dd13fed684fb1499d92355f168a733b73738f1b6))
- Updated dependencies:
- @plotday/twister@0.21.0

## 0.1.1

### Changed

- Updated dependencies:
- @plotday/twister@0.20.0
