# Project page: internal rules

Not for publication. `DESCRIPTION.md` and `SUMMARY.txt` are pasted verbatim
into CurseForge, so nothing internal belongs in either of them -- not even
inside an HTML comment. A comment is invisible in a rendered page and plainly
visible to anyone who opens the source or pastes the file somewhere that does
not render Markdown, which makes it a private note published by accident.

That is why this file exists separately, and why the test suite fails the
build if a comment reappears in the description.

## Hard limits

- `SUMMARY.txt` must be **256 characters or fewer**, on a single line.
  CurseForge rejects longer.
- `DESCRIPTION.md` must contain no HTML comments and must begin with the
  `# Completion Navigator` heading.

## House rules for the copy

Public-facing copy for this project carries a heightened bar. The test suite
enforces these; they are not stylistic preferences.

- No superlatives, and no claim of being the best or the only anything.
- No promises about outcomes.
- Other addons are named as things this one reads, never as things it beats.
- No completion percentage the game itself did not supply.

## When to update

With the change that makes it true, in the same release. A description
written fresh at upload time drifts from what shipped, and the only copy of
it ends up inside a web form that cannot be diffed.
