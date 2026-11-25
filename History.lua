-- WoW Tools Forever price history: a tab of the lists window that searches the items in Auctionator's price database
-- and draws how their price developed. Auctionator keeps per item and scan day the lowest (l) and the
-- highest (h) minimum buyout it saw and the most offers (a), plus the last minimum price (m); days count
-- from Auctionator.Constants.SCAN_DAY_0. Everything is read in the game: no app, no /reload needed.

local _, ns = ...
local L = ns.L
local U = ns.util -- helpers of Lists.lua

local ROW_HEIGHT = 22
local MAX_RESULTS = 200
local INDEX_BATCH = 500             -- item names read per frame while the index is built
-- Names the client does not have are asked from the server a few at a time, as the item export does: a
-- flood of requests is not answered in full. An item that stays without a name is asked again a few times.
local NAME_BATCH = 40               -- name requests per tick
local NAME_TICK = 0.25              -- seconds
local NAME_RETRY = 10               -- seconds until an unanswered request is sent again
local NAME_TRIES = 3
local RECENT = 12                   -- items remembered as "recently viewed"
-- Two-column dark card layout: search input + result list with thin scrollbar on the left, item header
-- card, price chart card and statistics strip on the right.
local SEARCH_H, STATUS = 26, 20
local LIST_TOP = SEARCH_H + 6
local GAP, GAP_V = 10, 8
local HEADER, FOOT = 50, 44
local AXIS = 68                     -- room for the price labels inside the chart card
local PLOT_PAD_TOP, PLOT_PAD_BOTTOM, PLOT_PAD_RIGHT = 14, 24, 16
local DEFAULT_W, DEFAULT_H = 740, 392 -- the panel at the window's default size
-- These follow the size of the window (layout); the values are those of the default size.
local resultRows, listWidth = 15, 236
local plotW, plotH = 410, 244
local OFFER_SHARE = 0.22            -- the offer bars use at most this share of the plot height
local DAY = 86400

local panel
local results, offset, selected = {}, 0, nil
local index = { names = {}, lower = {}, ids = {}, lastDay = nil, built = false, building = false, stale = false,
                waiting = {}, tries = {}, asked = {}, loading = false, unnamed = 0 }
local refreshQueued = false
local layout -- defined with the panel

---------------------------------------------------------------------------------------------------
-- Data: Auctionator's database and the name index
---------------------------------------------------------------------------------------------------

local function database()
    local db = type(Auctionator) == "table" and type(Auctionator.Database) == "table" and Auctionator.Database.db
    local constants = type(Auctionator) == "table" and Auctionator.Constants
    local day0 = type(constants) == "table" and U.num(constants.SCAN_DAY_0)
    if type(db) == "table" and day0 then return db, day0 end
end

-- Community-synced history written by the desktop app (SyncHistory.lua). Only used when realm and faction match.
local syncCache = {}
local function syncStore()
    local s = WoWToolsForever_SyncHistory
    if type(s) ~= "table" or type(s.items) ~= "table" then return nil end
    local realm = U.str(U.try(GetRealmName))
    local faction = U.str(U.try(UnitFactionGroup, "player"))
    if realm and U.str(s.realm) and realm:lower() ~= s.realm:lower() then return nil end
    if faction and U.str(s.faction) and faction:lower() ~= s.faction:lower() then return nil end
    return s
end

local function hasData()
    return database() ~= nil or syncStore() ~= nil
end

local function parseSyncItem(id)
    local s = syncStore()
    local raw = s and s.items[id]
    if type(raw) ~= "string" then return nil end
    local cached = syncCache[id]
    if cached and cached.raw == raw then return cached end
    local bar = raw:find("|", 1, true)
    local last = bar and tonumber(raw:sub(1, bar - 1)) or nil
    local body = bar and raw:sub(bar + 1) or raw
    local days, maxDay = {}, nil
    for part in body:gmatch("[^;]+") do
        local d, lo, hi, av = part:match("^(%d+),(%d+),(%d*),(%d*)$")
        local day, low = tonumber(d), tonumber(lo)
        if day and low and low > 0 then
            local high = tonumber(hi)
            if not high or high < low then high = low end
            local offers = tonumber(av)
            days[day] = { day = day, low = low, high = high, offers = offers }
            if not maxDay or day > maxDay then maxDay = day end
        end
    end
    cached = { raw = raw, m = last, days = days, maxDay = maxDay }
    syncCache[id] = cached
    return cached
end

local function dayTime(day)
    local _, day0 = database()
    if not day0 then
        local s = syncStore()
        day0 = s and U.num(s.day0)
    end
    return (day0 or 0) + day * DAY + DAY / 2 -- noon, so a change of daylight saving time cannot move the date
end

local function dayText(day)
    return date(L.historyDay, dayTime(day))
end

-- Lua lowers only ASCII; the umlauts of the German client are lowered by hand.
local function lower(text)
    return (text:lower():gsub("\195\132", "\195\164"):gsub("\195\150", "\195\182"):gsub("\195\156", "\195\188"))
end

