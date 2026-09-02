# Completion Navigator

Most completion addons answer **"what am I missing?"** and hand you a list of several thousand things. Completion Navigator answers a different question: **"what should I do next, what should I do while I am there, and how close am I to the thing I actually want?"**

It reads what you have already earned across your Warband, works out what is reachable now, ranks it, groups the nearby pieces together, and routes you through them.

Type `/cn` and it answers. Everything else is optional.

---

## Chase something

Pin a mount, an appearance, an achievement, a reputation â€” anything you are working toward â€” and the addon lays out the path:

```
/cn chase rep Severed Threads
```

> The Severed Threads â€” 1,200 of 3,000 reputation, next: 1,800 to the next rank
> `========------------` 40%

Every step in a chain carries a state. Done steps are behind you, one step is marked **next**, and blocked steps say what is blocking them. The **Next step** button goes to that step rather than to the goal itself â€” because the mount may be behind a dungeon you cannot enter yet, while its attunement quest is forty yards away.

It also says how long the whole thing is likely to take â€” as a **range**, never a figure, because task times vary by more than a third with competition, group size and luck. Where more than half the steps are kinds of thing it has never watched you do, it says *time unknown* and how many, rather than averaging its way to a number that looks like a fact.

Where the game supplies a real denominator â€” achievement criteria â€” you get a real bar. Where it does not, you get the truth instead of a bar. An appearance has several sources and needs only one of them, so it lists them and says so rather than pretending you are "1 of 9" of the way there. Reputation is reported as standing within the rank you are working on, named â€” *"11,999 of 12,000 to Revered"* â€” because the client will vouch for that and not for how far along the whole ladder you are.

## Follow the route

Start it and play. Follow mode puts the current stop on screen, ticks things off as you finish them, and moves to the next stop when this one is clear â€” with the arrow already pointed the right way.

```
/cn follow
```

Off by default, and it will not fight you: it advances when a stop is **done**, not on a timer, so the waypoint never moves out from under you mid-walk. Wander off and it re-plans around where you actually are rather than herding you back. It says nothing in chat while it runs.

## Play the time you have

```
/cn plan 30
```

Half an hour is not the same question as "what should I do next", and it gets its own answer: the stops that fit, in walking order, with what each one costs.

Travel time is **computed** from the journey you would actually make, weighing three options against each other: run it, take a flight path from the nearest point **you have discovered**, or fly it yourself â€” whichever is genuinely quicker. Your speed is measured from your own play, separately for running, riding and flying, because those are three different numbers and one median across them is wrong in all three. Task time is **learned** the same way, and learned as the *work* â€” the journey is taken back out, because the plan adds it separately and counting it twice is how a twelve-minute stop gets quoted as thirty-six. Until it has watched something enough times it says *time unknown* rather than inventing a number, so the plan starts honest and sharpens as you go.

The flight itself is costed through the **network**, not across it. A bird hops from flight master to flight master, so a pair at opposite ends of a continent is reached through the ones in between â€” and measuring the straight line between the two ends understates every long flight, always in the same direction. Routes are the shortest path through the flight points you have discovered, `/cn travel` prints the chain leg by leg so you can check it against your own map, and a route that needs more than one hop is never reported as measured: the connections between flight masters are inferred, and inferred is not the same as known.

A journey it cannot model â€” another continent, reached by a portal â€” still refuses to invent a duration, but it lists what you actually have: every hearthstone and teleport you know, with the cooldown left on each. Where a teleport lands somewhere fixed, the whole journey is costed straight through it â€” *"hearth, then four minutes"* rather than a list to work from yourself.

**Your own hearthstone included, once you have used one.** The client reports a bind point as the name of an inn, and a name does not convert to a place â€” so the one teleport every player owns was the one it could list and not price. It watches where you land after a hearth and remembers it. Until that has happened the row says it is not costed yet, rather than staying quietly absent from the arithmetic. `/cn travel` shows the whole calculation: how far to the flight point, how far in the air, how far at the far end, and what running it would have cost.

## Aim it in one command

```
/cn mode leveling
```

Levelling, collecting, reputation, achievements, professions, everything. A focus sets the weighting **and** what is shown together, because "I'm levelling tonight" means both *prefer quests* and *stop showing me pets*.

A focus raises what something is **worth to you**. It does not change how far away it is â€” so it moves the thing you asked for up the list at every distance, rather than only when it happens to be nearby.

