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
-- Modern dark stone panel matching the desktop app: slim title bar, flat underline tabs along the top,
-- a context bar for the open tab's note, an inset body with crisp rows and a thin scrollbar, and a
-- quiet footer with the auto-open toggle and the primary shopping action.
local TITLE_H, TABS_H, NOTE_H = 36, 30, 26
local TOP, BOTTOM = TITLE_H + TABS_H + NOTE_H, 38
local PAD, ROW_PAD = 10, 4
local BODY_TOP, BODY_BOTTOM = TOP + 6, BOTTOM + 6
local ROW_HEIGHT, ICON_SIZE, SUB_ICON_SIZE, INDENT = 24, 18, 16, 26
local PRICE_WIDTH, INFO_WIDTH, COUNT_WIDTH = 104, 250, 38
local WIDTH = 760
local HEIGHT = BODY_TOP + ROW_PAD * 2 + 16 * ROW_HEIGHT + BODY_BOTTOM -- default size: 16 rows
local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 640, 420, 1600, 1200
-- The price history panel fills the exact same body area as the list container.
local CONTENT = { left = PAD, top = -BODY_TOP, right = -PAD, bottom = BODY_BOTTOM }
local MAX_TABS = 6                 -- list tabs; the price history tab comes after them
local TAB_MIN, TAB_MAX, TAB_GAP = 64, 168, 2
local LOGO = "Interface\\Icons\\INV_Misc_Coin_02"
local MAGNIFIER = "common-search-magnifyingglass"
local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"
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

---------------------------------------------------------------------------------------------------
-- Look: modern dark stone theme matching the desktop app, shared with History.lua
---------------------------------------------------------------------------------------------------

