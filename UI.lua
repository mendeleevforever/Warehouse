local addonName, ns = ...
-- UI.lua
-- The Warehouse window, laid out like MendeLedger (dark window, layered gold
-- trim, title plate on the top edge, icon tabs down the right-hand edge):
--   * Items tab: search box, Filter button and four filter selectors (Region,
--     Ruleset, Faction, Characters) over every item your characters hold,
--     grouped under collapsible bars (item type, location, character or
--     quality). On the right: who holds the selected item (a bar per
--     character, split by location), a summary and every stack's location.
--   * Characters and Options tabs: Panels.lua
-- None of these frames are protected.

local WH, Scan, Index, UI = ns.WH, ns.Scan, ns.Index, ns.UI
local C, GREY, DOT = UI.C, UI.GREY, UI.DOT
local SetColor, Hex, AddLabel, NoWrap = UI.SetColor, UI.Hex, UI.AddLabel, UI.NoWrap
local FlatButton, SetFlatSelected, AddHoverTip = UI.FlatButton, UI.SetFlatSelected, UI.AddHoverTip

local W, H          = 880, 660
local TAB, TAB_GAP  = 40, 4
local HEADER_Y      = -44
local CONTENT_TOP   = -90
local CONTENT_BOT   = 52
local LEFT_X, LEFT_R = 16, 332            -- item list panel
local RIGHT_X       = 344                 -- detail panel (to W - 16)
local LIST_X        = LEFT_X + 4
local LIST_TOP      = CONTENT_TOP - 80     -- under the search row and two rows of filter selectors
local LIST_W        = LEFT_R - 24 - LIST_X
local ROW_H         = 22
local DW            = W - 16 - RIGHT_X    -- detail panel width
local CW, CH        = DW - 24, 182        -- holdings chart
local BAR_ROWS      = 8
local BAR_H         = 20
local NAME_W        = 150
local COUNT_W       = 64
local WHERE_ROW_H   = 20
local LOC_BTN_W     = 44
local LOC_W         = 6 * LOC_BTN_W + 5 * 3
local SEL_GAP       = 5
local ICON          = 413587
local CHARS_ICON    = "Interface\\Icons\\INV_Misc_Head_Human_01"
local OPTIONS_ICON  = "Interface\\Icons\\INV_Misc_Gear_01"
local QUESTION      = "Interface\\Icons\\INV_Misc_QuestionMark"
local OTHER         = "Other"

UI.W, UI.H, UI.CONTENT_BOT = W, H, CONTENT_BOT
UI.ICON = ICON

-------------------------------------------------------------------------------
-- Item helpers
-------------------------------------------------------------------------------
local function DisplayName(m)
    if m.name then return m.name end
    return ("Item #%s"):format(tostring(m.id or m.key))
end
UI.DisplayName = DisplayName

function WH:LinkItem(m)
    local link = Index:Link(m.key)
    if link and HandleModifiedItemClick then                       -- RETEST
        HandleModifiedItemClick(link)
    else
        ns.Print("that item is still loading; try again in a moment.")
    end
end

local function IsLinkClick()
    return IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP"))
end

-- The game's tooltip for the item (without Warehouse's own count lines,
-- which this adds itself for the filtered characters)
function UI.ItemTooltip(owner, m, a)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local shown = false
    local itemString = WH.db.links[m.key]
    Index.suppress = true
    if itemString then
        shown = pcall(GameTooltip.SetHyperlink, GameTooltip, itemString)    -- RETEST
    elseif m.id then
        shown = pcall(GameTooltip.SetItemByID, GameTooltip, m.id)
    end
    Index.suppress = false
    if not shown then GameTooltip:AddLine(DisplayName(m), 1, 1, 1) end
    if a then
        local mu = C.muted
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Held", ("%s  %s(%d %s)|r"):format(ns.Commas(a.total), GREY, a.nOwners,
            ns.Plural(a.nOwners, "owner")), mu[1], mu[2], mu[3], 1, 1, 1)
        for _, loc in ipairs(ns.LOCATIONS) do
            local n = a.loc[loc]
            if n then GameTooltip:AddDoubleLine(ns.LOC_LABEL[loc], ns.Commas(n), mu[1], mu[2], mu[3], 1, 1, 1) end
        end
        if a.soonest then
            GameTooltip:AddDoubleLine("Mail expires", ns.Until(a.soonest), mu[1], mu[2], mu[3], 1, 0.6, 0.2)
        end
        GameTooltip:AddLine("Click to see where it is" .. (WH.db.settings.groupBy ~= "owner" and "; shift-click to link it" or ""), mu[1], mu[2], mu[3], true)
    end
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Main window
-------------------------------------------------------------------------------
function WH:PlaceMainFrame()
    if self.frame then UI.PlaceFrame(self.frame, "main") end
end

function WH:CreateMainFrame()
    if self.frame then return self.frame end
    local f = UI.MakeWindow("WarehouseFrame", W, H, "main")
    UI.SetWindowTitle(f, "Warehouse")
    if f.SetClampRectInsets then f:SetClampRectInsets(0, TAB + 6, 20, 0) end
    self.frame = f

    self:CreateTabs(f)
    self:CreateItemsView(f)
    if self.CreateCharsView then self:CreateCharsView(f) end
    if self.CreateOptionsView then self:CreateOptionsView(f) end

    UI.AddFooterRule(f, 46)
    f.legend = NoWrap(AddLabel(f, "", "GameFontNormalSmall", C.legend))
    f.legend:SetPoint("BOTTOMLEFT", 22, 20)
    f.legend:SetWidth(W - 180)
    local closeBtn = UI.MenuButton(f, "Close", 110)
    closeBtn:SetPoint("BOTTOMRIGHT", -20, 13)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function()
        WH:SelectTab(WH.currentTab or WH.db.settings.lastTab)
    end)
    f:SetScript("OnHide", function()
        if f.search then f.search:ClearFocus() end
        UI.HideMenu()
        GameTooltip:Hide()
    end)
    return f
end

function WH:Toggle()
    local f = self:CreateMainFrame()
    if f:IsShown() then f:Hide() else f:Show(); f:Raise() end
end

function WH:Open(tab)
    local f = self:CreateMainFrame()
    if tab then self.currentTab = tab end
    if f:IsShown() then
        if tab then self:SelectTab(tab) end
    else
        f:Show()
    end
    f:Raise()
end

function WH:OpenSearch(text)
    self:Open("items")
    self.frame.search:SetText(ns.Trim(text or ""))
end

-- Show only one character's items
function WH:PickOwner(key)
    local s = self.db.settings
    s.who, s.pick = "pick", key
    self:Open("items")
    self:RefreshItems(true)
end

-- Show only one guild bank's items: its location alone, the other guild
-- banks left out, and whatever else was hiding it cleared
function WH:PickGuild(key)
    local g = self.db.guilds[key]
    if not g then return end
    local s = self.db.settings
    for _, loc in ipairs(ns.LOCATIONS) do s.locations[loc] = (loc == "guild") end
    wipe(s.guildOff)
    wipe(s.tabOff)
    for gk in pairs(self.db.guilds) do
        if gk ~= key then s.guildOff[gk] = true end
    end
    if not Index:OwnerPasses("guild", key, g) then
        s.who = "all"
        s.regions[ns.AreaGroup(g.area)] = true
        s.rulesets[ns.RuleKey(g.ruleset)] = true
        if g.faction then s.factions[g.faction] = true end
    end
    self:Open("items")
    self:RefreshItems(true)
end

local refreshTimer
function WH:RequestUIRefresh(delay)
    local f = self.frame
    if not f or not f:IsShown() then return end
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(delay or 0.15, function()
        refreshTimer = nil
        if not f:IsShown() then return end
        local tab = self.currentTab
        if tab == "options" then
            if self.RefreshOptions then self:RefreshOptions() end
        elseif tab == "chars" then
            if self.RefreshChars then self:RefreshChars() end
        else
            self:RefreshItems()
        end
        self:UpdateInfoLine()
    end)
end

local lastProgress = 0
function WH:OnJobProgress()
    local f = self.frame
    if not f or not f:IsShown() or GetTime() - lastProgress < 0.25 then return end
    lastProgress = GetTime()
    self:UpdateInfoLine()
    local job = ns.CurrentJob()
    if job and job.name == "tooltips" and self.currentTab == "items" and self.searchActive then
        self:RefreshItems()
    end
