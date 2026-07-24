---
"@plotday/twister": minor
---

Added: `canonicalizeEmail()` and `baseEmail()` for Gmail-scoped address
comparison, and `NewContact.nameTier` to declare how much authority an observed
display name carries.

Gmail ignores dots and `+tag` suffixes in the local part, so mail addressed to a
variant of a connected mailbox arrives in that same mailbox while headers
preserve whichever variant was used. Reply recipient resolution now compares
addresses through `baseEmail()`, and applies self-exclusion to
platform-resolved (curated) recipients as well as header-derived ones, so a
variant of your own address is no longer treated as a separate recipient. Only
`gmail.com` and `googlemail.com` are normalized; every other domain is
lowercased and otherwise untouched.

`nameTier` lets a connector say whether a name came from the contact's own
`From` header (`"self"`), from a third party's To/Cc (`"third-party"`, the
default), or from a directory import (`"directory"`).
