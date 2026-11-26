-- WoW Tools Forever: snapshots character state into per-character SavedVariables for an external MCP server.
-- Target: WoW Forever (Interface 16001, Mainline API family). Addons cannot do network or file I/O,
-- so the snapshot reaches disk only when the client writes SavedVariables on /reload or logout.

local ADDON_NAME, ns = ...
local L = ns.L
local ADDON_VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
local SCHEMA = 1
local THROTTLE_SECONDS = 2

-- Legacy trait trees on Forever 1.60.1 (Constants.LegacyConsts).
local LEGACY_TREES = { [1187] = "Professions", [1188] = "Adventure", [1189] = "Progression" }
local PVP_RANK_FACTION = 2800

local STATS = { "strength", "agility", "stamina", "intellect", "spirit" }
local SPELL_SCHOOLS = { [2] = "holy", [3] = "fire", [4] = "nature", [5] = "frost", [6] = "shadow", [7] = "arcane" }
local RESISTANCES = { [1] = "holy", [2] = "fire", [3] = "nature", [4] = "frost", [5] = "shadow", [6] = "arcane" }

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local function unpackOk(ok, ...)
    if ok then return ... end
end

-- Chat output in the language of the client (Locales.lua).
local function say(key, ...)
    print("|cffffd100WoW Tools Forever:|r " .. L[key]:format(...))
end

-- Calls fn protected; returns its results, or nothing if fn is missing or raises.
local function try(fn, ...)
    if type(fn) ~= "function" then return end
    return unpackOk(pcall(fn, ...))
end

local function isSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function num(v)
    if type(v) == "number" and not isSecret(v) then return v end
end

local function str(v)
    if type(v) == "string" and not isSecret(v) and v ~= "" then return v end
end

