-- WoW Tools Forever minimap button: draggable ring button around the minimap with quick access
-- to the lists window, price history and character sync. Position and visibility live in
-- WoWToolsForever_Account.ui (minimap, minimapAngle).

local _, ns = ...
local L = ns.L

local ICON_TEX = "Interface\\AddOns\\WoWToolsForever\\Media\\Icon"
local DEFAULT_ANGLE = 225

-- Quadrant roundness by GetMinimapShape() return value: { top-right, bottom-right, bottom-left, top-left }.
local MINIMAP_SHAPES = {
    ROUND = { true, true, true, true },
    SQUARE = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { true, false, false, false },
    ["CORNER-BOTTOMLEFT"] = { false, false, true, false },
    ["CORNER-BOTTOMRIGHT"] = { false, true, false, false },
    ["SIDE-LEFT"] = { false, false, true, true },
    ["SIDE-RIGHT"] = { true, true, false, false },
    ["SIDE-TOP"] = { true, false, false, true },
    ["SIDE-BOTTOM"] = { false, true, true, false },
    ["TRICORNER-TOPLEFT"] = { true, false, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMLEFT"] = { false, true, true, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local button

local function uiSettings()
    if type(WoWToolsForever_Account) ~= "table" then WoWToolsForever_Account = {} end
    if type(WoWToolsForever_Account.ui) ~= "table" then WoWToolsForever_Account.ui = {} end
    local ui = WoWToolsForever_Account.ui
    if ui.minimap == nil then ui.minimap = true end
    return ui
end

local function positionButton(angle)
    if not (button and Minimap) then return end
    angle = tonumber(angle) or DEFAULT_ANGLE
    local rad = math.rad(angle)
    local x, y = math.cos(rad), math.sin(rad)
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end
    -- Map quadrant index to { TR=1, BR=2, BL=3, TL=4 }
    local quadMap = { [1] = 2, [2] = 3, [3] = 1, [4] = 4 }
    local shape = type(GetMinimapShape) == "function" and GetMinimapShape() or "ROUND"
    local quad = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND
    local w = (Minimap.GetWidth and Minimap:GetWidth()) or 140
    local h = (Minimap.GetHeight and Minimap:GetHeight()) or w
    local rx, ry = w / 2 + 5, h / 2 + 5
    local dx, dy
    if quad[quadMap[q]] then
        dx, dy = x * rx, y * ry
    else
        local diagX = math.sqrt(2 * rx * rx) - 10
        local diagY = math.sqrt(2 * ry * ry) - 10
        dx = math.max(-rx, math.min(x * diagX, rx))
        dy = math.max(-ry, math.min(y * diagY, ry))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
end

local function angleFromCursor()
    if not (Minimap and Minimap.GetCenter and type(GetCursorPosition) == "function") then return nil end
    local mx, my = Minimap:GetCenter()
    if not (mx and my) then return nil end
    local scale = (Minimap.GetEffectiveScale and Minimap:GetEffectiveScale()) or 1
    if scale == 0 then scale = 1 end
    local cx, cy = GetCursorPosition()
    local atan2 = math.atan2 or math.atan
    return math.deg(atan2(cy / scale - my, cx / scale - mx))
end

local function buildButton()
    if button or not Minimap then return end
    button = CreateFrame("Button", "WoWToolsForeverMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", button, "CENTER", 0, 1)
    button.bg = bg

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON_TEX)
    icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    if button.CreateMaskTexture and icon.AddMaskTexture then
        local mask = button:CreateMaskTexture()
        if mask then
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(icon)
            icon:AddMaskTexture(mask)
        end
    end
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.border = border

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnMouseDown", function()
        icon:SetPoint("CENTER", button, "CENTER", 1, 0)
    end)
    button:SetScript("OnMouseUp", function()
        icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    end)

    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local angle = angleFromCursor()
            if angle then
                uiSettings().minimapAngle = angle
                positionButton(angle)
            end
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    end)

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
                if ns.sync then ns.sync() end
            elseif ns.commands and ns.commands.price then
                ns.commands.price("")
            end
        elseif ns.commands and ns.commands.show then
            ns.commands.show()
        end
    end)

    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local title = L.windowTitle
        if ns.version and ns.version ~= "?" then title = title .. " " .. ns.version end
        GameTooltip:SetText(title, 1, 0.82, 0)
        GameTooltip:AddLine(L.minimapLeft, 1, 1, 1)
        GameTooltip:AddLine(L.minimapRight, 1, 1, 1)
        GameTooltip:AddLine(L.minimapShiftRight, 1, 1, 1)
        GameTooltip:AddLine(L.minimapDrag, 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    local ui = uiSettings()
    positionButton(ui.minimapAngle)
    button:SetShown(ui.minimap ~= false)
end

ns.minimap = {
    setShown = function(on)
        if not button then buildButton() end
        if button then button:SetShown(on and true or false) end
    end,
    update = function()
        if not button then buildButton() end
        if button then
            local ui = uiSettings()
            positionButton(ui.minimapAngle)
            button:SetShown(ui.minimap ~= false)
        end
    end,
}

local loader = CreateFrame("Frame")
if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid("PLAYER_LOGIN") then
    pcall(loader.RegisterEvent, loader, "PLAYER_LOGIN")
end
loader:SetScript("OnEvent", function()
    pcall(buildButton)
end)
