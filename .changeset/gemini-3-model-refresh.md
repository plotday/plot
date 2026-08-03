---
"@plotday/twister": minor
---

Added: `AIModel.GEMINI_31_PRO`, `AIModel.GEMINI_35_FLASH`, and
`AIModel.GEMINI_35_FLASH_LITE` for the current generation of Gemini models.

Deprecated: the `GEMINI_25_*` and `GEMINI_20_*` members. Google has withdrawn
most of that generation, so a `hint` naming one of them previously failed the
whole `ai.prompt()` call. The members still exist and still compile, and a hint
naming a withdrawn model is now served by its current equivalent instead of
erroring — but new code should name a 3.x member.

The speed/cost tiers that `ai.prompt()` resolves without a hint have also moved
onto current models, so `{ speed: "capable", cost: "high" }` and the other tiers
that previously mapped to withdrawn Gemini models work again.

Note that Gemini availability is scoped to the calling project: an id can keep
answering for a long-lived key while returning "no longer available to new
users" elsewhere. A model resolving for you is not evidence that it resolves
for everyone, which is why the 2.x members are all treated as withdrawn here.