-- Shallow copy of string/number/boolean fields, dropping secret values and nested tables.
local function copyPlain(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        local tv = type(v)
        if (tv == "string" or tv == "number" or tv == "boolean") and not isSecret(v) then
            out[k] = v
        end
    end
    return out
end

local function colorHex(color)
    if type(color) ~= "table" then return nil end
    local r, g, b = num(color.r), num(color.g), num(color.b)
    if not (r and g and b) then return nil end
    return ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Tooltip text below the item name, as shown in game: one string per line ("left | right" when the line has
-- a right column, e.g. "Head | Cloth") plus each line's left text colour (red = requirement not met).
-- `first` is the first line to keep (default 2: line 1 is the item name).
local function tooltipLines(data, first)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local lines, colors = {}, {}
    for i = first or 2, #data.lines do
        local line = data.lines[i]
        local text, right = str(line.leftText), str(line.rightText)
        if right then text = (text or "") .. " | " .. right end
        if text then
            lines[#lines + 1] = text
            colors[#lines] = colorHex(line.leftColor) or "ffffff"
        end
    end
    return lines, colors
end

local function itemRecord(link, itemID, count)
    local name, _, quality, itemLevel, reqLevel, itemType, itemSubType, _, equipLoc, _, _, classID, subclassID,
        bindType = try(C_Item.GetItemInfo, link or itemID)
    return {
        id = itemID,
        link = link,
        -- GetItemInfo returns nil for items not yet in the client cache; the link always carries the name.
        name = name or (link and link:match("%[(.-)%]")),
        count = count or 1,
        quality = quality,
        ilvl = itemLevel,
        reqLevel = (num(reqLevel) and reqLevel > 1) and reqLevel or nil,
        type = str(itemType),
        subType = str(itemSubType),
        equipLoc = str(equipLoc),
        -- Since 1.12: item class and subclass as numbers (the names above are in the client's language)
        -- and how the item binds (0 never, 1 on pickup, 2 on equip, 3 on use).
        classID = num(classID),
        subclassID = num(subclassID),
        bind = num(bindType),
    }
end

-- Armor and weapons that can be equipped; class and slot come from the client files, no server request.
local function isEquippable(itemID)
    local id, _, _, equipLoc, _, classID = try(C_Item.GetItemInfoInstant, itemID)
    return id ~= nil and (classID == 2 or classID == 4) and str(equipLoc) ~= nil
end

---------------------------------------------------------------------------------------------------
-- Character and stats
---------------------------------------------------------------------------------------------------

local function sumAttackPower(base, pos, neg)
    if num(base) then return base + (num(pos) or 0) + (num(neg) or 0) end
end

-- Warlock Life Tap: highest known rank and its spell text ("Converts 310 health into 310 mana").
local LIFE_TAP_RANKS = { 11689, 11688, 11687, 1456, 1455, 1454 }

local function collectLifeTap()
    local known = C_SpellBook and C_SpellBook.IsSpellKnown
    if not known then return nil end
    for _, id in ipairs(LIFE_TAP_RANKS) do
        if try(known, id) then
            return { id = id, text = str(try(C_Spell.GetSpellDescription, id)) }
        end
    end
end

local function collectStats()
    local s = { spellDamage = {}, spellCrit = {}, resistances = {} }
    for i, key in ipairs(STATS) do
        local _, effective = try(UnitStat, "player", i)
        s[key] = num(effective)
    end
    local _, armor = try(UnitArmor, "player")
    s.armor = num(armor)
    s.attackPower = sumAttackPower(try(UnitAttackPower, "player"))
    s.rangedAttackPower = sumAttackPower(try(UnitRangedAttackPower, "player"))
    s.meleeCrit = num(try(GetCritChance))
    s.rangedCrit = num(try(GetRangedCritChance))
    s.meleeHit = num(try(GetHitModifier))
    s.spellHit = num(try(GetSpellHitModifier))
    s.dodge = num(try(GetDodgeChance))
    s.parry = num(try(GetParryChance))
    s.block = num(try(GetBlockChance))
    s.blockValue = num(try(GetShieldBlock))
    local defBase, defMod = try(UnitDefense, "player")
    if num(defBase) then s.defense = defBase + (num(defMod) or 0) end
    local mhSpeed, ohSpeed = try(UnitAttackSpeed, "player")
    if num(mhSpeed) and mhSpeed > 0 then
        s.meleeSpeed = mhSpeed
        if num(ohSpeed) and ohSpeed > 0 then s.offhandSpeed = ohSpeed end
    end
    local mhMin, mhMax, ohMin, ohMax = try(UnitDamage, "player")
    if num(mhMin) and num(mhMax) then
        s.meleeDamage = { min = mhMin, max = mhMax }
        if num(ohMin) and num(ohMax) and (ohMin > 0 or ohMax > 0) then
            s.offhandDamage = { min = ohMin, max = ohMax }
        end
    end
    local rSpeed, rMin, rMax = try(UnitRangedDamage, "player")
    if num(rSpeed) and rSpeed > 0 then
        s.rangedSpeed = rSpeed
        if num(rMin) and num(rMax) then s.rangedDamage = { min = rMin, max = rMax } end
    end
    s.meleeHaste = num(try(GetMeleeHaste))
    s.rangedHaste = num(try(GetRangedHaste))
    if try(IsDualWielding) then s.dualWield = true end
    s.healing = num(try(GetSpellBonusHealing))
    for school, key in pairs(SPELL_SCHOOLS) do
        s.spellDamage[key] = num(try(GetSpellBonusDamage, school))
        s.spellCrit[key] = num(try(GetSpellCritChance, school))
    end
    for school, key in pairs(RESISTANCES) do
        local _, total = try(UnitResistance, "player", school)
        s.resistances[key] = num(total)
    end
    s.healthMax = num(try(UnitHealthMax, "player"))
    s.powerMax = num(try(UnitPowerMax, "player"))
    local _, powerToken = try(UnitPowerType, "player")
    s.powerType = str(powerToken)
    -- What one point of a stat is worth at the current level, as the character sheet's tooltips compute it.
    if s.intellect then
        local fromInt = num(try(GetSpellCritChanceFromStat, 4, s.intellect))
        s.critFromIntellect = fromInt and fromInt * 100 -- percent from all intellect
    end
    if s.agility then
        local fromAgi = num(try(GetCritChanceFromAgility, "player"))
        if fromAgi then s.critFromAgility = fromAgi end
    end
    s.hpPerStamina = num(try(UnitHPPerStamina, "player"))
    -- Since 1.12: mana per second as the character sheet computes it (it shows these times 5):
    -- `base` outside the five-second rule, `casting` while casting; the two `spirit` values are the
    -- part that comes from spirit alone.
    local base, casting = try(GetManaRegen)
    local spirit, spiritCasting = try(GetManaRegenFromSpirit)
    if num(base) or num(spirit) then
        s.manaRegen = { base = num(base), casting = num(casting), spirit = num(spirit), spiritCasting = num(spiritCasting) }
    end
    s.manaPerIntellect = num(MANA_PER_INTELLECT)
    s.spellHaste = num(try(UnitSpellHaste, "player")) -- percent, since 1.12
    local formIndex = num(try(GetShapeshiftForm))
    if formIndex and formIndex > 0 then
        local _, active, _, formSpellID = try(GetShapeshiftFormInfo, formIndex)
        if active or formSpellID then
            s.form = {
                index = formIndex,
                spellID = num(formSpellID),
                name = formSpellID and str(try(C_Spell.GetSpellName, formSpellID)) or nil,
            }
        end
    end
    s.lifeTap = collectLifeTap()
    return s
end

-- The buffs on the character (since 1.12): the stats above include them, so a reader can tell a
-- snapshot taken with raid buffs from one without.
local function collectBuffs()
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return nil end
    local buffs = {}
    for i = 1, 40 do
        local aura = try(get, "player", i, "HELPFUL")
        if type(aura) ~= "table" then break end
        if num(aura.spellId) then
            buffs[#buffs + 1] = { id = aura.spellId, name = str(aura.name) }
        end
    end
    return buffs
end

local function collectPvpRank()
    local info = try(C_MajorFactions and C_MajorFactions.GetMajorFactionProgressionInfo, PVP_RANK_FACTION)
    local rank = info and num(info.renownLevel)
    if not rank then return nil end
    local factionIndex = UnitFactionGroup("player") == "Alliance" and 1 or 0
    return { rank = rank, title = _G[("PVP_RANK_%d_%d"):format(rank, factionIndex)] }
end

local function percent(v)
    if num(v) then return math.floor(v * 1000 + 0.5) / 10 end
end

-- In a dungeon or a raid the client keeps the character's stats secret: the calls answer with secret
-- values, which collectStats leaves out, so a snapshot taken there has health and mana but neither
-- attributes nor spell power, and everything the app computes from it would count them as 0. Such a
-- snapshot keeps the stats of the last one taken outside, with the buffs they include.
-- `statsUpdated` says when the stats were read, `statsKept` that they are older than the snapshot.
local function keepStats(c)
    local s = c.stats
    if s.stamina or s.intellect then
        c.statsUpdated = time()
        return
    end
    local old = WoWToolsForever_Char and WoWToolsForever_Char.character
    local kept = type(old) == "table" and old.stats
    if type(kept) == "table" and (kept.stamina or kept.intellect) then
        c.stats, c.buffs = kept, old.buffs
        c.statsUpdated, c.statsKept = old.statsUpdated or WoWToolsForever_Char.updated, true
    end
end

local function collectPet()
    if not try(UnitExists, "pet") then return nil end
    local speed = num(try(UnitAttackSpeed, "pet"))
    local dmgMin, dmgMax = try(UnitDamage, "pet")
    return {
        name = str(try(UnitName, "pet")),
        family = str(try(UnitCreatureFamily, "pet")),
        level = num(try(UnitLevel, "pet")),
        healthMax = num(try(UnitHealthMax, "pet")),
        attackPower = sumAttackPower(try(UnitAttackPower, "pet")),
        speed = (speed and speed > 0) and speed or nil,
        damage = (num(dmgMin) and num(dmgMax)) and { min = dmgMin, max = dmgMax } or nil,
    }
end

-- Temporary weapon enchants (oils, sharpening stones, poisons, shaman imbues): GetWeaponEnchantInfo
-- reports active main-hand and off-hand SpellItemEnchantment IDs and remaining duration in milliseconds.
local function collectWeaponEnchants()
    local mhHas, mhExp, mhCharges, mhID, ohHas, ohExp, ohCharges, ohID = try(GetWeaponEnchantInfo)
    local out = {}
    if mhHas and num(mhID) and mhID > 0 then
        out.mainHand = {
            id = mhID,
            remainingSec = (num(mhExp) and mhExp > 0) and math.floor(mhExp / 1000 + 0.5) or nil,
            charges = (num(mhCharges) and mhCharges > 0) and mhCharges or nil,
        }
    end
    if ohHas and num(ohID) and ohID > 0 then
        out.offHand = {
            id = ohID,
            remainingSec = (num(ohExp) and ohExp > 0) and math.floor(ohExp / 1000 + 0.5) or nil,
            charges = (num(ohCharges) and ohCharges > 0) and ohCharges or nil,
        }
    end
    return next(out) and out or nil
end

local function collectCharacter()
    local first, surname = UnitName("player")
    local className, classFile = UnitClass("player")
    local raceName, raceFile = UnitRace("player")
    local guildName, guildRank = GetGuildInfo("player")
    local c = {
        name = first,
        surname = str(surname), -- Forever returns the surname where other clients return the realm
        level = UnitLevel("player"),
        class = className,
        classFile = classFile,
        race = raceName,
        raceFile = raceFile,
        faction = UnitFactionGroup("player"),
        sex = ({ [2] = "male", [3] = "female" })[UnitSex("player")],
        money = GetMoney(),
        xp = num(UnitXP("player")),
        xpMax = num(UnitXPMax("player")),
        rested = num(GetXPExhaustion()),
        zone = str(GetRealZoneText()),
        subzone = str(GetSubZoneText()),
        guild = guildName and { name = guildName, rank = guildRank } or nil,
        dead = UnitIsDeadOrGhost("player") or nil,
        pvpRank = collectPvpRank(),
        stats = collectStats(),
        buffs = collectBuffs(),
        weaponEnchants = collectWeaponEnchants(),
        pet = collectPet(),
    }
    keepStats(c)
    local mapID = try(C_Map.GetBestMapForUnit, "player")
    if mapID then
        local info = try(C_Map.GetMapInfo, mapID)
        c.map = { id = mapID, name = info and info.name }
        local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
        if pos then
            local x, y = try(pos.GetXY, pos)
            c.map.x, c.map.y = percent(x), percent(y)
        end
    end
    return c
end

---------------------------------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------------------------------

local function collectEquipment()
    local items = {}
    for slot = 0, 19 do
        local link = try(GetInventoryItemLink, "player", slot)
        if link then
            local rec = itemRecord(link, try(GetInventoryItemID, "player", slot), 1)
            rec.slot = slot
            local enchID = str(link) and tonumber(link:match("item:%d+:(%d+)")) or nil
            if num(enchID) and enchID > 0 then rec.enchantId = enchID end
            local cur, max = try(GetInventoryItemDurability, slot)
            if num(cur) and num(max) then rec.durability = { cur, max } end
            rec.stats = copyPlain(try(C_Item.GetItemStats, link))
            rec.tooltip, rec.tipColors = tooltipLines(try(C_TooltipInfo.GetInventoryItem, "player", slot))
            items[#items + 1] = rec
        end
    end
    return items
end

local function bagIDs(match)
    local ids, seen = {}, {}
    for key, id in pairs(Enum.BagIndex or {}) do
        if type(key) == "string" and type(id) == "number" and not seen[id] and match(key) then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

local function isCarriedBag(key)
    return key == "Backpack" or key == "ReagentBag" or key:match("^Bag_%d+$") ~= nil
end

-- Forever's bank container IDs are unverified (Retail moved from Bank/BankBag_n to CharacterBankTab_n),
-- so take every character bank index the client defines and skip the account (warband) bank.
local function isCharacterBank(key)
    local k = key:lower()
    return k:find("bank", 1, true) ~= nil and not k:find("account", 1, true) and not k:find("warband", 1, true)
end

local function scanContainer(bag)
    local size = try(C_Container.GetContainerNumSlots, bag)
    if not num(size) or size == 0 then return nil end
    local items = {}
    for slot = 1, size do
        local info = try(C_Container.GetContainerItemInfo, bag, slot)
        if info and info.itemID then
            local rec = itemRecord(info.hyperlink, info.itemID, info.stackCount)
            rec.slot = slot
            rec.bound = info.isBound or nil
            -- Since 1.12: gear in bags and bank carries its stats and tooltip like equipped gear, so
            -- the app can rate what the character already owns (the link has the random suffix; the
            -- item export only knows auction house items by their ID).
            if isEquippable(info.itemID) then
                rec.stats = str(info.hyperlink) and copyPlain(try(C_Item.GetItemStats, info.hyperlink)) or nil
                rec.tooltip, rec.tipColors = tooltipLines(try(C_TooltipInfo.GetBagItem, bag, slot))
                if (not rec.tooltip or #rec.tooltip == 0) and str(info.hyperlink) then
                    rec.tooltip, rec.tipColors = tooltipLines(try(C_TooltipInfo.GetHyperlink, info.hyperlink))
                end
            end
            items[#items + 1] = rec
        end
    end
    return {
        id = bag,
        name = str(try(C_Container.GetBagName, bag)),
        size = size,
        free = num(try(C_Container.GetContainerNumFreeSlots, bag)),
        items = items,
    }
end

local function collectBags()
    local ids = bagIDs(isCarriedBag)
    if #ids == 0 then
        for bag = 0, NUM_BAG_SLOTS or 4 do ids[#ids + 1] = bag end
    end
    local containers = {}
    for _, bag in ipairs(ids) do
        containers[#containers + 1] = scanContainer(bag)
    end
    return containers
end

local bankOpen = false

-- Bank contents are only readable while the bank is open; the last scan persists across sessions.
local function scanBank()
    local db = WoWToolsForever_Char
    local containers = {}
    for _, bag in ipairs(bagIDs(isCharacterBank)) do
        containers[#containers + 1] = scanContainer(bag)
    end
    if #containers > 0 then
        db.bank = { updated = time(), containers = containers }
        db.errors.bank = nil
        return
    end
    local keys = {}
    for key in pairs(Enum.BagIndex or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    db.errors.bank = "no readable bank containers; Enum.BagIndex keys: " .. table.concat(keys, ",")
end

---------------------------------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------------------------------

local function collectQuests()
    local quests, category = {}, nil
    local firstDescription, descriptionsDiffer = nil, false
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and info.isHeader then
            category = info.title
        elseif info and not info.isHidden and (info.questID or 0) > 0 then
            local id = info.questID
            local q = {
                id = id,
                title = info.title,
                level = info.level,
                suggestedGroup = (num(info.suggestedGroup) or 0) > 0 and info.suggestedGroup or nil,
                category = category,
                complete = try(C_QuestLog.IsComplete, id) or nil,
                failed = try(C_QuestLog.IsFailed, id) or nil,
                rewardXP = num(try(GetQuestLogRewardXP, id)),
                rewardMoney = num(try(GetQuestLogRewardMoney, id)),
                objectives = {},
            }
            for _, o in ipairs(try(C_QuestLog.GetQuestObjectives, id) or {}) do
                q.objectives[#q.objectives + 1] = {
                    text = str(o.text),
                    finished = o.finished,
                    have = num(o.numFulfilled),
                    need = num(o.numRequired),
                }
            end
            local description, objectiveText = try(GetQuestLogQuestText, index)
            q.description, q.objectiveText = str(description), str(objectiveText)
            if q.description then
                if firstDescription == nil then
                    firstDescription = q.description
                elseif firstDescription ~= q.description then
                    descriptionsDiffer = true
                end
            end
            quests[#quests + 1] = q
        end
    end
    -- If GetQuestLogQuestText ignores the index it returns the selected quest's text for every entry;
    -- identical texts across several quests mean it did, so drop them rather than export wrong data.
    if #quests > 1 and firstDescription and not descriptionsDiffer then
        for _, q in ipairs(quests) do q.description, q.objectiveText = nil, nil end
    end
    return quests
end

local function collectCompletedQuests()
    local ids = try(C_QuestLog.GetAllCompletedQuestIDs)
    if type(ids) ~= "table" then return nil end
    table.sort(ids)
    return ids
end

---------------------------------------------------------------------------------------------------
-- Reputation, skills, talents
---------------------------------------------------------------------------------------------------

local function joinCategory(header, subheader)
    if header and subheader then return header .. " / " .. subheader end
    return subheader or header
end

local function collectReputation()
    -- Collapsed headers hide their factions from the index API; this expands the reputation panel.
    try(C_Reputation.ExpandAllFactionHeaders)
    local factions, header, subheader = {}, nil, nil
    for index = 1, C_Reputation.GetNumFactions() do
        local d = C_Reputation.GetFactionDataByIndex(index)
        if d then
            local category = joinCategory(header, subheader)
            if d.isHeader and not d.isChild then
                header, subheader = d.name, nil
            elseif d.isHeader then
                subheader = d.name
            end
            if not d.isHeader or d.isHeaderWithRep then
                factions[#factions + 1] = {
                    id = d.factionID,
                    name = d.name,
                    category = category,
                    reaction = d.reaction,
                    standing = _G["FACTION_STANDING_LABEL" .. tostring(d.reaction)],
                    value = num(d.currentStanding),
                    min = num(d.currentReactionThreshold),
                    max = num(d.nextReactionThreshold),
                    atWar = d.atWarWith or nil,
                }
            end
        end
    end
    return factions
end

local function collectSkills()
    local out = { professions = {}, skills = {} }
    for _, index in pairs({ try(GetProfessions) }) do
        local name, _, rank, maxRank, _, _, skillLine, modifier = try(GetProfessionInfo, index)
        if name then
            out.professions[#out.professions + 1] = {
                name = name,
                rank = num(rank),
                max = num(maxRank),
                modifier = (num(modifier) or 0) ~= 0 and modifier or nil,
                skillLine = skillLine,
            }
        end
    end
    -- C_SkillInfo backs Forever's Skills tab (weapon skills, languages, professions); no count
    -- function is documented, so read until the index runs out.
    local category
    for index = 1, 500 do
        local row = copyPlain(try(C_SkillInfo and C_SkillInfo.GetSkillLineInfo, index))
        if not row then break end
        if row.isHeader then
            category = row.name or row.skillName
        else
            row.category = category
            out.skills[#out.skills + 1] = row
        end
    end
    return out
end

local function exportTree(configID, treeID)
    local tree = { treeID = treeID, groups = {}, talents = {} }

    local currency = try(C_Traits.GetTreeCurrencyInfo, configID, treeID, false)
    if type(currency) == "table" and currency[1] then
        tree.spent, tree.unspent = num(currency[1].spent), num(currency[1].quantity)
    end

    -- On Forever the talent tabs (e.g. Arms/Fury/Protection) are trait groups within one tree.
    local groupName, groupIDs = {}, {}
    for _, g in ipairs(try(C_Traits.GetGroupDisplayInfoByTreeID, treeID) or {}) do
        groupName[g.groupID] = g.displayName
        groupIDs[#groupIDs + 1] = g.groupID
    end
    if #groupIDs > 0 then
        local spent = {}
        for _, e in ipairs(try(C_Traits.GetGroupCurrencyInfo, configID, groupIDs) or {}) do
            local info = e.currencyInfos and e.currencyInfos[1]
            if info then spent[e.traitNodeGroupID] = num(info.spent) end
        end
        for _, id in ipairs(groupIDs) do
            -- Groups without points are omitted from GetGroupCurrencyInfo's result.
            tree.groups[#tree.groups + 1] = { id = id, name = groupName[id], spent = spent[id] or 0 }
        end
    end

    for _, nodeID in ipairs(try(C_Traits.GetTreeNodes, treeID) or {}) do
        local node = try(C_Traits.GetNodeInfo, configID, nodeID)
        local rank = node and num(node.activeRank) or 0
        if rank > 0 then
            local entryID = (node.activeEntry and node.activeEntry.entryID) or (node.entryIDs and node.entryIDs[1])
            local entry = entryID and try(C_Traits.GetEntryInfo, configID, entryID)
            local definition = entry and entry.definitionID and try(C_Traits.GetDefinitionInfo, entry.definitionID)
            local spellID = definition and (definition.overriddenSpellID or definition.spellID)
            local name = definition and str(definition.overrideName)
            if not name and spellID then name = str(try(C_Spell.GetSpellName, spellID)) end
            -- A node's tab is whichever of its groupIDs is a display group, not necessarily the first.
            local group
            for _, gid in ipairs(node.groupIDs or {}) do
                if groupName[gid] then group = groupName[gid] break end
            end
            -- Since 1.12: what the talent does at the learned rank. `tip` is the talent tooltip for
            -- that rank, `text` the description of the talent's spell (one spell serves every rank,
            -- so its numbers are not always the learned rank's).
            local tip = entryID and tooltipLines(try(C_TooltipInfo.GetTraitEntry, entryID, rank), 1)
            tree.talents[#tree.talents + 1] = {
                name = name,
                spellID = spellID,
                rank = rank,
                maxRank = num(node.maxRanks),
                group = group,
                text = spellID and str(try(C_Spell.GetSpellDescription, spellID)) or nil,
                tip = (tip and #tip > 0) and tip or nil,
            }
        end
    end
    return tree
end

local function collectTalents()
    local out = { class = {}, legacy = {} }
    local configID = try(C_ClassTalents.GetActiveConfigID)
    local config = configID and try(C_Traits.GetConfigInfo, configID)
    if config then
        for _, treeID in ipairs(config.treeIDs or {}) do
            out.class[#out.class + 1] = exportTree(configID, treeID)
        end
    end
    for treeID, label in pairs(LEGACY_TREES) do
        local legacyConfigID = try(C_Traits.GetConfigIDByTreeID, treeID)
        if legacyConfigID then
            local tree = exportTree(legacyConfigID, treeID)
            tree.label = label
            out.legacy[#out.legacy + 1] = tree
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Recipes: read while the player's own profession window is open (the trade skill API only has data
-- then). Stored per profession in WoWToolsForever_Char.recipes[skillLineID], so each window opened once is enough.
---------------------------------------------------------------------------------------------------

local function professionInfo()
    local child = try(C_TradeSkillUI.GetChildProfessionInfo)
    local base = try(C_TradeSkillUI.GetBaseProfessionInfo)
    local info = (child and num(child.professionID) and child.professionID ~= 0) and child or base
    if not info or not num(info.professionID) or info.professionID == 0 then return nil end
    return info, base
end

local function recipeReagents(schematic, names)
    local out = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        local id = first and num(first.itemID)
        local count = num(slot.quantityRequired)
        if id and count and count > 0 then
            out[#out + 1] = { id = id, count = count, type = num(slot.reagentType), optional = not slot.required or nil }
            names[id] = names[id] or str(try(C_Item.GetItemNameByID, id))
        end
    end
    return out
end

local function scanTradeSkill()
    if try(C_TradeSkillUI.IsTradeSkillLinked) or try(C_TradeSkillUI.IsTradeSkillGuild)
        or try(C_TradeSkillUI.IsNPCCrafting) then
        return
    end
    local info, base = professionInfo()
    local ids = info and try(C_TradeSkillUI.GetAllRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then return end
    local names, recipes, learned = {}, {}, 0
    for _, id in ipairs(ids) do
        local r = try(C_TradeSkillUI.GetRecipeInfo, id)
        if r and not r.isDummyRecipe and not r.isGatheringRecipe then
            local rec = {
                name = str(r.name),
                learned = r.learned or nil,
                difficulty = num(r.relativeDifficulty), -- 0 orange, 1 yellow, 2 green, 3 grey
                skillUps = num(r.numSkillUps),
                category = num(r.categoryID),
            }
            local s = try(C_TradeSkillUI.GetRecipeSchematic, id, false)
            if s then
                rec.output = num(s.outputItemID)
                rec.qtyMin, rec.qtyMax = num(s.quantityMin), num(s.quantityMax)
                rec.reagents = recipeReagents(s, names)
                if rec.output then names[rec.output] = names[rec.output] or str(try(C_Item.GetItemNameByID, rec.output)) end
            end
            if not r.learned then rec.source = str(try(C_TradeSkillUI.GetRecipeSourceText, id)) end
            if r.learned then learned = learned + 1 end
            recipes[id] = rec
        end
    end
    local db = WoWToolsForever_Char
    db.recipes = type(db.recipes) == "table" and db.recipes or {}
    -- The DB2 tables list recipes under the base skill line (171 = Alchemy), so that is the key.
    local key = (base and num(base.professionID) and base.professionID ~= 0) and base.professionID
        or num(info.parentProfessionID) or info.professionID
    db.recipes[key] = {
        name = str(info.parentProfessionName) or str(info.professionName),
        professionID = info.professionID,
        rank = num(info.skillLevel),
        max = num(info.maxSkillLevel),
        modifier = (num(info.skillModifier) or 0) ~= 0 and info.skillModifier or nil,
        updated = time(),
        learned = learned,
        recipes = recipes,
        names = names,
    }
end

local tradeSkillPending = false
local function requestTradeSkillScan()
    if tradeSkillPending then return end
    tradeSkillPending = true
    -- TRADE_SKILL_LIST_UPDATE fires in bursts while the window fills; read once it is quiet.
    C_Timer.After(1, function()
        tradeSkillPending = false
        local ok, err = pcall(scanTradeSkill)
        WoWToolsForever_Char.errors.recipes = (not ok) and tostring(err) or nil
    end)
end

-- Vendor prices: what a merchant sells for gold (reagents like vials, and vendor recipes), per item.
local function scanMerchant()
    local n = num(try(GetMerchantNumItems)) or 0
    if n == 0 then return end
    WoWToolsForever_Account.vendor = type(WoWToolsForever_Account.vendor) == "table" and WoWToolsForever_Account.vendor or {}
    local npc = str(UnitName("npc"))
    for index = 1, n do
        local info = try(C_MerchantFrame.GetItemInfo, index)
        local id = num(try(GetMerchantItemID, index))
        if info and id and num(info.price) and info.price > 0 and not info.hasExtendedCost then
            local stack = math.max(1, num(info.stackCount) or 1)
            WoWToolsForever_Account.vendor[id] = {
                price = info.price / stack,
                npc = npc,
                limited = (num(info.numAvailable) or -1) >= 0 or nil,
                updated = time(),
            }
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Payouts: what writs and trade crates really return. A writ quest pays no gold itself, it hands out
-- a coin pouch (four pouch items, one per writ tier) whose coins the server rolls when it is opened.
-- Sealed crates pay Merchant's Favor on turn-in. The two halves of each payout arrive as separate
-- events in no fixed order (bag change, money or currency change, quest turn-in), so each half is
-- kept for PAIR_SECONDS and recorded once the matching half shows up. Stored account-wide in
-- WoWToolsForever_Account.payouts: pouches[itemID] / crates[itemID] = {n, sum, min, max, last, updated},
-- writQuests[questID] = {pouch, money, n, updated}.
---------------------------------------------------------------------------------------------------

local POUCHES = { 284583, 284584, 284585, 284586 }
local FAVOR_CURRENCY = 3402
local PAIR_SECONDS = 5
local TRACKED = {}
for _, id in ipairs(POUCHES) do TRACKED[id] = "pouch" end
for id = 248765, 248779 do TRACKED[id] = "crate" end -- sealed crates: 5 tiers in common/uncommon/rare

local trackedCounts -- item ID -> count in bags + bank at the last bag update
local lastMoney
local pend = {}

local function payouts()
    local p = type(WoWToolsForever_Account.payouts) == "table" and WoWToolsForever_Account.payouts or {}
    p.pouches = type(p.pouches) == "table" and p.pouches or {}
    p.crates = type(p.crates) == "table" and p.crates or {}
    p.writQuests = type(p.writQuests) == "table" and p.writQuests or {}
    WoWToolsForever_Account.payouts = p
    return p
end

local function addSample(t, key, value)
    local s = type(t[key]) == "table" and t[key] or { n = 0, sum = 0 }
    s.n, s.sum = s.n + 1, s.sum + value
    s.min, s.max = math.min(s.min or value, value), math.max(s.max or value, value)
    s.last, s.updated = value, time()
    t[key] = s
end

local function fresh(key)
    local e = pend[key]
    return e and GetTime() - e.t <= PAIR_SECONDS
end

local function take(a, b)
    local x, y = pend[a], pend[b]
    pend[a], pend[b] = nil, nil
    return x, y
end

local function pairPayouts()
    local p = payouts()
    if fresh("quest") and fresh("pouchGained") then
        local q, pouch = take("quest", "pouchGained")
        local rec = type(p.writQuests[q.id]) == "table" and p.writQuests[q.id] or { n = 0 }
        rec.n, rec.pouch, rec.money, rec.updated = rec.n + 1, pouch.id, q.money, time()
        p.writQuests[q.id] = rec
    end
    if fresh("pouchUsed") and fresh("money") then
        local pouch, money = take("pouchUsed", "money")
        addSample(p.pouches, pouch.id, money.amount)
    end
    if fresh("crateUsed") and fresh("favor") then
        local crate, favor = take("crateUsed", "favor")
        addSample(p.crates, crate.id, favor.amount)
    end
end

local function trackBags()
    local seed = trackedCounts == nil
    trackedCounts = trackedCounts or {}
    for id, kind in pairs(TRACKED) do
        local count = num(try(C_Item.GetItemCount, id, true)) or 0
        local old = trackedCounts[id]
        if not seed and old then
            if count > old and kind == "pouch" then
                pend.pouchGained = { id = id, t = GetTime() }
            elseif count < old then
                pend[kind == "pouch" and "pouchUsed" or "crateUsed"] = { id = id, t = GetTime() }
            end
        end
        trackedCounts[id] = count
    end
    pairPayouts()
end

local function trackMoney()
    local money = num(GetMoney())
    if money and lastMoney and money > lastMoney then
        pend.money = { amount = money - lastMoney, t = GetTime() }
        pairPayouts()
    end
    lastMoney = money or lastMoney
end

local function trackQuest(questID, money)
    questID = num(questID)
    if not questID then return end
    pend.quest = { id = questID, money = num(money) or 0, t = GetTime() }
    pairPayouts()
end

local function trackCurrency(currencyType, change)
    if num(currencyType) == FAVOR_CURRENCY and (num(change) or 0) > 0 then
        pend.favor = { amount = num(change), t = GetTime() }
        pairPayouts()
    end
end

local function collectCurrencies()
    local info = try(C_CurrencyInfo.GetCurrencyInfo, FAVOR_CURRENCY)
    if type(info) ~= "table" then return {} end
    return { [FAVOR_CURRENCY] = { name = str(info.name), quantity = num(info.quantity) or 0 } }
end

---------------------------------------------------------------------------------------------------
-- Spellbook (since 1.11): every spell the character knows, with its rank line and description.
-- The app's combat engine prefers this over assuming that every trainer rank is known; the
-- description's resolved numbers also serve as ground truth for the engine's spell data.
---------------------------------------------------------------------------------------------------

-- What a cast costs: the mana cost if the spell has one, else its first cost with the power type.
local function spellCost(spellID)
    local costs = try(C_Spell.GetSpellPowerCost, spellID)
    if type(costs) ~= "table" then return nil end
    local other
    for _, c in ipairs(costs) do
        if type(c) == "table" and num(c.cost) and c.cost > 0 then
            if num(c.type) == 0 then return c.cost end
            other = other or c
        end
    end
    if other then return other.cost, num(other.type) end
end

local function collectSpellbook()
    local book = C_SpellBook
    if not (book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo
            and book.GetSpellBookItemInfo) then
        return nil
    end
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
    local spells, count = {}, 0
    for lineIndex = 1, try(book.GetNumSpellBookSkillLines) or 0 do
        local line = try(book.GetSpellBookSkillLineInfo, lineIndex)
        -- Guild and off-spec pages are not the character's own book.
        if line and not line.isGuild and not line.offSpecID then
            local offset, n = num(line.itemIndexOffset) or 0, num(line.numSpellBookItems) or 0
            for slot = offset + 1, offset + n do
                local item = try(book.GetSpellBookItemInfo, slot, bank)
                -- Only learned spells: future (level-gated) spells, flyouts and pet actions are skipped.
                if item and item.spellID and item.itemType == spellType then
                    local cost, costType = spellCost(item.spellID)
                    local info = try(C_Spell.GetSpellInfo, item.spellID)
                    local cooldown = num(try(GetSpellBaseCooldown, item.spellID))
                    spells[item.spellID] = {
                        name = str(item.name),
                        -- "Rank 4" in the client's language; may still be empty right after
                        -- loading (SPELL_TEXT_UPDATE), the next snapshot fills it.
                        rank = str(item.subName),
                        text = str(try(C_Spell.GetSpellDescription, item.spellID)),
                        passive = item.isPassive and true or nil,
                        -- Since 1.12, as the game computes them (talents included): what a cast
                        -- costs (mana unless costType names another power), cast time and cooldown
                        -- in milliseconds.
                        cost = cost,
                        costType = costType,
                        castTime = type(info) == "table" and num(info.castTime) or nil,
                        cooldown = (cooldown and cooldown > 0) and cooldown or nil,
                    }
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then return nil end
    return { updated = time(), count = count, spells = spells }
end

---------------------------------------------------------------------------------------------------
-- Snapshot scheduling
---------------------------------------------------------------------------------------------------

local SECTIONS = {
    character = collectCharacter,
    equipment = collectEquipment,
    bags = collectBags,
    quests = collectQuests,
    completedQuests = collectCompletedQuests,
    reputation = collectReputation,
    skills = collectSkills,
    talents = collectTalents,
    spellbook = collectSpellbook,
    currencies = collectCurrencies,
}

-- A failing section keeps its previous data and records the error for the server to report.
local function snapshot()
    local db = WoWToolsForever_Char
    for key, collect in pairs(SECTIONS) do
        local ok, result = pcall(collect)
        if ok and result ~= nil then
            db[key], db.errors[key] = result, nil
        else
            db.errors[key] = ok and "no data returned" or tostring(result)
        end
    end
    if bankOpen then pcall(scanBank) end
    local version, build, _, interface = GetBuildInfo()
    db.schema = SCHEMA
    db.updated = time()
    -- The locale tells readers which language names, tooltips and spell texts are in.
    db.client = { version = version, build = tonumber(build), interface = interface, locale = GetLocale() }
    db.addon = { version = ADDON_VERSION }
end

local pending, dirty = false, false

local function inCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

local function runPending()
    pending = false
    -- Combat makes many values secret; PLAYER_REGEN_ENABLED re-requests the snapshot.
    if inCombat() then return end
    dirty = false
    snapshot()
end

local function requestSnapshot()
    dirty = true
    if not pending then
        pending = true
        C_Timer.After(THROTTLE_SECONDS, runPending)
    end
end

---------------------------------------------------------------------------------------------------
-- Item export ("/wtf items"): stats and tooltip text for equippable items seen in the auction house.
-- Account-wide and incremental: WoWToolsForever_Items keeps every item already read for the current client
-- build, so a run after the next AH scan only asks the server for items it has not seen yet.
---------------------------------------------------------------------------------------------------

-- Always included: Spellstones and wizard oils, so their tooltips (duration, slot) can be compared.
local EXTRA_ITEMS = { 5522, 13602, 13603, 20746, 20750 }
local ITEM_BATCH = 40       -- new item requests per tick
local ITEM_TICK = 0.25      -- seconds
local ITEM_IDLE_TICKS = 40  -- stop after ~10 s without progress
local AH_RECENT_DAYS = 4    -- Auctionator scan days that count as "currently listed"

local itemRun

local function clientBuild()
    local _, build = GetBuildInfo()
    return tonumber(build)
end

local function itemInfoRecord(itemID)
    local name, link, quality, itemLevel, reqLevel, _, _, _, equipLoc, _, _, classID, subclassID, bindType =
        try(C_Item.GetItemInfo, itemID)
    if not str(name) then return nil end
    local rec = {
        name = name,
        link = str(link),
        quality = num(quality),
        ilvl = num(itemLevel),
        reqLevel = num(reqLevel),
        equipLoc = str(equipLoc),
        classID = num(classID),
        subclassID = num(subclassID),
        bind = num(bindType),
        stats = str(link) and copyPlain(try(C_Item.GetItemStats, link)) or nil,
    }
    rec.tooltip, rec.tipColors = tooltipLines(try(C_TooltipInfo.GetItemByID, itemID))
    return rec
end

-- Item IDs Auctionator saw in its scans of the last AH_RECENT_DAYS days. Auctionator decodes its price
-- database on login, so this needs no generated file and no game restart.
local function auctionatorItems()
    local database = Auctionator and Auctionator.Database
    local db = database and database.db
    local day0 = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
    if type(db) ~= "table" or not day0 then return nil end
    local cutoff = math.floor((time() - day0) / 86400) - AH_RECENT_DAYS + 1
    local ids = {}
    for key, data in pairs(db) do
        local id = tonumber(key)
        if id and type(data) == "table" then
            for day in pairs(data.h or {}) do
                if (tonumber(day) or 0) >= cutoff then
                    ids[#ids + 1] = id
                    break
                end
            end
        end
    end
    return ids
end

-- Names and tooltips are in the language of the client, so the export starts over when the build or the
-- language changes. Exports from before 1.6 carry no locale and are taken as the current one.
local function itemStore()
    local build, locale = clientBuild(), GetLocale()
    if type(WoWToolsForever_Items) == "table" and WoWToolsForever_Items.locale == nil then WoWToolsForever_Items.locale = locale end
    if type(WoWToolsForever_Items) ~= "table" or WoWToolsForever_Items.build ~= build or WoWToolsForever_Items.locale ~= locale then
        WoWToolsForever_Items = { build = build, locale = locale, items = {} }
    end
    WoWToolsForever_Items.items = type(WoWToolsForever_Items.items) == "table" and WoWToolsForever_Items.items or {}
    return WoWToolsForever_Items
end

local function finishItemRun()
    local run = itemRun
    itemRun = nil
    run.ticker:Cancel()
    local missing = {}
    for id in pairs(run.todo) do missing[#missing + 1] = id end
    table.sort(missing)
    local store = itemStore()
    local count = 0
    for _ in pairs(store.items) do count = count + 1 end
    store.updated, store.missing, store.count, store.source = time(), missing, count, run.source
    store.lastRun = { new = run.done, total = run.total, missing = #missing, started = run.started }
    if run.requestID then
        WoWToolsForever_Account.lastRequest = { id = run.requestID, action = "items", done = time(), new = run.done }
    end
    if not run.quiet or run.done > 0 then
        say("itemsDone", run.done, count, #missing)
    end
end

local function itemTick()
    local run = itemRun
    if not run or inCombat() then return end
    local store = itemStore()
    local progressed, requested = false, 0
    for id in pairs(run.todo) do
        if not run.requested[id] then
            if requested < ITEM_BATCH then
                requested = requested + 1
                run.requested[id] = true
                try(C_Item.RequestLoadItemDataByID, id)
            end
        else
            local rec = itemInfoRecord(id)
            if rec then
                store.items[id], run.todo[id] = rec, nil
                run.done = run.done + 1
                progressed = true
                if run.done % 250 == 0 then
                    say("itemsProgress", run.done, run.total)
                end
            end
        end
    end
    run.idle = (progressed or requested > 0) and 0 or run.idle + 1
    if next(run.todo) == nil or run.idle >= ITEM_IDLE_TICKS then finishItemRun() end
end

-- opts.full re-reads items already in the export; opts.items replaces the Auctionator list.
local function startItemRun(opts)
    opts = opts or {}
    if itemRun then
        say("itemsRunning", itemRun.done, itemRun.total)
        return
    end
    local source, ids = "auctionator", opts.items
    if type(ids) == "table" then
        source = "app"
    else
        ids = auctionatorItems()
        if not ids then
            if not opts.quiet then
                say("noAuctionator")
            end
            return
        end
    end
    local store = itemStore()
    local run = { todo = {}, requested = {}, done = 0, total = 0, idle = 0, source = source,
                  started = time(), requestID = opts.requestID, quiet = opts.quiet }
    local function add(id)
        if type(id) == "number" and not run.todo[id] and (opts.full or not store.items[id]) and isEquippable(id) then
            run.todo[id] = true
            run.total = run.total + 1
        end
    end
    for _, id in ipairs(ids) do add(id) end
    for _, id in ipairs(EXTRA_ITEMS) do add(id) end
    itemRun = run
    if run.total == 0 then
        run.ticker = { Cancel = function() end }
        finishItemRun()
        return
    end
    run.ticker = C_Timer.NewTicker(ITEM_TICK, itemTick)
    say("itemsStart", run.total, source)
end

---------------------------------------------------------------------------------------------------
-- App requests: the desktop app writes AppRequest.lua into this folder; the client loads it on the
-- next /reload. A request runs once, its id is remembered in WoWToolsForever_Account.lastRequest.
---------------------------------------------------------------------------------------------------

local function runAppRequest()
    local req = WoWToolsForever_AppRequest
    if type(req) ~= "table" or type(req.id) ~= "number" then return end
    local last = WoWToolsForever_Account.lastRequest
    if type(last) == "table" and last.id == req.id then return end
    if req.action == "items" then
        say("requestItems")
        startItemRun({ full = req.full == true, items = type(req.items) == "table" and req.items or nil,
                       requestID = req.id })
    elseif req.action == "sync" then
        say("requestSync")
        snapshot()
        WoWToolsForever_Account.lastRequest = { id = req.id, action = "sync", done = time() }
        say("snapshotReady")
    else
        WoWToolsForever_Account.lastRequest = { id = req.id, action = tostring(req.action), done = time(), error = "unknown action" }
    end
end

---------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")

-- Registering an event the client lacks throws and would abort this file.
local function register(event)
    if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
    pcall(frame.RegisterEvent, frame, event)
end

local SNAPSHOT_EVENTS = {
    "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "QUEST_LOG_UPDATE",
    "UPDATE_FACTION", "SKILL_LINES_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_MONEY", "PLAYER_LEVEL_UP",
    "PLAYER_XP_UPDATE", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "PLAYER_GUILD_UPDATE",
    "UPDATE_SHAPESHIFT_FORM",
}
local SNAPSHOT_EVENT = {}
for _, event in ipairs(SNAPSHOT_EVENTS) do
    SNAPSHOT_EVENT[event] = true
    register(event)
end
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED", "AUCTION_HOUSE_CLOSED",
                         "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED",
                         "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "MERCHANT_SHOW", "MERCHANT_UPDATE",
                         "QUEST_TURNED_IN", "CURRENCY_DISPLAY_UPDATE" }) do
    register(event)
end

local function initSavedVariables()
    WoWToolsForever_Char = type(WoWToolsForever_Char) == "table" and WoWToolsForever_Char or {}
    WoWToolsForever_Char.errors = type(WoWToolsForever_Char.errors) == "table" and WoWToolsForever_Char.errors or {}
    WoWToolsForever_Account = type(WoWToolsForever_Account) == "table" and WoWToolsForever_Account or {}
    if WoWToolsForever_Account.autoItems == nil then WoWToolsForever_Account.autoItems = true end
    -- 1.0 kept the item export per character; move it into the shared export once.
    local old = WoWToolsForever_Char.itemInfo
    if type(old) == "table" and type(old.items) == "table" then
        local store = itemStore()
        for id, rec in pairs(old.items) do
            if store.items[id] == nil then store.items[id] = rec end
        end
        store.updated = store.updated or old.updated
    end
    WoWToolsForever_Char.itemInfo = nil
end

local enteredWorld = false

frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            initSavedVariables()
            frame:UnregisterEvent("ADDON_LOADED")
        end
    elseif not WoWToolsForever_Char then
        return
    -- No snapshot on PLAYER_LOGOUT: by then the client has torn down money, XP, stats, inventory
    -- and talents (they read as 0/empty), so it would overwrite the last good snapshot.
    elseif event == "PLAYER_REGEN_ENABLED" then
        if dirty then requestSnapshot() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- Auctionator has just stored the scan; read the items it found that are not in the export yet.
        if WoWToolsForever_Account.autoItems then
            C_Timer.After(1, function() startItemRun({ quiet = true }) end)
        end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        pcall(scanBank)
        requestSnapshot() -- rescans once the bank tabs have loaded
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" then
        if bankOpen then requestSnapshot() end
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        requestTradeSkillScan()
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        pcall(scanMerchant)
    elseif event == "QUEST_TURNED_IN" then
        pcall(trackQuest, arg1, arg3)
    elseif event == "CURRENCY_DISPLAY_UPDATE" then
        pcall(trackCurrency, arg1, arg3)
        requestSnapshot()
    elseif SNAPSHOT_EVENT[event] then
        if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_ENTERING_WORLD" then pcall(trackBags) end
        if event == "PLAYER_MONEY" or event == "PLAYER_ENTERING_WORLD" then pcall(trackMoney) end
        if event == "PLAYER_ENTERING_WORLD" and not enteredWorld then
            enteredWorld = true
            C_Timer.After(3, runAppRequest)
        end
        requestSnapshot()
    end
end)

---------------------------------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------------------------------

local function countItems()
    local n = 0
    for _ in pairs(itemStore().items) do n = n + 1 end
    return n
end

local function syncNow()
    snapshot()
    dirty = false
    if C_UI and C_UI.Reload then C_UI.Reload() else ReloadUI() end
end
ns.sync = syncNow
ns.version = ADDON_VERSION

SLASH_WOWTOOLSFOREVER1 = "/wtf"
SlashCmdList.WOWTOOLSFOREVER = function(msg)
    local cmd, raw = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local arg = raw:lower() -- the window's commands get the text as typed (item names)
    local db = WoWToolsForever_Char
    if cmd == "sync" then
        syncNow()
    elseif cmd == "items" then
        startItemRun({ full = arg == "full" })
    elseif cmd == "auto" then
        if arg == "on" or arg == "off" then WoWToolsForever_Account.autoItems = arg == "on" end
        say("autoState", WoWToolsForever_Account.autoItems and L.on or L.off)
    elseif cmd == "status" then
        local function at(t, fmt) return t and date(fmt or "%Y-%m-%d %H:%M", t) end
        print(L.statusSnapshot:format(ADDON_VERSION, at(db.updated, "%Y-%m-%d %H:%M:%S") or L.never))
        print(L.statusBank:format(db.bank and at(db.bank.updated) or L.bankNever))
        local store = itemStore()
        print(L.statusItems:format(countItems(), at(store.updated) or L.itemsNever,
            WoWToolsForever_Account.autoItems and L.on or L.off))
        for _, p in pairs(db.recipes or {}) do
            print(L.statusRecipes:format(tostring(p.name), p.learned or 0, at(p.updated) or "?"))
        end
        if not next(db.recipes or {}) then print(L.statusNoRecipes) end
        local p = payouts()
        for id, s in pairs(p.pouches) do
            print(L.statusPouch:format(id, s.n, ("%.2fs"):format(s.sum / s.n / 100)))
        end
        for id, s in pairs(p.crates) do
            print(L.statusCrate:format(id, s.n, ("%.1f"):format(s.sum / s.n)))
        end
        local last = WoWToolsForever_Account.lastRequest
        if type(last) == "table" then
            print(L.statusRequest:format(tostring(last.id), tostring(last.action), at(last.done, "%H:%M") or L.running))
        end
        if ns.listStatus then pcall(ns.listStatus) end
        for key, err in pairs(db.errors) do
            print(("  %s: %s"):format(key, err))
        end
    elseif ns.commands and ns.commands[cmd] then
        ns.commands[cmd](raw) -- the window and its switches, Lists.lua
    else
        for _, key in ipairs({ "helpSync", "helpItems", "helpAuto", "helpStatus", "helpShow", "helpPrice",
                               "helpLists", "helpTips", "helpAH", "helpMinimap", "helpRecipes", "helpPayouts" }) do
            say(key)
        end
    end
end
