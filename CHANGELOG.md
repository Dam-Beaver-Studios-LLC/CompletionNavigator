# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

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
