-- KeystoneCutoffs.lua
-- Core addon logic: reads CutoffData.lua and attaches a Raider.io-inspired
-- side tooltip to ChallengesFrame.
-- Author : Xtendr
-- License: MIT

local ADDON_NAME = "KeystoneCutoffs"

-- ─── Saved-variable defaults ──────────────────────────────────────────────────
local DB_DEFAULTS = {
    -- Display
    showMythThreshold = true,
    showSeasonEnd     = true,
    showDungeonScores = true,
    compactMode       = false,
    position          = "RIGHT",   -- "RIGHT" | "BOTTOM"
    -- Customize (dungeon score overlays)
    overlayFont       = "Friz Quadrata TT",
    overlayScoreSize  = 14,
    overlayTimeSize   = 11,
    overlayOutline    = "OUTLINE", -- "NONE" | "OUTLINE" | "THICKOUTLINE" | "SHADOW"
    -- Persistence
    panelPosition     = nil,       -- { point, relPoint, x, y } when user drags panel
    minimap           = { hide = false },
}

-- ─── Colour palette ──────────────────────────────────────────────────────────
local C = {
    gold   = "|cFFFFD100",
    purple = "|cFFA335EE",
    white  = "|cFFFFFFFF",
    grey   = "|cFFAAAAAA",
    reset  = "|r",
}

local function col(colour, text)
    return colour .. tostring(text) .. C.reset
end

local function fmt(n)
    if type(n) ~= "number" then return "N/A" end
    return string.format("%.1f", n)
end