`/cn mode fastest` is the one that is not about a subject: it weights travel and **how long the thing itself usually takes you**, measured from your own play. A kind of objective it has never timed still contributes nothing rather than a guessed duration.

`/cn mode off` restores exactly what you had before â€” including anything you had hidden yourself.

## Track the long campaign

If your plan is measured in zones rather than in the next ten minutes, `/cn progress` and `/cn loremaster` are for you.

- **`/cn progress`** â€” quests completed on this character, today, this session, your best day, and your rate.
- **`/cn loremaster`** â€” zones, continents and expansions, with the game's own quest achievements as the yardstick. Which zone is closest to finished, and how much is left in it.
- **`/cn zones`** â€” which zone to work on next, and why. Ranked by what is cheapest to finish rather than by size: a zone you are most of the way through beats a fresh one, a small fresh zone beats an enormous one, and the zone you are standing in costs nothing to reach. Zones you have never started are included, which matters when you are working through a continent.
- Story and side quests are counted separately, because *finish the story, then do the side quests* is how people actually play.

The **Journey** tab holds all of it in one place.

## Plan a zone once, walk it once

A quest is not one place. It is a **pick up**, a **do**, and a **turn in** â€” and treating it as a single dot is exactly why you cross a zone and come back.

- Objectives within about seventy yards collapse into a single **stop**.
- The route is solved stop to stop, then improved with a second pass to cut out doubling back.
- Distances are measured in **yards**, using the zone's real dimensions. A map's coordinates run 0 to 1 on both axes however the zone is actually shaped, so in a zone twice as wide as it is tall, ordering stops by raw coordinates puts them in the wrong order â€” and then optimises the wrong order confidently.
- Within a stop, things are ordered the way you would do them: collect the quests, do the work, hand them back.
- Work that batches with other work **scores higher**, so the recommendation agrees with the route instead of sending you across the zone for one quest.

`/cn zone` prints the sweep. *"3 things here â€” pick up 2, turn in 1."*

## See the plan on your map

The route is drawn on the world map as numbered pins, one per stop, in walking order.

- Hover a pin to see what you do when you arrive, in order.
- Click it to navigate there.
- The next stop wears the addon's blue; later stops are dimmed.
- One pin per stop, not per objective â€” a single pin reading "3 â€” pick up 2, do 4, hand in 1" tells you more than twelve overlapping pins on one camp.

Toggle with `/cn pins`, or from the options panel.

Lists in the window can be sorted alphabetically as well as by rank, and the filter box can follow you between tabs if you want it to (`/cn keepfilter`).

## Quests you have not picked up yet

The exclamation marks in front of you are often the cheapest next action available. Completion Navigator reads available quests from the map, not only your quest log, so *"go and collect that one"* is an answer it can give â€” weighted above an accepted quest you have not started, because the walk is short and it unlocks whatever follows.

It searches the surrounding zone as well as the map under your feet, since a city is a different map from the zone containing it, and it remembers what an NPC offered you when you spoke to them. `/cn available` lists them; `/cn whyzero` explains the count when it looks wrong.

**And the zones next door, from what you have already ridden past.** Every quest start it has ever seen is remembered by zone, so the answer is not bounded by the border you happen to be standing inside: the nearest few zones contribute their unpicked quests too, priced by how far the zone is rather than pin by pin, and the reason names the zone so the row is an instruction rather than a hint.

## Navigation without another addon

A native on-screen arrow, in the addon's own colours, that tells you whether you are walking toward your target or away from it â€” it turns and recolours the moment you pass the destination, keeps working when you step into a building or a cave, and when it hands itself to the next stop it tells you which destination it is now pointing at rather than quietly changing what it means.

Its angles are measured in yards rather than in map percentages, because a map normalises to the same square regardless of the shape of the ground: a zone twice as wide as it is tall will skew any bearing taken from raw coordinates, and most zones are not square. And which way your client counts your facing â€” a convention that cannot be derived, only observed â€” is settled by watching you move, since the direction you moved is the direction you were facing. Strafing and walking backwards are discarded rather than counted, so nothing a knockback does can flip your arrow.

`/cn navdiag` shows every value it is using, if it ever does something you did not expect. TomTom is used if you have it and is not required. HandyNotes, AllTheThings and BtWQuests are read when present, and nothing breaks when they are absent.

## Warband-aware

