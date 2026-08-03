---
"@plotday/twister": patch
---

Changed: `AIModel.GEMINI_25_FLASH` is documented as withdrawn rather than
merely superseded, matching the other 2.x members.

Gemini availability is scoped to the calling project: this model still answers
for some long-lived keys while returning "no longer available to new users" for
others, so a model resolving for you is not evidence that it resolves for
everyone. It is remapped to a current model like the rest of the generation.
