# Completion Navigator

A completion planning and navigation engine for World of Warcraft Retail.

Authored by **Travis A. Bryan I**. Owned, published and maintained by **Dam Beaver Studios, LLC**.

Most completion addons answer *what am I missing?* Completion Navigator is built to answer a different question:

> Given everything I have already completed, everything I can currently obtain, my current character, location, restrictions and prerequisites â€” **what should I do next?**

## What it does

Run `/cn setup` once, then type `/cn next` or click the minimap button. The addon scores every objective it knows to be currently actionable and tells you which one is worth doing, and why.

- **Explains itself.** Every recommendation comes with its reasons: *ready to turn in*, *in your current zone*, *a Paragon reward is waiting*, *unlocks four further quests*.
- **Navigates.** Sets a TomTom waypoint if you have TomTom, a Blizzard map pin if you don't, and falls back to the game's own quest tracking arrow when no coordinates exist.
- **Routes a zone.** `/cn zone` clusters everything obtainable on your current map and orders it nearest-first.
- **Knows your Warband.** Reputations, titles, professions and recipes are recorded per character where the game scopes them that way, so the addon can tell you when a different character is the right one for a job.
- **Explains blockers.** `/cn why <questID>` reports the first unmet prerequisite rather than just saying "not available", and names which data source produced the answer.
- **Learns from your play.** Every quest you accept or turn in has its name, zone, coordinates and level recorded permanently and account-wide. `/cn export` emits them as ready-to-paste `Data\Quests.lua` rows, so playing the game grows the shipped database.
- **Reads other addons rather than duplicating them.** AllTheThings and BtWQuests are consumed at runtime for quest names, coordinates and prerequisite chains when installed. Neither is required.

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
| Harvested data | Names, zones, coordinates and levels captured from your own play |

## Commands

`/cn` for status, `/cn help` for the full list, `/cn ui` for the window.

The window has eight tabs â€” Next, Now, Zone, Warband, Collections, Remaining, Scans, Settings â€” and everything the slash commands do is reachable by clicking. Keybindings live under Key Bindings â†’ AddOns.

## Known limitations

These are honest constraints, not oversights:

- **Recipes require the profession window.** `C_TradeSkillUI` only exposes a recipe list while that profession's window is open. The addon captures each one automatically the first time you open it and tells you which are still outstanding. It will not silently report zero.
- **No completion percentages for zones.** A percentage needs a trustworthy denominator, and the curated static database does not yet have zone coverage. The addon reports counts of what remains instead of inventing a number you would act on.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action.
- **Tooltip appearance lines only appear where an item has an appearance.** `PlayerHasTransmogByItemInfo` answers `false` for a stack of ore just as readily as for an unlearned tabard, so the lookup is gated on the item genuinely having an appearance source rather than stamping "not yet known" on every trade good in the game.
- **Recipe tooltips fall back to matching on name.** The trade skill API keys recipes by recipe ID while a vendor sells an item ID, and the two are not the same number. The ID lookup is tried first; when the name match is what fired, the tooltip says so rather than dressing it up as certainty.

## Optional integrations

**TomTom** for waypoints. Without it, navigation falls back to Blizzard map pins and the quest tracking arrow.

**AllTheThings** and **BtWQuests** are read at runtime for quest names, coordinates, source quests and prerequisite chains. Their internals are not published contracts, so every access is probed and wrapped: an update to either can make a provider go quiet, but cannot break Completion Navigator. `/cn providers` reports exactly what resolved.

None are required.

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
.\cn.ps1 release 0.9.0           # bump, commit, tag and push
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