Account-wide unlocks are recognised as account-wide. Something another character already earned is not recommended to this one, and the reason line says which character did it.

```
/cn warband
```

Your whole Warband, one line each: level, specialization, class and faction, with what each one has recorded â€” professions, recipes, titles, reputations. The specialization is stored as the game's own id and translated when you read it, so an alt levelled on a French client does not sit in the list in French.

```
/cn alts
```

And it will tell you when you are on the wrong character â€” *"your Druid could do four of these"* â€” grouped by who, with the reason for each. It stays quiet when the answer is "you are fine where you are", never suggests switching for progress that is account-wide anyway, and says how long ago each character was last played, because that is how old its information is.

## What it tracks

Everything below is read from your own client. Nothing is downloaded, and nothing leaves your machine.

| Tracked | What it reads |
| --- | --- |
| **Quests** | Your log, quests offered nearby that you have not taken, world quests, bonus objectives, daily and weekly resets |
| **Campaign vs side quests** | The game's own campaign data, so *the story* and *everything else* stay separate |
| **Zone / continent completion** | The game's quest achievements â€” real criteria, per zone and per expansion |
| **Reputations** | Standing, renown, paragon, friendship, and which factions are account-wide |
| **Achievements** | Criteria by criteria, including the ones that carry their own counter |
| **Battle pets** | Collected, uncollected, wild-caught, duplicates |
| **Mounts** | Collected, faction-locked, and the source text the game supplies |
| **Toys** | Collected and uncollected |
| **Appearances** | By category, and every source of a specific appearance |
| **Titles** | Earned and unearned |
| **Professions & recipes** | Skill lines, learned recipes, and which vendors sell the ones you lack |
| **Currencies** | Balances, weekly caps, and what is close to overflowing |
| **Exploration** | Zone discovery achievements |
| **Rares & treasures** | Live vignettes on the minimap and where you last saw each one |
| **Vendors** | Recorded when you open a merchant, so recipes and items become findable later |
| **The Great Vault** | All three rows, what is unlocked, and what is still one step away |
| **Dungeon & raid lockouts** | What you are saved to, how many bosses are left in it, and when it resets |
| **Boss loot** | The game's own Adventure Guide, so a drop can name the boss it comes from |
| **Flight points** | The ones you have discovered, so a journey is costed the way you would actually make it |
| **Your own speed** | Running, riding and flying, measured separately from your own play |
| **Crafting orders** | The ones you placed, and anything finished and waiting |
| **Your bags** | Quest starters and uncollected mounts, pets and toys you are already carrying |
| **Your mailbox** | What is expiring, and whether anything is attached to it |
| **Keystones** | The one you hold, and that it is replaced at the reset |
| **Profession knowledge** | Weekly, capped, and gone if the week passes |
| **Appearance sets** | Which are nearly complete, with a real count of pieces |
| **Your bank** | Recorded when you open one, so what is in it stays findable |
| **The Warband bank** | Kept separate from your own, because one is reachable by this character and the other by all of them |
| **Flight paths you have flown** | So a route the addon suggests is one you can actually take |
| **World events** | Timewalking and holidays, weighted by when they end |
| **Your Warband** | Every character, what each has earned, and which unlocks are account-wide |

Where the game does not supply a trustworthy total, it reports **counts rather than a percentage**. That is a deliberate rule, not a gap â€” an invented denominator is a number that looks like a fact.

And where there is a real percentage, it is honest at both ends. **999 of 1,000 does not read as 100%**, and neither does a full progress bar â€” the last percent is the part a completionist is here for, so nothing rounds its way past it. One item still to go reads as one item still to go.

## It works in your language

The addon stores what the game gives it as **ids**, and reads names back from the client in whatever language you play in. Nothing it decides is decided by matching an English word, so features do not quietly disappear on a non-English client â€” weekly profession knowledge, which mounts are worth going for, whether an item in your bags teaches a recipe, class and race restrictions, and every count on the Scans tab read the same way in every locale the game ships.

## Where every number comes from

```
/cn â€” Scans tab
```

Some of what the addon shows is asked of the client the moment you look at it. The rest is a snapshot it took when you last scanned, and a snapshot goes out of date the day the game adds something. Both look identical on screen unless somebody says which is which.

The Scans tab is that list. One row per source, live sources separated from stored ones, each with its count, when it was last read, and a marker on anything older than a day. Clicking a row runs that source's scan; one button runs everything that has gone stale.

