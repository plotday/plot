# @plotday/sdk

## 0.14.4

### Changed

- ActivityType.Task now has a default start of new Date() ([#34](https://github.com/plotday/plot/pull/34) [`d87d285`](https://github.com/plotday/plot/commit/d87d2850a2ac2c30bade586fc7f1654f37ff6101))

## 0.14.3

### Fixed

- Improve LLM guidance for activity creation ([#32](https://github.com/plotday/plot/pull/32) [`8f30644`](https://github.com/plotday/plot/commit/8f306448437af8bf5e20a5387594c0e655fcddf9))

## 0.14.2

### Added

- plot agent logs keepalive

## 0.14.1

### Changed

- plot agent logs takes id from package.json ([#29](https://github.com/plotday/plot/pull/29) [`9fefaca`](https://github.com/plotday/plot/commit/9fefaca426640fb84f7433471340d4f8ab4ba7b4))

## 0.14.0

### Added

- plot agent logs ([#27](https://github.com/plotday/plot/pull/27) [`8030c59`](https://github.com/plotday/plot/commit/8030c5951a72dc6326b06d798ea150843cdc0143))

### Fixed

- Improper use of tools in Agent and Tool base classes causing "Tool not found" errors ([#27](https://github.com/plotday/plot/pull/27) [`43ce7ab`](https://github.com/plotday/plot/commit/43ce7abdd97bea1fc8ee8569fd371f5f249c498c))

## 0.13.1

### Added

- Progress updates for agent generate and deploy ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))
- Install latest SDK package after generate ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))

### Fixed

- Several instances of Agents and Tools missing the id argument ([#24](https://github.com/plotday/plot/pull/24) [`2d53d37`](https://github.com/plotday/plot/commit/2d53d3794419ee218976d6468319ae9129c93088))

## 0.13.0

### Changed

- BREAKING: Add agent id to Agent and Tool constructors ([#22](https://github.com/plotday/plot/pull/22) [`34e7e43`](https://github.com/plotday/plot/commit/34e7e439d2d625e6749195623fe55389ff857e2a))
- Generate agent-guide.ts from AGENT.template.md ([#21](https://github.com/plotday/plot/pull/21) [`fee051d`](https://github.com/plotday/plot/commit/fee051dcb33729826cb31910e74fbdf8f57acdeb))

## 0.12.2

### Fixed

- Add lint and deploy scripts to generated package.json ([#19](https://github.com/plotday/plot/pull/19) [`0910b87`](https://github.com/plotday/plot/commit/0910b8770cd5cc404d5cedbe0e3380a624f7e348))

## 0.12.1

### Changed

- Export LLM docs ([#17](https://github.com/plotday/plot/pull/17) [`991afef`](https://github.com/plotday/plot/commit/991afeff288dfdaae4fb4f69a6471578149805aa))

## 0.12.0

### Changed

- BREAKING: Use ModelPreferences instead of an explicit AIModel in AI.prompt(). This supports BYOK and user preferences. ([#15](https://github.com/plotday/plot/pull/15) [`7cd2d7e`](https://github.com/plotday/plot/commit/7cd2d7e2f706abf464c2436076c30567e96a01f3))

## 0.11.1

### Changed

- Add instructions to AGENTS.md to avoid accidentally reprocessing agent-created activities ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))
- improved changelog format ([#9](https://github.com/plotday/plot/pull/9) [`ceecf33`](https://github.com/plotday/plot/commit/ceecf33))
- Generate a plotAgentId on "plot agent generate" if none specified ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

### Fixed

- Set displayName on plot agent generate ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

## 0.11.0

### Added

- plot agent generate command ([#7](https://github.com/plotday/plot/pull/7) [`1d809ec`](https://github.com/plotday/plot/commit/1d809ec778244921cda072eb3744f36e28b3c1b4))

## 0.10.2

### Added

- CLAUDE.md on "plot agent create" ([#5](https://github.com/plotday/plot/pull/5) [`0ac9a95`](https://github.com/plotday/plot/commit/0ac9a95953212ccd3abb3517e143e6a0957c061b14))

## 0.10.1

### Added

- plot create --name argument ([#3](https://github.com/plotday/plot/pull/3) [`61668e5`](https://github.com/plotday/plot/commit/61668e5fb6a640f0894f922bc852f2669dd4ea39))

## 0.10.0

### Added

- README.md and AGENTS.md on "plot agent create" ([#1](https://github.com/plotday/plot/pull/1) [`dce4f2f`](https://github.com/plotday/plot/commit/dce4f2ff3596bd9c73212c90a1cd49a7dac12f48))

### Changed

- Initial automated release setup ([#1](https://github.com/plotday/plot/pull/1) [`a00de4c`](https://github.com/plotday/plot/commit/a00de4c48e3ec1d6190235d1d38fd3e5d398d480))
