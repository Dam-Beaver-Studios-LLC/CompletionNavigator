# Completion Navigator

Most completion addons answer **"what am I missing?"** Completion Navigator is built to answer a different question:

> Given everything I have already completed, everything I can currently obtain, my current character, location, restrictions and prerequisites — **what should I do next?**

Click the minimap button or type `/cn next`. The addon scores every objective it knows to be currently actionable, tells you which one to do, and explains its reasoning.

---

## What it does

**Recommends, and shows its work.** Every recommendation comes with reasons: *ready to turn in*, *in your current zone*, *a Paragon reward is waiting to be collected*, *4 of 5 criteria already done*, *account-wide, so any character's progress counts*. You can see why it chose what it chose, and disagree with it.

**Navigates.** Sets a TomTom waypoint if you use TomTom, a Blizzard map pin if you don't, and hands off to the game's own quest tracking arrow when no coordinates exist. Quest locations are resolved from four separate client sources, not one.

**Sweeps a zone.** `/cn zone` gathers everything obtainable on your current map and orders it nearest-first from where you are standing. Click any stop to route to it. It re-routes on every call, so the order stays accurate as you finish things.

**Understands your Warband.** Reputations, titles, professions and recipes are stored per character where the game scopes them that way. So the addon can tell you that a faction you are Honored with is one your alt is already Revered with, or which character already knows a recipe.

**Explains blockers.** `/cn why <questID>` reports the first unmet prerequisite — the specific quest, level or faction standing in the way — rather than just saying "not available".

**Ignores and defers.** Not interested in something? Ignore it permanently, or defer it for an hour, and it stops competing for your attention.

---

## Tracked

| Subsystem | What is recorded |
|---|---|
| **Quests** | Event-driven discovery, character vs account/Warband completion, coordinates, prerequisites |
| **Reputations** | Standing, Renown, Paragon, and crucially whether each is account-wide or character-specific |
| **Achievements** | Focused on near-completion — what sits within two criteria of finishing |
| **Battle pets** | Collected counts per species, wild and obtainable classification |
| **Mounts** | Collection state and faction locks |
| **Toys** | Collection state |
| **Appearances** | Transmog progress per category |
| **Titles** | Per character, so you can see which alt already earned one |
| **Professions & recipes** | Skill levels, and which of your characters knows which recipe |

---

## Interface

A minimap button and a five-tab window. Everything the slash commands do is reachable by clicking.

- **Next** — the recommendation, its reasoning, and Navigate / Defer / Ignore. Below it, the ranked alternatives; click any to inspect it.
- **Zone** — a live nearest-first sweep of your current map. Click a row to set a waypoint.
- **Collections** — account completion per category, collected over known.
- **Scans** — counts and one-click scans for each subsystem.
- **Settings** — priority mode, debug output, minimap button, window position.

Keybindings are under **Key Bindings → AddOns**: toggle the window, recommend next, navigate to the recommendation.

### Priority modes

`balanced`, `fastest`, `zone`, `quests`, `achievements`, `reputation`, `pets`, `professions`, `recipes`, `collections`, `legacy`. Cycle them from the Settings tab or with `/cn mode`.

---

## Commands

`/cn` for status, `/cn help` for the full list.

```
/cn next                 Recommend the next objective
/cn list [count]         Show the top scored objectives
/cn zone [stop]          Route this zone, or navigate to a stop
/cn go [questID]         Set a waypoint
/cn why <questID>        Explain why a quest is not available
/cn where <questID>      Show what location is known, and from which source
/cn rep <faction>        Standing, scope, and the best character for it
/cn paragon              Paragon rewards ready to collect
/cn closest [count]      Achievements nearest to completion
/cn pets | mounts | toys | appearances | titles | professions | recipes
```

---

## Known limitations

Stated plainly, because finding these out yourself feels like a bug:

- **Recipes need the profession window open once.** The client only exposes a recipe list while that profession's window is open. This is a restriction in the game, not a design choice. The addon captures each list automatically the first time you open a profession, and tells you which ones it is still waiting on rather than reporting zero.
- **No zone completion percentages.** A percentage needs a denominator you can trust, and the curated static database does not yet have zone coverage. The addon reports counts of what remains instead of showing a number you would act on and shouldn't.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done. A dedicated wardrobe addon is the right tool for per-item work.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action, and including them would bury everything else.
- **Warband comparisons need more than one character logged in.** The addon can only reason about characters it has seen.

---

## Optional integrations

**TomTom** for waypoints. Without it, navigation falls back to Blizzard map pins and the quest tracking arrow — everything still works.

Completion Navigator is built to consume data from **AllTheThings**, **BtWQuests** and **HandyNotes** where practical. None are required. It is a decision layer, not a replacement for their data.

---

## Status

Version 0.8.0. The subsystems above are implemented and tested; the curated static quest database is still small, which is what limits prerequisite forensics and zone percentages today. Expect changes before 1.0.

Bug reports and feature requests: [GitHub issues](https://github.com/Dam-Beaver-Studios-LLC/CompletionNavigator/issues), or email developer@dambeaverstudios.com.

---

## License

MIT. Copyright © 2026 **Dam Beaver Studios, LLC**. Authored by Travis A. Bryan I.

[Source on GitHub](https://github.com/Dam-Beaver-Studios-LLC/CompletionNavigator)