local function fmtTime(secs)
    if type(secs) ~= "number" or secs <= 0 then return nil end
    return string.format("%d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

-- ─── Panel layout constants ────────────────────────────────────────────────
local FRAME_WIDTH    = 280
local PAD            = 12
local TOP_PAD        = 12
local BOTTOM_PAD     = 12

local MAIN_TITLE_H   = 22
local SECTION_TITLE_H= 18
local SUBTITLE_H     = 12
local SUBTITLE_GAP   = 2
local AFTER_SUBTITLE = 8

local ROW_H          = 18
local ROW_GAP        = 2
local SECTION_GAP    = 11

local BTN_W          = 22
local BTN_H          = 18

local COLLAPSED_HEIGHT = TOP_PAD + MAIN_TITLE_H + SUBTITLE_GAP + SUBTITLE_H + BOTTOM_PAD

local function rowBlockHeight(n)
    if n <= 0 then return 0 end
    return n * ROW_H + (n - 1) * ROW_GAP
end

-- ─── Score gradient ───────────────────────────────────────────────────────────
local scoreGradient = {}

local function refreshScorePalette()
    scoreGradient = {}
    if not KeystoneCutoffsData or not KeystoneCutoffsData.scoreColors then return end
    for _, entry in ipairs(KeystoneCutoffsData.scoreColors) do
        local score = tonumber(entry.score)
        local hex   = entry.color or ""
        if score and type(hex) == "string" then
            local clean = hex:match("#?(%x%x%x%x%x%x)")
            if clean then
                local norm = string.upper(clean)
                table.insert(scoreGradient, {
                    score = score,
                    hex   = norm,
                    r     = tonumber(norm:sub(1, 2), 16),
                    g     = tonumber(norm:sub(3, 4), 16),
                    b     = tonumber(norm:sub(5, 6), 16),
                })
            end
        end
    end
    table.sort(scoreGradient, function(a, b) return a.score > b.score end)
end

local function scoreColorFor(score)
    if type(score) ~= "number" or #scoreGradient == 0 then return C.white end
    if score >= scoreGradient[1].score then return "|cFF" .. scoreGradient[1].hex end
    local last = scoreGradient[#scoreGradient]
    if score <= last.score then return "|cFF" .. last.hex end
    for i = 1, #scoreGradient - 1 do
        local upper = scoreGradient[i]
        local lower = scoreGradient[i + 1]
        if score <= upper.score and score >= lower.score then
            local span  = upper.score - lower.score
            local ratio = span > 0 and (score - lower.score) / span or 0
            return string.format("|cFF%02X%02X%02X",
                math.floor(lower.r + (upper.r - lower.r) * ratio + 0.5),
                math.floor(lower.g + (upper.g - lower.g) * ratio + 0.5),
                math.floor(lower.b + (upper.b - lower.b) * ratio + 0.5))
        end
    end
    return C.white
end

-- ─── Forward declarations ────────────────────────────────────────────────────
local panel
local PositionPanel
local UpdatePanel
local UpdateDungeonOverlays

-- ─── Custom Settings Window ──────────────────────────────────────────────────
-- Styling tokens (dark theme with gold accent)
local ST = {
    bg      = { 0.08, 0.08, 0.08, 0.95 },
    surface = { 0.12, 0.12, 0.12, 1.00 },
    element = { 0.17, 0.17, 0.17, 1.00 },
    hover   = { 0.24, 0.24, 0.24, 0.90 },
    border  = { 0.25, 0.25, 0.25, 1.00 },
    accent  = { 1.00, 0.82, 0.00 },       -- gold
    text    = { 0.88, 0.88, 0.88, 1.00 },
    muted   = { 0.55, 0.55, 0.55, 1.00 },
    red     = { 0.75, 0.18, 0.18, 1.00 },
}

local BD_EDGE = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}
local BD_PLAIN = { bgFile = "Interface\\Buttons\\WHITE8x8" }

local function mixBD(f)
    if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
end

local settingsWin
local settingsRefreshFns = {}

-- Build and return a checkbox row Frame.
-- dbKey  = KeystoneCutoffsDB key (boolean)
-- label  = display text
-- onToggle = optional extra callback
local function makeKCCheckbox(parent, yOff, dbKey, labelText, onToggle)
    local ROW_H_CB = 22

    local row = CreateFrame("Button", nil, parent)
    row:SetSize(parent:GetWidth() - 28, ROW_H_CB)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff)

    -- Box backdrop
    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    mixBD(box)
    box:SetBackdrop(BD_EDGE)
    box:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    box:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)

    -- Checkmark (native WoW checkbox texture, tinted gold)
    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetSize(18, 18)
    check:SetPoint("CENTER", 0, 0)
    check:SetVertexColor(ST.accent[1], ST.accent[2], ST.accent[3])

    -- Label
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    lbl:SetWordWrap(false)

    local function refresh()
        check:SetShown(KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey] ~= false)
    end

    row:SetScript("OnClick", function()
        if KeystoneCutoffsDB then
            KeystoneCutoffsDB[dbKey] = not (KeystoneCutoffsDB[dbKey] ~= false)
        end
        refresh()
        if onToggle then onToggle() end
        UpdatePanel()
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)
    row:SetScript("OnEnter", function()
        box:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 1)
    end)
    row:SetScript("OnLeave", function()
        box:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    end)

    settingsRefreshFns[#settingsRefreshFns + 1] = refresh
    refresh()
    return row, ROW_H_CB
end

-- Build a label + right-side dropdown button.
-- Returns: labelFs, dropBtn, consumed_height
local function makeKCDropdown(parent, yOff, dbKey, labelText, opts, extraCb)
    local ITEM_H  = 24
    local BTN_W_D = 140
    local ROW_H_D = 24

    -- Row label
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff - 4)
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    lbl:SetWordWrap(false)

    -- Dropdown button
    local ddBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    ddBtn:SetSize(BTN_W_D, ROW_H_D)
    ddBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff - 2)
    mixBD(ddBtn)
    ddBtn:SetBackdrop(BD_EDGE)
    ddBtn:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    ddBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)

    local ddLabel = ddBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ddLabel:SetPoint("LEFT", 8, 0)
    ddLabel:SetPoint("RIGHT", -22, 0)
    ddLabel:SetJustifyH("LEFT")
    ddLabel:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    ddLabel:SetWordWrap(false)

    local ddArrow = ddBtn:CreateTexture(nil, "OVERLAY")
    ddArrow:SetTexture("Interface\\AddOns\\KeystoneCutoffs\\Assets\\chevron_right.tga")
    ddArrow:SetSize(10, 10)
    ddArrow:SetPoint("RIGHT", -6, 0)
    ddArrow:SetVertexColor(ST.muted[1], ST.muted[2], ST.muted[3], 0.95)
    -- Source icon points right; rotate clockwise so it points down.
    ddArrow:SetRotation(-math.pi / 2)

    local function getCurrentLabel()
        local cur = KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey]
        for _, opt in ipairs(opts) do
            if opt.value == cur then return opt.label end
        end
        return opts[1] and opts[1].label or "?"
    end

    local function refreshDD() ddLabel:SetText(getCurrentLabel()) end

    -- Floating menu (TOOLTIP strata so it always renders above the settings window)
    local menuH = #opts * ITEM_H + 6
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetSize(BTN_W_D, menuH)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(500)
    menu:SetClampedToScreen(true)
    mixBD(menu)
    menu:SetBackdrop(BD_EDGE)
    menu:SetBackdropColor(ST.surface[1], ST.surface[2], ST.surface[3], 1)
    menu:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    menu:Hide()

    for i, opt in ipairs(opts) do
        local item = CreateFrame("Button", nil, menu, "BackdropTemplate")
        item:SetSize(BTN_W_D - 2, ITEM_H)
        item:SetPoint("TOPLEFT", 1, -3 - (i - 1) * ITEM_H)
        mixBD(item)
        item:SetBackdrop(BD_PLAIN)
        item:SetBackdropColor(0, 0, 0, 0)

        local itemLbl = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        itemLbl:SetPoint("LEFT", 8, 0)
        itemLbl:SetText(opt.label)
        itemLbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])

        item:SetScript("OnEnter", function() item:SetBackdropColor(ST.hover[1], ST.hover[2], ST.hover[3], 0.9) end)
        item:SetScript("OnLeave", function() item:SetBackdropColor(0, 0, 0, 0) end)
        item:SetScript("OnClick", function()
            if KeystoneCutoffsDB then KeystoneCutoffsDB[dbKey] = opt.value end
            menu:Hide()
            refreshDD()
            if extraCb then extraCb() end
            UpdatePanel()
            PositionPanel()
            pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
    end

    -- Click-catcher to close menu on outside click (sits just below the TOOLTIP menu)
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints()
    catcher:SetFrameStrata("TOOLTIP")
    catcher:SetFrameLevel(499)
    catcher:EnableMouse(true)
    catcher:Hide()
    catcher:SetScript("OnMouseDown", function() menu:Hide() end)
    menu:SetScript("OnShow", function() catcher:Show() end)
    menu:SetScript("OnHide", function() catcher:Hide() end)

    ddBtn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
            menu:Show()
        end
    end)
    ddBtn:SetScript("OnEnter", function()
        ddBtn:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
    end)
    ddBtn:SetScript("OnLeave", function()
        ddBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)
    end)

    settingsRefreshFns[#settingsRefreshFns + 1] = refreshDD
    refreshDD()
    return ROW_H_D
end

-- Slider row (styled after the StarterUI template):
--   [label] ──────●────────── [value]
-- Uses a custom backdropped track + a flat rectangular thumb instead of the
-- default Blizzard slider textures which clash with the dark theme.
local function makeKCSlider(parent, yOff, dbKey, labelText, minVal, maxVal, step, extraCb)
    local ROW_H_S   = 24
    local TRACK_H   = 10
    local THUMB_W   = 10
    local THUMB_H   = 16
    local LABEL_W   = 78
    local VALUE_W   = 28
    local GAP       = 10

    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  14, yOff)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff)
    row:SetHeight(ROW_H_S)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", 0, 0)
    lbl:SetWidth(LABEL_W)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    lbl:SetWordWrap(false)

    local valueFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueFs:SetPoint("RIGHT", 0, 0)
    valueFs:SetWidth(VALUE_W)
    valueFs:SetJustifyH("RIGHT")
    valueFs:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])

    -- Track: backdropped frame representing the slider rail
    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetPoint("LEFT",  lbl,     "RIGHT", GAP, 0)
    track:SetPoint("RIGHT", valueFs, "LEFT", -GAP, 0)
    track:SetHeight(TRACK_H)
    mixBD(track)
    track:SetBackdrop(BD_EDGE)
    track:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    track:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)

    -- Invisible Slider widget overlaid on the track
    local slider = CreateFrame("Slider", nil, track)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("LEFT",  track,  THUMB_W / 2, 0)
    slider:SetPoint("RIGHT", track, -THUMB_W / 2, 0)
    slider:SetHeight(TRACK_H)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)

    -- Flat rectangular thumb, tinted with the accent color
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(THUMB_W, THUMB_H)
    thumb:SetColorTexture(ST.accent[1], ST.accent[2], ST.accent[3], 1)
    slider:SetThumbTexture(thumb)

    -- Guard: avoid feedback loop when refresh() programmatically calls SetValue
    local updating = false

    local function refresh()
        local cur = tonumber(KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey]) or minVal
        updating = true
        slider:SetValue(cur)
        updating = false
        valueFs:SetText(tostring(math.floor(cur + 0.5)))
    end
    settingsRefreshFns[#settingsRefreshFns + 1] = refresh
    refresh()

    slider:SetScript("OnValueChanged", function(_, val)
        if updating then return end
        val = math.floor(val + 0.5)
        if KeystoneCutoffsDB then KeystoneCutoffsDB[dbKey] = val end
        valueFs:SetText(tostring(val))
        if extraCb then extraCb() end
    end)

    -- Hover highlight on the track border for discoverability
    slider:SetScript("OnEnter", function()
        track:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
    end)
    slider:SetScript("OnLeave", function()
        track:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    end)

    return ROW_H_S
end

-- Flat button row (used for "Reset Panel Position").
local function makeKCButton(parent, yOff, labelText, onClick)
    local ROW_H_B = 24
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(parent:GetWidth() - 28, ROW_H_B)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff)
    mixBD(btn)
    btn:SetBackdrop(BD_EDGE)
    btn:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    btn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])

    btn:SetScript("OnEnter", function()
        btn:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
    end)
    btn:SetScript("OnLeave", function()
        btn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)
    end)
    btn:SetScript("OnClick", function()
        if onClick then onClick() end
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)
    return ROW_H_B
end

