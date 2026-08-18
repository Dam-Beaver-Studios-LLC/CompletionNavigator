# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

## [0.16.0]

Measured, not guessed. A benchmark against a retail-scale database -- 1800
pets, 3000 achievements, 500 factions, 2500 recipes -- drove every change
below. Numbers are from that benchmark.

### Changed

- **The ranked list is cached.** 0.15.0 cached the candidate list but still
  re-scored and re-sorted every candidate on every call, so `/cn next` cost
  **14.8ms** even with a warm cache. It is now **0.01ms**. A frame at 60fps is
  16ms, which means the minimap tooltip added in 0.15.0 was dropping a frame
  every time you hovered it. That was a regression I shipped, and this is the
  fix.
- **Invalidation is per provider.** Each provider declares which events can
  make it stale, so learning a mount no longer rebuilds the achievement
  candidates. `NEW_MOUNT_ADDED` went from **18.3ms to 0.02ms**;
  `UPDATE_FACTION` from **6.6ms to 0.01ms**; `CRITERIA_UPDATE` from **8.5ms to
  1.1ms**.
- **Chatty events are throttled at the cache, not just at the scan.**
  `CRITERIA_UPDATE` and `UPDATE_FACTION` fire many times a second during normal
  play. Providers subscribed to them rebuild at most once every five seconds.
- **Providers that enumerate a whole collection are capped.** Emitting 1200
  uncollected pets so that one can rank first is waste, and every one of them
  scores identically. The highest-valued 60 per provider are kept, chosen by
  counting rather than sorting, with ties broken by ID so the list does not
  reshuffle. Candidate count dropped from **3211 to 189**. `/cn perf` reports
  exactly what was dropped -- a cap nobody can see reads as "that was
  everything".
- **Ignore and defer lookups short-circuit when nothing is hidden.** They were
  building a `TYPE:id` string per call, several thousand times per rebuild,
  to look up nothing. **12ms to 3.5ms** per 10,000 pairs.
- A full rebuild is down from **45.2ms to 16.5ms**, and now only happens on a
  scan or a login rather than on every event.
- Ranking sorts a copy. Zone routing walks the candidate list, and having it
  reordered underneath as a side effect of somebody asking for a
  recommendation was a bug waiting to be found.

### Fixed

- **`release` no longer half-applies.** It bumped the version files and *then*
  checked the changelog, so a stale `CHANGELOG.md` left the tree claiming a
  version whose source had never been scaffolded -- and said so in a yellow
  warning that scrolled past. Every refusal now happens before anything is
  written, and says "nothing has been changed" out loud.
- **A failing `check` aborts the release** instead of printing above it and
  carrying on.
- **`cn.ps1` stamps the version it carries.** A `cn.ps1` older than the tree
  used to scaffold a previous release over the top and report success. `check`
  now fails on it, and `release` refuses a version this file does not carry.
- **An existing tag is detected** rather than letting `git tag` fail into the
  middle of a release.
- **Push failures are caught.** `git push` and `git push --tags` are checked,
  so a tag that never reached the remote is reported rather than assumed.
- git's stderr is rendered as its message rather than
  `System.Management.Automation.RemoteException`.
- **`init` scaffolds `Media\Logo.tga`.** A fresh scaffold previously failed its
  own `check` on a missing IconTexture, which then blocked `release`.
- Rescanning a store no longer invalidates every provider -- only the ones that
  read it. Mounts, toys, appearances and titles feed no candidate provider at
  all, so scanning them now invalidates nothing.

### Added

- **`.\cn.ps1 doctor`** reports the whole release chain in one place: toolkit
  version, tree version, changelog section, HEAD, tags at HEAD, uncommitted
  changes, remote, and whether the expected tag has actually been pushed. Written because diagnosing a release that silently did nothing
  meant assembling five separate commands by hand.
- `/cn perf` reports per-provider cache state and any caps hit.

## [0.15.0]

### Added