-- One item's history, oldest day first: {day, low, high, offers}. Merges local Auctionator data with SyncHistory.lua.
local function history(id)
    local byDay = {}
    local localLast, localMaxDay
    local db = database()
    local entry = db and db[tostring(id)]
    if type(entry) == "table" and type(entry.h) == "table" then
        local lows = type(entry.l) == "table" and entry.l or {}
        local offers = type(entry.a) == "table" and entry.a or {}
        for key, high in pairs(entry.h) do
            local day, top = tonumber(key), U.num(high)
            if day and top and top > 0 then
                local low = U.num(lows[key])
                byDay[day] = { day = day, low = (low and low > 0 and low <= top) and low or top, high = top,
                               offers = U.num(offers[key]) }
                if not localMaxDay or day > localMaxDay then localMaxDay = day end
            end
        end
        localLast = U.num(entry.m)
    end
    local synced = parseSyncItem(id)
    local syncLast, syncMaxDay
    if synced then
        syncLast, syncMaxDay = synced.m, synced.maxDay
        for day, sd in pairs(synced.days) do
            local cur = byDay[day]
            if cur then
                if sd.low < cur.low then cur.low = sd.low end
                if sd.high > cur.high then cur.high = sd.high end
                if sd.offers and (not cur.offers or sd.offers > cur.offers) then cur.offers = sd.offers end
            else
                byDay[day] = { day = sd.day, low = sd.low, high = sd.high, offers = sd.offers }
            end
        end
    end
    local out = {}
    for _, d in pairs(byDay) do out[#out + 1] = d end
    table.sort(out, function(a, b) return a.day < b.day end)
    local last = localLast
    if not last or (syncLast and syncMaxDay and (not localMaxDay or syncMaxDay > localMaxDay)) then
        last = syncLast or last
    end
    return out, last
end

local function setName(id, name)
    index.names[id], index.lower[id] = name, lower(name)
end

-- The item export of this addon (WoWToolsForever_Items) holds name and quality of the equipment seen in the auction
-- house. Many of these items are not in the client's files, so the client knows their names only after
-- asking the server; the export has them at once. Only an export in the client's language counts.
local function exported(id)
    local store = WoWToolsForever_Items
    if type(store) ~= "table" or type(store.items) ~= "table" or (store.locale and store.locale ~= GetLocale()) then
        return nil
    end
    local rec = store.items[id]
    return type(rec) == "table" and rec or nil
end

local function knownName(id)
    local rec = exported(id)
    return U.str(U.try(C_Item and C_Item.GetItemNameByID, id)) or (rec and U.str(rec.name))
end

local refreshSoon -- defined below, with the events

-- Asks the server for the names still missing, NAME_BATCH per tick, and looks for the answers itself
-- (GET_ITEM_INFO_RECEIVED does not come for every request). Stops when every item has a name or was asked
-- NAME_TRIES times; index.unnamed counts the items left without one, which a search by ID still finds.
local function loadNames()
    if index.loading then return end
    index.loading = true
    local request = C_Item and C_Item.RequestLoadItemDataByID
    local function tick()
        local now = U.num(U.try(GetTime)) or 0
        local waiting, requested, found, gaveUp = {}, 0, false, 0
        for _, id in ipairs(index.waiting) do
            local name = not index.names[id] and knownName(id)
            if name then
                setName(id, name)
                found = true
            elseif not index.names[id] then
                local tries, asked = index.tries[id] or 0, index.asked[id]
                local due = not asked or now - asked >= NAME_RETRY
                if due and tries >= NAME_TRIES then
                    gaveUp = gaveUp + 1
                else
                    if due and requested < NAME_BATCH then
                        requested = requested + 1
                        index.tries[id], index.asked[id] = tries + 1, now
                        U.try(request, id)
                    end
                    waiting[#waiting + 1] = id
                end
            end
        end
        index.waiting = waiting
        if #waiting == 0 then
            index.loading = false
            index.unnamed = 0
            for _, id in ipairs(index.ids) do
                if not index.names[id] then index.unnamed = index.unnamed + 1 end
            end
            refreshSoon()
            return
        end
        if found then refreshSoon() end
        C_Timer.After(NAME_TICK, tick)
    end
    tick()
end

-- Reads the names of all items in the database a few hundred per frame, from the client or the item
-- export. Names neither knows are asked from the server afterwards (loadNames).
local function buildIndex()
    local db = database()
    local sync = syncStore()
    if (not db and not sync) or index.building then return end
    index.building, index.stale = true, false
    local seen, ids, lastDay = {}, {}, nil
    if db then
        for key, entry in pairs(db) do
            local id = tonumber(key)
            if id and type(entry) == "table" and type(entry.h) == "table" then
                if not seen[id] then
                    seen[id] = true
                    ids[#ids + 1] = id
                end
                for day in pairs(entry.h) do
                    day = tonumber(day)
                    if day and (not lastDay or day > lastDay) then lastDay = day end
                end
            end
        end
    end
    if sync then
        local syncLast = U.num(sync.lastDay)
        if syncLast and (not lastDay or syncLast > lastDay) then lastDay = syncLast end
        for key, raw in pairs(sync.items) do
            local id = tonumber(key)
            if id and type(raw) == "string" and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    index.ids, index.lastDay = ids, lastDay
    local position, missing = 0, {}
    local function step()
        for _ = 1, INDEX_BATCH do
            position = position + 1
            local id = ids[position]
            if not id then
                index.built, index.building = true, false
                -- A load still running keeps its tries; it takes the new list on its next tick.
                index.waiting = missing
                if #missing > 0 then loadNames() else index.unnamed = 0 end
                if panel and panel:IsShown() then ns.history.search() end
                return
            end
            if not index.names[id] then
                local name = knownName(id)
                if name then setName(id, name) else missing[#missing + 1] = id end
            end
        end
        if panel and panel:IsShown() then panel.status:SetText(L.historyIndexing:format(position, #ids)) end
        C_Timer.After(0, step)
    end
    step()
end

local function ensureIndex()
    if (not index.built or index.stale) and not index.building then buildIndex() end
end

local function itemQuality(id)
    local quality = U.num(U.try(C_Item and C_Item.GetItemQualityByID, id))
    if not quality then quality = U.num(select(3, U.try(C_Item and C_Item.GetItemInfo, id))) end
    if not quality then
        local rec = exported(id)
        quality = rec and U.num(rec.quality)
    end
    return quality
end

-- What the search box asks for: an item ID, an item link, or words that must all be in the name.
local function find(text)
    text = strtrim(text or "")
    local id = tonumber(text:match("item:(%d+)") or text:match("^#?(%d+)$") or "")
    if id then
        local db, sync = database(), syncStore()
        local present = (db and db[tostring(id)]) or (sync and type(sync.items[id]) == "string")
        local found = present and { id } or {}
        return found, #found, true
    end
    local query = lower(text)
    if #query < 2 then return nil end
    local words = {}
    for word in query:gmatch("%S+") do words[#words + 1] = word end
    local hits = {}
    for _, item in ipairs(index.ids) do
        local name = index.lower[item]
        if name then
            local all = true
            for _, word in ipairs(words) do
                if not name:find(word, 1, true) then all = false break end
            end
            if all then
                hits[#hits + 1] = { id = item, rank = name == query and 0 or (name:sub(1, #query) == query and 1 or 2),
                                    name = name }
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(#hits, MAX_RESULTS) do out[i] = hits[i].id end
    return out, #hits
end

local function recentList()
    local ui = U.settings()
    if type(ui.historyRecent) ~= "table" then ui.historyRecent = {} end
    return ui.historyRecent
end

local function remember(id)
    local recent = recentList()
    for i = #recent, 1, -1 do
        if recent[i] == id or type(recent[i]) ~= "number" then table.remove(recent, i) end
    end
    table.insert(recent, 1, id)
    while #recent > RECENT do table.remove(recent) end
end

---------------------------------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------------------------------

-- Short money for the axis: 123g, 12g 34s, 34s 20c, 20c.
local function shortCoins(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local G, S, C = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
    if g >= 100 then return g .. G end
    if g > 0 then return s > 0 and (g .. G .. " " .. s .. S) or (g .. G) end
    if s > 0 then return c > 0 and (s .. S .. " " .. c .. C) or (s .. S) end
    return c .. C
end

local function nameOf(id)
    return knownName(id) or index.names[id] or ("#" .. id)
end

local function colored(id)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[itemQuality(id) or 1]
    return (color and color.hex or "|cffffffff") .. nameOf(id) .. "|r"
end

local function percent(from, to)
    if not (from and to and from > 0) then return "" end
    local change = (to - from) / from * 100
    if math.abs(change) < 0.5 then return "\194\1770%" end
    return ("%s%d%%"):format(change > 0 and "+" or "", math.floor(change + (change > 0 and 0.5 or -0.5)))
end

---------------------------------------------------------------------------------------------------
-- The plot
---------------------------------------------------------------------------------------------------

-- Widgets are made once and reused; pools hand them out per drawing.
local function pool(make)
    local p = { items = {}, used = 0 }
    function p:get()
        self.used = self.used + 1
        local w = self.items[self.used]
        if not w then
            w = make()
            if not w then -- e.g. no lines on this client
                self.used = self.used - 1
                return nil
            end
            self.items[self.used] = w
        end
        w:Show()
        return w
    end
    function p:reset()
        for i = 1, #self.items do self.items[i]:Hide() end
        self.used = 0
    end
    return p
end

local function hline(plot, y, r, g, b, a)
    local t = plot.textures:get()
    t:SetColorTexture(r, g, b, a)
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
    t:SetSize(plotW, 1)
    return t
end

local function box(plot, x, y, w, h, r, g, b, a)
    local t = plot.textures:get()
    t:SetColorTexture(r, g, b, a)
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, y)
    t:SetSize(math.max(1, w), math.max(1, h))
    return t
end

local function segment(plot, x1, y1, x2, y2)
    local line = plot.lines:get()
    if not line then return end
    line:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
    line:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
end

local function label(plot, text, point, x, y, justify)
    local f = plot.labels:get()
    f:ClearAllPoints()
    f:SetPoint(point, plot, "BOTTOMLEFT", x, y)
    f:SetJustifyH(justify or "CENTER")
    f:SetText(text)
    return f
end

-- Lower and upper end of the price axis, with some room around the prices.
local function priceRange(days)
    local lo, hi
    for _, d in ipairs(days) do
        lo = (not lo or d.low < lo) and d.low or lo
        hi = (not hi or d.high > hi) and d.high or hi
    end
    local pad = (hi - lo) * 0.12
    if pad == 0 then pad = math.max(1, hi * 0.1) end
    return math.max(0, lo - pad), hi + pad
end

local function draw(id)
    local plot = panel.plot
    plot.textures:reset()
    plot.lines:reset()
    plot.labels:reset()
    plot.marker:Hide()
    plot.hoverDot:Hide()
    plot.days = nil
    local days, last = history(id)
    if #days == 0 then
        plot.empty:SetText(L.historyNoPrices)
        plot.empty:Show()
        return days, last
    end
    plot.empty:Hide()

    local first = days[1].day
    local final = math.max(days[#days].day, index.lastDay or days[#days].day)
    local span = math.max(1, final - first)
    local slot = plotW / (span + 1)
    local function x(day) return (day - first + 0.5) * slot end
    local lo, hi = priceRange(days)
    local function y(price) return (price - lo) / (hi - lo) * plotH end

    -- Subtle warm grid: four price steps on the left and dated vertical guides.
    for i = 0, 3 do
        local price = lo + (hi - lo) * i / 3
        hline(plot, y(price), 0.95, 0.90, 0.80, i == 0 and 0.22 or 0.06)
        label(plot, shortCoins(price), "RIGHT", -8, y(price), "RIGHT")
    end
    local middle = math.floor((first + final) / 2)
    local dated = { first }
    if final > first then dated[#dated + 1] = final end
    if final - first >= 4 then dated[#dated + 1] = middle end
    for _, day in ipairs(dated) do box(plot, x(day), 0, 1, plotH, 0.95, 0.90, 0.80, 0.045) end

    -- Offers as crisp steel-blue bars with a bright top cap, daily min-max range as a soft gold band,
    -- and the lowest price as a gold line with 5x5 nodes.
    local most = 0
    for _, d in ipairs(days) do most = math.max(most, d.offers or 0) end
    local width = math.max(3, math.min(16, slot * 0.6))
    local previous
    for _, d in ipairs(days) do
        local cx = x(d.day)
        if most > 0 and d.offers and d.offers > 0 then
            local bh = math.max(2, d.offers / most * plotH * OFFER_SHARE)
            box(plot, cx - width / 2, 1, width, bh, 0.26, 0.50, 0.82, 0.30)
            box(plot, cx - width / 2, bh, width, 1, 0.44, 0.72, 1.00, 0.70)
        end
        if d.high > d.low then
            box(plot, cx - width / 4, y(d.low), width / 2, y(d.high) - y(d.low), 1, 0.82, 0, 0.22)
        end
        box(plot, cx - 2.5, y(d.low) - 2.5, 5, 5, 1, 0.84, 0.14, 1)
        if previous then segment(plot, x(previous.day), y(previous.low), cx, y(d.low)) end
        previous = d
    end

    -- Dates below: first, last and one in the middle if there is room.
    for _, day in ipairs(dated) do label(plot, dayText(day), "TOP", x(day), -6) end

    plot.days, plot.first, plot.slot, plot.y = days, first, slot, y
    return days, last
end

-- The day under the mouse: tooltip, gold vertical hairline and highlighted node.
local function hover(plot)
    if not plot.days then return end
    local left, scale = U.num(plot:GetLeft()), U.num(plot:GetEffectiveScale()) or 1
    local cx = U.num(select(1, U.try(GetCursorPosition)))
    if not (left and cx) then return end
    local slotIndex = math.floor((cx / scale - left) / plot.slot)
    local found
    for _, d in ipairs(plot.days) do
        if d.day - plot.first == slotIndex then found = d end
    end
    if found == plot.hovered then return end
    plot.hovered = found
    if not found then
        plot.marker:Hide()
        plot.hoverDot:Hide()
        GameTooltip:Hide()
        return
    end
    local px = (found.day - plot.first + 0.5) * plot.slot
    plot.marker:ClearAllPoints()
    plot.marker:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", px, 0)
    plot.marker:SetSize(1, plotH)
    plot.marker:Show()
    plot.hoverDot:ClearAllPoints()
    plot.hoverDot:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", px - 3.5, plot.y(found.low) - 3.5)
    plot.hoverDot:Show()
    GameTooltip:SetOwner(plot, "ANCHOR_RIGHT")
    GameTooltip:SetText(date(L.historyDate, dayTime(found.day)))
    GameTooltip:AddDoubleLine(L.historyLowest, U.coins(found.low), 1, 0.82, 0, 1, 1, 1)
    if found.high > found.low then
        GameTooltip:AddDoubleLine(L.historyHighest, U.coins(found.high), 1, 0.82, 0, 1, 1, 1)
    end
    if found.offers then
        GameTooltip:AddDoubleLine(L.historyOffers, tostring(found.offers), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------------------------------

local function markSelected(line)
    line.selected = line.id ~= nil and line.id == selected
    line.sel:SetShown(line.selected)
    line.selBar:SetShown(line.selected)
end

local function showItem(id)
    selected = id
    for _, line in ipairs(panel.rows) do markSelected(line) end
    if not id then
        panel.item:Hide()
        panel.searchBtn:Hide()
        panel.title:SetText("")
        panel.summary:SetText("")
        panel.change:SetText("")
        panel.plot.textures:reset()
        panel.plot.lines:reset()
        panel.plot.labels:reset()
        panel.plot.hoverDot:Hide()
        panel.plot.days = nil
        panel.plot.empty:SetText(hasData() and L.historyHint or L.noAuctionator)
        panel.plot.empty:Show()
        return
    end
    U.try(C_Item and C_Item.RequestLoadItemDataByID, id)
    remember(id)
    panel.item:Show()
    panel.searchBtn:Show()
    U.setIcon(panel.item.icon, U.num(U.try(C_Item and C_Item.GetItemIconByID, id)), itemQuality(id))
    panel.title:SetText(colored(id))
    local days, last = draw(id)
    if #days == 0 then
        panel.summary:SetText("")
        panel.change:SetText("")
        return
    end
    local newest = days[#days]
    local sum, lowest, highest = 0, nil, nil
    for _, d in ipairs(days) do
        sum = sum + d.low
        lowest = (not lowest or d.low < lowest) and d.low or lowest
        highest = (not highest or d.low > highest) and d.low or highest
    end
    panel.summary:SetText(L.historyLast:format(dayText(newest.day), U.coins(last or newest.low)))
    panel.change:SetText(L.historyStats:format(#days, shortCoins(lowest), shortCoins(highest),
        shortCoins(sum / #days), percent(days[1].low, newest.low)))
end

local function maxOffset()
    return math.max(0, #results - resultRows)
end

local function refreshResults()
    offset = math.max(0, math.min(offset, maxOffset()))
    for i = 1, #panel.rows do
        local line = panel.rows[i]
        local id = i <= resultRows and results[offset + i] or nil
        line.id = id
        if id then
            U.setIcon(line.icon, U.num(U.try(C_Item and C_Item.GetItemIconByID, id)), itemQuality(id))
            line.name:SetText(colored(id))
            line.stripe:SetShown((offset + i) % 2 == 0)
            markSelected(line)
            line:Show()
        else
            line:Hide()
        end
    end
    if panel.slider then
        panel.slider.quiet = true
        panel.slider:SetMinMaxValues(0, maxOffset())
        panel.slider:SetValue(offset)
        panel.slider.quiet = false
        panel.slider:SetShown(maxOffset() > 0)
        U.updateThumb(panel.slider, resultRows, #results)
    end
end

-- Items a search by name cannot find yet: names still on their way, or never sent by the server.
local function nameNote()
    if #index.waiting > 0 then return " \194\183 " .. L.historyLoading:format(#index.waiting) end
    if index.unnamed > 0 then return " \194\183 " .. L.historyUnnamed:format(index.unnamed) end
    return ""
end

local function syncSearchBox()
    if not (panel and panel.box) then return end
    local empty = (panel.box:GetText() or "") == ""
    if panel.placeholder then panel.placeholder:SetShown(empty) end
    if panel.clearBtn then panel.clearBtn:SetShown(not empty) end
end

-- Fills the result list from the search box; an empty box lists the recently viewed items.
local function search()
    if not panel then return end
    syncSearchBox()
    ensureIndex()
    local text = panel.box:GetText() or ""
    local found, total, byId = find(text)
    local note = byId and "" or nameNote()
    offset = 0
    if not hasData() then
        results = {}
        panel.status:SetText("")
    elseif found then
        results = found
        if index.building then
            panel.status:SetText(L.historyIndexing:format(0, #index.ids))
        elseif total > #found then
            panel.status:SetText(L.historyMore:format(total, #found) .. note)
        else
            panel.status:SetText(L.historyHits:format(total) .. note)
        end
        if #found == 1 and found[1] ~= selected then showItem(found[1]) end
    else
        results = {}
        for _, id in ipairs(recentList()) do results[#results + 1] = id end
        panel.status:SetText(#results > 0 and L.historyRecent or L.historyTyping)
    end
    refreshResults()
end

local function rowEnter(line)
    if not line.id then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetItemByID, GameTooltip, line.id) then GameTooltip:SetText(nameOf(line.id)) end
    local _, last = history(line.id)
    if last and last > 0 then GameTooltip:AddLine(L.historyLastPrice:format(U.coins(last)), 1, 1, 1) end
    GameTooltip:AddLine(L.historyRowHint, 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function rowClick(line)
    if not line.id then return end
    if IsModifiedClick and IsModifiedClick() then
        if HandleModifiedItemClick then HandleModifiedItemClick(U.itemLink({ id = line.id })) end
        return
    end
    showItem(line.id)
end

local function buildResultRow(index_)
    local line = CreateFrame("Button", nil, panel.list)
    line:SetSize(listWidth - 14, ROW_HEIGHT)
    line:SetPoint("TOPLEFT", panel.list, "TOPLEFT", 3, -3 - (index_ - 1) * ROW_HEIGHT)
    U.rowArt(line)
    line.icon = U.itemIcon(line, ROW_HEIGHT - 6)
    line.icon:SetPoint("LEFT", line, "LEFT", 6, 0)
    line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.name:SetPoint("LEFT", line.icon, "RIGHT", 7, 0)
    line.name:SetPoint("RIGHT", line, "RIGHT", -6, 0)
    line.name:SetJustifyH("LEFT")
    line.name:SetWordWrap(false)
    line:SetScript("OnEnter", rowEnter)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)
    line:SetScript("OnClick", rowClick)
    return line
end

-- Fits the panel to its size (width and height of the room the window gives it): a wider result list
-- up to a point, as many result rows as fit, and the plot takes the rest.
layout = function(width, height)
    if not panel then return end
    width, height = U.num(width) or DEFAULT_W, U.num(height) or DEFAULT_H
    listWidth = math.floor(math.max(220, math.min(340, 236 + (width - DEFAULT_W) / 4)))
    local right = listWidth + GAP -- the left edge of the right column
    local rightW = math.max(240, width - right)
    local listH = math.max(ROW_HEIGHT + 6, height - LIST_TOP - STATUS)
    local insetH = math.max(80 + PLOT_PAD_TOP + PLOT_PAD_BOTTOM, height - HEADER - GAP_V - FOOT - GAP_V)
    plotW = math.max(120, math.floor(rightW - AXIS - PLOT_PAD_RIGHT))
    plotH = math.max(80, math.floor(insetH - PLOT_PAD_TOP - PLOT_PAD_BOTTOM))
    resultRows = math.max(1, math.floor((listH - 6) / ROW_HEIGHT))

    panel.searchWrap:SetSize(listWidth, SEARCH_H)
    panel.list:SetSize(listWidth, listH)
    for i = #panel.rows + 1, resultRows do panel.rows[i] = buildResultRow(i) end
    for _, line in ipairs(panel.rows) do line:SetWidth(listWidth - 14) end
    panel.status:ClearAllPoints()
    panel.status:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -LIST_TOP - listH - 4)
    panel.status:SetWidth(listWidth)

    panel.headerCard:ClearAllPoints()
    panel.headerCard:SetPoint("TOPLEFT", panel, "TOPLEFT", right, 0)
    panel.headerCard:SetSize(rightW, HEADER)

    panel.frame:ClearAllPoints()
    panel.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", right, -(HEADER + GAP_V))
    panel.frame:SetSize(rightW, insetH)
    local plot = panel.plot
    plot:ClearAllPoints()
    plot:SetPoint("TOPLEFT", panel.frame, "TOPLEFT", AXIS, -PLOT_PAD_TOP)
    plot:SetSize(plotW, plotH)
    plot.empty:SetWidth(rightW - 40)

    panel.footCard:ClearAllPoints()
    panel.footCard:SetPoint("TOPLEFT", panel, "TOPLEFT", right, -(HEADER + GAP_V + insetH + GAP_V))
    panel.footCard:SetSize(rightW, FOOT)
    refreshResults()
    if selected and panel:IsShown() then draw(selected) end
end

local function buildSearchBox()
    local T = U.THEME
    local wrap = CreateFrame("Frame", nil, panel)
    wrap:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    wrap:SetSize(listWidth, SEARCH_H)
    wrap:EnableMouse(true)
    wrap.box = U.frameBox(wrap, T.input, T.border)

    local glass = wrap:CreateTexture(nil, "ARTWORK")
    glass:SetSize(12, 12)
    glass:SetPoint("LEFT", wrap, "LEFT", 8, 0)
    if U.hasAtlas(U.MAGNIFIER) then
        glass:SetAtlas(U.MAGNIFIER)
    else
        glass:SetTexture(U.QUESTION_MARK)
    end
    glass:SetVertexColor(T.muted[1], T.muted[2], T.muted[3], 0.9)

    local clear = CreateFrame("Button", nil, wrap)
    clear:SetSize(18, 18)
    clear:SetPoint("RIGHT", wrap, "RIGHT", -4, 0)
    local clearText = clear:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clearText:SetPoint("CENTER", clear, "CENTER", 0, 0)
    clearText:SetText("\195\151")
    clearText:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    clear:SetScript("OnEnter", function() clearText:SetTextColor(T.gold[1], T.gold[2], T.gold[3]) end)
    clear:SetScript("OnLeave", function() clearText:SetTextColor(T.muted[1], T.muted[2], T.muted[3]) end)
    clear:Hide()

    local box = CreateFrame("EditBox", nil, wrap)
    box:SetPoint("TOPLEFT", wrap, "TOPLEFT", 26, -2)
    box:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -22, 2)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextColor(T.text[1], T.text[2], T.text[3])
    box:SetAutoFocus(false)

    local placeholder = wrap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("LEFT", box, "LEFT", 0, 0)
    placeholder:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    placeholder:SetText(L.historySearch)
    placeholder:SetTextColor(T.dim[1], T.dim[2], T.dim[3])

    box:SetScript("OnEditFocusGained", function() wrap.box:setBorder(T.borderHi) end)
    box:SetScript("OnEditFocusLost", function() wrap.box:setBorder(T.border) end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self)
        if results[1] then showItem(results[1]) end
        self:ClearFocus()
    end)
    box:SetScript("OnTextChanged", function() search() end)
    wrap:SetScript("OnMouseDown", function() box:SetFocus() end)
    clear:SetScript("OnClick", function()
        box:SetText("")
        search()
    end)

    panel.searchWrap = wrap
    panel.placeholder = placeholder
    panel.clearBtn = clear
    panel.box = box
end

local function build(parent, content)
    local T = U.THEME
    panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", content.left, content.top)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", content.right, content.bottom)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - (tonumber(delta) or 0) * 3
        refreshResults()
    end)
    panel:Hide()

    buildSearchBox()

    -- Left column: dark result list card with a slim scrollbar.
    panel.list = CreateFrame("Frame", nil, panel)
    panel.list:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -LIST_TOP)
    panel.list.box = U.frameBox(panel.list, T.panel, T.borderSubtle)
    panel.rows = {}
    for i = 1, resultRows do panel.rows[i] = buildResultRow(i) end
    panel.slider = U.modernSlider(panel.list, 6, function(value)
        offset = math.floor((tonumber(value) or 0) + 0.5)
        refreshResults()
    end)
    panel.slider:SetPoint("TOPRIGHT", panel.list, "TOPRIGHT", -3, -3)
    panel.slider:SetPoint("BOTTOMRIGHT", panel.list, "BOTTOMRIGHT", -3, 3)

    panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.status:SetJustifyH("LEFT")
    panel.status:SetWordWrap(false)
    panel.status:SetTextColor(T.dim[1], T.dim[2], T.dim[3])

    -- Right column top: elevated item header card with icon, title, last seen and Search AH button.
    local headerCard = CreateFrame("Frame", nil, panel)
    headerCard.box = U.frameBox(headerCard, T.card, T.borderSubtle)
    panel.headerCard = headerCard

    local item = CreateFrame("Button", nil, headerCard)
    item:SetSize(34, 34)
    item:SetPoint("LEFT", headerCard, "LEFT", 9, 0)
    item.icon = U.itemIcon(item, 34)
    item.icon:SetPoint("TOPLEFT", item, "TOPLEFT")
    local itemHl = U.solid(item, "HIGHLIGHT", T.hover, 1)
    itemHl:SetAllPoints()
    item:SetScript("OnEnter", function(self)
        if not selected then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        pcall(GameTooltip.SetItemByID, GameTooltip, selected)
        GameTooltip:AddLine(L.historyIconHint, 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    item:SetScript("OnLeave", function() GameTooltip:Hide() end)
    item:SetScript("OnClick", function()
        if not selected then return end
        if IsModifiedClick and IsModifiedClick() then
            if HandleModifiedItemClick then HandleModifiedItemClick(U.itemLink({ id = selected })) end
        else
            U.searchRows({ { id = selected } })
        end
    end)
    item:Hide()
    panel.item = item

    local searchBtn = U.flatButton(headerCard, "ghost", { icon = U.MAGNIFIER, iconSize = 11, font = "GameFontHighlightSmall" })
    searchBtn:SetText(L.searchAH)
    searchBtn:SetSize(math.max(92, (U.textWidth(searchBtn, searchBtn.label) or 72) + 28), 22)
    searchBtn:SetPoint("RIGHT", headerCard, "RIGHT", -10, 0)
    searchBtn:SetScript("OnClick", function()
        if selected then U.searchRows({ { id = selected } }) end
    end)
    searchBtn:Hide()
    panel.searchBtn = searchBtn

    panel.title = headerCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", item, "TOPRIGHT", 10, -1)
    panel.title:SetPoint("RIGHT", searchBtn, "LEFT", -10, 0)
    panel.title:SetJustifyH("LEFT")
    panel.title:SetWordWrap(false)
    panel.summary = headerCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.summary:SetPoint("TOPLEFT", item, "TOPRIGHT", 10, -20)
    panel.summary:SetPoint("RIGHT", searchBtn, "LEFT", -10, 0)
    panel.summary:SetJustifyH("LEFT")
    panel.summary:SetWordWrap(false)
    panel.summary:SetTextColor(T.muted[1], T.muted[2], T.muted[3])

    -- Right column middle: chart card.
    panel.frame = CreateFrame("Frame", nil, panel)
    panel.frame.box = U.frameBox(panel.frame, T.panel, T.borderSubtle)
    local plot = CreateFrame("Frame", nil, panel.frame)
    plot:EnableMouse(true)
    plot.textures = pool(function()
        local t = plot:CreateTexture(nil, "ARTWORK")
        return t
    end)
    plot.lines = pool(function()
        local line = U.try(plot.CreateLine, plot, nil, "OVERLAY")
        if not line then return nil end
        line:SetThickness(2)
        line:SetColorTexture(1, 0.82, 0.12, 0.95)
        return line
    end)
    plot.labels = pool(function()
        local f = plot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
        return f
    end)
    plot.marker = plot:CreateTexture(nil, "OVERLAY")
    plot.marker:SetColorTexture(1, 0.85, 0.35, 0.55)
    plot.marker:Hide()
    plot.hoverDot = plot:CreateTexture(nil, "OVERLAY")
    plot.hoverDot:SetSize(7, 7)
    plot.hoverDot:SetColorTexture(1, 0.92, 0.45, 1)
    plot.hoverDot:Hide()
    plot.empty = plot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    plot.empty:SetPoint("CENTER", panel.frame, "CENTER", 0, 0)
    plot.empty:SetSpacing(4)
    plot.empty:SetTextColor(T.dim[1], T.dim[2], T.dim[3])
    plot:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", hover) end)
    plot:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        self.hovered = nil
        self.marker:Hide()
        self.hoverDot:Hide()
        GameTooltip:Hide()
    end)
    panel.plot = plot

    -- Right column bottom: statistics and legend card.
    local footCard = CreateFrame("Frame", nil, panel)
    footCard.box = U.frameBox(footCard, T.noteBar, T.borderSubtle)
    panel.footCard = footCard

    panel.change = footCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.change:SetPoint("TOPLEFT", footCard, "TOPLEFT", 10, -7)
    panel.change:SetPoint("TOPRIGHT", footCard, "TOPRIGHT", -10, -7)
    panel.change:SetJustifyH("LEFT")
    panel.change:SetWordWrap(false)
    panel.change:SetTextColor(T.text[1], T.text[2], T.text[3])
    panel.legend = footCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.legend:SetPoint("TOPLEFT", panel.change, "BOTTOMLEFT", 0, -4)
    panel.legend:SetPoint("RIGHT", footCard, "RIGHT", -10, 0)
    panel.legend:SetJustifyH("LEFT")
    panel.legend:SetWordWrap(false)
    panel.legend:SetText(L.historyLegend)
    panel.legend:SetTextColor(T.dim[1], T.dim[2], T.dim[3])

    layout(DEFAULT_W, DEFAULT_H)
    return panel
end

---------------------------------------------------------------------------------------------------
-- What Lists.lua and the slash command use
---------------------------------------------------------------------------------------------------

ns.history = {
    build = build,
    layout = function(width, height) layout(width, height) end,
    search = search,
    show = function()
        panel:Show()
        search()
        if selected then showItem(selected) else showItem(nil) end
    end,
    hide = function() if panel then panel:Hide() end end,
    -- Opens an item (by ID) or puts a text into the search box.
    open = function(what)
        if type(what) == "number" then
            -- An old search could pick another item by itself; the list shows the recently viewed.
            panel.box:SetText("")
            showItem(what)
            search()
        elseif type(what) == "string" and what ~= "" then
            panel.box:SetText(what)
            search()
        end
    end,
}

-- A shift-click on an item while the search box has the focus puts the item into it, as the profession
-- window's search does. The game inserts links into its own boxes only; this runs after it.
local function linkInserted(text)
    if not (panel and panel:IsShown() and panel.box:HasFocus() and U.str(text)) then return end
    local id = tonumber(text:match("item:(%d+)"))
    if not id then return end
    panel.box:SetText(nameOf(id))
    panel.box:ClearFocus()
    showItem(id)
    search()
end

-- Names arrive in bursts; search again once for a burst.
refreshSoon = function()
    if not (panel and panel:IsShown()) or refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.5, function()
        refreshQueued = false
        if panel:IsShown() then search() end
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "GET_ITEM_INFO_RECEIVED", "AUCTION_HOUSE_CLOSED" }) do
    if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event) then
        pcall(events.RegisterEvent, events, event)
    end
end
events:SetScript("OnEvent", function(_, event, id)
    if event == "PLAYER_LOGIN" then
        if hooksecurefunc then
            if type(ChatFrameUtil) == "table" and ChatFrameUtil.InsertLink then
                pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", linkInserted)
            elseif ChatEdit_InsertLink then
                pcall(hooksecurefunc, "ChatEdit_InsertLink", linkInserted)
            end
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        id = U.num(id)
        local db, sync = database(), syncStore()
        local knownInSource = (db and type(db[tostring(id)]) == "table") or (sync and type(sync.items[id]) == "string")
        if not (id and knownInSource and index.lower[id] == nil) then return end
        local name = U.str(U.try(C_Item and C_Item.GetItemNameByID, id))
        if not name then return end
        setName(id, name)
        refreshSoon()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- Auctionator has stored a scan: new items for the index, new days for the plot.
        index.stale = true
        if panel and panel:IsShown() then
            search()
            if selected then showItem(selected) end
        end
    end
end)
