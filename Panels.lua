local addonName, ns = ...
-- Panels.lua
--   * Characters tab: every saved character (region, realm ruleset, faction,
--     gold, last seen), each realm's ruleset, the guild banks and gold totals
--   * Options tab: what's saved, item tooltips, mail warnings, display,
--     storage used, this character, and a client capability check
--   * Game Options -> AddOns entry, addon compartment, minimap button, the
--     shift-click-to-search hook and the confirmation dialogs
-- The only protected UI touched is the Blizzard Settings panel, closed
-- through ns.AfterCombat.

local WH, Scan, Index, UI = ns.WH, ns.Scan, ns.Index, ns.UI
local C, GREY = UI.C, UI.GREY
local SetColor, Hex, AddLabel, NoWrap = UI.SetColor, UI.Hex, UI.AddLabel, UI.NoWrap
local FlatButton, SetFlatSelected, AddHoverTip = UI.FlatButton, UI.SetFlatSelected, UI.AddHoverTip
local W, H = UI.W, UI.H

-------------------------------------------------------------------------------
-- Characters tab
-------------------------------------------------------------------------------
local CH_LEFT_R, CH_RIGHT_X = 520, 548
local CHAR_ROW_H, REALM_ROW_H, GUILD_ROW_H = 36, 22, 34

-- long: say where the ruleset came from
local function RulesetText(rec, long)
    local rs = ns.RULESETS[rec.ruleset or ""]
    if not rs then return "|cffff6040ruleset not set|r" end
    if rec.rulesetGuessed then return rs.label .. " (from the realm name)" end
    if long then
        if rec.rulesetDetected then return rs.label .. " (from the game)" end
        return rs.label .. " (set by you, or by a character on the same server)"
    end
    return rs.label
end