-- Searchable LibSharedMedia font picker with font-previewed items.
local function makeKCFontDropdown(parent, yOff, dbKey, labelText, extraCb)
    local ITEM_H   = 22
    local BTN_W_D  = 170
    local ROW_H_D  = 24
    local MENU_W   = 220
    local MENU_H   = 260

    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff - 4)
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    lbl:SetWordWrap(false)

    local ddBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    ddBtn:SetSize(BTN_W_D, ROW_H_D)
    ddBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff - 2)
    mixBD(ddBtn)
    ddBtn:SetBackdrop(BD_EDGE)
    ddBtn:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    ddBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)

    -- Template ensures the FontString has a baseline font; otherwise the
    -- first SetText() call errors with "Font not set" (SetFont happens after).
    local ddLabel = ddBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ddLabel:SetPoint("LEFT", 8, 0)
    ddLabel:SetPoint("RIGHT", -22, 0)
    ddLabel:SetJustifyH("LEFT")
    ddLabel:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    ddLabel:SetWordWrap(false)

    local ddArrow = ddBtn:CreateTexture(nil, "OVERLAY")
    ddArrow:SetTexture("Interface\\AddOns\\KeystoneCutoffs\\Assets\\chevron_right.tga")
    ddArrow:SetSize(10, 10)
    ddArrow:SetPoint("RIGHT", -6, 0)
    ddArrow:SetVertexColor(ST.muted[1], ST.muted[2], ST.muted[3], 0.95)
    ddArrow:SetRotation(-math.pi / 2)

    local function resolve(name)
        if LSM and name then return LSM:Fetch("font", name, true) end
        return nil
    end

    local function refreshLabel()
        local cur = (KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey]) or "?"
        local path = resolve(cur)
        if path then
            ddLabel:SetFont(path, 12, "")
        else
            ddLabel:SetFontObject("GameFontHighlightSmall")
        end
        ddLabel:SetText(cur)
    end

    -- Floating scrollable menu
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetSize(MENU_W, MENU_H)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(500)
    menu:SetClampedToScreen(true)
    mixBD(menu)
    menu:SetBackdrop(BD_EDGE)
    menu:SetBackdropColor(ST.surface[1], ST.surface[2], ST.surface[3], 1)
    menu:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    menu:Hide()

    -- Search input
    local search = CreateFrame("EditBox", nil, menu, "InputBoxTemplate")
    search:SetSize(MENU_W - 32, 20)
    search:SetPoint("TOPLEFT", 14, -10)
    search:SetAutoFocus(true)
    search:SetMaxLetters(40)
    search:SetFontObject("GameFontHighlightSmall")

    -- Scrollable content
    local scroll = CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -38)
    scroll:SetPoint("BOTTOMRIGHT", -22, 6)

    -- Style the scrollbar to match the panel theme (thin accent thumb, hidden arrows).
    local scrollBar = scroll.ScrollBar
    if scrollBar then
        if scrollBar.ThumbTexture then
            scrollBar.ThumbTexture:SetColorTexture(
                ST.border[1], ST.border[2], ST.border[3], 0.8)
            scrollBar.ThumbTexture:SetWidth(6)
        end
        if scrollBar.ScrollUpButton then
            scrollBar.ScrollUpButton:SetAlpha(0)
            scrollBar.ScrollUpButton:SetSize(1, 1)
        end
        if scrollBar.ScrollDownButton then
            scrollBar.ScrollDownButton:SetAlpha(0)
            scrollBar.ScrollDownButton:SetSize(1, 1)
        end
    end

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(MENU_W - 40, 1)
    scroll:SetScrollChild(content)

    local itemPool = {}

    local function rebuild(filter)
        filter = (filter or ""):lower()
        for _, it in ipairs(itemPool) do it:Hide() end

        if not LSM then
            content:SetHeight(1)
            return
        end

        local list = LSM:List("font") or {}
        local y, idx = 0, 0
        for _, name in ipairs(list) do
            if filter == "" or name:lower():find(filter, 1, true) then
                idx = idx + 1
                local it = itemPool[idx]
                if not it then
                    it = CreateFrame("Button", nil, content, "BackdropTemplate")
                    mixBD(it)
                    it:SetBackdrop(BD_PLAIN)
                    it:SetBackdropColor(0, 0, 0, 0)
                    it:SetSize(MENU_W - 40, ITEM_H)
                    -- Baseline template so SetText works before SetFont override.
                    it.text = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    it.text:SetPoint("LEFT", 6, 0)
                    it.text:SetPoint("RIGHT", -6, 0)
                    it.text:SetJustifyH("LEFT")
                    it.text:SetWordWrap(false)
                    it:SetScript("OnEnter", function(self)
                        self:SetBackdropColor(ST.hover[1], ST.hover[2], ST.hover[3], 0.9)
                    end)
                    it:SetScript("OnLeave", function(self)
                        local selected = KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey] == self.fontName
                        if selected then
                            self:SetBackdropColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.15)
                        else
                            self:SetBackdropColor(0, 0, 0, 0)
                        end
                    end)
                    itemPool[idx] = it
                end

                it.fontName = name
                local path = resolve(name)
                if path then
                    it.text:SetFont(path, 14, "")
                else
                    it.text:SetFontObject("GameFontHighlightSmall")
                end
                it.text:SetText(name)

                local selected = KeystoneCutoffsDB and KeystoneCutoffsDB[dbKey] == name
                if selected then
                    it.text:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])
                    it:SetBackdropColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.15)
                else
                    it.text:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
                    it:SetBackdropColor(0, 0, 0, 0)
                end

                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", 0, -y)
                it:SetScript("OnClick", function(self)
                    if KeystoneCutoffsDB then KeystoneCutoffsDB[dbKey] = self.fontName end
                    menu:Hide()
                    refreshLabel()
                    if extraCb then extraCb() end
                    pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                end)
                it:Show()
                y = y + ITEM_H
            end
        end
        content:SetHeight(math.max(1, y))
    end

    search:SetScript("OnTextChanged",   function(self) rebuild(self:GetText()) end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); menu:Hide() end)
    search:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)

    -- Click-catcher to close menu on outside click
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints()
    catcher:SetFrameStrata("TOOLTIP")
    catcher:SetFrameLevel(499)
    catcher:EnableMouse(true)
    catcher:Hide()
    catcher:SetScript("OnMouseDown", function() menu:Hide() end)
    menu:SetScript("OnShow", function()
        catcher:Show()
        search:SetText("")
        rebuild("")
    end)
    menu:SetScript("OnHide", function() catcher:Hide(); search:ClearFocus() end)

    ddBtn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            menu:ClearAllPoints()
            menu:SetPoint("TOPRIGHT", ddBtn, "BOTTOMRIGHT", 0, -2)
            menu:Show()
        end
    end)
    ddBtn:SetScript("OnEnter", function()
        ddBtn:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
    end)
    ddBtn:SetScript("OnLeave", function()
        ddBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)
    end)

    settingsRefreshFns[#settingsRefreshFns + 1] = refreshLabel
    refreshLabel()
    return ROW_H_D
end

-- Custom checkbox for nested DB values (used by the minimap toggle).
-- getFn returns bool "checked"; setFn(newBool) persists.
local function makeKCCheckboxCustom(parent, yOff, labelText, getFn, setFn, onToggle)
    local ROW_H_CB = 22

    local row = CreateFrame("Button", nil, parent)
    row:SetSize(parent:GetWidth() - 28, ROW_H_CB)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff)

    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    mixBD(box)
    box:SetBackdrop(BD_EDGE)
    box:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    box:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetSize(18, 18)
    check:SetPoint("CENTER", 0, 0)
    check:SetVertexColor(ST.accent[1], ST.accent[2], ST.accent[3])

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
    lbl:SetText(labelText)
    lbl:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    lbl:SetWordWrap(false)

    local function refresh() check:SetShown(getFn() and true or false) end

    row:SetScript("OnClick", function()
        setFn(not getFn())
        refresh()
        if onToggle then onToggle() end
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)
    row:SetScript("OnEnter", function()
        box:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 1)
    end)
    row:SetScript("OnLeave", function()
        box:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    end)

    settingsRefreshFns[#settingsRefreshFns + 1] = refresh
    refresh()
    return row, ROW_H_CB
end

-- Forward declaration for the minimap helper (defined in its own section below).
local UpdateMinimapButton

local function CreateSettingsWindow()
    if settingsWin then return end

    local WIN_W = 340

    local win = CreateFrame("Frame", "KCSettingsFrame", UIParent, "BackdropTemplate")
    win:SetWidth(WIN_W)
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    mixBD(win)
    win:SetBackdrop(BD_EDGE)
    win:SetBackdropColor(ST.bg[1], ST.bg[2], ST.bg[3], ST.bg[4])
    win:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    win:Hide()
    tinsert(UISpecialFrames, "KCSettingsFrame")

    -- ── Title bar (drag handle) ──────────────────────────────────────────────
    -- Frame level raised above the content area so the drag doesn't cross over
    -- into sibling widgets mid-motion (that was the "snap far from mouse" bug).
    local TITLE_H = 30
    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetFrameLevel(win:GetFrameLevel() + 3)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing() end)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(ST.surface[1], ST.surface[2], ST.surface[3], 1)

    local titleTxt = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleTxt:SetPoint("LEFT", 12, 0)
    titleTxt:SetText(col(C.gold, "Keystone Cutoffs") .. " |cFF555555— Settings|r")
    titleTxt:SetWordWrap(false)

    -- Close button (always above title bar)
    local closeBtn = CreateFrame("Button", nil, win, "BackdropTemplate")
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetFrameLevel(win:GetFrameLevel() + 10)
    mixBD(closeBtn)
    closeBtn:SetBackdrop(BD_EDGE)
    closeBtn:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    closeBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.4)

    local closeX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeX:SetPoint("CENTER", 0, -1)
    closeX:SetText("×")
    closeX:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])

    closeBtn:SetScript("OnEnter", function()
        closeBtn:SetBackdropBorderColor(ST.red[1], ST.red[2], ST.red[3], 1)
        closeX:SetTextColor(ST.red[1], ST.red[2], ST.red[3])
    end)
    closeBtn:SetScript("OnLeave", function()
        closeBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.4)
        closeX:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])
    end)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- Separator under title
    local sep = win:CreateTexture(nil, "BACKGROUND")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, -TITLE_H)
    sep:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -TITLE_H)
    sep:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 1)

    -- ── Tab bar ───────────────────────────────────────────────────────────────
    local TAB_BAR_H = 26
    local tabBarY   = -TITLE_H - 4

    local tabContainers = {}
    local tabButtons    = {}

    local function showTab(name)
        for key, frm in pairs(tabContainers) do frm:SetShown(key == name) end
        for key, btn in pairs(tabButtons) do
            btn.underline:SetShown(key == name)
            btn.label:SetTextColor(
                key == name and ST.accent[1] or ST.muted[1],
                key == name and ST.accent[2] or ST.muted[2],
                key == name and ST.accent[3] or ST.muted[3])
        end
    end

    local function makeTabButton(name, labelText, xOff)
        local b = CreateFrame("Button", nil, win)
        b:SetSize(92, TAB_BAR_H)
        b:SetPoint("TOPLEFT", win, "TOPLEFT", xOff, tabBarY)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.label:SetPoint("CENTER", 0, 2)
        b.label:SetText(labelText)
        b.label:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])
        b.underline = b:CreateTexture(nil, "OVERLAY")
        b.underline:SetHeight(2)
        b.underline:SetPoint("BOTTOMLEFT", 6, 0)
        b.underline:SetPoint("BOTTOMRIGHT", -6, 0)
        b.underline:SetColorTexture(ST.accent[1], ST.accent[2], ST.accent[3], 1)
        b.underline:Hide()
        b:SetScript("OnClick", function()
            showTab(name)
            pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
        b:SetScript("OnEnter", function()
            if not b.underline:IsShown() then
                b.label:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
            end
        end)
        b:SetScript("OnLeave", function()
            if not b.underline:IsShown() then
                b.label:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])
            end
        end)
        tabButtons[name] = b
        return b
    end

    makeTabButton("display",   "Display",   14)
    makeTabButton("customize", "Customize", 112)

    -- Separator under tab bar
    local tabSep = win:CreateTexture(nil, "BACKGROUND")
    tabSep:SetHeight(1)
    tabSep:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, tabBarY - TAB_BAR_H)
    tabSep:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, tabBarY - TAB_BAR_H)
    tabSep:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 1)

    -- ── Tab content frames ────────────────────────────────────────────────────
    local CONTENT_TOP = tabBarY - TAB_BAR_H - 1

    local function makeTabFrame(name)
        local f = CreateFrame("Frame", nil, win)
        f:SetPoint("TOPLEFT",  win, "TOPLEFT",  0, CONTENT_TOP)
        f:SetWidth(WIN_W)
        f:SetHeight(1)
        tabContainers[name] = f
        return f
    end

    local display   = makeTabFrame("display")
    local customize = makeTabFrame("customize")

    local function sectionLabel(parent, text, yOff)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff)
        fs:SetText(col(C.gold, text))
        fs:SetWordWrap(false)
        return fs
    end

    local function divider(parent, yOff)
        local d = parent:CreateTexture(nil, "BACKGROUND")
        d:SetHeight(1)
        d:SetPoint("TOPLEFT",  parent, "TOPLEFT",  14, yOff)
        d:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff)
        d:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.5)
    end

    -- ── Display tab ───────────────────────────────────────────────────────────
    local dy = -10
    sectionLabel(display, "DISPLAY", dy); dy = dy - 18

    local _, hD1 = makeKCCheckbox(display, dy, "showMythThreshold", "Show Mythic Threshold"); dy = dy - hD1 - 6
    local _, hD2 = makeKCCheckbox(display, dy, "showSeasonEnd",     "Show Estimated Season End"); dy = dy - hD2 - 6
    local _, hD3 = makeKCCheckbox(display, dy, "showDungeonScores", "Show Dungeon Score Overlays",
        function() UpdateDungeonOverlays() end); dy = dy - hD3 - 6
    local _, hD4 = makeKCCheckbox(display, dy, "compactMode",       "Compact Mode"); dy = dy - hD4 - 6

    local _, hD5 = makeKCCheckboxCustom(display, dy, "Show Minimap Button",
        function()
            local m = KeystoneCutoffsDB and KeystoneCutoffsDB.minimap
            return not (m and m.hide)
        end,
        function(checked)
            KeystoneCutoffsDB.minimap = KeystoneCutoffsDB.minimap or {}
            KeystoneCutoffsDB.minimap.hide = not checked
        end,
        function() if UpdateMinimapButton then UpdateMinimapButton() end end)
    dy = dy - hD5 - 10

    divider(display, dy); dy = dy - 14
    sectionLabel(display, "POSITION", dy); dy = dy - 18

    local hDPos = makeKCDropdown(display, dy, "position", "Tooltip Position", {
        { value = "RIGHT",  label = "Right (below RIO)" },
        { value = "BOTTOM", label = "Bottom of window"  },
    }, function()
        -- Selecting a preset clears any user-dragged override.
        if KeystoneCutoffsDB then KeystoneCutoffsDB.panelPosition = nil end
    end)
    dy = dy - hDPos - 14

    display:SetHeight(math.abs(dy))

    -- ── Customize tab ─────────────────────────────────────────────────────────
    local cy2 = -10
    sectionLabel(customize, "OVERLAY TEXT", cy2); cy2 = cy2 - 18

    local hFont = makeKCFontDropdown(customize, cy2, "overlayFont", "Font",
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hFont - 12

    local hScoreSize = makeKCSlider(customize, cy2, "overlayScoreSize", "Score Size", 8, 28, 1,
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hScoreSize - 6

    local hTimeSize = makeKCSlider(customize, cy2, "overlayTimeSize", "Time Size", 6, 24, 1,
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hTimeSize - 10

    local hOutline = makeKCDropdown(customize, cy2, "overlayOutline", "Outline", {
        { value = "NONE",         label = "None"          },
        { value = "OUTLINE",      label = "Outline"       },
        { value = "THICKOUTLINE", label = "Thick Outline" },
        { value = "SHADOW",       label = "Shadow"        },
    }, function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hOutline - 14

    divider(customize, cy2); cy2 = cy2 - 14
    sectionLabel(customize, "PANEL POSITION", cy2); cy2 = cy2 - 18

    local hReset = makeKCButton(customize, cy2, "Reset Panel Position", function()
        if KeystoneCutoffsDB then KeystoneCutoffsDB.panelPosition = nil end
        PositionPanel()
    end)
    cy2 = cy2 - hReset - 8

    local hintFs = customize:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFs:SetPoint("TOPLEFT",  customize, "TOPLEFT",  14, cy2)
    hintFs:SetPoint("TOPRIGHT", customize, "TOPRIGHT", -14, cy2)
    hintFs:SetJustifyH("LEFT")
    hintFs:SetText("Tip: Shift+Left-drag the Keystone Cutoffs panel to reposition it.")
    hintFs:SetWordWrap(true)
    cy2 = cy2 - 32

    customize:SetHeight(math.abs(cy2))

    -- ── Window sizing + initial anchor ────────────────────────────────────────
    local contentH = math.max(display:GetHeight(), customize:GetHeight())
    win:SetSize(WIN_W, TITLE_H + 1 + TAB_BAR_H + 1 + contentH + 8)
    win:ClearAllPoints()
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    showTab("display")

    settingsWin = win
end

local function ToggleSettingsWindow()
    if not settingsWin then CreateSettingsWindow() end
    if settingsWin:IsShown() then
        settingsWin:Hide()
    else
        for _, fn in ipairs(settingsRefreshFns) do fn() end
        settingsWin:Show()
    end
end

-- ─── Panel helpers ────────────────────────────────────────────────────────────
local function createSplitRow(parent, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetTextColor(0.75, 0.75, 0.75, 1)

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)
    value:SetJustifyH("RIGHT")
    value:SetWordWrap(false)

    return label, value
end

local function wireTooltipHitbox(hitbox, title, body)
    local hi = hitbox:CreateTexture(nil, "ARTWORK")
    hi:SetAllPoints(hitbox)
    hi:SetColorTexture(1, 1, 1, 0.08)
    hi:Hide()
    hitbox._highlightTex = hi

    hitbox:EnableMouse(true)
    hitbox:SetScript("OnEnter", function(self)
        if self._highlightTex then self._highlightTex:Show() end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:SetText(title, 1, 0.82, 0)
        GameTooltip:AddLine(body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    hitbox:SetScript("OnLeave", function(self)
        if self._highlightTex then self._highlightTex:Hide() end
        GameTooltip:Hide()
    end)
end

local function addDataFrame(list, ...)
    for i = 1, select("#", ...) do
        local f = select(i, ...)
        if f then list[#list + 1] = f end
    end
end

-- ─── Panel construction ───────────────────────────────────────────────────────
local function CreatePanel()
    panel = CreateFrame("Frame", "KeystoneCutoffsPanel", ChallengesFrame, "TooltipBackdropTemplate")
    panel:SetParent(ChallengesFrame)
    panel:SetWidth(FRAME_WIDTH)
    panel:SetFrameStrata("MEDIUM")
    panel:SetFrameLevel(10)
    panel.collapsed = false

    -- Shift+drag to reposition the panel; position persists across sessions.
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Persist drag offsets relative to ChallengesFrame so the panel still
        -- follows Blizzard's UI panel push/stack behavior.
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            KeystoneCutoffsDB = KeystoneCutoffsDB or {}
            local cfRight = ChallengesFrame and ChallengesFrame:GetRight()
            local cfTop   = ChallengesFrame and ChallengesFrame:GetTop()

            if cfRight and cfTop then
                local xOff = math.floor((left - cfRight) + 0.5)
                local yOff = math.floor((top  - cfTop)   + 0.5)
                self:ClearAllPoints()
                self:SetPoint("TOPLEFT", ChallengesFrame, "TOPRIGHT", xOff, yOff)
                KeystoneCutoffsDB.panelPosition = {
                    point    = "TOPLEFT",
                    relTo    = "ChallengesFrame",
                    relPoint = "TOPRIGHT",
                    x        = xOff,
                    y        = yOff,
                }
            else
                -- Fallback for edge cases where ChallengesFrame geometry isn't available.
                self:ClearAllPoints()
                self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                KeystoneCutoffsDB.panelPosition = {
                    point    = "TOPLEFT",
                    relPoint = "BOTTOMLEFT",
                    x        = math.floor(left + 0.5),
                    y        = math.floor(top  + 0.5),
                }
            end
        end
    end)

    -- ── Collapse button ───────────────────────────────────────────────────────
    local collapseBtn = CreateFrame("Button", "KeystoneCutoffsCollapseBtn", panel)
    collapseBtn:SetSize(BTN_W, BTN_H)
    collapseBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    collapseBtn:RegisterForClicks("LeftButtonUp")
    collapseBtn:SetFrameLevel(panel:GetFrameLevel() + 5)
    panel.collapseBtn = collapseBtn

    -- Chevron icon: rotates to indicate state.
    -- Source texture points right; rotate +π/2 for up (open), -π/2 for down (closed).
    local collapseArrow = collapseBtn:CreateTexture(nil, "OVERLAY")
    collapseArrow:SetTexture("Interface\\AddOns\\KeystoneCutoffs\\Assets\\chevron_right.tga")
    collapseArrow:SetSize(18, 18)
    collapseArrow:SetPoint("CENTER")
    collapseArrow:SetVertexColor(0.85, 0.85, 0.85, 0.95)
    collapseArrow:SetRotation(math.pi / 2)   -- panel starts expanded → up
    collapseBtn.arrow = collapseArrow

    collapseBtn:SetScript("OnEnter", function()
        collapseArrow:SetVertexColor(1.00, 0.82, 0.00, 1.00)
    end)
    collapseBtn:SetScript("OnLeave", function()
        collapseArrow:SetVertexColor(0.85, 0.85, 0.85, 0.95)
    end)

    local y = -TOP_PAD

    -- ── Main title ────────────────────────────────────────────────────────────
    local sectionTracker = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sectionTracker:SetPoint("TOPLEFT",  panel, "TOPLEFT", PAD, y)
    sectionTracker:SetPoint("TOPRIGHT", collapseBtn, "TOPLEFT", -4, 0)
    sectionTracker:SetJustifyH("LEFT")
    sectionTracker:SetWordWrap(false)
    sectionTracker:SetText(col(C.gold, "Keystone Cutoffs"))
    y = y - MAIN_TITLE_H - SUBTITLE_GAP

    -- ── Subtitle ──────────────────────────────────────────────────────────────
    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT",  panel, "TOPLEFT", PAD, y)
    subtitle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - BTN_W, y)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetTextColor(0.65, 0.65, 0.65, 1)
    subtitle:SetWordWrap(false)
    panel.subtitle = subtitle
    y = y - SUBTITLE_H - AFTER_SUBTITLE

    -- ── Data rows (created at initial y; relayoutPanel repositions them) ──────
    local split = {}
    local dataFrames = {}

    split.gap01L,  split.gap01V  = createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.gap1L,   split.gap1V   = createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.mythL,   split.mythV   = createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.pctL,    split.pctV    = createSplitRow(panel, y); y = y - ROW_H - SECTION_GAP
    split.seasonL, split.seasonV = createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.updatedL,split.updatedV= createSplitRow(panel, y)

    panel.split = split

    addDataFrame(dataFrames,
        split.gap01L,  split.gap01V,
        split.gap1L,   split.gap1V,
        split.mythL,   split.mythV,
        split.pctL,    split.pctV,
        split.seasonL, split.seasonV,
        split.updatedL,split.updatedV
    )
    panel.dataFrames = dataFrames

    local tipLevel = panel:GetFrameLevel() + 20

    -- ── Tooltip hitboxes ──────────────────────────────────────────────────────
    local mythHit = CreateFrame("Frame", nil, panel)
    mythHit:SetPoint("TOPLEFT",     split.mythL, "TOPLEFT",     -4,  4)
    mythHit:SetPoint("BOTTOMRIGHT", split.mythV, "BOTTOMRIGHT",  4, -4)
    mythHit:SetFrameLevel(tipLevel)
    wireTooltipHitbox(mythHit, "Keystone Myth Achievement",
        "Upon reaching 3400 Mythic+ rating, players earn a Timelost Saddle to exchange for a curated mount selection. (New in Patch 12.0.5)")
    panel.mythTooltipHit = mythHit
    dataFrames[#dataFrames + 1] = mythHit

    local seasonHit = CreateFrame("Frame", nil, panel)
    seasonHit:SetPoint("TOPLEFT",     split.seasonL, "TOPLEFT",     -4,  4)
    seasonHit:SetPoint("BOTTOMRIGHT", split.seasonV, "BOTTOMRIGHT",  4, -4)
    seasonHit:SetFrameLevel(tipLevel)
    wireTooltipHitbox(seasonHit, "Estimated Season End",
        "Blizzard has not officially announced the end date. This is an estimate based on historical season lengths.")
    panel.seasonTooltipHit = seasonHit
    dataFrames[#dataFrames + 1] = seasonHit

    -- ── Collapse toggle ───────────────────────────────────────────────────────
    collapseBtn:SetScript("OnClick", function()
        panel.collapsed = not panel.collapsed
        if panel.collapsed then
            for _, f in ipairs(panel.dataFrames) do f:SetShown(false) end
            panel:SetHeight(COLLAPSED_HEIGHT)
            collapseArrow:SetRotation(-math.pi / 2)  -- closed → chevron down
        else
            collapseArrow:SetRotation(math.pi / 2)   -- open → chevron up
            UpdatePanel()
        end
    end)

    panel:Hide()
    PositionPanel()
end

-- ─── Panel positioning ────────────────────────────────────────────────────────
PositionPanel = function()
    if not panel then return end
    panel:ClearAllPoints()

    local db = KeystoneCutoffsDB or {}
    local custom = db.panelPosition
    if type(custom) == "table" and custom.point then
        -- New schema: anchor to ChallengesFrame so panel follows panel-push.
        if custom.relTo == "ChallengesFrame" and ChallengesFrame then
            panel:SetPoint(custom.point, ChallengesFrame, custom.relPoint or "TOPRIGHT",
                           custom.x or 0, custom.y or 0)
            return
        end
        -- Legacy schema from older builds used absolute UIParent anchoring
        -- (relPoint=BOTTOMLEFT), which breaks panel-push behavior. Migrate by
        -- clearing it once so default anchoring is restored automatically.
        if custom.relPoint == "BOTTOMLEFT" then
            db.panelPosition = nil
        else
            panel:SetPoint(custom.point, UIParent, custom.relPoint or custom.point,
                           custom.x or 0, custom.y or 0)
            return
        end
    end

    local pos = db.position or "RIGHT"
    if pos == "BOTTOM" then
        panel:SetPoint("TOPLEFT", ChallengesFrame, "BOTTOMLEFT", 0, -45)
    elseif RaiderIO_ProfileTooltip and RaiderIO_ProfileTooltip:IsShown() then
        panel:SetPoint("TOPLEFT", RaiderIO_ProfileTooltip, "BOTTOMLEFT", 0, -5)
    else
        panel:SetPoint("TOPLEFT", ChallengesFrame, "TOPRIGHT", 12, 0)
    end
end

-- ─── Region helper ────────────────────────────────────────────────────────────
local function GetRegion()
    local regionMap = { [1]="us", [2]="kr", [3]="eu", [4]="tw", [5]="us" }
    local id = GetCurrentRegionName and GetCurrentRegionName()
    if id then return string.lower(id) end
    return regionMap[GetCurrentRegion() or 3] or "eu"
end

-- ─── Dynamic panel relayout ───────────────────────────────────────────────────
-- Repositions all split-row FontStrings based on current DB settings,
-- shows/hides toggleable rows, and sets panel:SetHeight() accordingly.
-- Only runs when the panel is expanded.
local function relayoutPanel()
    if not panel or panel.collapsed then return end
    local db    = KeystoneCutoffsDB or {}
    local split = panel.split
    if not split then return end

    local compact = db.compactMode == true

    -- Starting y (below subtitle block). Compact mode hides the subtitle gap
    -- by pulling rows closer to the title.
    local headerBlock = MAIN_TITLE_H + SUBTITLE_GAP + SUBTITLE_H + AFTER_SUBTITLE
    if compact then headerBlock = MAIN_TITLE_H + AFTER_SUBTITLE end
    local y = -(TOP_PAD + headerBlock)

    if panel.subtitle then panel.subtitle:SetShown(not compact) end

    local function placeRow(L, V)
        L:SetShown(true); V:SetShown(true)
        L:ClearAllPoints(); L:SetPoint("TOPLEFT",  panel, "TOPLEFT",  PAD,  y)
        V:ClearAllPoints(); V:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y)
    end

    local function hideRow(L, V)
        L:SetShown(false); V:SetShown(false)
    end

    -- gap01 (always visible)
    placeRow(split.gap01L, split.gap01V); y = y - ROW_H - ROW_GAP

    -- gap1 (always visible)
    placeRow(split.gap1L, split.gap1V); y = y - ROW_H - ROW_GAP

    -- myth (toggleable)
    if db.showMythThreshold ~= false then
        placeRow(split.mythL, split.mythV)
        if panel.mythTooltipHit then panel.mythTooltipHit:Show() end
        y = y - ROW_H - ROW_GAP
    else
        hideRow(split.mythL, split.mythV)
        if panel.mythTooltipHit then panel.mythTooltipHit:Hide() end
    end

    if compact then
        -- In compact mode, stop here: hide everything below the cutoff block.
        hideRow(split.pctL,     split.pctV)
        hideRow(split.seasonL,  split.seasonV)
        hideRow(split.updatedL, split.updatedV)
        if panel.seasonTooltipHit then panel.seasonTooltipHit:Hide() end

        -- y is currently under the last visible cutoff row with ROW_GAP applied;
        -- snap it back to align the bottom padding.
        y = y + ROW_GAP

        local newH = math.ceil(-y + BOTTOM_PAD)
        panel.expandedHeight = newH
        panel:SetHeight(newH)
        return
    end

    -- pct (always visible when not compact)
    placeRow(split.pctL, split.pctV); y = y - ROW_H - SECTION_GAP

    -- season (toggleable)
    if db.showSeasonEnd ~= false then
        placeRow(split.seasonL, split.seasonV)
        if panel.seasonTooltipHit then panel.seasonTooltipHit:Show() end
        y = y - ROW_H - ROW_GAP
    else
        hideRow(split.seasonL, split.seasonV)
        if panel.seasonTooltipHit then panel.seasonTooltipHit:Hide() end
    end

    -- updated (always visible when not compact)
    placeRow(split.updatedL, split.updatedV)

    -- Dynamic height: y is at the top of updated row; bottom = y - ROW_H
    local newH = math.ceil(-y + ROW_H + BOTTOM_PAD)
    panel.expandedHeight = newH
    panel:SetHeight(newH)
end

-- ─── Panel update ─────────────────────────────────────────────────────────────
UpdatePanel = function()
    if not panel or not panel:IsShown() then return end
    PositionPanel()

    local split = panel.split
    if not split then return end
    local db = KeystoneCutoffsDB or {}

    local function showError(msg)
        split.gap01L:SetText(col(C.grey, "Status"))
        split.gap01V:SetText(col(C.grey, msg))
        for _, k in ipairs({ "gap1L","gap1V","mythL","mythV","pctL","pctV",
                              "seasonL","seasonV","updatedL","updatedV" }) do
            split[k]:SetText("")
        end
    end

    if not KeystoneCutoffsData then
        panel.subtitle:SetText("")
        showError("No cutoff data loaded.")
        relayoutPanel()
        return
    end

    local region     = GetRegion()
    local regionData = KeystoneCutoffsData.regions and KeystoneCutoffsData.regions[region]
    if not regionData then
        panel.subtitle:SetText("")
        showError("No data for region: " .. region)
        relayoutPanel()
        return
    end

    panel.subtitle:SetText(string.format("Keystone Cutoffs · %s · All", string.upper(region)))

    local pct  = regionData.percentiles or {}
    local p999 = pct["p999"] and pct["p999"].all
    local p990 = pct["p990"] and pct["p990"].all

    local myScore = 0
    if C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore then
        myScore = C_ChallengeMode.GetOverallDungeonScore() or 0
    end

    -- Top 0.1%: left = target context, right = actionable gap
    if p999 and p999.score then
        local gap01 = math.max(0, p999.score - myScore)
        split.gap01L:SetText(string.format("Top 0.1%% (%s)", fmt(p999.score)))
        split.gap01V:SetText(string.format("%s+ |r%s%s|r",
            C.white, scoreColorFor(p999.score), fmt(gap01)))
    else
        split.gap01L:SetText("Top 0.1% (—)")
        split.gap01V:SetText(col(C.grey, "—"))
    end

    -- Top 1%: left = target context, right = actionable gap
    if p990 and p990.score then
        local gap1 = math.max(0, p990.score - myScore)
        split.gap1L:SetText(string.format("Top 1%% (%s)", fmt(p990.score)))
        split.gap1V:SetText(string.format("%s+ |r%s%s|r",
            C.white, scoreColorFor(p990.score), fmt(gap1)))
    else
        split.gap1L:SetText("Top 1% (—)")
        split.gap1V:SetText(col(C.grey, "—"))
    end

    -- Keystone Myth threshold (toggleable)
    local titles = regionData.titles or {}
    local myth   = titles["keystoneMyth"]
    if myth and myth.fixedScore then
        local mythGap = math.max(0, myth.fixedScore - myScore)
        split.mythL:SetText(string.format("Keystone Myth (%s)", fmt(myth.fixedScore)))
        split.mythV:SetText(string.format("%s+ |r%s%s|r",
            C.white, scoreColorFor(myth.fixedScore), fmt(mythGap)))
    else
        split.mythL:SetText("Keystone Myth (—)")
        split.mythV:SetText(col(C.grey, "—"))
    end

    -- Estimated percentile
    local tierOrder = { "p999","p990","p900","p750","p600" }
    local tierLabel = { "0.1","1","10","25","40" }
    local myPercentile = "> 40%"
    for i, key in ipairs(tierOrder) do
        local t = pct[key] and pct[key].all
        if t and myScore >= t.score then
            myPercentile = "Top " .. tierLabel[i] .. "%"
            break
        end
    end
    split.pctL:SetText("Est. Percentile")
    split.pctV:SetText(col(scoreColorFor(myScore), myPercentile))

    -- Season end (toggleable)
    split.seasonL:SetText("Season Ends")
    split.seasonV:SetText(col(C.white, KeystoneCutoffsData.seasonEnd or "Unknown"))

    -- Cutoffs updated (with stale-data warning if > 7 days old)
    split.updatedL:SetText("Cutoffs Updated")
    local updated  = regionData.updatedAt or "Unknown"
    local dateOnly = updated:match("(%a+ %a+ %d+ %d+)") or updated:sub(1, 24)

    -- Compute age in days from ISO 8601 "YYYY-MM-DDTHH:MM:SS..." if present.
    local staleColor, staleSuffix = C.grey, ""
    local yy, mm, dd = updated:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if yy and mm and dd then
        local upTime = time({ year = tonumber(yy), month = tonumber(mm), day = tonumber(dd), hour = 12 })
        local days = (time() - upTime) / 86400
        if days > 7 then
            staleColor  = "|cFFCC5555"
            staleSuffix = " (stale)"
        end
    end
    split.updatedV:SetText(staleColor .. dateOnly .. staleSuffix .. "|r")

    relayoutPanel()
    UpdateDungeonOverlays()
end

-- ─── Dungeon score overlays ───────────────────────────────────────────────────
-- Approach ported from BigWigs (Tools/Keystones.lua) — the one reliable way.
-- Blizzard exposes the Season-Best badge frames directly on
-- `ChallengesFrame.DungeonIcons`, and each icon already carries `.mapID`.
-- Data is read via `C_MythicPlus.GetSeasonBestAffixScoreInfoForMap()` and
-- `C_MythicPlus.GetSeasonBestForMap()` (the official, always-available paths).
local hookedIcons = {}

--- Native Blizzard score-rarity color (what the game uses under the dungeon
--- icon by default). Returns `|cFFRRGGBB` wrapped around the numeric text.
--- Falls back to our own percentile gradient (`scoreColorFor`) if the API
--- isn't available — e.g. in very early addon loading or Classic clients.
local function nativeScoreColor(score)
    if C_ChallengeMode and C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor then
        local ok, color = pcall(C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor, score)
        if ok and color and color.r then
            return string.format("|cFF%02X%02X%02X",
                math.floor(color.r * 255 + 0.5),
                math.floor(color.g * 255 + 0.5),
                math.floor(color.b * 255 + 0.5))
        end
    end
    return scoreColorFor(score)
end

--- Resolve a font path via LibSharedMedia, with fallback to GameFontHighlight.
local function resolveFontPath(name)
    if type(name) == "string" and name ~= "" then
        local ok, LSM = pcall(function() return LibStub and LibStub("LibSharedMedia-3.0", true) end)
        if ok and LSM then
            local path = LSM:Fetch("font", name, true)
            if path then return path end
        end
    end
    return (GameFontHighlight:GetFont())
end

--- Translate DB overlay outline selection into a SetFont flag string.
--- "SHADOW" uses no outline flag (renderer draws a shadow via SetShadowOffset).
local function outlineFlag(mode)
    if mode == "OUTLINE" or mode == "THICKOUTLINE" then return mode end
    return ""
end

--- Apply current DB font/size/outline settings to a score/time pair.
local function applyOverlayStyle(ov)
    local db     = KeystoneCutoffsDB or {}
    local path   = resolveFontPath(db.overlayFont)
    local flag   = outlineFlag(db.overlayOutline)
    local shadow = (db.overlayOutline == "SHADOW")

    ov.score:SetFont(path, tonumber(db.overlayScoreSize) or 14, flag)
    ov.time:SetFont(path,  tonumber(db.overlayTimeSize)  or 11, flag)

    local sox, soy = shadow and 1 or 0, shadow and -1 or 0
    ov.score:SetShadowOffset(sox, soy); ov.score:SetShadowColor(0, 0, 0, shadow and 1 or 0)
    ov.time:SetShadowOffset(sox, soy);  ov.time:SetShadowColor(0, 0, 0, shadow and 1 or 0)
end

local function ensureOverlayFS(icon)
    if hookedIcons[icon] then
        applyOverlayStyle(hookedIcons[icon])
        return hookedIcons[icon]
    end

    local scoreTxt = icon:CreateFontString(nil, "OVERLAY")
    scoreTxt:SetJustifyH("CENTER")
    scoreTxt:SetPoint("BOTTOM", 0, 4)

    local timeTxt = icon:CreateFontString(nil, "OVERLAY")
    timeTxt:SetJustifyH("CENTER")
    timeTxt:SetPoint("BOTTOM", 0, 22)
    timeTxt:SetTextColor(1, 1, 1, 1)

    local ov = { score = scoreTxt, time = timeTxt }
    hookedIcons[icon] = ov
    applyOverlayStyle(ov)
    return ov
end

local function refreshDungeonOverlays()
    if not ChallengesFrame or not ChallengesFrame.DungeonIcons then return end

    local db   = KeystoneCutoffsDB or {}
    local show = db.showDungeonScores ~= false

    for i = 1, #ChallengesFrame.DungeonIcons do
        local icon = ChallengesFrame.DungeonIcons[i]
        if icon then
            local ov = ensureOverlayFS(icon)

            -- Re-anchor based on current time-size so the time label hugs the
            -- top of the score label instead of overlapping when sizes change.
            local timeBottom = math.max(18, (tonumber(db.overlayScoreSize) or 14) + 6)
            ov.time:ClearAllPoints()
            ov.time:SetPoint("BOTTOM", 0, timeBottom)

            ov.score:SetText("")
            ov.time:SetText("")

            if show and icon.mapID then
                local overAllScore
                if C_MythicPlus and C_MythicPlus.GetSeasonBestAffixScoreInfoForMap then
                    local ok, _, s = pcall(C_MythicPlus.GetSeasonBestAffixScoreInfoForMap, icon.mapID)
                    if ok then overAllScore = s end
                end

                local inTimeInfo, overtimeInfo
                if C_MythicPlus and C_MythicPlus.GetSeasonBestForMap then
                    local ok, a, b = pcall(C_MythicPlus.GetSeasonBestForMap, icon.mapID)
                    if ok then inTimeInfo, overtimeInfo = a, b end
                end

                local runInfo = inTimeInfo or overtimeInfo
                if overAllScore and runInfo then
                    ov.score:SetText(nativeScoreColor(overAllScore)
                        .. math.floor(overAllScore + 0.5) .. "|r")
                    local dur = tonumber(runInfo.durationSec or runInfo.duration)
                    if dur and dur > 0 then
                        ov.time:SetText(fmtTime(dur) or "")
                    end
                end
            end
        end
    end
end

--- Public entry point called by settings toggle and UpdatePanel.
UpdateDungeonOverlays = function()
    C_Timer.After(0, refreshDungeonOverlays)
end

-- ─── Minimap button (LibDataBroker + LibDBIcon) ───────────────────────────────
local minimapInitialized = false

local function InitializeMinimapButton()
    if minimapInitialized then return end

    local LDB  = LibStub and LibStub("LibDataBroker-1.1", true)
    local Icon = LibStub and LibStub("LibDBIcon-1.0",     true)
    if not LDB or not Icon then return end

    local dataObj = LDB:NewDataObject("KeystoneCutoffs", {
        type  = "launcher",
        text  = "Keystone Cutoffs",
        icon  = "Interface\\Icons\\inv_relics_hourglass",
        OnClick = function(_, button)
            if button == "RightButton" then
                if ToggleChallengesUI then
                    ToggleChallengesUI()
                end
            else
                ToggleSettingsWindow()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("|cFFFFD100Keystone Cutoffs|r")
            tt:AddLine("|cFFFFFFFFLeft-click:|r Open settings", 0.85, 0.85, 0.85)
            tt:AddLine("|cFFFFFFFFRight-click:|r Toggle Mythic+ Dungeons", 0.85, 0.85, 0.85)
        end,
    })

    KeystoneCutoffsDB.minimap = KeystoneCutoffsDB.minimap or { hide = false }
    Icon:Register("KeystoneCutoffs", dataObj, KeystoneCutoffsDB.minimap)
    minimapInitialized = true
end

UpdateMinimapButton = function()
    local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not Icon then return end
    if not minimapInitialized then InitializeMinimapButton() end
    if KeystoneCutoffsDB.minimap and KeystoneCutoffsDB.minimap.hide then
        Icon:Hide("KeystoneCutoffs")
    else
        Icon:Show("KeystoneCutoffs")
    end
end

-- ─── Visibility hooks ─────────────────────────────────────────────────────────
local function OnChallengesFrameShow()
    if panel then
        panel:Show()
        UpdatePanel()   -- calls UpdateDungeonOverlays at the end
    end
end

local function OnChallengesFrameHide()
    if panel then panel:Hide() end
end

-- ─── Initialization ───────────────────────────────────────────────────────────
local dataReady = false
local uiReady   = false

local function InitializeUI()
    CreatePanel()

    hooksecurefunc(ChallengesFrame, "Show", OnChallengesFrameShow)
    hooksecurefunc(ChallengesFrame, "Hide", OnChallengesFrameHide)

    -- OnShow fires after Blizzard has built `ChallengesFrame.DungeonIcons`
    -- and populated each icon.mapID, which is exactly what we need.
    ChallengesFrame:HookScript("OnShow", function()
        C_Timer.After(0, refreshDungeonOverlays)
    end)

    if ChallengesFrame:IsShown() then OnChallengesFrameShow() end

    local updater = CreateFrame("Frame")
    for _, ev in ipairs({
        "CHALLENGE_MODE_MAPS_UPDATE",
        "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
        "PLAYER_ENTERING_WORLD",
    }) do
        updater:RegisterEvent(ev)
    end
    updater:SetScript("OnEvent", function()
        UpdatePanel()
        UpdateDungeonOverlays()
    end)
end

local function TryInitialize()
    if dataReady and uiReady then
        refreshScorePalette()
        InitializeUI()
    end
end

-- ─── Event frame ──────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)

    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")

        if type(KeystoneCutoffsDB) ~= "table" then
            KeystoneCutoffsDB = {}
        end
        -- Copy defaults; clone table values so we don't share references with DB_DEFAULTS.
        for k, v in pairs(DB_DEFAULTS) do
            if KeystoneCutoffsDB[k] == nil then
                if type(v) == "table" then
                    local copy = {}
                    for kk, vv in pairs(v) do copy[kk] = vv end
                    KeystoneCutoffsDB[k] = copy
                else
                    KeystoneCutoffsDB[k] = v
                end
            end
        end

        if not KeystoneCutoffsData then
            print("|cFFFF0000[KeystoneCutoffs]|r CutoffData not found – did CutoffData.lua load?")
            return
        end

        -- Minimap button is independent of ChallengesUI and can register immediately.
        InitializeMinimapButton()
        UpdateMinimapButton()

        dataReady = true
        TryInitialize()

    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_ChallengesUI" then
        self:UnregisterEvent("ADDON_LOADED")
        uiReady = true
        TryInitialize()
    end
end)

-- ─── Slash commands ───────────────────────────────────────────────────────────
SLASH_KEYSTONECUTOFFS1 = "/kc"
SLASH_KEYSTONECUTOFFS2 = "/keystonecutoffs"
SlashCmdList["KEYSTONECUTOFFS"] = function()
    ToggleSettingsWindow()
end
