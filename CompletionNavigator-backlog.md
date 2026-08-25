# Completion Navigator — recommendation backlog

**Revised for 0.63.0.** The previous revision of this file was written against
0.42.0 and had gone badly stale: of its fifty-three open items, forty-one had
shipped and were still listed as outstanding. That is worse than no backlog,
because it makes a release plan out of work already done. Every item below was
checked against the code in this tree on the day it was written.

Timing key: **Next** = the recommended next build · **Short** = within a few
releases · **Later** = real value, no urgency · **Ongoing** = a cadence, not a
build · **Declined** = recommended *against*, with the reason.

---

## 1. Travel and navigation

1. **Flight-restricted zone handling, from the client rather than from
   observation** — `Travel.CanFly` learns from watching. `IsFlyableArea` is a
   direct answer and is not consulted. *(Short)*
2. **Corpse-run routing** — the addon knows you are a ghost and says so; it
   does not point you at your body. `C_DeathInfo.GetCorpseMapPosition` would
   make the one thing a dead player wants an actual waypoint. *(Short)*
3. **Waypoint arrow verification in game** — confirm the fixes with
   `/cn selftest` and `/cn navdiag` while walking; still unverified by a human.
   *(Now — task, not code)*

## 2. Content coverage

4. **Quests beyond the current map** — the POI list only covers the map you are
   on; caching observed pins per map would make "waiting three zones away"
   answerable. *(Short)*
5. **Difficulty selection for instance drops** — a mount that only drops on
   Mythic should say so in the chase chain. *(Later)*
6. **Warband bank** — reachable inventory the addon does not read. The
   character bank is read; this is not. *(Later)*
7. **Turn-in NPC database** — turn-in locations come from the client's moving
   "next waypoint"; an independent table would make the three-phase quest model
   stable. *(Later)*
8. **Eligibility database** — class, race and faction gating is implicit (the
   client simply does not draw pins you fail). A curated table would let
   `/cn why` say "that one is for a Druid". *(Later)*
9. **Delves** — revisit only if Blizzard ships a progress API. `C_DelvesUI`
   exposes UI plumbing, and vault credit already flows through the World row.
   *(Later, conditional)*

## 3. Data and the content pipeline

10. **Ship curated quest chains** — the pipeline works and `Data/Quests.lua`
    still holds one row. It fills from real play, not from writing. *(Ongoing)*
11. **Harvest cadence** — `/cn harvestnow`, log out, `.\cn.ps1 harvest`,
    periodically, on more than one account. *(Ongoing)*
12. **`Data/Community.lua`** — a reviewed home for submitted chains, kept apart
    from hand-curated data so provenance survives. *(Short)*
13. **Provenance spot-check command** — list every folded row that has never
    been hand-checked. *(Later)*
14. **Arm the fixture audit** — run `/cn capture`, then `.\cn.ps1 fixtures`,
    and commit the first recording so the stub audit stops reporting
    unverified. *(Now — task)*
15. **In-game import string** — an alternative to the GitHub path; lower
    priority and higher abuse surface. *(Later)*

## 4. Ranking, estimates and learning

16. **Session-shape learning** — how long you actually play, so `/cn plan` can
    default to your real session rather than thirty minutes. *(Later)*
17. **Learning granularity review** — once real data arrives, check whether
    per-type is the right resolution or whether campaign-versus-side-quest
    deserves its own counter. *(Later)*
18. **Urgency curve review** — re-fit the deadline weighting against real reset
    data. 0.63.0 removed a second, duplicate curve; what remains has never been
    fitted against anything. *(Short)*

## 5. Interface and experience

19. **Font scaling** — the colourblind pass landed; text size did not. The
    window is fixed-size text on a resizable frame. *(Short)*
20. **Search and filter across the whole window** — list filtering exists per
    tab; there is no way to find anything the addon knows without knowing which
    tab it lives on. *(Short)*
21. **Tooltip depth** — say *why* something matters on the tooltip, not only
    that it is tracked. *(Later)*
22. **Keybinding coverage** — bindings exist for the basics; extend to follow,
    plan and the window. *(Later)*
23. **Localization: more strings** — the framework covers everything; the
    bundled tables cover the most-visible strings. *(Ongoing)*
24. **Localization: translator workflow** — `/cn locale missing` produces the
    list; document how to send one back. *(Short)*

## 6. Engineering and infrastructure

25. **Fixtures in CI** — once a recording is committed, make the stub audit
    blocking rather than a printed notice. *(Short)*
26. **Interface-version process** — a checklist for each game patch: bump
    `Interface`, re-run the self-test, check for renamed APIs. *(Ongoing)*
27. **Wago publication** — a second distribution channel; the `.toc` already
    has the field commented out. *(Later)*
28. **Store page media** — screenshots and a short clip; the page carries none.
    *(Short)*
29. **Release-notes automation** — generate the CurseForge changelog from
    `CHANGELOG.md` rather than by hand. *(Later)*
30. **A call-site sweep after every fix** — see below. *(Ongoing, new)*

## 7. Declined — recommended against, with the reason

31. **External aggregation database** — an addon cannot upload anything, so
    this means a companion desktop app; it makes Dam Beaver Studios a data
    controller and retracts a promise printed twice on the store page.
32. **Addon-to-addon route sharing** — needs a versioned protocol and matching
    builds on both machines; a support burden the moment either side is stale.
33. **Gearing features** — item level, crests, catalyst charges, M+ score. A
    gear optimiser is a different product wearing the same window.
34. **Auction house and gold-making** — different addon.
35. **Combat, rotation or DPS** — different addon.
36. **Machine-translated locales** — a wrong translation is worse than English,
    because the player cannot tell it is wrong.
37. **Invented completion percentages** — where the client supplies no
    trustworthy denominator, the addon reports counts. Standing rule, not a gap.

---

## What the last three releases changed about how this list is made

0.61.0 through 0.63.0 were audit releases rather than feature releases, and
they found more than a feature would have been worth: three features that had
never once worked on any client, several numbers that were simply wrong, and a
recurring shape worth naming here because it belongs in the backlog as a
practice rather than as a ticket.

**A fix that lands at one call site is not finished.** Of the fourteen defects
found for 0.63.0, seven were places an earlier release had corrected one caller
and left the others: the class token fixed in two of three commands, the
capped-currency detection fixed without its display, the `force` recount given
no caller, the arrow's allocation removed from one function and left in the one
beside it. Each was written up as done. The rule now is that a fix ends with a
grep for every other caller of the thing changed, and the release is not
finished until that grep is clean — item 30 above.

## Recommended order

| | Item | Why |
| --- | --- | --- |
| 1 | Items 1–2 — the client's own answers about flying and about your corpse | Both replace an inference with a fact the client will state, in the two places a player is most likely to notice the addon being wrong. |
| 2 | Item 19 — font scaling | The one accessibility gap left after the colourblind pass, and it affects every screen. |
| 3 | Item 4 — quests beyond the current map | The largest remaining coverage gap; everything else the addon does is already cross-zone. |
| 4 | Item 25 — fixtures in CI | Turns the stub-audit notice into a gate, which is what has been catching the "stub simpler than the client" class by hand. |
