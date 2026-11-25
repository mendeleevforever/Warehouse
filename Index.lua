local addonName, ns = ...
-- Index.lua
-- Turns the saved records into answers:
--   * Build(): every item the filtered characters and guild banks hold, with
--     its total, how much is in each location, who holds it and the soonest
--     mail expiry. Cached until the data or a filter changes.
--   * Meta(): each item's name, quality, icon, type and slot (for grouping
--     and search). Names come from the links Warehouse saved, so most items
--     never need to be loaded from the server.
--   * Search: every word must match the name, the type/slot or (optionally)
--     the tooltip text; tooltips are read in the background for the session.
--   * Item tooltips: who holds the item, by location (TooltipDataProcessor).
--
-- Filters work on owners (characters and guild banks): region, ruleset (as
-- the game reported it), faction and "who"; locations and the guild bank
-- filter then pick which of each owner's places count. Nothing is keyed by
-- realm.

local WH, Scan = ns.WH, ns.Scan
local Index = {}
ns.Index = Index

local Text, Num = ns.Text, ns.Num

Index.meta     = {}       -- [item key] = display facts (session)
Index.metaById = {}       -- [itemID] = { meta, ... }
Index.tips     = {}       -- [item key] = lower-case tooltip text (session)

local COUNT_LOCS = { "bags", "bank", "equipped" }
local RULE_KEYS  = ns.RULE_FILTER

-------------------------------------------------------------------------------
-- Owner filters
-------------------------------------------------------------------------------
function Index:OwnerPasses(kind, key, rec)
    local s = WH.db.settings
    if not s.regions[ns.AreaGroup(rec.area)] then return false end
    if not s.rulesets[ns.RuleKey(rec.ruleset)] then return false end
    if rec.faction and not s.factions[rec.faction] then return false end
    local who = s.who
    if who == "all" then return true end
    local me = Scan.me
    if not me then return false end
    if who == "me" then
        if kind == "char" then return key == Scan.meKey end
        return key == me.guild
    elseif who == "ruleset" then
        return Scan:SameWorld(rec)
    elseif who == "pick" then
        if kind == "char" then return key == s.pick end
        local p = WH.db.chars[s.pick]
        return p ~= nil and p.guild == key
    end
    return true
end

local function Flags(list, set)
    local out = {}
    for i, k in ipairs(list) do out[i] = set[k] and "1" or "0" end
    return table.concat(out)
end

