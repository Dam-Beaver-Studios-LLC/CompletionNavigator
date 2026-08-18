# Completion Navigator â€” Roadmap

Current version: **0.18.0** Â· 40 Lua files Â· ~15,600 lines Â· 77 slash commands Â· 11 candidate providers Â· 10 UI tabs

Completion Navigator is a product of Dam Beaver Studios, LLC. Authored by Travis A. Bryan I.

This is an audit of what is built against what was designed, not a wishlist. Every item below was found by reading the code, not by imagining features.

---

## Tier 1 â€” Holes in the core promise

The addon claims to answer *"what should I do next?"* Each item here is a case where it currently cannot.

### 1.1 Great Vault / weekly rewards â€” **DONE in 0.18.0**

**Status:** shipped. `/cn vault`, a Vault tab, and vault rows as candidates with urgency scaled by both distance-to-threshold and time-to-reset.

This is the single largest recurring "what should I do next" signal in modern retail. A player with 2/8 dungeon runs toward a vault slot has a concrete, time-boxed, high-value objective, and the addon has nothing to say about it. Everything needed already exists â€” the opportunity scoring was built for exactly this shape of objective (real deadline, known progress, known reward).

**Delivers:** `/cn vault`, vault progress as candidates with genuine urgency weighting, a Now-tab section.
**Risk:** low. Read-only API, well documented.
**Effort:** moderate.
**Recommendation: build first.** Highest value-to-effort ratio on the entire list.

### 1.2 Five subsystems are tracked but never recommended

**Status:** confirmed by audit. These modules scan, store and report â€” but register **no candidate provider**, so they never surface in `/cn next`:

| Module | Scans | Reports | Recommends |
|---|---|---|---|
| Mounts | yes | yes | **no** |
| Toys | yes | yes | **no** |
| Appearances | yes | yes | **no** |
| Titles | yes | yes | **no** |
| Professions | yes | yes | **no** |

Pets has a provider; Mounts does not. That inconsistency is not a design decision, it is an omission â€” and it means the Collections priority mode weights types that can never appear.

The reason it was not obvious: `/cn breakdown` and the Collections tab read the stores directly, so the data *looks* wired up.

**Delivers:** these become real recommendations where a source is known. Professions in particular should surface "your skill is 42/100 and you can train to 150".
**Risk:** low, but needs the bounded-collection cap (already built) so 900 uncollected mounts do not flood the list.
**Effort:** moderate â€” five providers, each small.
**Recommendation: build second.** It closes a stated capability the addon does not have.

### 1.3 Delves

**Status:** absent.

Evergreen current-expansion content with weekly progression, tied to the vault. Naturally pairs with 1.1.

**Effort:** moderate. **Risk:** medium â€” the API surface has moved between patches.

### 1.4 Group content awareness

**Status:** absent. Zero references to dungeons, raids, or LFG anywhere.

The addon is entirely solo-content-aware. A meaningful share of what a player "should do next" is a dungeon or raid lockout. Even a modest version â€” "this raid lockout resets in 2 days and you have 3/8 bosses" â€” would be real.

**Effort:** large. **Risk:** medium.
**Recommendation:** after 1.1â€“1.3. Scope carefully; this could sprawl.

---

## Tier 2 â€” Existing features that are not yet load-bearing

### 2.1 The dependency graph is empty

**Status:** exactly **one** `CN.AddDependency` call and **one** static quest row exist.

`Dependencies.lua` is fully built â€” blocker reasons, graph walking, `/cn why`, prerequisite forensics. It has almost no data to walk. `/cn why` therefore answers "I don't know" for essentially every quest.

0.17.0's `.\cn.ps1 harvest` closes the *collection* half of this: quest names, zones and coordinates now flow from SavedVariables into `Data\Quests.lua` automatically. It does **not** populate prerequisites, because prerequisites cannot be observed reliably â€” the addon records `maybeRequires` (quests completed shortly before another became available) and deliberately keeps it separate from fact.

**Options, in order of preference:**

1. **Import prerequisite chains from BtWQuests at runtime.** The provider already exists and is probed. Extend it to feed the dependency graph rather than only answering name lookups. Zero curation burden, and it degrades quietly when BtWQuests is absent.
2. **Promote `maybeRequires` to `requires` with a confidence threshold** â€” e.g. observed across 3+ characters. Honest, self-improving, needs no external data.
3. Hand-curate. Does not scale, and is the reason the file is still empty.

**Recommendation: option 1, then option 2.** Curation is not a strategy.

### 2.2 Route quality

**Status:** `CN.OrderByProximity` is greedy nearest-neighbour.

Greedy nearest-neighbour is typically 15â€“25% worse than optimal and produces a characteristic failure: it strands one far objective and doubles back for it at the end. On a 12-stop zone sweep that is a visible, annoying detour.

**Fix:** a 2-opt improvement pass over the greedy result. Thirty lines, converges in milliseconds at this size, and typically recovers most of the gap.

**Effort:** small. **Risk:** low. **Recommendation: build it.** Cheap and directly visible.

### 2.3 Achievements only when nearly complete

**Status:** documented limitation â€” only achievements within 2 criteria become candidates.

Defensible as a default, and wrong as an absolute: a Goal pinned on an achievement should surface its criteria regardless of distance. Partly addressed by 0.17.0 Goals; worth extending so a pinned achievement decomposes into per-criterion objectives with locations.

**Effort:** moderate. **Risk:** low.

### 2.4 Appearances are per-category only

**Status:** documented limitation. Tracked per slot, not per item.

Enumerating every appearance source is tens of thousands of entries, which is why it was scoped out. A middle path exists: enumerate appearances only for a **pinned goal**, on demand. Bounded work, real answer.

