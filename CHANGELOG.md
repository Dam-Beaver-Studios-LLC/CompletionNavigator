# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

## [0.24.1]

A release-blocking defect in CI. No addon changes.

### Fixed

- **CI silently stopped releases from reaching CurseForge.** The coverage step
  added in 0.21.0 hardcoded the luacov path from the author's machine
  (`/usr/local/share/lua/5.1`). On any host where luarocks installed luacov
  somewhere else -- which includes the GitHub runner -- the script died under
  `set -e` producing **no output at all**, the workflow stopped, and the
  packager never ran. The tag was pushed, the release was validated, the log
  looked almost fine, and no file appeared.
  `coverage.sh` now locates luacov wherever the machine put it, and when it
  genuinely cannot run it says so and exits successfully. A quality signal for
  the author is not a reason to deny users a build.
- The coverage step is marked `continue-on-error`. Lint and the harness still
  block a release, because those mean the addon is broken. Missing developer
  tooling does not.

### Added

- **The test suite now checks the CI workflow itself.** Any step that could
  block a release must either be on an allow-list of things that indicate
  genuinely broken code, or carry `continue-on-error`. Adding a fragile step
  in front of the packager now fails the suite rather than a release.
- A test that runs `coverage.sh` with luacov deliberately unreachable and
  requires it to exit zero with an explanation.

## [0.24.0]

Stop running back and forth.

### Added

- **A quest is now three places, not one.** PICKUP, ACTIVE, TURNIN. Treating a
  quest as a single point is exactly why an addon sends you across a zone and
  back: it cannot tell that two quests share a giver, or that four you are
  carrying all hand in at the same NPC. Naming the phase is what makes
  batching possible at all, and every quest recommendation now says which one
  it is -- *pick up*, *work on*, *turn in*.
- **Routes are planned between places, not between objectives.** Stops within
  about seventy yards of each other collapse into one hub, the route is solved
  hub to hub, and within a hub the order is the order you would actually do it:
  collect the quests, do the work, hand them back. `/cn zone` prints it that
  way -- *"3 things here -- pick up 2, turn in 1"* -- and says how many of your
  stops share a place with something else.
  Single-link clustering, so a row of quest givers strung along a road becomes
  one stop rather than four.
- **The engine prefers work that batches**, rather than only displaying it that
  way. An objective sharing a place with others scores higher than an identical
  one standing alone, capped so a big cluster cannot drown out something
  genuinely urgent. Without this the *route* would batch while the
  *recommendation* still sent you across the zone for one quest.

### Notes

- Distances for clustering are computed in real yards through the client's
  world positions, falling back to a scaled normalized distance when the client
  will not convert. Clustering on raw map coordinates would make hubs enormous
  in small zones and useless in large ones, because map coordinates are
  normalized per map.
- The harness outgrew Lua's 200-local limit for a single function. Self-
  contained test sections are now scoped, which is better hygiene than it
  sounds: it also stops one section's fixtures leaking into the next.

## [0.23.0]

Reported from live play: *"it only shows the quests you have accepted -- I
don't see where it shows the quest pending to be accepted in the zone"*, and
*"'new' is always 0"*.

Both were the same defect, and it was a bad one.

### Fixed

- **The addon could not see a quest until you had already accepted it.**
  Every quest source it read was the quest log, which by definition contains
  only quests you have already taken. So the exclamation marks standing in
  front of you -- often the single best next action available -- were
  structurally invisible, and an addon whose entire purpose is answering
  *"what should I do next?"* could never answer *"go and pick that up"*.
  The client had the data the whole time. `C_QuestLog.GetQuestsOnMap` returns
  every quest pin with an `isQuestStart` flag, and the addon called that same
  function from the first build -- but only ever to ask "where is this one
  quest I already have?", discarding everything else it returned.
  Available quests now become recommendations, with their names, their pin
  coordinates, and a reason that says what they are. They are weighted above
  an accepted quest you have not started, because walking twenty yards to
  collect one is the cheaper action and it unlocks whatever follows.
