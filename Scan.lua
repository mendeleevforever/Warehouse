local addonName, ns = ...
-- Scan.lua
-- Who is playing, and what they hold. Saves into WarehouseDB:
--   * bags and equipped gear: after login and whenever they change
--   * personal bank: while the bank is open (the client only has bank
--     contents then), so an unopened bank keeps what was saved last time
--   * guild bank: while it's open; every viewable tab is read one after the
--     other with QueryGuildBankTab, and the tab you're looking at is always
--     saved when it changes
--   * mailbox: while it's open, every attachment with the mail's expiry time.
--     Mail you send to one of your own characters is added to their mailbox
--     at once ("in the mail"), and replaced by the real mailbox when that
--     character next opens it
--
-- Records (never keyed by realm: Forever has none):
--   chars[UnitGUID("player")] = { name, region, area, ruleset, faction, class, level,
--                                 money, lastSeen, guild,
--                                 bags = { items = {[key] = count}, used, slots, t },
--                                 bank = { same }, equipped = { items, t },
--                                 mail = { list = { {k, c, x, f, cod, ret, sent} }, money, count, more, t } }
--   guilds["club:<id>" or "name:<faction>:<guild>"] = { name, region, area, ruleset, faction,
--                                 money, numTabs, t, tabs = { [tab] = { name, icon, items, used, t } } }
-- Identity: a character is keyed by UnitGUID("player"), used whole and never
-- parsed. Whether it stays the same between sessions on Forever isn't
-- verified yet, so WarehouseCharDB (per character) remembers the key and a
-- changed ID moves the record. Region and ruleset come only from
-- ns.GetRegion and ns.GetRuleset (Core.lua); faction from UnitFactionGroup.
-- Item keys: "12345" for a plain item, "12345:suffix:bonus.bonus" for items
-- with a random suffix or bonus IDs (their item string is kept in db.links).
--
-- Unit data read here (all guarded with ns.Text / ns.Num / ns.Bool before
-- any branch or storage): UnitName, UnitClass, UnitLevel, UnitFactionGroup,
-- GetGuildInfo and IsInGuild for "player", and GetInventoryItemLink /
-- GetInventoryItemID for the player's own gear.

local WH = ns.WH
local Scan = {}
ns.Scan = Scan

local Text, Num, Bool = ns.Text, ns.Num, ns.Bool
local floor = math.floor

Scan.open    = { bank = false, guild = false, mail = false }
Scan.version = 0              -- bumps whenever saved data changes; the window and tooltips rebuild from it
Scan.instant = {}             -- [itemID] = instant item info (session)
Scan.facts   = {}             -- [item key] = { ilvl, sell, stack } once the item is loaded (session)

-------------------------------------------------------------------------------
-- Repairs for saved records (called from WH:InitDB)
-------------------------------------------------------------------------------
local COUNT_LOCS = { "bags", "bank", "equipped" }

-- Rulesets saved by 0.1.x. Only the ones the game reported carry over (an
-- RP-PvP character reads as RP with ns.GetRuleset); the rest are read again
-- at that character's next login.
local OLD_RULESETS = { normal = "PvE", pvp = "PvP", rp = "RP", rppvp = "RP", hardcore = "Hardcore" }

function Scan.RepairChar(c)
    for _, loc in ipairs(COUNT_LOCS) do
        local L = c[loc]
        if type(L) ~= "table" then L = {}; c[loc] = L end
        L.items = ns.CleanCounts(L.items)
        L.t = Num(L.t) or 0
        L.used, L.slots = Num(L.used), Num(L.slots)
    end
    local m = c.mail
    if type(m) ~= "table" then m = {}; c.mail = m end
    if type(m.list) ~= "table" then m.list = {} end
    local now = time()
    for i = #m.list, 1, -1 do
        local e = m.list[i]
        if type(e) ~= "table" or type(e.k) ~= "string" or type(e.c) ~= "number" or (type(e.x) == "number" and e.x < now) then
            table.remove(m.list, i)              -- broken, or the mail has expired since it was saved
        end
    end
    m.t, m.money, m.more, m.count = Num(m.t) or 0, Num(m.money) or 0, Num(m.more) or 0, Num(m.count) or 0
    if type(c.region) ~= "string" then c.region = "??" end
    c.area, c.areaGuessed = ns.AreaFor(c.region), nil
    if not ns.FACTIONS[c.faction or ""] then c.faction = nil end
    c.money, c.level, c.lastSeen = Num(c.money), Num(c.level), Num(c.lastSeen) or 0
    if type(c.class) ~= "string" then c.class = nil end
    if type(c.guild) ~= "string" then c.guild = nil end
    if not ns.RULESETS[c.ruleset or ""] then
        c.ruleset = c.rulesetDetected and OLD_RULESETS[c.ruleset or ""] or ""
    end
    c.rulesetDetected, c.rulesetGuessed = nil, nil
    c.realm, c.realmKey = nil, nil                -- 0.1.x kept realms; Forever has none
end

function Scan.RepairGuild(g)
    if type(g.tabs) ~= "table" then g.tabs = {} end
    for i, t in pairs(g.tabs) do
        if type(i) ~= "number" or type(t) ~= "table" then
            g.tabs[i] = nil
        else
            t.items = ns.CleanCounts(t.items)
            t.t = Num(t.t) or 0
            if type(t.name) ~= "string" then t.name = "Tab " .. i end
        end
    end
    g.money, g.t, g.numTabs = Num(g.money), Num(g.t) or 0, Num(g.numTabs)
    if type(g.region) ~= "string" then g.region = "??" end
    g.area = ns.AreaFor(g.region)
    if not ns.FACTIONS[g.faction or ""] then g.faction = nil end
    if not ns.RULESETS[g.ruleset or ""] then g.ruleset = "" end   -- taken from your character at the next visit
    g.realm, g.realmKey = nil, nil
end

-------------------------------------------------------------------------------
-- Region (read with ns.GetRegion, Core.lua)
-------------------------------------------------------------------------------
function Scan:ClientRegion()
    return (ns.GetRegion()) or "??"
end

