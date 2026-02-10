# @plotday/tool-google-contacts

## 0.5.1

### Changed

- Updated dependencies:
- @plotday/twister@0.34.0

## 0.5.0

### Changed

- BREAKING: All integrations are now individual, always acting on behalf of a particular user. ([`2208632`](https://github.com/plotday/plot/commit/22086320eb79c3cbe6c95aeaeb34472e4c3d7b50))
- Updated dependencies:
- @plotday/twister@0.33.0

## 0.4.9

### Changed

- Removed debugging logging ([`d8f07cd`](https://github.com/plotday/plot/commit/d8f07cd82d7db91fbb99c3e6b6b751980566e9b7))

## 0.4.8

### Changed

- Updated dependencies:
- @plotday/twister@0.32.0

## 0.4.7

### Changed

- Updated dependencies:
- @plotday/twister@0.31.0

## 0.4.6

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))
- Updated dependencies:
- @plotday/twister@0.30.0

## 0.4.5

### Changed

- Updated dependencies:
- @plotday/twister@0.29.0

### Fixed

- Authorizing Google Contacts sync from the Google Calendar tool ([`a8ec500`](https://github.com/plotday/plot/commit/a8ec500e69b316e6c086626d1bd5208d71c83077))

## 0.4.4

### Changed

- Updated dependencies:
- @plotday/twister@0.28.0

## 0.4.3

### Changed

- Updated dependencies:
- @plotday/twister@0.27.0

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

## 0.2.6

### Changed

- Updated dependencies:
- @plotday/twister@0.22.0

## 0.2.5

### Changed

- Updated dependencies:
- @plotday/twister@0.21.0

## 0.2.4

### Changed

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
