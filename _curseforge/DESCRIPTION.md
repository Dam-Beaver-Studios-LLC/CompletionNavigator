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

Where the game supplies a real denominator â€” achievement criteria, reputation standing â€” you get a real bar. Where it does not, you get the truth instead of a bar. An appearance has several sources and needs only one of them, so it lists them and says so rather than pretending you are "1 of 9" of the way there.

## Follow the route

Start it and play. Follow mode puts the current stop on screen, ticks things off as you finish them, and moves to the next stop when this one is clear â€” with the arrow already pointed the right way.

```
/cn follow
```

Off by default, and it will not fight you: it advances when a stop is **done**, not on a timer, so the waypoint never moves out from under you mid-walk. Wander off and it re-plans around where you actually are rather than herding you back. It says nothing in chat while it runs.

## Track the long campaign

If your plan is measured in zones rather than in the next ten minutes, `/cn progress` and `/cn loremaster` are for you.

- **`/cn progress`** â€” quests completed on this character, today, this session, your best day, and your rate.
- **`/cn loremaster`** â€” zones, continents and expansions, with the game's own quest achievements as the yardstick. Which zone is closest to finished, and how much is left in it.
- Story and side quests are counted separately, because *finish the story, then do the side quests* is how people actually play.

The **Journey** tab holds all of it in one place.

## Plan a zone once, walk it once

A quest is not one place. It is a **pick up**, a **do**, and a **turn in** â€” and treating it as a single dot is exactly why you cross a zone and come back.

- Objectives within about seventy yards collapse into a single **stop**.
- The route is solved stop to stop, then improved with a second pass to cut out doubling back.
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

## Quests you have not picked up yet

The exclamation marks in front of you are often the cheapest next action available. Completion Navigator reads available quests from the map, not only your quest log, so *"go and collect that one"* is an answer it can give â€” weighted above an accepted quest you have not started, because the walk is short and it unlocks whatever follows.

It searches the surrounding zone as well as the map under your feet, since a city is a different map from the zone containing it, and it remembers what an NPC offered you when you spoke to them. `/cn available` lists them; `/cn whyzero` explains the count when it looks wrong.

## Navigation without another addon

A native on-screen arrow, in the addon's own colours, that tells you whether you are walking toward your target or away from it. TomTom is used if you have it and is not required. HandyNotes, AllTheThings and BtWQuests are read when present, and nothing breaks when they are absent.

## Warband-aware

Account-wide unlocks are recognised as account-wide. Something another character already earned is not recommended to this one, and the reason line says which character did it.

## Show only what you care about

Hide any objective type you are not working on â€” quests, pets, mounts, toys, appearances, reputations, professions, currencies, exploration, rares. Hidden types drop out of the recommendations **and** out of the route, so you are not walked to something you said you did not want. Collection totals still count everything.

---

## Commands

| Command | What it does |
| --- | --- |
| `/cn` | What to do next |
| `/cn chase <type> <id>` | What stands between you and a goal, step by step |
| `/cn follow` | Follow the route, hands-free |
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

## Notes

- Where the game does not provide a trustworthy denominator, this addon reports counts rather than inventing a completion percentage. That rule is why some things get a progress bar and others deliberately do not.
- Nothing is taken over without being asked. Auto-advancing the waypoint and rare alerts are off by default.
- No external server, no account required, no data leaves your machine.

Completion Navigator is a product of **Dam Beaver Studios, LLC**. Authored by **Travis A. Bryan I**. Bug reports and feature requests are welcome on the issue tracker.
