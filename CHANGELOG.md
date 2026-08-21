# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

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