- **`new` was permanently zero.** Discovery walked the quest log and nothing
  else, so once your own quests had been scanned there was nothing left to
  discover, ever. It now records available quests too, and counts them.
- Available quests flow into `/cn zone`, so a zone sweep routes you past the
  quests you have not picked up rather than only the ones you have.

### Notes

- The harness stub was complicit. It returned a single in-log quest from
  `GetQuestsOnMap` and no quest starts at all, so the test data had exactly
  the same blind spot as the code and could never have caught this. It now
  returns in-log quests, offered quests, a daily, and a quest start for
  something already completed -- and the suite asserts the completed one is
  never offered again.
- Found by a player, not by a test. That is the second time a stub modelled
  the world too simply and hid a real defect; the pattern to watch for is test
  data that only contains the cases the code already handles.

## [0.22.0]

`/cn why` has been able to explain why a quest is locked since the first build,
and has had almost nothing to explain it with. This release gives it data.

### Added

- **Prerequisites inferred from repeated play, and gated on confidence.**
  The addon has always noted which quests you turned in shortly before
  accepting another. One such observation is the order you happened to play in
  and nothing more, so it was never used for anything.
  Observations now accumulate **per distinct character**, and only cross into
  the dependency graph once **three different characters** show the same
  ordering. Independent playthroughs do not agree by accident, and an alt
  cannot inherit a coincidence. Repeating a chain on one character does not
  raise confidence -- doing something twice is still one character's opinion.
- **Inference is never presented as fact.** Confident edges are published as
  `observedRequires`, never `requires`, and `/cn why` reports them as *"probably
  needs another quest first"* with the character count attached, not as the
  flat statement a curated prerequisite produces. The harness asserts an
  inferred edge can never be written as a curated one.
- `/cn export` and `.\cn.ps1 harvest` write confident observations as real
  `requires` rows and everything below the threshold as a comment with its
  character count, so curation never has to guess which lines were inferred.

### Fixed

- **Observed prerequisites could only ever apply to quests that already had
  curated data.** The check sat inside the branch that runs when a static
  record exists -- the exact opposite of the point, since inference matters
  most where curation is absent. Found by a test that expected a block and got
  silence.
- **The correlation window now clears on login.** A quest accepted in a new
  session could otherwise be correlated with one turned in before the last
  logout. The 300-second window covered that in most cases, and "most" is how
  a false prerequisite gets recorded and then repeated until it looks
  confident.

### Notes

- Schema 3 -> 4. Existing observations are preserved and credited to one
  unknown character each -- deliberately *below* the promotion threshold, so
  data gathered before the addon counted characters is never promoted on the
  strength of a count it never made.
- Delves were assessed and deliberately not built. `C_DelvesUI` exposes UI
  plumbing, not progress, and delve credit toward the Great Vault already
  flows through the World row added in 0.18.0. A separate module would have
  been guesswork duplicating something that already works.

## [0.21.0]

### Added

- **Per-character settings.** Priority mode, auto-advance, the arrow and
  tooltips can each be set for one character instead of the whole account.
  `/cn perchar priorityMode` takes control of a setting; running it again hands
  it back. A max-level main and a levelling alt want different answers, and the
  character you are on should decide that rather than the last one you changed
  it on.
  Overrides are stored sparsely -- only what a character explicitly took over --
  so a default changed in a later release still reaches everyone, instead of
  being frozen at whatever it was when the override was made. Schema 2 -> 3;
  nothing moves, and every existing character starts with no overrides at all.
- **LibDataBroker feed.** Titan Panel, ElvUI datatexts and ChocolateBar can
  show the current recommendation, click to open the window, right-click to
  navigate. It is the only external library the addon touches, and it is
  handled like every other optional integration: probed, wrapped, silent when
  absent. `/cn broker` reports whether it resolved.
- **Rare alerts.** `/cn alerts on` announces rares that appear near you, once
  each, only for ones you have not already cleared, reset when you change zone.
  **Off by default** -- unsolicited sound is worse than an uninvited waypoint,
  and the waypoint is already off by default.
- **Coverage measurement**, wired into the test suite and CI with an 80% floor.
  A suite whose reach nobody measures drifts: it keeps passing while covering
  less and less. Currently **85%**.

