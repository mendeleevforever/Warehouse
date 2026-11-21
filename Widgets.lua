local addonName, ns = ...
-- Widgets.lua
-- The building blocks of the Warehouse window, in the same palette and style
-- as MendeLedger: dark window, layered gold trim, a title plate on the top
-- edge, flat gold-edged buttons, dark field boxes, striped rows, and one
-- drop-down menu shared by the Filter button and the filter selectors.
-- None of these frames are protected.

local WH = ns.WH
local UI = {}
ns.UI = UI

-------------------------------------------------------------------------------
-- Palette
-------------------------------------------------------------------------------
local C = {
    bg        = { 0.118, 0.082, 0.051 },
    gold      = { 0.541, 0.416, 0.173 },
    goldLight = { 0.722, 0.569, 0.235 },
    outline   = { 0.169, 0.118, 0.055 },
    inner     = { 0.290, 0.212, 0.094 },
    rule      = { 0.420, 0.314, 0.137 },
    header    = { 0.831, 0.627, 0.090 },
    text      = { 0.902, 0.839, 0.682 },
    muted     = { 0.612, 0.553, 0.439 },
    legend    = { 0.720, 0.650, 0.520 },
    plate     = { 0.165, 0.114, 0.063 },
    field     = { 0.071, 0.047, 0.027 },
    stripe    = { 0.353, 0.263, 0.125 },
    up        = { 0.25, 1.00, 0.25 },
    down      = { 1.00, 0.38, 0.25 },
    warn      = { 1.00, 0.60, 0.20 },
}
UI.C = C
UI.DOT = "   |cff7d705a•|r   "
UI.GREY = "|cff9d9d9d"

-- One colour per location, used by the bars, the chart and the legend
UI.LOC_RGB = {
    bags     = { 0.831, 0.627, 0.090 },
    bank     = { 0.860, 0.360, 0.120 },
    guild    = { 0.300, 0.720, 0.300 },
    mail     = { 0.320, 0.560, 0.920 },
    equipped = { 0.640, 0.420, 0.920 },
}

local QUALITY = {
    [0] = { 0.62, 0.62, 0.62 }, { 1, 1, 1 }, { 0.12, 1, 0 }, { 0, 0.44, 0.87 },
    { 0.64, 0.21, 0.93 }, { 1, 0.5, 0 }, { 0.9, 0.8, 0.5 }, { 0, 0.8, 1 },
}
local QUALITY_NAMES = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }

function UI.QualityRGB(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]          -- RETEST
    if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
    return QUALITY[q or 1] or QUALITY[1]
end

function UI.QualityName(q)
    return ns.Text(rawget(_G, ("ITEM_QUALITY%d_DESC"):format(q or 1))) or QUALITY_NAMES[q or 1] or "Common"
end

function UI.SetColor(obj, rgb, a) obj:SetTextColor(rgb[1], rgb[2], rgb[3], a or 1) end
function UI.Hex(rgb) return ("|cff%02x%02x%02x"):format(rgb[1] * 255, rgb[2] * 255, rgb[3] * 255) end
local SetColor = UI.SetColor

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------
function UI.AddBorder(frame, layer, rgb, alpha, thickness, inset)
    local function edge()
        local t = frame:CreateTexture(nil, layer)
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", -inset, -inset)
    top:SetHeight(thickness)
    bottom:SetPoint("BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", inset, inset)
    left:SetWidth(thickness)
    right:SetPoint("TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", -inset, inset)
    right:SetWidth(thickness)
    return { top, bottom, left, right }
end
local AddBorder = UI.AddBorder

function UI.SetEdgeColor(edges, rgb, a)
    for _, t in ipairs(edges) do t:SetColorTexture(rgb[1], rgb[2], rgb[3], a or 1) end
end

function UI.SetEdgesShown(edges, shown)
    for _, t in ipairs(edges) do t:SetShown(shown) end
end

function UI.SavePosition(f, posKey)
    local p, _, rp, x, y = f:GetPoint()
    if p and WH.db then WH.db.positions[posKey] = { p, rp, x, y } end
end

function UI.PlaceFrame(f, posKey)
    local pos = WH.db and WH.db.positions[posKey]
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", -20, 20)
    end
end

