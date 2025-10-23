---
"@plotday/tool-outlook-calendar": minor
"@plotday/tool-google-calendar": minor
"@plotday/tool-google-contacts": minor
"@plotday/sdk": minor
---

Changed: BREAKING: Agents and Tools now use a static Init() function to gain access to tools, which are then available via this.tools.
Changed: BREAKING: Webhook functionality has been moved into the Network tool.
Changed: BREAKING: CallbackTool renamed Callbacks.
Changed: BREAKING: Auth renamed Integrations.
Changed: BREAKING: Run renamed Tasks.
