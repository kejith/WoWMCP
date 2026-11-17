# /// script
# requires-python = ">=3.11"
# dependencies = ["lupa>=2.0"]
# ///
"""Tests for WoWMCP without the game: the addon runs in Lua against a stubbed WoW API.

    uv run tests/test_addon.py

The stubs cover what the scenarios need. Everything else is missing on purpose: the addon has to cope
with API it does not find, the way it does on a client that lacks a function.
"""

import os
import re

from lupa.lua54 import LuaRuntime, lua_type

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
NAME = "WoWMCP"


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as f:
        return f.read()


def toc():
    """Fields and file list of the .toc."""
    fields, files = {}, []
    for line in read(f"{NAME}.toc").splitlines():
        line = line.strip()
        m = re.match(r"##\s*([^:]+):\s*(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2)
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return fields, files


def lua_to_py(x):
    if lua_type(x) != "table":
        return x
    keys = list(x.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [lua_to_py(x[k]) for k in sorted(keys)]
    return {k: lua_to_py(x[k]) for k in keys}


# A level 46 warlock in Orgrimmar with a hat, a backpack, a bank bag, two quests, one reputation and
# Alchemy. Time only moves through advance(), which also runs the timers that came due.
STUBS = r"""
now, clock, locale, combat, money, favor = 1000, 1763400000, "enUS", false, 50000, 7
timers, printed, counts = {}, {}, {}
handler, registered, reloaded = nil, {}, false

function print(...) printed[#printed + 1] = table.concat({...}, " ") end
function GetTime() return now end
function time() return clock + now end
date = os.date
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function GetLocale() return locale end
function GetBuildInfo() return "1.60.1", "70938", "Nov 1 2026", 16001 end
function GetMoney() return money end
function InCombatLockdown() return combat end
function UnitAffectingCombat() return combat end
SlashCmdList = {}

C_Timer = {
  After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end,
  NewTicker = function(delay, fn)
    local t = { at = now + delay, fn = fn, every = delay, Cancel = function(self) self.cancelled = true end }
    timers[#timers + 1] = t
    return t
  end,
}
function advance(seconds)
  local target = now + seconds
  while true do
    local best
    for i, t in ipairs(timers) do
      if not t.cancelled and t.at <= target and (not best or t.at < timers[best].at) then best = i end
    end
    if not best then break end
    local t = timers[best]
    now = t.at
    if t.every then t.at = t.at + t.every else table.remove(timers, best) end
    t.fn()
  end
  now = target
end

function CreateFrame()
  return {
    RegisterEvent = function(_, event) registered[event] = true end,
    UnregisterEvent = function(_, event) registered[event] = nil end,
    SetScript = function(_, _, fn) handler = fn end,
  }
end
function fire(event, ...) if registered[event] then handler(nil, event, ...) end end

C_AddOns = { GetAddOnMetadata = function() return VERSION end }
C_UI = { Reload = function() reloaded = true end }

-- Character
function UnitName(unit) if unit == "npc" then return "Vendor Bob" end return "Tester", "Smith" end
function UnitClass() return "Warlock", "WARLOCK" end
function UnitRace() return "Orc", "Orc" end
function GetGuildInfo() return nil end
function UnitLevel() return 46 end
function UnitFactionGroup() return "Horde" end
function UnitSex() return 2 end
function UnitXP() return 100 end
function UnitXPMax() return 1000 end
function GetXPExhaustion() return nil end
function GetRealZoneText() return "Orgrimmar" end
function GetSubZoneText() return "" end
function UnitIsDeadOrGhost() return false end
function UnitStat(_, i) return i * 10, i * 10 + 1 end
function UnitHealthMax() return 2000 end
function UnitPowerMax() return 3000 end
function UnitPowerType() return 0, "MANA" end
function GetSpellHitModifier() return 5 end
function GetSpellCritChanceFromStat() return 0.02 end
MANA_PER_INTELLECT = 15
C_Map = {
  GetBestMapForUnit = function() return 1454 end,
  GetMapInfo = function() return { name = "Orgrimmar" } end,
  GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.254 end } end,
}
C_SpellBook = { IsSpellKnown = function(id) return id == 1456 end }
C_Spell = {
  GetSpellDescription = function() return "Converts 310 health into 310 mana." end,
  GetSpellName = function(id) return "Spell " .. id end,
}

-- Items: loaded = false means the client has not received the item from the server yet.
items = {
  [1001] = { name = "Hat of Testing", equipLoc = "INVTYPE_HEAD", classID = 4, loaded = true },
  [1002] = { name = "Staff of Waiting", equipLoc = "INVTYPE_2HWEAPON", classID = 2, loaded = false },
  [1003] = { name = "Old Boots", equipLoc = "INVTYPE_FEET", classID = 4, loaded = true },
  [2447] = { name = "Peacebloom", equipLoc = "", classID = 7, loaded = true },
  [118] = { name = "Minor Healing Potion", equipLoc = "", classID = 0, loaded = true },
  [284583] = { name = "Coin Pouch", equipLoc = "", classID = 15, loaded = true },
}
local function itemID(x) return type(x) == "number" and x or tonumber(x:match("item:(%d+)")) end
function link(id) return "|cff1eff00|Hitem:" .. id .. "::::::::46:::::|h[" .. items[id].name .. "]|h|r" end
C_Item = {
  GetItemInfo = function(x)
    local id = itemID(x)
    local it = items[id]
    if not it or not it.loaded then return nil end
    return it.name, link(id), 2, 40, 35, "Armor", "Cloth", 1, it.equipLoc, 134400, 100, it.classID, 1, 2
  end,
  GetItemInfoInstant = function(id)
    local it = items[id]
    if it then return id, "Armor", "Cloth", it.equipLoc, 134400, it.classID, 1 end
  end,
  GetItemStats = function() return { ITEM_MOD_INTELLECT_SHORT = 10, nested = {} } end,
  GetItemNameByID = function(id) return items[id] and items[id].name end,
  GetItemCount = function(id) return counts[id] or 0 end,
  RequestLoadItemDataByID = function(id) items[id].loaded = true end,
}
local function tooltip(id)
  return { lines = {
    { leftText = items[id].name, leftColor = { r = 0.12, g = 1, b = 0 } },
    { leftText = "Head", rightText = "Cloth", leftColor = { r = 1, g = 1, b = 1 } },
    { leftText = "+10 Intellect", leftColor = { r = 1, g = 1, b = 1 } },
    { leftText = "" },
    { leftText = "Equip: Improves your chance to hit by 1%.", leftColor = { r = 0, g = 1, b = 0 } },
  } }
end
C_TooltipInfo = {
  GetInventoryItem = function(_, slot) return tooltip(1001) end,
  GetItemByID = function(id) return tooltip(id) end,
}
function GetInventoryItemLink(_, slot) if slot == 1 then return link(1001) end end
function GetInventoryItemID(_, slot) if slot == 1 then return 1001 end end
function GetInventoryItemDurability(slot) return 30, 40 end

Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, Bank = -1, BankBag_1 = 5, AccountBankTab_1 = 13 } }
containers = {
  [0] = { name = "Backpack", size = 16, slots = { [1] = { 2447, 20 }, [2] = { 284583, 1 } } },
  [5] = { name = "Bank Bag", size = 8, slots = { [3] = { 118, 5 } } },
  [13] = { name = "Account Bank", size = 8, slots = { [1] = { 118, 99 } } },
}
C_Container = {
  GetContainerNumSlots = function(bag) return containers[bag] and containers[bag].size or 0 end,
  GetContainerItemInfo = function(bag, slot)
    local s = containers[bag] and containers[bag].slots[slot]
    if s then return { itemID = s[1], hyperlink = link(s[1]), stackCount = s[2], isBound = false } end
  end,
  GetBagName = function(bag) return containers[bag].name end,
  GetContainerNumFreeSlots = function(bag) return 3 end,
}

-- Quests, reputation, skills, talents, currency
local log = {
  { isHeader = true, title = "Durotar" },
  { questID = 11, title = "First Quest", level = 5 },
  { questID = 12, title = "Second Quest", level = 6, suggestedGroup = 2 },
  { questID = 13, title = "Hidden", isHidden = true },
}
C_QuestLog = {
  GetNumQuestLogEntries = function() return #log end,
  GetInfo = function(i) return log[i] end,
  IsComplete = function(id) return id == 12 end,
  GetQuestObjectives = function(id) return { { text = "Boars slain: 3/8", finished = false, numFulfilled = 3, numRequired = 8 } } end,
  GetAllCompletedQuestIDs = function() return { 5, 3 } end,
}
function GetQuestLogQuestText(i) return "Description " .. i, "Objective " .. i end
C_Reputation = {
  GetNumFactions = function() return 2 end,
  GetFactionDataByIndex = function(i)
    if i == 1 then return { isHeader = true, name = "Horde" } end
    return { factionID = 76, name = "Orgrimmar", reaction = 5, currentStanding = 4000,
             currentReactionThreshold = 3000, nextReactionThreshold = 9000 }
  end,
}
FACTION_STANDING_LABEL5 = "Friendly"
function GetProfessions() return 1 end
function GetProfessionInfo() return "Alchemy", 0, 150, 225, 0, 0, 171, 0 end
C_ClassTalents = { GetActiveConfigID = function() return nil end }
C_Traits = { GetConfigIDByTreeID = function() return nil end }
C_CurrencyInfo = { GetCurrencyInfo = function() return { name = "Merchant's Favor", quantity = favor } end }

-- Profession window and merchant
C_TradeSkillUI = {
  GetChildProfessionInfo = function()
    return { professionID = 2485, parentProfessionID = 171, parentProfessionName = "Alchemy",
             professionName = "Classic Alchemy", skillLevel = 150, maxSkillLevel = 225, skillModifier = 0 }
  end,
  GetBaseProfessionInfo = function() return { professionID = 171, professionName = "Alchemy" } end,
  GetAllRecipeIDs = function() return { 2330, 2331, 2332 } end,
  GetRecipeInfo = function(id)
    if id == 2332 then return { name = "Gathering", isGatheringRecipe = true } end
    return { name = "Recipe " .. id, learned = id == 2330, relativeDifficulty = 2, numSkillUps = 1, categoryID = 9 }
  end,
  GetRecipeSchematic = function()
    return { outputItemID = 118, quantityMin = 1, quantityMax = 2, reagentSlotSchematics = {
      { reagents = { { itemID = 2447 } }, quantityRequired = 2, reagentType = 1, required = true } } }
  end,
  GetRecipeSourceText = function() return "Trainer" end,
}
local stock = {
  { id = 3371, price = 100, stackCount = 5, numAvailable = -1 },
  { id = 9300, price = 9000, stackCount = 1, numAvailable = 1 },
  { id = 8000, price = 50, stackCount = 1, numAvailable = -1, hasExtendedCost = true },
}
function GetMerchantNumItems() return #stock end
function GetMerchantItemID(i) return stock[i].id end
C_MerchantFrame = { GetItemInfo = function(i) return stock[i] end }

-- Auctionator: 1001 and 1002 were seen today, 1003 a month ago, 2447 is not equippable.
local day0 = clock - 86400 * 100
Auctionator = { Constants = { SCAN_DAY_0 = day0 }, Database = { db = {
  ["1001"] = { h = { ["100"] = 5 } }, ["1002"] = { h = { ["100"] = 5 } },
  ["1003"] = { h = { ["70"] = 5 } }, ["2447"] = { h = { ["100"] = 5 } }, ["g:1:2"] = { h = { ["100"] = 5 } },
} } }
"""


def new_runtime(locale="enUS"):
    lua = LuaRuntime(register_eval=False)
    lua.execute(STUBS)
    lua.globals().locale = locale
    lua.globals().VERSION = toc()[0]["Version"]
    return lua


def load_addon(lua, request=None, enter=True):
    """Runs the files of the .toc like the client does on login or /reload: in order, sharing one table."""
    load = lua.eval("function(src, name) return assert(load(src, name)) end")
    lua.execute("timers, registered, handler = {}, {}, nil")
    ns = lua.table()
    for name in toc()[1]:
        if name == "AppRequest.lua":
            lua.execute(f"WoWMCP_AppRequest = {request or 'nil'}")
        else:
            load(read(name), name)(NAME, ns)
    lua.execute('fire("ADDON_LOADED", "WoWMCP")')
    if enter:
        lua.execute('fire("PLAYER_ENTERING_WORLD", true, false); advance(4)')
    return ns


def char(lua):
    return lua_to_py(lua.globals().WoWMCP_Char)


def account(lua):
    return lua_to_py(lua.globals().WoWMCP_Account)


def printed(lua):
    out = lua_to_py(lua.globals().printed)
    return out if isinstance(out, list) else []


def test_snapshot():
    lua = new_runtime()
    load_addon(lua)
    c = char(lua)
    assert c["errors"] == {}, c["errors"]
    assert c["schema"] == 1 and c["addon"]["version"] == toc()[0]["Version"]
    assert c["client"] == {"version": "1.60.1", "build": 70938, "interface": 16001, "locale": "enUS"}
    who = c["character"]
    assert (who["name"], who["surname"], who["level"], who["classFile"], who["money"]) == ("Tester", "Smith", 46, "WARLOCK", 50000)
    assert who["map"] == {"id": 1454, "name": "Orgrimmar", "x": 50, "y": 25.4} and "subzone" not in who
    stats = who["stats"]
    assert stats["intellect"] == 41 and stats["spellHit"] == 5 and stats["critFromIntellect"] == 2
    assert stats["lifeTap"] == {"id": 1456, "text": "Converts 310 health into 310 mana."}
    assert "meleeCrit" not in stats  # GetCritChance does not exist here; a missing function is not an error

    hat = c["equipment"][0]
    assert hat["id"] == 1001 and hat["slot"] == 1 and hat["durability"] == [30, 40] and hat["equipLoc"] == "INVTYPE_HEAD"
    assert hat["stats"] == {"ITEM_MOD_INTELLECT_SHORT": 10}
    # Line 1 (the name) and empty lines are dropped; a right column is joined with " | ".
    assert hat["tooltip"] == ["Head | Cloth", "+10 Intellect", "Equip: Improves your chance to hit by 1%."]
    assert hat["tipColors"] == ["ffffff", "ffffff", "00ff00"]

    bag = c["bags"][0]
    assert bag["id"] == 0 and bag["size"] == 16 and [(i["id"], i["count"]) for i in bag["items"]] == [(2447, 20), (284583, 1)]
    assert "bank" not in c  # only readable while the bank is open
    assert [q["id"] for q in c["quests"]] == [11, 12] and c["quests"][0]["category"] == "Durotar"
    assert c["quests"][1]["complete"] is True and c["quests"][1]["suggestedGroup"] == 2
    assert c["quests"][0]["objectives"][0]["have"] == 3 and c["quests"][0]["description"] == "Description 2"
    assert c["completedQuests"] == [3, 5]
    rep = c["reputation"][0]
    assert (rep["id"], rep["category"], rep["standing"], rep["value"], rep["max"]) == (76, "Horde", "Friendly", 4000, 9000)
    assert c["skills"]["professions"][0] == {"name": "Alchemy", "rank": 150, "max": 225, "skillLine": 171}
    assert c["currencies"] == {3402: {"name": "Merchant's Favor", "quantity": 7}}
    print("ok test_snapshot")


def test_combat_and_bank():
    lua = new_runtime()
    load_addon(lua)
    first = char(lua)["updated"]
    # In combat values are unreliable: the snapshot waits for the end of the fight.
    lua.execute('combat, money = true, 60000; fire("PLAYER_MONEY"); advance(10)')
    assert char(lua)["updated"] == first and char(lua)["character"]["money"] == 50000
    lua.execute('combat = false; fire("PLAYER_REGEN_ENABLED"); advance(3)')
    assert char(lua)["updated"] > first and char(lua)["character"]["money"] == 60000

    # The bank: every character bank container, never the account bank.
    lua.execute('fire("BANKFRAME_OPENED"); advance(3)')
    bank = char(lua)["bank"]
    assert [b["id"] for b in bank["containers"]] == [5] and bank["containers"][0]["items"][0]["id"] == 118
    # A failing section keeps its old data and reports the error.
    lua.execute('C_QuestLog.GetNumQuestLogEntries = function() error("boom") end; fire("QUEST_LOG_UPDATE"); advance(3)')
    c = char(lua)
    assert "boom" in c["errors"]["quests"] and len(c["quests"]) == 2
    print("ok test_combat_and_bank")


def test_payouts():
    lua = new_runtime()
    lua.execute("counts[284583] = 1; counts[248766] = 2")
    load_addon(lua)
    # Handing in a writ: the quest event and the new pouch arrive within seconds, in any order.
    lua.execute('counts[284583] = 2; fire("BAG_UPDATE_DELAYED"); advance(1); fire("QUEST_TURNED_IN", 94212, 0, 0)')
    # Opening a pouch: the pouch leaves the bags, the coins arrive.
    lua.execute('advance(10); money = money + 3000; fire("PLAYER_MONEY"); advance(1)')
    lua.execute('counts[284583] = 1; fire("BAG_UPDATE_DELAYED")')
    lua.execute('advance(10); counts[284583] = 0; fire("BAG_UPDATE_DELAYED"); money = money + 4000; fire("PLAYER_MONEY")')
    # Handing in a sealed crate pays Merchant's Favor.
    lua.execute('advance(10); counts[248766] = 1; fire("BAG_UPDATE_DELAYED"); fire("CURRENCY_DISPLAY_UPDATE", 3402, 17, 10)')
    # Too far apart: money that arrives 8 seconds after a pouch left is something else.
    lua.execute('advance(10); counts[284583] = 1; fire("BAG_UPDATE_DELAYED"); advance(1)')
    lua.execute('counts[284583] = 0; fire("BAG_UPDATE_DELAYED"); advance(8); money = money + 99; fire("PLAYER_MONEY")')
    p = account(lua)["payouts"]
    assert p["writQuests"][94212]["pouch"] == 284583 and p["writQuests"][94212]["n"] == 1
    pouch = p["pouches"][284583]
    assert (pouch["n"], pouch["sum"], pouch["min"], pouch["max"], pouch["last"]) == (2, 7000, 3000, 4000, 4000), pouch
    assert p["crates"][248766]["n"] == 1 and p["crates"][248766]["sum"] == 10
    print("ok test_payouts")


def test_recipes_and_vendor():
    lua = new_runtime()
    load_addon(lua)
    lua.execute('fire("TRADE_SKILL_SHOW"); fire("TRADE_SKILL_LIST_UPDATE"); advance(2)')
    alchemy = char(lua)["recipes"][171]  # keyed by the base skill line, not the expansion's child profession
    assert (alchemy["name"], alchemy["professionID"], alchemy["rank"], alchemy["learned"]) == ("Alchemy", 2485, 150, 1)
    assert sorted(alchemy["recipes"]) == [2330, 2331]  # the gathering entry is not a recipe
    known, unknown = alchemy["recipes"][2330], alchemy["recipes"][2331]
    assert known["learned"] is True and "source" not in known and known["output"] == 118 and known["qtyMax"] == 2
    assert known["reagents"] == [{"id": 2447, "count": 2, "type": 1}]
    assert "learned" not in unknown and unknown["source"] == "Trainer"
    assert alchemy["names"] == {2447: "Peacebloom", 118: "Minor Healing Potion"}
    # A linked or guild profession window is someone else's and must not overwrite the own recipes.
    lua.execute('C_TradeSkillUI.IsTradeSkillLinked = function() return true end')
    lua.execute('C_TradeSkillUI.GetAllRecipeIDs = function() return { 1 } end; fire("TRADE_SKILL_SHOW"); advance(2)')
    assert sorted(char(lua)["recipes"][171]["recipes"]) == [2330, 2331]

    lua.execute('fire("MERCHANT_SHOW")')
    vendor = account(lua)["vendor"]
    assert vendor[3371]["price"] == 20 and vendor[3371]["npc"] == "Vendor Bob" and "limited" not in vendor[3371]
    assert vendor[9300]["limited"] is True and 8000 not in vendor  # sold for another currency
    print("ok test_recipes_and_vendor")


def test_item_export():
    lua = new_runtime()
    load_addon(lua)
    lua.globals().SlashCmdList.WOWMCP("items")
    lua.execute("advance(2)")
    store = lua_to_py(lua.globals().WoWMCP_Items)
    # Equippable items of the last scan days; 1002 arrives from the server one tick after it was requested.
    assert sorted(store["items"]) == [1001, 1002] and store["count"] == 2 and store["missing"] in ([], {})
    assert (store["build"], store["locale"], store["source"]) == (70938, "enUS", "auctionator")
    hat = store["items"][1001]
    assert hat["name"] == "Hat of Testing" and hat["classID"] == 4 and hat["tooltip"][0] == "Head | Cloth"
    assert any("2 new items read, 2 in the export" in p for p in printed(lua)), printed(lua)

    # Closing the auction house exports only what is new, and stays quiet when there is nothing.
    lua.execute('printed = {}; fire("AUCTION_HOUSE_CLOSED"); advance(3)')
    assert printed(lua) == [] and lua_to_py(lua.globals().WoWMCP_Items)["lastRun"]["new"] == 0
    lua.globals().SlashCmdList.WOWMCP("auto off")
    assert account(lua)["autoItems"] is False and "is off" in printed(lua)[-1]

    # Another client language: names and tooltips would be mixed, so the export starts over.
    lua.execute('locale = "deDE"')
    load_addon(lua)
    lua.globals().SlashCmdList.WOWMCP("status")
    store = lua_to_py(lua.globals().WoWMCP_Items)
    assert store["locale"] == "deDE" and store["items"] in ([], {})
    # An export from before 1.6 has no locale and is kept.
    lua.execute("WoWMCP_Items = { build = 70938, items = { [1001] = { name = 'Hut' } } }")
    load_addon(lua)
    lua.globals().SlashCmdList.WOWMCP("status")
    store = lua_to_py(lua.globals().WoWMCP_Items)
    assert store["locale"] == "deDE" and 1001 in store["items"]
    print("ok test_item_export")


def test_app_requests():
    lua = new_runtime()
    load_addon(lua, '{ id = 5, action = "sync" }')
    assert account(lua)["lastRequest"]["id"] == 5 and account(lua)["lastRequest"]["action"] == "sync"
    done = account(lua)["lastRequest"]["done"]
    # The same id never runs twice.
    lua.execute("advance(100)")
    load_addon(lua, '{ id = 5, action = "sync" }')
    assert account(lua)["lastRequest"]["done"] == done
    # The item export reports back once it has finished.
    load_addon(lua, '{ id = 6, action = "items", full = true }')
    lua.execute("advance(5)")
    last = account(lua)["lastRequest"]
    assert (last["id"], last["action"], last["new"]) == (6, "items", 2), last
    load_addon(lua, '{ id = 7, action = "explode" }')
    assert account(lua)["lastRequest"]["error"] == "unknown action"
    # /wowmcp sync takes a snapshot and reloads.
    lua.globals().SlashCmdList.WOWMCP("sync")
    assert lua.globals().reloaded is True
    print("ok test_app_requests")


def test_locales():
    # A translation may only use keys that exist in English, with the same placeholders.
    texts = {}
    for locale in ("enUS", "deDE", "frFR"):
        lua = new_runtime(locale)
        texts[locale] = lua_to_py(load_addon(lua, enter=False).L)
    assert texts["frFR"] == texts["enUS"], "an unknown locale falls back to English"
    assert texts["deDE"].keys() == texts["enUS"].keys()
    for key, text in texts["enUS"].items():
        assert re.findall(r"%\.?\d*[dsf]", text) == re.findall(r"%\.?\d*[dsf]", texts["deDE"][key]), key
    # Every text the code asks for exists.
    code = read("WoWMCP.lua")
    used = set(re.findall(r"\bL\.(\w+)", code)) | set(re.findall(r'say\("(\w+)"', code)) | set(re.findall(r'"(help\w+)"', code))
    assert used and used <= set(texts["enUS"]), used - set(texts["enUS"])
    assert set(texts["enUS"]) <= used, f"unused texts: {set(texts['enUS']) - used}"

    lua = new_runtime("deDE")
    load_addon(lua)
    lua.execute("counts[284583] = 1; fire('BAG_UPDATE_DELAYED'); counts[284583] = 0; fire('BAG_UPDATE_DELAYED')")
    lua.execute("money = money + 3350; fire('PLAYER_MONEY')")
    for cmd in ("status", "help", "auto on", "items"):
        lua.globals().SlashCmdList.WOWMCP(cmd)
    out = "\n".join(printed(lua))
    assert "letzter Snapshot" in out and "Bank: nie gescannt" in out and "ist an (/wowmcp auto on|off)" in out, out
    assert "Münzbeutel 284583: 1x geöffnet, Schnitt 33.50s" in out, out
    assert "lese 2 neue Items" in out and "/wowmcp sync - Snapshot und /reload" in out, out
    print("ok test_locales")


def test_toc():
    fields, files = toc()
    assert fields["Interface"] == "16001" and re.fullmatch(r"\d+\.\d+\.\d+", fields["Version"]), fields
    assert files and files[-1] == f"{NAME}.lua"
    for name in files:
        assert os.path.isfile(os.path.join(ROOT, name)), f"{name} is listed in the .toc but missing"
    for name in os.listdir(ROOT):
        if name.endswith((".lua", ".xml")):
            assert name in files, f"{name} is not listed in the .toc"
    print("ok test_toc")


if __name__ == "__main__":
    test_snapshot()
    test_combat_and_bank()
    test_payouts()
    test_recipes_and_vendor()
    test_item_export()
    test_app_requests()
    test_locales()
    test_toc()
