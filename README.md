# Completion Navigator

A completion planning and navigation engine for World of Warcraft Retail.

Authored by **Travis A. Bryan I**. Owned, published and maintained by **Dam Beaver Studios, LLC**.

Most completion addons answer *what am I missing?* Completion Navigator is built to answer a different question:

> Given everything I have already completed, everything I can currently obtain, my current character, location, restrictions and prerequisites â€” **what should I do next?**

## What it does

Type `/cn next` or click the minimap button. The addon scores every objective it knows to be currently actionable and tells you which one is worth doing, and why.

- **Explains itself.** Every recommendation comes with its reasons: *ready to turn in*, *in your current zone*, *a Paragon reward is waiting*, *unlocks four further quests*.
- **Navigates.** Sets a TomTom waypoint if you have TomTom, a Blizzard map pin if you don't, and falls back to the game's own quest tracking arrow when no coordinates exist.
- **Routes a zone.** `/cn zone` clusters everything obtainable on your current map and orders it nearest-first.
- **Knows your Warband.** Reputations, titles, professions and recipes are recorded per character where the game scopes them that way, so the addon can tell you when a different character is the right one for a job.
- **Explains blockers.** `/cn why <questID>` reports the first unmet prerequisite rather than just saying "not available".

## Tracked

| Subsystem | Notes |
|---|---|
| Quests | Event-driven discovery, account vs character completion, coordinates from four client sources |
| Reputations | Standing, Renown, Paragon; account-wide vs character-specific scope |
| Achievements | Focused on near-completion â€” what is within two criteria of finishing |
| Battle pets | Collected counts, wild/obtainable classification |
| Mounts | Faction-lock detection |
| Toys | Collection state |
| Appearances | Transmog progress per category |
| Titles | Per character, so you can see which alt has one |
| Professions & recipes | Skill levels and which characters know which recipe |

## Commands

`/cn` for status, `/cn help` for the full list, `/cn ui` for the window.

The window has five tabs â€” Next, Zone, Collections, Scans, Settings â€” and everything the slash commands do is reachable by clicking. Keybindings live under Key Bindings â†’ AddOns.

## Known limitations

These are honest constraints, not oversights:

- **Recipes require the profession window.** `C_TradeSkillUI` only exposes a recipe list while that profession's window is open. The addon captures each one automatically the first time you open it and tells you which are still outstanding. It will not silently report zero.
- **No completion percentages for zones.** A percentage needs a trustworthy denominator, and the curated static database does not yet have zone coverage. The addon reports counts of what remains instead of inventing a number you would act on.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action.

## Optional integrations

TomTom (waypoints), and the addon is built to consume data from AllTheThings, BtWQuests and HandyNotes where practical. None are required.

## Development

The addon is managed by `cn.ps1`, a PowerShell toolkit that carries the whole source tree inside it.

```powershell
.\cn.ps1 init                    # scaffold the modular tree
.\cn.ps1 new module Pets         # create a module and sync the .toc
.\cn.ps1 cmd pets -Module Pets   # register a slash command stub
.\cn.ps1 event NEW_PET_ADDED -Module Pets
.\cn.ps1 sync                    # rewrite the .toc load order from disk
.\cn.ps1 check                   # validate .toc, BOMs, duplicates, Lua syntax
.\cn.ps1 package                 # build a distributable zip
.\cn.ps1 release 0.8.0           # bump, commit, tag and push
```

Architecture is registry-based: `CN:RegisterCommand{}`, `CN:RegisterEvent()`, `CN:RegisterModule()`, `CN.RegisterCandidateProvider()`, `CN.RegisterEligibilityChecker()`, `CN.UI.RegisterTab{}`. Adding a subsystem never means editing a dispatcher. All client API calls live in `Providers/Blizzard.lua`, so a patch break is a one-file fix.

Load order is enforced by `sync`: fixed root order, then `Providers\`, then `Data\`, then `Modules\`.

## Contact

Bug reports and feature requests: open an issue on the repository, or email
developer@dambeaverstudios.com.

## License

Released under the MIT License.

Copyright (c) 2026 **Dam Beaver Studios, LLC**. All right, title and interest in
this work â€” including the copyright, the project, and its distribution channels â€”
is held and controlled by Dam Beaver Studios, LLC. Authorship credit: Travis A. Bryan I.

See [LICENSE](LICENSE).
