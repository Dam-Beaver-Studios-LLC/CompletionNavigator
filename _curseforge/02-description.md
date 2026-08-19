# Completion Navigator

Most completion addons answer **"what am I missing?"** Completion Navigator is built to answer a different question:

> Given everything I have already completed, everything I can currently obtain, my current character, location, restrictions and prerequisites — **what should I do next?**

Run `/cn setup` once, then click the minimap button or type `/cn next`. The addon scores every objective it knows to be currently actionable, tells you which one to do, and explains its reasoning.

---

## What it does

**Recommends, and shows its work.** Every recommendation comes with reasons: *world quest, 45m left*, *rare is up right now*, *ready to turn in*, *a Paragon reward is waiting to be collected*, *4 of 5 criteria already done*, *your alt is better suited*. You can see why it chose what it chose, and disagree with it.

**Tells you what the Great Vault still needs.** Three rows, three thresholds each, and one item to choose at the end of the week. A row one activity short of a threshold with the reset approaching is the most actionable thing this addon can surface: *one more Heroic before Tuesday unlocks a second reward*. Capped rows are never suggested, because there is nothing left to earn from them.

**Knows what expires.** World quests with real time remaining, daily and weekly resets, active world events, and rares that are up *this minute*. Urgency is weighted heavily and scaled steeply: something with an hour left dominates the list, something with three days left barely registers.

**Finds rares and treasures that are actually up.** Driven by the client's live vignette data, not a static spawn list. A database tells you where a rare *can* spawn; a vignette tells you one is there now — which is the half that decides what you do next, and the half that doesn't go stale every patch.

**Navigates, on its own.** An arrow that points at your destination, turns as you turn, colours by whether you are actually walking toward it, and reports real distance in yards rather than map percentage. No other addon required. TomTom is still supported for anyone who prefers its arrow — `/cn nav tomtom` — and quest locations are resolved from four separate client sources, not one.

**Sweeps a zone.** `/cn zone` gathers everything obtainable on your current map and orders it into a real route — nearest-first, then improved to remove the doubling-back that a naive nearest-first ordering always leaves behind. Click any stop to route to it.

**Understands your Warband.** Reputations, titles, professions, recipes and currencies are stored per character where the game scopes them that way. `/cn warband` shows your roster and combined coverage; `/cn who rep <faction>` tells you which character should do a job. Objectives another character is better suited to rank lower, and say so.

**Explains why you aren't at 100%.** `/cn breakdown` reports what's left in every category *and why* — how many pets can never be collected again, how many mounts are locked to the other faction, how many titles a different character already holds — with a concrete next step on each line.

**Moves the waypoint on as you finish.** Turn on auto-advance and the waypoint follows you through the list: finish one thing, it points at the next. It re-points when the objective *changes*, not on a timer, so it never moves out from under you while you are walking to it. Off by default, because seizing the waypoint uninvited is rude.

**Tells you who sells it.** `/cn sells <item>` finds the vendor from your own recorded travels; `/cn tovendor` routes you there. Recipes you do not know that a recorded vendor stocks become recommendations with real coordinates.

**Answers in the tooltip.** Hover an item anywhere — a vendor list, a loot window, the auction house — and it tells you whether you have collected that toy, mount, pet or appearance, whether this character knows that recipe and which of your characters does, and which recorded vendor sells it. Items the addon knows nothing about get nothing added, so it stays out of the way.

**Works toward what you actually want.** `/cn goal mount 1234` pins a target. It becomes actionable even when nothing else would have surfaced it — an uncollected mount is not normally a next action, which is exactly why saying you want it has to mean something — and anything that leads to it ranks higher and says so. `/cn goals` reports what is known about reaching each one: the source, where it is, which of your characters is best placed, and the next concrete step. Where nothing is known, it says so rather than inventing a route.

**Shows you only what you care about.** `/cn show only quests` while levelling, `/cn show pets` to drop a category you have finished with, or the *Filter types* button on the Next tab. Filtering changes what gets recommended, never what gets tracked — everything still appears in Remaining and Collections.

