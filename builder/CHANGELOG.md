# @plotday/agent

## 0.19.0

### Added

- Activity.threadRoot ([`bdbedca`](https://github.com/plotday/plot/commit/bdbedca3bd46a98a0892fa7d6710b1b2bfe82c5b))

### Changed

- BREAKING: Plot Activity intents now take an object that can include examples ([`431d8c7`](https://github.com/plotday/plot/commit/431d8c7c07965bbf893d1e19efce8007c4b786ff))

## 0.18.3

### Changed

- Update several references to the previous agent subcommand group ([`02936a6`](https://github.com/plotday/plot/commit/02936a671496c6124a31c1c54d69598276f4d8bb))

### Fixed

- build fixes ([`c3c83a7`](https://github.com/plotday/plot/commit/c3c83a7cddc72966209721fceec2eeb96c385dc2))

## 0.18.2

### Fixed

- README links ([#59](https://github.com/plotday/plot/pull/59) [`a1542bc`](https://github.com/plotday/plot/commit/a1542bc96a0d158b6080d5e44fc5eb1b9d87781e))

## 0.18.1

### Fixed

- README links ([#57](https://github.com/plotday/plot/pull/57) [`c475d13`](https://github.com/plotday/plot/commit/c475d13ae250f3b10f649f9bbc6515ba16bbbb49))

## 0.18.0

### Added

- Docs for build.plot.day ([#53](https://github.com/plotday/plot/pull/53) [`262d280`](https://github.com/plotday/plot/commit/262d2808858fdcb7a69f92d22286c435bb3f479f))

### Changed

- Renamed @plotday/sdk to @plotday/agent. ([#55](https://github.com/plotday/plot/pull/55) [`8106ba0`](https://github.com/plotday/plot/commit/8106ba0597966909dd223b800adf4f63b9c4b278))

## 0.17.0

### Added

- Improved stack traces ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

### Changed

- **BREAKING: Package renamed from @plotday/sdk to @plotday/agent**
  - Product name changed to "Plot Agent Builder"
  - Directory renamed from `public/sdk/` to `public/builder/`
  - Export `./sdk-docs` renamed to `./builder-docs`
  - Function `getSDKDocumentation()` renamed to `getBuilderDocumentation()`
  - See deprecation notice in @plotday/sdk@0.17.1
- BREAKING: Creating and updating Activity using the Plot tool now requires requesting permission in options ([#51](https://github.com/plotday/plot/pull/51) [`b3242e4`](https://github.com/plotday/plot/commit/b3242e4adecea87011379ac2dd58712dc91729d7))
- BREAKING: Agents and Tools now define a build() method to gain access to tools, which are then available via this.tools.
- BREAKING: Renamed callCallback, run, cancel, and cancelAll Agent/Tool functions ([#51](https://github.com/plotday/plot/pull/51) [`49b4dc9`](https://github.com/plotday/plot/commit/49b4dc94e08906a89799903610325c5fe7ebe10b))
- BREAKING: Improved callback ergonomics and types to use functions instead of strings ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

## 0.16.1

### Fixed

- Several references to call() renamed to callCallback() ([#49](https://github.com/plotday/plot/pull/49) [`2405588`](https://github.com/plotday/plot/commit/2405588f3c296b7e06057f11096e43771615a4b5))

## 0.16.0

### Changed

- BREAKING: Rename Agent.call() and Tool.call() to callCallback() to avoid confusion with JavaScript's Object.call(). ([#47](https://github.com/plotday/plot/pull/47) [`9ed2cf4`](https://github.com/plotday/plot/commit/9ed2cf4e019b5f7f0e04d35c383675ca4b6cd137))

## 0.15.0

### Changed

- BREAKING: Agents are now restricted to the http URLs they request via tools.enableInternet(). ([#45](https://github.com/plotday/plot/pull/45) [`0490f8e`](https://github.com/plotday/plot/commit/0490f8e801199893a971fdbfbead6ba2973a53c7))

## 0.14.8

### Added

- Documentation on generating agents from a spec ([#43](https://github.com/plotday/plot/pull/43) [`83ebb7e`](https://github.com/plotday/plot/commit/83ebb7ef96770e1d8ae42b62e8d48200424ee35e))

### Changed

- Improve developer docs in SDK readme ([#43](https://github.com/plotday/plot/pull/43) [`5ee6cab`](https://github.com/plotday/plot/commit/5ee6cab4a71584bdf7cbc176499c9b55e45f67da))

## 0.14.7

### Fixed

- Fix typo in readme ([#41](https://github.com/plotday/plot/pull/41) [`8054b77`](https://github.com/plotday/plot/commit/8054b777ac582ed972526a71548918e55d8c3de0))

## 0.14.6

### Changed

- Fix README link ([#39](https://github.com/plotday/plot/pull/39) [`6f06dce`](https://github.com/plotday/plot/commit/6f06dce1482f8d7af3c547bad2c0badf8d8e5f70))

## 0.14.5

### Changed

- Add login information to the README ([#37](https://github.com/plotday/plot/pull/37) [`f7439dc`](https://github.com/plotday/plot/commit/f7439dccdf05c3434a47800ffcd311d360d15cb3))

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