-- A ruleset the game reported can't be changed by hand
local function ReadOnlyRuleset(items, rs)
    items[#items + 1] = { label = ("%s, read from the game"):format(ns.RULESETS[rs] and ns.RULESETS[rs].label or "?"), muted = true }
    return items
end

-- Ruleset radio items; set(ruleset) applies the choice
local function RulesetChoices(items, current, set)
    for _, k in ipairs(ns.RULESET_ORDER) do
        local rs = ns.RULESETS[k]
        items[#items + 1] = { text = ("%s  %s(%s)|r"):format(rs.label, GREY, ns.RULE_GROUPS[rs.group]), checked = current == k,
            onClick = function() set(k) end }
    end
    items[#items + 1] = { text = "Not set", checked = (current or "") == "", onClick = function() set("") end }
    return items
end

function WH:CharMenuItems(key)
    local c = self.db.chars[key]
    if not c then return {} end
    local items = {
        { label = c.name },
        { text = "Show only their items", onClick = function() WH:PickOwner(key) end },
        { separator = true },
        { label = "Ruleset" },
    }
    if c.rulesetDetected then
        ReadOnlyRuleset(items, c.ruleset)
    else
        RulesetChoices(items, c.ruleset, function(rs) Scan:SetCharRuleset(key, rs) end)
    end
    items[#items + 1] = { separator = true }
    if key == Scan.meKey then
        items[#items + 1] = { label = "You're playing this character", muted = true }
    else
        items[#items + 1] = { text = "Forget " .. c.name .. "...", onClick = function() WH:ConfirmForgetChar(key) end }
    end
    return items
end

-- A realm's display name: its name when the client gave one, else its server number
local function RealmLabel(r)
    if r.name and r.name ~= "" then return r.name end
    if r.server then return "Server " .. r.server end
    return "Unknown realm"
end

function WH:RulesetMenuItems(realmKey)
    local r = self.db.realms[realmKey]
    if not r then return {} end
    if r.detected then return ReadOnlyRuleset({ { label = RealmLabel(r) } }, r.ruleset) end
    return RulesetChoices({ { label = RealmLabel(r) } }, r.ruleset, function(rs) Scan:SetRealmRuleset(realmKey, rs) end)
end

function WH:CharRulesetItems(key)
    local c = self.db.chars[key]
    if not c then return {} end
    if c.rulesetDetected then return ReadOnlyRuleset({ { label = c.name } }, c.ruleset) end
    return RulesetChoices({ { label = c.name } }, c.ruleset, function(rs) Scan:SetCharRuleset(key, rs) end)
end

local function RefreshAfterMenu()
    WH:RequestUIRefresh(0)
end

local function LocLine(L, label, never)
    if not L or L.t == 0 then return label, GREY .. never .. "|r" end
    local n = Scan.CountItems(L.items)
    local slots = L.slots and (", %d/%d slots"):format(L.used or 0, L.slots) or ""
    return label, ("%s %s%s  %s(%s)|r"):format(ns.Commas(n), ns.Plural(n, "item"), slots, GREY, ns.Ago(L.t))
end

function WH:CharHover(row, key, c)
    local mu = C.muted
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.OwnerLabel("char", c), 1, 1, 1)
    local realmName = ns.RealmName(c)
    GameTooltip:AddLine(("%s%s  •  %s"):format(realmName and (realmName .. "  •  ") or "", RulesetText(c, true),
        ns.AREAS[c.area]), mu[1], mu[2], mu[3], true)
    GameTooltip:AddLine(" ")
    local function Line(label, value) GameTooltip:AddDoubleLine(label, value, mu[1], mu[2], mu[3], 1, 1, 1) end
    Line(LocLine(c.bags, "Bags", "not saved yet"))
    Line(LocLine(c.bank, "Bank", "open the bank to save it"))
    Line(LocLine(c.equipped, "Equipped", "not saved yet"))
    local m = c.mail
    if m.t == 0 and #m.list == 0 then
        Line("Mail", GREY .. "open the mailbox to save it|r")
    else
        local n = 0
        for _, e in ipairs(m.list) do n = n + e.c end
        Line("Mail", ("%s %s%s  %s(%s)|r"):format(ns.Commas(n), ns.Plural(n, "item"),
            m.more > 0 and (", %d more mails on the server"):format(m.more) or "", GREY, ns.Ago(m.t)))
        if m.money > 0 then Line("Gold in mail", ns.Coins(m.money)) end
    end
    local g = c.guild and self.db.guilds[c.guild]
    if g then Line("Guild", ns.OwnerLabel("guild", g)) end
    Line("Gold", ns.Coins(c.money))
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to show only their items. Right-click for ruleset and forget.", mu[1], mu[2], mu[3], true)
    GameTooltip:Show()
end

function WH:CreateCharsView(f)
    local cv = CreateFrame("Frame", nil, f)
    cv:SetAllPoints()
    cv:Hide()
    f.charsView = cv
    local LEFT_RULE = -(W - CH_LEFT_R)
    local LW = CH_LEFT_R - 44
    local RW = W - 20 - CH_RIGHT_X

    local divider = cv:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.7)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", (CH_LEFT_R + CH_RIGHT_X) / 2, -46)
    divider:SetPoint("BOTTOMLEFT", (CH_LEFT_R + CH_RIGHT_X) / 2, 56)

    ---------------------------------------------------------------- Characters
    UI.AddSection(cv, "Characters", -46, 20, LEFT_RULE)
    local hint = AddLabel(cv, "Click a character to show only what they hold. Right-click to set their ruleset (if the game couldn't) or forget them.", nil, C.muted)
    hint:SetPoint("TOPLEFT", 22, -68)
    hint:SetWidth(LW)
    local cw = CH_LEFT_R - 24 - 22
    local scroll, child = UI.MakeScroll("WarehouseCharScroll", cv, cw)
    scroll:SetPoint("TOPLEFT", 20, -92)
    scroll:SetPoint("BOTTOMRIGHT", cv, "BOTTOMLEFT", CH_LEFT_R - 26, 58)
    cv.charList = UI.AttachVirtualList(scroll, child, CHAR_ROW_H, function()
        local row = CreateFrame("Button", nil, child)
        row:SetSize(cw, CHAR_ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.pick = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.pick:SetAllPoints()
        row.pick:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.28)
        row.selBar = row:CreateTexture(nil, "ARTWORK")
        row.selBar:SetPoint("TOPLEFT")
        row.selBar:SetPoint("BOTTOMLEFT")
        row.selBar:SetWidth(2)
        row.selBar:SetColorTexture(1, 0.82, 0.2, 1)
        row.name = NoWrap(AddLabel(row, "", "GameFontNormal", C.text))
        row.name:SetPoint("TOPLEFT", 8, -4)
        row.name:SetWidth(cw - 150)
        row.gold = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.gold:SetPoint("TOPRIGHT", -6, -5)
        row.gold:SetJustifyH("RIGHT")
        row.gold:SetWidth(140)
        row.info = NoWrap(AddLabel(row, "", "GameFontNormalSmall", C.muted))
        row.info:SetPoint("BOTTOMLEFT", 8, 5)
        row.info:SetWidth(cw - 130)
        row.seen = NoWrap(AddLabel(row, "", "GameFontNormalSmall", C.muted))
        row.seen:SetPoint("BOTTOMRIGHT", -6, 5)
        row.seen:SetJustifyH("RIGHT")
        row.seen:SetWidth(120)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.14)
        row:SetScript("OnClick", function(self, button)
            local it = self.item
            if not it then return end
            if button == "RightButton" then
                UI.ShowMenu(self, function() return WH:CharMenuItems(it.key) end, 200, RefreshAfterMenu)
            else
                WH:PickOwner(it.key)
            end
        end)
        row:SetScript("OnEnter", function(self) if self.item then WH:CharHover(self, self.item.key, self.item.c) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return row
    end, function(row, it, idx)
        UI.StripeRow(row, idx)
        row.item = it
        local c = it.c
        local s = WH.db.settings
        row.selBar:SetShown(it.key == Scan.meKey)
        row.pick:SetShown(s.who == "pick" and s.pick == it.key)
        row.name:SetText(ns.OwnerLabel("char", c) .. (c.level and (GREY .. "  level " .. c.level .. "|r") or ""))
        row.gold:SetText(ns.Coins(c.money))
        local faction = c.faction and (c.faction == "Horde" and "|cffff5a5aHorde|r" or (c.faction == "Alliance" and "|cff5a9cffAlliance|r" or c.faction)) or "?"
        local realmName = ns.RealmName(c)
        row.info:SetText(("%s%s  •  %s  •  %s"):format(realmName and (realmName .. "  •  ") or "", RulesetText(c),
            ns.AREAS[c.area], faction))
        row.seen:SetText(it.key == Scan.meKey and "playing now" or ("seen " .. ns.Ago(c.lastSeen)))
    end)
    cv.charEmpty = AddLabel(child, "", "GameFontNormalSmall", C.muted)
    cv.charEmpty:SetPoint("TOPLEFT", 6, -6)
    cv.charEmpty:SetWidth(cw - 20)

    ---------------------------------------------------------------- Realms
    UI.AddSection(cv, "Realms", -46, CH_RIGHT_X, -20)
    local rhint = AddLabel(cv, "Rulesets are read from the game at each login. Set one here only if the game couldn't say.", nil, C.muted)
    rhint:SetPoint("TOPLEFT", CH_RIGHT_X + 2, -68)
    rhint:SetWidth(RW)
    local rw = RW - 24
    local rscroll, rchild = UI.MakeScroll("WarehouseRealmScroll", cv, rw)
    rscroll:SetPoint("TOPLEFT", CH_RIGHT_X, -86)
    rscroll:SetPoint("BOTTOMRIGHT", cv, "TOPRIGHT", -44, -86 - 5 * REALM_ROW_H)
    cv.realmList = UI.AttachVirtualList(rscroll, rchild, REALM_ROW_H, function()
        local row = CreateFrame("Frame", nil, rchild)
        row:SetSize(rw, REALM_ROW_H)
        row.name = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.name:SetPoint("LEFT", 6, 0)
        row.name:SetWidth(rw - 110 - 70)
        row.info = NoWrap(AddLabel(row, "", "GameFontNormalSmall", C.muted))
        row.info:SetPoint("RIGHT", -100, 0)
        row.info:SetJustifyH("RIGHT")
        row.info:SetWidth(70)
        row.btn = FlatButton(row, "", 92, 18)
        row.btn:SetPoint("RIGHT", -2, 0)
        row.btn:SetScript("OnClick", function(self)
            local it = self:GetParent().item
            if it then UI.ShowMenu(self, function() return WH:RulesetMenuItems(it.key) end, 190, RefreshAfterMenu) end
        end)
        AddHoverTip(row.btn, "Ruleset", "Read from the game when one of your characters on this server logs in. If the game couldn't say, choose it here: every character on the server gets the same one. The Ruleset filter groups them into PvE and PvP.")
        return row
    end, function(row, it, idx)
        UI.StripeRow(row, idx)
        row.item = it
        row.name:SetText(RealmLabel(it.r))
        row.info:SetText(("%s  •  %d"):format(it.r.region, it.n))
        local rs = ns.RULESETS[it.r.ruleset]
        row.btn.label:SetText((rs and rs.label or "|cffff6040Set ruleset|r") .. (it.r.detected and "" or "  |cffffd100v|r"))
        SetFlatSelected(row.btn, rs == nil)
    end)

    ---------------------------------------------------------------- Guild banks
    UI.AddSection(cv, "Guild Banks", -212, CH_RIGHT_X, -20)
    local gscroll, gchild = UI.MakeScroll("WarehouseGuildScroll", cv, rw)
    gscroll:SetPoint("TOPLEFT", CH_RIGHT_X, -236)
    gscroll:SetPoint("BOTTOMRIGHT", cv, "TOPRIGHT", -44, -236 - 5 * GUILD_ROW_H)
    cv.guildList = UI.AttachVirtualList(gscroll, gchild, GUILD_ROW_H, function()
        local row = CreateFrame("Button", nil, gchild)
        row:SetSize(rw, GUILD_ROW_H)
        row:RegisterForClicks("RightButtonUp")
        row.name = NoWrap(AddLabel(row, "", "GameFontNormal", C.text))
        row.name:SetPoint("TOPLEFT", 6, -3)
        row.name:SetWidth(rw - 110)
        row.gold = NoWrap(AddLabel(row, "", "GameFontHighlightSmall", C.text))
        row.gold:SetPoint("TOPRIGHT", -4, -4)
        row.gold:SetJustifyH("RIGHT")
        row.gold:SetWidth(100)
        row.info = NoWrap(AddLabel(row, "", "GameFontNormalSmall", C.muted))
        row.info:SetPoint("BOTTOMLEFT", 6, 4)
        row.info:SetWidth(rw - 12)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.14)
        row:SetScript("OnClick", function(self)
            local it = self.item
            if not it then return end
            UI.ShowMenu(self, function()
                return { { label = "<" .. it.g.name .. ">" },
                         { text = "Forget this guild bank...", onClick = function() WH:ConfirmForgetGuild(it.key) end } }
            end, 200, RefreshAfterMenu)
        end)
        row:SetScript("OnEnter", function(self)
            local it = self.item
            if not it then return end
            local mu = C.muted
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(ns.OwnerLabel("guild", it.g), 1, 1, 1)
            GameTooltip:AddLine(("%s  •  %s"):format(ns.PlaceText(it.g, true), it.g.faction or "?"), mu[1], mu[2], mu[3])
            GameTooltip:AddLine(" ")
            local tabs = {}
            for tab in pairs(it.g.tabs) do tabs[#tabs + 1] = tab end
            table.sort(tabs)
            for _, tab in ipairs(tabs) do
                local t = it.g.tabs[tab]
                local n = Scan.CountItems(t.items)
                GameTooltip:AddDoubleLine(t.name, ("%s %s  %s(%s)|r"):format(ns.Commas(n), ns.Plural(n, "item"), GREY, ns.Ago(t.t)), mu[1], mu[2], mu[3], 1, 1, 1)
            end
            if #tabs == 0 then GameTooltip:AddLine("No tab saved yet. Open the guild bank to save it.", mu[1], mu[2], mu[3], true) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Tabs you can't view aren't saved. Right-click to forget this guild bank.", mu[1], mu[2], mu[3], true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return row
    end, function(row, it, idx)
        UI.StripeRow(row, idx)
        row.item = it
        local g = it.g
        row.name:SetText(ns.OwnerLabel("guild", g))
        row.gold:SetText(ns.Coins(g.money))
        local saved = 0
        for _ in pairs(g.tabs) do saved = saved + 1 end
        row.info:SetText(("%s  •  %s  •  %d of %s tabs  •  %s"):format(ns.PlaceText(g), g.faction or "?", saved,
            g.numTabs and tostring(g.numTabs) or "?", ns.Ago(g.t)))
    end)
    cv.guildEmpty = AddLabel(gchild, "", "GameFontNormalSmall", C.muted)
    cv.guildEmpty:SetPoint("TOPLEFT", 6, -6)
    cv.guildEmpty:SetWidth(rw - 12)

    ---------------------------------------------------------------- Gold
    UI.AddSection(cv, "Gold", -420, CH_RIGHT_X, -20)
    cv.gold = {}
    local goldLabels = { "On characters", "Waiting in mail", "In guild banks", "All together", "By region" }
    for i, text in ipairs(goldLabels) do
        local y = -444 - (i - 1) * 15
        local label = AddLabel(cv, text, "GameFontNormalSmall", C.muted)
        label:SetPoint("TOPLEFT", CH_RIGHT_X + 2, y)
        local value = NoWrap(AddLabel(cv, "", "GameFontNormalSmall", C.text))
        value:SetPoint("TOPLEFT", CH_RIGHT_X + 110, y)
        value:SetWidth(RW - 112)
        cv.gold[i] = value
    end
end

function WH:RefreshChars()
    local f = self.frame
    if not f or not f.charsView or not f.charsView:IsShown() then return end
    local cv = f.charsView
    local list = Scan:SortedChars()
    cv.charList:SetData(list)
    cv.charEmpty:SetText(#list == 0 and "No characters saved yet." or "")

    local counts = {}
    for _, it in ipairs(list) do
        local rk = it.c.realmKey
        counts[rk] = (counts[rk] or 0) + 1
    end
    local realms = {}
    for key, r in pairs(self.db.realms) do
        if counts[key] and not r.unknown then realms[#realms + 1] = { key = key, r = r, n = counts[key] } end
    end
    table.sort(realms, function(a, b)
        if a.r.region ~= b.r.region then return a.r.region < b.r.region end
        return RealmLabel(a.r) < RealmLabel(b.r)
    end)
    cv.realmList:SetData(realms)

    local guilds = {}
    for key, g in pairs(self.db.guilds) do guilds[#guilds + 1] = { key = key, g = g } end
    table.sort(guilds, function(a, b) return a.g.name < b.g.name end)
    cv.guildList:SetData(guilds)
    cv.guildEmpty:SetText(#guilds == 0 and "No guild bank saved yet. Open your guild bank to save it." or "")

    local onChars, inMail, inGuilds, byArea = 0, 0, 0, {}
    for _, it in ipairs(list) do
        local c = it.c
        onChars = onChars + (c.money or 0)
        inMail = inMail + (c.mail.money or 0)
        local a = ns.AreaGroup(c.area)
        byArea[a] = (byArea[a] or 0) + (c.money or 0) + (c.mail.money or 0)
    end
    for _, it in ipairs(guilds) do inGuilds = inGuilds + (it.g.money or 0) end
    cv.gold[1]:SetText(ns.Coins(onChars))
    cv.gold[2]:SetText(ns.Coins(inMail))
    cv.gold[3]:SetText(ns.Coins(inGuilds))
    cv.gold[4]:SetText(ns.Coins(onChars + inMail + inGuilds))
    local parts = {}
    for _, a in ipairs(ns.AREA_ORDER) do
        if byArea[a] then parts[#parts + 1] = ("%s %s"):format(ns.AREAS[a], ns.PlainMoney(byArea[a])) end
    end
    cv.gold[5]:SetText(#parts > 0 and table.concat(parts, GREY .. "  •  |r") or (GREY .. "—|r"))
end

function WH:ConfirmForgetChar(key)
    local c = self.db.chars[key]
    if not c then return end
    if key == Scan.meKey then ns.Print("you can't forget the character you're playing.") return end
    StaticPopup_Show("WAREHOUSE_FORGET_CHAR", ("%s (%s)"):format(c.name, ns.PlaceText(c, true)), nil, key)      -- RETEST
end

function WH:ConfirmForgetGuild(key)
    local g = self.db.guilds[key]
    if not g then return end
    StaticPopup_Show("WAREHOUSE_FORGET_GUILD", "<" .. g.name .. ">", nil, key)                    -- RETEST
end

function WH:ConfirmForgetByName(text)
    text = ns.Trim(text or "")
    if text == "" then ns.Print("use /warehouse forget <first name and surname>.") return end
    local lt = text:lower()
    local matches = {}
    for key, c in pairs(self.db.chars) do
        if c.name:lower() == lt then matches[#matches + 1] = key end
    end
    if #matches == 0 then
        ns.Print(("no saved character is called \"%s\". Type /warehouse chars to list them."):format(text))
    elseif #matches > 1 then
        ns.Print(("more than one saved character (in different regions) is called %s. Right-click the one to forget on the Characters tab."):format(text))
    else
        self:ConfirmForgetChar(matches[1])
    end
end

-------------------------------------------------------------------------------
-- Options tab
-------------------------------------------------------------------------------
local OPT_LEFT_R, OPT_RIGHT_X = 430, 450
local STORAGE = { "Characters", "Guild banks", "Item stacks", "Mail attachments", "Item names known", "Saved data" }
local SCOPES = { { "realm", "This ruleset" }, { "region", "This region" }, { "all", "Everywhere" } }
local EXPIRE = { 1, 3, 7 }

local function EstimateStorage(db)
    local bytes, stacks, mails, names = 0, 0, 0, 0
    for key, c in pairs(db.chars) do
        bytes = bytes + #key + 220
        for _, loc in ipairs({ "bags", "bank", "equipped" }) do
            for k in pairs(c[loc].items) do bytes = bytes + #k + 14; stacks = stacks + 1 end
        end
        for _, e in ipairs(c.mail.list) do bytes = bytes + #e.k + (e.f and #e.f or 0) + 44; mails = mails + 1 end
    end
    for key, g in pairs(db.guilds) do
        bytes = bytes + #key + 140
        for _, t in pairs(g.tabs) do
            bytes = bytes + #t.name + 50
            for k in pairs(t.items) do bytes = bytes + #k + 14; stacks = stacks + 1 end
        end
    end
    for k, v in pairs(db.names) do bytes = bytes + #k + #v + 12; names = names + 1 end
    for k, v in pairs(db.links) do bytes = bytes + #k + #v + 12 end
    return bytes, stacks, mails, names
end

function WH:CreateOptionsView(f)
    local ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints()
    ov:Hide()
    f.optionsView = ov
    local LEFT_RULE = -(W - OPT_LEFT_R)
    local LW = OPT_LEFT_R - 44
    local RW = W - 20 - OPT_RIGHT_X
    local s = function() return WH.db.settings end

    local divider = ov:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.7)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", (OPT_LEFT_R + OPT_RIGHT_X) / 2, -46)
    divider:SetPoint("BOTTOMLEFT", (OPT_LEFT_R + OPT_RIGHT_X) / 2, 56)

    ---------------------------------------------------------------- Saving
    UI.AddSection(ov, "Saving", -46, 20, LEFT_RULE)
    local intro = AddLabel(ov, "Bags, gear and gold are saved automatically. The bank, guild bank and mailbox are saved each time you open them, so open each once on every character.", nil, C.muted)
    intro:SetPoint("TOPLEFT", 22, -68)
    intro:SetWidth(LW)
    if intro.SetSpacing then intro:SetSpacing(2) end

    ov.guildCheck = UI.MakeCheck(ov, 18, -104, "Read every guild bank tab when it opens", "Read every tab",
        "When the guild bank opens, Warehouse asks for each tab you can view, one after another, so all of them are saved without clicking through. Off: only the tabs you look at are saved.",
        function(on) s().readGuildTabs = on end)
    ov.sentCheck = UI.MakeCheck(ov, 18, -128, "Add mail you send to your characters to their mailbox", "Mail to your characters",
        "Items you mail to one of your own characters show in their mailbox straight away, marked as on its way, until that character opens the mailbox.",
        function(on) s().trackSentMail = on end)
    ov.announceCheck = UI.MakeCheck(ov, 18, -152, "Print a line in chat after saving a bank, guild bank or mailbox", nil, nil,
        function(on) s().announce = on end)
    local save = UI.MenuButton(ov, "Save Now", 120)
    save:SetPoint("TOPLEFT", 20, -182)
    save:SetScript("OnClick", function() Scan:ScanEverything(true) end)
    AddHoverTip(save, "Save Now", "Save your bags and gear right away, and the bank, guild bank or mailbox if one is open.")
    ov.saveStatus = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.muted))
    ov.saveStatus:SetPoint("LEFT", save, "RIGHT", 10, 0)
    ov.saveStatus:SetWidth(LW - 130)

    ---------------------------------------------------------------- Item tooltips
    UI.AddSection(ov, "Item Tooltips", -220, 20, LEFT_RULE)
    ov.tipCheck = UI.MakeCheck(ov, 18, -242, "Show who holds an item in its tooltip", "Tooltip counts",
        "Adds a Warehouse section to item tooltips: how many of the item each character and guild bank holds, by location.",
        function(on) s().tooltipCounts = on end)
    local scopeLabel = AddLabel(ov, "Characters shown", "GameFontNormalSmall", C.muted)
    scopeLabel:SetPoint("TOPLEFT", 22, -274)
    ov.scopeButtons = {}
    local sx = 128
    for _, sc in ipairs(SCOPES) do
        local b = FlatButton(ov, sc[2], 84, 20)
        b:SetPoint("TOPLEFT", sx, -270)
        sx = sx + 88
        b.scope = sc[1]
        b:SetScript("OnClick", function(self) s().tooltipScope = self.scope; WH:RefreshOptions() end)
        ov.scopeButtons[#ov.scopeButtons + 1] = b
    end

    ---------------------------------------------------------------- Mail
    UI.AddSection(ov, "Mail", -304, 20, LEFT_RULE)
    ov.warnCheck = UI.MakeCheck(ov, 18, -326, "Warn at login about mail that expires soon", "Expiring mail",
        "A few seconds after you log in, Warehouse lists the characters whose saved mail expires soon. Mail that expires is returned to the sender or deleted.",
        function(on) s().warnExpiring = on end)
    local expLabel = AddLabel(ov, "Soon means within", "GameFontNormalSmall", C.muted)
    expLabel:SetPoint("TOPLEFT", 22, -358)
    ov.expireButtons = {}
    local ex = 128
    for _, days in ipairs(EXPIRE) do
        local b = FlatButton(ov, days .. " " .. ns.Plural(days, "day"), 60, 20)
        b:SetPoint("TOPLEFT", ex, -354)
        ex = ex + 64
        b.days = days
        b:SetScript("OnClick", function(self) s().expireDays = self.days; WH:RefreshOptions() end)
        ov.expireButtons[#ov.expireButtons + 1] = b
    end
    local listNow = FlatButton(ov, "List now", 70, 20)
    listNow:SetPoint("TOPLEFT", ex + 8, -354)
    listNow:SetScript("OnClick", function() Scan:WarnExpiring(true) end)
    AddHoverTip(listNow, "Expiring mail", "List in chat every character whose saved mail expires within the chosen number of days.")

    ---------------------------------------------------------------- Display and search
    UI.AddSection(ov, "Display", -388, 20, LEFT_RULE)
    ov.minimapCheck = UI.MakeCheck(ov, 18, -410, "Show minimap button", nil, nil,
        function(on) WH:SetMinimapButtonShown(on) end)
    ov.searchCheck = UI.MakeCheck(ov, 18, -434, "Search item tooltips, not just names and types", "Tooltip search",
        "The Items tab search also looks at stats, effects and everything else in each item's tooltip. Tooltips are read in the background the first time you search in a session.",
        function(on) s().searchTooltips = on end)

    ---------------------------------------------------------------- Storage
    UI.AddSection(ov, "Storage", -46, OPT_RIGHT_X, -20)
    ov.storage = {}
    for i, name in ipairs(STORAGE) do
        local y = -70 - (i - 1) * 15
        local label = AddLabel(ov, name, "GameFontNormalSmall", C.muted)
        label:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, y)
        local value = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
        value:SetPoint("TOPLEFT", OPT_RIGHT_X + 130, y)
        value:SetWidth(RW - 132)
        ov.storage[i] = value
    end

    ---------------------------------------------------------------- This character
    UI.AddSection(ov, "This Character", -170, OPT_RIGHT_X, -20)
    ov.me1 = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
    ov.me1:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -194)
    ov.me1:SetWidth(RW - 4)
    ov.me2 = NoWrap(AddLabel(ov, "", "GameFontNormalSmall", C.text))
    ov.me2:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -209)
    ov.me2:SetWidth(RW - 4)
    local rsBtn = FlatButton(ov, "Ruleset  |cffffd100v|r", 110, 18)
    rsBtn:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -228)
    rsBtn:SetScript("OnClick", function(self)
        if Scan.meKey then
            UI.ShowMenu(self, function() return WH:CharRulesetItems(Scan.meKey) end, 190, function() WH:RefreshOptions() end)
        end
    end)
    AddHoverTip(rsBtn, "This character's ruleset", "Read from the game at each login (Normal, PvP, Roleplay, Roleplay PvP or Hardcore). Choose it here only if the game couldn't say. The Ruleset filter uses it.")

    ---------------------------------------------------------------- Client
    UI.AddSection(ov, "Client", -262, OPT_RIGHT_X, -20)
    ov.probe = {}
    for i = 1, 18 do
        local b = CreateFrame("Button", nil, ov)
        b:SetSize(RW - 4, 14)
        b:SetPoint("TOPLEFT", OPT_RIGHT_X + 2, -286 - (i - 1) * 15)
        b.text = NoWrap(AddLabel(b, "", "GameFontNormalSmall", C.text))
        b.text:SetAllPoints()
        b:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self.entry.label, 1, 0.82, 0)
            GameTooltip:AddLine(self.entry.detail or "", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ov.probe[i] = b
    end
end

function WH:RefreshOptions()
    local f = self.frame
    if not f or not f.optionsView or not f.optionsView:IsShown() then return end
    local ov, s = f.optionsView, self.db.settings

    ov.guildCheck:SetChecked(s.readGuildTabs)
    ov.sentCheck:SetChecked(s.trackSentMail)
    ov.announceCheck:SetChecked(s.announce)
    ov.tipCheck:SetChecked(s.tooltipCounts)
    ov.warnCheck:SetChecked(s.warnExpiring)
    ov.minimapCheck:SetChecked(not self.db.minimap.hide)
    ov.searchCheck:SetChecked(s.searchTooltips)
    for _, b in ipairs(ov.scopeButtons) do SetFlatSelected(b, b.scope == s.tooltipScope) end
    for _, b in ipairs(ov.expireButtons) do SetFlatSelected(b, b.days == s.expireDays) end

    local me = Scan.me
    ov.saveStatus:SetText(me and ("Bags saved %s"):format(ns.Ago(me.bags.t)) or "This character isn't identified yet.")

    local bytes, stacks, mails, names = EstimateStorage(self.db)
    local nChars, nGuilds = 0, 0
    for _ in pairs(self.db.chars) do nChars = nChars + 1 end
    for _ in pairs(self.db.guilds) do nGuilds = nGuilds + 1 end
    local vals = { ns.Commas(nChars), ns.Commas(nGuilds), ns.Commas(stacks), ns.Commas(mails), ns.Commas(names),
                   ("about %s"):format(ns.Bytes(bytes)) }
    for i, fs in ipairs(ov.storage) do fs:SetText(vals[i] or (GREY .. "—|r")) end

    if me then
        ov.me1:SetText(("%s  %s— %s, %s|r"):format(ns.OwnerLabel("char", me), GREY, ns.AREAS[me.area], me.faction or "faction unknown"))
        local rs = ns.RULESETS[me.ruleset]
        local realm = Scan:RealmOf(me)
        ov.me2:SetText(("Ruleset %s%s  %s— %s|r"):format(rs and (rs.label .. " (" .. ns.RULE_GROUPS[rs.group] .. ")") or "|cffff6040not set|r",
            me.rulesetDetected and (GREY .. ", from the game|r") or "", GREY, realm and RealmLabel(realm) or "realm unknown"))
    else
        ov.me1:SetText(GREY .. "This character isn't identified yet.|r")
        ov.me2:SetText("")
    end

    local probe = ns.Probe()
    for i, b in ipairs(ov.probe) do
        local r = probe[i]
        b.entry = r
        if r then
            b.text:SetText(("%s•|r %s  %s%s|r"):format(r.ok and "|cff40ff40" or "|cffff6040", r.label, Hex(C.muted), r.detail or ""))
            b:Show()
        else
            b:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- Game Options -> AddOns entry, addon compartment, minimap button, chat links
-------------------------------------------------------------------------------
function WH:RegisterBlizzardOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Warehouse"
    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("Warehouse")
    local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -10)
    d:SetWidth(520)
    d:SetJustifyH("LEFT")
    d:SetText("A searchable database of your characters' bags, personal banks, guild banks and mailboxes. Settings are on the Options tab of the Warehouse window. You can also open it with /warehouse.")
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(220, 24)
    b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -14)
    b:SetText("Open Warehouse")
    b:SetScript("OnClick", function()
        -- the Settings panel is protected UI: close it only out of combat
        ns.AfterCombat("closeSettings", function()
            if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end       -- RETEST
            if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
        end)
        WH:Open("options")
    end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then   -- RETEST
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    end
end

local function AddShortcutTooltip(tooltip)
    tooltip:AddLine("Warehouse", 1, 0.82, 0)
    tooltip:AddLine("|cffffd100Left-click|r  search your items  " .. GREY .. "(/warehouse)|r", 1, 1, 1)
    tooltip:AddLine("|cffffd100Right-click|r  your characters  " .. GREY .. "(/warehouse characters)|r", 1, 1, 1)
    if WH.db then
        local n, gold = 0, 0
        for _, c in pairs(WH.db.chars) do n = n + 1; gold = gold + (c.money or 0) + (c.mail.money or 0) end
        for _, g in pairs(WH.db.guilds) do gold = gold + (g.money or 0) end
        tooltip:AddLine(("%d %s, %s gold in all"):format(n, ns.Plural(n, "character"), ns.PlainMoney(gold)), C.muted[1], C.muted[2], C.muted[3])
    end
end

local function ShortcutClick(button)
    if button == "RightButton" then WH:Open("chars") else WH:Toggle() end
end

-- The addon compartment (button by the minimap) works like the minimap button
function Warehouse_OnAddonCompartmentClick(_, mouseButton)
    if WH.db then ShortcutClick(mouseButton) end
end

function Warehouse_OnAddonCompartmentEnter(_, button)
    local owner = button or UIParent
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    AddShortcutTooltip(GameTooltip)
    GameTooltip:Show()
end

function Warehouse_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- Minimap button (LibDataBroker launcher drawn by LibDBIcon)
function WH:CreateMinimapButton()
    if self.minimapIcon then return end
    local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not LDB or not DBIcon then return end
    local launcher = LDB:NewDataObject("Warehouse", {
        type = "launcher",
        text = "Warehouse",
        icon = UI.ICON,
        OnClick = function(_, button) ShortcutClick(button) end,
        OnTooltipShow = function(tooltip) AddShortcutTooltip(tooltip) end,
    })
    if not launcher then return end
    DBIcon:Register("Warehouse", launcher, self.db.minimap)        -- RETEST: LibDBIcon on Forever
    self.minimapIcon = DBIcon
end

function WH:SetMinimapButtonShown(shown)
    self.db.minimap.hide = not shown
    if self.minimapIcon then
        if shown then self.minimapIcon:Show("Warehouse") else self.minimapIcon:Hide("Warehouse") end
    end
    local ov = self.frame and self.frame.optionsView
    if ov and ov:IsShown() then ov.minimapCheck:SetChecked(shown) end
end

-- With the search box selected, shift-clicking an item searches for it
local function OnInsertLink(link)
    local f = WH.frame
    if not f or not f:IsShown() or not f.search:HasFocus() then return end
    link = ns.Text(link)
    local name = link and link:match("|h%[(.-)%]|h")
    if name then
        name = ns.Trim((name:gsub("|A.-|a", "")))
        f.search:SetText(name)
        f.search:SetCursorPosition(#name)
    end
end

local function HookChatLinks()
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then      -- RETEST
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
    elseif type(rawget(_G, "ChatEdit_InsertLink")) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
    end
end

function WH:InitUI(Step)
    Step = Step or function(_, fn) fn() end
    Step("confirmation dialogs", function()
        StaticPopupDialogs["WAREHOUSE_FORGET_CHAR"] = {
            text = "Forget everything Warehouse saved for %s?\n\nYou can save them again by logging in on that character.",
            button1 = YES or "Yes",
            button2 = NO or "No",
            OnAccept = function(_, data) Scan:ForgetChar(data) end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopupDialogs["WAREHOUSE_FORGET_GUILD"] = {
            text = "Forget the saved guild bank of %s?\n\nIt's saved again the next time one of your characters opens it.",
            button1 = YES or "Yes",
            button2 = NO or "No",
            OnAccept = function(_, data) Scan:ForgetGuild(data) end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end)
    Step("Settings panel entry", function() self:RegisterBlizzardOptions() end)
    Step("minimap button", function() self:CreateMinimapButton() end)
    Step("chat link hook", HookChatLinks)
end