local THEME = {
    bg            = { 0.055, 0.043, 0.031, 0.97 }, -- main window canvas (#0e0b08)
    bar           = { 0.086, 0.071, 0.051, 1.00 }, -- title bar and footer (#16120d)
    tabs          = { 0.067, 0.055, 0.039, 1.00 }, -- tab strip (#110e0a)
    noteBar       = { 0.078, 0.063, 0.047, 1.00 }, -- context note strip (#14100c)
    panel         = { 0.043, 0.035, 0.027, 0.98 }, -- inset list / chart surface (#0b0907)
    card          = { 0.098, 0.078, 0.057, 1.00 }, -- section header / item header (#19140f)
    input         = { 0.067, 0.055, 0.039, 1.00 }, -- search box (#110e0a)
    border        = { 0.360, 0.275, 0.157, 1.00 }, -- outer bronze frame (#5c4628)
    borderHi      = { 0.604, 0.471, 0.251, 1.00 }, -- warm gold hover edge (#9a7840)
    borderSubtle  = { 0.175, 0.141, 0.106, 1.00 }, -- inner panel border (#2d241b)
    outerShadow   = { 0.000, 0.000, 0.000, 0.95 }, -- crisp 1px outer black edge
    line          = { 0.184, 0.153, 0.118, 0.95 }, -- subtle horizontal divider (#2f271e)
    lineHi        = { 0.280, 0.225, 0.165, 0.95 }, -- tree branch & tab separator (#47392a)
    gold          = { 1.000, 0.820, 0.000, 1.00 }, -- accent gold (#ffd100)
    goldSoft      = { 0.830, 0.650, 0.230, 0.95 }, -- section accent bar (#d4a63b)
    text          = { 0.945, 0.918, 0.867, 1.00 }, -- primary light text (#f1eadd)
    muted         = { 0.659, 0.600, 0.541, 1.00 }, -- secondary warm grey (#a8998a)
    dim           = { 0.459, 0.412, 0.361, 1.00 }, -- tertiary hint text (#75695c)
    count         = { 0.788, 0.702, 0.549, 1.00 }, -- warm sand count (#c9b38c)
    stripe        = { 1.000, 0.960, 0.880, 0.030 }, -- alternating row stripe
    hover         = { 1.000, 0.850, 0.450, 0.090 }, -- row hover wash
    select        = { 1.000, 0.820, 0.000, 0.140 }, -- selected result row
    tabActive     = { 0.118, 0.094, 0.067, 1.00 }, -- active tab fill (#1e1811)
    tabHover      = { 0.098, 0.078, 0.055, 1.00 }, -- hovered tab fill
    primary       = { 0.431, 0.098, 0.082, 1.00 }, -- crimson action button (#6e1915)
    primaryHover  = { 0.549, 0.133, 0.106, 1.00 }, -- crimson hover (#8c221b)
    primaryBorder = { 0.604, 0.471, 0.251, 1.00 }, -- bronze-gold edge
    ghost         = { 0.125, 0.102, 0.075, 1.00 }, -- subtle dark button (#201a13)
    ghostHover    = { 0.180, 0.145, 0.102, 1.00 }, -- subtle dark button hover (#2e251a)
    ghostBorder   = { 0.290, 0.224, 0.133, 1.00 }, -- dark button edge (#4a3922)
    disabledBg    = { 0.102, 0.086, 0.071, 0.90 }, -- disabled button fill
    disabledEdge  = { 0.184, 0.153, 0.118, 0.90 }, -- disabled button edge
    disabledText  = { 0.420, 0.376, 0.333, 1.00 }, -- disabled button text
    closeHover    = { 0.560, 0.140, 0.120, 1.00 }, -- close button crimson hover
    track         = { 0.027, 0.022, 0.016, 0.95 }, -- scrollbar track
    thumb         = { 0.360, 0.275, 0.157, 0.85 }, -- scrollbar thumb
    thumbHover    = { 0.604, 0.471, 0.251, 0.95 }, -- scrollbar thumb hover
    iconFrame     = { 0.200, 0.160, 0.118, 1.00 }, -- default 1px icon frame
}

local function textWidth(widget, fs)
    local w = fs and num(try(fs.GetUnboundedStringWidth, fs))
    if w and w > 0 then return w end
    w = fs and num(try(fs.GetStringWidth, fs))
    if w and w > 0 then return w end
    return num(try(widget.GetTextWidth, widget))
end
local function hasAtlas(name)
    return C_Texture ~= nil and type(C_Texture.GetAtlasInfo) == "function" and try(C_Texture.GetAtlasInfo, name) ~= nil
end

local function colorTex(tex, c)
    tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return tex
end

local function solid(parent, layer, c, sublevel)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
    return colorTex(tex, c)
end

-- Crisp 1px pixel-aligned border made of four edge textures, plus optional fill.
local function frameBox(parent, bg, border, inset)
    local box = {}
    inset = inset or 0
    if bg then
        box.bg = solid(parent, "BACKGROUND", bg, -6)
        box.bg:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
        box.bg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
    end
    local edges = {}
    if border then
        local top = solid(parent, "BORDER", border, 2)
        top:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
        top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, -inset)
        top:SetHeight(1)
        local bottom = solid(parent, "BORDER", border, 2)
        bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, inset)
        bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
        bottom:SetHeight(1)
        local left = solid(parent, "BORDER", border, 2)
        left:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset - 1)
        left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, inset + 1)
        left:SetWidth(1)
        local right = solid(parent, "BORDER", border, 2)
        right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, -inset - 1)
        right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset + 1)
        right:SetWidth(1)
        edges = { top, bottom, left, right }
    end
    box.edges = edges
    function box:setBorder(c)
        for _, edge in ipairs(self.edges) do colorTex(edge, c) end
    end
    function box:setBg(c)
        if self.bg then colorTex(self.bg, c) end
    end
    return box
end

local function divider(parent, pointA, xA, yA, pointB, xB, yB, c)
    local line = solid(parent, "BORDER", c or THEME.line, 1)
    line:SetPoint(pointA, parent, pointA, xA, yA)
    line:SetPoint(pointB, parent, pointB, xB, yB)
    line:SetHeight(1)
    return line
end

-- Modern flat button (kind = "primary" | "ghost") with clean hover and disabled states.
local function flatButton(parent, kind, opts)
    opts = opts or {}
    local isPrimary = kind == "primary"
    local bg = isPrimary and THEME.primary or THEME.ghost
    local bgHover = isPrimary and THEME.primaryHover or THEME.ghostHover
    local edge = isPrimary and THEME.primaryBorder or THEME.ghostBorder
    local edgeHover = THEME.borderHi
    local textCol = isPrimary and THEME.gold or THEME.text
    local textHover = THEME.gold

    local btn = CreateFrame("Button", nil, parent)
    btn.box = frameBox(btn, bg, edge)
    local font = opts.font or (isPrimary and "GameFontNormal" or "GameFontHighlightSmall")
    local label = btn:CreateFontString(nil, "OVERLAY", font)
    label:SetWordWrap(false)
    btn.label = label
    try(btn.SetFontString, btn, label)

    if opts.icon then
        local size = opts.iconSize or 11
        local ic = btn:CreateTexture(nil, "ARTWORK")
        ic:SetSize(size, size)
        ic:SetPoint("LEFT", btn, "LEFT", 7, 0)
        if hasAtlas(opts.icon) then
            ic:SetAtlas(opts.icon)
        else
            ic:SetTexture(opts.icon)
        end
        ic:SetVertexColor(0.88, 0.78, 0.56, 0.95)
        btn.icon = ic
        label:SetPoint("LEFT", ic, "RIGHT", 4, 0)
        label:SetPoint("RIGHT", btn, "RIGHT", -7, 0)
        label:SetJustifyH("CENTER")
    else
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    end

    local function paint()
        if not btn:IsEnabled() then
            btn.box:setBg(THEME.disabledBg)
            btn.box:setBorder(THEME.disabledEdge)
            label:SetTextColor(THEME.disabledText[1], THEME.disabledText[2], THEME.disabledText[3])
            if btn.icon then btn.icon:SetVertexColor(0.45, 0.40, 0.35, 0.6) end
        elseif btn.hovered then
            btn.box:setBg(bgHover)
            btn.box:setBorder(edgeHover)
            label:SetTextColor(textHover[1], textHover[2], textHover[3])
            if btn.icon then btn.icon:SetVertexColor(1, 0.85, 0.2, 1) end
        else
            btn.box:setBg(bg)
            btn.box:setBorder(edge)
            label:SetTextColor(textCol[1], textCol[2], textCol[3])
            if btn.icon then btn.icon:SetVertexColor(0.88, 0.78, 0.56, 0.95) end
        end
    end

    local baseSetEnabled = btn.SetEnabled
    function btn:SetEnabled(on)
        if baseSetEnabled then baseSetEnabled(self, on) end
        paint()
    end
    btn:SetScript("OnEnter", function(self)
        self.hovered = true
        paint()
        if self.onEnterExtra then self.onEnterExtra(self) end
    end)
    btn:SetScript("OnLeave", function(self)
        self.hovered = false
        paint()
        if self.onLeaveExtra then self.onLeaveExtra(self) end
    end)
    paint()
    return btn
end

-- Subtle row visuals: warm alternating stripe, hover wash, and gold selection bar + tint.
local function rowArt(line)
    line.stripe = solid(line, "BACKGROUND", THEME.stripe, -4)
    line.stripe:SetAllPoints()
    line.stripe:Hide()
    line.sel = solid(line, "BORDER", THEME.select, -2)
    line.sel:SetAllPoints()
    line.sel:Hide()
    line.selBar = solid(line, "OVERLAY", THEME.gold, 2)
    line.selBar:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -1)
    line.selBar:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 1)
    line.selBar:SetWidth(2)
    line.selBar:Hide()
    line.hl = solid(line, "HIGHLIGHT", THEME.hover, 0)
    line.hl:SetAllPoints()
end

-- Clean cropped item icon with a sharp 1px frame: subtle dark bronze by default, quality color from
-- uncommon upward.
local function itemIcon(parent, size)
    local icon = parent:CreateTexture(nil, "ARTWORK", nil, 0)
    icon:SetSize(size, size)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local base = solid(parent, "BORDER", THEME.iconFrame, 0)
    base:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    base:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    local border = parent:CreateTexture(nil, "BORDER", nil, 1)
    border:SetColorTexture(1, 1, 1, 1)
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    border:Hide()
    icon.frame = base
    icon.border = border
    return icon
end

local function setIcon(icon, texture, quality)
    icon:SetTexture(texture or QUESTION_MARK)
    icon:Show()
    icon.frame:Show()
    local color = quality and quality >= 2 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then
        icon.border:SetVertexColor(color.r, color.g, color.b)
        icon.border:Show()
    else
        icon.border:Hide()
    end
end

local function hideIcon(icon)
    icon:Hide()
    icon.frame:Hide()
    icon.border:Hide()
end

-- Slim modern scrollbar without classic arrow buttons.
local function modernSlider(parent, width, onValueChanged)
    width = width or 8
    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(width)
    slider:EnableMouse(true)
    slider.box = frameBox(slider, THEME.track, THEME.borderSubtle)
    local thumb = solid(slider, "ARTWORK", THEME.thumb, 1)
    thumb:SetSize(math.max(4, width - 2), 36)
    slider:SetThumbTexture(thumb)
    slider.thumb = thumb
    slider:SetMinMaxValues(0, 0)
    slider:SetValueStep(1)
    try(slider.SetObeyStepOnDrag, slider, true)
    slider:SetValue(0)
    slider:SetScript("OnEnter", function() colorTex(thumb, THEME.thumbHover) end)
    slider:SetScript("OnLeave", function() colorTex(thumb, THEME.thumb) end)
    slider:SetScript("OnValueChanged", function(self, value)
        if not self.quiet and onValueChanged then onValueChanged(value) end
    end)
    return slider
end

local function updateThumb(slider, visibleCount, totalCount)
    if not (slider and slider.thumb) then return end
    local h = num(try(slider.GetHeight, slider)) or 200
    if totalCount <= 0 or visibleCount >= totalCount then return end
    local thumbH = math.floor(math.max(24, math.min(h - 6, h * visibleCount / totalCount)))
    slider.thumb:SetHeight(thumbH)
end

local function playTabSound()
    if type(PlaySound) == "function" and type(SOUNDKIT) == "table" and SOUNDKIT.IG_CHARACTER_INFO_TAB then
        pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
    end
end

-- What History.lua (the price history tab) shares with this file.
ns.util = {
    try = try, num = num, str = str, coins = coins, settings = settings, itemLink = itemLink,
    searchRows = searchRows, QUESTION_MARK = QUESTION_MARK, MAGNIFIER = MAGNIFIER,
    THEME = THEME, hasAtlas = hasAtlas, solid = solid, colorTex = colorTex, frameBox = frameBox,
    flatButton = flatButton, textWidth = textWidth, rowArt = rowArt, itemIcon = itemIcon, setIcon = setIcon,
    modernSlider = modernSlider, updateThumb = updateThumb,
}

---------------------------------------------------------------------------------------------------
-- Window: modern dark stone panel with top underline tabs, inset rows and the price history
---------------------------------------------------------------------------------------------------

local frame
local entries = {}      -- what the rows show: {header = section} or {row = row}
local offset = 0        -- index of the first visible entry, minus one
local current           -- the list on screen
local historyMode = false -- the price history tab is on screen instead of a list
local autoOpened = false
local HISTORY = "history" -- settings().tab of the price history tab
local visibleRows = 16  -- rows that fit the window's height

local function maxOffset()
    return math.max(0, #entries - visibleRows)
end

local function size()
    local w, h = num(try(frame.GetWidth, frame)), num(try(frame.GetHeight, frame))
    return w or WIDTH, h or HEIGHT
end

local function refreshRows()
    if not frame then return end
    offset = math.max(0, math.min(offset, maxOffset()))
    for i = 1, #frame.rows do
        local line = frame.rows[i]
        local entry = i <= visibleRows and entries[offset + i] or nil
        line.entry = entry
        if not entry then
            line:Hide()
        elseif entry.header then
            local section = entry.header
            hideIcon(line.icon)
            line.name:Hide()
            line.count:Hide()
            line.info:Hide()
            line.price:Hide()
            line.stripe:Hide()
            line.hl:Hide()
            line.shopBar:Hide()
            line.branchV:Hide()
            line.branchH:Hide()
            line.headBg:Show()
            line.accent:Show()
            line.rule:Show()
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
            line.headBg:Hide()
            line.accent:Hide()
            line.rule:Hide()
            line.head:Hide()
            line.note:Hide()
            line.search:Hide()
            line.stripe:SetShown(entry.stripe)
            line.hl:Show()
            line.shopBar:SetShown(row.shop and true or false)
            line.branchV:SetShown(row.sub and true or false)
            line.branchH:SetShown(row.sub and true or false)
            local iconSize = row.sub and SUB_ICON_SIZE or ICON_SIZE
            line.icon:SetSize(iconSize, iconSize)
            line.icon:ClearAllPoints()
            line.icon:SetPoint("LEFT", line, "LEFT", row.sub and INDENT or 8, 0)
            setIcon(line.icon, num(try(C_Item and C_Item.GetItemIconByID, row.id)), num(row.q))
            line.name:SetText((row.shop and "|cffffd100*|r " or "") .. shownName(row))
            line.name:SetTextColor(r, g, b)
            line.count:SetText(count and ("x" .. count) or "")
            line.info:SetText(expand(row.info))
            line.price:SetText(num(row.price) and row.price > 0 and coins(row.price) or "")
            line.name:Show()
            line.count:Show()
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
    updateThumb(slider, visibleRows, #entries)
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

local function paintTab(tab)
    if tab.selected then
        colorTex(tab.bg, THEME.tabActive)
        tab.bg:Show()
        tab.bar:Show()
        tab.label:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
    elseif tab.hovered then
        colorTex(tab.bg, THEME.tabHover)
        tab.bg:Show()
        tab.bar:Hide()
        tab.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    else
        tab.bg:Hide()
        tab.bar:Hide()
        tab.label:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])
    end
end

local function markTab(tab, on)
    tab.selected = on and true or false
    paintTab(tab)
end

local function markTabs(chosen)
    for _, tab in ipairs(frame.tabs) do markTab(tab, tab.list ~= nil and tab == chosen) end
    markTab(frame.historyTab, frame.historyTab == chosen)
end

local function showList(list)
    current, historyMode = list, false
    entries, offset = {}, 0
    if ns.history then ns.history.hide() end
    frame.body:Show()
    frame.buy:Show()
    frame.empty:Show()
    local chosen
    if list then
        settings().tab = list.key
        for _, section in ipairs(list.sections) do
            if type(section) == "table" then
                entries[#entries + 1] = { header = section }
                for n, row in ipairs(rowsOf(section)) do
                    entries[#entries + 1] = { row = row, stripe = n % 2 == 0 } -- every other row of a section
                end
            end
        end
        for _, tab in ipairs(frame.tabs) do
            if tab.list == list then chosen = tab end
        end
    end
    markTabs(chosen)
    local noteText = list and expand(list.note) or ""
    frame.note:SetText(noteText)
    frame.hint:SetText((list and noteText == "") and L.rowHint or "")
    frame.buy:SetEnabled(#shopRows(list) > 0)
    refreshRows()
end

-- The price history tab: the list container hides and makes room for the panel of History.lua.
local function showHistory()
    if not (ns.history and frame.history) then return end
    current, historyMode = nil, true
    settings().tab = HISTORY
    entries, offset = {}, 0
    refreshRows()
    markTabs(frame.historyTab)
    frame.body:Hide()
    frame.note:SetText(L.historyNote)
    frame.hint:SetText("")
    frame.buy:Hide()
    frame.empty:Hide()
    ns.history.show()
end

-- Flat underline tabs along the top strip, sized to their label and bounded so they always fit one row.
local function layoutTabs()
    local listTabs = {}
    for _, tab in ipairs(frame.tabs) do
        if tab.list then listTabs[#listTabs + 1] = tab end
    end
    local shown = {}
    for _, tab in ipairs(listTabs) do shown[#shown + 1] = tab end
    local hasSep = #listTabs > 0 and frame.history ~= nil
    if frame.history then shown[#shown + 1] = frame.historyTab end

    local w = size()
    local sepRoom = hasSep and 13 or 0
    local avail = math.max(TAB_MIN, w - 20 - sepRoom - TAB_GAP * math.max(0, #shown - 1))
    local most = math.floor(math.max(TAB_MIN, math.min(TAB_MAX, avail / math.max(1, #shown))))
    frame.maxTabWidth = most

    local x = 10
    for i, tab in ipairs(shown) do
        if hasSep and tab == frame.historyTab then
            frame.tabSep:ClearAllPoints()
            frame.tabSep:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 5, -(TITLE_H + 7))
            frame.tabSep:Show()
            x = x + 13
        end
        local tw = math.floor(math.min(most, math.max(TAB_MIN, (textWidth(tab, tab.label) or 60) + 24)))
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -TITLE_H)
        tab:SetSize(tw, TABS_H)
        x = x + tw + TAB_GAP
    end
    if not hasSep then frame.tabSep:Hide() end
end

local function refreshWindow()
    if not frame then return end
    local ui = settings()
    local own, data = charData()
    local lists = listsOf(own)
    for i, tab in ipairs(frame.tabs) do
        local list = lists[i]
        tab.list = list
        if list then tab:SetText(list.title) end
        tab:SetShown(list ~= nil)
    end
    frame.historyTab:SetShown(frame.history ~= nil)
    layoutTabs()
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

-- Compact ghost button on a section header: searches every item of the section at once.
local function buildSearchButton(line)
    local button = flatButton(line, "ghost", { icon = MAGNIFIER, iconSize = 11, font = "GameFontHighlightSmall" })
    button:SetText(L.search)
    local bw = math.max(64, (textWidth(button, button.label) or 40) + 28)
    button:SetSize(bw, 18)
    button:SetPoint("RIGHT", line, "RIGHT", -6, -1)
    button:SetScript("OnClick", function()
        local entry = line.entry
        if entry and entry.header then searchRows(rowsOf(entry.header)) end
    end)
    button.onEnterExtra = function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.search)
        GameTooltip:AddLine(L.searchSectionHint, 1, 1, 1, true)
        GameTooltip:Show()
    end
    button.onLeaveExtra = function() GameTooltip:Hide() end
    return button
end

local function buildRow(parent, index)
    local line = CreateFrame("Button", nil, parent)
    line:SetHeight(ROW_HEIGHT)
    local y = -ROW_PAD - (index - 1) * ROW_HEIGHT
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    rowArt(line)

    -- Left gold indicator for items on the shopping list.
    line.shopBar = solid(line, "ARTWORK", THEME.gold, 2)
    line.shopBar:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -3)
    line.shopBar:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 3)
    line.shopBar:SetWidth(2)
    line.shopBar:Hide()

    -- Subtle L-shaped branch connecting sub-rows (reagents, crate bundles) to their parent item.
    line.branchV = solid(line, "ARTWORK", THEME.lineHi, 0)
    line.branchV:SetPoint("TOPLEFT", line, "TOPLEFT", 12, 0)
    line.branchV:SetSize(1, math.floor(ROW_HEIGHT / 2) + 1)
    line.branchV:Hide()
    line.branchH = solid(line, "ARTWORK", THEME.lineHi, 0)
    line.branchH:SetPoint("LEFT", line, "LEFT", 12, 0)
    line.branchH:SetSize(10, 1)
    line.branchH:Hide()

    line.icon = itemIcon(line, ICON_SIZE)
    line.icon:SetPoint("LEFT", line, "LEFT", 8, 0)

    line.price = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.price:SetPoint("RIGHT", line, "RIGHT", -8, 0)
    line.price:SetWidth(PRICE_WIDTH)
    line.price:SetJustifyH("RIGHT")

    line.info = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.info:SetPoint("RIGHT", line.price, "LEFT", -12, 0)
    line.info:SetWidth(INFO_WIDTH)
    line.info:SetJustifyH("LEFT")
    line.info:SetWordWrap(false)
    line.info:SetTextColor(0.76, 0.72, 0.66)

    line.count = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.count:SetPoint("RIGHT", line.info, "LEFT", -8, 0)
    line.count:SetWidth(COUNT_WIDTH)
    line.count:SetJustifyH("RIGHT")
    line.count:SetTextColor(THEME.count[1], THEME.count[2], THEME.count[3])

    line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    line.name:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
    line.name:SetPoint("RIGHT", line.count, "LEFT", -6, 0)
    line.name:SetJustifyH("LEFT")
    line.name:SetWordWrap(false)

    -- Section header strip: elevated card surface, gold left accent, subtle bottom border and search button.
    line.headBg = solid(line, "BACKGROUND", THEME.card, -3)
    line.headBg:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -2)
    line.headBg:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 0, 0)
    line.accent = solid(line, "ARTWORK", THEME.goldSoft, 1)
    line.accent:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -2)
    line.accent:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 0)
    line.accent:SetWidth(2)
    line.rule = solid(line, "ARTWORK", THEME.line, 1)
    line.rule:SetHeight(1)
    line.rule:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 0)
    line.rule:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 0, 0)

    line.search = buildSearchButton(line)
    line.head = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line.head:SetPoint("LEFT", line, "LEFT", 10, -1)
    line.head:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
    line.note = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.note:SetPoint("LEFT", line.head, "RIGHT", 10, 0)
    line.note:SetPoint("RIGHT", line.search, "LEFT", -8, 0)
    line.note:SetJustifyH("LEFT")
    line.note:SetWordWrap(false)
    line.note:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])

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

-- Fits the content to the window's size: as many rows as there is room for, a wider info column, the
-- tabs, and the price history panel. Runs while the window is dragged larger or smaller.
local function layout()
    if not frame then return end
    local w, h = size()
    local bodyH = h - BODY_TOP - BODY_BOTTOM
    visibleRows = math.max(1, math.floor((bodyH - ROW_PAD * 2) / ROW_HEIGHT))
    for i = #frame.rows + 1, visibleRows do frame.rows[i] = buildRow(frame.body, i) end
    local info = math.floor(math.max(180, math.min(520, INFO_WIDTH + (w - WIDTH) * 0.48)))
    for _, line in ipairs(frame.rows) do line.info:SetWidth(info) end
    frame.empty:SetWidth(w - 80)
    layoutTabs()
    if frame.history and ns.history.layout then
        ns.history.layout(w - CONTENT.left + CONTENT.right, h + CONTENT.top - CONTENT.bottom)
    end
    refreshRows()
end

local function clampSize(w, h)
    return math.floor(math.max(MIN_WIDTH, math.min(MAX_WIDTH, w)) + 0.5),
        math.floor(math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, h)) + 0.5)
end

-- Position and size go into the settings, so the window comes back as it was left.
local function savePlace()
    local point, _, relative, x, y = frame:GetPoint()
    if point then settings().point = { point, relative or point, x or 0, y or 0 } end
    local w, h = num(try(frame.GetWidth, frame)), num(try(frame.GetHeight, frame))
    if w and h then settings().size = { clampSize(w, h) } end
end

-- Crisp 6-dot triangular corner grip that lights up in gold on hover.
local function buildGrip()
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    local dots = {}
    for _, pos in ipairs({ { 11, 3 }, { 7, 3 }, { 3, 3 }, { 11, 7 }, { 7, 7 }, { 11, 11 } }) do
        local dot = solid(grip, "ARTWORK", THEME.border, 1)
        dot:SetSize(2, 2)
        dot:SetPoint("BOTTOMLEFT", grip, "BOTTOMLEFT", pos[1], pos[2])
        dots[#dots + 1] = dot
    end
    grip:RegisterForClicks("RightButtonUp")
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        -- Keep the top left corner where it is, whatever point the window is anchored by.
        local left, top = num(try(frame.GetLeft, frame)), num(try(frame.GetTop, frame))
        if left and top then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
        frame.sizing = true
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        if not frame.sizing then return end
        frame.sizing = false
        frame:StopMovingOrSizing()
        savePlace()
        layout()
    end)
    -- Right-click: back to the default size.
    grip:SetScript("OnClick", function()
        frame:SetSize(WIDTH, HEIGHT)
        settings().size = nil
        layout()
    end)
    grip:SetScript("OnEnter", function(self)
        for _, dot in ipairs(dots) do colorTex(dot, THEME.gold) end
        if type(SetCursor) == "function" then pcall(SetCursor, "UI_RESIZE_CURSOR") end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.resizeHint, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function()
        for _, dot in ipairs(dots) do colorTex(dot, THEME.border) end
        if type(SetCursor) == "function" then pcall(SetCursor, nil) end
        GameTooltip:Hide()
    end)
    return grip
end

local function buildTitleBar()
    local bar = solid(frame, "BACKGROUND", THEME.bar, -4)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_H - 1)
    divider(frame, "TOPLEFT", 1, -TITLE_H, "TOPRIGHT", -1, -TITLE_H)

    local logo = itemIcon(frame, 20)
    logo:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -8)
    logo:SetTexture(LOGO)
    logo.border:SetVertexColor(THEME.borderHi[1], THEME.borderHi[2], THEME.borderHi[3])
    logo.border:Show()
    frame.logo = logo

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", logo, "RIGHT", 9, 0)
    title:SetText(L.windowTitle)
    title:SetTextColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
    frame.title = title

    local close = CreateFrame("Button", nil, frame)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    close.box = frameBox(close, THEME.ghost, THEME.borderSubtle)
    local xText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    xText:SetPoint("CENTER", close, "CENTER", 0, 1)
    xText:SetText("\195\151")
    xText:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])
    close:SetScript("OnEnter", function()
        close.box:setBg(THEME.closeHover)
        close.box:setBorder(THEME.primaryBorder)
        xText:SetTextColor(1, 1, 1)
    end)
    close:SetScript("OnLeave", function()
        close.box:setBg(THEME.ghost)
        close.box:setBorder(THEME.borderSubtle)
        xText:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])
    end)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.close = close

    -- Scan and computation timestamp on the right side of the title bar.
    frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.sub:SetPoint("LEFT", title, "RIGHT", 12, 0)
    frame.sub:SetPoint("RIGHT", close, "LEFT", -10, 0)
    frame.sub:SetJustifyH("RIGHT")
    frame.sub:SetWordWrap(false)
    frame.sub:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])
end

local function buildTopStrips()
    local tabBg = solid(frame, "BACKGROUND", THEME.tabs, -4)
    tabBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -TITLE_H - 1)
    tabBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -TITLE_H - 1)
    tabBg:SetHeight(TABS_H - 1)
    divider(frame, "TOPLEFT", 1, -(TITLE_H + TABS_H), "TOPRIGHT", -1, -(TITLE_H + TABS_H))

    local noteBg = solid(frame, "BACKGROUND", THEME.noteBar, -4)
    noteBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -(TITLE_H + TABS_H + 1))
    noteBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -(TITLE_H + TABS_H + 1))
    noteBg:SetHeight(NOTE_H - 1)
    divider(frame, "TOPLEFT", 1, -TOP, "TOPRIGHT", -1, -TOP)

    frame.tabSep = solid(frame, "ARTWORK", THEME.lineHi, 1)
    frame.tabSep:SetSize(1, 16)
    frame.tabSep:Hide()

    frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.note:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(TITLE_H + TABS_H + 7))
    frame.note:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -(TITLE_H + TABS_H + 7))
    frame.note:SetJustifyH("LEFT")
    frame.note:SetWordWrap(false)
    frame.note:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(TITLE_H + TABS_H + 7))
    frame.hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -(TITLE_H + TABS_H + 7))
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(false)
    frame.hint:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