**Settles per character where it matters.** Priority mode, auto-advance, the arrow and tooltips can each be set for one character instead of the whole account. A max-level main and a levelling alt want different answers.

**Lets you undo hiding things.** Ignore or defer anything you are not interested in, then `/cn hidden` to see the list and `/cn unhide` to bring it back. Deferrals expire on their own.

**Learns from your play.** Every quest you accept or turn in has its name, zone, coordinates and level recorded permanently. Every vendor you open records what it sells and where they stand. Every rare you see joins a spawn database. `/cn export` emits the quest data as ready-to-paste rows, so playing the game grows the database that ships to everyone.

---

## Tracked

| Subsystem | What is recorded |
|---|---|
| **Quests** | Event-driven discovery, character vs account/Warband completion, coordinates, prerequisites |
| **World quests** | Live availability with real expiry times |
| **Rares & treasures** | Live vignette detection, plus a spawn database built from your own play |
| **Reputations** | Standing, Renown, Paragon, and whether each is account-wide or character-specific |
| **Achievements** | Focused on near-completion — what sits within two criteria of finishing |
| **Battle pets** | Collected counts per species, wild and obtainable classification |
| **Mounts** | Collection state and faction locks |
| **Toys** | Collection state |
| **Appearances** | Transmog progress per category |
| **Titles** | Per character, so you can see which alt already earned one |
| **Professions & recipes** | Skill levels, and which of your characters knows which recipe |
| **Currencies** | Caps, and unfilled weekly earning that resets whether you use it or not |
| **Exploration** | Per-zone subzone discovery, naming the places you have not been |
| **Vendors** | What each merchant sells and where they stand, recorded as you shop |
| **Great Vault** | Every row's progress, thresholds, and what the next reward costs |

---

## Interface

A minimap button and a ten-tab window. Everything the slash commands do is reachable by clicking.

- **Next** — the recommendation, its reasoning, and Navigate / Defer / Ignore. Below it, the ranked alternatives; click any to inspect it.
- **Vault** — Great Vault rows, thresholds, and what unlocks the next reward.
- **Goals** — what you are working toward, and the known route to each.
- **Now** — world quests, live rares, capped currencies and unfilled weekly earning, in one clickable list.
- **Zone** — a live nearest-first sweep of your current map.
- **Warband** — your roster and what each character covers.
- **Collections** — account completion per category.
- **Remaining** — what is left everywhere, and why.
- **Scans** — counts and one-click scans for each subsystem.
- **Settings** — priority mode, auto-advance, tooltips, the navigation arrow, debug output, minimap button, and a one-click full scan.

Keybindings live under **Key Bindings → AddOns**.

### Priority modes

`balanced`, `fastest`, `zone`, `quests`, `achievements`, `reputation`, `pets`, `professions`, `recipes`, `collections`, `legacy`. Cycle from the Settings tab or with `/cn mode`.

---

## Commands

`/cn` for status, `/cn help` for all seventy-three.

```
/cn setup                Scan every subsystem once; run this first
/cn next                 Recommend the next objective
/cn vault                Great Vault progress and what unlocks the next reward
/cn arrow                Toggle the on-screen navigation arrow
/cn nav                  Choose the navigation provider
/cn here                 Where you are, and what is being tracked
/cn show [type]          Choose which kinds of objective get recommended
/cn perchar <setting>    Set something for this character only
/cn alerts               Announce rares that appear near you
/cn goal <type> <id>     Pin something to work toward
/cn goals                Your goals, and what is known about reaching them
/cn now                  Everything expiring soon
/cn rares                Rares and treasures up right now
/cn zone [stop]          Route this zone, or navigate to a stop
/cn breakdown [category] What is left in each category, and why
/cn warband              Your roster and combined coverage
/cn who <type> <id>      Which character should do this
/cn why <questID>        Why a quest is not available
/cn currencies           Caps and unfilled weekly earning
/cn paragon              Paragon rewards ready to collect
/cn closest              Achievements nearest to completion
/cn export               Emit harvested quest data
/cn auto                 Move the waypoint on as you finish things
/cn sells <item>         Which recorded vendor sells something
/cn hidden               Everything you ignored or deferred
/cn exploration          Zones with the least left to discover
/cn tooltips             Toggle addon lines on item and unit tooltips
/cn perf                 Provider timings, cache state, and any caps hit
```