-- The guild banks and tabs left out, in a stable order
local function Excluded(set)
    local out = {}
    for k, v in pairs(set) do if v then out[#out + 1] = k end end
    table.sort(out)
    return table.concat(out, ",")
end

local function Signature(s)
    return table.concat({ Scan.version, s.who, s.pick, Scan.meKey or "-",
        Flags(ns.AREA_ORDER, s.regions), Flags(RULE_KEYS, s.rulesets),
        Flags(ns.FACTION_ORDER, s.factions), Flags(ns.LOCATIONS, s.locations),
        Excluded(s.guildOff), Excluded(s.tabOff) }, "|")
end

-- The guild bank filter: is this guild bank, or this tab of it, shown?
function Index:GuildShown(guildKey)
    return not WH.db.settings.guildOff[guildKey]
end

function Index:TabShown(guildKey, tab)
    return not WH.db.settings.guildOff[guildKey] and not WH.db.settings.tabOff[ns.GuildTabKey(guildKey, tab)]
end

function Index:Invalidate()
    self.cache = nil
end

-------------------------------------------------------------------------------
-- Aggregation
--   items[key] = { key, total, loc = {[loc] = n}, by = {[owner key] = n},
--                  nOwners, latest, soonest }
--   owners[owner key] = { kind, key, rec, n, loc = {[loc] = n} }
--   totals = { items, loc, gold, mailGold, guildGold, chars, guilds }
-------------------------------------------------------------------------------
function Index:Build()
    local s = WH.db.settings
    local sig = Signature(s)
    if self.cache and self.cache.sig == sig then return self.cache end

    local now = time()
    local items, owners = {}, {}
    local totals = { items = 0, loc = {}, gold = 0, mailGold = 0, guildGold = 0, chars = 0, guilds = 0 }

    local function Owner(kind, key, rec)
        local o = { kind = kind, key = key, rec = rec, n = 0, loc = {} }
        owners[key] = o
        return o
    end

    local function Add(o, loc, key, n, t, x)
        local a = items[key]
        if not a then
            a = { key = key, total = 0, loc = {}, by = {}, nOwners = 0, latest = 0 }
            items[key] = a
        end
        a.total = a.total + n
        a.loc[loc] = (a.loc[loc] or 0) + n
        local prev = a.by[o.key]
        if prev then a.by[o.key] = prev + n else a.by[o.key] = n; a.nOwners = a.nOwners + 1 end
        if t and t > a.latest then a.latest = t end
        if x and (not a.soonest or x < a.soonest) then a.soonest = x end
        o.n = o.n + n
        o.loc[loc] = (o.loc[loc] or 0) + n
        totals.items = totals.items + n
        totals.loc[loc] = (totals.loc[loc] or 0) + n
    end

    for key, c in pairs(WH.db.chars) do
        if self:OwnerPasses("char", key, c) then
            local o = Owner("char", key, c)
            totals.chars = totals.chars + 1
            totals.gold = totals.gold + (c.money or 0)
            for _, loc in ipairs(COUNT_LOCS) do
                if s.locations[loc] then
                    local L = c[loc]
                    for k, n in pairs(L.items) do Add(o, loc, k, n, L.t) end
                end
            end
            if s.locations.mail then
                totals.mailGold = totals.mailGold + (c.mail.money or 0)
                for _, e in ipairs(c.mail.list) do
                    if not e.x or e.x > now then Add(o, "mail", e.k, e.c, e.sent or c.mail.t, not e.sent and e.x or nil) end
                end
            end
        end
    end

    if s.locations.guild then
        for key, g in pairs(WH.db.guilds) do
            if self:GuildShown(key) and self:OwnerPasses("guild", key, g) then
                local o = Owner("guild", key, g)
                totals.guilds = totals.guilds + 1
                totals.guildGold = totals.guildGold + (g.money or 0)
                for tab, t in pairs(g.tabs) do
                    if self:TabShown(key, tab) then
                        for k, n in pairs(t.items) do Add(o, "guild", k, n, t.t) end
                    end
                end
            end
        end
    end

    self.cache = { sig = sig, items = items, owners = owners, totals = totals }
    return self.cache
end

-- Where one item is, as rows for the detail panel (filters applied):
-- { owner, kind, rec, loc, n, t, detail, x, tab, mails }
function Index:Holders(key)
    local s = WH.db.settings
    local rows, now = {}, time()
    for ownerKey, c in pairs(WH.db.chars) do
        if self:OwnerPasses("char", ownerKey, c) then
            for _, loc in ipairs(COUNT_LOCS) do
                local n = s.locations[loc] and c[loc].items[key]
                if n then rows[#rows + 1] = { owner = ownerKey, kind = "char", rec = c, loc = loc, n = n, t = c[loc].t } end
            end
            if s.locations.mail then
                local row
                for _, e in ipairs(c.mail.list) do
                    if e.k == key and (not e.x or e.x > now) then
                        if not row then
                            row = { owner = ownerKey, kind = "char", rec = c, loc = "mail", n = 0, t = c.mail.t, mails = {} }
                            rows[#rows + 1] = row
                        end
                        row.n = row.n + e.c
                        row.mails[#row.mails + 1] = e
                        if e.sent then row.inTransit = true; row.t = math.max(row.t or 0, e.sent) end
                        if e.x and not e.sent and (not row.x or e.x < row.x) then row.x = e.x end
                    end
                end
            end
        end
    end
    if s.locations.guild then
        for ownerKey, g in pairs(WH.db.guilds) do
            if self:GuildShown(ownerKey) and self:OwnerPasses("guild", ownerKey, g) then
                for tab, t in pairs(g.tabs) do
                    local n = self:TabShown(ownerKey, tab) and t.items[key]
                    if n then rows[#rows + 1] = { owner = ownerKey, kind = "guild", rec = g, loc = "guild", n = n, t = t.t, tab = tab, tabName = t.name } end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        if a.owner ~= b.owner then return a.owner < b.owner end
        return (a.tab or 0) < (b.tab or 0)
    end)
    return rows
end

-------------------------------------------------------------------------------
-- Item display facts
-------------------------------------------------------------------------------
function Index:FillName(m)
    local name, q = Scan:ItemName(m.key, m.id)
    m.name, m.quality = name, q
    m.lname = name and name:lower() or nil
    m.sn = m.lname or ("~" .. m.key)
end

function Index:Meta(key)
    local m = self.meta[key]
    if m then
        if not m.name then self:FillName(m) end
        return m
    end
    m = { key = key, id = Scan.KeyID(key), variant = key:find(":", 1, true) ~= nil }
    if m.id then
        local i = Scan:Instant(m.id)
        m.typeName, m.subName, m.slotName, m.icon, m.cls = i.typeName, i.subName, i.slotName, i.icon, i.cls
        local list = self.metaById[m.id]
        if not list then list = {}; self.metaById[m.id] = list end
        list[#list + 1] = m
    end
    local words = {}
    for _, w in ipairs({ m.typeName or "", m.subName or "", m.slotName or "" }) do
        if w ~= "" then words[#words + 1] = w end
    end
    m.kinds = table.concat(words, "\n"):lower()
    self:FillName(m)
    self.meta[key] = m
    return m
end

-- A full item link for chat and tooltips, or nil while the item loads
function Index:Link(key)
    local id = Scan.KeyID(key)
    if not id or not (C_Item and C_Item.GetItemInfo) then return nil end
    local _, link = ns.SafeCall(C_Item.GetItemInfo, WH.db.links[key] or id)
    link = Text(link)
    if not link then Scan:QueueItem(id, true) end
    return link
end

-- The item arrived from the server: names, tooltips and facts can be read now
function Index:ItemArrived(id, ok, wasForced)
    local list = self.metaById[id]
    if list then
        for _, m in ipairs(list) do
            if not m.name then self:FillName(m) end
            if wasForced or self.tipWanted[m.key] then self:TooltipArrived(m, ok) end
        end
    end
    if WH.RequestUIRefresh then WH:RequestUIRefresh(0.5) end
end

-------------------------------------------------------------------------------
-- Tooltip text for searching: kept for the session only (not saved), keyed
-- by item key (items with a suffix have their own tooltip). Read with
-- C_TooltipInfo, which builds a tooltip's text without showing anything; a
-- hidden tooltip is the fallback. Reading stops at the "Sell Price" line, so
-- lines other addons add after it never match.
-------------------------------------------------------------------------------
Index.tipWanted, Index.tipFailed = {}, {}
local scanTip

local SELL_PRICE_TEXT = Text(rawget(_G, "SELL_PRICE"))              -- RETEST: "Sell Price"
local RETRIEVING_TEXT = Text(rawget(_G, "RETRIEVING_ITEM_INFO"))    -- RETEST: "Retrieving item information"

local function Clean(v)
    v = Text(v)
    if not v then return nil end
    v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
         :gsub("|H.-|h(.-)|h", "%1"):gsub("|n", " ")
    v = ns.Trim(v)
    return v ~= "" and v or nil
end

local function StartsWith(text, prefix)
    return prefix ~= nil and text:sub(1, #prefix) == prefix
end

-- The text lines of an item's tooltip, or nil when the game hasn't loaded it yet
local function TooltipLines(m)
    local out = {}
    local function Add(left, right)
        if left then out[#out + 1] = left end
        if right then out[#out + 1] = right end
    end
    local itemString = WH.db.links[m.key]
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then                 -- RETEST
        local data
        if itemString and C_TooltipInfo.GetHyperlink then
            data = ns.SafeCall(C_TooltipInfo.GetHyperlink, itemString)
        else
            data = ns.SafeCall(C_TooltipInfo.GetItemByID, m.id)
        end
        if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
        local types = Enum and Enum.TooltipDataLineType
        local sellType = types and types.SellPrice                       -- RETEST
        for _, line in ipairs(data.lines) do
            if type(line) == "table" then
                if sellType and line.type == sellType then break end
                local left, right = Clean(line.leftText), Clean(line.rightText)
                if left and RETRIEVING_TEXT and left == RETRIEVING_TEXT then return nil end
                if left and StartsWith(left, SELL_PRICE_TEXT) then break end
                Add(left, right)
            end
        end
        return #out > 0 and out or nil
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "WarehouseScanTooltip", UIParent, "GameTooltipTemplate")   -- RETEST
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    Index.suppress = true
    local ok
    if itemString then ok = pcall(scanTip.SetHyperlink, scanTip, itemString) else ok = pcall(scanTip.SetItemByID, scanTip, m.id) end
    Index.suppress = false
    if not ok then scanTip:Hide() return nil end
    for i = 1, scanTip:NumLines() or 0 do
        local lfs, rfs = _G["WarehouseScanTooltipTextLeft" .. i], _G["WarehouseScanTooltipTextRight" .. i]
        local left = lfs and Clean(lfs:GetText())
        local right = rfs and rfs:IsShown() and Clean(rfs:GetText()) or nil
        if left and RETRIEVING_TEXT and left == RETRIEVING_TEXT then scanTip:Hide() return nil end
        if left and StartsWith(left, SELL_PRICE_TEXT) then break end
        Add(left, right)
    end
    scanTip:Hide()
    return #out > 0 and out or nil
end

-- Reads one item's tooltip into Index.tips; when the item isn't loaded yet
-- it asks the server once and tries again when the item arrives
function Index:ReadTooltip(m, final)
    local key = m.key
    if self.tips[key] or self.tipFailed[key] or not m.id then return self.tips[key] ~= nil end
    if not final and C_Item and C_Item.IsItemDataCachedByID then          -- RETEST
        if ns.SafeCall(C_Item.IsItemDataCachedByID, m.id) == false then
            self.tipWanted[key] = true
            Scan:QueueItem(m.id, false, true)
            return false
        end
    end
    local lines = TooltipLines(m)
    if not lines then
        if final then self.tipFailed[key] = true return false end
        self.tipWanted[key] = true
        Scan:QueueItem(m.id, false, true)
        return false
    end
    self.tipWanted[key] = nil
    self.tips[key] = table.concat(lines, "\n"):lower()
    return true
end

function Index:TooltipArrived(m, ok)
    if not self.tipWanted[m.key] then return end
    self.tipWanted[m.key] = nil
    if not ok then self.tipFailed[m.key] = true return end
    self:ReadTooltip(m, true)
end

-- Reads the tooltips of every listed item that doesn't have one yet
function Index:EnsureTooltips()
    if not WH.db.settings.searchTooltips or ns.FindJob("tooltips") then return end
    local data = self:Build()
    local list = {}
    for key in pairs(data.items) do
        if not self.tips[key] and not self.tipWanted[key] and not self.tipFailed[key] then list[#list + 1] = key end
    end
    if #list == 0 then return end
    table.sort(list)
    local job = { name = "tooltips", label = "reading item tooltips", keys = list, i = 1 }
    function job:Step(deadline)
        local keys, n = self.keys, #self.keys
        while self.i <= n do
            Index:ReadTooltip(Index:Meta(keys[self.i]))
            self.i = self.i + 1
            if self.i % 8 == 0 and ns.Clock() >= deadline then return false end
        end
        return true
    end
    function job:Progress() return self.i - 1, #self.keys end
    function job:OnDone() if WH.RequestUIRefresh then WH:RequestUIRefresh() end end
    ns.StartJob(job)
end

function Index:TooltipProgress()
    local job = ns.FindJob("tooltips")
    if job then return job:Progress() end
    return nil
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------
-- Words, or "a quoted phrase"; every term must match
function Index.ParseSearch(text)
    local terms = {}
    text = ns.Trim(text or ""):lower()
    text = text:gsub('"([^"]*)"', function(phrase)
        phrase = ns.Trim(phrase)
        if phrase ~= "" then terms[#terms + 1] = phrase end
        return " "
    end)
    for word in text:gmatch("%S+") do
        word = word:gsub('"', "")
        if word ~= "" then terms[#terms + 1] = word end
    end
    return terms
end

-- True when every term is in the item's name, its type/subtype/slot, or
-- (with useTips) its tooltip. A search that is just a number matches item IDs
-- and names only, so "51" doesn't list every item with a 51 in its tooltip.
function Index:Matches(m, terms, useTips)
    if #terms == 1 and terms[1]:match("^%d+$") then
        return m.id == tonumber(terms[1]) or (m.lname ~= nil and m.lname:find(terms[1], 1, true) ~= nil)
    end
    local tip = useTips and self.tips[m.key] or nil
    for _, term in ipairs(terms) do
        local found = (m.lname and m.lname:find(term, 1, true))
            or (m.kinds and m.kinds:find(term, 1, true))
            or (tip and tip:find(term, 1, true))
        if not found then return false end
    end
    return true
end

-------------------------------------------------------------------------------
-- Counts by item ID across every saved owner (for item tooltips and
-- /warehouse count). Not filtered by the window's filters; the tooltip has
-- its own scope setting.
-------------------------------------------------------------------------------
function Index:IdMap()
    if self.idMap and self.idMapVersion == Scan.version then return self.idMap end
    local map, now = {}, time()
    local function Add(id, ownerKey, kind, rec, loc, n)
        if not id then return end
        local o = map[id]
        if not o then o = {}; map[id] = o end
        local r = o[ownerKey]
        if not r then r = { kind = kind, key = ownerKey, rec = rec, n = 0, loc = {} }; o[ownerKey] = r end
        r.n = r.n + n
        r.loc[loc] = (r.loc[loc] or 0) + n
    end
    for key, c in pairs(WH.db.chars) do
        for _, loc in ipairs(COUNT_LOCS) do
            for k, n in pairs(c[loc].items) do Add(Scan.KeyID(k), key, "char", c, loc, n) end
        end
        for _, e in ipairs(c.mail.list) do
            if not e.x or e.x > now then Add(Scan.KeyID(e.k), key, "char", c, "mail", e.c) end
        end
    end
    for key, g in pairs(WH.db.guilds) do
        for _, t in pairs(g.tabs) do
            for k, n in pairs(t.items) do Add(Scan.KeyID(k), key, "guild", g, "guild", n) end
        end
    end
    self.idMap, self.idMapVersion = map, Scan.version
    return map
end

local function InScope(rec, scope)
    local me = Scan.me
    if scope == "all" or not me then return true end
    if scope == "ruleset" then return Scan:SameWorld(rec) end
    return rec.region == me.region
end

-- Owners holding the item (most first, the character you're playing on top), and the total
function Index:CountsFor(id, scope)
    local byOwner = self:IdMap()[id]
    if not byOwner then return {}, 0 end
    local list, total = {}, 0
    for _, r in pairs(byOwner) do
        if InScope(r.rec, scope) then
            list[#list + 1] = r
            total = total + r.n
        end
    end
    table.sort(list, function(a, b)
        if (a.key == Scan.meKey) ~= (b.key == Scan.meKey) then return a.key == Scan.meKey end
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return list, total
end

function Index.LocText(r)
    local parts = {}
    for _, loc in ipairs(ns.LOCATIONS) do
        local n = r.loc[loc]
        if n then parts[#parts + 1] = ("%s %s"):format(ns.LOC_LABEL[loc], ns.Commas(n)) end
    end
    return table.concat(parts, ", ")
end

local MAX_TIP_OWNERS = 8

function Index:AddCountLines(tt, id)
    local list, total = self:CountsFor(id, WH.db.settings.tooltipScope)
    if #list == 0 then return end
    tt:AddLine(" ")
    tt:AddDoubleLine("Warehouse", ns.Commas(total) .. " in total", 0.902, 0.706, 0.133, 0.902, 0.839, 0.682)
    for i, r in ipairs(list) do
        if i > MAX_TIP_OWNERS then
            tt:AddLine(("+ %d more"):format(#list - MAX_TIP_OWNERS), 0.612, 0.553, 0.439)
            break
        end
        tt:AddDoubleLine(ns.OwnerLabel(r.kind, r.rec), Index.LocText(r), 1, 1, 1, 0.902, 0.839, 0.682)
    end
end

function Index:OnItemTooltip(tt, data)
    if self.suppress or not WH.db or not WH.db.settings.tooltipCounts then return end
    if tt ~= GameTooltip and tt ~= rawget(_G, "ItemRefTooltip") then return end
    local id = type(data) == "table" and Num(data.id) or nil
    if not id and tt.GetItem then
        local _, _, tid = tt:GetItem()
        id = Num(tid)
    end
    if id then self:AddCountLines(tt, id) end
end

function Index:HookTooltips()
    if self.tooltipHooked then return end
    local function Post(tt, data)
        local ok, err = pcall(Index.OnItemTooltip, Index, tt, data)
        if not ok and not Index.tipErrorShown then
            Index.tipErrorShown = true
            ns.Print("|cffff4040item tooltip counts failed:|r " .. tostring(err))
        end
    end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then       -- RETEST
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, Post)
        self.tooltipHooked = true
    elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
        GameTooltip:HookScript("OnTooltipSetItem", function(tt) Post(tt, nil) end)
        self.tooltipHooked = true
    end
end

-------------------------------------------------------------------------------
-- /warehouse count <item>
-------------------------------------------------------------------------------
function Index:PrintCount(text)
    text = ns.Trim(text or "")
    if text == "" then ns.Print("use /warehouse count <item name, item ID or shift-clicked link>.") return end
    local map = self:IdMap()
    local id
    local key = text:find("|H", 1, true) and Scan.ItemKey(text) or nil
    if key then id = Scan.KeyID(key) end
    if not id and text:match("^%d+$") then id = tonumber(text) end
    if not id then
        local lt = text:lower()
        local exact, partial, partialHeld
        for k, packed in pairs(WH.db.names) do
            local n = packed:sub(2):lower()
            local kid = Scan.KeyID(k)
            if n == lt and (not exact or map[kid]) then exact = kid end
            if not partialHeld and n:find(lt, 1, true) then
                if map[kid] then partialHeld = kid elseif not partial then partial = kid end
            end
        end
        id = exact or partialHeld or partial
    end
    if not id then ns.Print(("no saved item matches \"%s\"."):format(text)) return end
    local name = Scan:ItemName(tostring(id), id) or ("item " .. id)
    local list, total = self:CountsFor(id, "all")
    if #list == 0 then ns.Print(("none of your characters holds %s."):format(name)) return end
    ns.Print(("%s: %s in total"):format(name, ns.Commas(total)))
    for _, r in ipairs(list) do
        print(("  %s  %s"):format(ns.OwnerLabel(r.kind, r.rec), Index.LocText(r)))
    end
end