- **Tooltips.** Item tooltips now say what the addon already knew: whether a
  toy, mount, battle pet or appearance is collected, whether this character
  knows a recipe and which of your characters does, and which recorded
  vendor sells the item and where they stand. Unit tooltips identify a
  merchant you have already shopped at.
  Nothing is added to items the addon knows nothing about â€” an appearance
  line only appears where the item genuinely has an appearance source, so
  the addon stays off every stack of ore in the game. `/cn tooltips` toggles
  the whole thing, and reports which tooltip API resolved.
- **`/cn setup`.** Runs all eleven subsystem scans in order, one per frame,
  then names the two things it cannot do for you: recipes and vendor
  inventories are readable only while their windows are open.
  A new install previously had to discover eleven separate scan commands,
  and looked broken until it did. The first login now prints a single
  pointer to this command and then stays quiet.
- The minimap button tooltip shows the current recommendation and its top
  reasons, so the most common question the addon answers no longer requires
  opening anything.
- Settings tab gains a tooltip toggle and a **Scan everything now** button.

### Changed

- **Candidates are cached.** Nine providers were being rebuilt on every
  `/cn next`, every window refresh and every auto-advance tick, several of
  them walking thousands of records. Results are now held for five seconds
  and invalidated by the sixteen events that can actually change an answer.
- `/cn perf` reports cache state and per-provider timings, slowest first, so
  a slow provider can be identified rather than guessed at.

## [0.14.0]

### Added

- **Managing what you hid.** `/cn hidden` lists everything ignored or
  deferred, with real names rather than internal keys. `/cn unhide <id>`
  restores one, `/cn unhide all` restores everything.
  Ignore and defer have existed since the first build with no way to see
  either list or undo anything in them. Ignoring something by accident
  meant it was gone permanently, which is a bug wearing a feature's
  clothes.
- Expired deferrals are pruned at login instead of accumulating in
  SavedVariables forever.
- **Vendors.** Every merchant you open is recorded permanently: what they
  sell, and where they stand. `/cn sells <item>` finds who sells something,
  `/cn tovendor <item>` routes you there, `/cn vendors` summarizes.
- Recipes you do not know that a recorded vendor sells now become
  recommendations with real coordinates. This is the missing link in the
  design's flagship example: everything else it needed already existed, but
  nothing knew where anything was sold.

### Fixed

- **NPC IDs were never parsed.** `tonumber(select(6, strsplit("-", guid)))`
  passes every remaining GUID field to `tonumber`, so the spawn UID arrived
  as the `base` argument and the call threw. Every vendor capture would have
  failed in game. Wrapping the `select` in parentheses truncates it to one
  value.

### Notes

- Vendor inventories, like trade skill recipes, are only readable while the
  window is open. So the vendor database grows as you play rather than
  shipping stale, and only vendors you have actually opened are known.


## [0.13.0]

### Added

- **Auto-advancing waypoints.** `/cn auto`, or the Settings checkbox. When
  the thing you were pointed at is finished, the waypoint moves to whatever
  is worth doing next. Off by default: taking over the waypoint uninvited
  is hostile, and TomTom arrows are shared with every other addon.
  It re-points when the objective *changes*, not on a timer, because a
  waypoint that silently moves while you walk to it is worse than one that
  never moves. A slow backstop ticker covers objectives that expire rather
  than complete, such as a world quest running out while you stand still.
- **Three new tabs: Now, Warband and Remaining.** Everything added since
  0.9 was reachable only by typing, which broke this addon's own rule that
  the keyboard is the power-user path and not the required one.
  The Now tab merges world quests, live rares, capped currencies and
  unfilled weekly earning into one clickable list.
- **Exploration.** Per-zone subzone discovery, with the names of the places
  you have not been. Zones closest to finishing are surfaced first.
  `/cn exploration`, `/cn explorescan`.
- **HandyNotes provider.** Reads registered HandyNotes plugins for treasure
  and rare coordinates. It never answers quest lookups, so it cannot
  contribute wrong prerequisite data.

### Fixed