The Collections tab carries the same information per row, because every percentage on it is measured against the addon's own snapshot â€” which is the honest denominator and also the one that quietly ages.

## What it does with it

| | |
| --- | --- |
| **Ranks** | One list, ordered by what is actually worth doing now, with a stated reason for every line |
| **Prioritises deadlines** | Dailies, timed quests, world quests, capped currencies and the Vault all climb as their reset approaches, steeply in the last stretch |
| **Fits your session** | A plan sized to the minutes you have, from measured travel â€” flights included â€” and learned task times |
| **Explains** | `/cn why` names what is blocking something â€” level, reputation, profession, faction, an unfinished prerequisite |
| **Batches** | Nearby work collapses into stops so you stop crossing the zone and coming back |
| **Routes** | Stop to stop, improved with a second pass, drawn on your map in walking order |
| **Navigates** | A native arrow that tells you whether you are walking toward your target or away from it |
| **Chases** | The full path to a goal, step by step, with the next move marked |
| **Follows** | Hands-free: the current stop on screen, advancing as you clear it |
| **Learns** | Quest prerequisites inferred from your own play, never guessed from a single sighting |
| **Adapts** | Which kinds of objective you actually go and do, within clamped limits, and it says so on the line |
| **Shows its working** | `/cn order` breaks the ranking into the terms that produced it |
| **Keeps up** | Finish something and it leaves the list, the route and the plan at once â€” not on a timer, and not when some unrelated thing happens along |

## When you finish something

The whole point of a list of what to do next is that finishing something changes it. That is easy to say and surprisingly easy to get wrong: a part of the addon that reads your quest log has to be told when your quest log changes, and there is nothing to notice when nobody wired that up.

So the addon is built so it cannot be quiet about it. Every part that reads something â€” your quest log, your bags, your collections, where you are standing â€” has to declare what it reads, and the build refuses to produce a release where one of them does not. It is the same argument as never inventing a percentage: the addon would rather fail loudly than be confidently out of date.

Concretely, this is what stops being true the moment you act: a quest handed in, a goal completed, a mount or toy collected, a deferral you set an hour ago running out, a currency the game has retired, a zone you have finished exploring, and a character on your Warband you have not played for a month. None of them wait for a timer.

## Dungeons and raids

```
/cn instances
```

What you are saved to, how much of each is left, and when it resets. A lockout you are part-way through is some of the cheapest progress in the game â€” those kills are spent effort with an expiry on them â€” so an unfinished one competes for *what next*. One you have not started is deliberately left alone: that is a decision about your evening, not a next action.

```
/cn drops Ashes of Al'ar
```

Which boss drops it, in which instance, and whether your own lockout is in the way. Chasing an instance drop now names the boss instead of handing you a sentence, and says *blocked, resets in two days* when you are already saved and cleared.

Reading the game's Adventure Guide changes what it is displaying, so the addon will not read it while you have it open, and puts its selection back exactly as it found it when you do not.

## It learns which things you actually do

```
/cn learned
```

The addon notices which kinds of objective you go and do, and leans that way. The guardrails matter more than the learning: nothing moves until a type has been shown 25 times, the adjustment is clamped so a type you skip gets quieter but never silent, and every adjusted line **says on the line** that it was adjusted. The counters decay, so it tracks how you play now rather than how you played in June. A focus you set with `/cn mode` always beats a habit it inferred.

**And it only learns from what it can actually see you finish.** The game announces a quest turned in, an achievement earned, and a pet, mount or toy collected â€” so those are the types it forms an opinion about. It cannot see the moment you collect an appearance or cross a reputation threshold, so it forms no opinion about those and says nothing about them. That distinction is the whole guardrail: a counter that can only ever read zero is not evidence that you ignore something, and an addon that treated it as evidence would be quietly telling you something about yourself that it made up.

`/cn learned reset` forgets it. `/cn learned off` switches it off. Hiding a type outright is still `/cn types`.

## It looks in your bags

```
/cn bags
```

A surprising amount of *what should I do next* is already in there: the item that starts a quest, sitting since a boss dropped it, mounts, pets and toys you own and have not learned, and recipes you bought and never used. Those cost **zero** travel, because they are in your bag â€” which makes them the cheapest thing the addon can ever recommend.

It also knows how close you are, in things rather than in percent. *One more feather* and *eighteen more boars* are different suggestions, and the first one outranks a quest you have not started.