### Fixed

- **The TomTom provider had never been executed by a single test.** Coverage
  found it at 41% -- it shipped in every release with no test able to reach it,
  because no TomTom existed to probe. It is stubbed now, and the suite asserts
  that choosing TomTom actually routes waypoints through TomTom rather than
  silently keeping the native one.
- **`cn.ps1` wrote shell scripts with CRLF line endings.** A CRLF shell script
  fails with `$'\r': command not found`, which reads like a corrupt file rather
  than a line-ending problem. `.sh`, `.yml` and `.yaml` are now written LF,
  since those are the files a Linux CI runner executes.

## [0.20.1]

The arrow pointed the wrong way. This fixes it, and fixes the reason the tests
did not catch it.

### Fixed

- **The navigation arrow pointed at the reciprocal of the target.** Following
  it increased the distance while it still showed blue for "on course", because
  the colour and the direction were computed from the same wrong number and so
  agreed with each other.
  The cause: 0 is north on every client, but whether `GetPlayerFacing()` grows
  as you turn left or as you turn right is a convention, and 0.19.0 assumed the
  wrong one.

### Changed

- **The arrow now works the convention out for itself.** If you are lined up
  with it, moving, and the distance is *growing*, the arrow is demonstrably
  backwards -- so it flips, says so once, and remembers. Several consecutive
  samples are required, so walking backwards, a flight path or a loading screen
  cannot trigger it. `/cn calibrate` forces the flip by hand.
- **The bearing tests were the real defect.** Seven cases "verified" 0.19.0,
  and every one of them computed its expected answer from the same assumption
  the code used -- so the tests agreed with the bug. A test that encodes the
  premise it is meant to check proves nothing.
  They are rewritten around properties that hold under *either* convention:
  facing the target is zero, facing away is a half turn, east and west are a
  quarter turn in opposite directions, and turning by the reported bearing must
  line you up. The suite now also asserts that the two conventions genuinely
  differ, and that the self-correction fires when the distance grows and stays
  put when it shrinks.

## [0.20.0]

### Fixed

- **The arrow reported "distance unknown" for every target.** 0.19.0 passed a
  `UiMapPoint` to `C_Map.GetWorldPosFromMapPos`, which wants a `Vector2D`.
  They are different types -- `UiMapPoint` carries a nested `position`,
  `Vector2D` carries `x` and `y` directly -- and they are easy to confuse
  because both describe a point. `SetUserWaypoint` wants the first, this wants
  the second.
  The harness stub modelled both as the same flat shape, which is exactly why
  the test passed while the addon failed. The stub now models each correctly
  and asserts the right type is passed; reintroducing the bug fails the suite.

### Added

- **Filter what you get recommended.** `/cn show` chooses which kinds of
  objective appear: `/cn show pets` toggles one, `/cn show only quests`
  narrows to a single kind, `/cn show all` restores everything. The **Next**
  tab has a *Filter types* button with the same checklist.
  Only hidden types are stored, so a kind added in a later release is visible
  by default rather than silently missing for everyone who upgraded. Filtering
  is applied to the ranked list, never to collection -- `/cn breakdown` and the
  Collections tab still see everything -- and when a filter empties the list
  the Next tab says so instead of looking broken.

- **Mounts, toys, professions and appearances are now recommendations.** Four
  subsystems that the addon has scanned, stored and reported since early
  builds registered no candidate provider at all, so they could never appear
  in `/cn next`. Pets had one; mounts did not. That was an omission, not a
  design decision, and it meant the Collections priority mode weighted types
  that could never surface.
  - **Mounts** are recommended only where the journal supplies a source --
    *"Vendor: X"*, *"Quest: Y"*, *"Drop: Z"*. A mount locked to the other
    faction is never suggested.
  - **Toys** join the vendor database exactly, because both are keyed by item
    ID, so an uncollected toy a recorded vendor sells becomes an objective
    with real coordinates.
  - **Professions** below their cap, weighted so the last few points rank
    above a profession barely started.
  - **Appearances** surface the least-complete slots only, capped at three.
