local addonName, ns = ...
-- Core.lua
-- Warehouse keeps a searchable record of what each of your characters holds:
-- bags, personal bank, guild banks, mailbox and equipped gear, filed by
-- region (US, EU, Oceanic), ruleset (PvE, PvP) and faction.
--
-- This file: shared helpers, SavedVariables (created in ADDON_LOADED and
-- merged onto defaults), the one event frame with its handler table, the
-- out-of-combat queue, the background job runner, the capability probe and
-- the /warehouse command.
--
-- Unit data: Warehouse reads only the player's own name, GUID, class, level,
-- faction and guild name, plus links of equipped items. Every value goes
-- through ns.Text / ns.Num / ns.Bool, which drop Midnight "secret" values
-- before anything compares, branches on, concatenates, stores or prints
-- them. Health and power are never read, and nothing does arithmetic on a
-- name. Warehouse never touches the combat log, never compiles secure
-- snippets, never parses a GUID, and never keys anything by realm (Forever
-- has no realms: only regions and rulesets). Region and ruleset are read
-- only with ns.GetRegion and ns.GetRuleset below.
--
-- Lines marked RETEST depend on the client build; check them when the
-- interface number moves off 16001.

local WH = {}
ns.WH = WH
if rawget(_G, "Warehouse") == nil then _G.Warehouse = WH end      -- for /dump Warehouse.db

WH.VERSION          = "0.2.1"
WH.TESTED_INTERFACE = 16001                                     -- RETEST: the build this was written against
WH.PREFIX           = "|cffe6b422Warehouse:|r "

local floor = math.floor

-------------------------------------------------------------------------------
-- Secret-value guards
-------------------------------------------------------------------------------
local issecretvalue = issecretvalue                             -- RETEST: Midnight secret values

function ns.IsSecret(v)
    if v == nil or issecretvalue == nil then return false end
    return issecretvalue(v) and true or false
end

-- A usable string from a game API, or nil (secret, empty or not a string)
function ns.Text(v)
    if type(v) ~= "string" or ns.IsSecret(v) or v == "" then return nil end
    return v
end

-- A usable number, or nil (secret, NaN or not a number)
function ns.Num(v)
    if type(v) ~= "number" or ns.IsSecret(v) then return nil end
    if v ~= v then return nil end
    return v
end

-- A usable boolean, or nil (secret or not a boolean)
function ns.Bool(v)
    if type(v) ~= "boolean" or ns.IsSecret(v) then return nil end
    return v
end

function ns.Print(msg)
    print(WH.PREFIX .. tostring(msg))
end

function ns.Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- pcall here only isolates Lua errors from optional APIs; it does not make a
-- protected call safe, and nothing in Warehouse makes protected calls.
local function PassResults(ok, ...)
    if ok then return ... end
    return nil
end

function ns.SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    return PassResults(pcall(fn, ...))          -- every return value (C_Item.GetItemInfo has 17)
end

function ns.Plural(n, one, many)
    return n == 1 and one or (many or (one .. "s"))
end

-------------------------------------------------------------------------------
-- Numbers, money, times
-------------------------------------------------------------------------------
function ns.Commas(n)
    n = ns.Num(n) or 0
    local s = ("%.0f"):format(n)
    local neg = s:sub(1, 1) == "-"
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (neg and "-" or "") .. out
end

function ns.Bytes(n)
    n = ns.Num(n) or 0
    if n < 1024 then return ("%d bytes"):format(n) end
    if n < 1024 * 1024 then return ("%.0f KB"):format(n / 1024) end
    return ("%.1f MB"):format(n / (1024 * 1024))
end

local GOLD, SILVER, COPPER = "|cffffd700", "|cffc7c7cf", "|cffeda55f"

-- Money with coin icons, like the game's own displays
function ns.Coins(copper)
    copper = ns.Num(copper)
    if not copper then return "|cff9d9d9d—|r" end
    copper = floor(copper + 0.5)
    if GetCoinTextureString then                                -- RETEST
        local s = ns.SafeCall(GetCoinTextureString, copper, 12)
        if type(s) == "string" then return s end
    end
    return ns.Money(copper)
end

