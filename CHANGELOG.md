# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

## [0.57.0]

The reason-tracking machinery is rebuilt rather than patched again, because
three consecutive releases each shipped a different symptom of the same cause.
Plus the largest performance pass since 0.54.0, and an accuracy fix that
changes what the addon recommends.

### Fixed

- **The shape that kept breaking is gone.** Every reason â€” the provider's own,
  a decorator's, another provider's, an adjuster's â€” was appended to one array
  on the objective, and each of four writers with four different lifetimes had
  to know where its own entries began and ended in order to take them back.
  That produced, in three consecutive releases: sentences repeated once per
  rebuild, sentences deleted and unrestorable, a quest collecting every state
  it had ever been in, and an unlock count frozen because a rollback nilled
  half its bookkeeping. Each was fixed; the shape that produced them was not.
  Nothing writes into anything it does not own now, so there is no boundary
  index to go stale, and the build fails on a write from outside the file that
  owns the list.
- **The most recent symptom, which 0.56.0 shipped:** the aggregate's rollback
  deleted adjuster sentences and left the key that says "I already said this",
  so `/cn why` lost the group-shared line, the "you are dead" line and the
  instance line after one rebuild â€” while the multipliers they described kept
  applying.
- **`/cn goal` did nothing to a quest already in your log, and `/cn ungoal`
  left its weighting behind.** Pinning changes the weight of a row without
  changing the row, so a provider that had not rebuilt took the
  unchanged-provider shortcut and the goals decorator never ran. Both
  persisted until that provider's list happened to change â€” which, standing at
  a vendor managing your goal list, is never.
- **A provider's row is never written into by the aggregate.** Two providers
  that know the same objective would raise the winner's value in place, with
  no way back: unpin a goal and the quest kept the pinned-era value for the
  session. Worse, the raised value then differed from the fresh one on every
  pass, so that provider could never take the unchanged-provider shortcut
  again â€” one shipped provider was measured rebuilding on 31 of 31 passes
  while the player stood still.
- **The Warband bank forgot every tab but one after each reload.** The
  per-container record 0.56.0 added lived in memory only, so the first time
  you opened a bank in a new session it threw away everything on disk except
  the tab the client happened to be describing â€” and reported the remains as
  freshly scanned. The record is per container on disk now, and "seen Nh ago"
  is the age of the stalest part of it rather than of the newest.
- **Data the addon refused to destroy stopped being mentioned one login
  later.** The refusal was recorded, the data was set aside â€” and the next
  login found the empty space where it had been, succeeded, and cleared the
  record. `/cn rescued` shows what is there and discards it when you say so;
  until then `/cn navdiag` and `/cn selftest` both keep saying it exists.

### Changed

- **"I don't know where it is" no longer beats "I can see it from here".** An
  objective with no coordinates was charged 3 for the journey; the far side of
  your own zone costs about 3.3. Measured on a real collection: twenty of the
  top thirty recommendations had no location at all. Two states are now
  distinguished â€” a currency or a reputation is not *anywhere*, so there is no
  journey to charge for, while a quest whose coordinates have not resolved is
  somewhere the addon cannot name and is charged the pessimistic figure, the
  same way an uncostable journey already was.

### Performance

Every figure below is measured, at a realistic scale: 300 candidates, a full
quest log, 160 located objectives in one zone, a 59-node flight network.

- **Routing a zone re-ranked the entire addon, every time, whether anything
  had moved or not.** The Zone tab refreshes every two seconds, the map does
  it on every open, and follow mode does it every three â€” so the ranked list
  had a hit rate of **zero** for as long as any of those was open. Thirty
  ticks produced thirty full re-ranks, 4,590 scorings and no hub changes.
  1.34ms per tick, returned.
- **The ranked sort built two strings per comparison**, and ties are the
  common case rather than the edge case â€” 134 of 153 candidates share a score
  with an earlier one. 943 comparisons per sort, 1,886 strings: 0.35ms and
  4.1KB per re-rank, down to 0.12ms.
- **One bag update cost 1,022 client calls**, 144 of them exact duplicates:
  the scan asked whether each slot starts a quest and threw the answer away,
  then asked again. What an item *is* â€” a mount, a pet, a toy â€” is a property
  of the item and was re-asked per slot, so a 40-slot stack of one reagent
  asked forty times.
- **The route optimiser** now works from flat coordinate arrays with
  don't-look bits: 3.70ms to 3.11ms at ninety stops, exactly the same route.
- **The clustering grid** builds numeric cell keys instead of 1,600 strings:
  0.63ms to 0.20ms.
- **The journey search** reuses its three per-node buffers instead of
  allocating 8.3KB per call, and the costing cache stopped allocating a
  closure before its own lookup.
- **The client is asked where you are once a frame**, not twenty-three times
  per rebuild â€” each of which allocated a vector in the client. The *map* is
  still asked every time, because walking into a building changes it without
  you moving.
- **The Remaining tab recounted three thousand achievement rows and eighteen
  hundred pets every two seconds** for numbers that change only when you
  collect something. Cached behind the events that announce a collection.
- **Learned task durations** are no longer re-sorted once per candidate.

### Internal

- Four of the eleven performance budgets could not fail: two measured the
  cached branch of the path they were guarding, and two fed the route
  optimiser a fixture a quarter the size of a real zone. All four now measure
  what a player triggers.
- A build-time check that nothing outside `Scoring.lua` writes into a reason
  list.
- Fifteen new mutations and eleven new assertions. Mutation score: 142 of 142.


## [0.56.0]

An adversarial review of everything 0.55.0 changed, a pass over the words the
addon puts in front of you, and two features from the backlog. Four of the
defects below were introduced by the release that was supposed to make things
correct, and are named as such.

### Added

- **Work your group shares ranks higher.** The addon has known you are in a
  group since 0.44.0 and used it for exactly one thing: pushing solo detours
  down while you are in a dungeon. Four people standing in a zone and one of
  the six quests on the list is one all four are carrying â€” that one is worth
  four times the work, every player already knows it, and the addon had the
  information and said nothing. It reads your own client about people already
  in your group, so nothing is sent, no other machine has to be running this
  addon, and outside a group it says nothing at all. `/cn why` names the
  count.
- **The Warband bank.** The account-wide bank tabs were never read. They are
  now, as a **separate** store from your character's own bank, because the two
  are different claims: one is reachable by this character, the other by every
  character on the account, and reachability is the addon's whole subject.
- **Every empty tab says what would fill it.** A tab with nothing to show drew
  literally nothing â€” a one-line header above 380 pixels of void, which reads
  as broken rather than as empty. Each one now names the step that fills it.
- **Sixteen more buttons have tooltips**, including "Re-route", "Refresh" and
  "Next step" â€” the three whose labels say least about what they do.

### Fixed

- **A pinned goal's weighting compounded on every rebuild, without bound.**
  The goals decorator read its own field and added eight to it â€” harmless
  while every rebuild produced fresh objects, and not harmless since 0.55.0
  started reusing them. After twenty quest turn-ins a pinned goal outweighed
  everything else on the list by thirty to one, `/cn next` returned it and
  nothing could displace it â€” including something about to despawn â€” and
  `/cn breakdown` showed the inflated figure as though it were deliberate.
  Only a reload cleared it. Unpinning now gives the weight back too, which it
  never did.
- **The first rebuild after a decoration deleted every explanation on an
  objective, permanently.** Rolling the reason list back to what the provider
  said is right; leaving the bookkeeping that says "I already said this" in
  place is not, because nothing could then say it again. The multipliers those
  sentences described went on applying, so `/cn why` printed a score with
  nothing under it. The new group-shared line was the most visible casualty:
  it appeared for exactly one rebuild.
- **A sentence carrying a number froze at the first number.** Three party
  members leaving one at a time left "3 others here are on this quest" on
  screen while the ranking tracked the truth.
- **Every learned task duration was collapsing to a twentieth of a second.**
  A journey estimate saturates at exactly 1200 seconds; 0.55.0 rejected any
  span over exactly 1200 as implausible. The window in which a far-away
  objective could produce anything but the floor was arithmetically empty, so
  every cross-zone completion stored 0.05s, the median settled at 0.05s, and
  `/cn plan` reported a zone as four minutes of work â€” confidently, because
  0.05 is not nil. An estimate the model will not stand behind is no longer
  subtracted at all, and the floor is gated on the measured span rather than
  on the estimate.
- **A quest two providers knew about accumulated every state it had ever been
  in.** The merge of one provider's reasons onto another's rows was harmless
  only by accident: the comparison that decides "this provider returned the
  same rows" always failed, so the merged set was rebuilt every pass.
  Repairing that comparison in 0.55.0 made the union permanent, and `/cn why`
  printed "available to pick up", "quest is ACTIVE" and "ready to turn in"
  about the same quest, at the same time.
- **The journey estimate was frozen at the first sighting.** It was stamped
  once, from wherever the addon thought you were when the objective first
  appeared on the list, and never revised â€” so an objective you flew to and
  finished was measured against a cost from the continent you left, and
  discarded. It is re-costed as you close on it now; the clock is not, because
  that is the measurement.
- **The dedup raised the winner's value into its live row and could not let
  go.** Unpin a goal and the quest kept the pinned-era value for the rest of
  the session, and the losing provider could stop emitting the row entirely
  with the number still there.
- **Saying the unlock count changed did not make anything recompute it.** The
  guard added for this was correct and unreachable: the decorator only
  consults it when a provider re-decorates, which the unchanged-provider
  shortcut skips, which is the normal case.
- **The Warband bank ended up holding whichever tab you looked at last.** The
  client does not describe a bank tab until it has been switched to, and the
  scan rewrote the whole store from what it could see â€” so moving one item at
  the bank rewrote both banks from whatever happened to be visible.
- **The shared-quest count asked the client once per candidate per ranking
  pass.** Measured at 8,151 client calls and 7.2ms for one pass in a
  forty-person raid, against a 0.4ms budget â€” the cache was keyed on the very
  thing that triggers a re-rank, so it was cleared exactly when it would have
  been used.
- **A quest's unlock count froze for the session** â€” on the second-heaviest
  term in the ranking, with `/cn why` stating a number the addon knew was
  wrong. Same cause: rows are reused now, and the decorator's "already set,
  leave it" guard made the first answer permanent.
- **A caching provider's rows collected a decorator's sentence once per
  rebuild.** The boundary between "what the provider said" and "what the addon
  added" was recorded blindly, so it crept upward every pass.
- **`/cn keepfilter off` did not clear the filter it was turning off.** The
  command looked the window up by the wrong name, so the branch never ran â€” it
  printed "a filter that persists invisibly is how a list looks empty when it
  is not" while leaving exactly that filter in memory. The checkbox in the
  window always worked.
- **`/cn help <word>` did not search aliases.** The worked example in the
  code's own comment â€” half-remembering "the one about lockouts" â€” was the
  exact query that returned nothing, because `lockouts` is an alias. Forty-nine
  aliases were invisible to the search.
- **A deferred objective could not be individually restored.** `/cn hidden`
  printed the time left and not the id, and `/cn unhide` matches on the id.
- **A corrupt character table was silently replaced with an empty one** â€” every
  character profile destroyed, version advanced, clean bill of health reported.
- **The harvest sorted its entire store on every captured quest** once at the
  ceiling, inside a loop over your whole quest log at login.
- **Rebuilding the tab strip could move you off the tab you were reading** and
  discard what you had typed in the search box.
- **A quest data provider that re-registers keeps its place in the queue**
  rather than dropping to the back of its priority band and silently handing
  over which addon answers first.

### Changed

