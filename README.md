# WoWMCP

[![CI](https://github.com/kejith/WoWMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/kejith/WoWMCP/actions/workflows/ci.yml)

Export addon for World of Warcraft: Forever (interface 16001). It writes character data into its SavedVariables so that programs outside the game can read it: the desktop app and the MCP server from [wow-forever-tools](https://github.com/kejith/wow-forever-tools).

Addons have no file or network I/O. The data reaches the disk only when the game writes the SavedVariables, which is on `/reload` or logout.

The addon works on every client language. Its chat messages are English or German, following the client. The exported data (item names, tooltips, zone names) is in the language of the client, and `client.locale` says which one.

## Installation

Unpack the zip of the [latest release](https://github.com/kejith/WoWMCP/releases/latest) into `World of Warcraft\_forever_\Interface\AddOns`, so that the folder `WoWMCP` sits there. Then type `/reload` in the game, open your bank once and open each profession window once.

The desktop app installs and updates the addon with one click (page "Connection").

Auctionator is optional. The item export needs it, because it reads the items from the Auctionator scans of the last 4 days.

## Commands

| Command | Effect |
| --- | --- |
| `/wowmcp sync` | take a snapshot and `/reload`, so app and server see current data |
| `/wowmcp items [full]` | read stats and tooltips of the equippable auction house items (only new ones, with `full` all of them), then `/reload` |
| `/wowmcp auto on\|off` | run the item export when the auction house closes (default: on) |
| `/wowmcp status` | last snapshot, bank scan, item export, recipes, requests, export errors |

## What is exported

| Variable | File | Content |
| --- | --- | --- |
| `WoWMCP_Char` | per character, `WTF\Account\<account>\<realm>\<name>\SavedVariables\WoWMCP.lua` | `character` (level, gold, zone, stats), `equipment` with tooltips, `bags`, `bank`, `quests`, `completedQuests`, `reputation`, `skills`, `talents`, `currencies`, `recipes` per profession, `errors`, `client` (`version`, `build`, `interface`, `locale`), `addon.version`, `updated` |
| `WoWMCP_Items` | account, `WTF\Account\<account>\SavedVariables\WoWMCP.lua` | item export: `items[id] = {name, quality, ilvl, reqLevel, equipLoc, classID, subclassID, bind, stats, tooltip, tipColors}`, incremental per client build and language (`build`, `locale`) |
| `WoWMCP_Account` | account, same file | `autoItems`, `lastRequest`, `vendor[itemID]` (vendor prices in copper), `payouts` (measured content of coin pouches, Merchant's Favor per trade crate) |

Limits:

- The bank can only be read while it is open and keeps that state until the next visit.
- Recipes are read while your own profession window is open, vendor prices when you talk to a merchant.
- No snapshot is taken in combat; it follows when the fight ends.
- A snapshot expands all reputation categories, because collapsed factions cannot be read.
- The item export starts over when the client build or the client language changes.

## Requests from outside

The app puts a request into `AppRequest.lua` in the addon folder. The game reads the file on the next `/reload`, the addon runs every `id` once and writes the result to `WoWMCP_Account.lastRequest`.

```lua
WoWMCP_AppRequest = { id = 1, action = "items", full = false }
```

`action` is `items` or `sync`.

## Development

`tests/test_addon.py` runs the addon in Lua 5.4 against a stubbed WoW API (snapshot, combat, bank, payouts, recipes, vendor prices, item export, requests, both languages, the `.toc`):

```
uv run tests/test_addon.py
```

The game itself runs Lua 5.1 with its own API, so a change still needs a look in the game.

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
