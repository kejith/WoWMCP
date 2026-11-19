-- WoWMCP lists: shows what the desktop app computed (AH upgrades, writs, trade crates, recipes, consumables)
-- inside the game. Addons cannot read files, so the app writes the data as Lua into AppData.lua in this
-- folder and the client loads it on the next /reload. This file only displays it:
--
--   WoWMCP_AppData = { version, generated, hash, locale, scanDate, chars = { [<first name>] = {
--       lists  = { { key, title, note, sections = { { title, note, rows = { row, ... } } } } },
--       tips   = { [itemID] = { line, ... } },    lines added to the item's tooltip
--       vendor = { [itemID] = line },             printed when a merchant sells the item
--   } } }
--   row = { id, name, q (quality), n (count), info, price (copper), shop (on the shopping list), sub (indented) }
--
-- Money inside a text is written {m:<copper>} and becomes coins here. Rows marked `shop` also go into
-- Auctionator shopping lists called "WoWMCP: <list title>". Nothing here touches the export in WoWMCP.lua.
-- The window's last tab, the price history, lives in History.lua; this file switches to it.

local _, ns = ...
local L = ns.L

local CALLER = "WoWMCP"            -- caller ID for Auctionator's API
local LIST_PREFIX = "WoWMCP: "     -- Auctionator shopping lists this addon owns
local ROWS, ROW_HEIGHT = 16, 20
local WIDTH, PAD = 640, 12
local MAX_SEARCH = 60              -- items in one Auctionator search
local SYNC_DELAY = 5               -- seconds after entering the world, so Auctionator has loaded its lists
local VENDOR_QUIET = 300           -- seconds until a vendor hint for the same item is printed again
local QUESTION_MARK = 134400       -- icon for items the client does not know

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local function say(key, ...)
    print("|cffffd100WoWMCP:|r " .. L[key]:format(...))
end

local function unpackOk(ok, ...)
    if ok then return ... end
end

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

-- The account-wide SavedVariables; they exist once the addon has loaded.
local function settings()
    if type(WoWMCP_Account) ~= "table" then WoWMCP_Account = {} end
    local account = WoWMCP_Account
    if type(account.ui) ~= "table" then account.ui = {} end
    local ui = account.ui
    if ui.tips == nil then ui.tips = true end     -- lines in item tooltips
    if ui.lists == nil then ui.lists = true end   -- Auctionator shopping lists
    if ui.ah == nil then ui.ah = true end         -- open the window with the auction house
    return ui
end

-- The data of the character that is logged in, and the whole file.
local function charData()
    local data = WoWMCP_AppData
    if type(data) ~= "table" or type(data.chars) ~= "table" then return nil, nil end
    local name = str(UnitName("player"))
    local own = name and data.chars[name]
    if type(own) ~= "table" then return nil, data end
    return own, data
end

