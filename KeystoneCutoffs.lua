-- KeystoneCutoffs.lua
-- Core addon logic: reads CutoffData.lua and attaches a Raider.io-inspired
-- side tooltip to ChallengesFrame.
-- Author : Xtendr
-- License: MIT

local ADDON_NAME = "KeystoneCutoffs"
local CURRENT_NEWS_ID = "optional-progression-update-2026-08-26"

-- ─── Saved-variable defaults ──────────────────────────────────────────────────
local DB_DEFAULTS = {
    -- Display
    showMythThreshold = true,
    showSeasonEnd     = true,
    showDungeonScores = true,
    showDungeonPace   = false,
    compactMode       = false,
    collapsed         = false,
    position          = "RIGHT",   -- "RIGHT" | "BOTTOM"
    dataRegion        = "auto",    -- "auto" | "eu" | "us" | "kr" | "tw"
    dataFaction       = "all",     -- "all" | "horde" | "alliance"
    standaloneMode    = false,
    panelScale        = 100,
    panelOpacity      = 100,
    -- Optional progression features (all deliberately disabled by default)
    goalMode          = false,
    goalTarget        = "title",   -- title | top1 | myth | legend | hero | master | custom
    goalCustomScore   = 3000,
    showCutoffMovement= false,
    showWeakestDungeon= false,
    trackCharacters   = false,
    -- Customize (dungeon score overlays)
    overlayFont       = "Friz Quadrata TT",
    overlayScoreSize  = 14,
    overlayTimeSize   = 11,
    overlayOutline    = "OUTLINE", -- "NONE" | "OUTLINE" | "THICKOUTLINE" | "SHADOW"
    -- Persistence
    panelPosition     = nil,       -- { point, relPoint, x, y } when user drags panel
    standalonePosition= nil,       -- UIParent-relative position for standalone mode
    minimap           = { hide = false },
    cutoffHistory     = {},        -- opt-in, bounded previous data snapshots by region/faction
    characterSnapshots = {},       -- opt-in account character summaries
    lastSeenNews      = "",        -- Stable announcement ID; independent of daily data tags
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

-- ─── Season dungeon list (challenge mode IDs + display info) ─────────────────
-- challengeModeID = icon.mapID used by C_MythicPlus.GetSeasonBestForMap().
-- Fallback pool is Midnight Season 2 (patch 12.1). refreshSeasonDungeons()
-- overwrites these in place from C_ChallengeMode.GetMapTable() so the pace
-- rows follow the live keystone rotation without a code change next season.
-- Short names match Raider.IO's locale-independent abbreviations.
local DUNGEON_SHORT_NAMES = {
    -- Midnight Season 2
    [588] = "AOF",  -- Altar of Fangs
    [586] = "DON",  -- Den of Nalorakk
    [587] = "MR",   -- Murder Row
    [584] = "BV",   -- The Blinding Vale
    [585] = "VSA",  -- Voidscar Arena
    [249] = "KR",   -- Kings' Rest
    [399] = "RLP",  -- Ruby Life Pools
    [250] = "TOS",  -- Temple of Sethraliss
    -- Midnight Season 1 (kept so a delayed client still labels correctly)
    [161] = "SR",   -- Skyreach
    [239] = "SEAT", -- Seat of the Triumvirate
    [402] = "AA",   -- Algeth'ar Academy
    [559] = "NPX",  -- Nexus-Point Xenas
    [556] = "POS",  -- Pit of Saron
    [560] = "MC",   -- Maisara Caverns
    [558] = "MT",   -- Magisters' Terrace
    [557] = "WS",   -- Windrunner Spire
}

local DUNGEON_PACE_DATA = {
    { mapID = 588, short = "AOF", name = "Altar of Fangs"       },
    { mapID = 586, short = "DON", name = "Den of Nalorakk"      },
    { mapID = 587, short = "MR",  name = "Murder Row"           },
    { mapID = 584, short = "BV",  name = "The Blinding Vale"    },
    { mapID = 585, short = "VSA", name = "Voidscar Arena"       },
    { mapID = 249, short = "KR",  name = "Kings' Rest"          },
    { mapID = 399, short = "RLP", name = "Ruby Life Pools"      },
    { mapID = 250, short = "TOS", name = "Temple of Sethraliss" },
}

local function deriveShortName(name)
    if type(name) ~= "string" or name == "" then return "?" end
    local parts = {}
    for word in string.gmatch(name, "%S+") do
        local lower = string.lower(word)
        if lower ~= "the" and lower ~= "of" then
            parts[#parts + 1] = string.upper(string.sub(word, 1, 1))
        end
    end
    if #parts == 0 then
        return string.upper(string.sub(name, 1, 3))
    end
    local short = table.concat(parts)
    if #short > 4 then short = string.sub(short, 1, 4) end
    return short
end

local function refreshSeasonDungeons()
    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return end
    local ok, maps = pcall(C_ChallengeMode.GetMapTable)
    if not ok or type(maps) ~= "table" or #maps == 0 then return end

    for i, mapID in ipairs(maps) do
        local name
        if C_ChallengeMode.GetMapUIInfo then
            local infoOk, mapName = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
            if infoOk and type(mapName) == "string" and mapName ~= "" then
                name = mapName
            end
        end
        local entry = DUNGEON_PACE_DATA[i]
        if not entry then
            entry = {}
            DUNGEON_PACE_DATA[i] = entry
        end
        entry.mapID = mapID
        entry.name  = name or entry.name or ("Map " .. tostring(mapID))
        entry.short = DUNGEON_SHORT_NAMES[mapID] or deriveShortName(entry.name)
    end
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
local getDungeonBenchmark
local ApplyPanelPresentation
local ShowAdvancedDetails
local GetDataRegion

local GOAL_OPTIONS = {
    { value = "title",  label = "Top 0.1% title" },
    { value = "top1",   label = "Top 1%" },
    { value = "myth",   label = "Keystone Myth" },
    { value = "legend", label = "Keystone Legend" },
    { value = "hero",   label = "Keystone Hero" },
    { value = "master", label = "Keystone Master" },
    { value = "custom", label = "Custom score" },
}

local function getDataFaction()
    local faction = (KeystoneCutoffsDB and KeystoneCutoffsDB.dataFaction) or "all"
    if faction ~= "horde" and faction ~= "alliance" then return "all" end
    return faction
end

local function getPercentileEntry(pct, key)
    local group = pct and pct[key]
    if type(group) ~= "table" then return nil end
    return group[getDataFaction()] or group.all
end

local function getGoalTarget(regionData)
    local db = KeystoneCutoffsDB or {}
    local key = db.goalTarget or "title"
    local pct = regionData and regionData.percentiles or {}
    local titles = regionData and regionData.titles or {}

    if key == "title" then
        local entry = getPercentileEntry(pct, "p999")
        return "Top 0.1%", entry and entry.score
    elseif key == "top1" then
        local entry = getPercentileEntry(pct, "p990")
        return "Top 1%", entry and entry.score
    elseif key == "custom" then
        return "Custom", tonumber(db.goalCustomScore)
    end

    local titleKeys = {
        myth = { "Keystone Myth", "keystoneMyth" },
        legend = { "Keystone Legend", "keystoneLegend" },
        hero = { "Keystone Hero", "keystoneHero" },
        master = { "Keystone Master", "keystoneMaster" },
    }
    local info = titleKeys[key]
    local entry = info and titles[info[2]]
    return info and info[1] or "Goal", entry and entry.fixedScore
end

local function formatGoalDifference(target, current)
    if type(target) ~= "number" or type(current) ~= "number" then
        return col(C.grey, "—")
    end
    local delta = target - current
    if math.abs(delta) < 0.05 then return col(C.gold, "At goal") end
    if delta > 0 then return col(scoreColorFor(target), "Need " .. fmt(delta)) end
    return "|cFF44FF44Ahead " .. fmt(-delta) .. "|r"
end

local function recordOptionalSnapshots(region, regionData, myScore)
    local db = KeystoneCutoffsDB or {}
    local faction = getDataFaction()

    if db.showCutoffMovement then
        db.cutoffHistory = type(db.cutoffHistory) == "table" and db.cutoffHistory or {}
        local historyKey = region .. ":" .. faction
        local history = type(db.cutoffHistory[historyKey]) == "table" and db.cutoffHistory[historyKey] or {}
        db.cutoffHistory[historyKey] = history
        local entry = getPercentileEntry(regionData and regionData.percentiles, "p999")
        local snapshotID = regionData and regionData.updatedAt
        if entry and entry.score and snapshotID and (#history == 0 or history[#history].id ~= snapshotID) then
            history[#history + 1] = { id = snapshotID, score = entry.score }
            while #history > 8 do table.remove(history, 1) end
        end
    end

    if db.trackCharacters then
        db.characterSnapshots = type(db.characterSnapshots) == "table" and db.characterSnapshots or {}
        local name, realm = UnitName("player")
        realm = realm or GetRealmName() or ""
        if name then
            local _, classToken = UnitClass("player")
            local key = name .. "-" .. realm
            db.characterSnapshots[key] = {
                name = name,
                realm = realm,
                class = classToken,
                score = tonumber(myScore) or 0,
                region = region,
                updatedAt = regionData and regionData.updatedAt or "Unknown",
            }
        end
    end
end

local function getCutoffMovement(region)
    local db = KeystoneCutoffsDB or {}
    local history = db.cutoffHistory and db.cutoffHistory[region .. ":" .. getDataFaction()]
    if type(history) ~= "table" or #history < 2 then return nil end
    local previous, current = history[#history - 1], history[#history]
    if type(previous.score) ~= "number" or type(current.score) ~= "number" then return nil end
    return current.score - previous.score
end

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

local function addHelpButton(parent, anchor, titleText, bodyText)
    if not bodyText or bodyText == "" then return nil end
    local help = CreateFrame("Button", nil, parent)
    help:SetSize(16, 16)
    help:SetPoint(unpack(anchor))

    local text = help:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", 0, 0)
    text:SetText("?")
    text:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])

    help:SetScript("OnEnter", function(self)
        text:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(titleText or "Keystone Cutoffs", 1, 0.82, 0)
        GameTooltip:AddLine(bodyText, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    help:SetScript("OnLeave", function()
        text:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])
        GameTooltip:Hide()
    end)
    return help
end

local settingsWin
local settingsRefreshFns = {}
local whatsNewWin
local advancedDetailsWin

local function IsAddonLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(name)
    end
    if IsAddOnLoaded then
        return IsAddOnLoaded(name)
    end
    return false
end

local function MarkCurrentNewsSeen()
    if KeystoneCutoffsDB then
        KeystoneCutoffsDB.lastSeenNews = CURRENT_NEWS_ID
    end
end

local function CreateWhatsNewWindow()
    if whatsNewWin then return end

    local WIN_W = 520
    local win = CreateFrame("Frame", "KCWhatsNewFrame", UIParent, "BackdropTemplate")
    win:SetWidth(WIN_W)
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    mixBD(win)
    win:SetBackdrop(BD_EDGE)
    win:SetBackdropColor(ST.bg[1], ST.bg[2], ST.bg[3], ST.bg[4])
    win:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 1)
    win:Hide()
    tinsert(UISpecialFrames, "KCWhatsNewFrame")

    local TITLE_H = 32
    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetFrameLevel(win:GetFrameLevel() + 3)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(ST.surface[1], ST.surface[2], ST.surface[3], 1)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 12, 0)
    title:SetText(col(C.gold, "What's New in Keystone Cutoffs"))
    title:SetWordWrap(false)

    local closeBtn = CreateFrame("Button", nil, win, "BackdropTemplate")
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
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

    local titleSep = win:CreateTexture(nil, "BACKGROUND")
    titleSep:SetHeight(1)
    titleSep:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -TITLE_H)
    titleSep:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -TITLE_H)
    titleSep:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 1)

    local versionBand = CreateFrame("Frame", nil, win)
    versionBand:SetHeight(34)
    versionBand:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -46)
    versionBand:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -46)

    local versionFill = versionBand:CreateTexture(nil, "BACKGROUND")
    versionFill:SetAllPoints()
    versionFill:SetColorTexture(ST.accent[1], ST.accent[2], ST.accent[3], 0.12)

    local versionLine = versionBand:CreateTexture(nil, "ARTWORK")
    versionLine:SetHeight(2)
    versionLine:SetPoint("BOTTOMLEFT")
    versionLine:SetPoint("BOTTOMRIGHT")
    versionLine:SetColorTexture(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)

    local versionText = versionBand:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    versionText:SetPoint("LEFT", 12, 1)
    versionText:SetText(col(C.white, "v1.3.0"))

    local intro = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", win, "TOPLEFT", 18, -94)
    intro:SetPoint("TOPRIGHT", win, "TOPRIGHT", -18, -94)
    intro:SetJustifyH("LEFT")
    intro:SetWordWrap(true)
    intro:SetText("All new progression and history features are optional and disabled by default.")
    intro:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])

    local function CreateNewsSection(text, yOffset)
        local heading = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heading:SetPoint("TOPLEFT", win, "TOPLEFT", 16, yOffset)
        heading:SetText(col(C.gold, string.upper(text)))

        local line = win:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", win, "TOPLEFT", 16, yOffset - 21)
        line:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, yOffset - 21)
        line:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.75)
        return heading, line
    end

    local function CreateNewsRow(category, body, yOffset)
        local dot = win:CreateTexture(nil, "ARTWORK")
        dot:SetSize(4, 4)
        dot:SetPoint("TOPLEFT", win, "TOPLEFT", 22, yOffset - 7)
        dot:SetColorTexture(ST.accent[1], ST.accent[2], ST.accent[3], 0.8)

        local categoryText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        categoryText:SetPoint("TOPLEFT", win, "TOPLEFT", 34, yOffset)
        categoryText:SetPoint("TOPRIGHT", win, "TOPRIGHT", -18, yOffset)
        categoryText:SetJustifyH("LEFT")
        categoryText:SetText(col(C.gold, string.upper(category)))

        local bodyText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bodyText:SetPoint("TOPLEFT", win, "TOPLEFT", 34, yOffset - 17)
        bodyText:SetPoint("TOPRIGHT", win, "TOPRIGHT", -18, yOffset - 17)
        bodyText:SetJustifyH("LEFT")
        bodyText:SetJustifyV("TOP")
        bodyText:SetWordWrap(true)
        bodyText:SetSpacing(2)
        bodyText:SetText(body)
        bodyText:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3])
        return dot, categoryText, bodyText
    end

    CreateNewsSection("New & Improved", -126)
    CreateNewsRow(
        "Goals & Progress",
        "Choose a focused percentile, achievement, or custom rating goal.",
        -160
    )
    CreateNewsRow(
        "Goal Status",
        "See whether your current score is Need, Ahead, or At Goal.",
        -205
    )
    CreateNewsRow(
        "Optional Insights",
        "Track cutoff movement, your weakest dungeon, and character scores.",
        -250
    )
    CreateNewsRow(
        "Detailed Ladder View",
        "Compare percentile cutoffs, achievements, populations, characters, and regions.",
        -295
    )
    CreateNewsRow(
        "Display & Settings",
        "Use standalone positioning, scale, opacity, persistent appearance, and focused help.",
        -340
    )

    local companionHeading, companionLine = CreateNewsSection("Optional Integration", -390)
    local companionDot, companionCategory, companionBody = CreateNewsRow(
        "Keystone Meta",
        "Supports companion placement when both addons are enabled.",
        -424
    )

    local footerSep = win:CreateTexture(nil, "BACKGROUND")
    footerSep:SetHeight(1)
    footerSep:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 48)
    footerSep:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 48)
    footerSep:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.7)

    local feedbackBody = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    feedbackBody:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 17)
    feedbackBody:SetText(col(C.gold, "Found a bug?") .. " Please leave a comment on our CurseForge page.")

    local gotIt = CreateFrame("Button", nil, win, "BackdropTemplate")
    gotIt:SetSize(90, 24)
    gotIt:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 12)
    mixBD(gotIt)
    gotIt:SetBackdrop(BD_EDGE)
    gotIt:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    gotIt:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)

    local gotItText = gotIt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gotItText:SetPoint("CENTER")
    gotItText:SetText("Got it")
    gotItText:SetTextColor(ST.text[1], ST.text[2], ST.text[3])

    gotIt:SetScript("OnEnter", function()
        gotIt:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
        gotItText:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])
    end)
    gotIt:SetScript("OnLeave", function()
        gotIt:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)
        gotItText:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    end)
    gotIt:SetScript("OnClick", function()
        win:Hide()
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)

    local function refreshContent()
        local showCompanion = IsAddonLoaded("KeystoneMeta")
        companionHeading:SetShown(showCompanion)
        companionLine:SetShown(showCompanion)
        companionDot:SetShown(showCompanion)
        companionCategory:SetShown(showCompanion)
        companionBody:SetShown(showCompanion)
        win:SetHeight(showCompanion and 510 or 430)
    end

    win:SetScript("OnShow", function(self)
        refreshContent()
        self._kcNewsWasShown = true
    end)
    win:SetScript("OnHide", function(self)
        if self._kcNewsWasShown then
            self._kcNewsWasShown = false
            MarkCurrentNewsSeen()
        end
    end)

    win.refreshContent = refreshContent
    whatsNewWin = win
