# Completion Navigator

Most completion addons answer **"what am I missing?"** and hand you a list of several thousand things. Completion Navigator answers a different question: **"what should I do next, what should I do while I am there, and how close am I to the thing I actually want?"**

It reads what you have already earned across your Warband, works out what is reachable now, ranks it, groups the nearby pieces together, and routes you through them.

---

## Chase something

Pin a mount, an appearance, an achievement, a reputation â€” anything you are working toward â€” and the addon lays out the path:

```
/cn chase rep 2600
```

> The Severed Threads â€” 1,200 of 3,000 reputation, next: 1,800 to the next rank
> `========------------` 40%

Every step in a chain carries a state. Done steps are behind you, one step is marked **next**, and blocked steps say what is blocking them. The **Next step** button goes to that step rather than to the goal itself â€” because the mount may be behind a dungeon you cannot enter yet, while its attunement quest is forty yards away.

It also says how long the whole thing is likely to take â€” as a **range**, never a figure, because task times vary by more than a third with competition, group size and luck. Where more than half the steps are kinds of thing it has never watched you do, it says *time unknown* and how many, rather than averaging its way to a number that looks like a fact.

Where the game supplies a real denominator â€” achievement criteria, reputation standing â€” you get a real bar. Where it does not, you get the truth instead of a bar. An appearance has several sources and needs only one of them, so it lists them and says so rather than pretending you are "1 of 9" of the way there.

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

Travel time is **computed** from the journey you would actually make, weighing three options against each other: run it, take a flight path from the nearest point **you have discovered**, or fly it yourself â€” whichever is genuinely quicker. Your speed is measured from your own play, separately for running, riding and flying, because those are three different numbers and one median across them is wrong in all three. Task time is **learned** the same way. Until it has watched something enough times it says *time unknown* rather than inventing a number, so the plan starts honest and sharpens as you go.

A journey it cannot model â€” another continent, reached by a portal â€” still refuses to invent a duration, but it now lists what you actually have: every hearthstone and teleport you know, with the cooldown left on each. `/cn travel` shows the whole calculation: how far to the flight point, how far in the air, how far at the far end, and what running it would have cost.

## Aim it in one command

```
/cn mode leveling
```

Levelling, collecting, reputation, achievements, professions, everything. A focus sets the weighting **and** what is shown together, because "I'm levelling tonight" means both *prefer quests* and *stop showing me pets*.

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

## Navigation without another addon

A native on-screen arrow, in the addon's own colours, that tells you whether you are walking toward your target or away from it â€” it turns and recolours the moment you pass the destination, keeps working when you step into a building or a cave, and when it hands itself to the next stop it tells you which destination it is now pointing at rather than quietly changing what it means.

Its angles are measured in yards rather than in map percentages, because a map normalises to the same square regardless of the shape of the ground: a zone twice as wide as it is tall will skew any bearing taken from raw coordinates, and most zones are not square. And which way your client counts your facing â€” a convention that cannot be derived, only observed â€” is settled by watching you move, since the direction you moved is the direction you were facing. Strafing and walking backwards are discarded rather than counted, so nothing a knockback does can flip your arrow.

`/cn navdiag` shows every value it is using, if it ever does something you did not expect. TomTom is used if you have it and is not required. HandyNotes, AllTheThings and BtWQuests are read when present, and nothing breaks when they are absent.

## Warband-aware

Account-wide unlocks are recognised as account-wide. Something another character already earned is not recommended to this one, and the reason line says which character did it.

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
| **Flight paths you have flown** | So a route the addon suggests is one you can actually take |
| **World events** | Timewalking and holidays, weighted by when they end |
| **Your Warband** | Every character, what each has earned, and which unlocks are account-wide |

Where the game does not supply a trustworthy total, it reports **counts rather than a percentage**. That is a deliberate rule, not a gap â€” an invented denominator is a number that looks like a fact.

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

`/cn learned reset` forgets it. `/cn learned off` switches it off. Hiding a type outright is still `/cn show`.

## It looks in your bags

```
/cn bags
```

A surprising amount of *what should I do next* is already in there: the item that starts a quest, sitting since a boss dropped it, mounts, pets and toys you own and have not learned, and recipes you bought and never used. Those cost **zero** travel, because they are in your bag â€” which makes them the cheapest thing the addon can ever recommend.