Nothing is used, learned, moved or sold on your behalf. It reads.

The same rule covers your interface. A full pet or toy scan has to widen the journal's filters to see everything you own â€” and it puts them back exactly as it found them, including the ones you had switched off.

## Things with a clock on them

```
/cn clock
```

Weekly profession knowledge, which is the most permanently missable thing in the game â€” a week not collected does not come back. Mail about to expire **with something attached** â€” expired mail is destroyed, not returned, and warning you about an empty message from a stranger is how an addon teaches you to ignore it. The keystone that is replaced at the reset whether you use it or not. Heirlooms.

## Sets, not just pieces

```
/cn sets
```

Collecting appearances is done by set â€” nobody wants *one more shoulder*, they want the set finished. The game supplies a real denominator there, which this addon is otherwise short of, so **four of five pieces** is a fact rather than an estimate. A set you have barely begun is a decision about your evening, not a next action, and is left out.

## Where to go when this zone is done

```
/cn elsewhere
```

What is worth doing outside this zone, ordered by **how long it takes to get there** rather than how far away it is â€” a flight point changes that answer, and a mountain range changes it the other way.

Another continent is costable now too, where a teleport you know lands on the right side of it: the addon prices the teleport, the cooldown you would wait through, and the ordinary journey from where it drops you.

## Why is it in this order?

```
/cn order
```

Every term in the score for the top few, biggest first, adding up to the number shown â€” including the focus you set and any adjustment the addon made for itself, which are multipliers on the whole rather than terms of their own and are shown as what they did to the total. `/cn why` explains one objective; this explains the ranking â€” including why the thing you expected to see at the top is not.

```
/cn urgency
```

Deadlines are the heaviest thing in that score, and until now the curve behind them could only be reasoned about. This draws it: what a reset is worth at ten distances from it, from a week out to the last hour.

**Not knowing where something is has a real cost, and it is not the same as there being nowhere to go.** A currency, a reputation or a renown track is not *anywhere* â€” there is no walk, so nothing is charged for one. A quest whose coordinates the client has not given up is somewhere the addon cannot name, and it is charged the pessimistic figure rather than the optimistic one, the same way a journey it cannot compute already is. Getting that wrong in the other direction is how a list fills up with things that have no location: they look free.

## It knows what you are in the middle of

Dead, in a group, in an instance, or out in the world alone are four different situations, and only one of them makes "go and collect a battle pet" a sensible thing to say.

```
/cn situation
```

Dead, and it says so before anything else.

**Inside an instance, it ranks by where things are.** Anything with a known location that is not in here with you is ranked down and says why â€” a world quest three zones away is not something you can go and do; it is something you can do after a loading screen. Anything that *is* in here, or that has no location at all â€” the mount off the last boss, a currency, a collection â€” is left exactly where it was. That holds whether you walked in with four other people or on your own, because the doorway is a fact about the doorway.

Being in a **group** is a separate fact and gets a separate weighting: four people waiting at a boss is a reason not to suggest a solo detour, and it is not a reason to bury the thing everyone came in for. Down, never hidden, because hiding something is your decision and not a counter's.

**And a quest your group shares outranks one only you are on.** Four of you standing in a zone, one of the six quests on the list is one all four are carrying: that one is worth four times the work, and every player already knows it â€” it is why people ask "anyone else need this?" out loud. The addon reads *your own client* about people already in your group. Nothing is sent, no protocol is agreed, nobody else has to be running this addon, and outside a group it says nothing at all.

## Quests you walked past

```
/cn unpicked
```

The game only lists quest pins for the map you are looking at, so "what is waiting three zones away" used to be unanswerable. It still cannot enumerate a zone it has never seen â€” but it remembers every quest start it *has* seen, by zone, which covers everywhere you have actually been.

## Built to be read

A scale for everything it draws, and a colourblind mode that changes the arrow's **palette** as well as labelling it in words. The arrow's whole language is colour, and gold against red is the worst pair there is for the commonest form of colour blindness â€” so the alternate palette separates by lightness as well as by hue, and the build checks that separation rather than trusting somebody's eye.

**Text size is a separate control from window size.** `/cn scale` grows the frame and everything in it; `/cn textsize` grows only the letters and leaves the window where it is. It uses whatever font your client already uses, at a larger size, and it applies to text the window has already drawn rather than only to what it builds next.

