# Translating Completion Navigator

Thank you. Nine languages ship with this addon and every one of them was
contributed by somebody who did not have to.

## What you need

Nothing but the game. You do not need to clone anything, install a toolchain,
or learn the addon's file format.

## How

1. In game, set your language and run:

   ```
   /cn locale export
   ```

   That prints every string the addon uses, as a ready-made Lua block with
   empty right-hand sides.

2. Copy it out of the chat frame and fill in the translations.

   **Leave anything you are unsure of blank.** An empty string is ignored and
   the English is shown instead. English is a better answer than a guess --
   a wrong translation is worse than no translation, because the player
   cannot tell it is wrong.

   **Keep the `%d` and `%s` markers exactly as they appear**, including their
   order. `"Stop %d of %d cleared"` has two numbers in it and the addon fills
   them in that order.

3. Open an issue on the project's GitHub with the block pasted in, titled
   `Translation: <locale code>` â€” for example `Translation: deDE`.

That is the whole process. You do not need to open a pull request; if you
would rather, the file is `Locales/<code>.lua` and the format is the same
block you pasted.

## What happens next

The block is checked for two things and then merged:

* every key still exists in the addon (a renamed string orphans its
  translations, and the build fails rather than showing English silently);
* every string the addon displays has a translation somewhere.

Both are enforced by the build, so a merged translation cannot quietly rot.

## Which strings matter most

`/cn locale missing` lists what is currently falling back to English for your
language, most-seen first. The arrow's words â€” `ahead`, `veer`, `turn`,
`back` â€” and the tab names are what a player reads hundreds of times a
session. The rest can wait.

## Locale codes

`deDE` `esES` `esMX` `frFR` `itIT` `koKR` `ptBR` `ruRU` `zhCN` `zhTW`

If yours is not listed, export it anyway â€” adding a new one is a new file and
nothing else.

---

Completion Navigator is a product of **Dam Beaver Studios, LLC**.
Authored by **Travis A. Bryan I**.