-------------------------------------------------------------------------------
-- Class colours and owner names
-------------------------------------------------------------------------------
function ns.ClassRGB(classFile)
    if classFile then
        local c
        if C_ClassColor and C_ClassColor.GetClassColor then c = ns.SafeCall(C_ClassColor.GetClassColor, classFile) end   -- RETEST
        if type(c) ~= "table" and type(rawget(_G, "RAID_CLASS_COLORS")) == "table" then c = RAID_CLASS_COLORS[classFile] end
        if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
    end
    return 0.902, 0.839, 0.682
end

function ns.ClassHex(classFile)
    local r, g, b = ns.ClassRGB(classFile)
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

ns.GUILD_HEX = "|cff40c040"

function ns.RulesetLabel(rec)
    local rs = ns.RULESETS[rec.ruleset or ""]
    return rs and rs.label or "ruleset not read yet"
end

-- "PvE", or with the region "PvE  •  US"
function ns.PlaceText(rec, withArea)
    local text = ns.RulesetLabel(rec)
    if withArea then text = text .. "  •  " .. (ns.AREAS[rec.area] or rec.region or "?") end
    return text
end

-- Coloured owner name: a character in its class colour, a guild bank as <Guild>
function ns.OwnerLabel(kind, rec)
    if kind == "guild" then return ("%s<%s>|r"):format(ns.GUILD_HEX, rec.name) end
    return ns.ClassHex(rec.class) .. rec.name .. "|r"
end

-------------------------------------------------------------------------------
-- Guild banks: keyed by the guild's club ID when the game gives one
-- (C_Club.GetGuildClubId), otherwise by faction and guild name. Never by realm.
-------------------------------------------------------------------------------
function Scan:CurrentGuildKey()
    local me = self.me
    if not me or not GetGuildInfo then return nil end
    local gname = Text((ns.SafeCall(GetGuildInfo, "player")))      -- RETEST; guarded: guild names are unit data
    if not gname then return nil end
    local club
    if C_Club and C_Club.GetGuildClubId then                       -- RETEST: a number on live, November 24, 2026
        local id = ns.SafeCall(C_Club.GetGuildClubId)
        id = Num(id) or Text(id)
        if id then club = "club:" .. tostring(id) end
    end
    return club or ("name:%s:%s"):format(me.faction or "?", gname), gname, club ~= nil
end

-- A guild bank's region, ruleset and faction come from your character
function Scan:TouchGuild(g)
    local me = self.me
    g.region, g.area = me.region, me.area
    g.faction = me.faction or g.faction
    if me.ruleset ~= "" then g.ruleset = me.ruleset end
end