function UI.MakeWindow(globalName, w, h, posKey)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); UI.SavePosition(self, posKey) end)
    UI.PlaceFrame(f, posKey)
    f:Hide()
    tinsert(UISpecialFrames, globalName)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.97)
    bg:SetAllPoints()
    AddBorder(f, "BORDER",  C.outline, 1, 2, -2)
    AddBorder(f, "BORDER",  C.gold,    1, 3,  0)
    AddBorder(f, "ARTWORK", C.inner,   1, 1,  3)

    local plate = CreateFrame("Frame", nil, f)
    plate:SetSize(300, 34)
    plate:SetPoint("TOP", 0, 18)
    plate:SetFrameLevel(f:GetFrameLevel() + 5)
    plate:EnableMouse(true)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnDragStart", function() f:StartMoving() end)
    plate:SetScript("OnDragStop", function() f:StopMovingOrSizing(); UI.SavePosition(f, posKey) end)
    local pbg = plate:CreateTexture(nil, "BACKGROUND")
    pbg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    pbg:SetAllPoints()
    AddBorder(plate, "BORDER", C.outline,   1, 2, -2)
    AddBorder(plate, "BORDER", C.goldLight, 1, 2,  0)
    local title = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 0)
    title:SetTextColor(1, 0.82, 0)
    if title.SetWordWrap then title:SetWordWrap(false) end
    f.plate, f.title = plate, title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")    -- RETEST
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.info:SetPoint("TOP", 0, -24)
    f.info:SetWidth(w - 160)
    if f.info.SetWordWrap then f.info:SetWordWrap(false) end
    SetColor(f.info, C.legend)
    return f
end

function UI.SetWindowTitle(f, text)
    f.title:SetText(text)
    f.plate:SetWidth(math.max(260, f.title:GetStringWidth() + 60))
end

function UI.AddFooterRule(f, y)
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    rule:SetPoint("BOTTOMLEFT", 20, y)
    rule:SetPoint("BOTTOMRIGHT", -20, y)
    rule:SetHeight(1)
    return rule
end

function UI.AddSection(parent, text, y, x1, x2)
    x1, x2 = x1 or 20, x2 or -20
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x1 + 2, y)
    fs:SetJustifyH("LEFT")
    SetColor(fs, C.header)
    fs:SetText(text)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", x1, y - 16)
    rule:SetPoint("TOPRIGHT", x2, y - 16)
    return fs, rule
end

function UI.AddLabel(parent, text, font, rgb)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    SetColor(fs, rgb or C.text)
    fs:SetText(text or "")
    return fs
end

function UI.NoWrap(fs)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

function UI.AddFieldBox(parent, left, top, right, bottom)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetColorTexture(C.field[1], C.field[2], C.field[3], 0.9)
    t:SetPoint("TOPLEFT", left, top)
    t:SetPoint("BOTTOMRIGHT", right, bottom)
    local function Edge(p1, p2, w, h)
        local e = parent:CreateTexture(nil, "BORDER")
        e:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
        e:SetPoint(p1, t, p1)
        e:SetPoint(p2, t, p2)
        if w then e:SetWidth(w) end
        if h then e:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return t
end

function UI.AddPlaceholder(eb, text)
    local ph = eb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ph:SetPoint("LEFT", 22, 0)
    SetColor(ph, C.muted)
    ph:SetText(text)
    local function Update()
        if eb:GetText() == "" and not eb:HasFocus() then ph:Show() else ph:Hide() end
    end
    eb:HookScript("OnTextChanged", Update)
    eb:HookScript("OnEditFocusGained", Update)
    eb:HookScript("OnEditFocusLost", Update)
    Update()
    return ph
end