local function listsOf(own)
    local out = {}
    if own and type(own.lists) == "table" then
        for _, list in ipairs(own.lists) do
            if type(list) == "table" and type(list.sections) == "table" and str(list.title) then
                out[#out + 1] = list
            end
        end
    end
    return out
end

local function rowsOf(section)
    local out = {}
    if type(section) == "table" and type(section.rows) == "table" then
        for _, row in ipairs(section.rows) do
            if type(row) == "table" and num(row.id) then out[#out + 1] = row end
        end
    end
    return out
end

local function coins(copper)
    copper = tonumber(copper) or 0
    local sign = copper < 0 and "-" or ""
    copper = math.floor(math.abs(copper) + 0.5)
    if type(GetMoneyString) == "function" then return sign .. GetMoneyString(copper, true) end
    return ("%s%dg %ds %dc"):format(sign, math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- Text from the app with its money placeholders turned into coins.
local function expand(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("{m:(%-?%d+)}", coins))
end

local function gameName(row)
    return str(try(C_Item and C_Item.GetItemNameByID, row.id))
end

-- The name as the game spells it, for searching and links. The app doubles "|" in the names it sends, so
-- a name cannot start an escape code when it is displayed.
local function plainName(row)
    local sent = type(row.name) == "string" and row.name:gsub("||", "|") or nil
    return gameName(row) or str(sent)
end

-- The name for display: the game's, else the one the app sent (escaped), else the item ID.
local function shownName(row)
    return gameName(row) or str(row.name) or tostring(row.id)
end

local function qualityColor(row)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[num(row.q) or 1]
    if color then return color.r, color.g, color.b, color.hex end
    return 1, 1, 1, "|cffffffff"
end

local function itemLink(row)
    local _, link = try(C_Item and C_Item.GetItemInfo, row.id)
    if str(link) then return link end
    local _, _, _, hex = qualityColor(row)
    return ("%s|Hitem:%d::::::::::::|h[%s]|h|r"):format(hex or "|cffffffff", row.id, plainName(row) or tostring(row.id))
end

local function quantity(row)
    local n = num(row.n)
    if n and n > 1 then return math.ceil(n) end
end

---------------------------------------------------------------------------------------------------
-- Auction house: searching, and the shopping lists in Auctionator
---------------------------------------------------------------------------------------------------

local function ahOpen()
    return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown()) or false
end

local function auctionator()
    return type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1 or nil
end

-- Auctionator rejects terms with its own separators.
local function searchName(row)
    local name = plainName(row)
    if name and not name:find("[;^]") and not name:find('^".*"$') then return name end
end

local function searchTerms(rows)
    local terms, seen = {}, {}
    for _, row in ipairs(rows) do
        local name = searchName(row)
        if name and not seen[name] and #terms < MAX_SEARCH then
            seen[name] = true
            terms[#terms + 1] = { searchString = name, isExact = true, quantity = quantity(row) }
        end
    end
    return terms
end

-- Blizzard's own search bar takes one text.
local function blizzardSearch(name)
    local ah = AuctionHouseFrame
    if not (ah and ah.SetSearchText) then return false end
    local ok, shown = pcall(ah.SetSearchText, ah, name)
    if not (ok and shown) then return false end
    local bar = ah.SearchBar
    if bar and bar.StartSearch then pcall(bar.StartSearch, bar) end
    return true
end

-- Searches the items of these rows in the auction house: all at once in Auctionator's shopping tab,
-- a single one also without Auctionator.
local function searchRows(rows)
    if not ahOpen() then
        say("needAH")
        return false
    end
    local terms = searchTerms(rows)
    if #terms == 0 then return false end
    local api = auctionator()
    if api and api.MultiSearchAdvanced and AuctionatorTabs_Shopping then
        if pcall(api.MultiSearchAdvanced, CALLER, terms) then return true end
    end
    if #terms == 1 and blizzardSearch(terms[1].searchString) then return true end
    if #terms > 1 then say("needAuctionator") else say("searchFailed") end
    return false
end

local function listManager()
    local shopping = type(Auctionator) == "table" and Auctionator.Shopping
    local manager = type(shopping) == "table" and shopping.ListManager
    if type(manager) == "table" and manager.GetIndexForName and manager.Delete then return manager end
end

local function deleteShoppingList(name)
    local manager = listManager()
    if manager and try(manager.GetIndexForName, manager, name) then
        pcall(manager.Delete, manager, name)
    end
end

local function removeShoppingLists()
    local ui = settings()
    for name in pairs(type(ui.listNames) == "table" and ui.listNames or {}) do
        deleteShoppingList(name)
    end
    ui.listNames, ui.synced = nil, nil
end

-- Writes the rows marked `shop` into Auctionator shopping lists, one per list, once per data file and
-- character. Lists of an earlier file that no longer have anything to buy are removed.
local function syncShoppingLists()
    local ui = settings()
    local own, data = charData()
    local api = auctionator()
    if not (ui.lists and own and api and api.CreateShoppingList and api.ConvertToSearchString and listManager()) then
        return
    end
    if ahOpen() then return end -- creating a list there starts a search; AUCTION_HOUSE_CLOSED tries again
    local key = tostring(data.hash or data.generated) .. ":" .. tostring(UnitName("player"))
    if ui.synced == key then return end
    local made, count = {}, 0
    for _, list in ipairs(listsOf(own)) do
        local rows = {}
        for _, section in ipairs(list.sections) do
            for _, row in ipairs(rowsOf(section)) do
                if row.shop then rows[#rows + 1] = row end
            end
        end
        local strings = {}
        for _, term in ipairs(searchTerms(rows)) do
            term.categoryKey = ""
            local text = try(api.ConvertToSearchString, CALLER, term)
            if str(text) then strings[#strings + 1] = text end
        end
        local name = LIST_PREFIX .. list.title
        if #strings > 0 and pcall(api.CreateShoppingList, CALLER, name, strings) then
            made[name] = true
            count = count + 1
        end
    end
    for name in pairs(type(ui.listNames) == "table" and ui.listNames or {}) do
        if not made[name] then deleteShoppingList(name) end
    end
    ui.listNames, ui.synced = made, key
    if count > 0 then say("listsSynced", count) end
end

-- What History.lua (the price history tab) shares with this file.
ns.util = {
    try = try, num = num, str = str, coins = coins, settings = settings, itemLink = itemLink,
    searchRows = searchRows, QUESTION_MARK = QUESTION_MARK,
}

---------------------------------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------------------------------

local frame
local entries = {}      -- what the rows show: {header = section} or {row = row}
local offset = 0        -- index of the first visible entry, minus one
local current           -- the list on screen
local historyMode = false -- the price history tab is on screen instead of a list
local autoOpened = false
local HISTORY = "history" -- settings().tab of the price history tab

local function maxOffset()
    return math.max(0, #entries - ROWS)
end

local function refreshRows()
    if not frame then return end
    offset = math.max(0, math.min(offset, maxOffset()))
    for i = 1, ROWS do
        local line, entry = frame.rows[i], entries[offset + i]
        line.entry = entry
        if not entry then
            line:Hide()
        elseif entry.header then
            local section = entry.header
            line.icon:Hide()
            line.name:Hide()
            line.info:Hide()
            line.price:Hide()
            line.head:SetText(str(section.title) or "")
            line.note:SetText(expand(section.note))
            line.head:Show()
            line.note:Show()
            line.search:SetShown(#rowsOf(section) > 0)
            line:Show()
        else
            local row = entry.row
            local r, g, b = qualityColor(row)
            local count = quantity(row) or (num(row.n) and row.n ~= 1 and row.n) or nil
            line.head:Hide()
            line.note:Hide()
            line.search:Hide()
            line.icon:ClearAllPoints()
            line.icon:SetPoint("LEFT", row.sub and 20 or 4, 0)
            line.icon:SetTexture(num(try(C_Item and C_Item.GetItemIconByID, row.id)) or QUESTION_MARK)
            line.name:SetText((row.shop and "|cffffd100*|r " or "") .. shownName(row)
                .. (count and (" |cffffffffx" .. count .. "|r") or ""))
            line.name:SetTextColor(r, g, b)
            line.info:SetText(expand(row.info))
            line.price:SetText(num(row.price) and row.price > 0 and coins(row.price) or "")
            line.icon:Show()
            line.name:Show()
            line.info:Show()
            line.price:Show()
            line:Show()
        end
    end
    local slider = frame.slider
    slider.quiet = true
    slider:SetMinMaxValues(0, maxOffset())
    slider:SetValue(offset)
    slider.quiet = false
    slider:SetShown(maxOffset() > 0)
end

local function scrollTo(value)
    offset = math.floor((tonumber(value) or 0) + 0.5)
    refreshRows()
end

local function shopRows(list)
    local rows = {}
    for _, section in ipairs(list and list.sections or {}) do
        for _, row in ipairs(rowsOf(section)) do
            if row.shop then rows[#rows + 1] = row end
        end
    end
    return rows
end

local function showList(list)
    current, historyMode = list, false
    entries, offset = {}, 0
    if ns.history then ns.history.hide() end
    frame.historyTab:UnlockHighlight()
    frame.buy:Show()
    frame.empty:Show()
    if list then
        settings().tab = list.key
        for _, section in ipairs(list.sections) do
            if type(section) == "table" then
                entries[#entries + 1] = { header = section }
                for _, row in ipairs(rowsOf(section)) do
                    entries[#entries + 1] = { row = row }
                end
            end
        end
    end
    for _, tab in ipairs(frame.tabs) do
        if tab.list == list then tab:LockHighlight() else tab:UnlockHighlight() end
    end
    frame.note:SetText(list and expand(list.note) or "")
    frame.buy:SetEnabled(#shopRows(list) > 0)
    refreshRows()
end

-- The price history tab: the rows of the lists make room for the panel of History.lua.
local function showHistory()
    if not (ns.history and frame.history) then return end
    current, historyMode = nil, true
    settings().tab = HISTORY
    entries, offset = {}, 0
    refreshRows()
    for _, tab in ipairs(frame.tabs) do tab:UnlockHighlight() end
    frame.historyTab:LockHighlight()
    frame.note:SetText("")
    frame.buy:Hide()
    frame.empty:Hide()
    ns.history.show()
end

local function refreshWindow()
    if not frame then return end
    local ui = settings()
    local own, data = charData()
    local lists = listsOf(own)
    local previous = 0
    for i, tab in ipairs(frame.tabs) do
        local list = lists[i]
        tab.list = list
        if list then
            tab:SetText(list.title)
            tab:SetWidth(math.max(70, (num(tab:GetTextWidth()) or 80) + 22))
            tab:ClearAllPoints()
            if i == 1 then
                tab:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -46)
            else
                tab:SetPoint("LEFT", frame.tabs[previous], "RIGHT", 4, 0)
            end
            previous = i
        end
        tab:SetShown(list ~= nil)
    end
    local history = frame.historyTab
    history:ClearAllPoints()
    if previous > 0 then
        history:SetPoint("LEFT", frame.tabs[previous], "RIGHT", 4, 0)
    else
        history:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -46)
    end
    history:SetWidth(math.max(70, (num(history:GetTextWidth()) or 80) + 22))
    history:SetShown(frame.history ~= nil)
    local chosen = lists[1]
    for _, list in ipairs(lists) do
        if list.key == ui.tab then chosen = list end
    end
    if data and (data.scanDate or data.generated) then
        frame.sub:SetText(L.windowSub:format(str(data.scanDate) or "?",
            num(data.generated) and date("%Y-%m-%d %H:%M", data.generated) or "?"))
    else
        frame.sub:SetText("")
    end
    frame.empty:SetText(chosen and "" or L.noData:format(str(UnitName("player")) or "?"))
    frame.auto:SetChecked(ui.ah)
    if ui.tab == HISTORY and frame.history then showHistory() else showList(chosen) end
end

local function rowEnter(line)
    local entry = line.entry
    local row = entry and entry.row
    if not row then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetItemByID, GameTooltip, row.id) then
        GameTooltip:SetText(shownName(row))
    end
    if str(row.info) then GameTooltip:AddLine(expand(row.info), 1, 1, 1, true) end
    if row.shop then GameTooltip:AddLine(L.onShoppingList, 1, 0.82, 0, true) end
    GameTooltip:AddLine(L.rowHint, 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function rowClick(line, button)
    local entry = line.entry
    local row = entry and entry.row
    if not row then return end
    if button == "RightButton" then
        if frame.history then
            showHistory()
            ns.history.open(row.id)
        end
        return
    end
    if IsModifiedClick and IsModifiedClick() then
        -- Shift: link into the chat or into the auction house search, Ctrl: dressing room.
        if HandleModifiedItemClick then HandleModifiedItemClick(itemLink(row)) end
        return
    end
    searchRows({ row })
end

local function buildRow(parent, index)
    local line = CreateFrame("Button", nil, parent)
    line:SetHeight(ROW_HEIGHT)
    local y = -98 - (index - 1) * ROW_HEIGHT
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD - 18, y)
    line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    line.icon = line:CreateTexture(nil, "ARTWORK")
    line.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
    line.icon:SetPoint("LEFT", 4, 0)

    line.price = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.price:SetPoint("RIGHT", -4, 0)
    line.price:SetWidth(92)
    line.price:SetJustifyH("RIGHT")

    line.info = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.info:SetPoint("RIGHT", line.price, "LEFT", -8, 0)
    line.info:SetWidth(236)
    line.info:SetJustifyH("RIGHT")
    line.info:SetWordWrap(false)
    line.info:SetTextColor(0.75, 0.75, 0.75)

    line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    line.name:SetPoint("LEFT", line.icon, "RIGHT", 5, 0)
    line.name:SetPoint("RIGHT", line.info, "LEFT", -6, 0)
    line.name:SetJustifyH("LEFT")
    line.name:SetWordWrap(false)

    line.head = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.head:SetPoint("LEFT", 2, 0)
    line.note = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    line.note:SetPoint("LEFT", line.head, "RIGHT", 8, 0)

    line.search = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.search:SetSize(76, ROW_HEIGHT - 2)
    line.search:SetPoint("RIGHT", -2, 0)
    line.search:SetText(L.search)
    line.search:SetScript("OnClick", function()
        local entry = line.entry
        if entry and entry.header then searchRows(rowsOf(entry.header)) end
    end)

    line:SetScript("OnEnter", rowEnter)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)
    line:SetScript("OnClick", rowClick)
    return line
end

local function place()
    local point = settings().point
    frame:ClearAllPoints()
    if type(point) == "table" and str(point[1]) and str(point[2]) and num(point[3]) and num(point[4]) then
        frame:SetPoint(point[1], UIParent, point[2], point[3], point[4])
    elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function buildWindow()
    frame = CreateFrame("Frame", "WoWMCPListFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, 98 + ROWS * ROW_HEIGHT + 44)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:Hide()
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "WoWMCPListFrame") end -- Escape closes it

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", PAD, -10)
    frame.title:SetText(L.windowTitle)
    frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.sub:SetPoint("TOPLEFT", PAD, -29)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    frame.tabs = {}
    for i = 1, 6 do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(90, 22)
        tab:SetScript("OnClick", function(self) if self.list then showList(self.list) end end)
        tab:Hide()
        frame.tabs[i] = tab
    end
    frame.historyTab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.historyTab:SetSize(90, 22)
    frame.historyTab:SetText(L.historyTab)
    frame.historyTab:SetScript("OnClick", function() showHistory() end)
    frame.historyTab:Hide()
    if ns.history then frame.history = ns.history.build(frame, PAD) end

    frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.note:SetPoint("TOPLEFT", PAD, -76)
    frame.note:SetPoint("TOPRIGHT", -PAD, -76)
    frame.note:SetJustifyH("LEFT")
    frame.note:SetWordWrap(false)

    frame.rows = {}
    for i = 1, ROWS do frame.rows[i] = buildRow(frame, i) end

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.empty:SetPoint("CENTER", 0, 0)
    frame.empty:SetWidth(WIDTH - 80)

    local slider = CreateFrame("Slider", nil, frame)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(12)
    slider:SetPoint("TOPRIGHT", -PAD, -98)
    slider:SetPoint("BOTTOMRIGHT", -PAD, 44)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.08)
    local thumb = slider:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(1, 0.82, 0, 0.7)
    thumb:SetSize(12, 36)
    slider:SetThumbTexture(thumb)
    slider:SetMinMaxValues(0, 0)
    slider:SetValueStep(1)
    slider:SetValue(0)
    slider:SetScript("OnValueChanged", function(self, value)
        if not self.quiet then scrollTo(value) end
    end)
    frame.slider = slider

    frame.auto = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.auto:SetSize(24, 24)
    frame.auto:SetPoint("BOTTOMLEFT", PAD - 4, 10)
    local label = frame.auto.Text or frame.auto.text or frame.auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if label:GetNumPoints() == 0 then label:SetPoint("LEFT", frame.auto, "RIGHT", 2, 0) end
    label:SetText(L.autoOpen)
    frame.auto:SetScript("OnClick", function(self) settings().ah = self:GetChecked() and true or false end)

    frame.buy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.buy:SetSize(210, 22)
    frame.buy:SetPoint("BOTTOMRIGHT", -PAD, 12)
    frame.buy:SetText(L.searchList)
    frame.buy:SetScript("OnClick", function() searchRows(shopRows(current)) end)
    frame.buy:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.searchList)
        GameTooltip:AddLine(L.searchListHint, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame.buy:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relative, x, y = self:GetPoint()
        if point then settings().point = { point, relative or point, x or 0, y or 0 } end
    end)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if not historyMode then scrollTo(offset - (tonumber(delta) or 0) * 3) end
    end)
    frame:SetScript("OnHide", function() autoOpened = false end)
end

local function showWindow()
    if not frame then buildWindow() end
    place()
    refreshWindow()
    frame:Show()
end

local function toggleWindow()
    if frame and frame:IsShown() then frame:Hide() else showWindow() end
end

-- /wowmcp price [name, ID or link]: the window on the price history tab.
local function openHistory(what)
    if not ns.history then return end
    if not (frame and frame:IsShown()) then showWindow() end
    showHistory()
    ns.history.open(tonumber(what) or what)
end

---------------------------------------------------------------------------------------------------
-- Tooltips and merchants
---------------------------------------------------------------------------------------------------

local function addTipLines(tooltip, id)
    if not (id and settings().tips) then return end
    local own = charData()
    local lines = own and type(own.tips) == "table" and own.tips[id]
    if type(lines) ~= "table" then return end
    for _, text in ipairs(lines) do
        if type(text) == "string" then tooltip:AddLine(expand(text), 0.4, 0.78, 1, true) end
    end
end

local function hookTooltips()
    local function wanted(tooltip)
        return tooltip == GameTooltip or tooltip == ItemRefTooltip
    end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if wanted(tooltip) and type(data) == "table" then pcall(addTipLines, tooltip, num(data.id)) end
        end)
        return
    end
    -- Clients before the tooltip data API.
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tooltip and tooltip.HookScript then
            pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self)
                local _, link = try(self.GetItem, self)
                local id = str(link) and tonumber(link:match("item:(%d+)"))
                pcall(addTipLines, self, id)
            end)
        end
    end
end

-- At a merchant: a chat line for each item on sale the app has a note for (recipes worth learning).
local hinted = {}

local function merchantHints()
    local own = charData()
    local vendor = own and type(own.vendor) == "table" and own.vendor
    if not vendor then return end
    local now = GetTime()
    for index = 1, num(try(GetMerchantNumItems)) or 0 do
        local id = num(try(GetMerchantItemID, index))
        local text = id and vendor[id]
        if type(text) == "string" and (hinted[id] or -VENDOR_QUIET) + VENDOR_QUIET <= now then
            hinted[id] = now
            print("|cffffd100WoWMCP:|r " .. itemLink({ id = id }) .. " " .. expand(text))
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------

-- What the game has loaded, for the app: it reads this from the SavedVariables after the next /reload.
local function markLoaded()
    local data = WoWMCP_AppData
    if type(WoWMCP_Account) ~= "table" then return end
    if type(data) == "table" and type(data.chars) == "table" then
        WoWMCP_Account.appData = { generated = num(data.generated), hash = str(data.hash), loaded = time() }
    else
        WoWMCP_Account.appData = nil
    end
end

-- Asks the client for the items of the lists, so names, links and icons are there when the window opens.
local function preloadItems()
    local request = C_Item and C_Item.RequestLoadItemDataByID
    if type(request) ~= "function" then return end
    for _, list in ipairs(listsOf((charData()))) do
        for _, section in ipairs(list.sections) do
            for _, row in ipairs(rowsOf(section)) do pcall(request, row.id) end
        end
    end
end

local events = CreateFrame("Frame")
local started, refreshQueued = false, false

for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
                         "MERCHANT_SHOW", "GET_ITEM_INFO_RECEIVED" }) do
    if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event) then
        pcall(events.RegisterEvent, events, event)
    end
