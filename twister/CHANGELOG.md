# @plotday/twister

## 0.31.2

### Added

- Priority.color for setting the priority theme color ([`bdb98a5`](https://github.com/plotday/plot/commit/bdb98a50860da15a7e2156cf2ac07236f5016fc7))

## 0.31.1

### Added

- Activity.kind to indicate the icon that should be used to depict the activity ([`3c8f841`](https://github.com/plotday/plot/commit/3c8f841b5c881fc42e0acadcc1d54859354a7815))

## 0.31.0

### Changed

- BREAKING: Return only the id when creating/upserting to increase performance ([`9428f5b`](https://github.com/plotday/plot/commit/9428f5bdca0221984836a67f902c8e7e691223b8))

### Fixed

- BREAKING: Fixed many issues with recurring activity, which required some changes to ActivityOccurrence ([`289cd83`](https://github.com/plotday/plot/commit/289cd83e292d1ebdd83b55990bffa33c9639000b))
- Clearer error when the server can't be reached during deploy ([`53585ca`](https://github.com/plotday/plot/commit/53585cac03d26ff0500dc227c81e349a3986380d))

## 0.30.0

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))

## 0.29.0

### Added

- Support for more serializable types, especially Date ([`1623e18`](https://github.com/plotday/plot/commit/1623e18a97afa97bb28f0c8497eabca1805d78a9))
- archived field on Priority, Activity, and Note ([`6685c33`](https://github.com/plotday/plot/commit/6685c330c617046b213524b058330745d2fee7a9))

### Changed

- BREAKING: Minor type and signature changes in preparation for the stable 1.0 interface ([`6685c33`](https://github.com/plotday/plot/commit/6685c330c617046b213524b058330745d2fee7a9))

## 0.28.0

### Added

- Activity.source and Note.key for upserts ([`8053f7a`](https://github.com/plotday/plot/commit/8053f7a49ca0dc871bd4e1ef8edb4dd54f1abaef))

## 0.27.0

### Added

- created_at for item's original creation time in the source system ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

### Changed

- BREAKING: Replace Activity.source for linking with source items with generated and stored UUIDs ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- BREAKING: Support either IDs or email for contact fields ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))

## 0.26.0

### Added

- Note creation callback for new notes added to activities created by a twist ([`b0c756d`](https://github.com/plotday/plot/commit/b0c756ddd3b2f334f1a19248dbe9279b2777a5ec))
- activity.update field in the Plot tool for seeing only what changed ([`b0c756d`](https://github.com/plotday/plot/commit/b0c756ddd3b2f334f1a19248dbe9279b2777a5ec))

### Changed

- BREAKING: Moved unread flag for new activity and notes into those items ([`c72a690`](https://github.com/plotday/plot/commit/c72a6902bf9798b666abc8d9cc652a18973920f1))

## 0.25.1

### Added

- WebhookRequest.rawBody for signature verification ([`804d217`](https://github.com/plotday/plot/commit/804d21783512fd023940a6b281330fada22cf7bb))

### Changed

- BREAKING: Tightened callback types to catch mismatched arguments ([`9293f29`](https://github.com/plotday/plot/commit/9293f290f727cc76a7eb6fdcb1460a100f5117ef))

## 0.25.0

### Changed

- Breaking: Renamed Note noteType to contentType ([`844be3f`](https://github.com/plotday/plot/commit/844be3f7fcdcad7094734ce4a6d23594e3add068))

## 0.24.0

### Added

- Create activities with unread: false ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))
- Activity.source upsert behaviour ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))

### Changed

- BREAKING: Remove Attachment and Link tags, as they are computed and read-only ([`4d32630`](https://github.com/plotday/plot/commit/4d32630101a8a0f4f7768318a9eeb85bdfe24127))
- Tightened tag types. ([`4c73a88`](https://github.com/plotday/plot/commit/4c73a88c94fd5e75f35ab707b6975638296110d3))

## 0.23.0

### Added

- Update Activity assignee ([`f0cda95`](https://github.com/plotday/plot/commit/f0cda95e9bda28d503557ff2149da47ebbb27f14))

### Changed

- BREAKING: Note content field renamed for clarity ([`e66e968`](https://github.com/plotday/plot/commit/e66e968776c67afd376354317d94656b773b2d9f))

## 0.22.0

### Changed

- BREAKING: Refactored Activity and Note types for clarity and type safety. ([#67](https://github.com/plotday/plot/pull/67) [`2aa5b8f`](https://github.com/plotday/plot/commit/2aa5b8fe57fe785bdc41f8347e62ba4beab0c3c5))

## 0.21.0

### Changed

- BREAKING: ActivityType.Task to ActivityType.Action to match product language ([`dd13fed`](https://github.com/plotday/plot/commit/dd13fed684fb1499d92355f168a733b73738f1b6))

## 0.20.0

### Added

- Hints for routing new Activity into the correct Priority ([`765487b`](https://github.com/plotday/plot/commit/765487b0ea2acadf8ce47e887f4494548dfdca83))
- Conferencing links ([`e8349dd`](https://github.com/plotday/plot/commit/e8349ddb79f7afd914728e93366a1525086911b1))
- Common Messaging interface
- Notion, Slack, Atlassian, Linear, Monday, GitHub, Asana, and HubSpot integrations ([`bc6eac1`](https://github.com/plotday/plot/commit/bc6eac16283f3fbfbd92cdd0f041e1adde3bbff3))
- Plot.getActors() to retrieve name, email, and type for people and twists.
- Slack and Gmail webhook support ([`4e262a0`](https://github.com/plotday/plot/commit/4e262a04cd506cb679840fc1ae83fef3130e142e))
- Attend, Skip, Undecided tags ([`34a5860`](https://github.com/plotday/plot/commit/34a5860c389debc30c876fea933feb3ba87b719b))
- NoteType with support for HTML and text notes in addition to the default (Markdown) ([`765487b`](https://github.com/plotday/plot/commit/765487b0ea2acadf8ce47e887f4494548dfdca83))

### Changed

- BREAKING: Renamed to @plotday/twister ([#65](https://github.com/plotday/plot/pull/65) [`ba7469d`](https://github.com/plotday/plot/commit/ba7469d22d8412a6ff4f17ee7d5d9c3b18ec59e7))

### Fixed

- login path error ([`cd8c1de`](https://github.com/plotday/plot/commit/cd8c1de84c07957c6189babd900479a1c7cd582a))

## 0.19.1

### Added

- Text and HTML (in addition to Markdown) note types ([`9516790`](https://github.com/plotday/plot/commit/95167908d414db8d92eddea83e85948482917d3d))

## 0.19.0

### Added

- Activity.threadRoot ([`bdbedca`](https://github.com/plotday/plot/commit/bdbedca3bd46a98a0892fa7d6710b1b2bfe82c5b))

### Changed

- BREAKING: Plot Activity intents now take an object that can include examples ([`431d8c7`](https://github.com/plotday/plot/commit/431d8c7c07965bbf893d1e19efce8007c4b786ff))

## 0.18.3

### Changed

- Update several references to the previous twist subcommand group ([`02936a6`](https://github.com/plotday/plot/commit/02936a671496c6124a31c1c54d69598276f4d8bb))

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

- Renamed @plotday/sdk to @plotday/twister. ([#55](https://github.com/plotday/plot/pull/55) [`8106ba0`](https://github.com/plotday/plot/commit/8106ba0597966909dd223b800adf4f63b9c4b278))

## 0.17.0

### Added

- Improved stack traces ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

### Changed

- **BREAKING: Package renamed from @plotday/sdk to @plotday/twister**
  - Product name changed to "Plot twist Builder"
  - Directory renamed from `public/sdk/` to `public/builder/`
  - Export `./sdk-docs` renamed to `./builder-docs`
  - Function `getSDKDocumentation()` renamed to `getBuilderDocumentation()`
  - See deprecation notice in @plotday/sdk@0.17.1
- BREAKING: Creating and updating Activity using the Plot tool now requires requesting permission in options ([#51](https://github.com/plotday/plot/pull/51) [`b3242e4`](https://github.com/plotday/plot/commit/b3242e4adecea87011379ac2dd58712dc91729d7))
- BREAKING: Twists and Tools now define a build() method to gain access to tools, which are then available via this.tools.
- BREAKING: Renamed callCallback, run, cancel, and cancelAll twist/Tool functions ([#51](https://github.com/plotday/plot/pull/51) [`49b4dc9`](https://github.com/plotday/plot/commit/49b4dc94e08906a89799903610325c5fe7ebe10b))
- BREAKING: Improved callback ergonomics and types to use functions instead of strings ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

## 0.16.1

### Fixed

- Several references to call() renamed to callCallback() ([#49](https://github.com/plotday/plot/pull/49) [`2405588`](https://github.com/plotday/plot/commit/2405588f3c296b7e06057f11096e43771615a4b5))

## 0.16.0

### Changed

- BREAKING: Rename twist.call() and Tool.call() to callCallback() to avoid confusion with JavaScript's Object.call(). ([#47](https://github.com/plotday/plot/pull/47) [`9ed2cf4`](https://github.com/plotday/plot/commit/9ed2cf4e019b5f7f0e04d35c383675ca4b6cd137))

## 0.15.0

### Changed

- BREAKING: Twists are now restricted to the http URLs they request via tools.enableInternet(). ([#45](https://github.com/plotday/plot/pull/45) [`0490f8e`](https://github.com/plotday/plot/commit/0490f8e801199893a971fdbfbead6ba2973a53c7))

## 0.14.8

### Added

- Documentation on generating twists from a spec ([#43](https://github.com/plotday/plot/pull/43) [`83ebb7e`](https://github.com/plotday/plot/commit/83ebb7ef96770e1d8ae42b62e8d48200424ee35e))

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

- ActivityType.Action now has a default start of new Date() ([#34](https://github.com/plotday/plot/pull/34) [`d87d285`](https://github.com/plotday/plot/commit/d87d2850a2ac2c30bade586fc7f1654f37ff6101))

## 0.14.3

### Fixed

- Improve LLM guidance for activity creation ([#32](https://github.com/plotday/plot/pull/32) [`8f30644`](https://github.com/plotday/plot/commit/8f306448437af8bf5e20a5387594c0e655fcddf9))

## 0.14.2

### Added

- plot twist logs keepalive

## 0.14.1

### Changed

- plot twist logs takes id from package.json ([#29](https://github.com/plotday/plot/pull/29) [`9fefaca`](https://github.com/plotday/plot/commit/9fefaca426640fb84f7433471340d4f8ab4ba7b4))

## 0.14.0

### Added

- plot twist logs ([#27](https://github.com/plotday/plot/pull/27) [`8030c59`](https://github.com/plotday/plot/commit/8030c5951a72dc6326b06d798ea150843cdc0143))

### Fixed

- Improper use of tools in twist and Tool base classes causing "Tool not found" errors ([#27](https://github.com/plotday/plot/pull/27) [`43ce7ab`](https://github.com/plotday/plot/commit/43ce7abdd97bea1fc8ee8569fd371f5f249c498c))

## 0.13.1

### Added

- Progress updates for twist generate and deploy ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))
- Install latest SDK package after generate ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))

### Fixed

- Several instances of Twists and Tools missing the id argument ([#24](https://github.com/plotday/plot/pull/24) [`2d53d37`](https://github.com/plotday/plot/commit/2d53d3794419ee218976d6468319ae9129c93088))

## 0.13.0

### Changed

- BREAKING: Add twist id to twist and Tool constructors ([#22](https://github.com/plotday/plot/pull/22) [`34e7e43`](https://github.com/plotday/plot/commit/34e7e439d2d625e6749195623fe55389ff857e2a))
- Generate twist-guide.ts from twist.template.md ([#21](https://github.com/plotday/plot/pull/21) [`fee051d`](https://github.com/plotday/plot/commit/fee051dcb33729826cb31910e74fbdf8f57acdeb))

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

- Add instructions to AGENTS.md to avoid accidentally reprocessing twist-created activities ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))
- improved changelog format ([#9](https://github.com/plotday/plot/pull/9) [`ceecf33`](https://github.com/plotday/plot/commit/ceecf33))
- Generate a plotTwistId on "plot twist generate" if none specified ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

### Fixed

- Set displayName on plot twist generate ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

## 0.11.0

### Added

- plot twist generate command ([#7](https://github.com/plotday/plot/pull/7) [`1d809ec`](https://github.com/plotday/plot/commit/1d809ec778244921cda072eb3744f36e28b3c1b4))

## 0.10.2

### Added

- CLAUDE.md on "plot twist create" ([#5](https://github.com/plotday/plot/pull/5) [`0ac9a95`](https://github.com/plotday/plot/commit/0ac9a95953212ccd3abb3517e143e6a0957c061b14))

## 0.10.1

### Added

- plot create --name argument ([#3](https://github.com/plotday/plot/pull/3) [`61668e5`](https://github.com/plotday/plot/commit/61668e5fb6a640f0894f922bc852f2669dd4ea39))

## 0.10.0

### Added

- README.md and AGENTS.md on "plot twist create" ([#1](https://github.com/plotday/plot/pull/1) [`dce4f2f`](https://github.com/plotday/plot/commit/dce4f2ff3596bd9c73212c90a1cd49a7dac12f48))

### Changed

- Initial automated release setup ([#1](https://github.com/plotday/plot/pull/1) [`a00de4c`](https://github.com/plotday/plot/commit/a00de4c48e3ec1d6190235d1d38fd3e5d398d480))