end

local function buildBottomBar()
    local foot = solid(frame, "BACKGROUND", THEME.bar, -4)
    foot:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    foot:SetHeight(BOTTOM - 1)
    divider(frame, "BOTTOMLEFT", 1, BOTTOM, "BOTTOMRIGHT", -1, BOTTOM)

    -- Modern flat checkbox with a gold checkmark.
    local auto = CreateFrame("CheckButton", nil, frame)
    auto:SetSize(16, 16)
    auto:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 11)
    auto.box = frameBox(auto, THEME.panel, THEME.border)
    local check = auto:CreateTexture(nil, "OVERLAY")
    check:SetTexture(CHECK_TEX)
    check:SetSize(18, 18)
    check:SetPoint("CENTER", auto, "CENTER", 0, 0)
    check:SetVertexColor(THEME.gold[1], THEME.gold[2], THEME.gold[3])
    auto:SetCheckedTexture(check)

    local label = auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", auto, "RIGHT", 7, 0)
    label:SetText(L.autoOpen)
    label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    auto.Text = label
    try(auto.SetHitRectInsets, auto, 0, -(textWidth(auto, label) or 160) - 10, -6, -6)

    auto:SetScript("OnClick", function(self) settings().ah = self:GetChecked() and true or false end)
    auto:SetScript("OnEnter", function(self)
        self.box:setBorder(THEME.borderHi)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.autoOpen)
        GameTooltip:AddLine(L.autoOpenHint, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    auto:SetScript("OnLeave", function(self)
        self.box:setBorder(THEME.border)
        GameTooltip:Hide()
    end)
    frame.auto = auto

    -- Primary action: crimson button with bronze-gold edge matching the desktop app.
    frame.buy = flatButton(frame, "primary", { font = "GameFontNormal" })
    frame.buy:SetText(L.searchList)
    frame.buy:SetSize(math.max(160, (textWidth(frame.buy, frame.buy.label) or 150) + 32), 24)
    frame.buy:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 7) -- room for the corner grip
    frame.buy:SetScript("OnClick", function() searchRows(shopRows(current)) end)
    frame.buy.onEnterExtra = function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.searchList)
        GameTooltip:AddLine(L.searchListHint, 1, 1, 1, true)
        GameTooltip:Show()
    end
    frame.buy.onLeaveExtra = function() GameTooltip:Hide() end
