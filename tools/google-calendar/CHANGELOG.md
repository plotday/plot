# @plotday/tool-google-calendar

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
- BREAKING: Agents and Tools now define a build() method to gain access to tools, which are then available via this.tools.
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

- Several instances of Agents and Tools missing the id argument ([#24](https://github.com/plotday/plot/pull/24) [`2d53d37`](https://github.com/plotday/plot/commit/2d53d3794419ee218976d6468319ae9129c93088))

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