**And you can search the whole window at once.** `/cn find <text>` looks on every tab and says which one the match is on, so finding something does not require knowing which tab it lives on first. The filter box does the same thing quietly: type on the wrong tab and it tells you which other tabs match, instead of saying nothing matched while the answer sits one tab over.

**Hovering a row says why it matters, not what it is.** A world quest says when it disappears whether you do it or not, and roughly how far away it is by the route this addon would take. A rare says whether this character has already cleared it since the last reset. A type filter says how much of the list it is currently holding â€” which is the only thing that makes switching it off a decision rather than a guess.

```
/cn scale 1.25
/cn colourblind
```

Both of those are in the Settings tab now, along with everything else the addon can be told â€” grouped by what the setting is about rather than by the order it was written, and every control says what it does when you hover it. They used to be typing-only, which is the sharpest version of an accessibility problem: the people who most need a larger interface are the least likely to find `/cn scale 1.4` in a hundred-line help listing.

An optional one-line heads-up display â€” drag it anywhere, click it to navigate, right-click to put that one off for an hour, and close it with the **x** in its corner â€” a filter box in the window, keybindings for the things you do often, and a real entry in the game's own options list rather than only inside a window you have to know how to open.

Every list can be sorted A to Z or reversed, and sorting reads the words rather than the colour in front of them â€” so a finished goal does not sort above an unfinished one because of how it is tinted. Rows that belong together stay together: a goal moves with its chain, a vault slot with its thresholds. The filter box greys itself out on the one tab that has no list, instead of accepting text that could not go anywhere. Anything a button does is answered in the window, where the click happened; anything you type is answered in chat, where you typed it. And Escape closes the window, the welcome screen and the export box; the arrow, the heads-up line and the follow frame each carry their own **x**.

A row that does something carries a marker, not just a slightly brighter grey â€” colour alone is not an explanation, and it is no explanation at all to the one player in twelve who cannot see the difference. A button that cannot act is drawn as unavailable rather than left looking live. A checkbox's words are part of what you can hover, not just the box. And a search that matches nothing says so, instead of falling back to the message about never having scanned.

## When something goes wrong

```
/cn errors
```

Failures inside the addon are caught so they cannot break your session â€” which is also why they were invisible. They are kept now, so a bug report can carry the text instead of a description of it.

## Share what your play taught it

```
/cn contribute
```

Prints one line of quest IDs and orderings â€” no character name, no realm, no timestamps, nothing that identifies you. You can read the whole thing before deciding to send it, which is the point of a format you can read.

Nothing is uploaded. The addon *cannot* upload; addons have no network access at all. Pasting it into an issue is the entire transport, and chains that arrive that way are recorded as observations, never as fact.

**And you can ask which of its claims have never been checked.** `/cn provenance` lists every prerequisite the addon believes on evidence rather than on somebody having read it â€” learned from your own play, contributed by another player, or imported by hand â€” with how many characters or contributions stand behind each. `/cn why` has always named the source of an answer; this is the opposite question, and it is where checking one starts.

**It also records where a quest was handed in.** A quest is a pick up, a do and a turn in, and the client's own waypoint moves with the work â€” so once a quest is ready to hand back, the addon walks you to where *this account* watched that quest be turned in, when the client will not say. It is labelled as an observation rather than as a checked fact, and it goes into `/cn contribute` with everything else.