It also knows how close you are, in things rather than in percent. *One more feather* and *eighteen more boars* are different suggestions, and the first one outranks a quest you have not started.

Nothing is used, learned, moved or sold on your behalf. It reads.

## Things with a clock on them

```
/cn clock
```

Mail about to expire **with something attached** â€” expired mail is destroyed, not returned, and warning you about an empty message from a stranger is how an addon teaches you to ignore it. The keystone that is replaced at the reset whether you use it or not. Weekly profession knowledge, which is the most permanently missable thing in the game. Heirlooms.

## Sets, not just pieces

```
/cn sets
```

Collecting appearances is done by set â€” nobody wants *one more shoulder*, they want the set finished. The game supplies a real denominator there, which this addon is otherwise short of, so **four of five pieces** is a fact rather than an estimate. A set you have barely begun is a decision about your evening, not a next action, and is left out.

## Where to go when this zone is done

```
/cn nearby
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

## It knows what you are in the middle of

Dead, in a group, in an instance, or out in the world alone are four different situations, and only one of them makes "go and collect a battle pet" a sensible thing to say.

```
/cn situation
```

Dead, and it says so before anything else. In a dungeon with four other people, outside work ranks down until you leave â€” down, never hidden, because hiding something is your decision and not a counter's.

## Quests you walked past

```
/cn waiting
```

The game only lists quest pins for the map you are looking at, so "what is waiting three zones away" used to be unanswerable. It still cannot enumerate a zone it has never seen â€” but it remembers every quest start it *has* seen, by zone, which covers everywhere you have actually been.

## Built to be read

A scale for everything it draws, and a mode that labels the arrow in words as well as colour â€” the arrow's whole language was colour, which is exactly the design that fails a colourblind player.

```
/cn scale 1.25
/cn colourblind
```

An optional one-line heads-up display (`/cn hud`), a filter box in the window, keybindings for the things you do often, and an entry in the game's own options list rather than only inside a window you have to know how to open.

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

## Ask it whether it is working

```
/cn selftest
```

Eighteen checks that run against your own client and report what they actually found â€” whether your position converts, whether the arrow's facing has been confirmed against your movement, whether the map reports quests you have not accepted yet, whether your lockouts and the Adventure Guide are readable, whether achievement criteria carry their counters, how much you are storing, and whether the engine can answer "what next" at all.

One of them is new and worth knowing about after a patch: **whether every client function this addon calls still exists**. An addon reads the game through a couple of hundred named functions, and every expansion renames or removes some. Each call is guarded, which is the right way to write it and also the reason a removed function makes no noise at all â€” the guard simply goes false and that feature stops working, silently, possibly for months. The list of names is generated from the source rather than written by hand, so it cannot fall out of step with what the addon actually calls, and the check will tell you exactly which ones your client no longer has.

Every check exists because the thing it covers was once broken in a release, and was found by somebody playing rather than by a test. Checks report the value they saw rather than the word "failed", so a bug report is a copy and paste. A check the client cannot answer says so and skips â€” it does not quietly pass.

## In your language

German, Spanish, French, Italian, Korean, Portuguese, Russian and both Chinese scripts are started. Anything not yet translated falls back to English rather than to a blank label or a raw identifier, so a partly translated addon is still a working one. `/cn locale` says how far along your language is, and `/cn locale missing` prints exactly the list a translator would work from. Nothing was machine-translated to make that number look larger.

## Show only what you care about

Hide any objective type you are not working on â€” quests, pets, mounts, toys, appearances, reputations, professions, currencies, exploration, rares. Hidden types drop out of the recommendations **and** out of the route, so you are not walked to something you said you did not want. Collection totals still count everything.

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
| `/cn travel` | How long it takes to reach the top recommendation, and by what route |
| `/cn situation` | What the addon thinks you are in the middle of |
| `/cn waiting` | Quests you have seen and never picked up, by zone |
| `/cn orders` | Crafting orders you placed, and anything ready to collect |
| `/cn hud` | A small always-on line showing the next thing |
| `/cn errors` | Anything that went wrong inside the addon this session |
| `/cn contribute` | Share the quest chains your play has taught it |
| `/cn bags` | What is in your bags that you could act on now |
| `/cn clock` | Everything with a deadline that is not a quest |
| `/cn nearby` | What is worth doing outside this zone, and how far away it is |
| `/cn order` | Why the list is in the order it is in |
| `/cn urgency` | What a deadline is worth, at every distance from it |
| `/cn sets` | Appearance sets nearly finished, and your guild |
| `/cn locale` | Which language the addon is using, and how much is translated |
| `/cn dbsize` | How much the addon is storing, and where |
| `/cn setup check` | What it still cannot see, without rescanning |
| `/cn progress` | Quests completed: lifetime, today, this session |
| `/cn loremaster` | Zone, continent and expansion completion |
| `/cn available` | Quests offered here that you have not taken |
| `/cn zone` | The full sweep for this zone, stop by stop |
| `/cn pins` | Route pins on the world map â€” `on`, `off`, `refresh` |
| `/cn go` | Navigate to the top recommendation |
| `/cn why <id>` | Why this is recommended, and what is blocking it |
| `/cn show` | Choose which kinds of objective appear |
| `/cn goal <type> <id>` | Pin a goal and weight everything toward it |
| `/cn vault` | Great Vault progress |
| `/cn breakdown` | Collection totals by category |
| `/cn setup` | Full rescan |
| `/cn help` | Everything |

There is a window (`/cn ui`), a minimap button, tooltip lines on items and NPCs, and an optional LibDataBroker feed.

---

## Built to stay out of the way

An addon that watches this much of the game can easily cost more than it gives back. This one is measured, not assumed: a full rebuild of everything it tracks â€” at a realistic scale of 1,800 pets, 3,000 achievements, 2,500 recipes, 3,000 appearance sets, five full bags and a continent's worth of flight points â€” costs about **four milliseconds**, and the answer to "what next?" is served from cache in **five microseconds**.

Those figures got better by making the benchmark harder. Three of the most expensive things the addon does had been measured against fixtures holding three appearance sets, three bags of items and three flight points, and at that size all three looked free. At the size the game actually produces, a rebuild cost eleven milliseconds â€” most of a frame, on every event that changes the answer. Costing a single journey has since gone from 1.48 milliseconds to 0.04, and no answer changed.

Tooltip lines are the same story: hovering an item answers from an index rather than searching everything the addon knows, so mousing across a full bag costs nothing you can feel. It gets there by not doing the same work twice. Counting the quests you have completed, for instance, asks the game once and remembers the answer â€” the alternative is rebuilding a list of every quest you have ever finished each time the window redraws, which on a long-lived character is thousands of entries to display one number. Providers keep shortlists of the handful of rows that could actually be actionable, rather than re-examining thousands on every update. Nothing is rebuilt because a timer fired; it is rebuilt because something you did changed the answer.

It is careful about disk, too â€” about a third less than it used to write, after two releases spent measuring it. The game rewrites an addon's saved data in full every time you log out and reads it back every time you log in, so this one stores only what the game cannot tell it instantly â€” your history, what your other characters have done, and your own choices. It does not keep a second copy of things the client already knows. `/cn dbsize` will show you exactly what it is holding.

There is a benchmark in the repository, and the numbers above come out of it rather than out of a marketing meeting.

## Notes

- Where the game does not provide a trustworthy denominator, this addon reports counts rather than inventing a completion percentage. That rule is why some things get a progress bar and others deliberately do not.
- "Available to pick up nearby" counts what is genuinely within reach and reports anything further out separately, rather than calling a four-minute ride "here".
- Follow mode never moves your waypoint during a fight. Whatever it was going to do happens when the fight ends.
- On a fresh install it asks you to run one scan, and keeps asking until you have â€” an addon that knows nothing about your collections should say so rather than quietly looking thin. Once scanned, it never mentions it again.
- Nothing is taken over without being asked. Auto-advancing the waypoint and rare alerts are off by default.
- No external server, no account required, no data leaves your machine.

Completion Navigator is a product of **Dam Beaver Studios, LLC**. Authored by **Travis A. Bryan I**. Bug reports and feature requests are welcome on the issue tracker.
