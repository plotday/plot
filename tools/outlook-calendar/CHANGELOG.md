# @plotday/tool-outlook-calendar

## 0.11.1

### Changed

- Removed debugging logging ([`d8f07cd`](https://github.com/plotday/plot/commit/d8f07cd82d7db91fbb99c3e6b6b751980566e9b7))

### Fixed

- Backdate cancellation notes for the date the event was cancelled ([`a38fa1c`](https://github.com/plotday/plot/commit/a38fa1c7b4c2de524a140b5d73e1acac3ff077a4))
- Always use event IDs rather than URL for source ([`b438aa3`](https://github.com/plotday/plot/commit/b438aa30240875c731d038df92e94f9435601637))

## 0.11.0

### Added

- Provide an activity preview ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))

### Changed

- BREAKING: Improve immutability of Activity.source and Note.key by using IDs rather than URLs ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))
- RSVP tags (attend, skip, undecided) are mutually exclusive per actor ([`b579997`](https://github.com/plotday/plot/commit/b5799978948ffffcffb3afb01ccf90997ee652b4))
- Explicitly set Activity.archived = false on initial syncs ([`6a0aec1`](https://github.com/plotday/plot/commit/6a0aec11ad1745c3b2500269de0335907b610e58))
- Updated dependencies:
- @plotday/twister@0.32.0

### Fixed

- Multiple calendar sync issues ([`b579997`](https://github.com/plotday/plot/commit/b5799978948ffffcffb3afb01ccf90997ee652b4))

## 0.10.1

### Fixed

- Limit size of batches ([`7e21de7`](https://github.com/plotday/plot/commit/7e21de7f5eb153e206fa7069bef60cbc25edc0d3))

## 0.10.0

### Changed

- Updated dependencies:
- @plotday/twister@0.31.0

### Fixed

- BREAKING: Fixed many issues with recurring activity, which required some changes to ActivityOccurrence ([`289cd83`](https://github.com/plotday/plot/commit/289cd83e292d1ebdd83b55990bffa33c9639000b))

## 0.9.2

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))
- Updated dependencies:
- @plotday/twister@0.30.0

## 0.9.1

### Changed

- Updated dependencies:
- @plotday/twister@0.29.0

## 0.9.0

### Changed

- Use Activity.source with canonical URLs for upserting ([`8053f7a`](https://github.com/plotday/plot/commit/8053f7a49ca0dc871bd4e1ef8edb4dd54f1abaef))
- Updated dependencies:
- @plotday/twister@0.28.0

## 0.8.0

### Added

- created_at for item's original creation time in the source system ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

### Changed

- BREAKING: Replace Activity.source for linking with source items with generated and stored UUIDs ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- BREAKING: Support either IDs or email for contact fields ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- Updated dependencies:
- @plotday/twister@0.27.0

### Fixed

- Set author and assignee ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

## 0.7.1

### Changed

- BREAKING: Moved unread flag for new activity and notes into those items ([`c72a690`](https://github.com/plotday/plot/commit/c72a6902bf9798b666abc8d9cc652a18973920f1))
- Updated dependencies:
- @plotday/twister@0.26.0

## 0.7.0

### Changed

- Breaking: Renamed Note noteType to contentType ([`844be3f`](https://github.com/plotday/plot/commit/844be3f7fcdcad7094734ce4a6d23594e3add068))
- Updated dependencies:
- @plotday/twister@0.25.0

## 0.6.0

### Added

- Activity.source upsert behaviour ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))

### Changed

- Updated dependencies:
- @plotday/twister@0.24.0

## 0.5.0

### Changed

- BREAKING: Note content field renamed for clarity ([`e66e968`](https://github.com/plotday/plot/commit/e66e968776c67afd376354317d94656b773b2d9f))
- Updated dependencies:
- @plotday/twister@0.23.0

## 0.4.0

### Changed

- BREAKING: Refactored Activity and Note types for clarity and type safety. ([#67](https://github.com/plotday/plot/pull/67) [`2aa5b8f`](https://github.com/plotday/plot/commit/2aa5b8fe57fe785bdc41f8347e62ba4beab0c3c5))
- Updated dependencies:
- @plotday/twister@0.22.0

## 0.3.1

### Changed

- Update to ActivityType.Action ([`dd13fed`](https://github.com/plotday/plot/commit/dd13fed684fb1499d92355f168a733b73738f1b6))
- Updated dependencies:
- @plotday/twister@0.21.0

## 0.3.0

### Added

- Coompleted base functionality. ([`c32b608`](https://github.com/plotday/plot/commit/c32b6086bfe429180d91696e3b4e334abc6dab7e))
- Conferencing links ([`e8349dd`](https://github.com/plotday/plot/commit/e8349ddb79f7afd914728e93366a1525086911b1))

### Changed

- Updated builder ([`d6f6a08`](https://github.com/plotday/plot/commit/d6f6a0804cb74b9647473d1ed8ebfaf24d36539c))
- Updated dependencies:
- @plotday/twister@0.20.0

## 0.2.3

### Changed

- Updated dependencies:
- @plotday/agent@0.19.0

## 0.2.2

### Changed

- Updated dependencies:
- @plotday/agent@0.18.3

### Fixed

- build fixes ([`c3c83a7`](https://github.com/plotday/plot/commit/c3c83a7cddc72966209721fceec2eeb96c385dc2))

## 0.2.1

### Changed

- Updated to @plotday/agent ([#55](https://github.com/plotday/plot/pull/55) [`8106ba0`](https://github.com/plotday/plot/commit/8106ba0597966909dd223b800adf4f63b9c4b278))
- Updated dependencies:
- @plotday/agent@0.18.0

## 0.2.0

### Changed

- BREAKING: Creating and updating Activity using the Plot tool now requires requesting permission in options ([#51](https://github.com/plotday/plot/pull/51) [`b3242e4`](https://github.com/plotday/plot/commit/b3242e4adecea87011379ac2dd58712dc91729d7))
- BREAKING: Twists and Tools now define a build() method to gain access to tools, which are then available via this.tools.
- BREAKING: Improved callback ergonomics and types to use functions instead of strings ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))
- Update for new callback function names ([#51](https://github.com/plotday/plot/pull/51) [`49b4dc9`](https://github.com/plotday/plot/commit/49b4dc94e08906a89799903610325c5fe7ebe10b))
- Updated dependencies:
- @plotday/agent@0.17.0

## 0.1.10

### Changed

- Updated dependencies:
- @plotday/agent@0.16.1

### Fixed

- Several references to call() renamed to callCallback() ([#49](https://github.com/plotday/plot/pull/49) [`2405588`](https://github.com/plotday/plot/commit/2405588f3c296b7e06057f11096e43771615a4b5))

## 0.1.9

### Changed

- Updated dependencies:
- @plotday/agent@0.16.0

## 0.1.8

### Changed

- Updated dependencies:
- @plotday/agent@0.15.0

## 0.1.7

### Changed

- Remove defunct static tool id ([#27](https://github.com/plotday/plot/pull/27) [`97b3195`](https://github.com/plotday/plot/commit/97b3195abaffb6886fda90ce511de796fbd34aac))
- Updated dependencies:
- @plotday/agent@0.14.0

## 0.1.6

### Changed

- Updated dependencies:
- @plotday/agent@0.13.1

### Fixed

- Several instances of Twists and Tools missing the id argument ([#24](https://github.com/plotday/plot/pull/24) [`2d53d37`](https://github.com/plotday/plot/commit/2d53d3794419ee218976d6468319ae9129c93088))

## 0.1.5

### Changed

- Updated dependencies:
- @plotday/agent@0.13.0

## 0.1.4

### Changed

- Updated dependencies:
- @plotday/agent@0.12.0

## 0.1.3

### Changed

- improved changelog format ([#9](https://github.com/plotday/plot/pull/9) [`ceecf33`](https://github.com/plotday/plot/commit/ceecf33))
- Updated dependencies:
- @plotday/agent@0.11.1

## 0.1.2

### Changed

- Updated dependencies [[`1d809ec`](https://github.com/plotday/plot/commit/1d809ec778244921cda072eb3744f36e28b3c1b4)]:
  - @plotday/agent@0.11.0

## 0.1.1

### Added

- Initial automated release setup ([#1](https://github.com/plotday/plot/pull/1) [`a00de4c`](https://github.com/plotday/plot/commit/a00de4c48e3ec1d6190235d1d38fd3e5d398d480))

### Changed

- Updated dependencies [[`a00de4c`](https://github.com/plotday/plot/commit/a00de4c48e3ec1d6190235d1d38fd3e5d398d480), [`dce4f2f`](https://github.com/plotday/plot/commit/dce4f2ff3596bd9c73212c90a1cd49a7dac12f48)]:
  - @plotday/agent@0.10.0