- Tab buttons ran off the edge of the window once there were more than about
  six. Tabs are a registry any module can add to, so they now wrap to a
  second row and the panel below moves down to match, rather than the window
  being widened to fit today's count.
- "1 plugins" in provider diagnostics.

### Notes

- The exploration achievement category is the only countable exploration
  data the client exposes. The map API reports which overlays you have
  revealed but never how many exist, so a true "percent explored" cannot be
  computed. Per-subzone criteria are more actionable anyway: they name the
  place you have not been.


## [0.12.0]

### Added

- **"Why isn't this 100%?"** `/cn breakdown` explains what is left in every
  category and why, with a concrete next action per line rather than a bare
  count. `/cn breakdown <category>` for one at a time.
  Percentages appear only where the denominator is trustworthy. The client
  knows how many mounts exist; nothing knows how many quests exist. Where a
  total is unknowable the addon says so and shows counts, instead of
  inventing a number that looks authoritative.
- **Currencies.** Caps and weekly earning, tracked per character.
  A capped currency is earning potential being thrown away, so it surfaces
  as a time-sensitive recommendation to go spend it. Unfilled weekly caps
  are reported because they reset whether you use them or not.
  `/cn currencies`, `/cn currencyscan`.

### Fixed

- Singular/plural agreement in breakdown output. "1 are locked to the
  opposite faction" reads as a bug even when the number is correct.


## [0.11.0]

### Added

- **Rares and treasures**, driven by the client's vignette data rather than a
  static spawn database. A vignette is the only live signal that a rare is
  actually up right now, which is the half of the question static data
  cannot answer and which goes stale every patch.
  `/cn rares` lists what is up, `/cn rare <n>` routes to it, `/cn raredb`
  summarizes everything recorded.
- Rares and treasures feed the recommendation engine as time-sensitive
  objectives, because something that is up now and dead when someone else
  finds it is exactly what the limited-time term is for.
- Everything seen is recorded permanently and account-wide, so the addon
  accumulates its own spawn database from play. It cannot go stale, because
  it comes from the live game.
- Vignettes that disappear while the player is nearby are inferred as
  cleared by that character. Recorded as inference, not asserted as fact.
- **Addon artwork.** The .toc IconTexture and the minimap button now use the
  project logo. `.\cn.ps1 icon <file.png>` regenerates `Media\Logo.tga`.

### Fixed

- `check` now verifies that the file `IconTexture` points at actually
  exists. WoW fails silently on a missing texture, so a typo produced a
  blank icon and no error anywhere.
- The minimap button verifies its texture loaded and falls back to a stock
  icon rather than rendering an invisible button.


## [0.10.0]

### Added

- **Opportunity scanner.** World quests, daily and weekly resets, and active
  world events. Urgency is scaled steeply: something with an hour left
  dominates, something with three days left barely registers.
  `/cn now` lists everything expiring, soonest first. `/cn events` lists
  active world events.
- **Warband intelligence.** `/cn warband` shows every known character with
  what each covers, plus the combined coverage across all of them.
  `/cn who <rep, recipe, title or profession> <id or name>` answers which
  character should do a given thing.
- **Candidate decorators.** Cross-cutting concerns now apply to objectives
  from modules that know nothing about them. Warband suitability is the
  first user.

### Fixed

- `limitedTimeBonus` carries the heaviest weight in the scoring formula
  (3.0) and nothing ever set it. The engine was built to prioritise
  expiring content and had no idea what expires.
- `characterSuitability` was likewise weighted and never set.
- **Migrations ran after defaults were merged**, which meant `CopyDefaults`
  had already discarded any stored value whose type no longer matched the
  default. A migration existing to read a legacy value would silently find
  nothing. Migrations now run on the raw saved data first. This affected no
  shipped migration yet; it would have broken every future one.
- Literal `|` characters in command help and usage text were eaten by the
  chat frame as escape sequences: `<factionID|name>` rendered as
  `<factionIDame>`. Every affected string now reads `<factionID or name>`.

### Notes

- Database schema is now version 2. The 1 to 2 migration creates the account
  tables the collection modules added and moves the flat minimap setting into
  its nested form, preserving the player's choice. It is idempotent and is
  covered by a test that starts from a real version 1 database.