-- Search box with a magnifying glass
function UI.MakeSearchBox(globalName, parent, w)
    local eb = CreateFrame("EditBox", globalName, parent)
    eb:SetSize(w, 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    eb:SetTextInsets(20, 18, 0, 0)
    eb:SetMaxLetters(60)
    SetColor(eb, C.text)
    local bg = eb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.02, 0.01, 0.95)
    local edges = AddBorder(eb, "BORDER", C.rule, 1, 1, 0)
    local glass = eb:CreateTexture(nil, "OVERLAY")
    glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    glass:SetSize(14, 14)
    glass:SetPoint("LEFT", 4, -1)
    glass:SetVertexColor(C.muted[1], C.muted[2], C.muted[3])
    local clear = CreateFrame("Button", nil, eb)
    clear:SetSize(14, 14)
    clear:SetPoint("RIGHT", -3, 0)
    local x = clear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    x:SetPoint("CENTER")
    x:SetText("x")
    SetColor(x, C.muted)
    clear:SetScript("OnClick", function() eb:SetText(""); eb:ClearFocus() end)
    clear:Hide()
    eb:HookScript("OnTextChanged", function(self) clear:SetShown(self:GetText() ~= "") end)
    eb:HookScript("OnEditFocusGained", function() UI.SetEdgeColor(edges, C.goldLight); glass:SetVertexColor(1, 0.82, 0) end)
    eb:HookScript("OnEditFocusLost", function() UI.SetEdgeColor(edges, C.rule); glass:SetVertexColor(C.muted[1], C.muted[2], C.muted[3]) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

function UI.FlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 18)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    b.edges = AddBorder(b, "BORDER", C.gold, 1, 1, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.25)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", 0, 0)
    fs:SetWidth(w - 6)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    SetColor(fs, C.header)
    fs:SetText(text)
    b.label = fs
    b:SetScript("OnMouseDown", function() fs:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    return b
end

function UI.SetFlatSelected(b, selected)
    local c = selected and C.stripe or C.plate
    b.bg:SetColorTexture(c[1], c[2], c[3], 1)
    UI.SetEdgeColor(b.edges, selected and { 1, 0.82, 0.25 } or C.gold)
    SetColor(b.label, selected and { 1, 1, 1 } or C.header)
end

function UI.MenuButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")   -- RETEST
    b:SetSize(w or 110, 26)
    b:SetText(text)
    return b
end

function UI.AddHoverTip(widget, title, body)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(type(title) == "function" and title() or title, 1, 0.82, 0)
        local b = type(body) == "function" and body() or body
        if b then GameTooltip:AddLine(b, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.MakeCheck(parent, x, y, text, tipTitle, tipBody, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")   -- RETEST
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local label = UI.AddLabel(cb, text, "GameFontNormal", C.text)
    label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    if tipTitle then UI.AddHoverTip(cb, tipTitle, tipBody) end
    return cb
end

function UI.MakeScroll(globalName, parent, childWidth)
    local scroll = CreateFrame("ScrollFrame", globalName, parent, "UIPanelScrollFrameTemplate")   -- RETEST
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(childWidth, 10)
    scroll:SetScrollChild(child)
    return scroll, child
end

-- A scrolling list that only creates frames for the rows on screen, so a
-- list of 5,000 items costs the same as a list of 20. Redraws on scroll
-- events (OnVerticalScroll covers the wheel, the scroll bar and SetVerticalScroll).
--   makeRow(i): create pooled row i      fill(row, item, index): show one item
function UI.AttachVirtualList(scroll, child, rowH, makeRow, fill)
    local list = { data = {}, rows = {} }
    function list:Render()
        local offset = scroll:GetVerticalScroll() or 0
        local first = math.floor(offset / rowH) + 1
        local visible = math.ceil((scroll:GetHeight() or 200) / rowH) + 1
        for i = 1, visible do
            local idx = first + i - 1
            local item = self.data[idx]
            local row = self.rows[i]
            if item and not row then row = makeRow(i); self.rows[i] = row end
            if row then
                if item then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(idx - 1) * rowH)
                    fill(row, item, idx)
                    row:Show()
                else
                    row:Hide()
                    row.item = nil
                end
            end
        end
        for i = visible + 1, #self.rows do self.rows[i]:Hide(); self.rows[i].item = nil end
    end
    function list:SetData(data, resetScroll)
        self.data = data
        child:SetHeight(math.max(10, #data * rowH))
        if resetScroll then scroll:SetVerticalScroll(0) end
        self:Render()
    end
    scroll:HookScript("OnVerticalScroll", function() list:Render() end)
    scroll:HookScript("OnSizeChanged", function() list:Render() end)
    return list
end

function UI.StripeRow(row, idx)
    if not row.stripe then
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
    end
    row.stripe:SetColorTexture(C.stripe[1], C.stripe[2], C.stripe[3], (idx % 2 == 0) and 0.18 or 0.06)
end

-- A thin bar split into one coloured segment per location
function UI.MakeLocationBar(parent, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.02, 0.01, 0.95)
    AddBorder(bar, "OVERLAY", C.rule, 1, 1, -1)
    bar.segs = {}
    for _, loc in ipairs(ns.LOCATIONS) do
        local t = bar:CreateTexture(nil, "ARTWORK")
        local rgb = UI.LOC_RGB[loc]
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], 0.85)
        t:SetPoint("TOP", 0, 0)
        t:SetPoint("BOTTOM", 0, 0)
        t:Hide()
        bar.segs[loc] = t
    end
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", 0, 0)
    bar.text:SetShadowOffset(1, -1)
    return bar
end

-- counts: { [loc] = n }; scale: the number that fills the whole bar (default: their sum)
function UI.SetLocationBar(bar, counts, scale, width)
    local sum = 0
    for _, loc in ipairs(ns.LOCATIONS) do sum = sum + ((counts and counts[loc]) or 0) end
    scale = scale or sum
    width = width or bar:GetWidth() or 0
    local x = 0
    for _, loc in ipairs(ns.LOCATIONS) do
        local t = bar.segs[loc]
        local n = (counts and counts[loc]) or 0
        if n > 0 and scale > 0 and width > 0 then
            local w = math.max(1, math.floor(width * n / scale + 0.5))
            if x + w > width then w = width - x end
            if w > 0 then
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
                t:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
                t:SetWidth(w)
                t:Show()
                x = x + w
            else
                t:Hide()
            end
        else
            t:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- One drop-down menu for the whole addon. build() returns its items, and is
-- called again after every click so checks and labels stay current:
--   { label = "Heading" }
--   { separator = true }
--   { text = "...", checked = true|false|nil, onClick = fn, close = true|nil, tip = "..." }
-- Items with checked == nil are actions and close the menu.
-------------------------------------------------------------------------------
local menu

local function MenuRow(l, i)
    local b = l.buttons[i]
    if b then return b end
    b = CreateFrame("Button", nil, l)
    b:SetHeight(20)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.22)
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.check:SetSize(16, 16)
    b.check:SetPoint("LEFT", 4, 0)
    b.box = b:CreateTexture(nil, "ARTWORK")
    b.box:SetSize(12, 12)
    b.box:SetPoint("CENTER", b.check, "CENTER", 0, 0)
    b.box:SetColorTexture(C.field[1], C.field[2], C.field[3], 1)
    b.text = UI.NoWrap(b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    b.text:SetPoint("LEFT", 24, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetJustifyH("LEFT")
    b:SetScript("OnClick", function(self)
        local it = self.item
        if not it then return end
        if it.checked == nil or it.close then l:Hide() end
        if it.onClick then it.onClick() end
        if l:IsShown() then UI.LayoutMenu() end
        if l.after then l.after() end
    end)
    b:SetScript("OnEnter", function(self)
        if self.item and self.item.tip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.item.text, 1, 0.82, 0)
            GameTooltip:AddLine(self.item.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    l.buttons[i] = b
    return b
end

local function GetMenu()
    if menu then return menu end
    local l = CreateFrame("Frame", "WarehouseMenu", UIParent)
    l:SetFrameStrata("FULLSCREEN_DIALOG")
    l:SetClampedToScreen(true)
    l:EnableMouse(true)
    l:Hide()
    local bg = l:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.98)
    AddBorder(l, "BORDER", C.outline, 1, 2, -2)
    AddBorder(l, "BORDER", C.gold, 1, 1, 0)

    -- clicking anywhere else closes the menu
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:Hide()
    catcher:SetScript("OnClick", function() l:Hide() end)
    l:SetScript("OnShow", function() catcher:Show() end)
    l:SetScript("OnHide", function() catcher:Hide(); GameTooltip:Hide() end)
    tinsert(UISpecialFrames, "WarehouseMenu")

    l.buttons, l.labels, l.seps = {}, {}, {}
    menu = l
    return l
end

function UI.LayoutMenu()
    local l = menu
    if not l or not l.build then return end
    local items = l.build()
    local w = l.width
    local y, nb, nl, ns_ = -6, 0, 0, 0
    for _, it in ipairs(items) do
        if it.separator then
            ns_ = ns_ + 1
            local sep = l.seps[ns_]
            if not sep then
                sep = l:CreateTexture(nil, "ARTWORK")
                sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
                sep:SetHeight(1)
                l.seps[ns_] = sep
            end
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", 8, y - 4)
            sep:SetPoint("TOPRIGHT", -8, y - 4)
            sep:Show()
            y = y - 9
        elseif it.label then
            nl = nl + 1
            local fs = l.labels[nl]
            if not fs then
                fs = UI.NoWrap(UI.AddLabel(l, "", "GameFontNormalSmall", C.header))
                l.labels[nl] = fs
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", 10, y - 4)
            fs:SetWidth(w - 20)
            SetColor(fs, it.muted and C.muted or C.header)
            fs:SetText(it.label)
            fs:Show()
            y = y - 18
        else
            nb = nb + 1
            local b = MenuRow(l, nb)
            b.item = it
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 4, y)
            b:SetWidth(w - 8)
            b.text:SetText(it.text)
            SetColor(b.text, C.text)
            if it.checked == nil then
                b.box:Hide()
                b.check:Hide()
            else
                b.box:Show()
                b.check:SetShown(it.checked and true or false)
            end
            b:Show()
            y = y - 20
        end
    end
    for i = nb + 1, #l.buttons do l.buttons[i]:Hide(); l.buttons[i].item = nil end
    for i = nl + 1, #l.labels do l.labels[i]:Hide() end
    for i = ns_ + 1, #l.seps do l.seps[i]:Hide() end
    l:SetSize(w, -y + 6)
end

-- Shows the menu under anchor (or hides it if it's already open there).
-- after() runs after each click, to refresh whatever the menu changed.
function UI.ShowMenu(anchor, build, width, after)
    local l = GetMenu()
    if l:IsShown() and l.anchor == anchor then l:Hide() return end
    l.anchor, l.build, l.width, l.after = anchor, build, width or 240, after
    UI.LayoutMenu()
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    l:Show()
    l:Raise()
end

function UI.HideMenu()
    if menu then menu:Hide() end
end
