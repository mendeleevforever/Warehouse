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
-- Records:
--   realms[realm key]         = { name, server, region, ruleset, guessed, unknown }
--   chars[region/full name]   = { name, realm, realmKey, region, area, ruleset, faction,
--                                 class, level, money, lastSeen, guild,
--                                 bags = { items = {[key] = count}, used, slots, t },
--                                 bank = { same }, equipped = { items, t },
--                                 mail = { list = { {k, c, x, f, cod, ret, sent} }, money, count, more, t } }
--   guilds[realm key/guild]   = { name, realm, realmKey, region, area, ruleset, faction, money, numTabs, t,
--                                  tabs = { [tab] = { name, icon, items, used, t } } }
-- Identity on Forever: characters have a first name and a surname, unique
-- per region, so a character is keyed by region and full name. Since the
-- 1.60.1.71037 hotfix the client hides realm names (GetRealmName() returns
-- ""), so a realm is known by the server number in the player's GUID
-- ("Player-<server>-<id>") when there's no name. The ruleset is read from
-- the game's own rules (C_GameRules) at each login and kept on the
-- character; characters on the same server share it until they log in
-- themselves. Where the game can't say, the player sets it once.
-- WarehouseCharDB (per character) remembers the key in case a later build
-- hides the name too.
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

function Scan.RepairChar(c, db)
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
    c.area, c.areaGuessed = ns.AreaFor(c.region), nil      -- always the client's region (an old "OCE" becomes US)
    if not ns.FACTIONS[c.faction or ""] then c.faction = nil end
    c.money, c.level, c.lastSeen = Num(c.money), Num(c.level), Num(c.lastSeen) or 0
    if type(c.class) ~= "string" then c.class = nil end
    if type(c.guild) ~= "string" then c.guild = nil end
    if type(c.realm) ~= "string" then c.realm = "" end
    if type(c.realmKey) ~= "string" then c.realmKey = c.region .. "/" .. (c.realm ~= "" and c.realm or "?") end
    if not ns.RULESETS[c.ruleset or ""] then
        local r = db and db.realms[c.realmKey]        -- 0.1.0 kept the ruleset on the realm only
        if r and ns.RULESETS[r.ruleset or ""] then
            c.ruleset, c.rulesetGuessed = r.ruleset, r.guessed or nil
        else
            c.ruleset = ""
        end
    end
end

function Scan.RepairGuild(g, db)
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
    if type(g.realm) ~= "string" then g.realm = "" end
    if type(g.region) ~= "string" then g.region = "??" end
    if type(g.realmKey) ~= "string" then g.realmKey = g.region .. "/" .. (g.realm ~= "" and g.realm or "?") end
    if not ns.RULESETS[g.ruleset or ""] then
        local r = db and db.realms[g.realmKey]
        g.ruleset = (r and ns.RULESETS[r.ruleset or ""]) and r.ruleset or ""
    end
    g.area = ns.AreaFor(g.region)
    if not ns.FACTIONS[g.faction or ""] then g.faction = nil end
end

-------------------------------------------------------------------------------
-- Region, Oceanic guess, ruleset guess
-------------------------------------------------------------------------------
local REGION_BY_ID = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

function Scan:ClientRegion()
    local name = GetCurrentRegionName and Text((ns.SafeCall(GetCurrentRegionName)))   -- RETEST
    if name then return name:upper() end
    local id = GetCurrentRegion and Num((ns.SafeCall(GetCurrentRegion)))              -- RETEST
    return (id and REGION_BY_ID[id]) or "??"
end

-- Forever has one realm per ruleset per region; if the realm's name says
-- which ruleset it is, use that. Otherwise the player sets it once.
local function GuessRuleset(realmName)
    local r = realmName:lower()
    local rp = r:find("roleplay", 1, true) or r:find("%f[%a]rp%f[%A]")
    if r:find("pvp", 1, true) then return rp and "rppvp" or "pvp" end
    if r:find("hardcore", 1, true) then return "hardcore" end
    if rp then return "rp" end
    if r:find("normal", 1, true) or r:find("pve", 1, true) then return "normal" end
    return nil
end
Scan.GuessRuleset = GuessRuleset

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
    return rs and rs.label or "ruleset not set"
end

-- The realm's name, when the client ever gave one (Forever hides it now)
function ns.RealmName(rec)
    if rec.realm and rec.realm ~= "" then return rec.realm end
    local r = WH.db and rec.realmKey and WH.db.realms[rec.realmKey]
    if r and r.name and r.name ~= "" then return r.name end
    return nil
end