**And another addon can supply that data.** [Navigator Data](https://www.curseforge.com/wow/addons/navigator-data) is a companion that contributes hand-checked quest chains, turn-in spots and gating â€” no window, no commands, no settings; it hands over a table and stops. It is entirely optional, and everything here works without it.

What matters is that installing it does not blur the line this addon draws. Rows from a supplier are counted separately from rows checked by this addon, `/cn providers` names who supplied what, and `/cn selftest` reports it. Two sources claiming the same quest is recorded and named rather than resolved quietly in favour of whoever loaded last. "Checked by hand" is a claim about *who* did the checking, and it survives having more than one answer.

## Ask it whether it is working

```
/cn selftest
```

Twenty checks that run against your own client and report what they actually found â€” whether your position converts, whether the arrow's facing has been confirmed against your movement, whether the map reports quests you have not accepted yet, whether your lockouts and the Adventure Guide are readable, whether achievement criteria carry their counters, how much you are storing, and whether the engine can answer "what next" at all.

One of them is new and worth knowing about after a patch: **whether every client function this addon calls still exists**. An addon reads the game through a couple of hundred named functions, and every expansion renames or removes some. Each call is guarded, which is the right way to write it and also the reason a removed function makes no noise at all â€” the guard simply goes false and that feature stops working, silently, possibly for months. The list of names is generated from the source rather than written by hand, so it cannot fall out of step with what the addon actually calls, and the check will tell you exactly which ones your client no longer has.

Every check exists because the thing it covers was once broken in a release, and was found by somebody playing rather than by a test. Checks report the value they saw rather than the word "failed", so a bug report is a copy and paste. A check the client cannot answer says so and skips â€” it does not quietly pass.

## In your language

German, Spanish, French, Italian, Korean, Portuguese, Russian and both Chinese scripts are started. Anything not yet translated falls back to English rather than to a blank label or a raw identifier, so a partly translated addon is still a working one. `/cn locale` says how far along your language is, `/cn locale missing` prints exactly the list a translator would work from, and `/cn locale export` produces a ready-made block to fill in â€” no toolchain, no file format to learn. Nothing was machine-translated to make that number look larger, and the build refuses to ship a string that is translated everywhere and displayed nowhere.

## Show only what you care about

Hide any objective type you are not working on â€” quests, pets, mounts, toys, appearances, reputations, professions, currencies, exploration, rares. Hidden types drop out of the recommendations **and** out of the route, so you are not walked to something you said you did not want. Collection totals still count everything.

**And you can put one specific thing off for as long as you like.** `/cn defer` takes an hour, the rest of today, tomorrow, this week, until the weekly reset, or until you undo it â€” the reset being the one that matches how most of the game is actually scheduled. It comes back on its own when the time is up; `/cn unhide <id>` brings it back sooner, and `/cn hidden` lists everything you have put aside and when each returns. Deferring is not the same as ignoring: ignoring is permanent and deferring is a decision about *now*, which is the decision this addon is for.

---

## Commands

| Command | What it does |
| --- | --- |
| `/cn` | What to do next |
| `/cn chase <type> <id>` | What stands between you and a goal, step by step |
| `/cn follow` | Follow the route, hands-free |
| `/cn plan <minutes>` | What fits in the time you have |
| `/cn mode <focus>` | Aim the whole addon at one kind of play |
| `/cn alts` | Which character should be doing what |
| `/cn zones` | Which zone to work on next, and why |
| `/cn navdiag` | Exactly what the arrow is doing, and why |
| `/cn selftest` | Check the addon against your live client and report what it finds |
| `/cn instances` | What you are saved to, and how much of it is left |
| `/cn drops <name>` | Which boss drops it, and whether you are locked to it |
| `/cn learned` | What the addon has worked out about how you play |
| `/cn travel` | How long it takes to reach the top recommendation, and by what route â€” leg by leg |
| `/cn handynotes` | What HandyNotes plugins are drawing on this map, shown rather than scored |
| `/cn situation` | What the addon thinks you are in the middle of |
| `/cn unpicked` | Quests you have seen and never picked up, by zone |
| `/cn find <text>` | Find something without knowing which tab it is on |
| `/cn provenance` | Which chain claims have never been checked by a person |
| `/cn textsize <100-200>` | Larger text, without resizing the window |
| `/cn orders` | Crafting orders you placed, and anything ready to collect |
| `/cn hud` | A small always-on line showing the next thing |
| `/cn errors` | Anything that went wrong inside the addon this session |
| `/cn contribute` | Share the quest chains your play has taught it |
| `/cn bags` | What is in your bags that you could act on now |
| `/cn clock` | Everything with a deadline that is not a quest |
| `/cn elsewhere` | What is worth doing in other zones, and how far away it is |
| `/cn order` | Why the list is in the order it is in |
| `/cn urgency` | What a deadline is worth, at every distance from it |
| `/cn sets` | Appearance sets nearly finished, and your guild |
| `/cn locale` | Which language the addon is using, and how much is translated |
| `/cn dbsize` | How much the addon is storing, and where |
| `/cn setup check` | What it still cannot see, without rescanning |
| `/cn setup again` | Forget what setup recorded and read everything once more |
| `/cn progress` | Quests completed: lifetime, today, this session |
| `/cn loremaster` | Zone, continent and expansion completion |
| `/cn available` | Quests offered here that you have not taken |
| `/cn zone` | The full sweep for this zone, stop by stop |
| `/cn pins` | Route pins on the world map â€” `on`, `off`, `refresh` |
| `/cn go` | Navigate to the top recommendation |
| `/cn why <id>` | Why this is recommended, and what is blocking it |
| `/cn types` | Choose which kinds of objective appear |
| `/cn defer <how long>` | Put the current recommendation off â€” an hour, today, this week, until the reset |
| `/cn goal <type> <id>` | Pin a goal and weight everything toward it |
| `/cn vault` | Great Vault progress |
| `/cn breakdown` | Collection totals by category |
| `/cn setup` | Full rescan |
| `/cn help` | Everything |

There is a window (`/cn ui`), a minimap button, tooltip lines on items and NPCs, and an optional LibDataBroker feed.

---

## Built to stay out of the way

An addon that watches this much of the game can easily cost more than it gives back. This one is measured, not assumed: a full rebuild of everything it tracks â€” at a realistic scale of 1,800 pets, 3,000 achievements, 2,500 recipes, 3,000 appearance sets, five full bags and a continent's worth of flight points â€” costs about **four milliseconds**, and the answer to "what next?" is served from cache in **five microseconds**.

Those figures got better by making the benchmark harder, repeatedly. The most expensive things the addon does had been measured against fixtures holding three appearance sets, three bags and three flight points, and at that size they all looked free. The most recent round found the same trap in a subtler form: the benchmark's sixty flight points were clustered into one corner of the map so they would not disturb any test's answer, and a corner cluster is precisely the shape the route search's pruning rejects without looking â€” so it was measuring a square the search never walks.

Spread across a continent, as they really are, two travel budgets turned out to be over their stated ceilings while the benchmark reported them at a fifth of it. And the zone router â€” which runs every two seconds while you have the Zone tab open â€” cost thirty-three milliseconds and several megabytes of garbage at the size a busy evening actually produces, because it rebuilt the whole route for every pair of stops it considered. It builds nothing now: reversing a segment changes exactly two edges, so the comparison is four distances. Same routes, a fortieth of the work.

Tooltip lines are the same story: hovering an item answers from an index rather than searching everything the addon knows, so mousing across a full bag costs nothing you can feel. It gets there by not doing the same work twice. Counting the quests you have completed, for instance, asks the game once and remembers the answer â€” the alternative is rebuilding a list of every quest you have ever finished each time the window redraws, which on a long-lived character is thousands of entries to display one number. Providers keep shortlists of the handful of rows that could actually be actionable, rather than re-examining thousands on every update. Nothing is rebuilt because a timer fired; it is rebuilt because something you did changed the answer.

It is careful about disk, too â€” about a third less than it used to write, after two releases spent measuring it. The game rewrites an addon's saved data in full every time you log out and reads it back every time you log in, so this one stores only what the game cannot tell it instantly â€” your history, what your other characters have done, and your own choices. It does not keep a second copy of things the client already knows. `/cn dbsize` will show you exactly what it is holding.

There is a benchmark in the repository, and the numbers above come out of it rather than out of a marketing meeting.

## Notes

- Where the game does not provide a trustworthy denominator, this addon reports counts rather than inventing a completion percentage. That rule is why some things get a progress bar and others deliberately do not.
- "Available to pick up nearby" counts what is genuinely within reach and reports anything further out separately, rather than calling a four-minute ride "here".
- Follow mode never moves your waypoint during a fight. Whatever it was going to do happens when the fight ends.
- While you are a ghost, the only thing it recommends is your body â€” pointed at, not just mentioned. Everything else keeps.
- On a fresh install it asks you to run one scan, and keeps asking until you have â€” an addon that knows nothing about your collections should say so rather than quietly looking thin. Once scanned, it never mentions it again.
- Nothing is taken over without being asked. Auto-advancing the waypoint and rare alerts are off by default.
- No external server, no account required, no data leaves your machine.
- The release build runs the addon's whole test suite â€” on Lua 5.4 and on the game's own Lua 5.1 â€” plus a mutation pass that checks the tests would actually notice if the code were wrong, and a stub audit that compares the test doubles against a recording from a real client. A build that fails any of it is not published.

Completion Navigator is a product of **Dam Beaver Studios, LLC**. Authored by **Travis A. Bryan I**. Bug reports and feature requests are welcome on the issue tracker.