end

local function ShowWhatsNewWindow()
    if not whatsNewWin then CreateWhatsNewWindow() end
    if whatsNewWin.refreshContent then whatsNewWin.refreshContent() end
    whatsNewWin:Show()
    whatsNewWin:Raise()
end

local function MaybeShowCurrentNews()
    if not KeystoneCutoffsDB then return end
    if KeystoneCutoffsDB.lastSeenNews == CURRENT_NEWS_ID then return end
    if whatsNewWin and whatsNewWin:IsShown() then return end
    ShowWhatsNewWindow()
end

local function CreateAdvancedDetailsWindow()
    if advancedDetailsWin then return end

    local win = CreateFrame("Frame", "KCAdvancedDetailsFrame", UIParent, "BackdropTemplate")
    win:SetSize(430, 470)
    win:SetPoint("CENTER", UIParent, "CENTER", 220, 20)
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
    tinsert(UISpecialFrames, "KCAdvancedDetailsFrame")

    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")
    titleBar:SetHeight(32)
    titleBar:SetFrameLevel(win:GetFrameLevel() + 3)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(ST.surface[1], ST.surface[2], ST.surface[3], 1)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 12, 0)
    title:SetText(col(C.gold, "Keystone Cutoffs") .. " |cFF777777— Details|r")

    local close = CreateFrame("Button", nil, win, "BackdropTemplate")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetFrameLevel(win:GetFrameLevel() + 10)
    mixBD(close)
    close:SetBackdrop(BD_EDGE)
    close:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    close:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.5)
    local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeText:SetPoint("CENTER", 0, -1)
    closeText:SetText("×")
    close:SetScript("OnClick", function() win:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -46)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local scrollBar = scroll.ScrollBar
    if scrollBar then
        if scrollBar.ThumbTexture then
            scrollBar.ThumbTexture:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.8)
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
    content:SetSize(370, 1)
    scroll:SetScrollChild(content)
    local rowPool = {}

    local function acquireRow(index)
        local row = rowPool[index]
        if row then row:Show(); return row end
        row = CreateFrame("Frame", nil, content)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", 0, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("RIGHT", 0, 0)
        row.value:SetJustifyH("RIGHT")
        row.value:SetWordWrap(false)
        row.label:SetPoint("RIGHT", row.value, "LEFT", -12, 0)
        row.rule = row:CreateTexture(nil, "BACKGROUND")
        row.rule:SetHeight(1)
        row.rule:SetPoint("BOTTOMLEFT")
        row.rule:SetPoint("BOTTOMRIGHT")
        row.rule:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.45)
        rowPool[index] = row
        return row
    end

    local function refresh()
        for _, row in ipairs(rowPool) do row:Hide() end
        local rowIndex, y = 0, 0

        local function nextRow(height)
            rowIndex = rowIndex + 1
            local row = acquireRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
            row:SetHeight(height)
            row.label:ClearAllPoints()
            row.value:ClearAllPoints()
            row.label:SetPoint("LEFT", 0, 0)
            row.value:SetPoint("RIGHT", 0, 0)
            row.label:SetPoint("RIGHT", row.value, "LEFT", -12, 0)
            row.label:SetWordWrap(false)
            row.value:SetWordWrap(false)
            row.rule:Hide()
            y = y - height
            return row
        end

        local function addSection(text)
            if rowIndex > 0 then y = y - 9 end
            local row = nextRow(23)
            row.label:SetFontObject(GameFontNormal)
            row.label:SetText(text)
            row.label:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])
            row.value:SetText("")
            row.rule:Show()
        end

        local function addRow(labelText, valueText, valueMuted)
            local row = nextRow(18)
            row.label:SetFontObject(GameFontHighlightSmall)
            row.value:SetFontObject(GameFontHighlightSmall)
            row.label:SetText(labelText)
            row.value:SetText(valueText or "—")
            row.label:SetTextColor(0.70, 0.70, 0.70, 1)
            if valueMuted then
                row.value:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3], 1)
            else
                row.value:SetTextColor(ST.text[1], ST.text[2], ST.text[3], 1)
            end
        end

        local function addParagraph(text)
            local row = nextRow(20)
            row.value:SetText("")
            row.label:ClearAllPoints()
            row.label:SetPoint("TOPLEFT", 0, -2)
            row.label:SetPoint("TOPRIGHT", 0, -2)
            row.label:SetFontObject(GameFontDisableSmall)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(true)
            row.label:SetText(text)
            row.label:SetTextColor(ST.muted[1], ST.muted[2], ST.muted[3], 1)
            local height = math.max(20, row.label:GetStringHeight() + 6)
            row:SetHeight(height)
            y = y - (height - 20)
        end

        local function populationText(value)
            if type(value) == "number" and BreakUpLargeNumbers then
                return BreakUpLargeNumbers(value)
            end
            return tostring(value or "—")
        end

        local region = GetDataRegion and GetDataRegion() or "eu"
        local regionData = KeystoneCutoffsData and KeystoneCutoffsData.regions
            and KeystoneCutoffsData.regions[region]
        local faction = getDataFaction()
        local factionLabel = faction == "all" and "All players"
            or (faction == "horde" and "Horde" or "Alliance")

        addSection("Overview")
        addRow("Region", string.upper(region))
        addRow("Ladder", factionLabel)
        if not regionData then
            addParagraph("No cutoff data is available for this selection.")
        else
            local score = C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore
                and C_ChallengeMode.GetOverallDungeonScore() or 0
            addRow("Current character score", fmt(score))
            addRow("Data updated", regionData.updatedAt or "Unknown", true)

            addSection("Percentile cutoffs")
            for _, item in ipairs({
                { "Top 0.1%", "p999" }, { "Top 1%", "p990" },
                { "Top 10%", "p900" }, { "Top 25%", "p750" }, { "Top 40%", "p600" },
            }) do
                local entry = getPercentileEntry(regionData.percentiles, item[2])
                if entry and entry.score then
                    addRow(item[1], fmt(entry.score) .. "  ·  "
                        .. populationText(entry.population) .. " players")
                end
            end

            addSection("Achievement goals")
            for _, item in ipairs({
                { "Keystone Myth", "keystoneMyth" }, { "Keystone Legend", "keystoneLegend" },
                { "Keystone Hero", "keystoneHero" }, { "Keystone Master", "keystoneMaster" },
                { "Keystone Conqueror", "keystoneConqueror" }, { "Keystone Explorer", "keystoneExplorer" },
            }) do
                local entry = regionData.titles and regionData.titles[item[2]]
                if entry and entry.fixedScore then
                    addRow(item[1], fmt(entry.fixedScore))
                end
            end
        end

        local snapshots = KeystoneCutoffsDB and KeystoneCutoffsDB.characterSnapshots
        local characters = {}
        if type(snapshots) == "table" then
            for _, snapshot in pairs(snapshots) do characters[#characters + 1] = snapshot end
            table.sort(characters, function(a, b) return (a.score or 0) > (b.score or 0) end)
        end
        addSection("Tracked characters")
        if #characters == 0 then
            addParagraph("Character tracking is off or no characters have been recorded yet.")
        else
            for i = 1, math.min(#characters, 12) do
                local char = characters[i]
                local charName = (char.name or "?")
                    .. (char.realm and char.realm ~= "" and ("-" .. char.realm) or "")
                addRow(charName, fmt(char.score or 0) .. "  ·  " .. string.upper(char.region or "?"))
            end
            if #characters > 12 then addParagraph(string.format("...and %d more", #characters - 12)) end
        end

        y = y - 10
        addParagraph("Cutoff movement compares bundled data releases seen while the option is enabled. Character scores are last-known snapshots, not live cross-character data.")
        content:SetHeight(math.max(1, -y + 8))
    end

    win.refresh = refresh
    advancedDetailsWin = win
end

ShowAdvancedDetails = function()
    if not advancedDetailsWin then CreateAdvancedDetailsWindow() end
    if advancedDetailsWin.refresh then advancedDetailsWin.refresh() end
    advancedDetailsWin:Show()
    advancedDetailsWin:Raise()
end

-- Build and return a checkbox row Frame.
-- dbKey  = KeystoneCutoffsDB key (boolean)
-- label  = display text
-- onToggle = optional extra callback
local function makeKCCheckbox(parent, yOff, dbKey, labelText, onToggle, helpText)
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
    addHelpButton(row, { "RIGHT", row, "RIGHT", 0, 0 }, labelText, helpText)

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
local function makeKCDropdown(parent, yOff, dbKey, labelText, opts, extraCb, helpText)
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
    addHelpButton(parent, { "RIGHT", ddBtn, "LEFT", -6, 0 }, labelText, helpText)

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
local function makeKCSlider(parent, yOff, dbKey, labelText, minVal, maxVal, step, extraCb, helpText)
    local ROW_H_S   = 24
    local TRACK_H   = 10
    local THUMB_W   = 10
    local THUMB_H   = 16
    local LABEL_W   = 78
    local VALUE_W   = 46
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
    addHelpButton(row, { "LEFT", row, "LEFT", LABEL_W - 12, 0 }, labelText, helpText)

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
local function makeKCButton(parent, yOff, labelText, onClick, helpText)
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
    addHelpButton(btn, { "RIGHT", btn, "RIGHT", -6, 0 }, labelText, helpText)

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
local function makeKCFontDropdown(parent, yOff, dbKey, labelText, extraCb, helpText)
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
    addHelpButton(parent, { "RIGHT", ddBtn, "LEFT", -6, 0 }, labelText, helpText)

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
local function makeKCCheckboxCustom(parent, yOff, labelText, getFn, setFn, onToggle, helpText)
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
    addHelpButton(row, { "RIGHT", row, "RIGHT", 0, 0 }, labelText, helpText)

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

    local WIN_W = 420

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
        b:SetSize(96, TAB_BAR_H)
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

    makeTabButton("display",   "Display",    10)
    makeTabButton("goals",     "Goals",     111)
    makeTabButton("customize", "Customize", 212)
    makeTabButton("advanced",  "Advanced",  313)

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
    local goals     = makeTabFrame("goals")
    local customize = makeTabFrame("customize")
    local advanced  = makeTabFrame("advanced")

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

    local function introText(parent, text, yOff)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yOff)
        fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, yOff)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetText(text)
        return 28
    end

    -- ── Display tab ───────────────────────────────────────────────────────────
    local dy = -10
    dy = dy - introText(display,
        "Keep the familiar dashboard, then enable only the sections you want.", dy) - 6
    sectionLabel(display, "PANEL CONTENT", dy); dy = dy - 18

    local _, hD1 = makeKCCheckbox(display, dy, "showMythThreshold", "Show Mythic Threshold")
    dy = dy - hD1 - 6
    local _, hD2 = makeKCCheckbox(display, dy, "showSeasonEnd", "Show Season End")
    dy = dy - hD2 - 6
    local _, hD3 = makeKCCheckbox(display, dy, "showDungeonScores", "Show Dungeon Score Overlays",
        function() UpdateDungeonOverlays() end)
    dy = dy - hD3 - 6
    local _, hD4 = makeKCCheckbox(display, dy, "showDungeonPace", "Show Dungeon Pace")
    dy = dy - hD4 - 6
    local _, hD5cb = makeKCCheckbox(display, dy, "compactMode", "Compact Mode")
    dy = dy - hD5cb - 6

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
    sectionLabel(display, "REGION & PLACEMENT", dy); dy = dy - 18

    local hDRegion = makeKCDropdown(display, dy, "dataRegion", "Region", {
        { value = "auto", label = "Auto-detect" }, { value = "eu", label = "EU" },
        { value = "us", label = "US" }, { value = "kr", label = "KR" }, { value = "tw", label = "TW" },
    }, function() UpdatePanel() end)
    dy = dy - hDRegion - 8

    local hDPos = makeKCDropdown(display, dy, "position", "Panel Position", {
        { value = "RIGHT", label = "Right (below RIO)" },
        { value = "BOTTOM", label = "Bottom of window" },
    }, function()
        if KeystoneCutoffsDB then KeystoneCutoffsDB.panelPosition = nil end
    end)
    dy = dy - hDPos - 8

    local _, hStandalone = makeKCCheckbox(display, dy, "standaloneMode", "Standalone Panel",
        function()
            if KeystoneCutoffsDB and KeystoneCutoffsDB.standaloneMode and not panel
                and C_AddOns and C_AddOns.LoadAddOn then
                pcall(C_AddOns.LoadAddOn, "Blizzard_ChallengesUI")
            end
            if ApplyPanelPresentation then ApplyPanelPresentation() end
        end)
    dy = dy - hStandalone - 10
    display:SetHeight(math.abs(dy))

    -- ── Goals tab ─────────────────────────────────────────────────────────────
    local gy = -10
    gy = gy - introText(goals,
        "Optional progression tools. Nothing in this tab is enabled by default.", gy) - 6
    sectionLabel(goals, "FOCUSED GOAL", gy); gy = gy - 18
    local _, hGoal = makeKCCheckbox(goals, gy, "goalMode", "Enable Goal Mode", nil,
        "Replaces the three default target rows with one selected goal and a clear Need or Ahead value.")
    gy = gy - hGoal - 6
    local hGoalTarget = makeKCDropdown(goals, gy, "goalTarget", "Goal", GOAL_OPTIONS, nil,
        "Select a percentile, achievement, or custom score target.")
    gy = gy - hGoalTarget - 8
    local hCustom = makeKCSlider(goals, gy, "goalCustomScore", "Custom", 1000, 5000, 10,
        function() UpdatePanel() end,
        "Used only when Goal is set to Custom score.")
    gy = gy - hCustom - 12

    divider(goals, gy); gy = gy - 14
    sectionLabel(goals, "OPTIONAL INSIGHTS", gy); gy = gy - 18
    local _, hMove = makeKCCheckbox(goals, gy, "showCutoffMovement", "Show Cutoff Movement", nil,
        "Compares the current Top 0.1% cutoff with the most recent data release previously seen while enabled.")
    gy = gy - hMove - 6
    local _, hWeak = makeKCCheckbox(goals, gy, "showWeakestDungeon", "Show Furthest-Behind Dungeon", nil,
        "Adds one summary row for the largest key-level deficit versus title pace. It is not a score-gain recommendation.")
    gy = gy - hWeak - 6
    local _, hChars = makeKCCheckbox(goals, gy, "trackCharacters", "Track Character Scores", nil,
        "Stores last-known scores in this addon's account-wide settings for the characters you log into. Off by default.")
    gy = gy - hChars - 10
    local hDetails = makeKCButton(goals, gy, "Open Detailed Ladder View", function() ShowAdvancedDetails() end,
        "Shows all percentile cutoffs, achievement goals, population values, and any opted-in character snapshots.")
    gy = gy - hDetails - 10
    goals:SetHeight(math.abs(gy))

    -- ── Customize tab ─────────────────────────────────────────────────────────
    local cy2 = -10
    cy2 = cy2 - introText(customize,
        "Adjust readability without changing which information is shown.", cy2) - 6
    sectionLabel(customize, "DUNGEON OVERLAY TEXT", cy2); cy2 = cy2 - 18

    local hFont = makeKCFontDropdown(customize, cy2, "overlayFont", "Font",
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hFont - 8
    local hScoreSize = makeKCSlider(customize, cy2, "overlayScoreSize", "Score Size", 8, 28, 1,
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hScoreSize - 6
    local hTimeSize = makeKCSlider(customize, cy2, "overlayTimeSize", "Time Size", 6, 24, 1,
        function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hTimeSize - 8
    local hOutline = makeKCDropdown(customize, cy2, "overlayOutline", "Outline", {
        { value = "NONE", label = "None" }, { value = "OUTLINE", label = "Outline" },
        { value = "THICKOUTLINE", label = "Thick Outline" }, { value = "SHADOW", label = "Shadow" },
    }, function() UpdateDungeonOverlays() end)
    cy2 = cy2 - hOutline - 12

    divider(customize, cy2); cy2 = cy2 - 14
    sectionLabel(customize, "PANEL APPEARANCE", cy2); cy2 = cy2 - 18
    local hScale = makeKCSlider(customize, cy2, "panelScale", "Scale", 75, 150, 5,
        function() if ApplyPanelPresentation then ApplyPanelPresentation() end end)
    cy2 = cy2 - hScale - 6
    local hOpacity = makeKCSlider(customize, cy2, "panelOpacity", "Opacity", 40, 100, 5,
        function() if ApplyPanelPresentation then ApplyPanelPresentation() end end)
    cy2 = cy2 - hOpacity - 10
    local hReset = makeKCButton(customize, cy2, "Reset Panel Position", function()
        if KeystoneCutoffsDB then
            KeystoneCutoffsDB.panelPosition = nil
            KeystoneCutoffsDB.standalonePosition = nil
        end
        PositionPanel()
    end)
    cy2 = cy2 - hReset - 6
    local hResetVisual = makeKCButton(customize, cy2, "Reset Appearance", function()
        if KeystoneCutoffsDB then
            KeystoneCutoffsDB.overlayFont = DB_DEFAULTS.overlayFont
            KeystoneCutoffsDB.overlayScoreSize = DB_DEFAULTS.overlayScoreSize
            KeystoneCutoffsDB.overlayTimeSize = DB_DEFAULTS.overlayTimeSize
            KeystoneCutoffsDB.overlayOutline = DB_DEFAULTS.overlayOutline
            KeystoneCutoffsDB.panelScale = DB_DEFAULTS.panelScale
            KeystoneCutoffsDB.panelOpacity = DB_DEFAULTS.panelOpacity
        end
        for _, refresh in ipairs(settingsRefreshFns) do refresh() end
        UpdateDungeonOverlays()
        if ApplyPanelPresentation then ApplyPanelPresentation() end
    end)
    cy2 = cy2 - hResetVisual - 8
    cy2 = cy2 - introText(customize,
        "Tip: Shift+Left-drag the panel to reposition it.", cy2)
    customize:SetHeight(math.abs(cy2))

    -- ── Advanced tab ──────────────────────────────────────────────────────────
    local ay = -10
    ay = ay - introText(advanced,
        "Deeper ladder context for players who want it; the standard All ladder remains the default.", ay) - 6
    sectionLabel(advanced, "LADDER DATA", ay); ay = ay - 18
    local hFaction = makeKCDropdown(advanced, ay, "dataFaction", "Ladder", {
        { value = "all", label = "All players" },
        { value = "horde", label = "Horde" },
        { value = "alliance", label = "Alliance" },
    }, function() UpdatePanel() end,
        "Uses faction-specific percentile and goal data when present. Dungeon Pace remains region-wide. All players is the default.")
    ay = ay - hFaction - 12
    local hAdvancedDetails = makeKCButton(advanced, ay, "Open Detailed Ladder View",
        function() ShowAdvancedDetails() end,
        "A deliberate popout keeps population and achievement data out of the lightweight panel.")
    ay = ay - hAdvancedDetails - 12
    divider(advanced, ay); ay = ay - 14
    sectionLabel(advanced, "DATA BEHAVIOR", ay); ay = ay - 18
    ay = ay - introText(advanced,
        "The addon cannot access the internet in game. Cutoffs come from the bundled daily data file. Movement and character history are local SavedVariables and are collected only after you enable them.", ay) - 6
    advanced:SetHeight(math.abs(ay))

    -- ── Persistent footer utility ─────────────────────────────────────────────
    local FOOTER_H = 38
    local footerSep = win:CreateTexture(nil, "BACKGROUND")
    footerSep:SetHeight(1)
    footerSep:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 0, FOOTER_H)
    footerSep:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 0, FOOTER_H)
    footerSep:SetColorTexture(ST.border[1], ST.border[2], ST.border[3], 0.7)

    local whatsNewBtn = CreateFrame("Button", nil, win, "BackdropTemplate")
    whatsNewBtn:SetSize(110, 24)
    whatsNewBtn:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 7)
    mixBD(whatsNewBtn)
    whatsNewBtn:SetBackdrop(BD_EDGE)
    whatsNewBtn:SetBackdropColor(ST.element[1], ST.element[2], ST.element[3], 1)
    whatsNewBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)

    local whatsNewText = whatsNewBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whatsNewText:SetPoint("CENTER")
    whatsNewText:SetText("What's New")
    whatsNewText:SetTextColor(ST.text[1], ST.text[2], ST.text[3])

    whatsNewBtn:SetScript("OnEnter", function()
        whatsNewBtn:SetBackdropBorderColor(ST.accent[1], ST.accent[2], ST.accent[3], 0.9)
        whatsNewText:SetTextColor(ST.accent[1], ST.accent[2], ST.accent[3])
    end)
    whatsNewBtn:SetScript("OnLeave", function()
        whatsNewBtn:SetBackdropBorderColor(ST.border[1], ST.border[2], ST.border[3], 0.6)
        whatsNewText:SetTextColor(ST.text[1], ST.text[2], ST.text[3])
    end)
    whatsNewBtn:SetScript("OnClick", function()
        ShowWhatsNewWindow()
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)

    -- ── Window sizing + initial anchor ────────────────────────────────────────
    local contentH = math.max(display:GetHeight(), goals:GetHeight(), customize:GetHeight(), advanced:GetHeight())
    win:SetSize(WIN_W, TITLE_H + 1 + TAB_BAR_H + 1 + contentH + FOOTER_H + 8)
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
    refreshSeasonDungeons()

    panel = CreateFrame("Frame", "KeystoneCutoffsPanel", ChallengesFrame, "TooltipBackdropTemplate")
    panel:SetParent(ChallengesFrame)
    panel:SetWidth(FRAME_WIDTH)
    panel:SetFrameStrata("MEDIUM")
    panel:SetFrameLevel(10)
    panel.collapsed = KeystoneCutoffsDB and KeystoneCutoffsDB.collapsed == true

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
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            KeystoneCutoffsDB = KeystoneCutoffsDB or {}
            if KeystoneCutoffsDB.standaloneMode then
                self:ClearAllPoints()
                self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                KeystoneCutoffsDB.standalonePosition = {
                    point = "TOPLEFT", relPoint = "BOTTOMLEFT",
                    x = math.floor(left + 0.5), y = math.floor(top + 0.5),
                }
                return
            end

            -- Persist drag offsets relative to ChallengesFrame so the panel still
            -- follows Blizzard's UI panel push/stack behavior.
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
    split.updatedL,split.updatedV= createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.movementL, split.movementV = createSplitRow(panel, y); y = y - ROW_H - ROW_GAP
    split.weakestL, split.weakestV = createSplitRow(panel, y)

    panel.split = split

    addDataFrame(dataFrames,
        split.gap01L,  split.gap01V,
        split.gap1L,   split.gap1V,
        split.mythL,   split.mythV,
        split.pctL,    split.pctV,
        split.seasonL, split.seasonV,
        split.updatedL,split.updatedV,
        split.movementL, split.movementV,
        split.weakestL, split.weakestV
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
    wireTooltipHitbox(seasonHit, "Season End",
        "Shows the published end date for your selected data region. Regional reset dates can differ; Not announced is shown until a reliable date is available.")
    panel.seasonTooltipHit = seasonHit
    dataFrames[#dataFrames + 1] = seasonHit

    -- ── Dungeon pace section (optional, positioned by relayoutPanel) ───────────
    local paceDivider = panel:CreateTexture(nil, "BACKGROUND")
    paceDivider:SetHeight(1)
    paceDivider:SetColorTexture(0.25, 0.25, 0.25, 0.7)
    panel.paceDivider = paceDivider
    dataFrames[#dataFrames + 1] = paceDivider

    local paceHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    paceHeader:SetJustifyH("LEFT")
    paceHeader:SetText(col(C.gold, "Dungeon Pace"))
    panel.paceHeader = paceHeader
    dataFrames[#dataFrames + 1] = paceHeader

    local paceHeaderHit = CreateFrame("Frame", nil, panel)
    paceHeaderHit:SetFrameLevel(panel:GetFrameLevel() + 20)
    paceHeaderHit:EnableMouse(true)
    do
        local hi = paceHeaderHit:CreateTexture(nil, "ARTWORK")
        hi:SetAllPoints(paceHeaderHit)
        hi:SetColorTexture(1, 1, 1, 0.08)
        hi:Hide()
        paceHeaderHit._highlightTex = hi
        paceHeaderHit:SetScript("OnEnter", function(self)
            if self._highlightTex then self._highlightTex:Show() end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:SetText("Dungeon Pace", 1, 0.82, 0)
            GameTooltip:AddLine(
                "Compares your best key level per dungeon to what"
                .. " title players (Top 0.1%) typically complete.",
                1, 1, 1, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Gap color:", 0.65, 0.65, 0.65)
            GameTooltip:AddLine(" ")
            -- |T| extended syntax: path:h:w:xOff:yOff:fileW:fileH:l:r:t:b:R:G:B
            -- Tints the white circle texture with each gap colour at runtime.
            local function circleIcon(R, G, B)
                return string.format(
                    "|TInterface\\AddOns\\KeystoneCutoffs\\Assets\\circle:10:10:0:0:64:64:0:64:0:64:%d:%d:%d|t",
                    R, G, B)
            end
            GameTooltip:AddLine(circleIcon(68,  255, 68)  .. "  On pace or ahead")
            GameTooltip:AddLine(circleIcon(255, 153, 51)  .. "  1 key behind")
            GameTooltip:AddLine(circleIcon(255, 68,  68)  .. "  2+ keys behind")
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Data sourced from Raider.IO, updated daily.",
                0.55, 0.55, 0.55)
            GameTooltip:Show()
        end)
        paceHeaderHit:SetScript("OnLeave", function(self)
            if self._highlightTex then self._highlightTex:Hide() end
            GameTooltip:Hide()
        end)
    end
    panel.paceHeaderHit = paceHeaderHit
    dataFrames[#dataFrames + 1] = paceHeaderHit

    local paceRows = {}
    for i = 1, #DUNGEON_PACE_DATA do
        local d = DUNGEON_PACE_DATA[i]
        local L, V = createSplitRow(panel, 0)

        -- Invisible hitbox for tooltip — positioned by relayoutPanel each frame.
        local hb = CreateFrame("Frame", nil, panel)
        hb:SetFrameLevel(panel:GetFrameLevel() + 20)
        hb:EnableMouse(true)
        local hiTex = hb:CreateTexture(nil, "ARTWORK")
        hiTex:SetAllPoints(hb)
        hiTex:SetColorTexture(1, 1, 1, 0.06)
        hiTex:Hide()
        hb:SetScript("OnEnter", function(self)
            hiTex:Show()
            -- Gather live data for this dungeon
            local playerLevel, isTimed
            if C_MythicPlus and C_MythicPlus.GetSeasonBestForMap then
                local ok, inTime, overtime = pcall(C_MythicPlus.GetSeasonBestForMap, d.mapID)
                if ok then
                    local run = inTime or overtime
                    if run then
                        playerLevel = run.level
                        isTimed     = (inTime ~= nil)
                    end
                end
            end
            local benchmark = getDungeonBenchmark(d.mapID)

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(d.name, 1, 0.82, 0)
            if playerLevel then
                local timedStr = isTimed
                    and "|cFF44FF44in time|r"
                    or  "|cFFAAAAAA overtime|r"
                GameTooltip:AddDoubleLine("Your best",
                    string.format("|cFFFFFFFF+%d|r  %s", playerLevel, timedStr),
                    0.65, 0.65, 0.65, 1, 1, 1)
            else
                GameTooltip:AddLine("|cFF888888No run recorded this season|r")
            end
            if benchmark then
                GameTooltip:AddDoubleLine("Title typical",
                    string.format("|cFFFFD100+%d|r", benchmark),
                    0.65, 0.65, 0.65, 1, 1, 1)
            end
            if benchmark and playerLevel then
                local gap = playerLevel - benchmark
                local gapColor = gap >= 0 and "|cFF44FF44"
                    or (gap >= -1 and "|cFFFF9933" or "|cFFFF4444")
                local sign = gap >= 0 and "+" or ""
                GameTooltip:AddDoubleLine("Gap",
                    string.format("%s%s%d keys|r", gapColor, sign, gap),
                    0.65, 0.65, 0.65, 1, 1, 1)
            end
            GameTooltip:Show()
        end)
        hb:SetScript("OnLeave", function()
            hiTex:Hide()
            GameTooltip:Hide()
        end)

        paceRows[i] = { L = L, V = V, hitbox = hb }
        dataFrames[#dataFrames + 1] = L
        dataFrames[#dataFrames + 1] = V
        dataFrames[#dataFrames + 1] = hb
    end
    panel.paceRows = paceRows

    -- ── Collapse toggle ───────────────────────────────────────────────────────
    collapseBtn:SetScript("OnClick", function()
        panel.collapsed = not panel.collapsed
        if KeystoneCutoffsDB then KeystoneCutoffsDB.collapsed = panel.collapsed end
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
    if panel.collapsed then
        for _, f in ipairs(panel.dataFrames) do f:SetShown(false) end
        panel:SetHeight(COLLAPSED_HEIGHT)
        collapseArrow:SetRotation(-math.pi / 2)
    end
    PositionPanel()
    if ApplyPanelPresentation then ApplyPanelPresentation() end
end

-- ─── Panel positioning ────────────────────────────────────────────────────────
PositionPanel = function()
    if not panel then return end
    panel:ClearAllPoints()

    local db = KeystoneCutoffsDB or {}
    if db.standaloneMode then
        panel:SetParent(UIParent)
        local customStandalone = db.standalonePosition
        if type(customStandalone) == "table" and customStandalone.point then
            panel:SetPoint(customStandalone.point, UIParent,
                customStandalone.relPoint or customStandalone.point,
                customStandalone.x or 0, customStandalone.y or 0)
        else
            panel:SetPoint("CENTER", UIParent, "CENTER", 310, 60)
        end
        return
    end

    panel:SetParent(ChallengesFrame)
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

ApplyPanelPresentation = function()
    if not panel then return end
    local db = KeystoneCutoffsDB or {}
    panel:SetScale(math.max(0.75, math.min(1.50, (tonumber(db.panelScale) or 100) / 100)))
    panel:SetAlpha(math.max(0.40, math.min(1.00, (tonumber(db.panelOpacity) or 100) / 100)))
    PositionPanel()
    if db.standaloneMode then
        panel:Show()
        UpdatePanel()
    elseif ChallengesFrame and ChallengesFrame:IsShown() then
        panel:Show()
        UpdatePanel()
    else
        panel:Hide()
    end
end

-- ─── Region helper ────────────────────────────────────────────────────────────
local function GetRegion()
    local regionMap = { [1]="us", [2]="kr", [3]="eu", [4]="tw", [5]="us" }
    local id = GetCurrentRegionName and GetCurrentRegionName()
    if id then return string.lower(id) end
    return regionMap[GetCurrentRegion() or 3] or "eu"
end

-- Returns the region to use for data lookups: manual setting if configured,
-- otherwise the auto-detected game region.
GetDataRegion = function()
    local db = KeystoneCutoffsDB or {}
    local setting = db.dataRegion
    if setting and setting ~= "auto" then return setting end
    return GetRegion()
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

    -- First target row is always visible. Goal Mode repurposes it as the chosen goal.
    placeRow(split.gap01L, split.gap01V); y = y - ROW_H - ROW_GAP

    if db.goalMode then
        hideRow(split.gap1L, split.gap1V)
        hideRow(split.mythL, split.mythV)
        if panel.mythTooltipHit then panel.mythTooltipHit:Hide() end
    else
        placeRow(split.gap1L, split.gap1V); y = y - ROW_H - ROW_GAP
        if db.showMythThreshold ~= false then
            placeRow(split.mythL, split.mythV)
            if panel.mythTooltipHit then panel.mythTooltipHit:Show() end
            y = y - ROW_H - ROW_GAP
        else
            hideRow(split.mythL, split.mythV)
            if panel.mythTooltipHit then panel.mythTooltipHit:Hide() end
        end
    end

    if compact then
        -- In compact mode, stop here: hide everything below the cutoff block.
        hideRow(split.pctL,     split.pctV)
        hideRow(split.seasonL,  split.seasonV)
        hideRow(split.updatedL, split.updatedV)
        hideRow(split.movementL, split.movementV)
        hideRow(split.weakestL, split.weakestV)
        if panel.seasonTooltipHit then panel.seasonTooltipHit:Hide() end

        -- Also hide the dungeon pace section.
        if panel.paceDivider  then panel.paceDivider:SetShown(false)  end
        if panel.paceHeader   then panel.paceHeader:SetShown(false)   end
        if panel.paceHeaderHit then panel.paceHeaderHit:SetShown(false) end
        for _, row in ipairs(panel.paceRows or {}) do
            row.L:SetShown(false); row.V:SetShown(false)
            if row.hitbox then row.hitbox:SetShown(false) end
        end

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
    y = y - ROW_H  -- advance below the updated row

    if db.showCutoffMovement then
        y = y - ROW_GAP
        placeRow(split.movementL, split.movementV)
        y = y - ROW_H
    else
        hideRow(split.movementL, split.movementV)
    end

    if db.showWeakestDungeon then
        y = y - ROW_GAP
        placeRow(split.weakestL, split.weakestV)
        y = y - ROW_H
    else
        hideRow(split.weakestL, split.weakestV)
    end

    -- ── Dungeon pace (optional section) ───────────────────────────────────────
    local PACE_ROW_H   = 16
    local PACE_ROW_GAP = 1

    if db.showDungeonPace and panel.paceRows and #panel.paceRows > 0 then
        y = y - SECTION_GAP

        panel.paceDivider:SetShown(true)
        panel.paceDivider:ClearAllPoints()
        panel.paceDivider:SetPoint("TOPLEFT",  panel, "TOPLEFT",  PAD, y)
        panel.paceDivider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y)
        y = y - 1 - 5  -- 1px line + spacing

        panel.paceHeader:SetShown(true)
        panel.paceHeader:ClearAllPoints()
        panel.paceHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
        if panel.paceHeaderHit then
            panel.paceHeaderHit:SetShown(true)
            panel.paceHeaderHit:ClearAllPoints()
            panel.paceHeaderHit:SetPoint("TOPLEFT",     panel, "TOPLEFT",  PAD - 2, y + 2)
            panel.paceHeaderHit:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -PAD + 2, y - SECTION_TITLE_H)
        end
        y = y - SECTION_TITLE_H - 3

        for i, row in ipairs(panel.paceRows) do
            row.L:SetShown(true); row.V:SetShown(true)
            row.L:ClearAllPoints(); row.L:SetPoint("TOPLEFT",  panel, "TOPLEFT",  PAD, y)
            row.V:ClearAllPoints(); row.V:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y)
            if row.hitbox then
                row.hitbox:SetShown(true)
                row.hitbox:ClearAllPoints()
                row.hitbox:SetPoint("TOPLEFT",     panel, "TOPLEFT",  PAD - 2, y + 1)
                row.hitbox:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -PAD + 2, y - PACE_ROW_H + 1)
            end
            if i < #panel.paceRows then
                y = y - PACE_ROW_H - PACE_ROW_GAP
            end
        end
        y = y - PACE_ROW_H  -- below the last pace row
    else
        panel.paceDivider:SetShown(false)
        panel.paceHeader:SetShown(false)
        if panel.paceHeaderHit then panel.paceHeaderHit:SetShown(false) end
        for _, row in ipairs(panel.paceRows or {}) do
            row.L:SetShown(false); row.V:SetShown(false)
            if row.hitbox then row.hitbox:SetShown(false) end
        end
    end

    local newH = math.ceil(-y + BOTTOM_PAD)
    panel.expandedHeight = newH
    panel:SetHeight(newH)
end

-- ─── Panel update ─────────────────────────────────────────────────────────────
UpdatePanel = function()
    if not panel or not panel:IsShown() then return end
    refreshSeasonDungeons()
    PositionPanel()

    local split = panel.split
    if not split then return end
    local db = KeystoneCutoffsDB or {}

    local function showError(msg)
        split.gap01L:SetText(col(C.grey, "Status"))
        split.gap01V:SetText(col(C.grey, msg))
        for _, k in ipairs({ "gap1L","gap1V","mythL","mythV","pctL","pctV",
                              "seasonL","seasonV","updatedL","updatedV",
                              "movementL","movementV","weakestL","weakestV" }) do
            split[k]:SetText("")
        end
    end

    if not KeystoneCutoffsData then
        panel.subtitle:SetText("")
        showError("No cutoff data loaded.")
        relayoutPanel()
        return
    end

    local region     = GetDataRegion()
    local regionData = KeystoneCutoffsData.regions and KeystoneCutoffsData.regions[region]
    if not regionData then
        panel.subtitle:SetText("")
        showError("No data for region: " .. region)
        relayoutPanel()
        return
    end

    local faction = getDataFaction()
    local factionLabel = faction == "all" and "All"
        or (faction == "horde" and "Horde" or "Alliance")
    panel.subtitle:SetText(string.format("Keystone Cutoffs · %s · %s", string.upper(region), factionLabel))

    local pct  = regionData.percentiles or {}
    local p999 = getPercentileEntry(pct, "p999")
    local p990 = getPercentileEntry(pct, "p990")

    local myScore = 0
    if C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore then
        myScore = C_ChallengeMode.GetOverallDungeonScore() or 0
    end

    recordOptionalSnapshots(region, regionData, myScore)

    if db.goalMode then
        local goalLabel, goalScore = getGoalTarget(regionData)
        split.gap01L:SetText(col(C.white, goalLabel)
            .. col(C.grey, " (" .. fmt(goalScore) .. ")"))
        split.gap01V:SetText(formatGoalDifference(goalScore, myScore))
    else
        if p999 and p999.score then
            split.gap01L:SetText(col(C.white, "Top 0.1%") .. col(C.grey, " (" .. fmt(p999.score) .. ")"))
            split.gap01V:SetText(formatGoalDifference(p999.score, myScore))
        else
            split.gap01L:SetText(col(C.white, "Top 0.1%") .. col(C.grey, " (—)"))
            split.gap01V:SetText(col(C.grey, "—"))
        end

        if p990 and p990.score then
            split.gap1L:SetText(col(C.white, "Top 1%") .. col(C.grey, " (" .. fmt(p990.score) .. ")"))
            split.gap1V:SetText(formatGoalDifference(p990.score, myScore))
        else
            split.gap1L:SetText(col(C.white, "Top 1%") .. col(C.grey, " (—)"))
            split.gap1V:SetText(col(C.grey, "—"))
        end

        local titles = regionData.titles or {}
        local myth = titles["keystoneMyth"]
        if myth and myth.fixedScore then
            split.mythL:SetText(col(C.white, "Keystone Myth") .. col(C.grey, " (" .. fmt(myth.fixedScore) .. ")"))
            split.mythV:SetText(formatGoalDifference(myth.fixedScore, myScore))
        else
            split.mythL:SetText(col(C.white, "Keystone Myth") .. col(C.grey, " (—)"))
            split.mythV:SetText(col(C.grey, "—"))
        end
    end

    -- Estimated percentile
    local tierOrder = { "p999","p990","p900","p750","p600" }
    local tierLabel = { "0.1","1","10","25","40" }
    local myPercentile = "> 40%"
    for i, key in ipairs(tierOrder) do
        local t = getPercentileEntry(pct, key)
        if t and myScore >= t.score then
            myPercentile = "Top " .. tierLabel[i] .. "%"
            break
        end
    end
    split.pctL:SetText("Est. Percentile")
    split.pctV:SetText(col(scoreColorFor(myScore), myPercentile))

    -- Season end (toggleable)
    split.seasonL:SetText("Season Ends")
    local regionEnds = KeystoneCutoffsData.seasonEnds
    local seasonEnd = regionEnds and regionEnds[GetDataRegion()]
        or KeystoneCutoffsData.seasonEnd
        or "Unknown"
    split.seasonV:SetText(col(C.white, seasonEnd))

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

    split.movementL:SetText("Cutoff Movement")
    local movement = getCutoffMovement(region)
    if movement then
        local movementColor = movement > 0 and "|cFFFF9933" or (movement < 0 and "|cFF44FF44" or C.grey)
        local sign = movement > 0 and "+" or ""
        split.movementV:SetText(movementColor .. sign .. fmt(movement) .. "|r")
    else
        split.movementV:SetText(col(C.grey, "Collecting…"))
    end

    local weakestName, weakestGap

    -- ── Dungeon pace rows ──────────────────────────────────────────────────────
    if (db.showDungeonPace or db.showWeakestDungeon) and panel.paceRows then
        for i, row in ipairs(panel.paceRows) do
            local d = DUNGEON_PACE_DATA[i]

            local playerLevel, isTimed
            if C_MythicPlus and C_MythicPlus.GetSeasonBestForMap then
                local ok, inTime, overtime = pcall(C_MythicPlus.GetSeasonBestForMap, d.mapID)
                if ok then
                    local run = inTime or overtime
                    if run then
                        playerLevel = run.level
                        isTimed     = (inTime ~= nil)
                    end
                end
            end

            local benchmark = getDungeonBenchmark(d.mapID)

            if benchmark and playerLevel then
                local gap = playerLevel - benchmark
                if not weakestGap or gap < weakestGap then
                    weakestName, weakestGap = d.short, gap
                end
            end

            -- Left: abbreviated name + player's key level
            if playerLevel then
                local keyColor = isTimed and C.white or C.grey
                row.L:SetText(string.format("%-4s  %s+%d|r", d.short, keyColor, playerLevel))
            else
                row.L:SetText(string.format("%-4s  %s—|r", d.short, C.grey))
            end
            row.L:SetTextColor(0.75, 0.75, 0.75, 1)

            -- Right: colored gap vs title typical
            if benchmark and playerLevel then
                local gap = playerLevel - benchmark
                local gapColor
                if gap >= 0 then
                    gapColor = "|cFF44FF44"
                elseif gap == -1 then
                    gapColor = "|cFFFF9933"
                else
                    gapColor = "|cFFFF4444"
                end
                local sign = gap >= 0 and "+" or ""
                row.V:SetText(gapColor .. sign .. gap .. "|r")
            elseif benchmark then
                row.V:SetText(col(C.grey, "—"))
            else
                row.V:SetText("")
            end
        end
    end

    split.weakestL:SetText("Furthest Behind")
    if weakestName and weakestGap and weakestGap < 0 then
        local unit = math.abs(weakestGap) == 1 and " key" or " keys"
        split.weakestV:SetText("|cFFFF4444" .. weakestName .. " " .. weakestGap .. unit .. "|r")
    elseif weakestName then
        split.weakestV:SetText("|cFF44FF44On pace|r")
    else
        split.weakestV:SetText(col(C.grey, "No runs"))
    end

    relayoutPanel()
    UpdateDungeonOverlays()
end

-- ─── Per-dungeon title-pace benchmark ────────────────────────────────────────
-- Returns the title-boundary key level for mapID in the player's region,
-- or nil if the data isn't available yet (first load before a data update).
getDungeonBenchmark = function(mapID)
    if not KeystoneCutoffsData or not KeystoneCutoffsData.dungeonBenchmarks then return nil end
    local regionBenchmarks = KeystoneCutoffsData.dungeonBenchmarks[GetDataRegion()]
    if not regionBenchmarks then return nil end
    return regionBenchmarks[mapID]
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

            -- ── Title-pace tooltip (hooked once per icon) ──────────────────
            if not icon._kcTitlePaceHooked then
                icon:HookScript("OnEnter", function(self)
                    local mid = self.mapID
                    if not mid then return end
                    local benchmark = getDungeonBenchmark(mid)
                    if not benchmark then return end

                    local playerLevel
                    if C_MythicPlus and C_MythicPlus.GetSeasonBestForMap then
                        local ok, inT, outT = pcall(C_MythicPlus.GetSeasonBestForMap, mid)
                        if ok then
                            local run = inT or outT
                            playerLevel = run and run.level
                        end
                    end

                    local tt = GameTooltip
                    if not tt:IsShown() then
                        tt:SetOwner(self, "ANCHOR_RIGHT")
                    end
                    tt:AddLine(" ")
                    tt:AddLine(col(C.gold, "Title Players") .. " |cFF888888(Top 0.1%)|r")
                    tt:AddDoubleLine("Typical key", col(C.gold, "+" .. benchmark),
                        0.65, 0.65, 0.65, 1, 1, 1)
                    if playerLevel then
                        tt:AddDoubleLine("Your best", col(C.white, "+" .. playerLevel),
                            0.65, 0.65, 0.65, 1, 1, 1)
                        local gap = playerLevel - benchmark
                        local gapColor, gapStr
                        if gap >= 0 then
                            gapColor = "|cFF44FF44"
                            gapStr   = "+" .. gap
                        elseif gap == -1 then
                            gapColor = "|cFFFF9933"
                            gapStr   = tostring(gap)
                        else
                            gapColor = "|cFFFF4444"
                            gapStr   = tostring(gap)
                        end
                        local unit = math.abs(gap) == 1 and " key" or " keys"
                        tt:AddDoubleLine("Gap", gapColor .. gapStr .. unit .. "|r",
                            0.65, 0.65, 0.65, 1, 1, 1)
                    else
                        tt:AddLine("|cFF888888No run recorded this season|r")
                    end
                    tt:Show()
                end)
                icon._kcTitlePaceHooked = true
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
                if KeystoneCutoffsDB and KeystoneCutoffsDB.standaloneMode and panel then
                    if panel:IsShown() then panel:Hide() else panel:Show(); UpdatePanel() end
                elseif ToggleChallengesUI then
                    ToggleChallengesUI()
                end
            else
                ToggleSettingsWindow()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("|cFFFFD100Keystone Cutoffs|r")
            tt:AddLine("|cFFFFFFFFLeft-click:|r Open settings", 0.85, 0.85, 0.85)
            local rightAction = KeystoneCutoffsDB and KeystoneCutoffsDB.standaloneMode
                and "Toggle standalone panel" or "Toggle Mythic+ Dungeons"
            tt:AddLine("|cFFFFFFFFRight-click:|r " .. rightAction, 0.85, 0.85, 0.85)
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
    if panel and not (KeystoneCutoffsDB and KeystoneCutoffsDB.standaloneMode) then
        panel:Hide()
    end
end

-- ─── Initialization ───────────────────────────────────────────────────────────
local dataReady = false
local uiReady   = false
local initialized = false

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
    if ApplyPanelPresentation then ApplyPanelPresentation() end

    local updater = CreateFrame("Frame")
    for _, ev in ipairs({
        "CHALLENGE_MODE_MAPS_UPDATE",
        "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
        "PLAYER_ENTERING_WORLD",
    }) do
        updater:RegisterEvent(ev)
    end
    updater:SetScript("OnEvent", function()
        refreshSeasonDungeons()
        UpdatePanel()
        UpdateDungeonOverlays()
    end)
end

local function TryInitialize()
    if dataReady and uiReady and not initialized then
        initialized = true
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

        if C_MythicPlus and C_MythicPlus.RequestMapInfo then
            pcall(C_MythicPlus.RequestMapInfo)
        end

        dataReady = true
        if IsAddonLoaded("Blizzard_ChallengesUI") then uiReady = true end
        if KeystoneCutoffsDB.standaloneMode and not uiReady
            and C_AddOns and C_AddOns.LoadAddOn then
            pcall(C_AddOns.LoadAddOn, "Blizzard_ChallengesUI")
            if IsAddonLoaded("Blizzard_ChallengesUI") then uiReady = true end
        end
        TryInitialize()

        -- Optional history collection does not require the Mythic+ window to be opened.
        C_Timer.After(2, function()
            if not KeystoneCutoffsDB or not (KeystoneCutoffsDB.showCutoffMovement
                or KeystoneCutoffsDB.trackCharacters) then return end
            local region = GetDataRegion and GetDataRegion() or GetRegion()
            local regionData = KeystoneCutoffsData and KeystoneCutoffsData.regions
                and KeystoneCutoffsData.regions[region]
            if not regionData then return end
            local score = C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore
                and C_ChallengeMode.GetOverallDungeonScore() or 0
            recordOptionalSnapshots(region, regionData, score)
        end)

        -- Delay until the login UI has settled. The stable news ID is separate
        -- from daily vdata tags, so routine data releases never reopen this.
        C_Timer.After(1, MaybeShowCurrentNews)

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