-- A guild bank moved to a new key: its filter entries and references follow
function Scan:MoveGuild(oldKey, newKey)
    local db = WH.db
    db.guilds[newKey], db.guilds[oldKey] = db.guilds[oldKey], nil
    local s = db.settings
    if s.guildOff[oldKey] then s.guildOff[newKey], s.guildOff[oldKey] = true, nil end
    -- collect first: a table can't gain keys while it's being looped over
    local prefix, moved = ns.GuildTabKey(oldKey, ""), {}
    for k in pairs(s.tabOff) do
        if k:sub(1, #prefix) == prefix then moved[#moved + 1] = k end
    end
    for _, k in ipairs(moved) do
        s.tabOff[k] = nil
        s.tabOff[ns.GuildTabKey(newKey, k:sub(#prefix + 1))] = true
    end
    for _, c in pairs(db.chars) do
        if c.guild == oldKey then c.guild = newKey end
    end
end

-- The current guild's bank record. One saved under another key for the same
-- guild (0.1.x realm keys, or the other key form) moves to this key first;
-- two different club IDs are never merged.
function Scan:GuildRecord(create)
    local key, gname, isClub = self:CurrentGuildKey()
    if not key then return nil end
    local db, me = WH.db, self.me
    local g = db.guilds[key]
    if not g then
        local found
        for k, old in pairs(db.guilds) do
            local sameGuild = old.name == gname and (old.faction == nil or old.faction == me.faction)
            if k ~= key and sameGuild and not (isClub and k:sub(1, 5) == "club:") then found = k break end
        end
        if found then
            g = db.guilds[found]
            self:MoveGuild(found, key)
        end
    end
    if not g and create then
        g = { name = gname, tabs = {}, t = 0 }
        db.guilds[key] = g
    end
    if g then
        g.name = gname
        Scan.RepairGuild(g)
        self:TouchGuild(g)
        me.guild = key
    end
    return g, key
end

function Scan:RefreshGuild(clearIfNone)
    local c = self.me
    if not c then return end
    local _, key = self:GuildRecord(false)
    if key then
        c.guild = key
    elseif clearIfNone and IsInGuild then
        if Bool(IsInGuild()) == false then c.guild = nil end   -- only a real "no", never a secret or a not-loaded answer
    end
end

-------------------------------------------------------------------------------
-- The character being played
-------------------------------------------------------------------------------
-- Gold. GetMoney() reads 0 while the game logs out (Warehouse 0.1.0 and
-- 0.1.1 saved that 0) and can for a moment at login, so a 0 only replaces
-- saved gold once the game has confirmed it: a PLAYER_MONEY event, or after
-- the first seconds of the session. Gold is never read at logout.
local moneyTrusted = false

local function ReadMoney(c)
    local money = GetMoney and Num(GetMoney())
    if not money then return nil end
    if money == 0 and (c.money or 0) > 0 and not moneyTrusted then return nil end
    return money
end

function Scan:RefreshMe()
    local c = self.me
    if not c then return end
    local _, classFile = UnitClass("player")
    classFile = Text(classFile)
    if classFile then c.class = classFile end
    local level = Num(UnitLevel("player"))
    if level and level > 0 then c.level = level end
    local faction = Text((UnitFactionGroup("player")))
    if faction and ns.FACTIONS[faction] then c.faction = faction end
    local money = ReadMoney(c)
    if money then c.money = money end
    c.lastSeen = time()
    self:RefreshGuild(false)
end

-- The player's full name, for showing only (characters are keyed by their
-- GUID: a bare name may not be unique). Forever characters have a first name
-- and a surname, which UnitName("player") returns as its two values.
function Scan.PlayerName()
    local first, second = UnitName("player")
    first, second = Text(first), Text(second)                   -- guarded: names can be secret values
    if first and second and not first:find(second, 1, true) then return first .. " " .. second end
    if first then return first end
    return GetUnitName and Text((ns.SafeCall(GetUnitName, "player", true))) or nil
end

function Scan.PlayerGUID()
    return UnitGUID and Text(UnitGUID("player")) or nil       -- RETEST; guarded, used whole, never parsed
end

-- The ruleset from the game (ns.GetRuleset). Only the game's answer is
-- saved; when this build can't say, the character shows "ruleset not read yet".
function Scan:ReadRuleset()
    local c = self.me
    if not c then return false end
    local ruleset = ns.GetRuleset()
    if not ruleset then return false end
    self.rulesetRead = true
    local changed = c.ruleset ~= ruleset
    c.ruleset = ruleset
    local g = c.guild and WH.db.guilds[c.guild]
    if g and g.ruleset ~= ruleset then g.ruleset, changed = ruleset, true end
    return changed
end

local toldRuleset = false

function Scan:TellRulesetMissing()
    if toldRuleset or self.rulesetRead or not self.me then return end
    toldRuleset = true
    local _, why = ns.GetRuleset()
    ns.Print(("the game didn't tell addons %s's ruleset (%s), so it shows as \"ruleset not read yet\" and the Ruleset filter lists it under Not read yet."):format(self.me.name, why))
end

-- Characters are saved under UnitGUID("player"). Whether that ID stays the
-- same between sessions on Forever isn't verified yet, so the per-character
-- WarehouseCharDB also remembers the key: if the ID ever changes, the
-- character's record moves to the new one instead of starting over.
local function IsLegacyKey(key)
    return key:find("/", 1, true) ~= nil                       -- 0.1.x keys: "US/First Last"
end

function Scan:Identify()
    local db = WH.db
    local guid = Scan.PlayerGUID()
    local remembered = WH.charDB and WH.charDB.key
    local name = Scan.PlayerName()
    local key = guid
    if not key then
        -- the client hides the ID for now: use the record this character had last time
        if remembered and db.chars[remembered] then key = remembered else return false end
    end
    local region = Scan:ClientRegion()

    if not db.chars[key] then
        local old, idChanged
        if remembered and remembered ~= key and db.chars[remembered] then
            old, idChanged = remembered, not IsLegacyKey(remembered)
        elseif name then
            for k, c in pairs(db.chars) do
                if IsLegacyKey(k) and c.name == name and c.region == region then old = k break end
            end
        end
        if old then
            db.chars[key], db.chars[old] = db.chars[old], nil
            if db.settings.pick == old then db.settings.pick = key end
            if idChanged then
                ns.Print(("%s's game ID (UnitGUID) changed since last time; Warehouse moved its saved items to the new one."):format(db.chars[key].name))
            end
        end
    end

    local c = db.chars[key]
    if not c then
        if not name then return false end                     -- a new character needs its name
        c = { name = name }
        db.chars[key] = c
    end
    if name then c.name = name end
    if region ~= "??" or type(c.region) ~= "string" then c.region = region end
    Scan.RepairChar(c)
    self.me, self.meKey = c, key
    if WH.charDB then WH.charDB.key = key end
    self:RefreshMe()
    self:ReadRuleset()
    return true
end

function Scan:AfterIdentify()
    self:Request("bags", 2)
    self:Request("equipped", 2.5)
    C_Timer.After(10, function()
        moneyTrusted = true
        Scan:Request("money", 0)
    end)
    C_Timer.After(8, function() Scan:WarnExpiring(false) end)
    C_Timer.After(3, function()
        if not Scan.rulesetRead and Scan:ReadRuleset() then Scan:Changed() end
        if not Scan.rulesetRead then Scan:TellRulesetMissing() end
    end)
    self:Changed()
end

function Scan:OnLogin()
    self:HookSendMail()
    if self:Identify() then
        self:AfterIdentify()
        return
    end
    -- the name and ID can be missing (or secret) for a moment at login; try again shortly
    local tries, ticker = 0, nil
    ticker = C_Timer.NewTicker(2, function()
        tries = tries + 1
        if Scan:Identify() then
            ticker:Cancel()
            Scan:AfterIdentify()
        elseif tries >= 15 then
            ticker:Cancel()
            ns.Print("the game is hiding this character's name or ID from addons, so nothing is saved this session. Type /reload to try again; if it keeps happening, type /warehouse probe and include the Character ID and Name lines when you report it.")
        end
    end)
end

function Scan:Changed()
    self.version = self.version + 1
    if WH.RequestUIRefresh then WH:RequestUIRefresh(0.3) end
end

-------------------------------------------------------------------------------
-- Item keys, names and item facts
-------------------------------------------------------------------------------
local function SplitItemString(s)
    local f = {}
    for field in (s .. ":"):gmatch("([^:]*):") do f[#f + 1] = field end
    return f
end

-- key, item string (the item string only for keys with a suffix or bonus IDs)
function Scan.ItemKey(link, itemID)
    link = Text(link)
    local s = link and link:match("|H(item:[^|]+)|h")
    if not s then
        itemID = Num(itemID)
        return itemID and tostring(floor(itemID)) or nil, nil
    end
    local f = SplitItemString(s)
    local id = tonumber(f[2])
    if not id then return nil, nil end
    local suffix = tonumber(f[8]) or 0
    local nb = tonumber(f[14]) or 0
    if suffix == 0 and nb <= 0 then return tostring(id), nil end
    local bonus = {}
    for i = 15, 14 + nb do bonus[#bonus + 1] = f[i] or "" end
    return ("%d:%d:%s"):format(id, suffix, table.concat(bonus, ".")), s
end

function Scan.KeyID(key)
    return tonumber(key:match("^(%d+)"))
end

function Scan.NameFromLink(link)
    link = Text(link)
    return link and link:match("|h%[(.-)%]|h") or nil
end

local function CleanName(name)
    name = Text(name)
    if not name then return nil end
    name = ns.Trim((name:gsub("|A.-|a", ""):gsub("|T.-|t", "")))
    return name ~= "" and name or nil
end

-- Caches an item's name and quality (from its link or a mail attachment)
function Scan:Remember(key, name, quality, itemString)
    local db = WH.db
    name = CleanName(name)
    if name then
        quality = Num(quality)
        if not quality or quality < 0 or quality > 9 then
            local old = db.names[key]
            quality = old and tonumber(old:sub(1, 1)) or 1
        end
        local packed = floor(quality) .. name
        if db.names[key] ~= packed then db.names[key] = packed end
    end
    if itemString and db.links[key] ~= itemString then db.links[key] = itemString end
end

-- name, quality; nil (and asks the server) when the client doesn't have it yet
function Scan:ItemName(key, id)
    local db = WH.db
    local c = db.names[key]
    if type(c) == "string" and #c > 1 then return c:sub(2), tonumber(c:sub(1, 1)) or 1 end
    id = id or Scan.KeyID(key)
    if not id then return nil end
    local ref = db.links[key] or id
    local n, q
    if not db.links[key] and C_Item and C_Item.GetItemNameByID then
        n = Text((ns.SafeCall(C_Item.GetItemNameByID, id)))     -- RETEST
    end
    if not n and C_Item and C_Item.GetItemInfo then
        local name, _, quality = ns.SafeCall(C_Item.GetItemInfo, ref)
        n, q = Text(name), Num(quality)
    end
    if n then
        if not q and C_Item and C_Item.GetItemQualityByID then q = Num((ns.SafeCall(C_Item.GetItemQualityByID, id))) end
        self:Remember(key, n, q)
        return CleanName(n) or n, q or 1
    end
    self:QueueItem(id)
    return nil
end

-- Type, subtype, slot and icon: known without loading the item
function Scan:Instant(id)
    local i = self.instant[id]
    if i then return i end
    local get = C_Item and C_Item.GetItemInfoInstant                              -- RETEST
    local _, itemType, itemSubType, equipLoc, icon, classID, subclassID = ns.SafeCall(get, id)
    i = { typeName = Text(itemType), subName = Text(itemSubType), icon = Num(icon) or Text(icon),
          cls = Num(classID), sub = Num(subclassID) }
    equipLoc = Text(equipLoc)
    i.slotName = equipLoc and Text(rawget(_G, equipLoc)) or nil      -- "INVTYPE_LEGS" -> "Legs"
    self.instant[id] = i
    return i
end

-- Item level, vendor price and stack size: needs the item loaded. nil while
-- it loads (it's requested once through the throttled queue below).
function Scan:Facts(key)
    local f = self.facts[key]
    if f then return f end
    local id = Scan.KeyID(key)
    if not id or not (C_Item and C_Item.GetItemInfo) then return nil end
    local itemString = WH.db.links[key]
    local info = { ns.SafeCall(C_Item.GetItemInfo, itemString or id) }   -- RETEST: level 4, stack 8, sell price 11
    if not Text(info[1]) then
        self:QueueItem(id)
        return nil
    end
    f = { ilvl = Num(info[4]), stack = Num(info[8]), sell = Num(info[11]) }
    if itemString and C_Item.GetDetailedItemLevelInfo then
        local d = Num((ns.SafeCall(C_Item.GetDetailedItemLevelInfo, itemString)))   -- RETEST
        if d then f.ilvl = d end
    end
    self.facts[key] = f
    return f
end

-------------------------------------------------------------------------------
-- Loading items from the server, a few at a time
-------------------------------------------------------------------------------
local urgent, normal = { head = 1, tail = 0 }, { head = 1, tail = 0 }
local queued, queuedUrgent, pending, failed, forced = {}, {}, {}, {}, {}
local outstanding = 0
local loadTicker

local function PushId(list, id)
    list.tail = list.tail + 1
    list[list.tail] = id
end

local function Pop(list)
    if list.head > list.tail then
        list.head, list.tail = 1, 0
        return nil
    end
    local id = list[list.head]
    list[list.head] = nil
    list.head = list.head + 1
    return id
end

local function QueueEmpty(list)
    return list.head > list.tail
end

local function IsCached(id)
    if C_Item and C_Item.IsItemDataCachedByID then
        return ns.SafeCall(C_Item.IsItemDataCachedByID, id) == true    -- RETEST
    end
    return false
end

local function LoadTick()
    local now = GetTime()
    for id, t in pairs(pending) do
        if now - t > 15 then pending[id] = nil; outstanding = outstanding - 1; failed[id] = true end
    end
    local sent = 0
    while sent < 25 and outstanding < 80 do
        local id = Pop(urgent) or Pop(normal)
        if not id then break end
        queued[id], queuedUrgent[id] = nil, nil
        if not pending[id] and not failed[id] then
            if not forced[id] and IsCached(id) then
                if ns.Index then ns.Index:ItemArrived(id, true, false) end
            else
                pending[id] = now
                outstanding = outstanding + 1
                sent = sent + 1
                if C_Item and C_Item.RequestLoadItemDataByID then     -- RETEST
                    ns.SafeCall(C_Item.RequestLoadItemDataByID, id)
                elseif C_Item and C_Item.GetItemInfo then
                    ns.SafeCall(C_Item.GetItemInfo, id)              -- also asks the server
                end
            end
        end
    end
    if outstanding <= 0 and QueueEmpty(urgent) and QueueEmpty(normal) and loadTicker then
        loadTicker:Cancel()
        loadTicker = nil
        outstanding = 0
    end
end

-- force: load the item even if the client has it (tooltip reading needs a fresh answer)
function Scan:QueueItem(id, isUrgent, force)
    if type(id) ~= "number" or failed[id] or pending[id] then return end
    if force then forced[id] = true end
    if isUrgent then
        if queuedUrgent[id] then return end
        queuedUrgent[id] = true
    elseif queued[id] then
        return
    end
    queued[id] = true
    PushId(isUrgent and urgent or normal, id)
    if not loadTicker then loadTicker = C_Timer.NewTicker(0.2, LoadTick) end
end

local function OnItemLoaded(itemID, success)
    itemID = Num(itemID)
    if not itemID or not pending[itemID] then return end
    pending[itemID] = nil
    outstanding = outstanding - 1
    local wasForced = forced[itemID]
    forced[itemID] = nil
    if success == false then failed[itemID] = true end
    if ns.Index then ns.Index:ItemArrived(itemID, success ~= false, wasForced) end
end

-------------------------------------------------------------------------------
-- Which containers are bags and which are the bank. Names come from
-- Enum.BagIndex when the client has it (Bag_1, ReagentBag, BankBag_1,
-- CharacterBankTab_1...); the classic numbering fills any gaps. Warband
-- (account) bank tabs are left out: they belong to no single character.
-------------------------------------------------------------------------------
local function IsBagName(n)
    return n == "Backpack" or n:match("^Bag_%d+$") ~= nil or n == "ReagentBag" or n == "Keyring"
end

local function IsBankName(n)
    return n == "Bank" or n == "Reagentbank" or n:match("^BankBag_") ~= nil or n:match("^CharacterBankTab") ~= nil
end

local function SortedKeys(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end

local function NamedBags(test)
    local named, other, tabbed = {}, {}, false
    local E = Enum and Enum.BagIndex                                  -- RETEST: container names
    if type(E) == "table" then
        for name, id in pairs(E) do
            if type(name) == "string" and type(id) == "number" then
                if test(name) then
                    named[id] = true
                    if name:match("^CharacterBankTab") then tabbed = true end
                else
                    other[id] = true
                end
            end
        end
    end
    return named, other, tabbed
end

local function LastBag()
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4          -- RETEST
end

function Scan:BagIDs()
    local set, other = NamedBags(IsBagName)
    for b = BACKPACK_CONTAINER or 0, LastBag() do
        if not other[b] then set[b] = true end
    end
    return SortedKeys(set)
end

function Scan:BankIDs()
    local set, other, tabbed = NamedBags(IsBankName)
    if not tabbed then
        local bank = BANK_CONTAINER or -1
        if not other[bank] then set[bank] = true end
        local first = LastBag() + 1
        for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do         -- RETEST
            if not other[b] then set[b] = true end
        end
    end
    -- a reagent bank that hasn't been bought has slots but holds nothing
    local reagent = Enum and Enum.BagIndex and Enum.BagIndex.Reagentbank
    if reagent and set[reagent] and IsReagentBankUnlocked and ns.Bool(IsReagentBankUnlocked()) == false then   -- RETEST
        set[reagent] = nil
    end
    return SortedKeys(set), tabbed
end

-------------------------------------------------------------------------------
-- Saving bags, bank, gear and money
-------------------------------------------------------------------------------
local function ReadContainers(ids)
    local items, used, slots = {}, 0, 0
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then   -- RETEST
        return items, used, slots
    end
    for _, bag in ipairs(ids) do
        local n = Num((ns.SafeCall(C_Container.GetContainerNumSlots, bag))) or 0
        slots = slots + n
        for slot = 1, n do
            local info = ns.SafeCall(C_Container.GetContainerItemInfo, bag, slot)
            if type(info) == "table" then
                local link = Text(info.hyperlink)
                local key, itemString = Scan.ItemKey(link, info.itemID)
                if key then
                    items[key] = (items[key] or 0) + (Num(info.stackCount) or 1)
                    used = used + 1
                    Scan:Remember(key, Scan.NameFromLink(link), info.quality, itemString)
                end
            end
        end
    end
    return items, used, slots
end

local function SameCounts(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function Scan:SaveLocation(loc, items, used, slots)
    local L = self.me[loc]
    local changed = not SameCounts(L.items, items)
    L.items, L.used, L.slots, L.t = items, used, slots, time()
    if changed then self:Changed() end
    return changed
end

local function CountItems(items)
    local n = 0
    for _, c in pairs(items) do n = n + c end
    return n
end
Scan.CountItems = CountItems

function Scan:ScanBags()
    if not self.me then return end
    local items, used, slots = ReadContainers(self:BagIDs())
    if slots == 0 then return end        -- the backpack always has slots; 0 means the bags aren't readable yet
    self:SaveLocation("bags", items, used, slots)
    self:ScanMoney()
end

function Scan:ScanBank()
    if not self.me or not self.open.bank then return end
    local items, used, slots = ReadContainers((self:BankIDs()))
    if slots == 0 then return end        -- not readable yet
    self:SaveLocation("bank", items, used, slots)
    if not self.bankAnnounced and WH.db.settings.announce then
        self.bankAnnounced = true
        local n = CountItems(items)
        ns.Print(("saved your bank: %s %s in %d of %d slots."):format(ns.Commas(n), ns.Plural(n, "item"), used, slots))
    end
end

function Scan:ScanEquipped()
    if not self.me or not GetInventoryItemLink then return end
    local items = {}
    for slot = INVSLOT_FIRST_EQUIPPED or 1, INVSLOT_LAST_EQUIPPED or 19 do    -- RETEST
        local link = Text((ns.SafeCall(GetInventoryItemLink, "player", slot)))
        local id = (not link and GetInventoryItemID) and Num((ns.SafeCall(GetInventoryItemID, "player", slot))) or nil
        local key, itemString = Scan.ItemKey(link, id)
        if key then
            items[key] = (items[key] or 0) + 1
            if link then
                local quality = GetInventoryItemQuality and Num((ns.SafeCall(GetInventoryItemQuality, "player", slot)))
                Scan:Remember(key, Scan.NameFromLink(link), quality, itemString)
            end
        end
    end
    self:SaveLocation("equipped", items, nil, nil)
end

function Scan:ScanMoney()
    local c = self.me
    if not c then return end
    local money = ReadMoney(c)
    if money and money ~= c.money then
        c.money = money
        self:Changed()
    end
end

-------------------------------------------------------------------------------
-- Mailbox
-------------------------------------------------------------------------------
function Scan:ScanMail()
    local c = self.me
    if not c or not self.open.mail or not GetInboxNumItems then return end
    local shown, total = ns.SafeCall(GetInboxNumItems)
    shown, total = Num(shown) or 0, Num(total) or 0
    local list, money, now = {}, 0, time()
    local maxAttach = ATTACHMENTS_MAX_RECEIVE or 16                          -- RETEST
    for i = 1, shown do
        local _, _, sender, _, cash, cod, daysLeft, hasItem, _, wasReturned = ns.SafeCall(GetInboxHeaderInfo, i)
        sender = Text(sender)
        cash, cod, daysLeft = Num(cash) or 0, Num(cod) or 0, Num(daysLeft)
        money = money + cash
        local expires = daysLeft and floor(now + daysLeft * 86400) or nil
        if hasItem then
            for a = 1, maxAttach do
                local name, itemID, _, count, quality = ns.SafeCall(GetInboxItem, i, a)
                itemID = Num(itemID)
                if itemID then
                    local link = GetInboxItemLink and Text((ns.SafeCall(GetInboxItemLink, i, a)))
                    local key, itemString = Scan.ItemKey(link, itemID)
                    if key then
                        Scan:Remember(key, Text(name) or Scan.NameFromLink(link), quality, itemString)
                        list[#list + 1] = { k = key, c = Num(count) or 1, x = expires, f = sender,
                                            cod = cod > 0 or nil, ret = (wasReturned == true) or nil }
                    end
                end
            end
        end
    end
    local m = c.mail
    m.list, m.money, m.count, m.more, m.t = list, money, shown, math.max(0, total - shown), now
    self:Changed()
    if not self.mailAnnounced and WH.db.settings.announce then
        self.mailAnnounced = true
        local n = 0
        for _, e in ipairs(list) do n = n + e.c end
        ns.Print(("saved your mailbox: %s %s in %d %s%s."):format(ns.Commas(n), ns.Plural(n, "item"), shown, ns.Plural(shown, "mail"),
            m.more > 0 and (" (%d more still on the server)"):format(m.more) or ""))
    end
end

-- Mail sent to one of your own characters goes into their record at once.
-- The attachments are read when they change (MAIL_SEND_INFO_UPDATE) and when
-- SendMail is called (a post-hook: it runs after the game's own code and
-- changes nothing), and saved only when the game confirms the send.
local function ReadOutbox()
    local list = {}
    if not GetSendMailItem then return list end
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do                                -- RETEST
        local name, itemID, _, count, quality = ns.SafeCall(GetSendMailItem, i)
        itemID = Num(itemID)
        if itemID then
            local link = GetSendMailItemLink and Text((ns.SafeCall(GetSendMailItemLink, i)))
            local key, itemString = Scan.ItemKey(link, itemID)
            if key then
                Scan:Remember(key, Text(name) or Scan.NameFromLink(link), quality, itemString)
                list[#list + 1] = { k = key, c = Num(count) or 1 }
            end
        end
    end
    return list
end

function Scan:HookSendMail()
    if self.sendHooked then return end
    if type(rawget(_G, "SendMail")) == "function" then                     -- RETEST
        hooksecurefunc("SendMail", function(recipient) Scan:OnSendMail(recipient) end)
        self.sendHooked = true
    end
end

function Scan:OnSendMail(recipient)
    self.sending = nil
    if not self.me or not WH.db.settings.trackSentMail then return end
    recipient = Text(recipient)
    if not recipient then return end
    local items = ReadOutbox()
    if #items == 0 then items = self.outbox or {} end
    if #items == 0 then return end
    self.sending = { to = ns.Trim(recipient), items = items }
end

-- The one character of yours with that name in your region and ruleset (mail
-- doesn't cross them); a character whose ruleset the game hasn't reported
-- yet counts if it's the only candidate. A name may not be unique, so if two
-- match, nothing is added: the mailbox is saved anyway when that character
-- opens it.
function Scan:FindAlt(recipient)
    local me = self.me
    local name = ns.Trim(recipient:match("^(.-)%-.+$") or recipient)
    local lname = name:lower()
    local exact, loose = {}, {}
    for key, c in pairs(WH.db.chars) do
        if c.region == me.region and (c.name == name or c.name:lower() == lname) then
            if c.ruleset == me.ruleset then
                exact[#exact + 1] = key
            elseif c.ruleset == "" or me.ruleset == "" then
                loose[#loose + 1] = key
            end
        end
    end
    local key = (#exact == 1 and exact[1]) or (#exact == 0 and #loose == 1 and loose[1]) or nil
    if key then return WH.db.chars[key], key end
    return nil
end

function Scan:CommitSent()
    local s = self.sending
    self.sending = nil
    if not s or not self.me then return end
    local target, key = self:FindAlt(s.to)
    if not target or key == self.meKey then return end
    local now, n = time(), 0
    for _, it in ipairs(s.items) do
        target.mail.list[#target.mail.list + 1] = { k = it.k, c = it.c, x = now + 30 * 86400, f = self.me.name, sent = now }
        n = n + it.c
    end
    self:Changed()
    if WH.db.settings.announce then
        ns.Print(("added %s %s to %s's mailbox (in the mail until they open it)."):format(ns.Commas(n), ns.Plural(n, "item"), target.name))
    end
end

-------------------------------------------------------------------------------
-- Guild bank
-------------------------------------------------------------------------------
local GB_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98                         -- RETEST

function Scan:ScanGuildMoney()
    local g = self.open.guild and self:GuildRecord(true)
    if not g or not GetGuildBankMoney then return end
    local money = Num((ns.SafeCall(GetGuildBankMoney)))
    if money and money ~= g.money then
        g.money = money
        self:Changed()
    end
end

-- Saves one tab. A tab that reads empty while it held items before (and
-- isn't the tab on screen) probably hasn't arrived from the server yet, so
-- what was saved before is kept.
function Scan:ScanGuildTab(g, tab)
    local name, icon, viewable = ns.SafeCall(GetGuildBankTabInfo, tab)
    if not viewable then return false end
    local items, used = {}, 0
    for slot = 1, GB_SLOTS do
        local link = Text((ns.SafeCall(GetGuildBankItemLink, tab, slot)))
        if link then
            local _, count, _, _, quality = ns.SafeCall(GetGuildBankItemInfo, tab, slot)
            local key, itemString = Scan.ItemKey(link)
            if key then
                items[key] = (items[key] or 0) + (Num(count) or 1)
                used = used + 1
                Scan:Remember(key, Scan.NameFromLink(link), quality, itemString)
            end
        end
    end
    local old = g.tabs[tab]
    local current = GetCurrentGuildBankTab and Num((ns.SafeCall(GetCurrentGuildBankTab)))
    if used == 0 and old and next(old.items) and tab ~= current then return false end
    g.tabs[tab] = { name = Text(name) or ("Tab " .. tab), icon = Num(icon) or Text(icon), items = items, used = used, t = time() }
    g.t = time()
    return true
end

function Scan:ScanGuild()
    if not self.open.guild or not self.me or not self.gbLoaded then return end
    local g = self:GuildRecord(true)
    if not g then return end
    local any = false
    for tab in pairs(self.gbLoaded) do
        if self:ScanGuildTab(g, tab) then any = true end
    end
    if any then self:Changed() end
end

function Scan:OnGuildBankOpened()
    self.gbLoaded, self.gbQueue, self.gbWaiting, self.gbToken = {}, {}, nil, nil
    local g = self:GuildRecord(true)
    if not g then
        ns.Print("couldn't read your guild's name, so the guild bank isn't saved this time.")
        return
    end
    local n = GetNumGuildBankTabs and Num((ns.SafeCall(GetNumGuildBankTabs))) or 0
    g.numTabs = n
    for tab in pairs(g.tabs) do
        if tab > n then g.tabs[tab] = nil end              -- the guild has fewer tabs now
    end
    self:ScanGuildMoney()
    self.gbAnnounce = WH.db.settings.announce
    if WH.db.settings.readGuildTabs and rawget(_G, "QueryGuildBankTab") then   -- RETEST: not protected on 12.x
        local current = GetCurrentGuildBankTab and Num((ns.SafeCall(GetCurrentGuildBankTab)))
        for tab = 1, n do
            local _, _, viewable = ns.SafeCall(GetGuildBankTabInfo, tab)
            if viewable and tab ~= current then self.gbQueue[#self.gbQueue + 1] = tab end
        end
        -- let the game's own query of the tab on screen arrive first
        C_Timer.After(1, function() Scan:NextGuildTab() end)
    end
end

function Scan:NextGuildTab()
    if not self.open.guild or not self.gbQueue then return end
    local tab = table.remove(self.gbQueue, 1)
    if not tab then
        self.gbWaiting = nil
        if self.gbAnnounce then
            self.gbAnnounce = false
            local g = self:GuildRecord(false)
            if g then
                local items, tabs = 0, 0
                for _, t in pairs(g.tabs) do items = items + CountItems(t.items); tabs = tabs + 1 end
                ns.Print(("saved the guild bank of <%s>: %s %s in %d %s."):format(g.name, ns.Commas(items), ns.Plural(items, "item"), tabs, ns.Plural(tabs, "tab")))
            end
        end
        return
    end
    self.gbWaiting = tab
    local token = {}
    self.gbToken = token
    ns.SafeCall(QueryGuildBankTab, tab)
    C_Timer.After(3, function()                             -- no answer: move on
        if Scan.gbToken == token then
            Scan.gbWaiting = nil
            Scan:NextGuildTab()
        end
    end)
end

function Scan:OnGuildBankSlotsChanged()
    if not self.open.guild or not self.gbLoaded then return end
    local current = GetCurrentGuildBankTab and Num((ns.SafeCall(GetCurrentGuildBankTab)))
    if current then self.gbLoaded[current] = true end
    if self.gbWaiting then
        self.gbLoaded[self.gbWaiting] = true
        self.gbWaiting, self.gbToken = nil, nil
        C_Timer.After(0.4, function() Scan:NextGuildTab() end)
    end
    self:Request("guild", 0.3)
end

-------------------------------------------------------------------------------
-- Windows opening and closing
-------------------------------------------------------------------------------
local RUN = {
    bags     = function() Scan:ScanBags() end,
    bank     = function() Scan:ScanBank() end,
    equipped = function() Scan:ScanEquipped() end,
    mail     = function() Scan:ScanMail() end,
    guild    = function() Scan:ScanGuild() end,
    money    = function() Scan:ScanMoney() end,
}
local requested = {}

-- Saves soon (changes come in bursts), and never during combat
function Scan:Request(what, delay)
    if requested[what] then return end
    requested[what] = true
    C_Timer.After(delay or 0.4, function()
        requested[what] = nil
        if Scan.me then ns.AfterCombat("scan:" .. what, RUN[what]) end
    end)
end

function Scan:ScanEverything(verbose)
    if not self.me then
        if verbose then ns.Print("this character isn't identified yet; try again in a moment.") end
        return
    end
    self:Request("bags", 0)
    self:Request("equipped", 0)
    if self.open.bank then self:Request("bank", 0) end
    if self.open.mail then self:Request("mail", 0) end
    if self.open.guild then self:Request("guild", 0) end
    if verbose then ns.Print("saving your bags and gear" .. ((self.open.bank or self.open.mail or self.open.guild) and ", and the open window." or ".")) end
end

local OPENERS = {
    bank  = function() Scan.bankAnnounced = false; Scan:Request("bank", 0.6) end,
    guild = function() Scan:OnGuildBankOpened() end,
    mail  = function() Scan.mailAnnounced = false; Scan:Request("mail", 1.0) end,
}

function Scan:Opened(what)
    if self.open[what] then return end
    self.open[what] = true
    if self.me then OPENERS[what]() end
end

function Scan:Closed(what)
    self.open[what] = false
    if what == "guild" then self.gbQueue, self.gbWaiting, self.gbToken = nil, nil, nil end
end

-- Mainline-family clients announce these windows through the interaction
-- manager; the older per-window events are registered too, in case.
local INTERACTION = {}
local PIT = Enum and Enum.PlayerInteractionType                             -- RETEST
if type(PIT) == "table" then
    if PIT.Banker then INTERACTION[PIT.Banker] = "bank" end
    if PIT.GuildBanker then INTERACTION[PIT.GuildBanker] = "guild" end
    if PIT.MailInfo then INTERACTION[PIT.MailInfo] = "mail" end
end

function Scan.HasInteractionEvents()
    return ns.eventOK.PLAYER_INTERACTION_MANAGER_FRAME_SHOW and next(INTERACTION) ~= nil
end

-------------------------------------------------------------------------------
-- Settings changed by the player
-------------------------------------------------------------------------------
-- Same region and ruleset as the character you're playing (Forever has no
-- realms: a region and a ruleset make one world)
function Scan:SameWorld(rec)
    local me = self.me
    if not me then return false end
    return rec.region == me.region and (rec.ruleset or "") == (me.ruleset or "")
end

function Scan:ForgetChar(key)
    local c = WH.db.chars[key]
    if not c then return false end
    if key == self.meKey then
        ns.Print("you can't forget the character you're playing.")
        return false
    end
    WH.db.chars[key] = nil
    if WH.db.settings.pick == key then WH.db.settings.who, WH.db.settings.pick = "all", "" end
    self:Changed()
    ns.Print(("forgot %s."):format(c.name))
    return true
end

function Scan:ForgetGuild(key)
    local g = WH.db.guilds[key]
    if not g then return false end
    WH.db.guilds[key] = nil
    local s = WH.db.settings
    s.guildOff[key] = nil
    local prefix = ns.GuildTabKey(key, "")
    for k in pairs(s.tabOff) do
        if k:sub(1, #prefix) == prefix then s.tabOff[k] = nil end
    end
    self:Changed()
    ns.Print(("forgot the guild bank of <%s>."):format(g.name))
    return true
end

-------------------------------------------------------------------------------
-- Chat reports
-------------------------------------------------------------------------------
function Scan:SortedChars()
    local list = {}
    for key, c in pairs(WH.db.chars) do list[#list + 1] = { key = key, c = c } end
    table.sort(list, function(a, b)
        if (a.key == Scan.meKey) ~= (b.key == Scan.meKey) then return a.key == Scan.meKey end
        if a.c.region ~= b.c.region then return a.c.region < b.c.region end
        if a.c.ruleset ~= b.c.ruleset then return a.c.ruleset < b.c.ruleset end
        return a.c.name < b.c.name
    end)
    return list
end

function Scan:PrintCharacters()
    local list = self:SortedChars()
    if #list == 0 then ns.Print("no characters saved yet.") return end
    ns.Print("your characters:")
    local gold = 0
    for _, it in ipairs(list) do
        local c = it.c
        gold = gold + (c.money or 0)
        print(("  %s  |cff9c8d70%s, %s|r  %s  |cff9c8d70seen %s|r"):format(ns.OwnerLabel("char", c), ns.PlaceText(c, true),
            c.faction or "?", ns.Coins(c.money), it.key == self.meKey and "now" or ns.Ago(c.lastSeen)))
    end
    print(("  |cffffd100Total gold|r  %s"):format(ns.Coins(gold)))
end

-- Mail that expires within the warning window, on every character
function Scan:WarnExpiring(force)
    local s = WH.db.settings
    if not force and not s.warnExpiring then return end
    local now, limit = time(), time() + s.expireDays * 86400
    local found = false
    for _, it in ipairs(self:SortedChars()) do
        local n, soonest = 0, nil
        for _, e in ipairs(it.c.mail.list) do
            if e.x and e.x > now and e.x <= limit and not e.sent then
                n = n + e.c
                if not soonest or e.x < soonest then soonest = e.x end
            end
        end
        if n > 0 then
            if not found then ns.Print(("mail expiring within %d %s:"):format(s.expireDays, ns.Plural(s.expireDays, "day"))) end
            found = true
            print(("  %s  %s %s, the first %s"):format(ns.OwnerLabel("char", it.c), ns.Commas(n), ns.Plural(n, "item"), ns.Until(soonest)))
        end
    end
    if not found and force then
        ns.Print(("no saved mail expires within %d %s."):format(s.expireDays, ns.Plural(s.expireDays, "day")))
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
ns.On("BAG_UPDATE_DELAYED", function()
    Scan:Request("bags", 0.3)
    if Scan.open.bank then Scan:Request("bank", 0.3) end
end)

local function BankChanged() if Scan.open.bank then Scan:Request("bank", 0.3) end end
ns.On("PLAYERBANKSLOTS_CHANGED", BankChanged)                               -- RETEST
ns.On("PLAYERREAGENTBANKSLOTS_CHANGED", BankChanged)                        -- RETEST
ns.On("BANK_TABS_CHANGED", BankChanged)                                     -- RETEST

ns.On("PLAYER_EQUIPMENT_CHANGED", function() Scan:Request("equipped", 0.3) end)
ns.On("PLAYER_MONEY", function()
    moneyTrusted = true
    Scan:Request("money", 0.5)
end)
ns.On("PLAYER_LEVEL_UP", function()
    C_Timer.After(1, function() Scan:RefreshMe(); Scan:Changed() end)
end)
ns.On("PLAYER_GUILD_UPDATE", function()
    Scan:RefreshGuild(true)
    if WH.RequestUIRefresh then WH:RequestUIRefresh(0.5) end
end)

ns.On("BANKFRAME_OPENED", function() Scan:Opened("bank") end)               -- RETEST
ns.On("BANKFRAME_CLOSED", function() Scan:Closed("bank") end)
ns.On("GUILDBANKFRAME_OPENED", function() Scan:Opened("guild") end)         -- RETEST
ns.On("GUILDBANKFRAME_CLOSED", function() Scan:Closed("guild") end)
ns.On("MAIL_SHOW", function() Scan:Opened("mail") end)                      -- RETEST
ns.On("MAIL_CLOSED", function() Scan:Closed("mail") end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)               -- RETEST
    local what = INTERACTION[Num(kind) or -1]
    if what then Scan:Opened(what) end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    local what = INTERACTION[Num(kind) or -1]
    if what then Scan:Closed(what) end
end)

ns.On("GUILDBANKBAGSLOTS_CHANGED", function() Scan:OnGuildBankSlotsChanged() end)   -- RETEST
ns.On("GUILDBANK_UPDATE_MONEY", function() Scan:ScanGuildMoney() end)
ns.On("MAIL_INBOX_UPDATE", function() if Scan.open.mail then Scan:Request("mail", 0.3) end end)
ns.On("MAIL_SEND_INFO_UPDATE", function() Scan.outbox = ReadOutbox() end)
ns.On("MAIL_SEND_SUCCESS", function() Scan:CommitSent() end)
ns.On("MAIL_FAILED", function() Scan.sending = nil end)
ns.On("ITEM_DATA_LOAD_RESULT", OnItemLoaded)                                -- RETEST

-- Only the time: the game reports 0 gold (and may report other defaults)
-- while it logs out, so nothing else is read here.
ns.On("PLAYER_LOGOUT", function()
    local c = Scan.me
    if c then c.lastSeen = time() end
end)
