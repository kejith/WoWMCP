# WoWMCP

[![CI](https://github.com/kejith/WoWMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/kejith/WoWMCP/actions/workflows/ci.yml)

Export addon for World of Warcraft: Forever (interface 16001). It writes character data into its SavedVariables so that programs outside the game can read it: the desktop app and the MCP server from [wow-forever-tools](https://github.com/kejith/wow-forever-tools). Since 1.7 it also shows what the desktop app computed inside the game: lists for the auction house, lines in item tooltips and hints at merchants. Since 1.8 it draws the price history of any item Auctionator has scanned.

Addons have no file or network I/O. The data reaches the disk only when the game writes the SavedVariables, which is on `/reload` or logout.

The addon works on every client language. Its chat messages are English or German, following the client. The exported data (item names, tooltips, zone names) is in the language of the client, and `client.locale` says which one.

## Installation

Unpack the zip of the [latest release](https://github.com/kejith/WoWMCP/releases/latest) into `World of Warcraft\_forever_\Interface\AddOns`, so that the folder `WoWMCP` sits there. Then type `/reload` in the game, open your bank once and open each profession window once.

The desktop app installs and updates the addon with one click (page "Connection").

Auctionator is optional. The item export needs it, because it reads the items from the Auctionator scans of the last 4 days. The lists use it to search several items at once and to keep shopping lists, the price history reads its scans.

## Commands

| Command | Effect |
| --- | --- |
| `/wowmcp sync` | take a snapshot and `/reload`, so app and server see current data |
| `/wowmcp items [full]` | read stats and tooltips of the equippable auction house items (only new ones, with `full` all of them), then `/reload` |
| `/wowmcp auto on\|off` | run the item export when the auction house closes (default: on) |
| `/wowmcp status` | last snapshot, bank scan, item export, recipes, requests, lists from the app, export errors |
| `/wowmcp show` | open or close the lists from the app |
| `/wowmcp price [name]` | the price history tab, searching for the name, item ID or link if one is given |
| `/wowmcp lists on\|off` | keep Auctionator shopping lists `WoWMCP: <list>` with what the lists say to buy (default: on) |
| `/wowmcp tips on\|off` | lines from the app in item tooltips (default: on) |
| `/wowmcp ah on\|off` | open the lists together with the auction house (default: on) |

## Lists from the app

The desktop app computes AH upgrades, writs, trade crates, profession recipes and consumables from the exported data. It writes the result into `AppData.lua` in the addon folder, and the game reads that file on the next `/reload`. So new data needs two reloads: one that saves the scan for the app, and one that loads what the app made of it.

- **Window** (`/wowmcp show`, or together with the auction house): a dark stone panel matching the desktop app, with a slim title bar (coin icon, title, scan timestamp, close button), flat underline tabs along the top edge (with the price history separated on the right), a context strip for the open tab's note, and a dark inset body with a thin scrollbar. Section headers sit on elevated cards with a gold accent bar and a compact "Search" button; item rows show a crisp 1px quality border around cropped icons, a left gold accent bar and `*` on shopping-list items, tree connectors for indented sub-rows, alternating stripes, amount, note and price in coins. Along the footer: "Open with the auction house" and the primary "Search the shopping list" button.
  - Drag the corner grip in the bottom right to resize the window: more rows, a wider info column, a wider price history graph. Right-click the grip for the default size. Position, size and the open tab are kept. Escape closes it.
  - Click an item to search it in the auction house.
  - Shift-click an item to link it, into the chat or into the search box of the auction house.
  - Right-click an item to see its price history.
  - "Search" on a section header searches all of its items at once, "Search the shopping list" every marked item of the tab. Both need Auctionator.
- **Auctionator shopping lists** `WoWMCP: <list>` hold the marked items of each list, with the amount to buy. They are written once per data file and character, a few seconds after login, and removed when a list has nothing to buy any more. What you change in them stays until the app sends new data.
- **Tooltips**: items the lists know get light blue lines, for example "Upgrade for Chest: +12.5 points, no. 1 in the AH scan", "Reagent for Mana Potion: profit 12s per craft" or "For a writ (Journeyman): hand in 4x".
- **Merchants**: when a merchant sells a recipe the app found worth learning, the addon says so in the chat.

The data is per character, by first name. Texts in the file are in the language of the client.

```lua
WoWMCP_AppData = { version = 1, generated = 1763400500, hash = "f3d15650d5a9a092", locale = "enUS", scanDate = "2026-11-18",
  chars = { Tester = {
    lists = { { key = "upgrades", title = "AH upgrades", note = "Budget {m:150000}", sections = {
      { title = "Chest", note = "now: Old Robe", rows = {
        { id = 9001, name = "Robe of Tests", q = 2, info = "+12.5", price = 90000, shop = true } } } } } },
    tips = { [9001] = { "Upgrade for Chest: +12.5 points, no. 1 in the AH scan ({m:90000})" } },
    vendor = { [7001] = "Teaches Elixir of Gain: profit {m:3000} per craft" },
  } } }
```

A row is `{id, name, q (quality), n (amount), info, price (copper), shop (to buy), sub (indented)}`. Money inside a text is written `{m:<copper>}` and shown as coins. The addon reports what it loaded in `WoWMCP_Account.appData = {generated, hash, loaded}`.

## Price history

The last tab of the window, "Price history", works without the app and without a `/reload`: it reads Auctionator's price database, which Auctionator loads on login and updates with every scan.

- **Layout**: the search box and the results on the left, on the right the item (icon, name, last price), the graph in an inset of its own and the statistics below it.
- **Search** by name (every word must be in the name, any case), item ID (`2447` or `#2447`) or item link. Shift-click an item into the search box, as in the profession window. An empty box lists the items you looked at last.
- **Graph** per scan day, on a faint grid with the prices on the left and three dates below: a line through the lowest price, a band from the lowest to the highest minimum price of the day (Auctionator notes both when it scans more than once a day) and bars for the number of offers. The time axis runs to the newest scan day of the whole database, so an item that vanished from the auction house ends early. Hover a day for its numbers.
- Below the graph: the last price seen, and over the scan days the lowest, highest and average lowest price and the change from the first to the last day.
- Click the icon to search the item in the auction house, shift-click it to link it.

Auctionator keeps 21 days by default (its option "price history days"). The names are read the first time the tab opens, a few hundred per frame: from the client, else from the item export (`WoWMCP_Items`). Many Forever items, most of them equipment, are not in the client's files, so the client knows their names only after asking the server; the export has them at once. Names neither knows are asked from the server 40 at a time, every unanswered item up to three times, 10 seconds apart; the status line below the results says how many are still loading and how many stayed without a name. Those are still found by their item ID.

## What is exported

| Variable | File | Content |
| --- | --- | --- |
| `WoWMCP_Char` | per character, `WTF\Account\<account>\<realm>\<name>\SavedVariables\WoWMCP.lua` | `character` (level, gold, zone, stats; since 1.12 also the mana regeneration of the character sheet, spell haste and the active buffs), `equipment` with tooltips, `bags`, `bank` (since 1.12 armor and weapons in bags and bank carry their stats and tooltip like equipped gear, every item its class, subclass and binding), `quests`, `completedQuests`, `reputation`, `skills`, `talents` (since 1.12 with the description and the tooltip of the learned rank), `spellbook` (since 1.11: every learned spell with its rank line and description; since 1.12 also cost, cast time and cooldown as the game computes them; future level-gated spells, guild and off-spec pages are left out), `currencies`, `recipes` per profession, `errors`, `client` (`version`, `build`, `interface`, `locale`), `addon.version`, `updated` |
| `WoWMCP_Items` | account, `WTF\Account\<account>\SavedVariables\WoWMCP.lua` | item export: `items[id] = {name, quality, ilvl, reqLevel, equipLoc, classID, subclassID, bind, stats, tooltip, tipColors}`, incremental per client build and language (`build`, `locale`) |
| `WoWMCP_Account` | account, same file | `autoItems`, `lastRequest`, `vendor[itemID]` (vendor prices in copper), `payouts` (measured content of coin pouches, Merchant's Favor per trade crate), `appData` (which `AppData.lua` the game loaded), `ui` (settings, position and size of the list window) |

Limits:

- The bank can only be read while it is open and keeps that state until the next visit.
- Recipes are read while your own profession window is open, vendor prices when you talk to a merchant.
- No snapshot is taken in combat; it follows when the fight ends.
- In a dungeon or a raid the client keeps the character's stats secret (attributes, spell power, crit, the buffs). A snapshot taken there keeps the stats and buffs of the last snapshot taken outside: `character.statsKept` is `true` then, and `character.statsUpdated` says when the stats were read. A character that was never saved outside has no stats until it is.
- A snapshot expands all reputation categories, because collapsed factions cannot be read.
- The item export starts over when the client build or the client language changes.

## Requests from outside

The app puts a request into `AppRequest.lua` in the addon folder. The game reads the file on the next `/reload`, the addon runs every `id` once and writes the result to `WoWMCP_Account.lastRequest`.

```lua
WoWMCP_AppRequest = { id = 1, action = "items", full = false }
```

`action` is `items` or `sync`.

## Development

`tests/test_addon.py` runs the addon in Lua 5.4 against a stubbed WoW API (snapshot, combat, bank, payouts, recipes, vendor prices, item export, requests, the list window with search, shopping lists, tooltip lines and vendor hints, both languages, the `.toc`):

```
uv run tests/test_addon.py
```

The game itself runs Lua 5.1 with its own API, so a change still needs a look in the game. The widget stubs answer every method they do not know with nothing, so they cannot tell whether a frame looks right.

The window uses a custom dark stone theme (1px pixel-aligned borders, flat underline tabs, flat buttons, thin scrollbars, cropped icons with 1px quality frames) without relying on Blizzard panel templates. The magnifier atlas (`common-search-magnifyingglass`) is looked up via `C_Texture.GetAtlasInfo` first and falls back to an icon texture.

`WoWMCP.lua` is the export, `Lists.lua` the window, tooltips and shopping lists. `Lists.lua` loads last and only reads `WoWMCP_AppData`, so a problem there cannot stop the export.

Texts live in `Locales.lua`. English is the default; a language only lists what it translates. To add a language, add a block for its `GetLocale()` code.

## Releases

Releases are automatic. Raise `## Version:` in `WoWMCP.toc` and push to `main`:

1. The CI workflow runs the tests and builds the zip.
2. If the version has no tag yet, CI creates the tag `v<version>` and starts the release workflow.
3. The release workflow builds `WoWMCP-v<version>.zip` with the [BigWigs packager](https://github.com/BigWigsMods/packager), checks it and publishes it as a GitHub release with the commits since the last release as notes.

A tag pushed by hand (`git tag v<version> && git push origin v<version>`) starts the same release workflow. The tag must match the version in the `.toc`. `.pkgmeta` lists what stays out of the zip.

### CurseForge and Wago

The release workflow also uploads to CurseForge and Wago Addons as soon as both the project id and the API token are present. Until then these uploads are skipped.

| Site | One-time setup | Line in `WoWMCP.toc` | Repository secret |
| --- | --- | --- | --- |
| [CurseForge](https://www.curseforge.com/project/create) | create the project for World of Warcraft, pick a license, wait for approval | `## X-Curse-Project-ID: <id>` (the "Project ID" on the project page) | `CF_API_TOKEN` from <https://authors.curseforge.com/#/settings/api-tokens> |
| [Wago Addons](https://addons.wago.io/developers) | create the project | `## X-Wago-ID: <id>` | `WAGO_API_TOKEN` from <https://addons.wago.io/account/apikeys> |

Set a secret with `gh secret set CF_API_TOKEN --repo kejith/WoWMCP`. The packager marks the upload as compatible with WoW: Forever from the interface number in the `.toc`. WoWInterface has no category for WoW: Forever.
