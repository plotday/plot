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