- **2-opt route improvement.** `/cn zone` built its route with greedy
  nearest-neighbour, which has a characteristic failure: it takes the locally
  cheap step every time, strands one far objective, and doubles back for it at
  the end. A 2-opt pass now uncrosses the route. On the harness's crossed test
  case it removes **21.6%** of the distance.

### Notes

- **Titles deliberately do NOT get a provider, and the harness asserts it.**
  A recommendation has to name an action, and the client exposes a title's
  name and whether you have it -- no source, no coordinates, no criteria.
  *"You do not have Loremaster"* is a fact, not a next action. Titles remain
  fully tracked in `/cn titles`, `/cn who title`, the Collections tab and
  `/cn breakdown`, and one you actually want can be pinned with
  `/cn goal title <id>`. Shipping a fifth provider to close a checklist item
  would have put rows with no route into a list whose entire purpose is to be
  actionable.
- The Goals test previously proved its point using an uncollected mount, on
  the premise that one is never a candidate. Mounts gained a provider and that
  premise quietly became false -- the test caught it, and now uses a title,
  which has no provider by design.

## [0.19.0]

Completion Navigator no longer needs any other addon to navigate.

### Added

- **Native navigation.** An on-screen arrow that points at your destination,
  turns as you turn, and reports real distance in yards.
  TomTom was never a dependency on paper -- every access was probed and
  wrapped -- but in practice it was: without it you got a static map pin and no
  arrow, which is not navigation. That gap is closed.
- **The arrow is the addon's own.** Custom artwork, tinted with the blue of
  the waypoint marker in the Completion Navigator logo (`#5DD2FB`), sampled
  from the logo rather than guessed. It turns gold when you drift off course
  and red when you are walking away, so the colour carries information rather
  than only branding. Drag it anywhere; the position is saved.
- **Real distance, in yards.** Map coordinates are normalized per map, so the
  same 0.1 difference is a different real distance in every zone. The arrow
  converts through the client's world positions and reports yards -- and
  reports *"distance unknown"* rather than a made-up figure when the client
  cannot convert.
- **Arrival detection.** Getting within twelve yards fires arrival, which is
  what auto-advance was designed around; before this it could only re-point on
  a timer or an event.
- **`/cn nav`** chooses the provider: `auto` (native), `tomtom`, or
  `blizzard`. TomTom users who prefer its arrow keep it with one command.
  `/cn arrow` toggles the arrow, `/cn here` reports where you are and what is
  being tracked.

### Changed

- Native navigation is now the preferred waypoint provider, ahead of TomTom.
  It is the only provider that cannot be missing.
- Routing no longer suggests installing TomTom when nothing is available,
  because that is no longer the reason.

### Notes

- The bearing maths is the kind that is invisible when wrong -- a reversed sign
  points you confidently at the wrong place and raises no error. Seven cardinal
  cases are asserted in the harness, along with the yard conversion, the
  arrival threshold, and the refusal to compute a bearing to another map.

## [0.18.0]

### Added

- **The Great Vault.** `/cn vault`, a **Vault** tab, and vault progress as real
  recommendations.
  This is the only system in the game that supplies all three things the addon
  normally has to guess at -- a hard deadline, a known denominator, and a known
  reward -- so it is the one place a percentage is a fact rather than an
  estimate. A row one activity short of a threshold, with the reset approaching,
  is the most actionable thing this addon can offer: *"one more Heroic before
  Tuesday unlocks a second reward."*
  Capped rows are never recommended, because they cannot be advanced. An
  unclaimed reward from last week outranks everything -- it is free, it takes
  thirty seconds, and it is destroyed when the vault next fills.
- **luacheck static analysis**, configured for the WoW client surface so a
  warning is worth reading. The baseline is zero, enforced by the test suite
  and by CI.
- **CI now runs the tests.** `release.yml` previously syntax-checked Lua and
  verified the `.toc` but never ran the harness -- the full suite ran only on
  the author's machine, which meant a release could ship with it failing and
  nothing would say so. The harness and the benchmark now ship with the source
  and run on every tagged build.

### Changed

