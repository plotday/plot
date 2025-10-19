# @plotday/sdk

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