-- "Normal  •  Oceanic", or with a realm name "Realm 10  •  Roleplay  •  EU"
function ns.PlaceText(rec, withArea)
    local parts = {}
    local realm = ns.RealmName(rec)
    if realm then parts[#parts + 1] = realm end
    parts[#parts + 1] = ns.RulesetLabel(rec)
    if withArea then parts[#parts + 1] = ns.AREAS[rec.area] or rec.region or "?" end
    return table.concat(parts, "  •  ")
end

-- Coloured owner name: a character in its class colour, a guild bank as <Guild>
function ns.OwnerLabel(kind, rec)
    if kind == "guild" then return ("%s<%s>|r"):format(ns.GUILD_HEX, rec.name) end
    return ns.ClassHex(rec.class) .. rec.name .. "|r"
end

-------------------------------------------------------------------------------
-- The character being played
-------------------------------------------------------------------------------
function Scan:CurrentGuildKey()
    local me = self.me
    if not me or not GetGuildInfo then return nil end
    local gname = Text((ns.SafeCall(GetGuildInfo, "player")))      -- RETEST; guarded: guild names are unit data
    if not gname then return nil end
    return me.realmKey .. "/" .. gname, gname
end

function Scan:RefreshGuild(clearIfNone)
    local c = self.me
    if not c then return end
    local key = self:CurrentGuildKey()
    if key then
        c.guild = key
        local g = WH.db.guilds[key]
        if g then self:TouchGuild(g) end
    elseif clearIfNone and IsInGuild then
        if Bool(IsInGuild()) == false then c.guild = nil end   -- only a real "no", never a secret or a not-loaded answer
    end
end

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

-- The player's full name. Forever characters have a first name and a
-- surname: UnitName("player") returns them as its two values, and Blizzard's
-- own Forever UI joins them with a space. Names are unique per region.
function Scan.PlayerName()
    local first, second = UnitName("player")
    first, second = Text(first), Text(second)                   -- guarded: names can be secret values
    if first and second and not first:find(second, 1, true) then return first .. " " .. second end
    if first then return first end
    return GetUnitName and Text((ns.SafeCall(GetUnitName, "player", true))) or nil
end

-- The realm's name (nil when hidden) and the server number from the player's GUID
function Scan.PlayerRealm()
    local name = GetRealmName and Text((ns.SafeCall(GetRealmName)))           -- RETEST: "" since 1.60.1.71037
    local guid = UnitGUID and Text((ns.SafeCall(UnitGUID, "player")))         -- RETEST
    local server = guid and guid:match("^Player%-(%d+)%-") or nil
    return name, server
end

-- The ruleset from the game's own rules: Hardcore; RP and PvP together are
-- Roleplay PvP; RP; PvP; none of them is Normal. Returns the ruleset (nil
-- when the client can't say: no API, an error or a secret answer) and a
-- description of what each rule answered, for the probe.
local RULES = { { "hc", "HardcoreRuleset", "Hardcore" }, { "rp", "RPRuleset", "RP" }, { "pvp", "PvPRuleset", "PvP" } }

function Scan.DetectRuleset()
    local api = C_GameRules and C_GameRules.IsGameRuleActive               -- RETEST
    local enum = Enum and Enum.GameRule                                    -- RETEST: PvPRuleset 213, RPRuleset 214, HardcoreRuleset 10 on 71037
    if type(api) ~= "function" or type(enum) ~= "table" then return nil, "C_GameRules.IsGameRuleActive not found" end
    local on, words = {}, {}
    for _, r in ipairs(RULES) do
        local id = enum[r[2]]
        local value, word
        if type(id) ~= "number" then
            value, word = false, "missing"                -- this client has no such rule, so it isn't on
        else
            local ok, v = pcall(api, id)
            if not ok then
                word = "error"
            elseif ns.IsSecret(v) then
                word = "secret"
            else
                value = Bool(v)
                word = value == nil and "unclear" or (value and "on" or "off")
            end
        end
        on[r[1]] = value
        words[#words + 1] = r[3] .. " " .. word
    end
    local detail = table.concat(words, ", ")
    if on.hc then return "hardcore", detail end
    if on.hc == nil or on.rp == nil or on.pvp == nil then return nil, detail end
    if on.rp and on.pvp then return "rppvp", detail end
    if on.rp then return "rp", detail end
    if on.pvp then return "pvp", detail end
    return "normal", detail
end

-- The game said which ruleset this character is on: it wins over a choice
-- or a guess, and characters on the same server that haven't told Warehouse
-- themselves get it too. Returns true when anything changed.
function Scan:ApplyDetectedRuleset(key, ruleset)
    local db = WH.db
    local c = db.chars[key]
    if not c then return false end
    local changed = c.ruleset ~= ruleset or not c.rulesetDetected
    c.ruleset, c.rulesetDetected, c.rulesetGuessed = ruleset, true, nil
    local r = db.realms[c.realmKey]
    if r and not r.unknown then
        r.ruleset, r.guessed, r.detected = ruleset, false, true
        for _, o in pairs(db.chars) do
            if o.realmKey == c.realmKey and not o.rulesetDetected and o.ruleset ~= ruleset then
                o.ruleset, o.rulesetGuessed = ruleset, nil
                changed = true
            end
        end
        for _, g in pairs(db.guilds) do
            if g.realmKey == c.realmKey then g.ruleset = ruleset end
        end
    end
    local g = c.guild and db.guilds[c.guild]
    if g then g.ruleset = ruleset end
    return changed
end

-- Reads the ruleset for the character being played; tells the player when
-- the game disagrees with what they had set
function Scan:ReadRuleset()
    local c, key = self.me, self.meKey
    if not c then return false end
    local ruleset = Scan.DetectRuleset()
    if not ruleset then return false end
    local before, wasDetected = c.ruleset, c.rulesetDetected
    local changed = self:ApplyDetectedRuleset(key, ruleset)
    if before ~= "" and before ~= ruleset and not wasDetected then
        ns.Print(("the game says %s is on %s, not %s; Warehouse uses that from now on."):format(
            c.name, ns.RULESETS[ruleset].label, ns.RulesetLabel({ ruleset = before })))
    end
    self.rulesetRead = true
    return changed
end

local askedRuleset = {}

function Scan:AskRuleset()
    local c, key = self.me, self.meKey
    if not c or c.ruleset ~= "" or askedRuleset[key] then return end
    askedRuleset[key] = true
    ns.Print(("which ruleset is %s on? The game didn't say this time. Type |cffffd100/warehouse ruleset normal|r, pvp, rp, rppvp or hardcore, or right-click them on the Characters tab."):format(c.name))
end

function Scan:Identify()
    local db = WH.db
    local region = self:ClientRegion()
    local remembered = WH.charDB and WH.charDB.key
    local name = Scan.PlayerName()
    if not name then
        -- the client hides the name for now: use the record this character had last time
        local old = remembered and db.chars[remembered]
        if not old then return false end
        name = old.name
    end
    local key = region .. "/" .. name

    -- carry over a record saved under another key (Warehouse 0.1.0, or a renamed character)
    if not db.chars[key] then
        local old = (remembered and remembered ~= key and db.chars[remembered]) and remembered or nil
        if not old then
            for k, c in pairs(db.chars) do
                if k ~= key and c.region == region and c.name == name then old = k break end
            end
        end
        if old then
            db.chars[key], db.chars[old] = db.chars[old], nil
            if db.settings.pick == old then db.settings.pick = key end
        end
    end

    local realmName, server = Scan.PlayerRealm()
    local realmKey = region .. "/" .. (server and ("#" .. server) or realmName or "?")
    local realm = db.realms[realmKey]
    if not realm then
        realm = { name = realmName or "", server = server, region = region, ruleset = "", guessed = false, unknown = (not server and not realmName) or nil }
        db.realms[realmKey] = realm
    end
    if realmName and realm.name ~= realmName then realm.name = realmName end
    if realm.ruleset == "" and realmName then
        local guess = GuessRuleset(realmName)
        if guess then realm.ruleset, realm.guessed = guess, true end
    end

    local c = db.chars[key]
    local isNew = c == nil
    if isNew then
        c = { name = name, region = region }
        db.chars[key] = c
    end
    c.name, c.region, c.realmKey = name, region, realmKey
    if realmName then c.realm = realmName end
    Scan.RepairChar(c, db)
    if c.ruleset == "" and realm.ruleset ~= "" then c.ruleset, c.rulesetGuessed = realm.ruleset, realm.guessed end
    self.me, self.meKey, self.realmKey = c, key, realmKey
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
        if not Scan.rulesetRead then Scan:AskRuleset() end
    end)
    self:Changed()
end

function Scan:OnLogin()
    self:HookSendMail()
    if self:Identify() then
        self:AfterIdentify()
        return
    end
    -- the name can be missing (or secret) for a moment at login; try again shortly
    local tries, ticker = 0, nil
    ticker = C_Timer.NewTicker(2, function()
        tries = tries + 1
        if Scan:Identify() then
            ticker:Cancel()
            Scan:AfterIdentify()
        elseif tries >= 15 then
            ticker:Cancel()
            ns.Print("the game is hiding this character's name from addons, so nothing is saved this session. Type /reload to try again; if it keeps happening, type /warehouse probe and include the Name line when you report it.")
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
    local get = (C_Item and C_Item.GetItemInfoInstant) or rawget(_G, "GetItemInfoInstant")   -- RETEST
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

-- One of your characters with that name in this region (names are unique
-- per region on Forever), on the same realm first
function Scan:FindAlt(recipient)
    local me = self.me
    local name = ns.Trim(recipient:match("^(.-)%-.+$") or recipient)
    local lname = name:lower()
    local fallback, fallbackKey
    for key, c in pairs(WH.db.chars) do
        if c.region == me.region and (c.name == name or c.name:lower() == lname) then
            if c.realmKey == me.realmKey then return c, key end
            if not fallback then fallback, fallbackKey = c, key end
        end
    end
    return fallback, fallbackKey
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

-- A guild bank takes its region, ruleset and faction from your character
function Scan:TouchGuild(g)
    local me = self.me
    g.area, g.faction = me.area, me.faction or g.faction
    g.realm, g.realmKey = me.realm, me.realmKey
    if me.ruleset ~= "" then g.ruleset = me.ruleset end
end

function Scan:GuildRecord(create)
    local key, gname = self:CurrentGuildKey()
    if not key then return nil end
    local g = WH.db.guilds[key]
    if not g and create then
        g = { name = gname, region = self.me.region, tabs = {}, t = 0 }
        WH.db.guilds[key] = g
    end
    if g then
        Scan.RepairGuild(g, WH.db)
        self:TouchGuild(g)
        self.me.guild = key
    end
    return g, key
end

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
local RULE_WORDS = { normal = "normal", pve = "normal", pvp = "pvp", rp = "rp", roleplay = "rp",
                     rppvp = "rppvp", ["rp-pvp"] = "rppvp", hardcore = "hardcore", hc = "hardcore" }

-- Sets the ruleset of every character (and guild bank) on a realm. A realm
-- known only as "?" (no name and no server number) can't be shared.
function Scan:SetRealmRuleset(realmKey, ruleset)
    local db = WH.db
    local r = db.realms[realmKey]
    if not r or r.unknown or r.detected or not (ruleset == "" or ns.RULESETS[ruleset]) then return end
    r.ruleset, r.guessed = ruleset, false
    for _, c in pairs(db.chars) do
        if c.realmKey == realmKey and not c.rulesetDetected then c.ruleset, c.rulesetGuessed = ruleset, false end
    end
    for _, g in pairs(db.guilds) do
        if g.realmKey == realmKey then g.ruleset = ruleset end
    end
    self:Changed()
end

function Scan:SetCharRuleset(key, ruleset)
    local db = WH.db
    local c = db.chars[key]
    if not c or c.rulesetDetected or not (ruleset == "" or ns.RULESETS[ruleset]) then return end
    local r = db.realms[c.realmKey]
    if r and not r.unknown and not r.detected then
        self:SetRealmRuleset(c.realmKey, ruleset)
        return
    end
    c.ruleset, c.rulesetGuessed = ruleset, false
    local g = c.guild and db.guilds[c.guild]
    if g then g.ruleset = ruleset end
    self:Changed()
end

-- Same region and ruleset as the character you're playing (on Forever that's
-- the same realm); the same realm key when either ruleset isn't set
function Scan:SameWorld(rec)
    local me = self.me
    if not me or rec.region ~= me.region then return false end
    if me.ruleset ~= "" and (rec.ruleset or "") ~= "" then return rec.ruleset == me.ruleset end
    return rec.realmKey == me.realmKey
end

function Scan:SetMyRuleset(word)
    local me = self.me
    if not me then ns.Print("this character isn't identified yet.") return end
    if me.rulesetDetected then
        ns.Print(("the game says %s is on %s, so Warehouse uses that."):format(me.name, ns.RulesetLabel(me)))
        return
    end
    local rs = RULE_WORDS[(word or ""):lower()]
    if not rs then
        ns.Print(("%s's ruleset is %s. Use /warehouse ruleset normal, pvp, rp, rppvp or hardcore."):format(me.name, ns.RulesetLabel(me)))
        return
    end
    self:SetCharRuleset(self.meKey, rs)
    ns.Print(("%s is now marked %s (%s)."):format(me.name, ns.RULESETS[rs].label, ns.RULE_GROUPS[ns.RULESETS[rs].group]))
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

function Scan:RealmOf(rec)
    return rec.realmKey and WH.db.realms[rec.realmKey] or nil
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