- Precedence between goals and expiring content is now explicit and tested. A
  pinned goal outranks everything merely *available*; it does not outrank
  something with a deadline. A vault slot expires on Tuesday and an uncollected
  mount will still be there next week, and special-casing goals out of urgency
  weighting would have been wrong. The harness asserts both halves.

### Fixed

- `harness.lua` had two shadowed locals that made two halves of the file look
  independent when they were not. Found by luacheck on its first run.
- Test tooling is excluded from the `.toc`, the addon zip and the packaging
  step. `harness.lua` stubs the entire client API, so a copy of it in a
  player's AddOns folder would replace live client functions with fakes.

## [0.17.0]

### Added

- **Goals.** `/cn goal <type> <id>` pins something you have decided you want.
  A goal becomes a candidate in its own right -- an uncollected mount is not
  normally a next action, which is exactly why saying you want it has to mean
  something -- and anything that leads to it ranks higher and says so.
  `/cn goals` prints what is actually known about reaching each one: the
  source, where it is, which of your characters is best placed, and the next
  concrete step. Where nothing is known it says so, and names what would make
  it knowable, rather than inventing a route.
  `/cn ungoal`, `/cn gogoal <n>` to navigate, and a **Goals** tab.
  Types: quest, achievement, mount, pet, toy, recipe, title, rep, rare,
  currency. Goals are account-wide, because deciding you want a mount is not
  a fact about the character you happened to be playing at the time.
- **`.\cn.ps1 harvest`** reads SavedVariables directly and folds harvested
  quests into `Data\Quests.lua`.
  The addon has recorded the name, zone, coordinates and level of every quest
  you accept since the first build, and the only way to get it out was a copy
  box -- so in practice it stayed in SavedVariables and the curated database
  stayed nearly empty. That is what limits prerequisite forensics, and it was
  a tooling gap, not a data gap. Curated rows are never overwritten:
  hand-checked data outranks observed data, the same source-ranking rule the
  addon applies internally. Quests with no coordinates are skipped unless
  you pass `-Force`.

### Fixed

- **Decorators ran once per rebuild instead of once per objective.** 0.16.0's
  per-provider caching means the aggregate list is mostly the *same* objective
  tables as last time, so Warband's "another character is better suited" was
  appended again on every rebuild and stacked up under the recommendation.
  Decoration now happens when a provider builds its objectives. Regression
  test asserts no objective is ever decorated twice.
- **An explicit action no longer waits on a cooldown.** Cooldowns exist to
  stop a chatty *event* from causing work; they were also delaying things the
  player just did on purpose, so a newly pinned goal could take two seconds to
  appear. Invalidation with no event reason -- a scan finishing, a login, a
  goal changing -- now bypasses cooldowns.

### Notes

- `Data\Quests.lua` still ships nearly empty. `harvest` is the mechanism that
  changes that; it needs people to play with the addon loaded first.

## [0.16.1]

A Windows-only defect in 0.16.0's release path. No addon changes.

### Fixed

- **`release` died mid-push on Windows PowerShell 5.1.** There, stderr from a
  native command under `2>&1` arrives as ErrorRecord objects, and with
  `$ErrorActionPreference = 'Stop'` -- set at the top of `cn.ps1` -- the first
  one becomes a terminating error. git writes its ordinary progress to stderr,
  so `git push 2>&1` killed the script on a push that had *succeeded*, leaving
  the tag unpushed and the release invisible to CurseForge.
  Every native invocation now goes through one helper that neutralizes the
  preference for the duration, renders stderr as its message rather than its
  type name, and returns the real exit code.
  This was not caught because the end-to-end test runs PowerShell 7 on Linux,
  which does not behave this way.
- **`check` had the same defect.** `luac.exe` writes syntax errors to stderr,
  so the first malformed file would have terminated the whole check rather
  than being reported alongside the others.
- **`doctor` sorted remote tags as strings**, which put `v0.9.0` above
  `v0.15.0` and made "newest remote tags" actively misleading. Sorted by
  version number now.
- A failed push prints the two commands that finish the release by hand,
  rather than leaving you to work them out.

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