end

local function newTab(onClick)
    local tab = CreateFrame("Button", nil, frame)
    tab.bg = solid(tab, "BACKGROUND", THEME.tabActive, -2)
    tab.bg:SetAllPoints()
    tab.bg:Hide()
    tab.bar = solid(tab, "OVERLAY", THEME.gold, 2)
    tab.bar:SetHeight(2)
    tab.bar:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.bar:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
    tab.bar:Hide()
    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.label:SetPoint("LEFT", tab, "LEFT", 8, 0)
    tab.label:SetPoint("RIGHT", tab, "RIGHT", -8, 0)
    tab.label:SetJustifyH("CENTER")
    tab.label:SetWordWrap(false)
    try(tab.SetFontString, tab, tab.label)
    tab:SetScript("OnEnter", function(self)
        self.hovered = true
        paintTab(self)
    end)
    tab:SetScript("OnLeave", function(self)
        self.hovered = false
        paintTab(self)
    end)
    tab:SetScript("OnClick", function(self)
        playTabSound()
        onClick(self)
    end)
    tab:Hide()
    return tab
end

local function buildWindow()
    frame = CreateFrame("Frame", "WoWMCPListFrame", UIParent)
    local saved = settings().size
    if type(saved) == "table" and num(saved[1]) and num(saved[2]) then
        frame:SetSize(clampSize(saved[1], saved[2]))
    else
        frame:SetSize(WIDTH, HEIGHT)
    end
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    elseif frame.SetMinResize then
        frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        frame:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:RegisterForDrag("LeftButton")
    frame:Hide()
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "WoWMCPListFrame") end -- Escape closes it

    -- Opaque dark stone canvas with a 1px bronze frame and 1px black outer shadow.
    frame.outer = frameBox(frame, nil, THEME.outerShadow, -1)
    frame.box = frameBox(frame, THEME.bg, THEME.border, 0)

    buildTitleBar()
    buildTopStrips()

    frame.tabs = {}
    for i = 1, MAX_TABS do
        frame.tabs[i] = newTab(function(self) if self.list then showList(self.list) end end)
    end
    frame.historyTab = newTab(function() showHistory() end)
    frame.historyTab:SetText(L.historyTab)

    -- Dark inset body that holds the list rows and the thin scrollbar.
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BODY_TOP)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, BODY_BOTTOM)
    body.box = frameBox(body, THEME.panel, THEME.borderSubtle)
    frame.body = body

    if ns.history then frame.history = ns.history.build(frame, CONTENT) end

    frame.rows = {}
    frame.empty = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.empty:SetPoint("CENTER", body, "CENTER", 0, 0)
    frame.empty:SetSpacing(4)
    frame.empty:SetTextColor(THEME.muted[1], THEME.muted[2], THEME.muted[3])

    frame.slider = modernSlider(body, 8, scrollTo)
    frame.slider:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -ROW_PAD)
    frame.slider:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, ROW_PAD)

    buildBottomBar()

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePlace()
    end)
    frame:SetScript("OnSizeChanged", function() layout() end)
    frame.grip = buildGrip()
    layout()
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
