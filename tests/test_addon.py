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
frames, postCalls, reloaded, modified = {}, {}, false, false

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

-- Widgets: frames, font strings and textures share one stub. It keeps what the tests look at (shown,
-- text, scripts, events, slider value, check state) and answers every other widget method with nothing.
local function nothing() end
local widgetMeta = { __index = function(_, key)
  if type(key) == "string" and key:match("^%u") then return nothing end
end }
function widget(kind, name, parent, template)
  local w = { kind = kind, name = name, parent = parent, template = template, shown = true,
              scripts = {}, hooks = {}, events = {}, points = {} }
  function w:Show()
    if not self.shown then
      self.shown = true
      if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
  end
  function w:Hide()
    if self.shown then
      self.shown = false
      if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
  end
  function w:SetShown(on) if on then self:Show() else self:Hide() end end
  function w:IsShown() return self.shown end
  function w:SetText(text) self.text = text end
  function w:GetText() return self.text end
  function w:GetTextWidth() return #(self.text or "") * 7 end
  function w:SetScript(what, fn) self.scripts[what] = fn end
  function w:GetScript(what) return self.scripts[what] end
  function w:HookScript(what, fn) self.hooks[what] = fn end
  function w:RegisterEvent(event) self.events[event] = true end
  function w:UnregisterEvent(event) self.events[event] = nil end
  function w:CreateFontString() return widget("FontString", nil, self) end
  function w:CreateTexture() return widget("Texture", nil, self) end
  function w:SetTexture(texture) self.texture = texture end
  function w:SetChecked(on) self.checked = on end
  function w:GetChecked() return self.checked end
  function w:SetEnabled(on) self.enabled = on end
  function w:IsEnabled() return self.enabled ~= false end
  function w:ClearAllPoints() self.points = {} end
  function w:SetPoint(...) self.points[#self.points + 1] = { ... } end
  function w:GetNumPoints() return #self.points end
  function w:GetPoint() if self.points[1] then return "TOPLEFT", UIParent, "TOPLEFT", 300, -200 end end
  function w:SetMinMaxValues(low, high) self.low, self.high = low, high end
  function w:SetValue(value)
    value = math.max(self.low or 0, math.min(self.high or 0, value))
    if value ~= self.value then
      self.value = value
      if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
    end
  end
  function w:GetValue() return self.value end
  function w:LockHighlight() self.locked = true end
  function w:UnlockHighlight() self.locked = false end
  function w:Click() if self.scripts.OnClick and self:IsEnabled() then self.scripts.OnClick(self, "LeftButton") end end
  if template == "UICheckButtonTemplate" then w.Text = widget("FontString", nil, w) end
  return setmetatable(w, widgetMeta)
end
function CreateFrame(kind, name, parent, template)
  local f = widget(kind, name, parent, template)
  frames[#frames + 1] = f
  if name then _G[name] = f end
  return f
end
-- Events reach every frame that registered for them, in the order the frames were created.
function fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
UIParent, UISpecialFrames = widget("Frame", "UIParent"), {}

-- Tooltips keep their lines; showing an item runs the hooks addons registered for item tooltips.
local function tooltipStub(name)
  local t = widget("GameTooltip", name)
  t.lines = {}
  function t:SetOwner() self.lines = {} end
  function t:SetText(text) self.lines = { text } end
  function t:AddLine(text) self.lines[#self.lines + 1] = text end
  function t:GetItem() if self.item and items[self.item] then return items[self.item].name, link(self.item) end end
  function t:SetItemByID(id)
    self.item = id
    self.lines = { items[id] and items[id].name or "?" }
    for _, fn in ipairs(postCalls) do fn(self, { id = id, type = 0 }) end
    if self.hooks.OnTooltipSetItem then self.hooks.OnTooltipSetItem(self) end
  end
  return t
end
GameTooltip, ItemRefTooltip, OtherTooltip = tooltipStub("GameTooltip"), tooltipStub("ItemRefTooltip"), tooltipStub("OtherTooltip")
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) postCalls[#postCalls + 1] = fn end }

ITEM_QUALITY_COLORS = {}
for quality, hex in pairs({ [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee" }) do
  ITEM_QUALITY_COLORS[quality] = { r = quality / 10, g = 1, b = 1, hex = "|cff" .. hex }
end
function GetMoneyString(copper)
  return ("%dg %ds %dc"):format(copper // 10000, copper // 100 % 100, copper % 100)
end
function IsModifiedClick() return modified end
linked = {}
function HandleModifiedItemClick(itemLink) linked[#linked + 1] = itemLink end

-- The auction house and Auctionator's API for other addons. Shopping lists live in `shopping`, as they
-- do in Auctionator's SavedVariables: they survive a /reload.
AuctionHouseFrame = { shown = false, searched = {}, SearchBar = {} }
function AuctionHouseFrame:IsShown() return self.shown end
function AuctionHouseFrame:SetSearchText(text) self.text = text return true end
function AuctionHouseFrame.SearchBar:StartSearch() table.insert(AuctionHouseFrame.searched, AuctionHouseFrame.text) end
AuctionatorTabs_Shopping = {}
shopping, created, searches = {}, 0, {}

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
  RequestLoadItemDataByID = function(id) if items[id] then items[id].loaded = true end end,
  GetItemIconByID = function(id) return items[id] and 130000 + id or nil end,
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

Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, Bank = -1, BankBag_1 = 5, AccountBankTab_1 = 13 },
         TooltipDataType = { Item = 0 } }
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
local function checked(caller, term)
  assert(type(caller) == "string" and caller ~= "", "caller ID")
  assert(type(term.searchString) == "string", "searchString")
  for _, value in pairs(term) do
    assert(type(value) ~= "string" or not (value:find("[;^]") or value:find('^".*"$')), "bad search term")
  end
  return term
end
Auctionator.API = { v1 = {
  ConvertToSearchString = function(caller, term)
    checked(caller, term)
    return ('"%s";%s;%s'):format(term.searchString, term.categoryKey or "", tostring(term.quantity or ""))
  end,
  CreateShoppingList = function(caller, name, strings)
    assert(type(caller) == "string" and type(name) == "string" and type(strings) == "table")
    shopping[name] = strings
    created = created + 1
  end,
  MultiSearchAdvanced = function(caller, terms)
    local names = {}
    for i, term in ipairs(terms) do
      checked(caller, term)
      names[i] = term.searchString .. (term.quantity and (" x" .. term.quantity) or "") .. (term.isExact and "" or " ~")
    end
    searches[#searches + 1] = names
  end,
} }
Auctionator.Shopping = { ListManager = {
  GetIndexForName = function(_, name) return shopping[name] and 1 or nil end,
  Delete = function(_, name) shopping[name] = nil end,
} }
"""


def new_runtime(locale="enUS"):
    lua = LuaRuntime(register_eval=False)
    lua.execute(STUBS)
    lua.globals().locale = locale
    lua.globals().VERSION = toc()[0]["Version"]
    return lua


def load_addon(lua, request=None, enter=True, data=None):
    """Runs the files of the .toc like the client does on login or /reload: in order, sharing one table.
    `request` and `data` are what the desktop app wrote into AppRequest.lua and AppData.lua (Lua source)."""
    load = lua.eval("function(src, name) return assert(load(src, name)) end")
    lua.execute("timers, frames, postCalls = {}, {}, {}")
    ns = lua.table()
    for name in toc()[1]:
        if name == "AppRequest.lua":
            lua.execute(f"WoWMCP_AppRequest = {request or 'nil'}")
        elif name == "AppData.lua":
            lua.execute(f"WoWMCP_AppData = {data or 'nil'}")
        else:
            load(read(name), name)(NAME, ns)
    lua.execute('fire("ADDON_LOADED", "WoWMCP")')
    if enter:
        lua.execute('fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD", true, false); advance(4)')
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


# What the desktop app writes into AppData.lua: three lists for Tester, one for another character.
def app_data(hash_="h1", writ_shop="true", extra=""):
    many = "".join(f'{{ id = {5000 + i}, name = "Filler {i}", price = {i} }}, ' for i in range(30))  # Filler 0 costs nothing
    return f"""{{ version = 1, generated = 1763400500, hash = "{hash_}", locale = "enUS", scanDate = "2026-11-18", chars = {{
      Tester = {{ level = 46,
        lists = {{
          {{ key = "upgrades", title = "AH upgrades", note = "Budget {{m:150000}}", sections = {{
            {{ title = "Best package", note = "+12.5 points for {{m:90000}}", rows = {{
              {{ id = 1001, name = "Sent Hat Name", q = 2, info = "Head +12.5", price = 90000, shop = true }},
              {{ id = 1002, name = "Staff of Waiting", q = 3, info = "Staff +3.0", price = 12345, shop = true }} }} }},
            {{ title = "Head", note = "now: Old Hat", rows = {{
              {{ id = 1001, name = "Sent Hat Name", q = 2, info = "+12.5", price = 90000 }},
              "junk", {{ name = "no id" }},
              {{ id = 1003, name = "Old Boots", info = "+1.0", price = 100 }} }} }},
            "not a section" }} }},
          {{ key = "writs", title = "Writs", sections = {{ {{ title = "Journeyman", rows = {{
              {{ id = 264012, name = "Writ: Elixir || Wisdom", q = 1, info = "net {{m:-500}}", price = 5000, shop = {writ_shop} }},
              {{ id = 2447, name = "Friedensblume", n = 20, price = 400, shop = {writ_shop}, sub = true }},
              {{ id = 7777, name = "Bad;Name", shop = {writ_shop} }},
              {many} }} }} }} }},
          {{ key = "look", title = "Nothing to buy", sections = {{ {{ title = "Potions", rows = {{
              {{ id = 118, name = "Minor Healing Potion" }} }} }} }} }},
          {{ key = "broken", sections = "x" }}, 5,
        }},
        tips = {{ [1001] = {{ "Upgrade for Head: +12.5 points ({{m:90000}})", "Part of the best package", 7 }}, [118] = "x" }},
        vendor = {{ [9300] = "Teaches Elixir: profit {{m:3000}} per craft", [3371] = false }},
      }},
      Other = {{ lists = {{ {{ key = "x", title = "Not mine", sections = {{}} }} }} }},
      {extra}
    }} }}"""


def window(lua):
    return lua.globals().WoWMCPListFrame


def visible(lua):
    """The rows on screen: ("head", title, note) or ("item", name, info, price)."""
    out = []
    for line in lua_to_py_list(window(lua).rows):
        if not line.shown:
            continue
        if line.head.shown:
            out.append(("head", line.head.text, line.note.text))
        else:
            out.append(("item", line.name.text, line.info.text, line.price.text))
    return out


def lua_to_py_list(table):
    return [table[i] for i in range(1, len(table) + 1)]


def tabs(lua):
    return [(t.text, bool(t.locked)) for t in lua_to_py_list(window(lua).tabs) if t.shown]


def slash(lua, text):
    lua.globals().SlashCmdList.WOWMCP(text)


def click(widget):
    widget.Click(widget)


def test_lists_window():
    lua = new_runtime()
    load_addon(lua, data=app_data())
    assert window(lua) is None, "the window is built when it is first needed"
    assert account(lua)["appData"] == {"generated": 1763400500, "hash": "h1", "loaded": lua.eval("time()") - 4}
    slash(lua, "show")
    w = window(lua)
    assert w.shown and "WoWMCPListFrame" in lua_to_py(lua.globals().UISpecialFrames)
    assert tabs(lua) == [("AH upgrades", True), ("Writs", False), ("Nothing to buy", False)], "broken lists are skipped"
    assert w.note.text == "Budget 15g 0s 0c" and "2026-11-18" in w.sub.text and w.empty.text == ""
    assert visible(lua) == [
        ("head", "Best package", "+12.5 points for 9g 0s 0c"),
        # The game's name wins over the one the app sent; * marks the shopping list.
        ("item", "|cffffd100*|r Hat of Testing", "Head +12.5", "9g 0s 0c"),
        ("item", "|cffffd100*|r Staff of Waiting", "Staff +3.0", "1g 23s 45c"),
        ("head", "Head", "now: Old Hat"),
        ("item", "Hat of Testing", "+12.5", "9g 0s 0c"),
        ("item", "Old Boots", "+1.0", "0g 1s 0c"),
    ], visible(lua)
    assert w.rows[2].icon.texture == 131001 and not w.slider.shown and w.buy.enabled

    # The second tab has more rows than fit: scrolling by wheel and by slider.
    click(w.tabs[2])
    assert tabs(lua)[1] == ("Writs", True) and account(lua)["ui"]["tab"] == "writs"
    rows = visible(lua)
    assert len(rows) == 16 and rows[0] == ("head", "Journeyman", "") and w.slider.shown and w.slider.high == 34 - 16
    # An item the client does not know keeps the name the app sent, with its escaped "|".
    assert rows[1] == ("item", "|cffffd100*|r Writ: Elixir || Wisdom", "net -0g 5s 0c", "0g 50s 0c")
    assert rows[2][1] == "|cffffd100*|r Peacebloom |cffffffffx20|r"
    w.scripts.OnMouseWheel(w, -1)
    assert visible(lua)[1] == ("item", "Filler 0", "", "") and w.slider.value == 3
    w.slider.SetValue(w.slider, 18)
    assert visible(lua)[-1][1] == "Filler 29" and len(visible(lua)) == 16
    w.scripts.OnMouseWheel(w, -5)
    assert visible(lua)[-1][1] == "Filler 29", "scrolling stops at the end"
    w.scripts.OnMouseWheel(w, 50)
    assert visible(lua)[0] == ("head", "Journeyman", "")

    # The tab is remembered, also over a /reload; a list without anything to buy disables the button.
    slash(lua, "show")
    assert not w.shown
    load_addon(lua, data=app_data())
    slash(lua, "show")
    assert tabs(lua)[1] == ("Writs", True)
    click(window(lua).tabs[3])
    assert visible(lua) == [("head", "Potions", ""), ("item", "Minor Healing Potion", "", "")]
    assert window(lua).buy.enabled is False

    # Dragging saves the position; the next opening uses it.
    w = window(lua)
    w.scripts.OnDragStop(w)
    assert account(lua)["ui"]["point"] == ["TOPLEFT", "TOPLEFT", 300, -200]
    slash(lua, "status")
    assert any("lists from the app: 3, computed" in line for line in printed(lua)), printed(lua)
    print("ok test_lists_window")


def test_lists_search():
    lua = new_runtime()
    load_addon(lua, data=app_data())
    slash(lua, "show")
    w = window(lua)
    click(w.rows[2])
    assert printed(lua)[-1].endswith("open the auction house first.") and not lua_to_py(lua.globals().searches)

    lua.execute("AuctionHouseFrame.shown = true; fire('AUCTION_HOUSE_SHOW')")
    click(w.rows[2])
    click(w.rows[1].search)   # the section "Best package"
    click(w.buy)
    click(w.tabs[2])
    click(w.buy)              # a name Auctionator cannot take is left out
    assert lua_to_py(lua.globals().searches) == [
        ["Hat of Testing"], ["Hat of Testing", "Staff of Waiting"], ["Hat of Testing", "Staff of Waiting"],
        ["Writ: Elixir | Wisdom", "Peacebloom x20"]], lua_to_py(lua.globals().searches)

    # Shift-click hands the game a link: the client puts it into the chat or the auction house search.
    lua.execute("modified = true")
    click(w.rows[2])
    click(w.rows[3])
    lua.execute("modified = false")
    links = lua_to_py(lua.globals().linked)
    assert "|Hitem:264012:" in links[0] and "[Writ: Elixir | Wisdom]" in links[0] and links[0].startswith("|cffffffff")
    assert links[1] == lua.eval("link(2447)") and len(lua_to_py(lua.globals().searches)) == 4

    # The tooltip of a row: the item, what the list says about it, and how to use the row.
    click(w.tabs[1])
    w.rows[2].scripts.OnEnter(w.rows[2])
    tip = lua_to_py(lua.globals().GameTooltip.lines)
    assert tip[0] == "Hat of Testing" and "Head +12.5" in tip and "On the shopping list" in tip, tip
    assert "Upgrade for Head: +12.5 points (9g 0s 0c)" in tip and tip[-1].startswith("Click: search")

    # Without Auctionator one item goes into Blizzard's search bar; several cannot be searched.
    lua.execute("Auctionator.API = nil")
    click(w.rows[2])
    assert lua_to_py(lua.globals().AuctionHouseFrame.searched) == ["Hat of Testing"]
    click(w.buy)
    assert printed(lua)[-1].endswith("needs Auctionator.") and len(lua_to_py(lua.globals().searches)) == 4
    print("ok test_lists_search")


def test_lists_open_with_the_auction_house():
    lua = new_runtime()
    load_addon(lua, data=app_data())
    lua.execute("AuctionHouseFrame.shown = true; fire('AUCTION_HOUSE_SHOW')")
    w = window(lua)
    assert w.shown and w.auto.checked is True
    lua.execute("AuctionHouseFrame.shown = false; fire('AUCTION_HOUSE_CLOSED')")
    assert not w.shown, "what opened with the auction house closes with it"
    slash(lua, "show")
    lua.execute("fire('AUCTION_HOUSE_SHOW'); fire('AUCTION_HOUSE_CLOSED')")
    assert w.shown, "a window the player opened stays"
    w.Hide(w)
    w.auto.checked = False
    click(w.auto)
    assert account(lua)["ui"]["ah"] is False
    lua.execute("fire('AUCTION_HOUSE_SHOW')")
    assert not w.shown
    slash(lua, "ah on")
    assert printed(lua)[-1].endswith("is on (/wowmcp ah on|off)")
    lua.execute("fire('AUCTION_HOUSE_SHOW')")
    assert w.shown
    print("ok test_lists_open_with_the_auction_house")


def test_shopping_lists():
    lua = new_runtime()
    load_addon(lua, data=app_data())
    assert not lua_to_py(lua.globals().shopping), "Auctionator gets time to load its lists first"
    lua.execute("advance(2)")
    lists = lua_to_py(lua.globals().shopping)
    assert lists == {
        "WoWMCP: AH upgrades": ['"Hat of Testing";;', '"Staff of Waiting";;'],
        "WoWMCP: Writs": ['"Writ: Elixir | Wisdom";;', '"Peacebloom";;20'],
    }, lists
    assert printed(lua)[-1].endswith("2 Auctionator shopping lists updated.")
    assert account(lua)["ui"]["synced"] == "h1:Tester"

    # The same file after a /reload: the lists are left alone, also what the player changed in them.
    load_addon(lua, data=app_data())
    lua.execute("advance(2)")
    assert lua.globals().created == 2
    # New data without anything to buy for the writs: that list goes, the other is written again.
    load_addon(lua, data=app_data("h2", writ_shop="false"))
    lua.execute("advance(2)")
    assert list(lua_to_py(lua.globals().shopping)) == ["WoWMCP: AH upgrades"] and lua.globals().created == 3

    slash(lua, "lists off")
    assert not lua_to_py(lua.globals().shopping) and printed(lua)[-1].endswith("are off (/wowmcp lists on|off)")
    load_addon(lua, data=app_data("h3"))
    lua.execute("advance(2)")
    assert not lua_to_py(lua.globals().shopping)
    slash(lua, "lists on")
    assert len(lua_to_py(lua.globals().shopping)) == 2

    # Not while the auction house is open (Auctionator would start searching), but when it closes.
    lua = new_runtime()
    lua.execute("AuctionHouseFrame.shown = true")
    load_addon(lua, data=app_data())
    lua.execute("advance(2)")
    assert not lua_to_py(lua.globals().shopping)
    lua.execute("AuctionHouseFrame.shown = false; fire('AUCTION_HOUSE_CLOSED')")
    assert len(lua_to_py(lua.globals().shopping)) == 2

    # Without Auctionator's API nothing happens and nothing is remembered as done.
    lua = new_runtime()
    lua.execute("Auctionator.API = nil")
    load_addon(lua, data=app_data())
    lua.execute("advance(2)")
    assert "synced" not in account(lua)["ui"]
    print("ok test_shopping_lists")


def test_tooltip_lines_and_vendor_hints():
    lua = new_runtime()
    load_addon(lua, data=app_data())

    def tip(name, item):
        lua.execute(f"{name}:SetItemByID({item})")
        return lua_to_py(lua.globals()[name].lines)

    assert tip("GameTooltip", 1001) == ["Hat of Testing", "Upgrade for Head: +12.5 points (9g 0s 0c)",
                                        "Part of the best package"]
    assert len(tip("ItemRefTooltip", 1001)) == 3
    assert tip("OtherTooltip", 1001) == ["Hat of Testing"], "only the item tooltips of the game"
    assert tip("GameTooltip", 1003) == ["Old Boots"] and tip("GameTooltip", 118) == ["Minor Healing Potion"]
    slash(lua, "tips off")
    assert tip("GameTooltip", 1001) == ["Hat of Testing"]
    slash(lua, "tips on")
    assert len(tip("GameTooltip", 1001)) == 3

    # A merchant who sells an item the app has a note for: one chat line, not again on every visit.
    lua.execute("fire('MERCHANT_SHOW')")
    hints = [line for line in printed(lua) if "Teaches Elixir" in line]
    assert len(hints) == 1 and "|Hitem:9300:" in hints[0] and hints[0].endswith("profit 0g 30s 0c per craft"), hints
    lua.execute("advance(60); fire('MERCHANT_SHOW')")
    assert len([line for line in printed(lua) if "Teaches Elixir" in line]) == 1
    lua.execute("advance(300); fire('MERCHANT_SHOW')")
    assert len([line for line in printed(lua) if "Teaches Elixir" in line]) == 2

    # A client without the tooltip data API: the hook on the tooltip itself.
    lua = new_runtime()
    lua.execute("TooltipDataProcessor = nil")
    load_addon(lua, data=app_data())
    assert len(tip("GameTooltip", 1001)) == 3 and tip("GameTooltip", 1003) == ["Old Boots"]
    print("ok test_tooltip_lines_and_vendor_hints")


def test_lists_without_or_with_bad_data():
    # Nothing sent yet, data for someone else only, and files that are not what the addon expects.
    cases = {
        "nil": "No lists for Tester yet",
        '{ chars = { Other = { lists = {} } } }': "No lists for Tester yet",
        '"text"': "No lists for Tester yet",
        '{ chars = 5 }': "No lists for Tester yet",
        '{ generated = "x", hash = 5, chars = { Tester = { lists = "x", tips = 5, vendor = true } } }': "No lists for Tester yet",
        '{ chars = { Tester = { lists = { { title = "T", sections = { { rows = "x" }, { title = 5, rows = { {} } } } } }, '
        'tips = { [1001] = 5 }, vendor = { [9300] = {} } } } }': "",
    }
    for data, empty in cases.items():
        lua = new_runtime()
        load_addon(lua, data=data)
        lua.execute("advance(10); AuctionHouseFrame.shown = true; fire('AUCTION_HOUSE_SHOW'); fire('MERCHANT_SHOW')")
        lua.execute("GameTooltip:SetItemByID(1001)")
        assert lua_to_py(lua.globals().GameTooltip.lines) == ["Hat of Testing"], data
        if empty:
            assert window(lua) is None, f"no window with the auction house without lists: {data}"
            slash(lua, "show")
        w = window(lua)
        assert w.shown and w.empty.text.startswith(empty) and (empty == "") == bool(tabs(lua)), data
        click(w.buy)
        for cmd in ("lists on", "lists off", "tips", "ah", "status"):
            slash(lua, cmd)
        assert char(lua)["errors"] == {} and not lua_to_py(lua.globals().shopping), data
    lua = new_runtime()
    load_addon(lua, data="nil")
    assert "appData" not in account(lua), "nothing loaded, nothing to report to the app"
    print("ok test_lists_without_or_with_bad_data")


def test_lists_in_german():
    lua = new_runtime("deDE")
    load_addon(lua, data=app_data())
    slash(lua, "show")
    w = window(lua)
    assert w.rows[1].search.text == "Suchen" and w.buy.text == "Einkaufsliste suchen" and w.auto.Text.text == "Mit dem Auktionshaus öffnen"
    assert w.sub.text.startswith("AH-Scan 2026-11-18, berechnet ")
    lua.execute("advance(2)")
    assert printed(lua)[-1].endswith("2 Auctionator-Einkaufslisten aktualisiert.")
    print("ok test_lists_in_german")


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
    code = read("WoWMCP.lua") + read("Lists.lua")
    used = (set(re.findall(r"\bL\.(\w+)", code)) | set(re.findall(r'say\("(\w+)"', code))
            | set(re.findall(r'"(help\w+|\w+State)"', code)))
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
    assert "/wowmcp show - die Listen der App" in out and "Listen der App: keine" in out, out
    print("ok test_locales")


def test_toc():
    fields, files = toc()
    assert fields["Interface"] == "16001" and re.fullmatch(r"\d+\.\d+\.\d+", fields["Version"]), fields
    # The data files come first, the texts before the code, and the window after the export.
    order = ["AppRequest.lua", "AppData.lua", "Locales.lua", f"{NAME}.lua", "Lists.lua"]
    assert [f for f in files if f in order] == order and "WoWMCP_Account" in fields["SavedVariables"], files
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
    test_lists_window()
    test_lists_search()
    test_lists_open_with_the_auction_house()
    test_shopping_lists()
    test_tooltip_lines_and_vendor_hints()
    test_lists_without_or_with_bad_data()
    test_lists_in_german()
    test_locales()
    test_toc()