- **The addon's internal vocabulary stopped reaching you.** `State:
  REQUIRES_OTHER_CHARACTER` now reads "another character has to do this". The
  Zone tab's header said "3 collectible, 2 exploration, 7 quest" â€” the type
  enum, lowercased, with the wrong plural. "No eligibility checker registered
  for CURRENCY" named a registry you have never heard of. "The Mounts module
  is not loaded" named a file.
- **The ranking weight and the focus stopped sharing a name.** `/cn mode` said
  "Focus: Collecting" and `/cn order` said "Focus: collections" about two
  different settings in the same session.
- **The first-run screen describes the focuses the same way every other
  surface does.** It carried its own four descriptions, all of which had
  drifted â€” and one was wrong: it called Levelling "quests first, collections
  quiet" when Levelling hides seventeen of the nineteen types. Quiet and gone
  are not the same promise.
- **It also names the focus you picked**, rather than the internal key: the
  button marked "Reputation" answered "Focus: reputation", and "Levelling"
  answered "Focus: leveling".
- **`/cn list` explains an empty list** the way the other five surfaces that
  show one already did, instead of being a dead end.
- **The required first step is no longer printed in the disabled grey.**
- **One grammar for a number that is not a measurement.** "roughly X to Y" and
  "(searched on Normal)" were two more private dialects beside the convention
  built for exactly this. The build now fails on a new one.
- **One unit per quantity.** `/cn plan` said "Planning 45 minutes" and then
  "32m of the 45m you have", four lines apart.
- **Ignore and Defer name the way back**, and Defer says how long.
- **The window's geometry agrees between tabs**: one header size, one button
  baseline, one gap, one list inset. None of it is visible on one tab and all
  of it is visible when you click between them.

### Internal

- The offline harness can now model a group, a shared quest, and a Warband
  bank tab, so all three are asserted through the path the game takes.
- A build-time check that a number which is not a measurement is hedged in the
  addon's one convention rather than in a private phrasing.
- A migration that refuses to destroy data it cannot read is no longer undone
  by the defaults merge three lines later, which replaced the same value and
  erased the evidence.
- Twenty-five new mutations and nineteen new assertions. Mutation score: 134
  of 134.


## [0.55.0]

An adversarial review of everything 0.54.0 changed, plus the registry
contracts and the data the addon keeps about you. Four of the defects below
were shipped by the release that was supposed to make things faster, and are
named as such.

### Fixed

- **Learned durations were biased long, and said so confidently.** A
  completion faster than the addon's own travel estimate was clamped up to a
  floor of 0.05 seconds -- and then discarded by a test on the very next line
  that rejected anything at or below 0.05. Every sample the floor existed to
  preserve was thrown away, which is the precise bias the floor was written to
  remove. Every `/cn plan`, every hub estimate, every "this will take" line
  read long. The order of the two tests is now correct: reject the
  implausible span first, floor what survives.
- **Half the addon's subject matter was being demoted for the addon's own
  deafness.** Preference learning counted a "sighting" for every objective
  type but could only count an "action" for the five the client announces --
  quests, achievements, pets, mounts and toys. The other thirteen crossed the
  observation threshold with a numerator nailed to zero, settled permanently
  on the 0.80 penalty, and `/cn learned` reported "you rarely act on these" --
  a claim about the player that the addon had no way to make. Only types with
  a completion path are credited now; the rest are left alone, and the rows
  that could never have been earned are dropped on upgrade.
- **A zone whose size the client would not report became one stop.** The
  0.54.0 clustering grid compares squared distances against the hub radius in
  yards. When the map scale was unavailable the fallback left distances in map
  units, where the largest possible value is smaller than the radius squared
  by three orders of magnitude -- so every objective in the zone joined the
  first hub, with a batch bonus to match. The fallback is now the same
  2000-yard assumption the distance helper has always used, which also means
  `RouteLength` reports yards on that path instead of map units.
- **And the scale lookup could not tell a refusal from an answer.** The map
  scale helper returns `1, 1` when the client will not convert -- correct for
  the arrow, which uses only the ratio of the two, and useless for routing,
  which wants absolute yards. Routing validated it with "greater than zero",
  which `1` satisfies, so the fallback above could never fire for a real map
  during a loading screen -- the one situation it exists for. The helper now
  says whether its answer is a measurement.
- **The unchanged-provider shortcut was off for any provider a decorator had
  touched.** The comparison that decides "this provider returned the same
  rows" ran a freshly built list against the previously *decorated* one, so
  anything a decorator had added was present on one side and absent on the
  other and the comparison could only disagree. Measured at 0.2 ms per
  collect, every five seconds, for no change on screen.
- **A preference verdict was never withdrawn.** `/cn learned reset` reported
  "Forgotten. The ranking is back to its defaults." while `/cn why` went on
  printing "you rarely act on these" from the sentence stamped on cached
  objectives.
- **The clustering grid was inert on that same path**, so the optimisation it
  was written for -- one cell per hub radius -- degenerated to the quadratic
  scan it replaced.
- **`ADDON_LOADED` handlers were accepted and never called.** The event is in
  the registry and `RegisterEvent` takes a handler for it; the dispatcher
  returned before dispatching. Anything registered that way ran never.
- **A migration that failed part-way printed one line and carried on.** The
  saved data was then in neither the old shape nor the new one, and every
  later login retried the same step against data it had already partly
  rewritten. The failure is recorded now, and `/cn navdiag` and `/cn selftest`
  say which step failed and why before reporting on anything read from that
  data.
- **Migration 8 could produce a store nothing could read** -- a key with no
  colon whose value was not a table was copied straight across, mixing two
  incompatible row shapes in one table.

### Changed

- **What a quest unlocks is now measured.** `unlockValue` carries the
  second-heaviest weight in the scorer and had exactly one producer out of
  twenty-two: a flat 1 for an item that teaches something. Every quest,
  reputation, profession and dungeon contributed nothing to it, so the term
  printed 0.00 and ranked nothing. It now reads the prerequisite graph the
  addon already harvests from your own play, inverted: how many quests have
  been observed sitting behind this one. A quest nothing has been seen behind
  still scores zero -- nothing is invented.
- **The harvest store evicts what it has not seen, not what is oldest.** It
  dropped the lowest quest IDs, on the reasoning that a low ID is old content.
  That describes a max-level character; it describes the exact opposite of an
  alt levelling through classic zones, whose entire log is low IDs -- so the
  store threw away the records for the zone that character was standing in and
  kept the main's endgame chains.
- **Any registered waypoint provider can be chosen.** The registry was open
  and the selector was not: `/cn nav` matched three names hardcoded in the
  command, so a fourth provider could be used automatically and never picked
  deliberately. The command now offers what is actually registered.
- **The window reopens on the tab you left, by name.** It stored an array
  index into a list that is sorted and rebuilt whenever a tab registers, so
  adding a tab silently moved everybody's remembered position.
- **The arrival prompt can fire again.** It latched once per zone per session,
  so clearing a zone, crossing a continent and coming back four hours later to
  the quests you left behind was met with silence -- the moment it is most
  useful, and the one moment it could not fire. Two hours, and a deliberate
  rescan clears it.
- **The harvest store counts before it allocates.** Pruning built its sort
  array before checking whether there was anything to prune, on every single
  captured quest -- and quests are captured in a loop over the whole log at
  login.
- **Quest data providers sort deterministically.** The priority list was
  re-sorted on every registration with a comparator that does not break ties,
  so two third-party providers that omit a priority could swap places because
  a third one registered -- silently changing which of them supplies a quest's
  name or coordinates.

### Internal

- Quest data providers must supply both halves of their contract. A provider
  registered without `IsAvailable` was accepted and then silently reported
  unavailable for ever, because the call on nil happened inside a `pcall`.
  Registering twice replaces rather than duplicating the priority row.
- Captures must be named. The name is the key the result is filed under, so a
  nameless one threw inside the capture run and took every later capture with
  it; a duplicate name silently overwrote another capture's result.
- `/cn why` re-runs the score adjusters, because an adjuster's contribution is
  recorded nowhere else. That is safe only while adjusters are idempotent, so
  the suite now asserts it -- and the re-run is guarded, so an adjuster that
  throws no longer takes the explanation with it.
- The offline test harness can now model the client REFUSING to convert a map
  position -- a loading screen, an instance, a map with no world position.
  Every fallback path in routing and navigation was unreachable from the
  suite until this release, which is why one of them shipped broken.
- Sixteen new mutations and eighteen new assertions covering the above.
  Mutation score: 109 of 109.


## [0.54.0]

Three audits: what it costs, what it looks like, and what the first five
minutes are actually like. The largest release this project has had.

### Added

- **One palette.** There were sixteen colours across five hundred and
  forty-three inline codes -- five near-identical greys doing one job, three
  reds, two greens, two golds, and the brand blue in two different casings --
  plus three separate colour tables, none of which was the source of truth.
  There are now eight roles in one file, every call site goes through a
  wrapper, and the test suite fails on a colour that is not one of them. It
  also fails if two roles become indistinguishable, which is how the five
  greys happened.
- **A settings page instead of seven checkboxes.** Twenty-one settings existed
  and seven were reachable in the window. The fourteen that were not included
  **both accessibility controls** -- text size and the colourblind arrow
  labelling -- so the players who most need a larger interface were the least
  likely to find it, since the only way in was typing `/cn scale 1.4`.
  Everything is now grouped by subject, and every control has a tooltip
  saying what it does.
- **A sort control.** Three sort modes were written, tested, and reachable
  from nowhere: the comment said "cycled by clicking the header" and nothing
  called it.
- **`/cn why` with no arguments** explains the current recommendation, which
  is what the word means. It used to print a usage line, while the addon
  computed exactly that answer and threw it away after `/cn next`.
- **A prompt on arriving somewhere.** The addon has always counted how many
  quests a zone holds that you have not picked up, and kept it to itself until
  you typed `/cn zone`. Once per zone, above a threshold, never mid-fight.
- **Per-tab footers** naming the two or three commands that go deeper from
  *that* tab. The window's only route to a hundred and twenty-five commands
  was one line pointing at `/cn help`.

### Changed

- **`/cn` answers the question the addon exists for.** It printed a status
  dump -- version, mode, and a list of all forty-seven internal module names
  -- and the login banner told every new player to type it. So the front door,
  advertised in the addon's own first line of output, answered a question
  nobody asked in vocabulary nobody shares. The status is still there, under
  `/cn status`.
- **The addon's name appears once per answer, not once per line.** Every line
  carried "Completion Navigator: ", and this addon answers in blocks -- six
  lines for `/cn next`, twenty for `/cn help`. Twenty-two characters of chrome
  per line turned every answer into a wall of the addon's own name.
- **Goals and chases accept names.** The store page leads with `/cn chase rep
  2600` and nobody knows that 2600 is the Severed Threads. Six modules had a
  name resolver; the two commands most likely to be handed a name called
  `CN.ToID` and refused anything that was not already a number.
- **Setup knows which scans have run**, not merely whether one did. The single
  flag meant the login reminder told players nothing had been scanned while
  four subsystems had scanned themselves eight seconds earlier, the window's
  own scan button did not satisfy it, and it could not name what was missing.
- **Three commands renamed.** `/cn nearby` meant "not near you"; it is
  `/cn elsewhere` now. `/cn waiting` read as "waiting on a timer" and meant
  unpicked quests; it is `/cn unpicked`. `/cn show` is `/cn types`, which is
  what it filters. All three keep their old names as aliases.
- **The essentials list is ten commands, all of them day-one.** It was
  fifteen, four of which were not.
- **The Blizzard options panel is a settings surface**, not a placard listing
  six commands and omitting the one required step.
- **The welcome screen offers the scan.** It arrived at the one moment a new
  player is engaged and looking at the addon, and offered four flavour presets
  and no way to do the thing that matters.

### Fixed

- **The tab strip was drawn on top of the filter box.** In the default
  configuration, on every install, two of the eleven tabs sat underneath the
  search field and its label.
- **The selected tab was rendered as a disabled button** -- greyed text,
  dimmed art. In every interface anywhere, greyed means unavailable, so the
  tab you were looking at was the one that looked broken.
- **The route optimiser cost 33 milliseconds and several megabytes of garbage
  per call** at the size a busy zone produces, and it runs every two seconds
  while the Zone tab is open. It built a whole new route table for every pair
  of stops and measured both routes end to end, including the one that had not
  changed. Reversing a segment alters exactly two edges, so the comparison is
  four distances and the swap happens in place. Same routes, no allocation.
- **Clustering was quadratic with a module lookup inside the inner loop** --
  10.7 ms at a hundred and ten objectives, growing as the square. The map
  scale is asked for once and candidates are bucketed into a grid, so only the
  nine cells around one can decide the answer.
- **Every located objective re-costed its journey from scratch on every
  rebuild.** Those are now memoised on the destination and thrown away when
  you move more than twenty yards.
- **The flight network was rebuilt after every loading screen** -- about ten
  milliseconds, on top of a provider rebuild, at the moment the client is
  busiest. Flight points cannot appear during a loading screen; only talking
  to a flight master adds one.
- **One click of Ignore cost 2.2 ms on every rebuild after it.** The hide
  lists were keyed on a `"TYPE:id"` string and read twice per candidate, so
  using the feature once meant eight thousand string allocations per rebuild
  -- for exactly the players the feature exists for. Nested by type now, which
  is two hash lookups and no string. Database version 9.
- **A volatile provider returning an identical list re-ranked everything.**
  Seven providers expire on a five-second clock and most of the time return
  precisely the rows they returned before; each one forced a full re-score.
  Measured, 0.007 ms became 0.221 ms, every five seconds, for no change.
- **The zone router scored every candidate and then threw the scores away**,
  twice: nothing in the function read them, and it invalidated the ranking
  immediately afterwards.
- **The benchmark was measuring a corner, not a continent.** Its sixty flight
  points were clustered into one corner of the map so they would not change
  any test's answer -- which is exactly the geometry the search's pruning
  bound rejects unexamined. One origin of fifty-nine survived there against
  seventeen of sixty on a real network, so two travel budgets were reported at
  a fifth of their ceiling while a realistic network was over both. The
  benchmark now spreads them after the assertions have run.
- **Nothing the addon drew over the game world had an outline.** The arrow's
  distance readout -- the number you read *while running* -- the heads-up
  line, the follow frame and the map pin numbers were all bare text with a
  one-pixel shadow, which is enough over a dark panel and not enough over
  Northrend snow.
- **The heads-up line and the follow frame had no background at all**, while
  the window used a Blizzard template and the welcome screen used parchment.
  Three idioms, and two of them read as text that had come loose.
- **Route pins were one bright arrow and eleven identical grey ones.** They
  are a sequence now: same colour, fading back, so "where next" is answerable
  without reading a digit. The arrow texture is still an arrow, which means
  *direction*, not *place* -- that is a further release.
- **Three tabs built their columns with `%-16s` padding in a proportional
  font**, which is not a column. Values are right-aligned in their own slot,
  and progress is a texture rather than a row of equals signs whose pixel
  width changed as it filled.
- **The completion flourish fired on every stop past the end of a route.**
- **`Appearances` had no refresh path at all** -- no event, no login hook --
  so it was read once by `/cn setup` and silently rotted from there.
- **Reputation scope corrections apply**: writing a faction to one scope now
  clears the other.
- Smaller: the harvest store had no ceiling and kept a map name it can derive
  from a map id; the preference cache was keyed on a string it rebuilt on
  every call and on a generation that changed every two seconds; `YES` and
  `NO` were shouting; type badges were plural on single items; the window
  reopens on the tab you left it on.

### Testing

- 95 mutations killed, none surviving, up from 81.
- The test stubs forgot what they were told: `SetWidth`, `SetSize` and
  `SetShown` all fell through to a catch-all, so nothing the addon sized or
  showed could be asserted about -- and an unset field read back as a *table*
  rather than as nil, which is how `GetWidth() or 400` returned a table.
- Coverage held at 85% across a release that added a file.


## [0.53.0]

Multi-hop flight routing, and three audits: how state lives and dies, how the
addon behaves when the client refuses, and whether what it prints is true.

### Added

- **Flight routes go through the network instead of across it.** The flight
  leg of a journey was the straight-line distance between two flight points,
  which is the one distance a taxi never travels: the bird hops from master to
  master, and a pair at opposite ends of a continent is reached through the
  ones in between. Measuring the hypotenuse understated every long flight, and
  always in the same direction, so distant objectives were systematically
  preferred over near ones. Routes are now the shortest path through an
  inferred flight graph, `/cn travel` prints the chain leg by leg, and a
  multi-hop estimate is never reported as measured -- the edge list is a
  model, and it says so.
- **`/cn handynotes`** lists what HandyNotes plugins are drawing on your map.
  The function behind it has existed since 0.41.0 with no caller.
- **`/cn rareforget`** clears the rares this character is assumed to have
  cleared. See below for why that assumption needed an escape hatch.
- **`/cn help flat`** prints the ungrouped listing. `ShowFullHelp` was written,
  exported and called from nowhere.

### Fixed

- **Ignoring or deferring an objective did nothing until something else
  happened.** The ignore list is read inside candidate providers, at build
  time, so it was baked into the cached list -- and none of the four mutators
  invalidated anything. It looked like it worked because most providers rebuild
  on some event within seconds; for `Mounts`, which waits on a new mount, an
  ignore could go unhonoured for the rest of the session with the dismissed row
  still at the top of the list.
- **Riding past a rare marked it cleared, permanently.** A vignette leaves the
  client's list for two completely different reasons -- somebody killed it, or
  you rode out of range -- and the addon assumed the first, with no expiry and
  no undo. That character was then never offered that rare again. Clearing now
  needs corroboration (the client said it was dead, or it vanished from within
  150 yards) and expires at the weekly reset.
- **An alt was shown its main's quest progress.** `IsQuestFlaggedCompleted`
  answers for the character asking, and the answer was being written into an
  account-wide store: a main that ran `/cn scanquests` wrote four thousand of
  its own completions into a table every alt read as its own, and scanning on
  the alt destroyed the main's record. The store is gone -- the client answers
  this for free, per character. The remembered quest locations had the mirror
  defect: one character finishing a zone deleted the locations for every other
  character who still had it to do.
- **An achievement you just earned was recommended again.** The store row was
  deleted and the shortlist revision was not, so the provider rebuilt, got the
  cached shortlist back, and re-emitted the completed achievement -- where it
  stayed until something unrelated moved the revision.
- **"You are dead -- this is for after" outlived being dead.** Adjusters stamp
  a sentence explaining the score they returned, onto objectives that live in
  the cache long after the situation does, and appending was the only operation
  there was. `/cn why` told living players their recommendation was for later.
- **Two providers rebuilt six times more often than they asked to.** `volatile`
  was a peer of the dirty check rather than subordinate to the cooldown, so
  `Waiting` -- which walks the mail inbox, the bags, the heirlooms and the
  currency store -- and `Instances` each declared thirty seconds and got five.
- **A quiet session erased the record of a bad one.** The error log was written
  on every logout including when it was empty, so the exact sequence the
  feature exists for -- something breaks, the player reloads before thinking to
  look -- destroyed its own evidence.
- **The map still showed stops you had just hidden.** The pin cache was keyed
  on the candidate generation, and hiding an objective type deliberately does
  not move that. `/cn zone` and the map disagreed about the same route.
- **A pinned goal appeared twice and inflated its own hub.** Providers dedupe
  their own lists; the aggregate concatenated them. Two copies of one objective
  share a position exactly, so the route reported a hub of two for one real
  stop and paid a batching bonus for a batching that does not exist.
- **The HandyNotes integration could not work for anyone who has HandyNotes.**
  `IteratePlugins` returns a `pairs`-style triplet and the addon captured only
  the first value, which throws. The test stub was a single closure -- the one
  shape under which the broken form works.
- **The Adventure Guide was asked with the wrong id.** `GetSavedInstanceInfo`
  returns the lockout id in slot 2 and the journal's instance id in slot 14;
  the addon stored the first and handed it to the journal, so "which bosses are
  left" always answered that there was no boss list. The fixture had journal
  ids in slot 2, so the stub and the code shared one wrong belief.
- **Your Pet Journal filters were reset every thirty seconds.** The file's own
  comment said the source and type checks were widened "only if the scan would
  otherwise see nothing"; the code did it on every scan, and the pet scan runs
  on a timer. Neither checkbox has a getter, so it could not be undone. It now
  happens only when the journal genuinely reports nothing, and says so out loud
  when it does. The Toy Box had the same defect.
- **"Waypoint set" was printed whether or not one was.** The provider's answer
  was discarded and `true` returned unconditionally -- on maps the client
  refuses waypoints on, with TomTom absent, and whenever the client would not
  build a map point. `C_Map.CanSetUserWaypointOnMap` exists to say which maps
  refuse and was called nowhere in the addon.
- **Clearing waypoints deleted pins you placed by hand.** There is exactly one
  user waypoint and it is the player's unless this addon set it; `/cn clearway`
  and stopping follow mode both removed it unconditionally.
- **Currencies under a collapsed header were invisible.** The list counts only
  rows under expanded headers, exactly like the reputation list -- which the
  addon has handled since 0.30.0. Collapse your profession group, which most
  people have, and every currency under it vanished from `/cn currencies`,
  `/cn clock` and the weekly-cap warnings.
- **One collapsed reputation header collapsed them all.** Captured under
  `factionID or index` and restored on `factionID` alone; headers carry
  factionID 0, so they all collided.
- **`/cn setup` recorded success when every scan had failed**, which stopped the
  login reminder and made `/cn setup check` answer that everything was scanned.
  A module that threw was also reported with the word "unavailable" -- a defect
  presented as a missing feature.
- **A repeating timer that threw produced a repeating error box.** Five
  callbacks -- the auto-advance ticker, the session observer, follow mode's
  tick, the world map hooks and the broker's click and tooltip -- were
  unguarded. The broker's ran inside the host bar addon.
- **`/cn next` told new players the addon was quests-only.** A leftover from an
  early build, printed on the most likely first thing anyone sees, and false
  since the second release. All four empty-state messages now come from one
  explanation that can also distinguish "nothing to do" from "the engine
  threw" -- which previously looked identical.
- **`/cn where am i` could not be typed.** The dispatcher splits on the first
  space, so a registered, documented, multi-word command was unreachable.
- **`/cn zones` ran a different command than its help text described.** It was
  registered as a command and, further down the same file, as an alias of
  `/cn loremaster`; the alias loaded later and won. Registration now records
  collisions and the test suite fails on them.
- **The welcome window's "a bit of everything" set nothing** while printing
  that it had -- and left every type hidden if a focus was already active.
- **Three of the ten "weighting only" modes silently applied filters**, because
  they exist in both tables and the preset is tried first. `/cn mode profile
  <name>` now asks for the weighting alone.
- **An unknown expiry was printed as "expired"**, so a live world quest sat at
  the bottom of a list headed "soonest to expire", labelled expired.
- **An imported quest chain was reported as observed on zero characters.** The
  edges carried no origin, so the eligibility line asked the harvest store --
  which has no record of an imported quest -- and printed the zero as evidence.
- **The exploration percentage was computed against the addon's own scan** and
  read as the world. The module's header says a real one is uncomputable; the
  code printed one anyway. The counts remain.
- **Raw enums were shown where a label belongs** -- `(ACHIEVEMENT)` in `/cn
  next`, and `MOUNT` as the broker's name in Titan Panel and ElvUI.
- **The follow-mode completion flourish fired on every stop past the end.**
- **`CN.Guard` changed the arity of what it wrapped**, truncating at a trailing
  nil.
- **The bearing shim had no callers.** `CN.Mod` is documented as the mandatory
  floored modulo and the one place that wraps an angle used two unbounded
  `while` loops instead.
- Nine smaller corrections: a fabricated battle-pet denominator, a hardcoded
  English string two lines from its own translation, `/cn order` clamping
  silently, a help entry that printed nothing, `/cn who` promising name
  resolution for four types and supporting two, `/cn percharacter` listing four
  of six overridable settings, a durations formatter rendering twenty-five
  seconds as "0m", two error messages naming commands that cannot do what the
  message says, and an inert `enabled` setting nothing had ever read.

### Changed

- **Persistence pruned again.** The quest-status store is gone entirely (the
  client answers it for free), the harvest store no longer keeps a map name it
  can derive from a map id, and it has a ceiling for the first time -- it was
  the largest thing the addon saved and the only large store with no bound.
  Database version 8.
- **Reputation scope corrections apply.** Writing a faction to one scope now
  clears the other, so a faction Blizzard moves between account-wide and
  character-specific cannot leave a stale row winning forever.
- The `/cn locale` report now says what it is a report about: the recurring
  strings routed through the locale table, not every line the addon prints.
- The Collections tab says its percentages are of the last scan.
- `/cn warband` puts its caveat on the number rather than only on the
  one-character case.

### Testing

- 81 mutations killed, none surviving, up from 67.
- Coverage floor raised from 82% to 85%, closing a backlog item open since
  0.31.0. `Alts` went from 49.6% to 73.5%; the TomTom and HandyNotes providers,
  the key bindings, the minimap button and the whole window rebuilt with every
  Blizzard template retired are now exercised.
- The fixture audit no longer prints a count that reads as coverage when three
  of its seven rules were skipped for want of a recording. It names them.
- The API-surface extractor no longer harvests example code out of comments,
  which had made one of those rules permanently unpassable.
- The stubs for the currency list, the reputation headers, the pet and toy
  filters, the user waypoint, the saved-instance tuple and the HandyNotes
  iterator were all more forgiving than the client. They are not now.


## [0.52.0]

The backlog, reconciled item by item against the shipped code rather than
against its own status tags -- and then the buildable half of what that
reconciliation found still outstanding.

### Fixed

- **Nine languages were shipping English for strings that had already been
  translated.** Forty-six strings were carried in ten locale files and only
  seventeen were ever looked up. The arrow's own words -- *ahead*, *veer*,
  *turn*, *back* -- were printed as English literals, and so were "Stop 3 of 8
  cleared", "Route complete.", the confidence qualifier that wraps every
  uncertain number in the addon, and the situation line. Thirteen more had no
  display anywhere at all: translated into ten languages, passing every lint,
  appearing on no screen.
  
  The existing lint only ever asked whether a translation matched a key and
  whether a key had a translation. Neither question is *does anything show
  this*. It is asked now, and the build fails on a string nothing displays.
  The thirteen orphans have been removed rather than kept, because a list of
  translated strings is a claim about what has been translated, and one that
  counts strings nobody sees makes that claim false in the direction that
  flatters it.

### Added

- **A ghost is pointed at their body.** The addon has recognised death since
  0.43.0, ranked everything else down for it, and printed *"your body first"*
  -- while being unable to say where the body is. The client answers that
  directly and was never asked. The corpse is now an ordinary recommendation,
  so the arrow, the map pin, `/cn go` and the heads-up display all pick it up
  without any of them needing to know what a corpse is; it keeps its full
  weight while everything else is ranked down, and no display filter can hide
  it.
- **A non-mage can be told how long another continent takes.** A
  cross-continent journey can only be costed through a teleport whose landing
  place is known, and eight of the fourteen the addon tracks carried none --
  including the hearthstone, which everybody has. Five of those eight had no
  destination for no better reason than that nobody had filled it in.
  Costable teleports go from six to eleven; the remaining three say why they
  cannot be pinned rather than being given a plausible-looking false landing.
- **The colourblind mode now changes the colours.** It added a word beside the
  arrow -- which satisfies "no information carried by colour alone" and left
  the palette exactly as unusable as it was. Gold against red is the worst
  pair there is for the commonest form of colour blindness, and it was
  carrying *drifting* against *walking away*: the one distinction the arrow
  exists to make. The alternate palette separates by lightness as well as
  hue, and the build checks the separation rather than trusting the eye.
- **`/cn cues` fires at the two moments it was written for.** It was described
  as sound and a flash when a route finishes, and that is all it did -- while
  the moments a player actually wants marked are the smaller ones: arriving
  somewhere, and clearing a stop. All three now, quieter for the small ones.
- **`TRANSLATING.md`**, and a line in `/cn locale export` saying where to send
  the block. The tool half of that workflow has existed since 0.39.0 and the
  return path was written down nowhere, so a translator finished the work and
  then had to guess -- which is where most people stop.
- **`cn.ps1 provenance` names the rows worth checking** instead of counting
  them and telling you to go and look.

### Changed

- **A curated turn-in location now beats the client's moving waypoint** for a
  quest that is ready to hand in. The lookup was written when the three-phase
  quest model was designed -- *"a quest is a pick up, a do, and a turn in"* --
  and was called by nothing, so the third phase, the one the design rests on,
  has always used a waypoint that points at whatever the quest currently wants
  rather than at the person who takes it back.
- **A drop's difficulty is no longer stated as though it were the drop's.**
  The label came from the Encounter Journal's *currently selected* difficulty
  -- a window the player may have opened once and left on Normal -- so a
  Mythic-only mount was confidently labelled Normal. The client offers no
  per-item difficulty, so it now says what was actually searched.

### Not done, and why

Multi-hop flight routing is a day's work through the code path two previous
releases' performance and correctness guards both sit on, and is the right
first thing for the next release rather than a rushed addition to this one.
Reading the Warband bank cannot be verified against a real container list from
here. A cross-tab search is a decision the author declined in writing and it
stays declined until he says otherwise. Screenshots for the store page, the
in-game arrow verification, the Wago project id and the curated quest data all
need a live client or an account this build cannot reach.

## [0.51.0]

An audit of **whether the numbers are right** -- not whether the code runs,
but whether the answers it gives are true. Fourteen findings. A confidently
wrong number is worse than no number, and several of these were confidently
wrong in the direction that made the addon's advice actively bad.

### Fixed

- **A focus made the thing you asked for rank LOWER, as soon as it was more
  than a few minutes away.** Everything went into one running total which was
  then multiplied -- and that total crosses zero, because travel is weighted
  against a cost reaching 40 while what finishing something is worth tops out
  around 8. Multiplying a negative number by 2.0 pushes it down. `/cn mode
  quests` ranked a distant quest **twenty-seven points below a distant pet**.
  The learned preference inverted the same way, promoting exactly the types it
  had decided you avoid. Worth and cost are now kept apart: a focus doubles
  what a thing is worth to you, and cannot reverse the sign of anything.
- **Every task time the addon learned contained the journey, which the planner
  then added again** -- once per objective at a stop, which is worst precisely
  where the router is trying to reward grouping work together. Four quests six
  minutes apart came out at **thirty-six minutes against a true twelve**,
  reported as confident. Learned times are now the work itself.
- **"Running the whole way" was costed at whatever speed you happened to be
  moving.** Asked while flying, it divided by your skyriding speed: a
  twenty-one thousand yard journey was quoted at **six minutes, labelled
  `run`, marked confident**, where the truth on foot is fifty. It also made
  the self-flown option unreachable while airborne -- the same divisor plus
  six seconds of takeoff can never win.
- **Another continent scored as CHEAPER to reach than the far side of the zone
  you are standing in.** The fallback for a journey the addon cannot model was
  25 while a journey it can model saturates at 40 -- so "I have no idea how to
  get there" outranked a quest two minutes away by fifteen points, nearly
  twice the entire range of what finishing something is worth. Vendors and
  toys were charged a flat 25 for the next zone while holding the seller's
  exact coordinates; they are costed properly now.
- **A player who did everything they were shown was told they do nothing.**
  Quests are counted under both their type and a campaign/side sub-bucket; the
  showing side incremented both and the completion side credited only the
  type. The sub-buckets collected sightings and never a single action, drifted
  to the floor multiplier -- and the ranking prefers the sub-bucket. Measured:
  120 quests offered, 120 turned in, `/cn learned` reporting **"0 of 60 acted
  on, x0.80, you rarely act on these."**
- **A reputation bar showed 100% for a goal half done.** Progress was reported
  inside the current rank and presented as progress toward the goal, so
  somebody at 21,000 of the 42,000 the ladder needs -- but one point from the
  top of Honored -- got a full bar. It also decided the order of `/cn chase`.
  The band is now reported as a count with the rank named, and no denominator
  is invented for the ladder, which is the rule this addon applies everywhere
  else.
- **A hundred-quest zone grind was advertised as a one-step job.** The client
  reports "complete 100 quests in X" as ONE criterion carrying a quantity;
  counting rows gave 0 of 1, so it was filed as "not started, 1 to do", sorted
  to the front of `/cn zones` as the smallest job available, and given the
  bonus for a small remainder.
- **`/cn travel` printed legs that did not sum to its own total.** The
  preference for a flight path you have flown before was applied to the
  duration rather than to the comparison, so the headline was ten percent
  short of the model's own arithmetic -- and that shortened number flowed into
  scoring and into `/cn plan`'s budget. Every player has flown somewhere, so
  this was the ordinary case.
- **"Stop 9 of 8 cleared."** The route is rebuilt from live candidates as you
  go, so it grows when you accept quests -- against a total frozen when you
  started. The completion moment fired at stop 8 and then again at 9, 10 and
  11 while stops remained, and the heads-up display stuck on "stop 8 of 8" for
  the rest of the session.
- **One nil answer from the client wiped your quest count for the day.** The
  two branches computing the day key returned numbers on different scales -- a
  day index of about 20,687 and a calendar number of 20,260,822 -- so a single
  miss during a loading screen read as a day rollover.
- **`/cn plan` justified its confidence with evidence from the wrong bucket**,
  citing forty-six speed samples for a flying median that came from six of
  them.
- **`/cn plan 5` would print "1 stop, about 45m"** with nothing saying the
  budget had been blown ninefold: the first stop was admitted unconditionally.
  It is still shown -- there may be nothing smaller -- and now it says so.

## [0.50.0]

An audit of **sequences** rather than files: login to logout to login again,
state machines entered and left, events arriving in the order the game sends
them. Ten findings, and the previous three audits could not have found any of
them by reading one file at a time.

### Fixed

- **The addon threw a Lua error into your chat frame on every login, and has
  never appeared in the game's own options list.** The registration reads
  `Settings.RegisterCanvasLayoutCategory` -- the client's options API since
  Dragonflight -- and `Settings` was also the name of a file-local function
  two hundred lines above it, so it indexed a function and threw. The error
  was caught and printed; because it aborted the function, the older fallback
  never ran either, which is why the addon has never been in that list at all.
  The test harness did not define the client's options API, so the guard
  short-circuited before the bad line. Same shape as the invented event name
  in 0.46.0: a stub more forgiving than the client.
- **`/cn why` repeated itself, more each time.** Scoring runs repeatedly over
  the same cached objectives, and adjusters appended their explanation on
  every pass -- one objective was measured carrying **sixty-two** reasons
  after thirty rounds of ordinary play, printing the same sentence sixty times
  over. This is the identical defect recorded as fixed for decorators; that
  fix was applied to decorators and nobody looked at the adjuster path, which
  runs far more often.
- **`/cn setup` told you it had scanned your mounts, toys, appearances and
  professions, and the recommendation could not see any of it.** Four of the
  eleven scans rewrote their store and left their own provider serving a cache
  built before the scan -- stale until a zone change, a level-up or the next
  login, which is exactly the first five minutes of a new install. The suite
  asserted the bug was correct: *"a mount scan must not rebuild candidate
  providers"*, true when mounts fed only the Collections tab and false from
  the day they became a source of recommendations.
- **Three of the six per-character settings could not be set by any input** --
  including `priorityMode`, the example the feature was built around. The
  command lowercased what you typed and looked it up in a table with camelCase
  keys, so it rejected the exact spelling its own help line prints.
- **`/cn mode fastest` still had an inert second lever.** 0.48.0 wired the
  learned-duration term and got two things wrong in one edit: the producer was
  registered as taking a list where the addon hands over one objective, and
  the whole block landed *inside* another function -- so it existed only as a
  side effect of calling that one, and re-registered itself on every call.
  Fifty-seven copies of the same producer in one session, none of which set
  the field. The suite hand-built objectives with the value already in them,
  testing the consumer against a fixture the producer never made.
- **`/cn mode off` with no focus set silently deleted your `/cn show`
  filters** while printing that it had restored them. Hidden types are saved
  to disk, so the loss was permanent. It now says nothing changed, because
  nothing did.
- **`/cn follow off` left the arrow on screen** pointing at a route nobody was
  walking, along with the map waypoint, the map pin and the navigation ticker
  -- it hid its own frame and cancelled its own timer and stopped there. It
  also left a combat deferral armed, which fired into the next quiet moment of
  a session that was no longer following anything.
- **Follow mode rebuilt the entire zone route on every quest-log update**
  whenever nothing routable was near you -- a capital city, a dungeon, a
  battleground, a flight. Measured: twenty events cost twenty full route
  builds with a 2-opt pass each, where a live stop costs zero.
- **Follow mode resumed at login never showed progress.** The route length was
  counted only when the command was typed, and at login the map API has not
  answered yet -- so every "Stop 3 of 8 cleared" degraded to a bare "Stop
  cleared" and the completion moment was unreachable for the entire session.
- **A goal pinned before the matching scan kept its placeholder name
  forever** -- "Currency 3008" in the goal list, in `/cn chase`, and after
  every future login, even once the client could name it. `/cn chase` pins
  automatically, so this needed no unusual sequence at all.

## [0.49.0]

A third end-to-end audit, over the subsystems the first two did not reach.
Twenty findings. **Six of them were whole features that had never once run**
-- written, documented at length, shipped, and silently off, in every case
because the failure was indistinguishable from an empty result.

Plus the thing that made the last four releases painful: the release workflow
now runs *here*, before a tag is cut.

### Fixed

- **Dungeon and raid lockouts have never produced a single recommendation.**
  The client reports the number of bosses and then how many you have killed;
  the addon read those two the other way round. A raid six bosses into eight
  came back as eight of six, so "remaining" clamped to zero, the lockout
  looked cleared, and the provider returned nothing. This module exists on the
  premise that a part-finished lockout is the cheapest progress in the game --
  spent effort with an expiry on it -- and it has never offered one. The test
  fixture had the same reversal written into its own comment, so the suite
  agreed with the bug.
- **Weekly profession knowledge has never appeared in `/cn clock`.** The
  lookup guarded on a function that does not exist and never has, so it
  returned an empty list on every client -- for the thing the file's own
  header calls "the most permanently missable in modern professions". An empty
  list and a list that cannot be built look identical from outside.
- **The addon was resetting your pet journal and toy box filters and not
  putting them back.** A scan has to widen the filters to see everything, and
  the comment above it has always said "and then put them back" -- it restored
  the search box and nothing else; the toy box restored nothing at all. Filter
  your journal to uncollected wild pets, run `/cn setup` once, and it was
  silently reset to show everything, permanently, with no message. That is the
  addon changing a setting you chose, which this project's standing rule
  forbids outright.
- **Your currencies have never been recorded.** The row the client returns for
  the currency list carries no id -- it has to be read from the row's link --
  and the addon read a field that is not there. Every row was dropped,
  `/cn currencies` has always said "no currency data yet", and the currency
  provider has always been empty. The stub returned rows that *did* carry the
  field, which is the ninth time in this project a stub and the code have
  shared one wrong belief.
- **A Warband currency capped on one character was still recommended on every
  other one** -- the exact mistake the Warband work exists to prevent, and
  which 0.43.0 recorded as fixed. The flag was read from the client correctly,
  stored correctly, and then dropped by the one function that builds the rows
  the provider reads.
- **The LibDataBroker feed was frozen at login.** Its refresh had exactly one
  caller, inside its own installer, which runs before the collection scans
  have populated anything -- so it was built from an empty database, settled
  on "nothing actionable", and never changed again for the rest of the
  session. It now updates whenever the recommendation list does.
- **Recipe counts were discarded on every login**, so opening a profession
  window to record them and then logging out produced "(nil of nil recipes)".
- **`/cn mode off` did not undo the mode.** Switching focus twice overwrote
  the saved state with the *first* focus's state, so `off` restored a preset
  rather than what you had -- while printing that your previous filters were
  restored, and leaving no single command to get back.
- **Near-complete achievements all reported "0 achievement points."** The
  field stopped being stored in 0.36.0; two other readers were updated and
  this one was missed, where `or 0` turned an absent number into a confident
  false statement. Points are now read live, or not mentioned.
- **`/cn export` wrote the same key twice** for any quest with both a provider
  answer and observed agreement, so Lua kept the second and the curated list
  was destroyed on the way into shipped data. It also wrote inference under
  the name reserved for curated fact -- the door the runtime path had already
  closed, still open on the path that actually ships data to other players.
- **BtWQuests was reported unavailable to anyone whose version had moved its
  database.** The probe walked three possible locations with `ipairs`, and the
  first is nil in exactly the case the other two exist for. The two
  interpreters do not even agree on the length of such a list.
- **`/cn where` attributed machine-learned coordinates to you.** Two callers
  pass where a location came from; the function did not declare the parameter.
- **The first-run window appeared on the same tick as the setup reminder**,
  in the order its own comment says must not happen, and reappeared on every
  login for anyone who read it without clicking a button.
- Two more: an ATT merge that took the last answer where every neighbouring
  field takes the first, and a calendar deadline gated on an unrelated
  function -- which silently dropped the urgency weighting from every world
  event on any client lacking it.

### Changed

- **The release workflow's own steps now run before a tag is cut.** Four
  consecutive releases were tagged, pushed, reported as published and never
  reached CurseForge, each failing at a different step -- and every one of
  them was reproducible in seconds locally. What the local suite ran were
  *equivalents*: the linter against one directory, the harness against
  another. The workflow runs them against a scaffolded tree from the
  repository root, and that difference is where all four failures lived. The
  build now extracts each step from the workflow file and executes it, in a
  scaffolded tree, with the client recording in place -- eleven of the
  thirteen, the two skipped being the ones that need a real tag push.
- **Retrying a failed release is one word.** A release whose build fails
  leaves its tag behind, so the retry is refused -- which happened four times,
  each time answered by two git commands typed by hand from a message that had
  scrolled past. `release <version> -Retag` replaces the tag and cuts it again.
- **The goal-zone rule is worked out once per rebuild** instead of once per
  goal per candidate, where it was making thousands of client calls on the
  path a previous release restructured specifically to stop doing work per
  objective.
- Dead weight removed: an achievement-category table written on every scan and
  read by nothing, a field whose name meant the opposite of its contents, and
  two command aliases that a later module had already taken.

## [0.48.1]

**0.46.0, 0.47.0 and 0.48.0 were tagged, pushed, and never published.** The
build failed at a step before the packager on all three, and the release
command reported success anyway. No addon code changed in this release; the
release pipeline did.

### Fixed

- **Every client recording this toolkit has ever written was malformed Lua,
  so the stub audit had never once run.** `cn.ps1 fixtures` emitted `return `
  followed by the *interior* of the capture table -- no braces -- producing a
  file beginning `return` and then a bare `["worldPosition"] = {`. The block
  extractor returns interiors on purpose, which is right for its two other
  callers and wrong here.
  
  Nothing said so. The harness treated an unparseable recording exactly like
  an absent one, printed *"no recording present, stubs are UNVERIFIED"* and
  passed; `check` reported *"stub audit backed by a recording"* on the
  strength of a regular expression that found a version number in the text.
  Both statements were false for as long as the feature has existed. The
  recording is now written with its braces, `check` requires the file to
  actually load, and a test writes one through the real command and loads it.
- **The audit's own achievement rule named an achievement no fixture has**,
  so the first time it ever ran against real data it reported the stub as
  simpler than the client. The stub was correct; the rule was not. It survived
  because no recording had ever parsed, so the rule had never executed.
- **A string in the addon was never translated, and the check said so for
  four releases.** `Stop %d of %d cleared` -- the line follow mode shows when
  you finish a stop on a multi-stop route -- was added to the canonical string
  list in 0.45.0 and handed to no translator, so every non-English player has
  been seeing English there. `check` printed *"1 of 46 strings have no
  translation in any locale"* on every run since and it was scrolled past
  every time, because it was a note. **A note nobody acts on is not a check.**
  A string translated in NO locale now fails the build and is named in the
  output; partial coverage stays a note, because a string in six languages
  and not the seventh is ordinary work in progress. All ten locales now carry
  it.
- **The canonical string list repeated itself.** `ready` and `another zone`
  were each listed twice from 0.45.0, so the list claimed 48 entries for 46
  strings and every coverage figure reported against it was wrong -- including
  the note above. Duplicates now fail.
- **A recording that will not parse no longer reads as no recording at all.**
  The harness loads `fixtures/captured.lua` and treated "the file is missing"
  and "the file is broken" identically, so a corrupt one printed *"stubs are
  UNVERIFIED"* and the run went green. The strongest test in this project
  would have been silently absent while a file sat in the repository claiming
  to provide it. It is now a hard failure that names the parse error.
- **A stray file under `fixtures/` is now reported.** The toolkit writes
  exactly one recording, `captured.lua`. Anything else there was put in by
  hand, is read by nothing, and can look like broken addon source to any tool
  that walks the tree.
- **`## X-Wago-ID:` sat in the `.toc` with no value.** The packager reads that
  header to decide whether to publish to Wago, and a blank value is a value --
  it is being asked to upload to a project id of `""`. An absent header is
  understood; an empty one has to be interpreted. The line is gone, and any
  `X-` header present with no value now fails the check.
- **A captured client recording failed the build.** `cn.ps1 fixtures` writes
  `fixtures/captured.lua` -- evidence read only by the test harness, and the
  thing that makes the stub audit possible at all. It is a `.lua` file sitting
  in the repository, so the build step that verifies every Lua file is listed
  in the `.toc` reported it as missing and exited non-zero, before the
  packager ran. The failure began the moment the first recording was committed
  and repeated on every release after it.
- **Four separate lists decide what counts as addon source** -- the toolkit's
  file scanner, the build workflow's search, luacheck's exclusion list and the
  packager's ignore list -- and 0.47.0 taught only the first one about
  `fixtures/`. Fixing three of the four moved the failure from the `.toc` step
  to the Lint step rather than curing it, which is the same mistake a second
  time in the same hour. That is a fix
  applied to the instance somebody noticed instead of to the class, which is
  the same mistake this project's comments have described twice already. All
  three now agree, and a test scaffolds a tree with a recording in it and
  fails if any of them disagrees.
- **The recording would have shipped inside the addon.** The packager's ignore
  list did not mention `fixtures`, so a copy of one machine's client evidence
  was going into every player's AddOns folder. `mutate.sh` was going with it.
- **`cn.ps1 release` claimed an upload it cannot see.** It printed "Pushed
  vX. GitHub Actions packages and uploads to CurseForge" in green -- a
  statement about the future, formatted as an outcome. That line is why three
  failed releases were reported as live. It now says what it actually did:
  the push happened, nothing is published, and the build has to pass first.

## [0.48.0]

A second end-to-end audit, aimed at the parts 0.47.0 did not reach: the
scorer, the router, the planner and the caches. Twelve findings. Four of them
were features that had been silently off -- in one case since the release that
introduced them.

### Fixed

- **Measured flight speed never survived a reload.** The save routine wrote
  two of the three speed buckets and left out `flying`, while the load routine
  read all three. Since the travel model requires five flying samples before
  it will consider a self-flown route at all, every logout turned self-flying
  back off -- the feature 0.43.0 was built around, off for everyone, for five
  releases. The suite tested disk-to-memory for all three buckets and
  memory-to-disk for two, each against a fixture the other half never
  produced. Testing each half separately is not testing the round trip.
- **Five providers were subscribed to events nothing dispatched.** Providers
  declare which events invalidate them; the scorer held a separate
  hand-written list of the events it actually listened for. Nine declared
  events were on no such list -- and declaring an unwired event is *worse*
  than declaring none, because a provider that names events is skipped by any
  event it did not name. Orders and Inventory therefore never refreshed after
  login: **a quest-starting item you looted did not become a recommendation,
  and a crafting order you collected stayed on the list until you reloaded.**
  The scorer now subscribes to whatever the providers declare. There is one
  list.
- **Follow mode could stall on a finished stop.** Its cache of what is still
  actionable was keyed on a counter that only a rebuild advances -- and the
  cache returned early *before* triggering the rebuild. Once the two
  converged, nothing on that path ever rebuilt again, so the counter could
  never move and the cache never expired. It came unstuck only if some other
  part of the addon happened to rebuild. The guard was saving about two
  microseconds.
- **Routes were ordered as though every zone were square.** Ordering, the
  2-opt improvement pass and the reported route length all worked on raw map
  coordinates, which run 0 to 1 on both axes whatever the zone's real shape.
  In an ordinary 3000-by-1500-yard zone a stop 300 yards east compared as
  further away than one 165 yards north, and the optimiser then confidently
  improved a distance that was not the distance. **This is the same
  square-map assumption as the bearing defect of 0.40.0**, eight releases
  later, in the last file still making it -- while another function in that
  very file converted properly, so clustering and routing disagreed with each
  other.
- **Routing one zone left every objective in it scored as batched, forever.**
  The batch bonus is written onto live objectives at the end of a zone route
  and was never cleared, so it followed them into the ranked list and into
  every later zone. The ranking cache was not invalidated either, so
  `/cn next` served scores from before the batching that `/cn zone` was
  showing: two commands contradicting each other about the same objectives.
- **`/cn order` did not print the arithmetic `/cn next` had done.** It left
  out the focus multiplier and every registered adjustment, having promised in
  its own comment that "if the two ever disagree, this is wrong". In
  `/cn mode quests` it printed a headline of 6.0 above terms summing to 3.0.
  The test that was supposed to catch this checked one synthetic objective in
  the one mode where both omissions happen to be no-ops.
- **The session planner cherry-picked stops** out of a route ordered to
  minimise walking -- the thing the comment above it explains at length that
  it must not do -- and costed the stops after a skipped one from the wrong
  position. It now stops at the first stop that does not fit, and reports how
  much of the route is left rather than how many stops overran.
- **`/cn mode fastest` had only one of its two advertised levers.** The scoring
  term for how long something takes was declared, summed, printed and
  overridden by that mode -- and nothing had ever set it. The addon has been
  measuring how long each kind of objective takes you since 0.41.0; that is
  now wired to the term, scaled so a value of 1 means "about as long as things
  usually take", and an objective the addon has never timed still contributes
  nothing rather than a guess.
- **Three more scoring inputs that nothing produced** -- difficulty,
  prerequisites, and a second nearby term -- have been removed. Each was
  summed on every objective, listed in the documented formula and printed by
  `/cn order`, and contributed exactly zero to every score the addon has ever
  computed.
- **`/cn mode legacy` did nothing.** It was an empty profile, offered in the
  mode list and accepted by the command, behaviourally identical to balanced.
- **The harvest summary counted a field that a database migration deletes.**
  It reported zero inferred prerequisites on every database in existence,
  including databases full of them -- a reader that outlived its field by four
  schema versions.
- **Two contradictory comments in one function**, and a rules block that
  described the opposite of what the code below it did. In both cases the code
  was right; the prose has been corrected rather than the behaviour.
- **Five functions that nothing called** have been deleted, and the count of
  the rest is now printed and capped, so the number cannot quietly grow. Dead
  code in this addon has twice turned out to be a missing wire rather than
  untidiness.

## [0.47.0]

An end-to-end audit of the whole addon, run the way the last release taught:
assume the test suite is more forgiving than the game. Six defects, every one
of them invisible to a suite that otherwise passes eighty files, two
interpreters and thirty-seven mutations.

### Added

- **The addon now knows which client functions it calls, and can tell you
  which of them are gone.** 0.46.0 shipped an event name that does not exist;
  the client throws on those, so it announced itself. Client *functions* fail
  silently instead: every call site is guarded with `if C_Thing and
  C_Thing.Method`, which is correct, and which makes a renamed or misspelled
  name indistinguishable from a client that lacks the feature -- the guard
  goes false, the branch never runs, and the feature is dead for as long as
  nobody notices. The list of the 198 names this addon uses is now **generated
  from the source** at build time, `/cn selftest` reports any the client no
  longer has, and `/cn capture` records them for the offline suite to fail on.
  A hand-written list of what the code calls is a second copy of the code, so
  nobody writes this one.

### Fixed

- **The route search could return the second-best route.** The bound that lets
  it skip hopeless flight points was documented as exact "because every
  remaining term of the sum is positive". Every term is -- but the sum is then
  *multiplied* by a discount for a flight path you have actually flown, and a
  discount is not a term. A route up to a tenth cheaper than the bound
  predicted could be discarded unexamined. The test written to catch exactly
  this brute-forced the answer honestly and still missed it, because no flown
  routes had been recorded at that point in the run: the discount was never
  live while the comparison ran. It would have affected every player who has
  ever taken a flight path, and no fixture.
- **Nothing ever recorded whether a zone allows flying.** The store was
  written, commented at length -- *"remembering the answer per zone turns that
  guess into evidence"* -- and never filled, for four releases. So the check
  fell through to asking the client about **where you are standing**, which is
  precisely the guess the design replaced, and every self-flown estimate to
  another zone rested on it. It is now recorded on arrival, and flying
  somewhere is taken as proof that flying is allowed there.
- **A filter that follows you between tabs did not filter.** `/cn keepfilter`
  put the search term in the box and applied it to nothing on a tab's first
  visit, because the box was set before the tab's list existed. Its own help
  text warns that a filter you cannot see is how a list looks empty when it is
  not; what it produced was the same fault inverted -- a list that looks full
  when it is filtered. The function written to do this properly had never been
  called from anywhere.
- **A quest item is not an item the vendor will not buy.** The bag scan read
  `hasNoValue` -- "has no sell price" -- as though it meant "is a quest item",
  so every grey and every worthless token in your bags was flagged as one. The
  correct call was already being used forty lines away in the same file.
- **The refined preference counter kept the flat twenty-minute window** that
  0.46.0 replaced with per-type windows, so the two counters would have
  silently disagreed the moment a quest window was added.
- **One unguarded client call** in the provider file set whose entire purpose
  is that every client call goes through it, so that a patch break is a
  contained fix.
- **A second copy of a compatibility shim** was living outside the one file
  that gets audited for that class of mistake. There is one `CN.Unpack` again.
- **Eleven names in the static-analysis allowlist that the source no longer
  mentions.** An allowlist entry for something nothing calls weakens the only
  guarantee that file makes: that an undeclared global is a typo or a leak.
- **An infinite loop in the list widget, found by a new test.** It kept one
  piece of state on the frame while its neighbour had been moved off for the
  documented reason that reading an unset field on a frame is not guaranteed
  to give you nil. That is a fix applied to the instance somebody noticed
  rather than to the class, and the leftover hung the suite outright the first
  time a filter was set before any rows were.

## [0.46.0]

A release about speed, and about how this project keeps discovering that its
own test fixtures are smaller than the game. Three of the most expensive
things the addon does were invisible in every benchmark it has ever run,
because the fixtures behind them held three appearance sets, three bags of
items and three flight points. Measured at the size the game actually
produces, a cold rebuild cost **eleven and a half milliseconds** -- most of a
frame, on every event that invalidates the list.

It now costs **four**, with no answer changed.

### Changed

- **Costing a journey is twenty times cheaper.** The route search tries every
  pairing of flight points, deliberately -- the nearest one to you and the
  nearest one to your destination are frequently not the best route together.
  That is still exactly what it does. What it no longer does is recompute
  three distances inside every pairing: the walk at each end is measured once
  per flight point instead of once per pair, the flight legs between points
  are computed once per continent and kept until the list of points changes,
  and an origin whose walk alone already costs more than the best route found
  so far is abandoned without being examined. With a levelled character's
  sixty flight points on a continent, one estimate fell from **1.48 ms to
  0.04 ms**. Every objective that has a location pays this cost, so it
  multiplied by the whole candidate list.
- **Appearance sets are read once and kept until you collect one.** Scanning
  them was the single most expensive thing in the addon -- **4.4 ms**, more
  than every other source of recommendations added together -- and it ran on
  every rebuild. Collections change rarely and the client announces it when
  they do.
- **Your bags are read once and kept until they change.** Same shape, smaller
  number. The bank is deliberately kept separate: it is a different container
  list read at a different time, and serving one from the other's cache would
  report a bank you are not standing at.
- **How long the addon waits before deciding you took its advice** now depends
  on what the advice was. It was a flat twenty minutes for everything, which
  is roughly right for a quest and badly wrong at both ends: a dungeon takes
  most of an hour, and an appearance takes minutes. Reputation, renown and
  instances now get ninety minutes, achievements and professions an hour,
  appearances forty minutes.
- **The grouped help was rebuilt.** A test written this release counted what
  was actually in the "everything else" bucket: **74 of 123 commands**. The
  groups had been describing an addon three releases smaller than this one,
  and the catch-all had quietly become the main list -- which is the exact
  state the grouping was introduced to fix. Seven groups now, covering
  everything, and the build fails if more than two commands fall outside them.

### Added

- **`/cn urgency`** draws the deadline curve at ten distances from a reset, so
  the weighting that decides "this expires tonight" can be looked at rather
  than reasoned about. It has never been visible before.
- **The recording that the test suite audits itself against now carries the
  client version it was taken from**, and a recording older than the client
  the addon claims to support is a build failure rather than a quiet pass. An
  audit against a game that has since been patched is worse than no audit,
  because it reports success.
- **A missing recording is now a failure on a machine that has the game
  installed.** It stays a printed notice where no client exists, because the
  automated build has no game and never will -- but "unverified" had been
  printing for months while every run still ended in *all checks passed*.

### Fixed

- **The travel estimate's reported legs are the legs it costed.** The rewrite
  carries the walked distances internally as time and converts them back for
  display; a wrong conversion there would be invisible in the total and wrong
  on every screen showing the breakdown. There is now an assertion that the
  parts add up to the whole.
- **`NEW_TAXI_NODE` is not an event, and the addon was registering it.** The
  client refuses an event name it does not have -- it throws rather than
  ignoring -- so this produced a Lua error at every login, in a module that
  had been shipping the line for several releases. The name was plausible and
  invented. There is no discovery event; `TAXIMAP_OPENED` is the honest
  substitute, since you discover a flight point by talking to the flight
  master.
- **One bad event name is no longer a Lua error at every login.** Registration
  now goes through a guarded path: the client's refusal is caught, the name is
  kept, and `/cn errors` will name it. A feature that quietly does not update
  is a bad outcome; an error box on every login is a worse one.
- **Handlers registered before the event frame existed were reaching the
  client through an unguarded loop.** Most of the addon loads before
  `Events.lua`, so that replay -- not the registration itself -- is where a
  bad name from any earlier module actually reached the client. The guard now
  covers both.
- **The test suite could not see any of this, because the fake frame accepted
  any string.** Tenth entry in this project's list of defects caused by a stub
  simpler than the thing it stands for. The stub now refuses an event the
  client does not have, exactly as the client does, and the harness fails on
  anything the guarded path rejected -- production degrades, the build does
  not. The list of real event names is maintained by hand, which is precisely
  the fragile kind of artefact this keeps happening to, so `/cn capture` now
  asks the live client to register every event the addon uses and records what
  it refused. The audit fails on any refusal.
- **`fixtures\captured.lua` was being counted as addon source.** The recording
  is evidence, read only by the test harness, but it is a `.lua` file in the
  tree -- so `check` warned that it was missing from the `.toc` and `sync`
  would have listed it, handing the game a table of test data to load at
  login. Everything under `fixtures\` is now excluded by directory.
- **`check` said nothing when the tree was a release behind the toolkit.**
  There was a guard for a `cn.ps1` *older* than the source it manages, because
  that one would overwrite good source with old. The case that actually
  happens is the reverse: a new `cn.ps1` arrives, `init` declines to overwrite
  an existing tree, and every remaining line of the check reports contentedly
  on the previous release. It now fails, and names the command that fixes it.
- **A stale help entry named a command that does not exist.** Nothing errored
  -- the entry simply did not appear, and a command became undiscoverable
  while the help still looked complete. Every name in the help is now checked
  against the commands that are actually registered.

## [0.45.0]

Two promises this addon made in writing and did not keep, the last of the
backlog that can be built without a live client, and the first structural
split of the codebase.

### Fixed

- **Two features that existed only in a comment.** `Modules/Inventory.lua`
  opened, in 0.44.0, by saying the addon would tell you *"forty of the fifty
  things a quest wants, so the answer is ten more"* and would notice *"a
  recipe you already own and have not learned"*. It did neither: the file
  collected quest starters and stopped. Writing down what something is going
  to do and then not doing it is worse than not writing it down, because the
  next reader believes it. Both are built now, and the counting one is worth
  **more the closer it is** -- "one more feather" outranks a quest not begun.
- **`Inventory.bankIDs` had been declared and read by nothing** since the
  module was written -- a list of container numbers sitting there looking like
  a feature. The bank is scanned when you open one, remembered by item, and
  reported with its age, because the client will not describe a bank you are
  not standing at.

### Added

- **Appearance sets.** The addon has tracked individual appearances since
  0.13.0 without ever knowing the game groups them -- and collecting is
  overwhelmingly done by set. "Four of five pieces" is a real denominator,
  which this addon is normally short of. A finished set is not offered as
  nearly finished; a set barely begun is a decision, not a next action.
- **Your guild, and what you could queue for** -- read-only. The addon does
  not put you in a queue, and will not.
- **Flight paths are learned rather than assumed.** The costing has assumed
  since 0.42.0 that any flight point reaches any other on a continent. Mostly
  true; wrong often enough to matter. There is no API for "does A connect to
  B", so the addon watches the flights you take -- a flight taken is proof --
  and prefers a proven pair. A pair never flown is **not** ruled out: that
  would be worse than the assumption it replaces.
- **`/cn locale export`** prints a paste-ready block for a translator, rather
  than a list they would have to turn into Lua themselves.
- **Sortable lists** -- as ranked, alphabetical, reversed. "As ranked" is
  first, so the default never changes for anybody who does not go looking.
- **The window's filter can follow you between tabs** (`/cn keepfilter`), off
  by default, because a filter that persists invisibly is how a list looks
  empty when it is not.
- **Middle-click the minimap button** to start or stop follow mode.
- **Tooltips say where a collectible drops from**, which the addon has known
  since 0.41.0 without putting it where the mouse already is.
- **`cn.ps1 provenance`** -- how many quest rows are curated, how many were
  folded in from observed play, and how many were contributed. The
  distinction is preserved carefully at runtime and was invisible in the
  repository, where the decisions get made.
- **Sixteen more translated strings** across ten languages.

### Structure

- **`Providers/Blizzard.lua` split into three** at 2,250 lines --
  quests/reputation/character/map, collections, and the world -- divided by
  what the client is asked about, because that is how patches break things.
  `CN.Blizzard` is still one table.
- **The list widget moved out of `UI.lua`** into `UI/List.lua`. It is the
  piece with the least to do with the rest: it knows about rows, pooling,
  filtering and sorting, and nothing about what is in them.
- **`Modules/Navigation.lua` was deliberately NOT split.** Its four sections
  share half a dozen upvalues -- the target, the arrow, the smoothing state,
  the calibration counters -- so separating them is a real refactor rather
  than a move. It is also the one subsystem carrying a fix that has not yet
  been confirmed in game. Splitting it now would mean that if the arrow is
  still wrong, nobody could tell which change did it.

### Tooling

- **Twenty-three mutations, up from eighteen.** The five new ones found one
  hole, now closed.
- **A test that had quietly become two assertions in one.** "Appearance
  candidates are capped" counted objectives BY TYPE across the whole list, so
  the moment a second provider began emitting appearances it was asserting
  something about two unrelated caps added together. It counts its own
  provider now.
- **The curated data accessors have tests at last.** Class, race, faction,
  level and turn-in shipped as schema in 0.43.0 with no rows and nothing
  exercising the readers -- a schema nothing reads is a schema that is wrong
  the first time somebody fills it in.

### Notes

- An unknown quest is eligible. Absence of curated data is not a block, and
  never becomes one.

## [0.44.0]

The addon can see your bags, your mailbox and your keystone; it can cost a
journey to another continent; and it can tell you why the list is in the order
it is in. Two more defects found by the tooling built in 0.43.1.

### Fixed

- **Every flying speed sample was being thrown away.** 0.43.0 added a third
  speed bucket for flying yourself and left the sanity band alone -- a single
  range written when both buckets were ground travel, rejecting anything above
  60 yards per second. That is *below* the speed you actually fly at, so every
  genuine sample was discarded as implausible, the bucket never filled, and
  the flying estimate would have stayed seeded forever while appearing to
  work. The band is per bucket now. Found by a test that assumed a realistic
  flying speed.
- **Quest starters you had already used were recommended again.** The client
  flags an item as starting a quest whether or not you have accepted it.
- **The session planner laid out routes you could not start** -- the ranking
  knew you were dead or in a dungeon since 0.43.0 and the planner did not.

### Added

- **It looks in your bags.** `C_Container` appeared nowhere in this addon for
  twenty-nine releases, and a surprising amount of "what should I do next?"
  is already in there: the item that starts a quest, sitting since a boss
  dropped it, and mounts, pets and toys you own and have not learned. They
  cost **zero** travel, which is the honest number. `/cn bags`.
- **Things with a clock on them** -- `/cn clock`. Mail about to expire *with
  something attached* (expired mail is destroyed, not returned), the keystone
  that is replaced at the reset whether you use it or not, weekly profession
  knowledge that does not come back, and heirlooms.
- **Another continent is now costable.** Where a teleport you know lands on
  the right continent, the journey is priced: the teleport, the cooldown you
  would wait through, and the ordinary journey from where it drops you.
  Destinations are curated, because the client will not convert a bind
  location into a map.
- **`/cn nearby`** -- what is worth doing outside this zone, ordered by how
  long it takes to get there rather than how far away it is. The router has
  been zone-scoped since it was written; the distance function stopped being
  zone-scoped in 0.42.0 and nobody told the router.
- **`/cn order`** -- why the list is in this order. Every term in the score for
  the top few, biggest first, summing to the number shown. `/cn why` explains
  one objective; this explains the ranking.
- **Flying is remembered per zone.** `IsFlyableArea` answers for where you are
  standing and nothing answers for where you are going, so the addon records
  what it observes and trusts that over the near end.
- **`/cn help` is no longer 120 lines.** A dozen essentials by default,
  `/cn help all` grouped by what you are trying to do, and `/cn help <word>`
  searches names and descriptions.
- **The chase estimate walks its legs nearest-first** rather than in whatever
  order the steps happened to be listed.
- **The arrow's distance figure is eased**, like its rotation, and snaps on a
  real jump.
- **Errors survive a logout.** One summary line each, shown once and then
  forgotten -- because the case that mattered was somebody relogging before
  they thought to look.

### Tooling

- **A rule against constructs that mean two different things.** Seven of them,
  checked across every shipped file: two-argument `math.atan`, `table.unpack`,
  `math.fmod`, `goto`, `math.type`, `math.tointeger`, integer division. Each
  names what breaks and what to use instead. This is the generalisation of
  the 0.43.1 defect.
- **`CN.Mod` and `CN.Unpack`** join `CN.Atan2`: if a construct means two
  things, the addon uses neither directly.
- **An end-to-end session test** -- login, ask, explain, route, plan, follow,
  log out -- asserting that nothing throws in the order a player actually does
  things. Every part was tested; the sequence was not.
- **Eighteen mutations, up from ten.** The eight new ones found six holes in
  the suite on the day they were written; all six now have assertions. One of
  the eight was itself wrong -- `%` in Lua is already floored, so mutating to
  it changed nothing -- and was replaced with `math.fmod`, which is the real
  hazard.
- **Two more performance budgets**, and a zero measurement is now a FAILURE
  rather than a pass: "UI refresh: 0.000 ms" meant the function had returned
  immediately without running, which is a budget guarding nothing.
- **`bench.lua --history`** appends every measurement to a TSV. Budgets catch
  a cliff; they do not catch a slope, and the cold rebuild has crept from
  3.9ms to 6.2ms across eight releases without ever failing a gate.
- **Database version 7**, which enforces the remembered-quest-pin ceiling on
  read rather than trusting that it was never exceeded.

### Notes

- Nothing in this release uses, learns, moves, sends or opens anything. It
  reads your bags and your mailbox and tells you what is in them.

## [0.43.1]

One defect, found by evaluating the addon against the language the game
actually runs rather than the one its tests run on. It is the arrow bug that
has been reported three times.

### Fixed

- **Every bearing computed in game since 0.19.0 was wrong.** World of Warcraft
  runs Lua 5.1, in which `math.atan(y, x)` is the ONE-argument arctangent and
  the second argument is silently discarded. The offline test suite runs Lua
  5.4, where the same call is the two-argument form and is correct.

  ```
  Lua 5.4:  math.atan(1, 0) == 1.5707963   (90 degrees -- correct)
  Lua 5.1:  math.atan(1, 0) == 0.7853981   (45 degrees -- atan(1))
  ```

  No error, no warning, a plausible number. In game the arrow's bearing was
  `atan(dx)` with the north-south component of the direction thrown away,
  which is why it could never point behind the player -- reported three times
  as "it does not turn around when I walk past the destination", and "fixed"
  three times against a suite in which the code was genuinely correct.

  The same expression was also behind the motion-based facing calibration
  added in 0.40.0 and the minimap button's drag angle.

- **Overrides were invisible to anything that iterated settings.** The
  settings proxy exposed its merged view through the `__pairs` metamethod,
  which arrived in Lua 5.2. In 5.1 `pairs()` ignores it and yields nothing at
  all. `CN.AllSettings()` returns the merged table and works in both.

- **`/cn closest` threw for anybody whose database had been migrated.** 0.36.0
  stopped storing achievement points -- correctly, the client answers
  instantly -- and one of the three readers was missed. Points are read live
  now, and omitted rather than faked when the client will not say.

### Tooling

- **The test suite runs twice, on both languages**, locally and in CI, with
  Lua 5.1 first because it is the one that ships. This is the only mechanism
  that could have caught any of the three defects above.
- **A rule against the expression itself.** The suite walks every shipped file
  and fails if two-argument `math.atan` reappears. The fix is one function;
  the rule is what stops the next one.
- **The geometry tests run a second time under simulated 5.1 semantics**, so a
  reintroduction fails on the mathematics as well as on the grep.

### Notes

- This is the eighth defect in this project traced to the test environment
  differing from the real one, and the first where the difference was the
  language rather than something I stubbed. `/cn selftest` was built for
  exactly this class and could not catch it either: the check ran in game,
  where both the code and the check were using the same wrong function.

## [0.43.0]

The largest release this addon has had. Fifty-three items, and the short
version is: it knows how you actually travel, it knows what situation you are
in, it introduces itself, and its tests now check themselves.

### Fixed

- **Flying yourself was filed under "mounted".** The speed model has had two
  buckets since 0.31.0 -- mounted and on foot -- and skyriding landed in the
  first one beside a ground mount, dragging that median upward by however much
  you fly. That is the same mistake the file's own comment warns against, one
  level down. Three buckets now, and the third one changes the answer to
  almost every travel question.
- **The addon never noticed you were dead.** Recommending a battle pet to a
  corpse is the clearest possible signal that a tool is not watching. It now
  says so first, and ranks everything down until you are up.
- **A "quest three zones away" was structurally unanswerable.** The client only
  lists quest pins for the map you are looking at, which the addon recorded as
  a scope limit and left there. It now remembers every quest start it has ever
  seen, so `/cn waiting` can tell you what you walked past in Azj-Kahet last
  week.
- **World quests were still costed with a straight line and a flat penalty.**
  0.42.0 fixed that for ordinary quests and missed the provider where it
  matters most -- world quests are scattered across a continent and they
  expire.
- **Weekly deadlines were worth exactly nothing until their last two hours.**
  The urgency curve was built when everything with a deadline was a world
  quest. A raid lockout you are six bosses into, with a day left, could not
  outrank anything. There are two ramps now: a week-long one that breaks ties
  between things that are all days away, and the original steep one on top,
  which still dominates -- ten minutes beats four days, as it should.
- **Account-wide currencies were recommended on every character.** The client
  flags them; the addon ignored the flag. That is the exact mistake the
  Warband work exists to prevent, in the one store nobody had told about it.
- **The arrow stepped rather than swept.** It recomputes ten times a second and
  snapped to each new bearing. It eases now -- except through a reversal,
  which still snaps, because an arrow easing through 170 degrees is pointing
  at nothing at all for a quarter of a second.

### Added

- **Flying yourself, hearthstones and teleports.** A journey is now costed
  against three options -- run, take a flight path, or fly it yourself -- and
  the third usually wins in current content. Cross-continent still refuses to
  invent a duration, but it now lists what you actually have: every
  hearthstone and teleport you know, with the cooldown the client reports.
- **`/cn waiting`** -- quests you have seen and never picked up, by zone.
- **`/cn situation`** -- what the addon thinks you are in the middle of, and
  what that is changing about the ranking. In an instance with four other
  people, outside work ranks down.
- **`/cn orders`** -- crafting orders you placed, and anything finished and
  waiting. It does not open or scrape the order frame.
- **`/cn contribute`** -- shares the quest chains your play has taught the
  addon, as one line of quest IDs you can read before you send it. No server,
  no account, no personal data: the addon cannot upload anything, and this is
  a format you paste into an issue yourself. Imports land as observations,
  never as curated fact.
- **A first-run question.** One screen, four buttons, asked once, setting the
  focus mode that almost nobody discovered because `/cn mode collecting` is a
  sentence you have to already know to type.
- **Visible route progress.** Follow mode now says "stop 3 of 7 cleared" as you
  walk it, and marks the moment a route is actually finished. Sound and a
  flash are available and off by default.
- **`/cn hud`** -- a small always-on line showing the next thing. Off by
  default, like everything here that puts pixels on screen uninvited.
- **`/cn scale` and `/cn colourblind`.** The arrow's entire language was
  colour -- blue on course, amber drifting, red walking away -- which is
  precisely the design that fails a colourblind player. In that mode it
  carries the word as well.
- **A filter box in the window**, and the addon now appears in the game's own
  options list rather than only inside a window you have to know how to open.
- **Three more keybindings**: follow, plan, and the heads-up line.
- **`/cn errors`** -- failures inside the addon are caught so they cannot break
  your session, which is also why they were invisible. They are kept now, and
  a bug report can carry the text instead of a description of the text.
- **`/cn dbsize` reports memory as well as disk.** One of the two was being
  measured and the other assumed.
- **Curated gating data**: class, race, faction and level, plus turn-in
  locations, so `/cn why` can say "that one is for a Druid" rather than
  leaving the player to work out why they cannot see it.
- **Fifteen more translated strings**, across ten languages.
- **A standing Delves probe.** The decision not to build Delve tracking has
  been made twice, for a reason -- `C_DelvesUI` exposes interface plumbing and
  not progress -- and a decision nobody re-checks becomes a thing everyone
  forgot. The self-test now names the exact API that would change it.

### Tooling

- **`mutate.sh`** -- breaks the code on purpose, ten ways, and fails if the
  suite does not notice. It found three holes on the day it was written, all
  three now covered. This was being done by hand, from memory, which means
  inconsistently.
- **Performance budgets in CI.** Two regressions have shipped in this project
  and both were visible in the benchmark output at the time. Printing a number
  somebody has to remember is not a check.
- **Release notes are cut from the changelog** for the version being built,
  rather than the whole file since 0.1.0.
- **`cn.ps1 interface`** -- sets the game interface version and prints the rest
  of the patch checklist, which had been living in my head.
- **Issue templates** that ask for `/cn selftest` and `/cn errors` output.
- **The translation lint now checks both directions.** It caught orphaned
  translations; the failure that actually happens is the reverse -- the key IS
  the English string, so editing the English silently orphans every
  translation of it.
- **Coverage floor raised to 83%**, and the Wago publishing field prepared.

### Notes

- A surviving mutation is a hole in the test suite, not a mutation to delete.
- The filter box keeps its state in a local rather than on the frame. Reading
  an unset field off a frame does not reliably return nil -- a metatable can
  answer -- and the first version relied on it. The harness caught that; a
  player running a UI replacement might have found it instead.

## [0.42.0]

Travel that knows about flight paths, an honest answer to "how long will this
take", and prerequisite chains that finally reach the shipped data.

### Fixed

- **Every travel figure in the addon was a straight line.** Within a zone that
  is very nearly right. Between zones it was not even approximately right, and
  the addon covered that with a flat penalty: anything outside your current
  zone cost the same whether it was over the next ridge or on the far side of
  the continent. A journey is now costed the way you would actually make it --
  run to the nearest flight point **you have discovered**, fly, run from the
  arrival point -- against simply running the whole way, whichever is quicker.
  This is why `/cn plan 30` could put a nine-minute flight into your half hour.
- **Flight speed was not merely unknown, it was thrown away.** The addon has
  measured your running speed for several releases and explicitly discarded
  taxi movement while doing it. It now measures your flying speed too, from
  your own flights, and says *estimated* until it has. The client does not
  expose the number and it differs between expansions, so measuring is the
  only honest way to have it.
- **Harvested prerequisites could never reach `Data/Quests.lua`.** The addon
  wrote them, the toolkit's parser could not see an array field at all, and so
  it silently dropped every chain -- both halves looking like they worked. The
  parser reads them now, `cn.ps1 harvest` writes them, and a row that already
  exists for its location gains its chain rather than being skipped whole. A
  `requires` that is already there is never overwritten: curated data outranks
  observation, so this is an insert, not an update.
- **Two maps meant no distance at all.** Cross-map distances are now computed
  in world coordinates, which are continuous across a continent, instead of in
  map coordinates, which are normalised per map and cannot be compared.

### Added

- **`/cn chase` now says how long the goal will take.** The addon already
  measured how long each kind of objective takes *you* and how long it takes
  to get anywhere; nothing multiplied them. It is a **range**, not a figure,
  because task times vary by more than a third with competition, group size
  and luck -- and where more than half the steps are kinds of thing it has
  never watched you do, it says *time unknown* and how many, rather than
  averaging its way to a number that looks like a fact.
- **`/cn travel`** -- how long it takes to reach the top recommendation and by
  what route: how far to the flight point, how far in the air, how far at the
  far end, and what running the whole way would have cost. Also how many
  flight points you know and whether your flying speed has been measured yet.

### Notes

- Two continents with no flight between them return **nothing**, not a large
  number. Portals and boats are not modelled, and a fabricated four hours
  would be worse than an admission.
- Flight points you have not discovered do not exist as far as the costing is
  concerned, because they do not exist for you either. A pessimistic plan you
  can follow beats an optimistic one you cannot.
- The one invented constant in the travel model is the twenty seconds a flight
  costs before it starts moving -- talking to the flight master, mounting, and
  landing. It is a constant rather than a measurement because timing it would
  mostly be timing how fast you read a gossip window.

## [0.41.0]

The addon can see inside a dungeon, it learns what you actually do, and its
tests can finally check themselves against a real client.

### Added

- **Dungeons and raids.** Until now this addon knew everything about the open
  world and nothing about the inside of an instance: a mount that drops from a
  raid boss was a line of free text with no boss, no instance, and no idea
  whether you had already killed the thing this week. Now:
  - **`/cn instances`** -- what you are saved to, how much of each is left, and
    when it resets. Where nothing has been killed yet, every boss is named;
    part-way through, the client reports how many are left rather than which,
    and so does this, because inventing the names would be inventing
    information.
  - **`/cn drops <name>`** -- which boss drops something, in which instance,
    and whether your own lockout is in the way.
  - **`/cn chase` on an instance drop now names the boss** instead of
    dead-ending in prose, and marks the step blocked with a reset time when
    you are already saved and cleared.
  - **A part-finished lockout now competes for "what next".** Those kills are
    spent effort with an expiry on them, which makes them some of the cheapest
    progress in the game -- and the ranking could not see them at all.
    A lockout you have not started is deliberately *not* recommended: that is
    a decision about your evening, not a next action.
  - Reading the Adventure Guide **changes what it is displaying**, so the addon
    refuses to read it at all while you have it open, and puts its selection
    back exactly as it found it when you do not.
- **It learns which kinds of thing you actually go and do.** `/cn learned`
  shows the whole table. The guardrails matter more than the learning: nothing
  moves until a type has been shown 25 times, the adjustment is clamped to a
  narrow band so a type you ignore gets quieter but never silent, every
  adjusted line says on the line that it was adjusted, the counters decay so
  the addon tracks how you play now, `/cn learned reset` throws it all away,
  and `/cn learned off` switches it off entirely. A focus you chose with
  `/cn mode` always outranks a habit the addon inferred.
- **`/cn capture` and `cn.ps1 fixtures`.** Nine defects in this addon's history
  came from the offline test suite modelling the world more simply than the
  world is -- most recently by treating every map in the game as a perfect
  square, which hid an angle error in every zone for eight releases. Writing
  more careful stubs does not fix that, because the author of a stub does not
  know which part of reality he simplified. So the addon can now record what
  your client actually returned, and the test suite audits its own stubs
  against that recording: a stub missing a field reality had is a test failure
  rather than a future bug report. Shapes and counts only -- nothing that
  identifies you, and nothing leaves your machine.

### Fixed

- **Switching a setting off wrote nothing.** `x and false or nil` cannot
  produce false in Lua -- `and false` is falsy, so it falls through to the
  `or` every time. The line read correctly and did nothing. Caught by a test
  that asserted the switch worked rather than that it had been called.
- **A completion the client identifies differently was never credited.**
  `NEW_PET_ADDED` reports the pet you now own, not the species that was
  recommended. Those now match by type; quests and achievements, whose events
  carry exactly the id that was recommended, deliberately do not, because a
  loose match there would credit the addon for every quest anybody turns in.

### Notes

- `/cn selftest` is now fifteen checks: the two new ones read your lockouts
  and confirm the Adventure Guide can be read without disturbing what you are
  looking at. With it open, that check SKIPs and says the refusal was the
  intended behaviour rather than a fault.
- One assertion in the suite asserted "a pinned goal ranks in the top three",
  which was a magic number meaning "above the three expiring things this
  fixture happens to contain". It broke when a provider was added, for a
  reason that had nothing to do with goals. It now asserts the property that
  was actually meant: only time-limited work may outrank a pinned goal.
- The multiplier the learning applies is memoised. Uncached, it resolved the
  settings proxy once per candidate and doubled the cost of building the list.

## [0.40.0]

Two things the arrow was doing wrong in every zone, and the addon finally
speaks more than one language.

### Fixed

- **Every bearing the arrow computed was stretched by the shape of the zone.**
  Map coordinates run 0 to 1 across a map regardless of the ground underneath,
  so a zone twice as wide as it is tall compresses east-west angles by half.
  The arrow measured its angles in those raw coordinates, which means a target
  genuinely 45 degrees off your left read as something else entirely --
  in every zone in the game, on every target, since the arrow was written.
  Bearings are now measured in yards, using the size the client reports for
  the map you are standing in. Distances were always correct; angles now are
  too.
- **Which way the client counts your facing is now settled by watching you
  move.** Whether `GetPlayerFacing` grows as you turn left or as you turn
  right is a client convention that cannot be derived, and getting it wrong
  does not make the arrow point backwards -- it makes it *mirrored*, wrong by
  twice your facing, which looks correct when you face north and badly wrong
  when you face east. The old evidence for it was indirect and only arrived
  when you happened to be lined up with a target and walking. The new evidence
  is direct: when you move, the direction you moved is the direction you were
  facing, and only one of the two conventions agrees with that. Strafing and
  walking backwards agree with neither and are discarded rather than voted on,
  and six consecutive samples are required, so nothing a knockback or a lag
  spike does can flip your arrow.

### Added

- **`/cn selftest`** -- thirteen checks that run against your live client and
  report what they actually found: whether your position converts, whether the
  arrow's facing has been confirmed against your own movement, whether the map
  reports quests you have not accepted, whether achievement criteria carry
  their counters, how large your saved data is, and whether the engine can
  answer "what next" at all. Each check exists because something it covers was
  once broken in a shipped release and was found by somebody playing rather
  than by the test suite. A check that cannot be answered says so and skips;
  it does not pass.
- **Translation support, with nine languages started.** German, Spanish
  (Spain and Mexico), French, Italian, Korean, Portuguese, Russian, and both
  Chinese scripts. The framework covers the whole addon; the bundled
  translations cover the strings you see most, and anything not yet translated
  falls back to English rather than to a blank label. `/cn locale` says how
  far along your language is, and `/cn locale missing` prints exactly the list
  a translator would work from. Nothing was machine-translated to make that
  number look better.

### Notes

- The self-test's bearing check was written the obvious way first: project a
  point in front of the player using the addon's own facing convention, then
  ask the addon which way that point is. It passed, and it would have passed
  with the maths inverted, because it derived its expected answer from the
  code it was checking. It was rewritten against cases whose answers come from
  the definition of a map, and the suite now breaks the maths deliberately and
  requires the check to notice.
- The offline test suite modelled every map as a flat 1,000 by 1,000 yard
  square for eight releases, which is why the angle error above survived every
  test the addon has. The stub now describes maps that are not square, and one
  of the new checks reports the real shape of the zone you are standing in.

## [0.39.0]

An addon that knows nothing should say so more than once.

### Fixed

- **The first-run prompt fired once, ever.** A fresh install has scanned
  nothing, so it knows nothing about your collections and its
  recommendations are correspondingly thin. It said so -- one line, eight
  seconds after your first login, in the middle of the login chatter -- and
  then recorded that it had spoken and never mentioned it again.
  Miss that line, which most people would, and the addon underperforms
  silently for the rest of its installed life with no way to find out why.
  It now says so every login **until the scan has actually been run**, and
  then never again. That is the difference between a reminder and nagging: a
  reminder stops when the thing is finished.
- **Two subsystems can only be read while their window is open**, so the addon
  can be fully set up and still blind to a profession you levelled last week.
  It knew that, and only said so immediately after a manual scan -- the one
  moment you are least likely to need telling. It is now mentioned at login,
  at most once a week, because the fix is "open a window some time" rather
  than anything urgent.

### Added

- **`/cn setup check`** -- what the addon still cannot see, without
  rescanning anything. "What can you not see?" and "go and look again" are
  different questions, and answering the first by doing the second is why
  people stop asking.

### Notes

- The existing behaviour was **prompt, never act** -- eleven scans run
  uninvited on someone's login is the same discourtesy as seizing their
  waypoint. That stance is unchanged and correct; the defect was that the
  prompt gave up after one attempt at being heard.
- **The navigation arrow is untouched for the fifth release running**, for the
  same reason each time: two fixes to it are shipped and unverified, and
  `/cn navdiag` will settle it in one command.

## [0.38.0]

The hottest path in the addon was the slowest thing in it.

### Fixed

- **Every item tooltip scanned every recipe you know.** To answer "is this
  item a recipe?", the tooltip walked the entire recipe list -- lowercasing
  each name and searching it -- because the item that *teaches* a recipe is
  named after the recipe rather than sharing its ID.
  At retail scale that is twenty-five hundred iterations and five thousand
  string allocations, to answer a question about one item. **Measured at
  0.536ms per tooltip** -- three per cent of a frame for hovering one thing,
  and sweeping a bag or an auction house list fires dozens of them a second.
  A lowercased name index, built once and rebuilt only when recipes are
  scanned, answers the same question with two hash lookups. **0.536ms to
  0.004ms**, a hundred and thirty-fold.
- The old match used a substring search, which could recognise an item as a
  recipe far more loosely than intended -- any item whose name happened to
  contain a recipe's name anywhere. The replacement matches the name exactly,
  or the name with a known teaching prefix removed (`Recipe:`, `Pattern:`,
  `Plans:` and the rest). More correct as well as faster, and there is a test
  asserting an unrelated item is not mistaken for a recipe.

### Notes

- Two tests in this release had to be rewritten before they could fail.
  The invalidation test bumped the index's revision by hand, which proved the
  index respects a revision but said nothing about whether anything ever
  changes one -- deleting the scanner's bump left it passing while the tooltip
  would have answered from a stale index for the rest of the session. It now
  drives a real scan.
  This keeps happening in the same shape: a test that exercises the mechanism
  instead of the caller. Worth naming as its own rule alongside the one about
  stubs -- **assert through the path the game actually takes, not the seam you
  built to make it testable.**
- **The navigation arrow is untouched for the fourth release running.** Two
  fixes to it are shipped and unverified; `/cn navdiag` settles it in one
  command when there is time.

## [0.37.0]

The window itself. Two defects that only show up while you are looking at it.

### Fixed

- **Every list redraw allocated three closures per row.** The click and hover
  handlers were built inside the redraw, so a hundred-row list threw away and
  rebuilt three hundred functions every time the window refreshed -- each one
  capturing a table it did not need to capture.
  In this game that is not an abstract cost. Allocation churn is what garbage
  collection pauses are made of, and a pause is a stutter. The handlers are
  now bound once when a row is created and read the row's current entry, so a
  redraw allocates nothing at all.
- **The row pool had no ceiling.** Frames cannot be destroyed in this game,
  only hidden and reused, so a list that renders one frame per entry grows to
  the size of the largest list it has ever shown and keeps it for the rest of
  the session. A thousand entries meant a thousand permanent frames.
  Capped, and when the cap bites the list says **"... and N more not shown"**
  rather than simply ending. A truncated list that looks complete is worse
  than a long one.

### Notes

- Binding a handler once is only correct if it reads the row's *current*
  entry rather than the one that was there when it was bound -- otherwise
  clicking the first row would forever run the first list's action. That is
  asserted directly: the list is refilled with different actions and the
  handler must run the new one.
- The first version of the row-cap test compared both sides of the assertion
  to the setting it was meant to constrain, so raising the cap moved the
  goalposts and the test passed against a list that created a thousand
  frames. It now asserts an absolute number. A ceiling defined by the thing it
  constrains is not a ceiling -- and this is the same shape of mistake as the
  fixture that was ordered like the bug in 0.31.0.
- **The navigation arrow is untouched for the third release running**, for the
  same reason: two fixes to it are shipped and unverified, and `/cn navdiag`
  will settle it in one command.

## [0.36.0]

Finishing what 0.35.0 measured.

### Changed

- **Saved data: 947 KB down to 832 KB**, and 1,275 KB down to 832 KB across
  the two releases -- a third less written on every logout and parsed on every
  login.
  Achievements kept a name and a point value for every tracked row; pets kept
  a name for all eighteen hundred. Every one of those comes back from the
  client in microseconds. Names now resolve live, from the achievement info
  and the pet journal, and databases written before this release still honour
  whatever name they are carrying until the migration clears it.
- **Per-row timestamps are gone.** Achievements, pets, toys and recipes each
  stamped `firstSeen` and `lastSeen` on every row. Nothing read them. Roughly
  seven thousand rows carried a pair of values that existed only to be written
  to disk and parsed back. (The per-character `lastSeen` is a different thing
  and stays -- `/cn alts` needs it to say how old its information is.)
- The migration reclaims all of it on the next login rather than on the next
  full rescan.

### Notes

- These were named in the 0.35.0 roadmap with their measurements, and pets
  were deliberately deferred there because the name had six consumers
  including a search. Doing it in its own release, with a resolver and tests
  rather than at the end of an unrelated one, is why it took two versions
  instead of one.
- The benchmark fixture had to be corrected first -- twice now. It was writing
  the *old* shape, so it would have reported a saving that had not happened.
  A performance measurement taken against a fixture that does not match what
  the code writes is a measurement of nothing, and this is the second release
  running where checking that came before believing the number.
  The timestamp removal is real but does **not** appear in the 832 KB figure,
  because the fixture never modelled the timestamps in the first place. Said
  plainly rather than folded into a larger claim.
- **The navigation arrow is untouched again.** Two fixes to it remain
  unverified; `/cn navdiag` will answer it in one command when there is time
  to look.

## [0.35.0]

A third of what this addon saved to disk was a copy of something the game
already had.

### Changed

- **Saved data: 1,275 KB down to 947 KB**, measured at retail scale. The
  client rewrites this file in full on every logout and parses it again on
  every login, so it is a cost paid twice a session, and nobody had ever
  measured it.
  The largest contributor was **vendors, at 488 KB for twenty of them** --
  roughly twenty-four kilobytes each. Every vendor stored the *name* of every
  item it sold, which is a duplicate of the client's own item cache, plus a
  table per item to hold two fields. Names are gone and prices are stored as
  bare numbers; a three-hundred-item merchant now costs 6 KB instead of over
  twenty. Prices are still kept, because the client only reports them while
  the merchant window is open and they genuinely cannot be recovered later.
- **A migration reclaims it on the next login** rather than waiting for you to
  reopen every merchant you have ever visited.

### Added

- **`/cn dbsize`** -- how much the addon writes to disk and where it goes, so
  this cannot quietly grow back.
- The test suite asserts a three-hundred-item vendor stays in single-figure
  kilobytes, and that the migration actually drops names already on disk.

### Notes

- The rule this establishes, worth stating because it will apply again:
  **persist only what the client cannot tell us.** Names, collected states and
  completion flags come back instantly from the game. Cross-character
  knowledge, observations gathered over time, and the player's own choices do
  not -- and those are what this database is actually for.
- Two further stores fit the same argument: achievements at 394 KB and pets at
  274 KB, both carrying names the client can re-supply. Pets were deliberately
  left alone here -- the name has six consumers including a search, and a
  six-site refactor rushed at the end of a release is how a saving becomes a
  regression. Both are written up in the roadmap with their measurements.
- **Nothing was changed in the navigation arrow this release.** Two fixes to
  it are shipped and unverified, and stacking a third speculative change on
  top of them would make the next report harder to interpret, not easier.

## [0.34.0]

The arrow stopped working indoors, and now it can explain itself.

### Fixed

- **Stepping into a building, a cave or a city district stopped the arrow.**
  The client answers "which map are you on" with the most *specific* map
  containing you, so walking through a door changes it -- while you have moved
  thirty yards. The arrow compared that to the destination's map, found them
  different, and announced "another zone" while standing next to the thing it
  was pointing at.
  It now asks the client where you are **as expressed on the destination's
  map**, which works for any map that can describe you, and only gives up when
  the answer is genuinely nowhere -- another continent, or an instance. That
  case still says so plainly rather than producing a confident arrow pointing
  at nothing.
  This is the same defect that made available quests invisible in a city in
  0.27.0, in a different file, with the same cause: assuming the map under
  your feet is the map the data is on.

### Added

- **`/cn navdiag` -- everything the arrow is thinking, in one command.**
  Written because the arrow has been reported as misbehaving twice, and both
  times the only available evidence was a description in prose. I guessed from
  it twice and was wrong twice. Prose is a bad instrument.
  It reports what is being tracked, where the client says you are, which way it
  says you are facing, every intermediate value in the bearing, the rotation
  actually applied to the texture, the colour that implies, and -- crucially --
  which of the several things that can silently change your destination is
  switched on. If the arrow does something surprising again, one command
  produces the answer instead of a conversation.

### Notes

- The offline stub answered "where is the player on this map?" for *every*
  map, including ones on other continents. That made "you are in a building
  inside this zone" and "you are on another continent" indistinguishable --
  two cases that need opposite behaviour from the arrow. The stub now refuses
  maps that cannot place the player, which is what the client does.
  Seventh instance of the same pattern, and the rule written down in 0.33.0
  is what caught this one: ask which part of reality the stub is refusing to
  model, and whether that is the part under test.
- One test in this release had to be corrected rather than the code: it put
  the player on a map the client could not place them on, which is a state the
  client never produces. A test asserting behaviour in an impossible state
  proves nothing about a real one.

## [0.33.0]

The arrow. Reported twice, and I did not find it either time because I never
wrote the test that would have shown it.

### Fixed

- **Arriving re-pointed the arrow at a different destination without saying
  so.** This is the actual defect behind *"I walked past it and the arrow did
  not turn around."* With auto-advance on, reaching a destination hands the
  arrow to the next thing on the route -- and the arrow looks absolutely
  identical doing it. Same shape, same blue, still ahead of you, distance now
  counting **up** because the new destination is further away than the one you
  just walked through.
  A player seeing that concludes the arrow failed to turn round, and they are
  not wrong to: nothing on screen said the destination had changed. The addon
  now names the new destination in chat and the arrow's own label updates to
  match. The maths was never wrong; the communication was.
- **Hiding the arrow left everything it was showing intact.** Rotation, colour
  and distance were never reset, so an arrow hidden while pointing north-east
  at "10 yd" was still pointing north-east at "10 yd" the instant anything
  showed it again -- a stale claim about a destination nobody was tracking.
- **Arrival latched permanently.** `arrived` was set once and never cleared,
  so walking back out of range left the addon believing you were still there.
  Defensive rather than load-bearing -- the arrow turned round correctly even
  with the latch in place, and I am saying so rather than claiming a fix I did
  not need to make -- but a flag that can only ever be set once is a bug
  waiting for a caller.

### Added

- **The arrow is testable for the first time.** The offline harness's texture
  stub accepted `SetRotation` and `SetVertexColor` and remembered neither, and
  its font strings swallowed `SetText`. The single most visible thing this
  addon draws had no test that could see which way it pointed or what colour
  it was. Both now record, and so does the player's position -- which was a
  fixed point, meaning every arrow test ever written tested standing still.
- A walk-past test drives the real refresh path: approach, arrive, continue,
  and assert the arrow turns a half circle, recolours, keeps reporting a real
  distance, announces a re-target, and leaves nothing stale behind.

### Notes

- Six times now a stub has modelled the world more simply than the world and
  hidden a defect: a flat map point, a quest list without quest starts, an
  achievement criterion without a counter, a completed-quest list that cost
  nothing to read, a fixture ordered the same way as the bug, and now a player
  who could not move and an arrow whose direction nobody could read.
  The pattern is exact enough to state as a rule: **when a test needs a stub,
  the first question is which part of reality the stub is refusing to model,
  and the second is whether that is the part under test.**

## [0.32.0]

The quest counter was costing your entire quest history to display.

### Fixed

- **Reading "quests completed" allocated a copy of every quest you have ever
  finished.** `C_QuestLog.GetAllCompletedQuestIDs` does not return a number;
  it builds a table containing all of them -- tens of thousands of entries for
  anyone who has played a while, which is exactly who this addon is for. The
  Journey tab called it on every refresh to display one integer.
  It is now read once and kept, so twenty-five refreshes cost one trip to the
  client instead of twenty-five. Measured at a realistic twelve thousand
  completed quests: **0.260ms per refresh, now 0.000ms.**
- **The offline test stub was hiding it.** It handed back the same table on
  every call, so reading the history looked free and the cost was invisible to
  every test that had ever run. The stub now builds a fresh table, because
  that is what the client does.
  This is the fifth time in this project a stub has modelled the world more
  cheaply than the world and hidden a real defect. The pattern is always the
  same: a stub that costs less than the thing it stands for.

### Notes

- **I nearly shipped a cache that did not cache.** The obvious invalidation
  list includes `QUEST_LOG_UPDATE`, which sounds right and fires many times a
  second during normal play -- so hooking it handed the entire saving straight
  back. The benchmark caught it: 0.000ms became 0.244ms, which is to say
  exactly the number I had just removed.
  Invalidation is now precise on the events that certainly change the count,
  with a sixty-second staleness bound for anything that slips through. A count
  a minute out of date is not a problem; a count that costs a quest history to
  display is.
  Both behaviours are asserted, including the negative one -- hooking the
  chatty event fails the build.

## [0.31.0]

Which zone next -- and two bugs that were hiding the answer.

### Added

- **`/cn zones` -- which zone to work on next, and why.** The addon could
  answer *what next* and *where in this zone*, and had nothing at all to say
  about *which zone*. That is the question somebody working through a
  continent asks every time they finish one.
  Zones are ranked by what is cheapest to finish rather than by size: a zone
  you are most of the way through beats a fresh one, a fresh small zone beats
  a fresh enormous one, the zone you are standing in costs nothing to reach,
  and anything you have pinned as a goal is lifted. Every line says which of
  those reasons applied.

### Fixed

- **A zone you had never set foot in could never be recommended.** The
  underlying list excluded anything with zero progress. For a player sweeping
  a continent -- the exact person this is for -- the untouched zones are the
  entire point. They are now included and ranked separately, because "you are
  90% through this one" and "you have not started this one" are different
  suggestions and blending them by percentage buries every fresh zone under
  every half-finished one forever.
- **The zone ordering was being thrown away.** The list was sorted carefully
  by completion, then handed to a helper that re-sorts by a field these rows
  do not carry -- so every row compared equal, the tie-break took over, and
  the whole list silently collapsed to alphabetical by achievement ID. It only
  bit when there were more zones than the display limit, which is to say:
  always, on a real account.

### Notes

- Both bugs sat in eleven lines of code that had passed every release since
  they were written, because nothing had ever asked the function for fewer
  rows than it had.
- Two tests in this release had to be corrected rather than the code.
  The first demanded that a zone you are chasing outrank everything -- but a
  zone with one quest left genuinely does beat a ninety-quest zone you have
  merely pinned, and rewriting the scoring to satisfy the assertion would have
  made the addon worse to make a line green. The second numbered its fixtures
  in the correct order, so the broken ordering and the right one produced the
  same list and the test passed against the bug; the IDs now run deliberately
  backwards. That is the fourth time in this project a test has agreed with a
  defect, and every one has been the same mistake: a fixture that cannot tell
  the two answers apart.

## [0.30.0]

The rest of your Warband, and two things that were quietly throwing work away.

### Added

- **`/cn alts` -- should you be playing somebody else?** The addon has known
  the answer for several releases and had no way to volunteer it. It could
  tell you which character was best for one objective, when asked, buried in
  `/cn why`. The question a player actually has runs the other way: *is the
  character I am logged into the right one for tonight?*
  It now looks at what is on your list, asks the Warband who each thing
  belongs to, groups the answers by character, and says either "this one is
  fine" or "your Druid could do four of these".
- **It refuses to suggest a switch for account-wide progress**, which is the
  one answer that would actively waste your time -- a loading screen to earn
  something that would have counted anyway. There is a test for exactly that,
  because it is the mistake this feature exists to avoid making.
- **It says how old its information is.** Everything known about another
  character is whatever that character recorded the last time it logged in. A
  roster line reads "yesterday" or "3 weeks ago", and anything past a month
  stops producing suggestions rather than presenting a stale snapshot as
  current.
- The verdict is deliberately conservative: one reason is not enough to
  recommend a loading screen. A tool that suggests switching every time you
  log in is a tool people turn off.

### Fixed

- **Follow mode moved your waypoint mid-fight.** Clearing the last objective
  at a camp while something is hitting you caused the arrow and the waypoint
  to swing to the next stop -- the single most intrusive moment the addon
  could have chosen. Automatic advances now wait for the fight to end and then
  happen immediately. Pressing the button yourself still works during combat;
  you can see your own screen.
- **Measured travel speed was thrown away on every reload.** The samples lived
  in a table that died with the session, so a `/reload` -- which a player does
  several times an hour -- put the planner back on a guessed constant. The
  addon was permanently five samples away from being useful and never got
  there. Samples are now kept per character and survive reloading, logging
  out, and patch days.
- Corrupt values in the saved samples are cleaned on load rather than filtered
  on every read. SavedVariables outlive every version of this addon; junk left
  in place is junk filtered forever.

## [0.29.0]

No new features. Six defects, four of them mine, and the rebuild cut by two
thirds.

### Fixed

- **The urgency curve barely fired.** 0.28.0 shipped a headline feature that
  weights anything carrying a deadline, and then only two providers attached
  one. A daily disappears at the daily reset, a timed quest carries its own
  clock, and a capped currency wastes everything you earn until the weekly
  reset -- all knowable, none of them being said. Now they are.
  Worth stating plainly: the release notes for 0.28.0 described a feature
  that was, in practice, close to inert.
- **Durations were measured with a one-second ruler.** `time()` returns whole
  seconds, so a ten-second travel sample carried up to ten per cent of error,
  and anything finished inside the same second it was offered read as zero
  elapsed and was discarded as implausible -- which threw away precisely the
  fast turn-ins a quest grinder produces most of. Measurement now uses the
  client's fractional clock.
- **Travel speed was one median across mounted and unmounted travel** -- a
  number wrong in both states. Two buckets now, with samples that span
  mounting discarded as belonging to neither.
- **The offer table grew without bound.** Every objective the addon decorated
  got a timestamp and only completing it removed one; crossing a dozen zones
  accumulated an entry for everything that ever scrolled past. Entries now
  expire and the table is capped.
- **Duration timing ran on every candidate rather than every recommendation.**
  Two hundred timestamps taken per rebuild at retail scale, of which the
  player saw perhaps five. Wrong on cost and wrong on meaning -- something
  ranked one hundred and eightieth has not been offered to anybody.
- **"Available to pick up here" could mean a four-minute ride away.** Widening
  the search to neighbouring maps is what fixed a player being told zero while
  standing in front of a quest giver; it also made "here" overstate the case.
  Results are now split by real distance, and the wording matches which.

### Changed

- **A cold rebuild costs 5.5ms instead of 15.6ms** at retail scale (1800 pets,
  3000 achievements, 2500 recipes), measured, not estimated.
  Two providers accounted for most of it and both were doing the same thing
  wrong. Achievements walked all three thousand rows on every rebuild to keep
  about a dozen, rejecting the same two thousand nine hundred and eighty every
  time; it now keeps a shortlist against a revision number and costs 0.02ms.
  Reputations built a complete objective -- table, reasons, formatted strings
  -- for all five hundred factions and then discarded all but sixty; it now
  scores first and allocates only the survivors.

### Added

- **The release now refuses to proceed until the project page has been
  reviewed against it.** A release with no user-visible change legitimately
  needs no new copy -- but that has to be a decision somebody made, and this
  time it was an omission the author had to catch. `_curseforge/REVIEWED.txt`
  carries the version the page was last considered against, and `check` fails
  until it matches the tree. Editing the description satisfies it; deciding no
  edit is needed means bumping the marker, which is a five-second
  acknowledgement that the question was asked.
  "How fast it is" and "how accurate it is" count as things a player notices.
  That is written into the failure message, because the judgement that got
  this wrong was mine.

- **`cn.ps1 ci` replaces the standalone CI script, and explains its own
  failures.** Checking a build twice per invocation against an unauthenticated
  budget of sixty requests an hour means roughly thirty checks -- which
  somebody watching a release will spend in ten minutes, after which every
  call returns a bare `403 Forbidden` that says nothing about why.
  It now reads the rate-limit headers and says which limit was hit and when it
  clears, caches answers for twenty-five seconds so pressing it again costs
  nothing, accepts a token for a budget of five thousand, and offers
  `ci -Watch` to follow a run to completion on one invocation instead of being
  re-run by hand. The repository is read from the git remote, so a fork
  reports its own builds rather than the upstream's.

### Notes

- The urgency test took three attempts to become capable of failing. The first
  asserted that *something* carried a deadline, which the Vault already
  satisfied. The second asserted that a *quest* did, which world quests --
  same objective type, different provider -- also already satisfied. Both
  passed with the code under test deleted. The third asks the Quests provider
  directly. Recorded because this is the third time in this project that a
  test has agreed with a bug, and the pattern is always the same: asserting on
  an aggregate that something else already satisfies.
- Bounding the offer table naively made `Recommend(25)` seventy times slower
  -- pruning fired on every insert once the table was full. It now overshoots
  by a quarter before sweeping. A fix for a memory leak that costs seventy
  times the CPU is not a fix.

## [0.28.0]

Time, focus, and one performance bug I put there myself.

### Added

- **`/cn plan 30` -- what fits in the time you actually have.** The most
  common shape a play session has, and the addon had nothing to say about it.
  It could rank everything and route between stops, and could not answer the
  one question a person with a job and a bedtime asks before logging in.
  The estimate is built from two halves and only one of them is guessed.
  **Travel is computed** -- the router knows real yard distances, and the
  addon now measures how fast you actually move by watching your position,
  discarding flight paths and loading screens as implausible. **Task time is
  learned**, timed from when something was first put in front of you, kept as
  a median per type. Until a type has been watched enough times it has *no*
  estimate, and the plan says "time unknown" rather than inventing one.
  A plan therefore starts honest and vague and sharpens as it watches you
  play. That is slower to become useful than a table of made-up constants and
  it is the only version that is ever true.
- **`/cn mode leveling` -- aim the whole addon in one command.** Levelling,
  collecting, reputation, achievements, professions, everything. A focus sets
  the weighting *and* the type filter together, because "I'm levelling
  tonight" means both "prefer quests" and "stop showing me pets", and making
  someone say that twice is the addon asking them to do its filing.
  `/cn mode off` restores exactly what you had -- including types *you* had
  hidden before, which the addon must not quietly undo.
- The Journey tab gained one-click 30-minute and 1-hour plans.

### Changed

- **Urgency is a gradient now, not a flag.** A world quest with four days left
  and one with nine minutes left used to score identically, which is exactly
  backwards at the moment it matters. Anything carrying a deadline now gains
  weight on a curve that stays flat until the last two hours and then climbs
  hard -- steeply enough that the final ten minutes outrank the previous
  hour, deliberately late so that "urgent" keeps meaning something.
- `/cn mode` absorbed the new focus presets rather than sitting beside a
  second command that also meant "what am I doing tonight". A bare profile
  name still sets only the weighting, as before.

### Fixed

- **A performance regression I shipped in 0.27.0.** Follow mode asks three
  questions per redraw -- is this stop finished, what does the header say,
  what does the body say -- and each one walked the entire candidate list and
  built a throwaway set of several thousand keys. Three full scans every
  three seconds for an answer that could not have changed between them.
  The index is now memoised against the candidate generation, so it is built
  once per actual change instead of once per question. The test asserts four
  consecutive redraw queries cost at most one walk; it currently costs zero.

### Notes

- The urgency test compares the curve's slope *per second* rather than raw
  differences between unequally spaced samples. The first version of it
  failed a correct curve, which is the test being wrong rather than the code
  -- worth recording, because a test that fails for the wrong reason teaches
  you to distrust the suite.

## [0.27.0]

Four things, all of them traceable to one player's report of what he was
actually doing.

### Fixed

- **"It now says '0 available to pick up here' but I'm literally standing in
  front of one."** The count asked one map: the one under the player's feet.
  `GetBestMapForUnit` answers with the most *specific* map containing you --
  a city, a cave, a building -- while quest starts belonging to the
  surrounding zone are registered against the **parent**. Standing in a city
  and being told there is nothing here was not a rare edge case; it was the
  expected result of asking the wrong map.
  The search now covers the neighbourhood: your map, its parent, and the
  parent's other children. Continents are excluded -- that is a scan, not a
  lookup.
- **Talking to someone now counts.** A conversation cannot be wrong about
  what it is offering, while map data can simply be absent. Quests an NPC has
  offered you are remembered for fifteen minutes and counted as available,
  which covers the case where no map query knows about the pin at all.
  Accepting the quest forgets it immediately.
- World quests and bonus objectives are counted **separately** rather than
  folded in. They are available in the dictionary sense and they are not what
  a player means by "quests I can pick up here" -- there is no exclamation
  mark and nobody to talk to. Folding them in makes the number stop matching
  what is on the screen, which was the entire complaint.
- **`/cn whyzero`** explains the count: every map that was asked, what each
  answered, and why each answer was rejected. When this is wrong again, the
  first question will be "which source found it", and now there is an answer.

### Added

- **Quest progress is back, and it is a real number.** *"It doesn't show how
  many quests I've completed anymore, which I kinda liked seeing."* It was
  removed in 0.26.1 along with the bookkeeping figure it was tangled up in.
  It returns as the client's own lifetime total -- correct on a fresh install
  with no scan history, unlike the count of rows this addon had written.
  `/cn progress` shows lifetime, today, this session, your best day, and a
  rate once the session is long enough for one to mean anything.
- **`/cn loremaster` -- zones, continents and expansions.** For the player
  whose stated plan is *"complete every main quest and side quest in the
  entire game"*, the next hundred yards is not the unit of progress. This
  reads the game's own quest achievements, which have criteria the client
  enumerates, and shows which zone is closest to finished. The progress is
  real because it was read rather than computed.
- Story and side quests are counted separately, because *"finish the story,
  then do the side quests"* is how players actually talk and the client knows
  which is which.
- **`/cn follow` -- follow mode.** Everything this addon knew was something
  you had to ask for: type a command, read a list, close it, play from
  memory. Follow mode puts the current stop on screen, ticks items off as you
  finish them, and moves to the next stop when this one is clear, with the
  arrow already pointed the right way.
  Off by default. It will not move the waypoint out from under you: it
  advances when the stop is **done**, not on a timer. Wander off and it
  re-plans around where you actually are rather than herding you back. It
  says nothing in chat while it runs.
- A **Journey** tab holding the long view: lifetime and daily counts, this
  zone's completion, the zones closest to finished, and a button to start
  following.

### Notes

- The harness hit Lua's 200-local ceiling for a single function. Test
  sections are now immediately-invoked functions rather than `do` blocks: a
  `do` block shares the enclosing function's register budget, a function gets
  its own. This is a structural fix, not a workaround -- the file can now
  grow.
- The project page regained the "what it tracks" table. It was dropped in
  0.25.0 when the page was rewritten around new features -- which left the
  page describing what the addon had just learned to do and no longer saying
  what it covers. A reader deciding whether to install it needs the second
  thing more than the first.
- The zone-completion denominators are the game's, not ours. Counting "quests
  I know about" would give a denominator that grows as you play, so the
  percentage would fall as you did more. That is worse than no percentage,
  and this addon has a standing rule against inventing one.

## [0.26.1]

Reported from live play, again: *"the '0 New' just confuses me -- I feel like
'0 New' should show the amount of quests in the zone that are available but
not accepted."*

He is right, and this one was worse than a bug.

### Fixed

- **The addon was showing a player a number about itself.** "New" counted rows
  written to the addon's own database for the first time. That is a scanner
  statistic: accurate, and permanently zero once a zone has been walked, since
  there is nothing left to record. A player reads "0 new" while looking at
  exclamation marks on their screen and reasonably concludes the addon is
  broken.
  0.23.0 fixed the *cause* of that number sitting at zero. It never asked
  whether the number belonged in front of a player at all. It did not.
- Quest scans now report **how many quests are available to pick up where you
  are standing** -- a fact about the world, which keeps being true after the
  database has seen everything. The bookkeeping figure still exists and now
  goes to debug output, where it was always the only thing it was useful for.
- The Scans panel leads with the same number and demotes the database counts
  to one dim line, in that order. A player reads the top line and stops.

### Added

- **`/cn available`** lists them, with coordinates: what is on offer here that
  you have not taken. A count you cannot act on is half an answer.
- The test suite now pins the *meaning*, not just the value: the count must
  survive repeated scanning, because availability is a fact about the zone and
  not about what the addon has recorded. Reverting to the old definition fails
  the build.

## [0.26.0]

Chase something.

### Added

- **`/cn chase` â€” what actually stands between you and the thing you want.**
  Pinning a goal has always re-weighted the list. It never said what the
  *path* was: which steps remain, how many are already behind you, or which
  one to go and do now. A goal was a preference, not a plan.
  Now a goal becomes an ordered chain. Each step carries a state -- done,
  next, to do, blocked -- and the one immediate move is marked and coloured so
  it can be found without reading the rest. `/cn chase mount 1234` pins it and
  prints the path in one go, because asking how to get something is the
  clearest possible way of saying you want it.
- **Progress, where the game will vouch for it.** Achievement criteria and
  reputation standing have denominators the client supplies, so those get a
  real bar and a real percentage. Chasing Revered now reads *"1,200 of 3,000
  reputation, next: 1,800 to the next rank"* rather than a name and a shrug.
- **The Goals panel is now a chase view.** The selected goal expands into its
  chain, with completed steps struck through in green and the next one in the
  addon's blue. The button says *Next step* rather than *Navigate*, because
  those are different destinations -- the mount may be behind a dungeon you
  cannot enter, while its attunement quest is forty yards away.
- Names now come from the client when the addon has not scanned the thing
  yet. Pinning an unscanned faction used to answer *"Faction 2600"*, which is
  the addon admitting it did not look.


- **`_curseforge/DESCRIPTION.md` and `_curseforge/SUMMARY.txt` now ship with
  the code.** The CurseForge page was written fresh at upload time, which
  meant the only copy of it lived inside a web form: it could not be diffed,
  it was never reviewed alongside the change that made it true, and it drifted
  from what had actually shipped. It is now versioned next to the changelog,
  scaffolded by `init` like every other file, and excluded from the packaged
  addon by `.pkgmeta` -- it belongs in the repository, not in a player's
  AddOns folder.
- The house rules for that copy are enforced rather than written down. The
  test suite fails the build on superlatives, on claims of being the best or
  only anything, on promises about outcomes, on a summary over CurseForge's
  256-character limit, and on any HTML comment in the description. A rule that
  lives only in a comment is a rule that survives exactly as long as the
  person who remembers it.
- **Internal notes moved out of the published file.** The description carried
  its own editing rules in an HTML comment at the top. That is invisible in a
  rendered page and plainly readable to anyone who opens the file or pastes it
  somewhere that does not render Markdown -- a private note published by
  accident. The rules now live in `_curseforge/RULES.md`, which is not the
  file anyone pastes, and the description opens with its title.

### Notes

- **An appearance deliberately gets no progress bar.** An appearance needs
  *one* of its sources, not all of them, so "1 of 9 sources" would suggest
  eight remaining for something already collected. It lists every source and
  says plainly that any one is enough.
  The same rule kills the bar for anything whose only known source is a
  sentence of English: a mount described as dropping from a rare has no
  denominator, so it gets the sentence and no bar. A progress bar is the most
  confident shape information can take, and this addon does not spend that
  confidence on a guess. The test suite asserts the absence, not just the
  presence -- inventing a fraction fails the build.
- Three new client accessors carry this: full achievement criteria with their
  own counters, reputation remaining to the next rank, and every source of an
  appearance. All read-only, all degrade to "the game does not say".

## [0.25.0]

The route, drawn on the map.

### Added

- **Numbered route pins on the world map.** The addon has been grouping nearby
  work into stops, ordering those stops to minimise walking, and improving the
  order with a second pass -- and showing none of that. You saw a list and an
  arrow, with no way to know that stops three through six were the same camp,
  or that a doubling-back was deliberate.
  Now each stop is a numbered pin, in the order you would walk it. Hovering
  says what you do when you arrive -- pick up, do, hand in -- in that order.
  Clicking navigates there. The next stop wears the addon's blue; the rest are
  dimmed, so "where now" is answerable without reading numbers.
- One pin per stop, not per objective. Twelve overlapping pins on one camp say
  less than a single pin reading "3 -- pick up 2, do 4, hand in 1", and a map
  that becomes unreadable when you have a lot to do fails exactly when it
  matters. Busier stops are drawn larger; a crowded zone draws smaller pins
  rather than fewer, since dropping stops would misrepresent the route.
- `/cn pins` lists the current stops in the chat window, and `/cn pins on|off`
  toggles them. There is a checkbox in the options panel as well. On by
  default: pins are additive and read-only, and appear only on a map you have
  deliberately opened.

### Fixed

- **Zone routes ignored the type filter.** Hiding everything but quests
  changed the recommendation list and left the route alone, so `/cn zone`
  would still walk you to a pet you had explicitly said you did not want to
  see. The filter now applies to routing as well. Collection totals and
  `/cn breakdown` still count everything, as before.
- **The generator shipped stale copies of the test files.** `harness.lua`,
  `bench.lua`, `coverage.sh` and `pstest.sh` existed twice -- once where they
  are actually run, once in the build tree -- and the two drifted. The build
  copies were what shipped, so CI ran a harness older than the one every local
  run had just passed, and reported success for tests that no longer existed.
  There is now one copy of each, and the generator refuses to run if a second
  one reappears.

### Notes

- The pins are drawn for the map you are LOOKING at, which is not always the
  map you are standing in. When you open a zone you are not in, the route is
  ordered by how the stops relate to each other rather than by distance from
  your character -- your coordinates mean nothing on another map, and using
  them anyway produces an ordering that is arbitrary rather than merely
  imperfect.

## [0.24.4]

Consequence of the previous fix. No addon changes.

### Fixed

- **The new toolchain installs into the repository, and the checks started
  reading it.** The install directory is named `.lua`, so a search for files
  matching `*.lua` matched the directory itself and handed it to the compiler,
  which reasonably objected that it is a directory. Underneath it sat several
  thousand third-party files besides, some malformed on purpose because they
  are another project's test fixtures.
  Every search for Lua files is now restricted to regular files and scoped to
  ours, and the linter is configured to match. The rule excludes dotted
  directories as a class rather than naming today's, so the next tool that
  installs somewhere new is already covered.

### Added

- The syntax check now reports how many files it examined and fails if that
  number is implausibly small. A search that matches nothing passes silently,
  which is a worse failure than the one it replaced.
- The test suite plants a deliberately malformed file where the toolchain
  installs and asserts that neither the syntax check nor the linter reads it.

## [0.24.3]

The release pipeline stops depending on the runner's package manager. No addon
changes.

### Fixed

- **The previous fix was the wrong fix, and I should say so plainly.** 0.24.2
  bounded how long `apt-get` would wait for the dpkg lock, on the theory that
  the lock was held briefly at boot. It is not held briefly. Bounding the wait
  changed a build that hung for thirty-eight minutes into a build that failed
  after six, which is better but is not working.
  Lua, LuaRocks and luacheck now come from setup actions that build the
  toolchain into the workspace. There is no shared lock, no package database
  and no other process to contend with, so the entire failure class is gone
  rather than merely reported faster.
- Coverage no longer installs anything of its own, and locates luacov by asking
  LuaRocks where it put it instead of guessing from a list of directories. The
  workspace-local install used by CI appears in none of the paths it guessed.

### Added

- The test suite asserts that Lua arrives from a setup action and not from
  `apt-get`, so a later edit cannot quietly reintroduce the hang.

## [0.24.2]

The other half of the release problem. No addon changes.

### Fixed

- **A hung CI step ran for six hours and looked exactly like a working one.**
  The workflow had no `timeout-minutes` anywhere, so GitHub's six-hour default
  applied. A run that wedged on a package install simply sat "in progress"
  indefinitely -- indistinguishable, from the outside, from one still doing
  useful work. That is why a release appeared to have been pushed successfully
  and then nothing ever arrived.
  The job is now bounded at twenty minutes, and the steps that can realistically
  wedge -- package installs, lint, the harness, coverage -- carry their own
  limits. A hang now fails in minutes and says which step it was.
- Package installs run with `DEBIAN_FRONTEND=noninteractive` and
  `--no-install-recommends`. An apt configuration prompt on a runner waits on
  stdin that will never arrive, which is the classic way this happens.
- **The actual hang: apt waits for the dpkg lock forever.** A fresh Ubuntu
  runner starts `unattended-upgrades` at boot, which holds the package lock for
  a minute or two. `apt-get` has no default timeout on that lock -- it blocks
  silently until the lock clears, and if the holder never exits, it blocks until
  the job is killed. Two releases wedged there, one for thirty-eight minutes.
  Every `apt-get` call now carries `DPkg::Lock::Timeout=120`, so it gives up
  after two minutes instead of waiting indefinitely, plus `Acquire::Retries=3`
  for transient mirror failures and an outer three-attempt retry loop. The step
  either installs Lua or fails with a message, within its own six-minute bound.

### Added

- The test suite now asserts the workflow cannot hang: there must be a job-level
  timeout, and it must be short enough that a wedged run is noticed rather than
  discovered hours later. It also asserts that every `apt-get` invocation in the
  workflow carries an explicit dpkg lock timeout, so this specific hang cannot
  be reintroduced by a later edit.

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