**Effort:** moderate. **Risk:** medium â€” `C_TransmogCollection` enumeration is slow and needs the caching layer.

---

## Tier 3 â€” Reach and polish

### 3.1 Localization

**Status:** zero. `GetLocale` appears nowhere; every user-facing string is hardcoded English.

CurseForge asked about localization permissions at project setup, and the answer today is that there is nothing to localize against.

**Work:** extract strings to `Locales\enUS.lua` behind an `L[]` table, then let CurseForge's localization system handle translations. The extraction is mechanical and large; `cn.ps1` can generate the initial locale file by scanning for string literals.

**Effort:** large but low-risk and highly parallelizable.
**Recommendation:** do the *extraction* early â€” it gets harder every release. Translations can follow whenever.

### 3.2 LibDataBroker

**Status:** absent.

Titan Panel and ElvUI users expect a datatext. A broker object showing the current recommendation, clickable to open the window, is roughly forty lines.

**Effort:** small. **Risk:** low â€” but it is the first external library dependency, and the UI file's header explicitly notes that no libraries are embedded. Worth doing as an *optional* integration: detect LibStub, register if present, stay silent if not. Consistent with how TomTom/ATT/BtWQuests are handled.

### 3.3 Per-character settings

**Status:** settings are account-wide only.

Priority mode in particular is character-shaped: a max-level main and a levelling alt want different answers. Auto-waypoint too.

**Work:** a profile layer over `CN.Settings()`, with account-wide as the default and per-character override. Needs a migration (dbVersion 2 â†’ 3), and the migration ladder is already proven.

**Effort:** moderate. **Risk:** low-medium â€” settings migrations are where data gets destroyed, and the existing test asserts against exactly that.

### 3.4 Rare spawn alerts

**Status:** no sound or on-screen alerting anywhere.

Vignette detection already works. A rare appearing that you have not cleared is worth an optional sound and a screen message. Must be **off by default** â€” unsolicited noise is worse than seizing the waypoint.

**Effort:** small. **Risk:** low.

### 3.5 Minimap/world map pins

**Status:** navigation is waypoint-only.

HandyNotes integration exists as a provider but the addon draws no pins of its own. Drawing zone-sweep stops on the world map would make `/cn zone` far more legible.

**Effort:** moderate. **Risk:** medium â€” map pin APIs churn between expansions.

---

## Tier 4 â€” Infrastructure

### 4.1 Player-to-player data sharing

`/cn export` emits rows; `.\cn.ps1 harvest` now folds SavedVariables in. Neither lets one player's harvest reach another's install except through you shipping a release.

**Options:** a curated `Data\Community.lua` built from submitted exports (needs a submission path), or accepting an import string in-game. The former is a process problem more than a code problem.

### 4.2 Test coverage measurement

The harness and `pstest.sh` are strong but coverage is unmeasured â€” I do not know what fraction of the Lua is exercised. `luacov` under the harness would say.

**Effort:** small. **Recommendation: do it.** It will find dead paths, and this project has now shipped three bugs that a test existed near but not on.

### 4.3 Static analysis â€” **DONE in 0.18.0**

luacheck runs over the Lua, configured for the client surface, baseline zero, enforced by the suite and CI. Historically: no linter ran over the Lua. `luacheck` catches globals-by-typo, unused locals and shadowing â€” the exact class of bug that a stubbed test harness hides. Add to `pstest.sh` and to CI.

**Effort:** small. **Risk:** none. **Recommendation: do it.**

### 4.4 CI runs the tests â€” **DONE in 0.18.0**

CI now lints and runs the full harness on every tagged build. Historically: `release.yml` syntax-checked Lua and verified the `.toc` but never ran `harness.lua`. The full suite runs only on my machine.

**Effort:** small. **Recommendation: do it.** A release can currently ship with a failing harness.

---

## Recommended order

Not a menu. This is what I would build, in this sequence:

| # | Item | Why here |
|---|---|---|
| 1 | **4.3 luacheck + 4.4 CI runs the harness** | Half a day. Every subsequent item is safer. Stop shipping bugs the tests could have caught. |
| 2 | **1.1 Great Vault** | Largest single gap in the core promise. Self-contained. |
| 3 | **1.2 Five missing candidate providers** | Closes a capability the addon implies but lacks. Low risk, immediately visible. |
| 4 | **2.2 Route 2-opt** | Thirty lines, visible improvement. |
| 5 | **3.1 Localization extraction** | Gets harder every release. Do the extraction now; translate later. |
| 6 | **2.1 Dependencies via BtWQuests** | Makes `/cn why` load-bearing for the first time. |
| 7 | **1.3 Delves** | Pairs with the vault work. |
| 8 | **3.2 LibDataBroker + 3.4 Rare alerts** | Small, popular, low risk. Ship together. |
| 9 | **3.3 Per-character settings** | Needs a migration; do it when the ladder is quiet. |
| 10 | **1.4 Group content** | Largest scope. Do it when the foundation above is solid. |

Items 4.1, 2.3, 2.4 and 3.5 are worth doing but are not on the critical path.

---

## Deliberately not planned

- **Combat, rotation or DPS features.** Different addon.
- **Auction house or gold-making.** Different addon.
- **Anything requiring an external server.** The addon is self-contained by design, and a server is an ongoing liability.
- **Invented completion percentages.** Where the client cannot supply a trustworthy denominator, the addon reports counts and says why. This is a standing rule, not a gap.

---

## Compliance note

Public-facing copy for this addon carries no outcome promises, no superlatives, no specialization claims. That applies to the CurseForge page, the README, and any future marketing.
