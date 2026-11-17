# WoWMCP

Export-Addon für World of Warcraft: Forever (Interface 16001). Es schreibt Charakterdaten in seine SavedVariables, damit Programme außerhalb des Spiels sie lesen können: die Desktop-App und der MCP-Server aus [wow-forever-tools](https://github.com/kejith/wow-forever-tools).

Addons haben kein Datei- oder Netzwerk-I/O. Die Daten erreichen die Platte erst, wenn WoW die SavedVariables schreibt, also bei `/reload` oder Logout.

## Installation

Das Zip des [neuesten Release](https://github.com/kejith/WoWMCP/releases/latest) nach `World of Warcraft\_forever_\Interface\AddOns` entpacken, sodass dort der Ordner `WoWMCP` liegt. Danach im Spiel `/reload`, einmal die Bank öffnen und jedes Berufsfenster einmal öffnen.

Die Desktop-App installiert und aktualisiert das Addon per Klick (Seite „Verbindung“).

Auctionator ist optional. Der Item-Export braucht es, weil er die Items aus den Auctionator-Scans der letzten 4 Tage liest.

## Befehle

| Befehl | Wirkung |
| --- | --- |
| `/wowmcp sync` | Snapshot erstellen und `/reload`, damit App und Server aktuelle Daten sehen |
| `/wowmcp items [full]` | Werte und Tooltips der ausrüstbaren AH-Items lesen (nur neue, mit `full` alle), danach `/reload` |
| `/wowmcp auto on\|off` | Item-Export automatisch beim Schließen des Auktionshauses (Standard: an) |
| `/wowmcp status` | letzter Snapshot, Bank-Scan, Item-Export, Rezepte, Aufträge, Exportfehler |

## Was exportiert wird

| Variable | Datei | Inhalt |
| --- | --- | --- |
| `WoWMCP_Char` | pro Charakter, `WTF\Account\<Account>\<Realm>\<Name>\SavedVariables\WoWMCP.lua` | `character` (Stufe, Gold, Zone, Werte), `equipment` mit Tooltips, `bags`, `bank`, `quests`, `completedQuests`, `reputation`, `skills`, `talents`, `currencies`, `recipes` pro Beruf, `errors`, `client`, `addon.version`, `updated` |
| `WoWMCP_Items` | Account, `WTF\Account\<Account>\SavedVariables\WoWMCP.lua` | Item-Export: `items[id] = {name, quality, ilvl, reqLevel, equipLoc, classID, subclassID, bind, stats, tooltip, tipColors}`, inkrementell pro Client-Build |
| `WoWMCP_Account` | Account, dieselbe Datei | `autoItems`, `lastRequest`, `vendor[itemID]` (Händlerpreise in Kupfer), `payouts` (gemessener Inhalt von Münzbeuteln, Händlergunst pro Handelskiste) |

Einschränkungen:

- Die Bank ist nur bei geöffneter Bank lesbar und bleibt bis zum nächsten Besuch auf diesem Stand.
- Rezepte liest das Addon, wenn das eigene Berufsfenster offen ist, Händlerpreise beim Händlerbesuch.
- Im Kampf entsteht kein Snapshot, er folgt nach Kampfende.
- Beim Snapshot klappt das Addon alle Ruf-Kategorien auf, sonst sind eingeklappte Fraktionen nicht lesbar.

## Aufträge von außen

Die App legt einen Auftrag in `AppRequest.lua` im Addon-Ordner ab. Das Spiel liest die Datei beim nächsten `/reload`, das Addon führt jede `id` einmal aus und schreibt das Ergebnis nach `WoWMCP_Account.lastRequest`.

```lua
WoWMCP_AppRequest = { id = 1, action = "items", full = false }
```

`action` ist `items` oder `sync`.

## Entwicklung

```
uv run tests/check_syntax.py
```

lädt jede Datei aus der `.toc` in Lua 5.4 und findet Syntaxfehler. Verhalten prüft das nicht.

## Release

1. `## Version:` in `WoWMCP.toc` hochzählen und committen.
2. `git tag v<Version>` und `git push origin main v<Version>`.

Die GitHub-Action prüft, dass Tag und Version übereinstimmen, und hängt `WoWMCP-v<Version>.zip` an das Release. Das Zip enthält nur den Ordner `WoWMCP` mit den Dateien aus der `.toc`.
