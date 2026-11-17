-- Chat texts of the addon. English is the default; a locale only lists what it translates, everything
-- else falls back to English. To add a language, add a block for its GetLocale() code below.
-- The exported data itself (item names, tooltips, zone names) is always in the language of the client.
local _, ns = ...

local L = {
    on = "on", off = "off", never = "never", running = "running",
    itemsDone = "%d new items read, %d in the export (%d not loaded). Type /reload so the app sees them.",
    itemsProgress = "%d/%d items...",
    itemsRunning = "item export already running (%d/%d).",
    itemsStart = "reading %d new items (%s)...",
    noAuctionator = "Auctionator price data not found. Install Auctionator and scan the auction house first.",
    requestItems = "app request #%d: item export",
    requestSync = "app request #%d: snapshot",
    snapshotReady = "snapshot ready. Type /reload so the app sees it.",
    autoState = "item export after closing the auction house is %s (/wowmcp auto on|off)",
    statusSnapshot = "WoWMCP %s: last snapshot %s",
    statusBank = "  bank: %s",
    bankNever = "never scanned (open your bank once)",
    statusItems = "  item export: %d items, %s, auto %s",
    itemsNever = "never run",
    statusRecipes = "  recipes %s: %d learned, read %s",
    statusNoRecipes = "  recipes: none yet (open each profession window once)",
    statusPouch = "  coin pouch %d: opened %dx, average %s",
    statusCrate = "  crate %d: handed in %dx, average favor %s",
    statusRequest = "  last app request: #%s (%s) %s",
    helpSync = "/wowmcp sync - snapshot and reload so the app and MCP server see current data",
    helpItems = "/wowmcp items [full] - read stats of new auction house items (full: all again), then /reload",
    helpAuto = "/wowmcp auto on|off - run the item export automatically when the auction house closes",
    helpStatus = "/wowmcp status - snapshot time, item export, recipes, app requests and export errors",
    helpRecipes = "recipes are read when you open a profession window, vendor prices when you talk to a merchant",
    helpPayouts = "coin pouch gold and crate favor are recorded when you open a pouch or hand in a crate",
}

local translations = {
    deDE = {
        on = "an", off = "aus", never = "nie", running = "läuft",
        itemsDone = "%d neue Items gelesen, %d im Export (%d nicht geladen). /reload eingeben, damit die App sie sieht.",
        itemsProgress = "%d/%d Items...",
        itemsRunning = "Item-Export läuft bereits (%d/%d).",
        itemsStart = "lese %d neue Items (%s)...",
        noAuctionator = "Keine Preisdaten von Auctionator gefunden. Auctionator installieren und zuerst das Auktionshaus scannen.",
        requestItems = "Auftrag #%d der App: Item-Export",
        requestSync = "Auftrag #%d der App: Snapshot",
        snapshotReady = "Snapshot fertig. /reload eingeben, damit die App ihn sieht.",
        autoState = "Item-Export nach dem Schließen des Auktionshauses ist %s (/wowmcp auto on|off)",
        statusSnapshot = "WoWMCP %s: letzter Snapshot %s",
        statusBank = "  Bank: %s",
        bankNever = "nie gescannt (Bank einmal öffnen)",
        statusItems = "  Item-Export: %d Items, %s, automatisch %s",
        itemsNever = "nie gelaufen",
        statusRecipes = "  Rezepte %s: %d gelernt, gelesen %s",
        statusNoRecipes = "  Rezepte: noch keine (jedes Berufsfenster einmal öffnen)",
        statusPouch = "  Münzbeutel %d: %dx geöffnet, Schnitt %s",
        statusCrate = "  Kiste %d: %dx abgegeben, Händlergunst im Schnitt %s",
        statusRequest = "  letzter Auftrag der App: #%s (%s) %s",
        helpSync = "/wowmcp sync - Snapshot und /reload, damit App und MCP-Server aktuelle Daten sehen",
        helpItems = "/wowmcp items [full] - Werte neuer Auktionshaus-Items lesen (full: alle neu), danach /reload",
        helpAuto = "/wowmcp auto on|off - Item-Export automatisch beim Schließen des Auktionshauses",
        helpStatus = "/wowmcp status - Zeit des Snapshots, Item-Export, Rezepte, Aufträge der App und Exportfehler",
        helpRecipes = "Rezepte werden beim Öffnen eines Berufsfensters gelesen, Händlerpreise beim Händlerbesuch",
        helpPayouts = "Gold aus Münzbeuteln und Händlergunst pro Kiste werden beim Öffnen bzw. Abgeben gemessen",
    },
}

for key, text in pairs(translations[GetLocale()] or {}) do
    L[key] = text
end

ns.L = L