## [0.9.0]

### Added

- **Harvesting.** Every quest you pick up or turn in now has its name, zone,
  map, coordinates and observed level recorded permanently and account-wide.
  Playing the game fills the static database. `/cn harvest` shows what has
  been collected; `/cn harvestnow` sweeps the current log.
- **Export.** `/cn export` emits harvested quests as ready-to-paste
  `Data\Quests.lua` rows, so what one player harvests can be committed and
  shipped to everyone. `/cn export all` includes quests with no coordinates.
- **AllTheThings provider.** Reads quest names, coordinates, source quests
  and level requirements from ATT when the player has it installed.
- **BtWQuests provider.** Reads quest names and prerequisite chains,
  including nested prerequisite conditions.
- **Provider registry.** External data sources are merged by priority behind
  one interface. Curated static data always outranks them, because it is the
  only source this addon ships.
- `/cn providers` reports which external addons were detected and which entry
  points resolved. `/cn lookup <questID>` asks all of them about one quest.
- `/cn why` now reports which data source produced its answer, or says
  plainly that no prerequisite data exists for that quest.

### Notes

- Third-party addon internals are not published contracts. Every provider
  access is probed and wrapped, so an ATT or BtWQuests update can make a
  provider go quiet but cannot break Completion Navigator. `/cn providers` is
  how you tell which happened.
- Prerequisites inferred from the order you completed quests are recorded
  separately, never fed to the eligibility checker, and appear in exports as
  commented suggestions for a human to confirm. Correlation is not a
  prerequisite.

## [0.8.0]

### Added

- Battle pet collection tracking, including wild/obtainable classification
  and per-species collected counts.
- Mount collection tracking with faction-lock detection, so a mount your
  current character can never use is reported as such rather than as simply
  missing.
- Toy box tracking.
- Transmog appearance progress, reported per category.
- Title tracking, stored per character so the addon can say which alt
  already earned one.
- Achievement tracking focused on near-completion: achievements within two
  criteria of finishing are surfaced and fed to the recommendation engine.
- Profession and recipe tracking, including which characters know which
  recipe.
- A Collections tab showing account-wide completion per category.
- Slash commands for every subsystem: `/cn pets`, `/cn mounts`, `/cn toys`,
  `/cn appearances`, `/cn titles`, `/cn achievements`, `/cn closest`,
  `/cn professions`, `/cn recipes`, and per-item lookups.

### Fixed

- Profession enumeration walked the five profession slots with `ipairs`,
  which stops at the first empty slot. A character without Archaeology
  silently lost Fishing and Cooking.

### Notes

- Recipe lists can only be read while a profession window is open. This is a
  client restriction. The addon captures them automatically the first time
  you open each profession and tells you which are still outstanding rather
  than reporting zero.

## [0.7.0]

### Fixed

- Quest coordinates now come from four client sources rather than one.
  `GetNextWaypoint` answers for very few quests; the map POI list covers
  ordinary ones.
- Quests with no coordinates fall back to Blizzard's own tracking arrow
  instead of refusing to navigate.

### Added

- `/cn where` and `/cn setloc` for inspecting and recording quest locations.

## [0.6.0]

### Added

- Minimap button, tabbed main window, clickable objective lists, and
  keybindings.

## [0.5.0]

### Added

- `/cn zone`: clusters and routes everything obtainable in the current map.

## [0.4.0]

### Added

- Quests feed the recommendation engine; `/cn go` sets waypoints.

### Fixed

- Priority profiles applied weight names to an objective-type lookup, so
  `/cn mode fastest` did nothing.
- Objectives with no known location paid no travel cost and structurally
  outranked located ones.

## [0.3.0]

### Added

- Reputation, Renown and Paragon tracking, scoped account-wide versus
  character-specific.

## [0.1.0]

### Added

- Modular rewrite with registry-based commands, events and modules.
- Source-ranked quest metadata.
- Event-driven quest discovery.