end

function WH:UpdateInfoLine()
    local f = self.frame
    if not f then return end
    local job = ns.CurrentJob()
    if job and job.Progress then
        local done, total = job:Progress()
        f.info:SetText(("%s  —  %s of %s items"):format(job.label or job.name, ns.Commas(done), ns.Commas(total)))
        return
    end
    if not next(self.db.chars) then
        f.info:SetText("Nothing saved yet")
        return
    end
    local t = Index:Build().totals
    local parts = {
        ("%d %s"):format(t.chars, ns.Plural(t.chars, "character")),
        ("%d %s"):format(t.guilds, ns.Plural(t.guilds, "guild bank")),
        ("%s %s"):format(ns.Commas(t.items), ns.Plural(t.items, "item")),
        ns.PlainMoney(t.gold + t.mailGold + t.guildGold) .. " gold",
    }
    if self.db.settings.who ~= "all" or self:AnyFilterActive() then parts[#parts + 1] = "filtered" end
    f.info:SetText(table.concat(parts, "  •  "))
end

-------------------------------------------------------------------------------
-- Tabs down the right edge
-------------------------------------------------------------------------------
local TAB_INFO = {
    options = { title = "Options", body = "What's saved, item tooltips, mail warnings, the minimap button and a client check" },
    items   = { title = "Items", body = "Search everything your characters hold, and see where each stack is" },
    chars   = { title = "Characters", body = "Your characters and guild banks: region, ruleset, faction, gold and when each was saved" },
}

local function CreateTab(f, key, icon, y)
    local b = CreateFrame("Button", nil, f)
    b:SetSize(TAB, TAB)
    b.y = y
    b:SetPoint("TOPLEFT", f, "TOPRIGHT", 1, y)
    b:SetFrameLevel(f:GetFrameLevel() + 2)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    b.outline = UI.AddBorder(b, "BORDER", C.outline, 1, 2, -2)
    b.edges = UI.AddBorder(b, "BORDER", C.gold, 1, 2, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexture(icon)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 3, -3)
    hl:SetPoint("BOTTOMRIGHT", -3, 3)
    hl:SetColorTexture(1, 0.9, 0.6, 0.18)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetPoint("TOPLEFT", -3, 3)
    b.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    b.glow:SetColorTexture(1, 0.82, 0.2, 0.18)
    b.glow:Hide()
    b.key = key
    b:SetScript("OnClick", function(self) WH:SelectTab(self.key) end)
    b:SetScript("OnEnter", function(self)
        local info = TAB_INFO[self.key]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(info.title, 1, 0.82, 0)
        GameTooltip:AddLine(info.body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

function WH:CreateTabs(f)
    f.tabs = {}
    local y = -22
    f.tabs.options = CreateTab(f, "options", OPTIONS_ICON, y)
    y = y - TAB - TAB_GAP - 8
    f.tabs.items = CreateTab(f, "items", ICON, y)
    y = y - TAB - TAB_GAP
    f.tabs.chars = CreateTab(f, "chars", CHARS_ICON, y)
end

function WH:UpdateTabs()
    local f = self.frame
    if not f then return end
    for key, b in pairs(f.tabs) do
        local selected = key == self.currentTab
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPRIGHT", selected and -2 or 1, b.y)
        UI.SetEdgeColor(b.edges, selected and { 1, 0.82, 0.25 } or C.gold)
        b.glow:SetShown(selected)
    end
end

local LEGENDS = {
    items   = function() return "Click an item to see where it is (again for the overview)" .. DOT .. "Shift-click to link it" .. DOT .. "Hover a bar for each location" end,
    chars   = function() return "Click a character to show only their items" .. DOT .. "Right-click to forget" .. DOT .. "Region, ruleset and faction come from the game" end,
    options = function() return ("Warehouse %s"):format(WH.VERSION) .. DOT .. "Saved for every character on this account" .. DOT .. "/warehouse help" end,
}

function WH:SelectTab(key)
    local f = self:CreateMainFrame()
    if key ~= "options" and key ~= "chars" then key = "items" end
    self.currentTab = key
    self.db.settings.lastTab = key
    UI.HideMenu()
    GameTooltip:Hide()
    f.itemsView:SetShown(key == "items")
    if f.charsView then f.charsView:SetShown(key == "chars") end
    if f.optionsView then f.optionsView:SetShown(key == "options") end
    f.legend:SetText(LEGENDS[key]())
    if key == "options" then
        if self.RefreshOptions then self:RefreshOptions() end
    elseif key == "chars" then
        if self.RefreshChars then self:RefreshChars() end
    else
        self:RefreshItems(true)
    end
    self:UpdateInfoLine()
    self:UpdateTabs()
end

-------------------------------------------------------------------------------
-- Filter selectors: Region, Ruleset, Faction, Characters
-------------------------------------------------------------------------------
-- How many saved characters fall in each region area, ruleset group and faction
function WH:OwnerCounts()
    local out = { area = {}, rule = {}, faction = {} }
    for _, c in pairs(self.db.chars) do
        local a = ns.AreaGroup(c.area)
        out.area[a] = (out.area[a] or 0) + 1
        local r = ns.RuleKey(c.ruleset)
        out.rule[r] = (out.rule[r] or 0) + 1
        if c.faction then out.faction[c.faction] = (out.faction[c.faction] or 0) + 1 end
    end
    return out
end

local function CountSuffix(n)
    return n and n > 0 and ("  %s(%d)|r"):format(GREY, n) or ""
end

-- The choices each selector offers: always the ones asked for, plus Other,
-- Not set yet and Neutral only when a saved character has them
local SELECTORS = {
    region = {
        title = "Region", setting = "regions", order = ns.AREA_ORDER, labels = ns.AREAS, countKey = "area",
        optional = { OTHER = true }, short = { US = "US", EU = "EU", OTHER = "Other" },
        all = "Show all regions",
        note = "US includes Oceanic: one world, one auction house.",
    },
    ruleset = {
        title = "Ruleset", setting = "rulesets", order = ns.RULE_FILTER, labels = ns.RULE_LABELS, countKey = "rule",
        optional = { RP = true, Hardcore = true, UNSET = true },
        short = { PvE = "PvE", PvP = "PvP", RP = "RP", Hardcore = "Hardcore", UNSET = "Not read" },
        all = "Show all rulesets",
        note = "Read from the game when each character logs in.",
    },
    faction = {
        title = "Faction", setting = "factions", order = ns.FACTION_ORDER, labels = ns.FACTIONS, countKey = "faction",
        optional = { Neutral = true }, short = { Horde = "Horde", Alliance = "Alliance", Neutral = "Neutral" },
        all = "Show both factions",
    },
}

local function VisibleChoices(def, counts)
    local out = {}
    for _, k in ipairs(def.order) do
        if not def.optional[k] or (counts[def.countKey][k] or 0) > 0 then out[#out + 1] = k end
    end
    return out
end

-- Saved guild banks, sorted by name, each with its tab numbers in order
function WH:SortedGuilds()
    local list = {}
    for key, g in pairs(self.db.guilds) do
        local tabs = {}
        for tab in pairs(g.tabs) do tabs[#tabs + 1] = tab end
        table.sort(tabs)
        list[#list + 1] = { key = key, g = g, tabs = tabs }
    end
    table.sort(list, function(a, b)
        if a.g.name ~= b.g.name then return a.g.name < b.g.name end
        return a.key < b.key
    end)
    return list
end

local function GuildState(self)
    local s = self.db.settings
    if not s.locations.guild then return "No guild banks", true end
    local banks, shownBanks, tabs, shownTabs = 0, 0, 0, 0
    local lastBank, lastTab
    for _, it in ipairs(self:SortedGuilds()) do
        banks = banks + 1
        if Index:GuildShown(it.key) then
            shownBanks, lastBank = shownBanks + 1, it.g
            for _, tab in ipairs(it.tabs) do
                tabs = tabs + 1
                if Index:TabShown(it.key, tab) then shownTabs, lastTab = shownTabs + 1, it.g.tabs[tab] end
            end
        end
    end
    if shownBanks == banks and shownTabs == tabs then return "Guild banks", false end
    if shownBanks == 0 or (tabs > 0 and shownTabs == 0) then return "No guild banks", true end
    if shownBanks == 1 and shownTabs == 1 and lastTab then return lastTab.name, true end
    if shownBanks == 1 and shownTabs == tabs then return "<" .. lastBank.name .. ">", true end
    if shownTabs < tabs then return ("%d of %d tabs"):format(shownTabs, tabs), true end
    return ("%d of %d guild banks"):format(shownBanks, banks), true
end

function WH:SelectorState(kind)
    local s = self.db.settings
    if kind == "guild" then return GuildState(self) end
    if kind == "who" then
        if s.who == "me" then return "Only me", true end
        if s.who == "ruleset" then return "This ruleset", true end
        if s.who == "pick" then
            local c = self.db.chars[s.pick]
            return c and c.name or "Characters", c ~= nil
        end
        return "Characters", false
    end
    local def = SELECTORS[kind]
    local set = s[def.setting]
    local vis = VisibleChoices(def, self:OwnerCounts())
    local on = {}
    for _, k in ipairs(vis) do if set[k] then on[#on + 1] = def.short[k] end end
    if #on == #vis then return def.title, false end
    if #on == 0 then return def.title .. ": none", true end
    return table.concat(on, " + "), true
end

function WH:AnyFilterActive()
    for _, kind in ipairs({ "region", "ruleset", "faction", "guild" }) do
        local _, active = self:SelectorState(kind)
        if active then return true end
    end
    for _, loc in ipairs(ns.LOCATIONS) do
        if not self.db.settings.locations[loc] then return true end
    end
    local s = self.db.settings
    return s.minQuality > 0 or s.multiOwner or s.expiringOnly
end

function WH:SelectorItems(kind)
    local s = self.db.settings
    local def = SELECTORS[kind]
    local set = s[def.setting]
    local counts = self:OwnerCounts()
    local items = { { label = def.title } }
    for _, k in ipairs(VisibleChoices(def, counts)) do
        items[#items + 1] = { text = def.labels[k] .. CountSuffix(counts[def.countKey][k]), checked = set[k] and true or false,
            onClick = function() set[k] = not set[k] end }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = def.all, onClick = function() for k in pairs(set) do set[k] = true end end }
    if def.note then items[#items + 1] = { label = def.note, muted = true } end
    return items
end

local MAX_PICK = 16

function WH:WhoItems()
    local s = self.db.settings
    local items = {
        { label = "Characters" },
        { text = "All characters", checked = s.who == "all", onClick = function() s.who = "all" end },
        { text = "Only the character you're playing", checked = s.who == "me", onClick = function() s.who = "me" end,
          tip = "Their own bags, bank, mail and gear, plus their guild's bank." },
        { text = "Only this ruleset", checked = s.who == "ruleset", onClick = function() s.who = "ruleset" end,
          tip = "Every character in your region on the same ruleset as the one you're playing, and their guild banks." },
        { separator = true },
        { label = "Show one character" },
    }
    local list = Scan:SortedChars()
    for i, it in ipairs(list) do
        if i > MAX_PICK then
            items[#items + 1] = { label = ("%d more on the Characters tab"):format(#list - MAX_PICK), muted = true }
            break
        end
        local key = it.key
        items[#items + 1] = { text = ns.OwnerLabel("char", it.c) .. GREY .. "  " .. ns.AREAS[it.c.area] .. "|r",
            checked = s.who == "pick" and s.pick == key, onClick = function() s.who, s.pick = "pick", key end }
    end
    return items
end

-- Guild banks and their tabs, each one a checkbox
function WH:GuildItems()
    local s = self.db.settings
    local items = { { label = "Guild banks" } }
    local list = self:SortedGuilds()
    if #list == 0 then
        items[#items + 1] = { label = "None saved yet: open a guild bank to save it.", muted = true }
        return items
    end
    for _, it in ipairs(list) do
        local key, g = it.key, it.g
        items[#items + 1] = { text = ns.OwnerLabel("guild", g) .. CountSuffix(#it.tabs), checked = not s.guildOff[key],
            onClick = function() s.guildOff[key] = not s.guildOff[key] or nil end,
            tip = "Show this guild bank's items. Untick tabs below to leave just those out." }
        if not s.guildOff[key] then
            for _, tab in ipairs(it.tabs) do
                local tkey = ns.GuildTabKey(key, tab)
                local t = g.tabs[tab]
                local n = Scan.CountItems(t.items)
                items[#items + 1] = { text = ("      %s  %s(%s)|r"):format(t.name, GREY, ns.Commas(n)), checked = not s.tabOff[tkey],
                    onClick = function() s.tabOff[tkey] = not s.tabOff[tkey] or nil end }
            end
        end
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = "Show all guild banks and tabs", onClick = function()
        wipe(s.guildOff); wipe(s.tabOff); s.locations.guild = true
    end }
    items[#items + 1] = { text = "Only guild bank items", onClick = function()
        for _, loc in ipairs(ns.LOCATIONS) do s.locations[loc] = (loc == "guild") end
    end, tip = "Hide bags, banks, mail and equipped gear (the location buttons above do the same)." }
    items[#items + 1] = { text = "Hide guild banks", onClick = function() s.locations.guild = false end }
    return items
end

function WH:UpdateSelectors()
    local iv = self.frame and self.frame.itemsView
    if not iv then return end
    for kind, b in pairs(iv.selectors) do
        local text, active = self:SelectorState(kind)
        b.label:SetText(text .. "  |cffffd100v|r")
        SetFlatSelected(b, active)
    end
    local s = self.db.settings
    local all = true
    for _, loc in ipairs(ns.LOCATIONS) do if not s.locations[loc] then all = false end end
    for _, b in ipairs(iv.locButtons) do
        if b.loc then SetFlatSelected(b, s.locations[b.loc] and not all) else SetFlatSelected(b, all) end
    end
end

local function AfterFilterChange()
    WH:UpdateSelectors()
    WH:RefreshItems(true)
    WH:UpdateInfoLine()
end

-------------------------------------------------------------------------------
-- Filter menu
-------------------------------------------------------------------------------
local SORT_CHOICES = {
    { "name", "Name" }, { "total", "Total held" }, { "owners", "Characters holding it" },
    { "ilvl", "Item level" }, { "quality", "Quality" }, { "value", "Vendor value" }, { "recent", "Recently saved" },
}
local GROUP_CHOICES = {
    { "type", "Item type" }, { "location", "Location" }, { "owner", "Character" }, { "quality", "Quality" }, { "none", "Nothing" },
}
local QUALITY_CHOICES = { { 0, "Any quality" }, { 2, "Uncommon and better" }, { 3, "Rare and better" }, { 4, "Epic and better" } }

function WH:FilterItems()
    local s = self.db.settings
    local items = { { label = "Sort by" } }
    for _, o in ipairs(SORT_CHOICES) do
        items[#items + 1] = { text = o[2], checked = s.sort == o[1], onClick = function() s.sort = o[1] end }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Group by" }
    for _, o in ipairs(GROUP_CHOICES) do
        items[#items + 1] = { text = o[2], checked = s.groupBy == o[1], onClick = function() s.groupBy = o[1] end }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Show" }
    items[#items + 1] = { text = "Search item tooltips", checked = s.searchTooltips, onClick = function() s.searchTooltips = not s.searchTooltips end,
        tip = "Search stats, effects and everything else in each item's tooltip, not just names and types." }
    items[#items + 1] = { text = "Only items in 2 or more places", checked = s.multiOwner, onClick = function() s.multiOwner = not s.multiOwner end,
        tip = "Items held by two or more characters or guild banks: handy for gathering stacks onto one character." }
    items[#items + 1] = { text = ("Only mail expiring within %d %s"):format(s.expireDays, ns.Plural(s.expireDays, "day")), checked = s.expiringOnly,
        onClick = function() s.expiringOnly = not s.expiringOnly end, tip = "Change the number of days on the Options tab." }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Quality" }
    for _, o in ipairs(QUALITY_CHOICES) do
        items[#items + 1] = { text = o[2], checked = s.minQuality == o[1], onClick = function() s.minQuality = o[1] end }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = "Expand all groups", onClick = function() WH:SetAllCollapsed(false) end }
    items[#items + 1] = { text = "Collapse all groups", onClick = function() WH:SetAllCollapsed(true) end }
    return items
end

-------------------------------------------------------------------------------
-- Items view: header, item list, detail panel
-------------------------------------------------------------------------------
function WH:CreateItemsView(f)
    local iv = CreateFrame("Frame", nil, f)
    iv:SetAllPoints()
    f.itemsView = iv

    -- Header: item icon, name, type line, location bar and location buttons
    local iconBtn = CreateFrame("Button", nil, iv)
    iconBtn:SetSize(38, 38)
    iconBtn:SetPoint("TOPLEFT", 18, HEADER_Y + 1)
    UI.AddBorder(iconBtn, "BORDER", C.gold, 1, 1, 0)
    iv.icon = iconBtn:CreateTexture(nil, "ARTWORK")
    iv.icon:SetPoint("TOPLEFT", 2, -2)
    iv.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    iv.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconBtn:SetScript("OnEnter", function(self) if WH.selectedMeta then UI.ItemTooltip(self, WH.selectedMeta, WH.selectedAgg) end end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:SetScript("OnClick", function()
        if WH.selectedMeta and IsLinkClick() then WH:LinkItem(WH.selectedMeta) end
    end)

    iv.title = NoWrap(AddLabel(iv, "", "GameFontNormalLarge", C.header))
    iv.title:SetPoint("TOPLEFT", 66, HEADER_Y - 1)
    iv.title:SetWidth(W - 66 - 310)

    iv.stats = NoWrap(AddLabel(iv, "", "GameFontNormalSmall", C.legend))
    iv.stats:SetPoint("TOPRIGHT", -22, HEADER_Y - 4)
    iv.stats:SetJustifyH("RIGHT")
    iv.stats:SetWidth(290)

    local bar = UI.MakeLocationBar(iv, 16)
    bar:SetPoint("TOPLEFT", 66, HEADER_Y - 22)
    bar:SetPoint("TOPRIGHT", -(20 + LOC_W + 10), HEADER_Y - 22)
    iv.bar = bar
    iv.barWidth = W - 66 - (20 + LOC_W + 10)

    -- location buttons: All, then one toggle per location
    iv.locButtons = {}
    local locs = { false, "bags", "bank", "guild", "mail", "equipped" }
    for i = #locs, 1, -1 do
        local loc = locs[i]
        local b = FlatButton(iv, loc and ns.LOC_SHORT[loc] or "All", LOC_BTN_W, 18)
        b:SetPoint("TOPRIGHT", -20 - (#locs - i) * (LOC_BTN_W + 3), HEADER_Y - 21)
        b.loc = loc or nil
        b:SetScript("OnClick", function(self)
            local set = WH.db.settings.locations
            if not self.loc then
                for _, l in ipairs(ns.LOCATIONS) do set[l] = true end
            else
                local all = true
                for _, l in ipairs(ns.LOCATIONS) do if not set[l] then all = false end end
                if all then
                    -- from "everything", a click means "only this"
                    for _, l in ipairs(ns.LOCATIONS) do set[l] = (l == self.loc) end
                else
                    set[self.loc] = not set[self.loc]
                    local any = false
                    for _, l in ipairs(ns.LOCATIONS) do if set[l] then any = true end end
                    if not any then for _, l in ipairs(ns.LOCATIONS) do set[l] = true end end
                end
            end
            AfterFilterChange()
        end)
        if loc then
            AddHoverTip(b, ns.LOC_LABEL[loc], "Click to show only this location; click others to add them. All shows everything again.")
        else
            AddHoverTip(b, "All locations", "Bags, bank, guild banks, mail and equipped gear.")
        end
        iv.locButtons[#iv.locButtons + 1] = b
    end

    -- Left panel: search, filter, selectors and the item list
    UI.AddFieldBox(iv, LEFT_X, CONTENT_TOP, -(W - LEFT_R), CONTENT_BOT)

    local search = UI.MakeSearchBox("WarehouseSearchBox", iv, 214)
    search:SetPoint("TOPLEFT", LEFT_X + 6, CONTENT_TOP - 5)
    UI.AddPlaceholder(search, "Search names and tooltips")
    search:HookScript("OnTextChanged", function() WH:RequestUIRefresh(0.12) end)
    AddHoverTip(search, "Search", "Matches item names, item types and tooltip text: weapon and armor types, slots, stats and effects. "
        .. "Every word must match; put a phrase in quotes to match it exactly, like \"chance on hit\". A number on its own finds that item ID. "
        .. "With the box selected, shift-click an item in your bags to search for it.")
    f.search = search

    local filter = FlatButton(iv, "Filter  |cffffd100>|r", 84, 22)
    filter:SetPoint("TOPLEFT", LEFT_X + 226, CONTENT_TOP - 5)
    filter:SetScript("OnClick", function(self) UI.ShowMenu(self, function() return WH:FilterItems() end, 250, AfterFilterChange) end)
    iv.filter = filter

    iv.selectors = {}
    -- row one: Region, Ruleset, Faction; row two: Characters, Guild banks
    local rowW = LEFT_R - LEFT_X - 12
    local defs = {
        { "region",  function() return WH:SelectorItems("region") end, "Region", "US or EU characters (and their guild banks), as the game reports them. US includes Oceanic." },
        { "ruleset", function() return WH:SelectorItems("ruleset") end, "Ruleset", "Characters on PvE or PvP rulesets, as the game reports them when each character logs in." },
        { "faction", function() return WH:SelectorItems("faction") end, "Faction", "Horde or Alliance characters and guild banks." },
        { "who",     function() return WH:WhoItems() end, "Characters", "Everyone, the character you're playing, this ruleset, or one character." },
        { "guild",   function() return WH:GuildItems() end, "Guild banks", "Which guild banks, and which of their tabs, to include. The Guild button above shows or hides every guild bank." },
    }
    local w3 = math.floor((rowW - 2 * SEL_GAP) / 3)
    local w2 = math.floor((rowW - SEL_GAP) / 2)
    for i, d in ipairs(defs) do
        local row, col, w = 1, i - 1, w3
        if i > 3 then row, col, w = 2, i - 4, w2 end
        local b = FlatButton(iv, d[3], w, 20)
        b:SetPoint("TOPLEFT", LEFT_X + 6 + col * (w + SEL_GAP), CONTENT_TOP - 31 - (row - 1) * 24)
        local build = d[2]
        b:SetScript("OnClick", function(self) UI.ShowMenu(self, build, (d[1] == "who" or d[1] == "guild") and 250 or 220, AfterFilterChange) end)
        AddHoverTip(b, d[3], d[4])
        iv.selectors[d[1]] = b
    end

    local scroll, child = UI.MakeScroll("WarehouseItemScroll", iv, LIST_W)
    scroll:SetPoint("TOPLEFT", LIST_X, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", iv, "BOTTOMLEFT", LEFT_R - 24, CONTENT_BOT + 4)
    iv.itemList = UI.AttachVirtualList(scroll, child, ROW_H, function() return WH:MakeItemRow(child) end,
        function(row, e) WH:FillItemRow(row, e) end)

    iv.listEmpty = AddLabel(iv, "", "GameFontNormal", C.muted)
    iv.listEmpty:SetPoint("TOPLEFT", LIST_X + 10, LIST_TOP - 30)
    iv.listEmpty:SetWidth(LIST_W - 20)
    iv.listEmpty:SetJustifyH("CENTER")
    if iv.listEmpty.SetSpacing then iv.listEmpty:SetSpacing(3) end

    -- Right panel: chart, summary, where it is
    UI.AddFieldBox(iv, RIGHT_X, CONTENT_TOP, -16, CONTENT_BOT)
    local d = CreateFrame("Frame", nil, iv)
    d:SetPoint("TOPLEFT", RIGHT_X, CONTENT_TOP)
    d:SetPoint("BOTTOMRIGHT", -16, CONTENT_BOT)
    iv.detail = d
    self:CreateChart(d)
    self:CreateSummary(d)
end

-------------------------------------------------------------------------------
-- Item list rows
-------------------------------------------------------------------------------
function WH:MakeItemRow(child)
    local row = CreateFrame("Button", nil, child)
    row:SetSize(LIST_W, ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    -- group header look: dark plate with gold edge, gold text and -/+
    row.hbg = row:CreateTexture(nil, "BACKGROUND")
    row.hbg:SetPoint("TOPLEFT", 0, -1)
    row.hbg:SetPoint("BOTTOMRIGHT", 0, 1)
    row.hbg:SetColorTexture(0.22, 0.14, 0.06, 1)
    row.hedges = {}
    local function hedge(p1, p2, w, h)
        local e = row:CreateTexture(nil, "BORDER")
        e:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
        e:SetPoint(p1, row.hbg, p1)
        e:SetPoint(p2, row.hbg, p2)
        if w then e:SetWidth(w) end
        if h then e:SetHeight(h) end
        row.hedges[#row.hedges + 1] = e
    end
    hedge("TOPLEFT", "TOPRIGHT", nil, 1)
    hedge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    hedge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    hedge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    row.htext = NoWrap(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    row.htext:SetPoint("LEFT", 8, 0)
    row.htext:SetPoint("RIGHT", -60, 0)
    row.htext:SetJustifyH("LEFT")
    SetColor(row.htext, C.header)
    row.htoggle = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.htoggle:SetPoint("RIGHT", -8, 0)
    SetColor(row.htoggle, C.header)
    row.hcount = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.hcount:SetPoint("RIGHT", -26, 0)
    SetColor(row.hcount, C.muted)

    -- item look
    row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.32)
    row.selBar = row:CreateTexture(nil, "ARTWORK")
    row.selBar:SetPoint("TOPLEFT")
    row.selBar:SetPoint("BOTTOMLEFT")
    row.selBar:SetWidth(2)
    row.selBar:SetColorTexture(1, 0.82, 0.2, 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.text = NoWrap(row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    row.text:SetPoint("LEFT", 28, 0)
    row.text:SetPoint("RIGHT", -82, 0)
    row.text:SetJustifyH("LEFT")
    row.value = NoWrap(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    row.value:SetPoint("RIGHT", -6, 0)
    row.value:SetJustifyH("RIGHT")
    row.value:SetWidth(76)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 0, -1)
    hl:SetPoint("BOTTOMRIGHT", 0, 1)
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.16)

    row:SetScript("OnClick", function(self)
        local e = self.item
        if not e then return end
        if e.header then
            WH:ToggleGroup(e.ckey)
        elseif IsLinkClick() then
            WH:LinkItem(e.m)
        else
            WH:SelectItem(e.m.key)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local e = self.item
        if e and not e.header then UI.ItemTooltip(self, e.m, e.a) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function ShortAgo(t)
    if not t or t <= 0 then return "—" end
    local d = time() - t
    if d < 3600 then return math.max(1, math.floor(d / 60)) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

-- The number on the right of each item row, by sort
local VALUE_TEXT = {
    owners = function(e) return Hex(C.text) .. e.a.nOwners .. " " .. ns.Plural(e.a.nOwners, "owner") .. "|r" end,
    ilvl   = function(e) return e.ilvl and (Hex(C.text) .. "ilvl " .. e.ilvl .. "|r") or (GREY .. "—|r") end,
    value  = function(e) return e.value and (e.value > 0 and ns.Money(e.value) or (GREY .. "no value|r")) or (GREY .. "—|r") end,
    recent = function(e) return GREY .. ShortAgo(e.a.latest) .. "|r" end,
}

function WH:FillItemRow(row, e)
    row.item = e
    local isHeader = e.header and true or false
    row.hbg:SetShown(isHeader)
    UI.SetEdgesShown(row.hedges, isHeader)
    row.htext:SetShown(isHeader)
    row.htoggle:SetShown(isHeader)
    row.hcount:SetShown(isHeader)
    row.icon:SetShown(not isHeader)
    row.text:SetShown(not isHeader)
    row.value:SetShown(not isHeader)
    if isHeader then
        row.sel:Hide()
        row.selBar:Hide()
        row.htext:SetText(e.name)
        row.htoggle:SetText(e.collapsed and "+" or "–")
        row.hcount:SetText(ns.Commas(e.n))
        return
    end
    local m = e.m
    local selected = m.key == self.selectedKey
    row.sel:SetShown(selected)
    row.selBar:SetShown(selected)
    row.icon:SetTexture(m.icon or QUESTION)
    row.text:SetText(DisplayName(m))
    if m.name then SetColor(row.text, UI.QualityRGB(m.quality)) else SetColor(row.text, C.muted) end
    local fmt = VALUE_TEXT[self.db.settings.sort]
    if fmt then
        row.value:SetText(fmt(e))
    else
        local soon = e.a.soonest and e.a.soonest <= time() + self.db.settings.expireDays * 86400
        row.value:SetText(Hex(soon and C.warn or C.text) .. "x" .. ns.Commas(e.n) .. "|r")
    end
end

-------------------------------------------------------------------------------
-- The list: group headers + rows, built from Index:Build()
-------------------------------------------------------------------------------
local function ByName(x, y)
    if x.m.sn ~= y.m.sn then return x.m.sn < y.m.sn end
    if x.m.key ~= y.m.key then return x.m.key < y.m.key end
    return (x.n or 0) > (y.n or 0)
end

local SORTS = {
    name    = ByName,
    total   = function(x, y) if x.n ~= y.n then return x.n > y.n end return ByName(x, y) end,
    owners  = function(x, y) if x.a.nOwners ~= y.a.nOwners then return x.a.nOwners > y.a.nOwners end return ByName(x, y) end,
    quality = function(x, y)
        local p, q = x.m.quality or 1, y.m.quality or 1
        if p ~= q then return p > q end
        return ByName(x, y)
    end,
    recent  = function(x, y) if x.a.latest ~= y.a.latest then return x.a.latest > y.a.latest end return ByName(x, y) end,
    ilvl    = function(x, y)
        local p, q = x.ilvl or -1, y.ilvl or -1
        if p ~= q then return p > q end
        return ByName(x, y)
    end,
    value   = function(x, y)
        local p, q = x.value or -1, y.value or -1
        if p ~= q then return p > q end
        return ByName(x, y)
    end,
}

-- How each grouping places an item: one row per group it belongs to
local GROUPERS = {
    type     = function(a, m, Put) Put(m.typeName or OTHER, { a = a, m = m, n = a.total }) end,
    quality  = function(a, m, Put) Put(m.quality or 1, { a = a, m = m, n = a.total }) end,
    none     = function(a, m, Put) Put("", { a = a, m = m, n = a.total }) end,
    location = function(a, m, Put) for loc, n in pairs(a.loc) do Put(loc, { a = a, m = m, n = n, loc = loc }) end end,
    owner    = function(a, m, Put) for ok, n in pairs(a.by) do Put(ok, { a = a, m = m, n = n, owner = ok }) end end,
}

local LOC_ORDER = {}
for i, loc in ipairs(ns.LOCATIONS) do LOC_ORDER[loc] = i end

-- Group header text and order, per grouping
local function GroupInfo(mode, owners)
    if mode == "quality" then
        return function(q) return Hex(UI.QualityRGB(q)) .. UI.QualityName(q) .. "|r" end,
               function(a, b) return a > b end
    elseif mode == "location" then
        return function(loc) return ns.LOC_LABEL[loc] end,
               function(a, b) return LOC_ORDER[a] < LOC_ORDER[b] end
    elseif mode == "owner" then
        local function Label(k)
            local o = owners[k]
            if not o then return k end
            local extra = o.kind == "char" and (GREY .. "  " .. ns.PlaceText(o.rec) .. "|r") or ""
            return ns.OwnerLabel(o.kind, o.rec) .. extra
        end
        return Label, function(a, b)
            local x, y = owners[a], owners[b]
            if (a == Scan.meKey) ~= (b == Scan.meKey) then return a == Scan.meKey end
            if x and y and x.kind ~= y.kind then return x.kind == "char" end
            local nx, ny = x and x.rec.name or a, y and y.rec.name or b
            if nx ~= ny then return nx < ny end
            return a < b
        end
    end
    return function(k) return k end, function(a, b)
        if (a == OTHER) ~= (b == OTHER) then return b == OTHER end
        return a < b
    end
end

WH.searchCollapsed = {}

function WH:CollapseState()
    return self.searchActive and self.searchCollapsed or self.db.collapsed
end

function WH:ToggleGroup(ckey)
    local state = self:CollapseState()
    state[ckey] = not state[ckey] or nil
    self:RefreshItems()
end

function WH:SetAllCollapsed(collapse)
    local state = self:CollapseState()
    local mode = self.db.settings.groupBy
    for ckey in pairs(state) do
        if ckey:sub(1, #mode + 1) == mode .. ":" then state[ckey] = nil end
    end
    if collapse and self.lastGroupKeys then
        for _, ckey in ipairs(self.lastGroupKeys) do state[ckey] = true end
    end
    self:RefreshItems()
end

function WH:BuildEntries(searchText)
    local s = self.db.settings
    local data = Index:Build()
    local terms = Index.ParseSearch(searchText)
    local searching = #terms > 0
    -- searches keep their own open/closed state: every search starts with all
    -- groups open, and closing one doesn't change the saved layout
    self.searchActive = searching
    if not searching then wipe(self.searchCollapsed) end
    local useTips = s.searchTooltips
    local limit = time() + s.expireDays * 86400
    local mode = GROUPERS[s.groupBy] and s.groupBy or "type"
    local needFacts = s.sort == "ilvl" or s.sort == "value"

    local groups, order = {}, {}
    local function Put(gkey, row)
        local g = groups[gkey]
        if not g then
            g = { key = gkey, rows = {} }
            groups[gkey] = g
            order[#order + 1] = gkey
        end
        if needFacts then
            local f = Scan:Facts(row.m.key)
            if f then
                row.ilvl = f.ilvl
                row.value = f.sell and f.sell * row.n or nil
            end
        end
        g.rows[#g.rows + 1] = row
    end

    local total = 0
    for key, a in pairs(data.items) do
        total = total + 1
        local m = Index:Meta(key)
        local pass = true
        if s.minQuality > 0 and (m.quality or 1) < s.minQuality then pass = false end
        if pass and s.multiOwner and a.nOwners < 2 then pass = false end
        if pass and s.expiringOnly and not (a.soonest and a.soonest <= limit) then pass = false end
        if pass and searching then pass = Index:Matches(m, terms, useTips) end
        if pass then GROUPERS[mode](a, m, Put) end
    end

    local label, less = GroupInfo(mode, data.owners)
    table.sort(order, less)
    local cmp = SORTS[s.sort] or SORTS.name
    local state = self:CollapseState()
    local entries, groupKeys = {}, {}
    for _, gkey in ipairs(order) do
        local g = groups[gkey]
        local ckey = mode .. ":" .. tostring(gkey)
        groupKeys[#groupKeys + 1] = ckey
        local collapsed = mode ~= "none" and state[ckey] or false
        if mode ~= "none" then
            entries[#entries + 1] = { header = true, name = label(gkey), ckey = ckey, n = #g.rows, collapsed = collapsed }
        end
        if not collapsed then
            table.sort(g.rows, cmp)
            for _, r in ipairs(g.rows) do entries[#entries + 1] = r end
        end
    end
    self.lastGroupKeys = groupKeys
    return entries, total
end

function WH:RefreshItems(resetScroll)
    local f = self.frame
    if not f or not f.itemsView:IsShown() then return end
    local iv = f.itemsView
    local search = f.search:GetText() or ""
    local entries, total = self:BuildEntries(search)
    if self.searchActive then Index:EnsureTooltips() end
    iv.itemList:SetData(entries, resetScroll or search ~= self.lastSearch)
    self.lastSearch = search

    local empty
    if not next(self.db.chars) then
        empty = "Nothing saved yet.\n\nWarehouse saves your bags and gear as soon as you log in, and your bank, guild bank and mailbox each time you open them."
    elseif #entries == 0 then
        if ns.Trim(search) ~= "" then
            local done, all = Index:TooltipProgress()
            if done and self.db.settings.searchTooltips then
                empty = ("Nothing matches \"%s\" yet.\n\nItem tooltips are still being read (%s of %s)."):format(ns.Trim(search), ns.Commas(done), ns.Commas(all))
            else
                empty = ("Nothing matches \"%s\".\n\nAn item ID always works; tooltip text can be searched from the Filter menu."):format(ns.Trim(search))
            end
        elseif total == 0 then
            empty = "No character passes the filters.\n\nCheck Region, Ruleset, Faction, Characters and the location buttons above."
        else
            empty = "No item passes the filters.\n\nCheck the Filter menu."
        end
    end
    iv.listEmpty:SetText(empty or "")
    iv.listEmpty:SetShown(empty ~= nil)
    self:UpdateSelectors()
    self:RefreshDetail()
end

function WH:SelectItem(key)
    self.selectedKey = (self.selectedKey ~= key) and key or nil       -- click again to go back to the overview
    self.frame.itemsView.itemList:Render()
    self:RefreshDetail()
end

-------------------------------------------------------------------------------
-- Holdings chart: one bar per owner, split by location
-------------------------------------------------------------------------------
function WH:CreateChart(d)
    local g = CreateFrame("Frame", nil, d)
    g:SetSize(CW, CH)
    g:SetPoint("TOPLEFT", 12, -12)
    d.chart = g

    g.title = NoWrap(AddLabel(g, "", "GameFontNormalSmall", C.legend))
    g.title:SetPoint("TOPLEFT", 2, 0)
    g.title:SetWidth(CW - 4)

    local trackW = CW - NAME_W - COUNT_W
    g.trackW = trackW
    local axis = g:CreateTexture(nil, "BORDER")
    axis:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.9)
    axis:SetPoint("TOPLEFT", NAME_W - 4, -18)
    axis:SetPoint("BOTTOMLEFT", NAME_W - 4, 2)
    axis:SetWidth(1)

    g.rows = {}
    for i = 1, BAR_ROWS do
        local r = CreateFrame("Button", nil, g)
        r:SetSize(CW, BAR_H)
        r:SetPoint("TOPLEFT", 0, -18 - (i - 1) * BAR_H)
        r.name = NoWrap(AddLabel(r, "", "GameFontHighlightSmall", C.text))
        r.name:SetPoint("RIGHT", r, "LEFT", NAME_W - 10, 0)
        r.name:SetWidth(NAME_W - 14)
        r.name:SetJustifyH("RIGHT")
        r.bar = UI.MakeLocationBar(r, BAR_H - 6)
        r.bar:SetPoint("LEFT", NAME_W, 0)
        r.bar:SetWidth(trackW)
        r.bar.text:Hide()
        r.count = NoWrap(AddLabel(r, "", "GameFontHighlightSmall", C.text))
        r.count:SetPoint("RIGHT", -2, 0)
        r.count:SetWidth(COUNT_W - 6)
        r.count:SetJustifyH("RIGHT")
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.12)
        r:SetScript("OnEnter", function(self) WH:ChartHover(self) end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self)
            local o = self.owner
            if not o or not o.key then return end
            if o.kind == "char" then WH:PickOwner(o.key) elseif o.kind == "guild" then WH:PickGuild(o.key) end
        end)
        r:Hide()
        g.rows[i] = r
    end

    g.empty = AddLabel(g, "", "GameFontNormal", C.muted)
    g.empty:SetPoint("CENTER", 0, -8)
    g.empty:SetWidth(CW - 40)
    g.empty:SetJustifyH("CENTER")
    if g.empty.SetSpacing then g.empty:SetSpacing(3) end

    -- legend under the chart
    local lg = CreateFrame("Frame", nil, d)
    lg:SetSize(CW, 16)
    lg:SetPoint("TOPLEFT", 12, -12 - CH - 3)
    local x = NAME_W
    for _, loc in ipairs(ns.LOCATIONS) do
        local t = lg:CreateTexture(nil, "ARTWORK")
        local rgb = UI.LOC_RGB[loc]
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.85)
        t:SetSize(10, 10)
        t:SetPoint("LEFT", x, 0)
        local fs = AddLabel(lg, ns.LOC_LABEL[loc], "GameFontNormalSmall", C.muted)
        fs:SetPoint("LEFT", t, "RIGHT", 4, 0)
        x = x + 10 + 4 + math.max(40, fs:GetStringWidth()) + 12
    end
end

function WH:ChartHover(r)
    local o = r.owner
    if not o then return end
    local mu = C.muted
    GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
    if o.kind == "others" then
        GameTooltip:AddLine(("%d more"):format(o.count), 1, 0.82, 0)
    else
        GameTooltip:AddLine(ns.OwnerLabel(o.kind, o.rec), 1, 1, 1)
        GameTooltip:AddLine(("%s  •  %s"):format(ns.PlaceText(o.rec, true), o.rec.faction or "?"), mu[1], mu[2], mu[3])
    end
    GameTooltip:AddLine(" ")
    for _, loc in ipairs(ns.LOCATIONS) do
        local n = o.loc[loc]
        if n then
            local rgb = UI.LOC_RGB[loc]
            GameTooltip:AddDoubleLine(Hex(rgb) .. "■|r " .. ns.LOC_LABEL[loc], ns.Commas(n), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddDoubleLine("Total", ns.Commas(o.n), 1, 0.82, 0, 1, 1, 1)
    if o.kind == "char" then
        GameTooltip:AddLine(o.key == Scan.meKey and "Playing now" or ("Last seen " .. ns.Ago(o.rec.lastSeen)), mu[1], mu[2], mu[3])
        GameTooltip:AddLine("Click to show only this character's items", mu[1], mu[2], mu[3])
    elseif o.kind == "guild" then
        GameTooltip:AddLine("Click to show only this guild bank's items", mu[1], mu[2], mu[3])
    end
    GameTooltip:Show()
end

-- list: { { kind, key, rec, n, loc } } sorted, most first
function WH:DrawChart(list, title, emptyText)
    local g = self.frame.itemsView.detail.chart
    g.title:SetText(title or "")
    local shown = list
    if #list > BAR_ROWS then
        shown = {}
        local others = { kind = "others", n = 0, loc = {}, count = #list - BAR_ROWS + 1 }
        for i, o in ipairs(list) do
            if i < BAR_ROWS then
                shown[i] = o
            else
                others.n = others.n + o.n
                for loc, n in pairs(o.loc) do others.loc[loc] = (others.loc[loc] or 0) + n end
            end
        end
        shown[BAR_ROWS] = others
    end
    local maxN = 0
    for _, o in ipairs(shown) do if o.n > maxN then maxN = o.n end end
    for i, r in ipairs(g.rows) do
        local o = shown[i]
        r.owner = o
        if o then
            if o.kind == "others" then
                r.name:SetText(("%s%d more|r"):format(GREY, o.count))
            else
                r.name:SetText(ns.OwnerLabel(o.kind, o.rec) .. ((o.key == Scan.meKey) and " |cffffd100•|r" or ""))
            end
            UI.SetLocationBar(r.bar, o.loc, maxN, g.trackW)
            r.count:SetText(ns.Commas(o.n))
            r:Show()
        else
            r:Hide()
        end
    end
    g.empty:SetText(#list == 0 and (emptyText or "") or "")
end

-------------------------------------------------------------------------------
-- Summary and "where it is"
-------------------------------------------------------------------------------
local SUMMARY = { "total", "owners", "bags", "bank", "guild", "mail", "equipped", "extra" }
local SUMMARY_LABELS = {
    item = { total = "Total held", owners = "Held by", bags = "In bags", bank = "In banks", guild = "In guild banks",
             mail = "In mail", equipped = "Equipped", extra = "Vendor value" },
    all  = { total = "Items", owners = "Owners", bags = "In bags", bank = "In banks", guild = "In guild banks",
             mail = "In mail", equipped = "Equipped", extra = "Gold" },
}

function WH:CreateSummary(d)
    local y0 = -12 - CH - 26
    UI.AddSection(d, "Summary", y0, 12, -12)
    d.sum, d.sumLabel = {}, {}
    local colW = math.floor((DW - 24) / 2)
    for i, key in ipairs(SUMMARY) do
        local col, rowN = (i - 1) % 2, math.floor((i - 1) / 2)
        local x, y = 14 + col * colW, y0 - 24 - rowN * 16
        local label = AddLabel(d, SUMMARY_LABELS.item[key], "GameFontNormalSmall", C.muted)
        label:SetPoint("TOPLEFT", x, y)
        local value = NoWrap(AddLabel(d, "", "GameFontHighlightSmall", C.text))
        value:SetPoint("TOPLEFT", x + 96, y)
        value:SetWidth(colW - 100)
        d.sum[key], d.sumLabel[key] = value, label
    end

    local y1 = y0 - 24 - 4 * 16 - 10
    d.whereTitle = UI.AddSection(d, "Where It Is", y1, 12, -12)
    d.heads = {}
    local xs = { 16, 188, 344 }
    local texts = { "Owner", "Where", "Saved" }
    for i = 1, 3 do
        local fs = AddLabel(d, texts[i], "GameFontNormalSmall", C.muted)
        fs:SetPoint("TOPLEFT", xs[i], y1 - 22)
        d.heads[i] = fs
    end
    d.heads[4] = AddLabel(d, "Count", "GameFontNormalSmall", C.muted)
    d.heads[4]:SetPoint("TOPRIGHT", -44, y1 - 22)
    d.heads[4]:SetJustifyH("RIGHT")

    local listW = DW - 24 - 24
    local scroll, child = UI.MakeScroll("WarehouseWhereScroll", d, listW)
    scroll:SetPoint("TOPLEFT", 12, y1 - 38)
    scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -36, 8)
    d.whereList = UI.AttachVirtualList(scroll, child, WHERE_ROW_H, function()
        local row = CreateFrame("Button", nil, child)
        row:SetSize(listW, WHERE_ROW_H)
        row.owner = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.owner:SetPoint("LEFT", 4, 0)
        row.owner:SetWidth(168)
        row.where = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.where:SetPoint("LEFT", 176, 0)
        row.where:SetWidth(150)
        row.saved = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.muted))
        row.saved:SetPoint("LEFT", 332, 0)
        row.saved:SetWidth(90)
        row.count = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.count:SetPoint("RIGHT", -8, 0)
        row.count:SetJustifyH("RIGHT")
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.14)
        row:SetScript("OnEnter", function(self) if self.item then WH:WhereHover(self, self.item) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            local r = self.item
            if not r or not r.owner then return end
            if r.kind == "char" then WH:PickOwner(r.owner) elseif r.kind == "guild" then WH:PickGuild(r.owner) end
        end)
        return row
    end, function(row, r, idx)
        UI.StripeRow(row, idx)
        row.item = r
        local area = r.rec.area and (" " .. GREY .. ns.AREAS[r.rec.area] .. "|r") or ""
        row.owner:SetText(ns.OwnerLabel(r.kind, r.rec) .. area)
        row.where:SetText(WH:WhereText(r))
        row.saved:SetText(ns.Ago(r.t))
        row.count:SetText(ns.Commas(r.n))
    end)
    d.whereEmpty = AddLabel(d, "", "GameFontNormalSmall", C.muted)
    d.whereEmpty:SetPoint("TOPLEFT", 18, y1 - 44)
    d.whereEmpty:SetWidth(DW - 50)
end

function WH:WhereText(r)
    if r.overview then return r.whereText end
    if r.loc == "guild" then return "Guild: " .. (r.tabName or ("Tab " .. tostring(r.tab))) end
    if r.loc == "mail" then
        if r.inTransit and not r.x then return Hex(UI.LOC_RGB.mail) .. "Mail|r " .. GREY .. "(on its way)|r" end
        if r.x then
            local soon = r.x <= time() + self.db.settings.expireDays * 86400
            return "Mail " .. Hex(soon and C.warn or C.muted) .. "(expires " .. ns.Until(r.x) .. ")|r"
        end
        return "Mail"
    end
    return ns.LOC_LABEL[r.loc] or r.loc
end

function WH:WhereHover(row, r)
    local mu = C.muted
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.OwnerLabel(r.kind, r.rec), 1, 1, 1)
    GameTooltip:AddLine(("%s  •  %s"):format(ns.PlaceText(r.rec, true), r.rec.faction or "?"), mu[1], mu[2], mu[3], true)
    if r.overview then
        GameTooltip:AddLine(" ")
        for _, loc in ipairs(ns.LOCATIONS) do
            local n = r.locCounts[loc]
            if n then GameTooltip:AddDoubleLine(ns.LOC_LABEL[loc], ns.Commas(n), mu[1], mu[2], mu[3], 1, 1, 1) end
        end
        if r.kind == "char" then
            GameTooltip:AddDoubleLine("Gold", ns.Coins(r.rec.money), mu[1], mu[2], mu[3], 1, 1, 1)
            GameTooltip:AddLine("Click to show only this character's items", mu[1], mu[2], mu[3])
        elseif r.rec.money then
            GameTooltip:AddDoubleLine("Gold", ns.Coins(r.rec.money), mu[1], mu[2], mu[3], 1, 1, 1)
            GameTooltip:AddLine("Click to show only this guild bank's items", mu[1], mu[2], mu[3])
        end
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(ns.LOC_LABEL[r.loc] .. (r.tabName and (": " .. r.tabName) or ""), ns.Commas(r.n), mu[1], mu[2], mu[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Saved", ns.Ago(r.t), mu[1], mu[2], mu[3], 1, 1, 1)
    if r.mails then
        GameTooltip:AddLine(" ")
        for i, e in ipairs(r.mails) do
            if i > 10 then GameTooltip:AddLine(("+ %d more"):format(#r.mails - 10), mu[1], mu[2], mu[3]) break end
            local when = e.sent and "on its way" or ("expires " .. ns.Until(e.x))
            local from = e.f and ("from " .. e.f) or "from unknown"
            local flags = (e.cod and "  |cffff6040COD|r" or "") .. (e.ret and (GREY .. "  returned|r") or "")
            GameTooltip:AddDoubleLine(("%s %s%s"):format(ns.Commas(e.c), from, flags), when, 1, 1, 1, mu[1], mu[2], mu[3])
        end
    end
    if r.kind == "char" and r.owner ~= Scan.meKey and r.loc == "bank" then
        GameTooltip:AddLine("The bank is saved each time this character opens it.", mu[1], mu[2], mu[3], true)
    end
    if r.kind == "char" then
        GameTooltip:AddLine("Click to show only this character's items", mu[1], mu[2], mu[3])
    elseif r.kind == "guild" then
        GameTooltip:AddLine("Click to show only this guild bank's items", mu[1], mu[2], mu[3])
    end
    GameTooltip:Show()
end

local function OwnerList(owners)
    local list = {}
    for _, o in pairs(owners) do if o.n > 0 then list[#list + 1] = o end end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return list
end

local function BarText(total, loc)
    local parts = {}
    for _, l in ipairs(ns.LOCATIONS) do
        local n = loc[l]
        if n then parts[#parts + 1] = ("%s %s"):format(ns.Commas(n), ns.LOC_LABEL[l]:lower()) end
    end
    if total == 0 then return "Nothing held with these filters" end
    return ("%s held: %s"):format(ns.Commas(total), table.concat(parts, ", "))
end

function WH:RefreshDetail()
    local f = self.frame
    if not f or not f.itemsView:IsShown() then return end
    local iv, d = f.itemsView, f.itemsView.detail
    local data = Index:Build()
    local key = self.selectedKey
    local a = key and data.items[key] or nil
    local m = key and Index:Meta(key) or nil
    self.selectedMeta, self.selectedAgg = m, a
    local labels = m and SUMMARY_LABELS.item or SUMMARY_LABELS.all
    for _, k in ipairs(SUMMARY) do
        d.sumLabel[k]:SetText(labels[k])
        d.sum[k]:SetText(GREY .. "—|r")
    end

    if m then
        -- header
        iv.icon:SetTexture(m.icon or QUESTION)
        iv.title:SetText(DisplayName(m))
        SetColor(iv.title, m.name and UI.QualityRGB(m.quality) or C.muted)
        local parts = {}
        if m.typeName then parts[#parts + 1] = m.typeName end
        if m.subName and m.subName ~= m.typeName then parts[#parts + 1] = m.subName end
        if m.slotName then parts[#parts + 1] = m.slotName end
        local facts = Scan:Facts(key)
        if facts and facts.ilvl and m.cls and (m.cls == 2 or m.cls == 4) then parts[#parts + 1] = "item level " .. facts.ilvl end
        parts[#parts + 1] = "item " .. tostring(m.id or key)
        iv.stats:SetText(table.concat(parts, "  •  "))
        local loc = a and a.loc or {}
        UI.SetLocationBar(iv.bar, loc, nil, iv.barWidth)
        iv.bar.text:SetText(BarText(a and a.total or 0, loc))

        -- chart: owners of this item
        local rows = Index:Holders(key)
        local byOwner, list = {}, {}
        for _, r in ipairs(rows) do
            local o = byOwner[r.owner]
            if not o then
                o = { kind = r.kind, key = r.owner, rec = r.rec, n = 0, loc = {} }
                byOwner[r.owner] = o
                list[#list + 1] = o
            end
            o.n = o.n + r.n
            o.loc[r.loc] = (o.loc[r.loc] or 0) + r.n
        end
        table.sort(list, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.key < y.key end)
        self:DrawChart(list, ("Who holds %s"):format(DisplayName(m)),
            "None of the filtered characters holds this item.\n\nCheck the filters, or the location buttons above.")

        -- summary
        if a then
            d.sum.total:SetText(ns.Commas(a.total))
            local chars, guilds = 0, 0
            for ok in pairs(a.by) do
                if data.owners[ok] and data.owners[ok].kind == "guild" then guilds = guilds + 1 else chars = chars + 1 end
            end
            local who = {}
            if chars > 0 then who[#who + 1] = ("%d %s"):format(chars, ns.Plural(chars, "character")) end
            if guilds > 0 then who[#who + 1] = ("%d %s"):format(guilds, ns.Plural(guilds, "guild bank")) end
            d.sum.owners:SetText(table.concat(who, ", "))
            for _, l in ipairs(ns.LOCATIONS) do
                local n = a.loc[l]
                d.sum[l]:SetText(n and ns.Commas(n) or (GREY .. "none|r"))
            end
            if a.soonest then
                d.sum.mail:SetText(("%s  %s(first expires %s)|r"):format(ns.Commas(a.loc.mail or 0),
                    Hex(a.soonest <= time() + self.db.settings.expireDays * 86400 and C.warn or C.muted), ns.Until(a.soonest)))
            end
            if facts and facts.sell then
                d.sum.extra:SetText(facts.sell > 0 and (ns.Coins(facts.sell * a.total) .. ("  %s(%s each)|r"):format(GREY, ns.PlainMoney(facts.sell)))
                    or (GREY .. "vendors won't buy it|r"))
            elseif not facts then
                d.sum.extra:SetText(GREY .. "loading...|r")
            end
        end
        d.whereTitle:SetText("Where It Is")
        d.whereList:SetData(rows, true)
        d.whereEmpty:SetText(#rows == 0 and "Not held by the filtered characters." or "")
        return
    end

    -- nothing selected: the overview
    local t = data.totals
    iv.icon:SetTexture(ICON)
    iv.title:SetText("Everything Your Characters Hold")
    SetColor(iv.title, C.header)
    iv.stats:SetText(("%d %s  •  %d %s"):format(t.chars, ns.Plural(t.chars, "character"), t.guilds, ns.Plural(t.guilds, "guild bank")))
    UI.SetLocationBar(iv.bar, t.loc, nil, iv.barWidth)
    iv.bar.text:SetText(t.items > 0 and BarText(t.items, t.loc) or "Select an item to see where it is")

    local owners = OwnerList(data.owners)
    self:DrawChart(owners, "Items held, by character and guild bank",
        next(self.db.chars) and "No character passes the filters." or "Nothing saved yet.")

    d.sum.total:SetText(ns.Commas(t.items))
    d.sum.owners:SetText(("%d %s, %d %s"):format(t.chars, ns.Plural(t.chars, "character"), t.guilds, ns.Plural(t.guilds, "guild bank")))
    for _, l in ipairs(ns.LOCATIONS) do d.sum[l]:SetText(ns.Commas(t.loc[l] or 0)) end
    d.sum.extra:SetText(ns.Coins(t.gold + t.mailGold + t.guildGold))

    local rows = {}
    for _, o in ipairs(owners) do
        local where = {}
        for _, l in ipairs(ns.LOCATIONS) do if o.loc[l] then where[#where + 1] = ns.LOC_SHORT[l] end end
        local saved = o.kind == "char" and o.rec.lastSeen or o.rec.t
        rows[#rows + 1] = { overview = true, kind = o.kind, owner = o.key, rec = o.rec, n = o.n, t = saved,
                            whereText = table.concat(where, ", "), locCounts = o.loc }
    end
    d.whereTitle:SetText("Owners")
    d.whereList:SetData(rows, true)
    d.whereEmpty:SetText(#rows == 0 and "Nothing to show." or "")
end