---

## Known limitations

Stated plainly, because finding these out yourself feels like a bug:

- **No invented percentages.** Where the client cannot tell the addon how many things exist — quests, factions, recipes — it reports counts and says why there is no percentage. A number that looks authoritative and isn't is worse than no number.
- **Recipes need the profession window open once.** The client only exposes a recipe list while that window is open. The addon captures each one automatically the first time you open it, and tells you which are still outstanding rather than reporting zero.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action.
- **Warband comparisons need more than one character logged in.** The addon can only reason about characters it has seen.
- **Harvested prerequisites are evidence, not facts, and are labelled as such.** Quests completed shortly before another became available are recorded as possible prerequisites. One observation is the order you happened to play in, so nothing is acted on until **three different characters** show the same ordering — independent playthroughs don't agree by accident. Even then it is reported as *"probably needs another quest first"*, with the character count, never as the flat statement a curated prerequisite produces.
- **Only vendors you have opened are known.** Merchant inventories, like recipe lists, are readable only while the window is open. The addon builds its vendor database from your own shopping rather than shipping a list that goes stale.
- **Tooltip lines only appear where the addon actually knows something.** The appearance lookup is gated on the item having a real appearance source, because the client's "do you own this appearance" call answers *no* for a stack of ore just as readily as for an unlearned tabard. And because the trade skill API keys recipes by recipe ID while a vendor sells an item ID, a recipe tooltip that matched on name says so rather than dressing it up as certainty.
- **Collection providers contribute at most 60 candidates each.** There is no useful ranking among a thousand uncollected pets with no known location; they all score identically. The highest-valued are kept and `/cn perf` says exactly how many were dropped. Full counts live in `/cn breakdown` and the Collections tab, which read their stores directly.
- **Exploration is measured in subzones, not percent.** The map API reports which overlays you have revealed but never how many exist, so a true "percent explored" cannot be computed. Per-subzone criteria name the place you have not been, which is more useful anyway.

---

## Optional integrations

**LibDataBroker** is picked up automatically when a display addon supplies it — Titan Panel, ElvUI, ChocolateBar — showing the current recommendation in your bar.

**TomTom** is no longer needed. Navigation is native: the addon draws its own arrow and computes its own distances. TomTom remains supported for anyone who prefers it — `/cn nav tomtom` — and Blizzard map pins remain available as a third option.

**AllTheThings** and **BtWQuests** are read at runtime when installed, for quest names, coordinates, source quests and prerequisite chains. Their internals are not published contracts, so every access is probed and wrapped: an update to either can make a provider go quiet, but cannot break this addon. `/cn providers` shows exactly what resolved.

None are required. Completion Navigator is a decision layer, not a replacement for their data.

---

## Status

Version 0.22.0. All subsystems above are implemented and tested. The recommendation path is benchmarked against a retail-scale database rather than assumed: candidates are cached per provider and invalidated per event, so asking "what next?" costs a hundredth of a millisecond and hovering the minimap button does not cost you a frame. The curated static quest database is still small, which is what limits prerequisite forensics today — harvesting is designed to close that gap as people play.

Bug reports and feature requests: [GitHub issues](https://github.com/Dam-Beaver-Studios-LLC/CompletionNavigator/issues), or email developer@dambeaverstudios.com.

---

## License

MIT. Copyright © 2026 **Dam Beaver Studios, LLC**. Authored by Travis A. Bryan I.

[Source on GitHub](https://github.com/Dam-Beaver-Studios-LLC/CompletionNavigator)