-- Compact coloured text with the two biggest units: "12g 50s", "7s 25c", "40c"
function ns.Money(copper)
    copper = ns.Num(copper)
    if not copper then return "|cff9d9d9d—|r" end
    copper = floor(copper + 0.5)
    local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
    if g > 0 then
        if s > 0 and g < 1000 then return ("%s%s|rg %s%d|rs"):format(GOLD, ns.Commas(g), SILVER, s) end
        return ("%s%s|rg"):format(GOLD, ns.Commas(g))
    end
    if s > 0 then
        if c > 0 then return ("%s%d|rs %s%d|rc"):format(SILVER, s, COPPER, c) end
        return ("%s%d|rs"):format(SILVER, s)
    end
    return ("%s%d|rc"):format(COPPER, c)
end

-- The same without colours: "12g 50s"
function ns.PlainMoney(copper)
    copper = ns.Num(copper)
    if not copper then return "—" end
    return (ns.Money(copper):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

function ns.Ago(t)
    t = ns.Num(t)
    if not t or t <= 0 then return "never" end
    local d = time() - t
    if d < 60 then return "just now" end
    if d < 3600 then local m = floor(d / 60); return m == 1 and "1 minute ago" or (m .. " minutes ago") end
    if d < 86400 then local h = floor(d / 3600); return h == 1 and "1 hour ago" or (h .. " hours ago") end
    local days = floor(d / 86400)
    return days == 1 and "yesterday" or (days .. " days ago")
end

-- "in 2 days", "in 5 hours", "expired"
function ns.Until(t)
    t = ns.Num(t)
    if not t then return "?" end
    local d = t - time()
    if d <= 0 then return "expired" end
    if d < 3600 then local m = math.max(1, floor(d / 60)); return ("in %d %s"):format(m, ns.Plural(m, "minute")) end
    if d < 86400 then local h = floor(d / 3600); return ("in %d %s"):format(h, ns.Plural(h, "hour")) end
    local days = floor(d / 86400)
    return ("in %d %s"):format(days, ns.Plural(days, "day"))
end

-------------------------------------------------------------------------------
-- Regions, rulesets, factions, locations: the vocabulary every file shares
-------------------------------------------------------------------------------
-- One guild bank tab, for the guild bank filter
function ns.GuildTabKey(guildKey, tab)
    return guildKey .. ":tab:" .. tostring(tab)
end

-- A character's region, as the client reports it (GetCurrentRegion). US
-- covers the Americas and Oceania: Oceanic players share the US world and
-- auction house, so they aren't told apart. KR, TW and CN are "Other".
ns.AREAS      = { US = "US", EU = "EU", OTHER = "Other" }
ns.AREA_ORDER = { "US", "EU", "OTHER" }

function ns.AreaFor(region)
    if region == "US" or region == "EU" then return region end
    return "OTHER"
end

function ns.AreaGroup(area)
    if area == "US" or area == "EU" then return area end
    return "OTHER"
end

-- Rulesets: exactly what ns.GetRuleset can return. "" on a record means the
-- game hasn't told Warehouse yet; the filter calls that "Not read yet".
ns.RULESETS = {
    PvE      = { label = "PvE" },
    PvP      = { label = "PvP" },
    RP       = { label = "RP" },
    Hardcore = { label = "Hardcore" },
}
ns.RULESET_ORDER  = { "PvE", "PvP", "RP", "Hardcore" }
ns.RULE_FILTER    = { "PvE", "PvP", "RP", "Hardcore", "UNSET" }
ns.RULE_LABELS    = { PvE = "PvE", PvP = "PvP", RP = "RP", Hardcore = "Hardcore", UNSET = "Not read yet" }

-- The Ruleset filter's key for a record
function ns.RuleKey(ruleset)
    return ns.RULESETS[ruleset or ""] and ruleset or "UNSET"
end

-------------------------------------------------------------------------------
-- Region and ruleset: read only these ways (the addon rules' GetRegion and
-- GetRuleset), with every value that can be secret guarded first.
-------------------------------------------------------------------------------
local REGION_CODES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

-- The region code and where it came from. Prefers the regionID of the
-- player's Battle.net game account, then the portal-based functions.
-- KR and TW are one region group until a Taiwan player confirms the regionID
-- reads TW, and the region is never used for anything that breaks if it's
-- wrong: it's only shown and filtered on, never part of a saved key.
function ns.GetRegion()
    local guid = UnitGUID and ns.Text(UnitGUID("player"))
    if guid and C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID then           -- RETEST
        local info = ns.SafeCall(C_BattleNet.GetGameAccountInfoByGUID, guid)
        local id = type(info) == "table" and ns.Num(info.regionID) or nil
        if id and REGION_CODES[id] then return REGION_CODES[id], "Battle.net game account" end
    end
    if GetCurrentRegionName then                                                       -- RETEST
        local name = ns.Text((ns.SafeCall(GetCurrentRegionName)))
        if name then return name:upper(), "GetCurrentRegionName" end
    end
    if GetCurrentRegion then                                                           -- RETEST
        local id = ns.Num((ns.SafeCall(GetCurrentRegion)))
        if id and REGION_CODES[id] then return REGION_CODES[id], "GetCurrentRegion" end
        return nil, ("GetCurrentRegion gave an unknown ID (%s)"):format(tostring(id))
    end
    return nil, "no region function on this build"
end

-- The ruleset: Hardcore, RP, PvP, else PvE, checked in that order. nil when
-- this build lacks the API or a rule's answer can't be read (secret or not a
-- boolean). The second value describes each answer, for the probe.
local RULE_CHECKS = { { "HardcoreRuleset", "Hardcore" }, { "RPRuleset", "RP" }, { "PvPRuleset", "PvP" } }

function ns.GetRuleset()
    if not (C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule) then   -- RETEST
        return nil, "C_GameRules.IsGameRuleActive is missing on this build"
    end
    local words = {}
    for _, check in ipairs(RULE_CHECKS) do
        local id = Enum.GameRule[check[1]]                                             -- RETEST: 10, 214, 213 on 71037
        local on
        if id == nil then
            on = false                                    -- a rule this build doesn't have isn't active
            words[#words + 1] = check[2] .. " missing"
        else
            local ok, v = pcall(C_GameRules.IsGameRuleActive, id)
            if ok then on = ns.Bool(v) end
            words[#words + 1] = check[2] .. " " .. (on == nil and "unreadable" or (on and "on" or "off"))
        end
        if on == nil then return nil, table.concat(words, ", ") end
        if on then return check[2], table.concat(words, ", ") end
    end
    return "PvE", table.concat(words, ", ")
end

ns.FACTIONS      = { Horde = "Horde", Alliance = "Alliance", Neutral = "Neutral" }
ns.FACTION_ORDER = { "Horde", "Alliance", "Neutral" }

ns.LOCATIONS   = { "bags", "bank", "guild", "mail", "equipped" }
ns.LOC_LABEL   = { bags = "Bags", bank = "Bank", guild = "Guild bank", mail = "Mail", equipped = "Equipped" }
ns.LOC_SHORT   = { bags = "Bags", bank = "Bank", guild = "Guild", mail = "Mail", equipped = "Worn" }

-------------------------------------------------------------------------------
-- SavedVariables: created in ADDON_LOADED (never at file scope), merged onto defaults
-------------------------------------------------------------------------------
ns.DEFAULTS = {
    schema   = 3,
    settings = {
        sort           = "name",     -- name | total | owners | ilvl | quality | value | recent
        groupBy        = "type",     -- type | location | owner | quality | none
        searchTooltips = true,       -- search item tooltips (stats, effects), not just names
        minQuality     = 0,
        multiOwner     = false,      -- only items held by 2 or more characters or guild banks
        expiringOnly   = false,      -- only items in mail that expires soon
        expireDays     = 3,
        warnExpiring   = true,       -- chat warning at login about mail that expires soon
        regions        = { US = true, EU = true, OTHER = true },
        rulesets       = { PvE = true, PvP = true, RP = true, Hardcore = true, UNSET = true },
        factions       = { Horde = true, Alliance = true, Neutral = true },
        locations      = { bags = true, bank = true, guild = true, mail = true, equipped = true },
        guildOff       = {},         -- [guild key] = true: guild banks left out (new ones are shown)
        tabOff         = {},         -- [ns.GuildTabKey(guild key, tab)] = true: tabs left out
        who            = "all",      -- all | me | ruleset | pick
        pick           = "",         -- character key when who == "pick"
        readGuildTabs  = true,       -- read every viewable guild bank tab, not only the ones you click
        trackSentMail  = true,       -- add mail sent to your alts to their mailbox
        tooltipCounts  = true,       -- add counts to item tooltips
        tooltipScope   = "region",   -- ruleset | region | all
        announce       = true,       -- one chat line after saving a bank, guild bank or mailbox
        lastTab        = "items",
    },
    collapsed   = {},                -- [group mode .. ":" .. group name] = true
    minimap     = { hide = false },
    positions   = {},
    chars       = {},                -- [UnitGUID("player")] = character record (Scan.lua)
    guilds      = {},                -- ["club:<id>" or "name:<faction>:<guild>"] = guild bank record (Scan.lua)
    names       = {},                -- [item key] = quality digit .. name
    links       = {},                -- [item key] = item string, for items with a suffix or bonus IDs
    namesLocale = "",
}

local function Copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = Copy(x) end
    return t
end
ns.Copy = Copy

-- Fills in anything missing (or of the wrong type) from the defaults,
-- keeps everything the player already has.
local function MergeDefaults(dst, defaults)
    for k, v in pairs(defaults) do
        if dst[k] == nil or type(dst[k]) ~= type(v) then
            dst[k] = Copy(v)
        elseif type(v) == "table" then
            MergeDefaults(dst[k], v)
        end
    end
    return dst
end
ns.MergeDefaults = MergeDefaults

local function CleanCounts(t)
    if type(t) ~= "table" then return {} end
    for k, v in pairs(t) do
        if type(k) ~= "string" or type(v) ~= "number" or v <= 0 then t[k] = nil end
    end
    return t
end
ns.CleanCounts = CleanCounts

function WH:InitDB()
    if type(WarehouseDB) ~= "table" then WarehouseDB = {} end
    local db = MergeDefaults(WarehouseDB, ns.DEFAULTS)

    db.realms = nil                                             -- 0.1.x kept realms; Forever has none
    for key, c in pairs(db.chars) do
        if type(key) ~= "string" or type(c) ~= "table" or type(c.name) ~= "string" then
            db.chars[key] = nil
        else
            ns.Scan.RepairChar(c, db)
        end
    end
    for key, g in pairs(db.guilds) do
        if type(key) ~= "string" or type(g) ~= "table" or type(g.name) ~= "string" then
            db.guilds[key] = nil
        else
            ns.Scan.RepairGuild(g, db)
        end
    end
    db.schema = ns.DEFAULTS.schema
    for k, v in pairs(db.names) do
        if type(k) ~= "string" or type(v) ~= "string" then db.names[k] = nil end
    end
    for k, v in pairs(db.links) do
        if type(k) ~= "string" or type(v) ~= "string" then db.links[k] = nil end
    end
    -- item names are cached in the client's language; start over if it changed
    local locale = GetLocale and ns.Text(GetLocale()) or ""
    if db.namesLocale ~= locale then
        wipe(db.names)
        db.namesLocale = locale
    end
    -- filter settings from 0.1.x
    local s = db.settings
    s.regions.OCE = nil
    s.rulesets.PVE, s.rulesets.PVP = nil, nil
    if s.who == "realm" then s.who = "ruleset" end
    if s.tooltipScope == "realm" then s.tooltipScope = "ruleset" end
    if s.who ~= "all" and s.who ~= "me" and s.who ~= "ruleset" and s.who ~= "pick" then s.who = "all" end
    if s.tooltipScope ~= "ruleset" and s.tooltipScope ~= "region" and s.tooltipScope ~= "all" then s.tooltipScope = "region" end
    self.db = db

    -- per character: which record is this character's (see Scan:Identify)
    if type(WarehouseCharDB) ~= "table" then WarehouseCharDB = {} end
    if type(WarehouseCharDB.key) ~= "string" then WarehouseCharDB.key = nil end
    self.charDB = WarehouseCharDB
end

-------------------------------------------------------------------------------
-- One event frame, one handler table keyed by event name
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
local handlers = {}
ns.eventOK = {}

-- Registers (or replaces) the handler for an event. An event this client
-- doesn't know is reported by the probe instead of breaking the load.
function ns.On(event, fn)
    handlers[event] = fn
    local ok = pcall(events.RegisterEvent, events, event)
    ns.eventOK[event] = ok
    return ok
end

events:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h and (event == "ADDON_LOADED" or WH.db) then h(...) end
end)

-------------------------------------------------------------------------------
-- Out-of-combat queue. The Blizzard Settings panel is the only protected
-- frame Warehouse touches; it waits for combat to end. Saving scans also
-- waits, so Warehouse stays quiet while you fight.
-------------------------------------------------------------------------------
local combatQueue, combatOrder = {}, {}

function ns.AfterCombat(key, fn)
    if not InCombatLockdown() then
        fn()
        return true
    end
    if not combatQueue[key] then combatOrder[#combatOrder + 1] = key end
    combatQueue[key] = fn
    return false
end

local function FlushCombatQueue()
    local order = combatOrder
    combatOrder = {}
    for _, key in ipairs(order) do
        local fn = combatQueue[key]
        combatQueue[key] = nil
        if fn then
            local ok, err = pcall(fn)
            if not ok then ns.Print("|cffff4040error:|r " .. tostring(err)) end
        end
    end
end

-------------------------------------------------------------------------------
-- Background jobs: reading item tooltips for search runs a few milliseconds
-- per frame (C_Timer, not OnUpdate) and pauses during combat.
-- A job is { name = "...", Step = function(job, deadline) return done end,
--            OnDone = function(job) end, Progress = function(job) return done, total end }
-------------------------------------------------------------------------------
local jobs, pumping = {}, false
local BUDGET_MS = 4
local clock = debugprofilestop                                  -- RETEST
    or function() return (GetTimePreciseSec and GetTimePreciseSec() or GetTime()) * 1000 end
ns.Clock = clock

local Pump
local function Schedule()
    if pumping then return end
    pumping = true
    C_Timer.After(0, Pump)
end

Pump = function()
    pumping = false
    if #jobs == 0 then return end
    if InCombatLockdown() then
        ns.AfterCombat("jobs", Schedule)
        return
    end
    local deadline = clock() + BUDGET_MS
    repeat
        local job = jobs[1]
        local ok, done = pcall(job.Step, job, deadline)
        if not ok then
            ns.Print(("|cffff4040error|r while %s: %s"):format(job.label or job.name, tostring(done)))
            done = true
        end
        if done then
            table.remove(jobs, 1)
            if job.OnDone then
                local ok2, err = pcall(job.OnDone, job)
                if not ok2 then ns.Print("|cffff4040error:|r " .. tostring(err)) end
            end
        end
    until #jobs == 0 or clock() >= deadline
    if WH.OnJobProgress then WH:OnJobProgress() end
    if #jobs > 0 then Schedule() end
end

function ns.StartJob(job)
    jobs[#jobs + 1] = job
    Schedule()
    return job
end

function ns.FindJob(name)
    for _, job in ipairs(jobs) do
        if job.name == name then return job end
    end
    return nil
end

function ns.CurrentJob()
    return jobs[1]
end

-------------------------------------------------------------------------------
-- Capability probe (/warehouse probe and the Options tab). Nothing here picks
-- a code path from the project ID; each feature checks the API it needs.
-------------------------------------------------------------------------------
local function ListIDs(ids)
    local out = {}
    for i, id in ipairs(ids or {}) do out[i] = tostring(id) end
    return #out > 0 and table.concat(out, ", ") or "none"
end

function ns.Probe()
    local out = {}
    local function Add(label, ok, detail) out[#out + 1] = { label = label, ok = ok and true or false, detail = detail } end
    local Scan = ns.Scan

    local build, _, _, iface = GetBuildInfo()                   -- RETEST
    iface, build = ns.Num(iface), ns.Text(build)
    Add("Interface", iface == WH.TESTED_INTERFACE,
        ("%s (build %s; written for %d)"):format(tostring(iface or "?"), build or "?", WH.TESTED_INTERFACE))

    local proj = ns.Num(rawget(_G, "WOW_PROJECT_ID"))           -- RETEST: informational only
    local projName = "unknown"
    if proj then
        if proj == rawget(_G, "WOW_PROJECT_CAMELOT") then projName = "Forever (Camelot)"
        elseif proj == rawget(_G, "WOW_PROJECT_MAINLINE") then projName = "Mainline"
        elseif proj == rawget(_G, "WOW_PROJECT_CLASSIC") then projName = "Classic" end
    end
    Add("Game type", true, ("%s = %s (shown only, never used to choose behaviour)"):format(tostring(proj or "?"), projName))

    -- what the client tells addons about the player (secret values are named, never printed)
    local function Describe(v)
        if v == nil then return "nil" end
        if ns.IsSecret(v) then return "secret" end
        if v == "" then return "empty" end
        return tostring(v)
    end
    local first, second = UnitName("player")
    Add("Character", Scan.me ~= nil, Scan.me and ("%s, saved under its UnitGUID"):format(Scan.me.name)
        or "not identified: nothing is saved this session")
    local guid = UnitGUID and UnitGUID("player")
    Add("Character ID", ns.Text(guid) ~= nil, (ns.Text(guid) and "UnitGUID is readable" or ("UnitGUID gives " .. Describe(guid)))
        .. "; whether it stays the same between sessions on Forever isn't verified yet (Warehouse also remembers each character's key, and moves its record if the ID changes)")
    Add("Name", ns.Text(first) ~= nil, ("UnitName gives %s, %s"):format(Describe(first), Describe(second)))
    local faction = UnitFactionGroup("player")
    Add("Faction", ns.Text(faction) ~= nil, ("UnitFactionGroup gives %s"):format(Describe(faction)))
    local ruleset, ruleDetail = ns.GetRuleset()
    Add("Ruleset", ruleset ~= nil, ruleset and ("%s (%s)"):format(ruleset, ruleDetail)
        or ("not readable: %s"):format(ruleDetail))
    local region, regionFrom = ns.GetRegion()
    Add("Region", region ~= nil, region and ("%s, from %s%s"):format(region, regionFrom, region == "US" and " (the Americas and Oceania: one world)" or "")
        or regionFrom)
    -- C_Club.GetGuildClubId returned a number on the live client (November 24, 2026)
    local clubFn = C_Club and C_Club.GetGuildClubId                                       -- RETEST
    local clubID = clubFn and ns.SafeCall(clubFn)
    clubID = ns.Num(clubID) or ns.Text(clubID)
    Add("Guild ID", true, (clubID and ("C_Club.GetGuildClubId gives %s: your guild bank is saved under it"):format(tostring(clubID)))
        or (clubFn and "C_Club.GetGuildClubId gives nothing right now (not in a guild, or not loaded yet): guild name and faction are used")
        or "C_Club.GetGuildClubId missing: guild banks are keyed by guild name and faction")
    Add("Containers", C_Container and C_Container.GetContainerItemInfo,
        "C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo")   -- RETEST
    Add("Bag IDs", true, ListIDs(Scan:BagIDs()))
    local bankIDs, tabbed = Scan:BankIDs()
    Add("Bank IDs", #bankIDs > 0, ListIDs(bankIDs) .. (tabbed and " (tabbed character bank)" or " (bank slots + bank bags)"))
    Add("Window events", Scan.HasInteractionEvents() or ns.eventOK.BANKFRAME_OPENED,
        Scan.HasInteractionEvents() and "PLAYER_INTERACTION_MANAGER_FRAME_SHOW / HIDE" or "BANKFRAME / GUILDBANKFRAME / MAIL events")   -- RETEST
    Add("Guild bank", GetGuildBankItemLink ~= nil and GetNumGuildBankTabs ~= nil,
        (rawget(_G, "QueryGuildBankTab") and "reads every viewable tab with QueryGuildBankTab" or "QueryGuildBankTab missing: saves only the tabs you click"))   -- RETEST
    Add("Mailbox", GetInboxItem ~= nil and GetInboxHeaderInfo ~= nil, "GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink")   -- RETEST
    Add("Mail to alts", Scan.sendHooked, Scan.sendHooked and "SendMail hooked (post-hook, changes nothing)" or "SendMail not found: mail to alts appears when they open their mailbox")   -- RETEST
    Add("Item tooltips", ns.Index and ns.Index.tooltipHooked, ns.Index and ns.Index.tooltipHooked and "TooltipDataProcessor.AddTooltipPostCall" or "no tooltip hook on this client")   -- RETEST
    Add("Tooltip search", true, (C_TooltipInfo and C_TooltipInfo.GetItemByID) and "reads tooltips with C_TooltipInfo"
        or "C_TooltipInfo missing: reads tooltips with a hidden tooltip")   -- RETEST
    Add("Item loading", C_Item and C_Item.RequestLoadItemDataByID and ns.eventOK.ITEM_DATA_LOAD_RESULT,
        "C_Item.RequestLoadItemDataByID + ITEM_DATA_LOAD_RESULT")   -- RETEST
    Add("Secret values", true, issecretvalue and "issecretvalue present: guards active" or "issecretvalue absent: guards idle")
    return out
end

function WH:PrintProbe()
    ns.Print("client check:")
    for _, r in ipairs(ns.Probe()) do
        print(("  %s  %s  |cff9c8d70%s|r"):format(r.ok and "|cff40ff40OK|r" or "|cffff6040--|r", r.label, r.detail or ""))
    end
end

-------------------------------------------------------------------------------
-- /warehouse
-------------------------------------------------------------------------------
local HELP = {
    { "/warehouse", "open / close the window" },
    { "/warehouse <text>", "open the window and search (names, types, stats, effects or an item ID)" },
    { "/warehouse count <item>", "print who holds an item (name, item ID or shift-clicked link)" },
    { "/warehouse chars", "list your characters, their gold and when each was last seen" },
    { "/warehouse scan", "save your bags and gear now (and any open bank, guild bank or mailbox)" },
    { "/warehouse forget <character name>", "forget a character (asks first)" },
    { "/warehouse expiring", "list mail that expires soon on every character" },
    { "/warehouse characters", "open the Characters tab" },
    { "/warehouse options", "open the Options tab" },
    { "/warehouse minimap", "show / hide the minimap button" },
    { "/warehouse reset", "move the window back to the middle of the screen" },
    { "/warehouse probe", "check which game features this client provides" },
}

function WH:PrintHelp()
    ns.Print("commands:")
    for _, line in ipairs(HELP) do
        print(("  |cffffd100%s|r  %s"):format(line[1], line[2]))
    end
end

local commands = {}
commands[""] = function() WH:Toggle() end
commands.help = function() WH:PrintHelp() end
commands["?"] = commands.help
commands.probe = function() WH:PrintProbe() end
commands.options = function() WH:Open("options") end
commands.config = commands.options
commands.characters = function() WH:Open("chars") end
commands.chars = function() ns.Scan:PrintCharacters() end
commands.alts = commands.chars
commands.count = function(rest) ns.Index:PrintCount(rest) end
commands.expiring = function() ns.Scan:WarnExpiring(true) end
commands.scan = function() ns.Scan:ScanEverything(true) end
commands.save = commands.scan
commands.forget = function(rest) WH:ConfirmForgetByName(rest) end
commands.reset = function()
    WH.db.positions.main = nil
    if WH.frame then WH:PlaceMainFrame() end
    ns.Print("window moved back to the middle of the screen.")
end
commands.minimap = function()
    local show = WH.db.minimap.hide and true or false
    WH:SetMinimapButtonShown(show)
    ns.Print("minimap button " .. (show and "shown." or "hidden. Type /warehouse minimap to show it again."))
end

SLASH_WAREHOUSE1 = "/warehouse"
SlashCmdList["WAREHOUSE"] = function(msg)
    if not WH.db then return end
    msg = ns.Trim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    local fn = commands[(cmd or ""):lower()]
    if fn then
        fn(ns.Trim(rest or ""))
    else
        WH:OpenSearch(msg)
    end
end

-------------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    WH:InitDB()
    events:UnregisterEvent("ADDON_LOADED")
end)

-- Each startup step is isolated, so a problem in one (say the minimap button
-- on a new build) can never stop saving.
local function Step(what, fn)
    local ok, err = pcall(fn)
    if not ok then ns.Print(("|cffff4040%s failed:|r %s"):format(what, tostring(err))) end
end

ns.On("PLAYER_LOGIN", function()
    Step("character setup", function() ns.Scan:OnLogin() end)
    Step("item tooltips", function() ns.Index:HookTooltips() end)
    if WH.InitUI then WH:InitUI(Step) end
    print(("|cffe6b422Warehouse %s|r loaded  —  /warehouse to search everything your characters hold"):format(WH.VERSION))
    local iface = ns.Num((select(4, GetBuildInfo())))           -- RETEST
    if iface and iface ~= WH.TESTED_INTERFACE then
        ns.Print(("this client reports interface %d; Warehouse was written for %d. Type /warehouse probe to check what still works."):format(iface, WH.TESTED_INTERFACE))
    end
end)

ns.On("PLAYER_REGEN_ENABLED", FlushCombatQueue)
