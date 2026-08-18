# CurseForge project settings — Completion Navigator

Filled-in values for the "Create Project" form. Items 1, 2 and 8 are in the
accompanying files.

| # | Field | Value |
|---|---|---|
| 1 | Summary | `01-summary.txt` |
| 2 | Description | `02-description.md` |
| 3 | Editor | **Markdown** |
| 4 | Distribution | **Allow project distribution** |
| 5 | Project License | **MIT License** |
| 6 | Primary Category | **Quests & Leveling** |
| 7 | Categories | Achievements, Map & Minimap, Battle Pets, Professions and Skills |
| 8 | Logo Image | `CompletionNavigator-logo-400.png` |
| 9 | Localization | **Disabled** |
| 10 | Allow comments | **Enabled** |
| 11 | Experimental | **Enabled** |
| 12 | Author Rewards Program | **Enabled**, if the account is studio-owned — see note |

---

## Why each value

### 3. Markdown, not WYSIWYG

The description is maintained alongside the README in the repository. Markdown
round-trips; the WYSIWYG editor rewrites your markup and makes the two drift
apart. Paste `02-description.md` in as-is.

### 4. Allow project distribution

This is what permits the CurseForge app, WowUp and other managers to install
and update the addon. Disallowing it means users must download and unzip by
hand, which for a WoW addon means most of them will not.

It does not surrender any rights — the MIT license and the LLC's copyright are
unaffected.

### 5. MIT License

Matches `LICENSE` in the repository and `## X-License` in the .toc. If
CurseForge's dropdown has no MIT entry, choose "Custom" and paste the LICENSE
file contents, keeping the copyright line as
`Copyright (c) 2026 Dam Beaver Studios, LLC`.

### 6 & 7. Categories

**Quests & Leveling** is the primary because the quest subsystem is the most
developed and because "what should I do next" is a progression question. The
addon genuinely spans several categories, so the secondaries matter for
discovery:

- **Achievements** — near-completion tracking is a headline feature
- **Map & Minimap** — waypoints, zone routing, and the minimap button
- **Battle Pets** — pet collection tracking
- **Professions and Skills** — profession and recipe tracking

Category names vary slightly on CurseForge; pick the closest match to each.
Do not add categories the addon does not actually serve — it dilutes search
placement and draws installs from people who will be disappointed.

### 8. Logo

`CompletionNavigator-logo-400.png` meets CurseForge's 400×400 minimum.
A 512×512 version is included if a larger upload is accepted, and a 64×64 for
checking legibility at list size.

A compass needle for the navigation half and a checkmark for the completion
half, on the addon's own accent colour (the same green as its chat prefix).

### 9. Localization: Disabled

The addon ships enUS strings only, with no localization table. Enabling the
localization system when there is nothing to translate creates an empty
project page section and invites translator sign-ups you cannot use. Turn it
on when strings are actually externalized.

### 10. Allow comments: Enabled

Comments are the most common route for bug reports from users who will not
open a GitHub issue. For a project this early, that feedback is worth more
than the moderation cost.

### 11. Experimental: Enabled

The honest answer at 0.8.0. Several subsystems have been tested against a
stubbed client but not yet against thousands of real characters, and the
static database is small enough that prerequisite forensics are incomplete.

The trade-off is real: the experimental flag reduces search placement and some
clients warn users about it. Turn it off at 1.0, once the subsystems have seen
live use.

### 12. Author Rewards Program

This is CurseForge's revenue share for authors. Whether to enable it is a
business decision, not a technical one, and it has consequences worth
considering before you tick the box:

- Payouts go to the account that owns the project. If everything is to sit
  with Dam Beaver Studios, LLC, the CurseForge account, its tax details and
  its payout method all need to be the LLC's — not personal.
- Enrolment involves providing tax information to Overwolf/CurseForge.
- Revenue for a new addon is generally negligible until it has a substantial
  install base.

If the account is already studio-owned with the LLC's details, enabling it
costs nothing and can be switched off later. If the account is personal,
resolve that first — retro-fitting ownership after payments have been made is
worse than doing it now.

I am not a financial or tax advisor; confirm the tax treatment of any
CurseForge payouts with someone who is.

---

## After the project exists

1. Copy the numeric **Project ID** from the project page.
2. Put it in the .toc:

   ```
   ## X-Curse-Project-ID: 123456
   ```

3. Generate a CurseForge **API token** (account settings → API Tokens).
4. Add it to the GitHub repository as a secret named exactly **`CF_API_KEY`**
   under Settings → Secrets and variables → Actions.
5. Ship it:

   ```powershell
   .\cn.ps1 release 0.8.0
   ```

The tag triggers the workflow, which syntax-checks every Lua file and verifies
the .toc lists them before packaging and uploading. If either check fails,
nothing is published.