end

events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        pcall(markLoaded)
        pcall(hookTooltips)
        pcall(preloadItems)
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not started then
            started = true
            C_Timer.After(SYNC_DELAY, function() pcall(syncShoppingLists) end)
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        if settings().ah and #listsOf((charData())) > 0 and not (frame and frame:IsShown()) then
            showWindow()
            autoOpened = true
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if autoOpened and frame then frame:Hide() end
        pcall(syncShoppingLists)
    elseif event == "MERCHANT_SHOW" then
        pcall(merchantHints)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Names and links arrive late; redraw once for a burst of them.
        if frame and frame:IsShown() and not refreshQueued then
            refreshQueued = true
            C_Timer.After(0.3, function()
                refreshQueued = false
                if frame:IsShown() then refreshRows() end
            end)
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Slash commands (dispatched by WoWMCP.lua) and the status line
---------------------------------------------------------------------------------------------------

local function switch(key, stateText, arg, changed)
    local ui = settings()
    arg = type(arg) == "string" and arg:lower() or arg
    if arg == "on" or arg == "off" then
        ui[key] = arg == "on"
        if changed then changed(ui[key]) end
    end
    say(stateText, ui[key] and L.on or L.off)
end

ns.commands = {
    show = toggleWindow,
    price = openHistory,
    tips = function(arg) switch("tips", "tipsState", arg) end,
    ah = function(arg) switch("ah", "ahState", arg) end,
    lists = function(arg)
        switch("lists", "listsState", arg, function(on)
            if on then
                settings().synced = nil
                syncShoppingLists()
            else
                removeShoppingLists()
            end
        end)
    end,
}

function ns.listStatus()
    local own, data = charData()
    local lists = listsOf(own)
    if #lists == 0 then
        print(L.statusNoLists)
    else
        print(L.statusLists:format(#lists, num(data.generated) and date("%Y-%m-%d %H:%M", data.generated) or "?"))
    end
end
