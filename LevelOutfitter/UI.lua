-- UI.lua: the window. It shows what Shop.lua worked out and passes clicks on; it decides nothing about gold.
-- The only thing here that spends gold is a click on a row's Buy button: one click, one Shop.Buy, one piece.
local ADDON, ns = ...
local UI = {}
ns.UI = UI

local Shop, Scan, Scroll = ns.Shop, ns.Scan, ns.Scroll
local floor, max, min, sqrt, tonumber, type, ipairs, pcall = math.floor, math.max, math.min, math.sqrt, tonumber, type,
    ipairs, pcall

local W, H, PAD, ROWS, ROW_H = 640, 548, 12, 15, 22
local LIST_TOP = -136              -- where the first row starts, from the top of the window
local STEPS = 1000                 -- slider positions; the gold grows with the square, so small amounts are easy to hit
local MESSAGE_FOR = 10             -- seconds a status message stays before the standing hint returns
local GOLD, DIM, GOOD, BAD = { 1, 0.82, 0 }, { 0.6, 0.6, 0.62 }, { 0.3, 1, 0.3 }, { 1, 0.35, 0.3 }
local QUALITY = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 } }
-- what a Buy button says while it cannot be clicked, per row state
local LABEL = { bought = "Bought", buying = "Buying", own = "Have it", moved = "Moved", again = "Kept", unsure = "Check mail",
    gone = "Sold out", checking = "Checking", dearer = "Price up" }
-- ... and per reason a confirmed row cannot be bought this very moment
local SHORT = { ["Checking the price..."] = "Checking", ["Not enough gold."] = "No gold",
    ["Open the auction house to buy."] = "AH closed", ["Scanning..."] = "Scanning", ["Buying..."] = "Buying",
    ["That would go past your gold limit."] = "Over limit", ["That costs more than the list allows."] = "Price up",
    ["Sold out."] = "Sold out", ["The list changed."] = "Wait", [Scan.WATCHING] = "Wait", [Scan.UNSURE] = "Check mail",
    [Scroll.UNSURE] = "Check mail", [Scroll.WAITING] = "Wait" }
-- the same for a scroll row
local SCROLL_LABEL = { checking = "Checking", gone = "None", manual = "By hand", unsure = "Check mail", quoting = "Asking",
    buying = "Buying" }
local SCROLL_EXPLAIN = {
    checking = "Reading its prices.",
    gone = "None on sale right now, or the auction house did not answer. It is asked again by itself.",
    manual = "This game sells this one as single auctions, not by amount: buy it in the auction window.",
    unsure = "A payment for these got no clear answer. Check your mail, then open the auction house again.",
    quoting = "Asking the auction house what this amount costs right now.",
    quoted = "The auction house named its price. Click to buy at the total shown.",
    buying = "Paying...",
}
local EXPLAIN = {
    checking = "Reading the real listing to confirm the price.",
    dearer = "The real price is above what the list counted. The list is worked out again once all prices are read.",
    gone = "Sold out. The list is worked out again once all prices are read.",
    moved = "Nothing to buy: it comes over from your other hand or ring slot once that slot has its upgrade.",
    again = "Nothing to buy: you wore it earlier in this slot and it is still in your bags.",
    own = "You already have it.",
}

local frame, rows, range = nil, {}, {}
UI.scroll = 0
UI.view = "gear"                   -- what the rows show: "gear" or "scrolls"
UI.usable = true                   -- consumables: only what can be used at this level (false: the level range of the tab)

-- Small building blocks (the same plain parts Alt Outfitter is built from) ------------------------------------
local function Fill(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function Border(parent, r, g, b, a)
    local edges = {}
    for i = 1, 4 do edges[i] = Fill(parent, "BORDER", r, g, b, a) end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
end

local function Text(parent, font, justify, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    return fs
end

-- Writes only when the text changed (the window draws several times a second).
local function Put(fs, text)
    if fs.shownText ~= text then
        fs.shownText = text
        fs:SetText(text)
    end
end

local function Button(parent, width, height, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height)
    b.bg = Fill(b, "BACKGROUND", 0.16, 0.16, 0.18, 1)
    b.bg:SetAllPoints()
    Border(b, 0.32, 0.32, 0.36, 1)
    b.label = Text(b, "GameFontHighlightSmall", "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText(label or "")
    b.on, b.text = true, label
    function b:Paint()
        if not self.on then
            self.bg:SetColorTexture(0.1, 0.1, 0.11, 1)
            if self.tone then
                self.label:SetTextColor(self.tone[1], self.tone[2], self.tone[3])
            else
                self.label:SetTextColor(0.45, 0.45, 0.45)
            end
        elseif self.picked then
            self.bg:SetColorTexture(0.42, 0.33, 0.06, 1)
            self.label:SetTextColor(1, 0.92, 0.6)
        elseif self.hot then
            self.bg:SetColorTexture(0.26, 0.26, 0.3, 1)
            self.label:SetTextColor(1, 1, 1)
        else
            self.bg:SetColorTexture(0.16, 0.16, 0.18, 1)
            self.label:SetTextColor(0.9, 0.9, 0.9)
        end
    end
    -- does nothing when nothing changed
    function b:Able(on, text, tone, picked)
        on, picked = on and true or false, picked and true or false
        if on == self.on and (text == nil or text == self.text) and tone == self.tone and picked == (self.picked or false) then
            return
        end
        self.on, self.tone, self.picked = on, tone, picked
        if text and text ~= self.text then
            self.text = text
            self.label:SetText(text)
        end
        self:Paint()
    end
    b:SetScript("OnEnter", function(self)
        self.hot = true
        self:Paint()
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.tip, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hot = false
        self:Paint()
        GameTooltip:Hide()
    end)
    -- A greyed-out button swallows the click.
    b:SetScript("OnClick", function(self, mouse)
        if self.on and onClick then onClick(self, mouse) end
    end)
    b:Paint()
    return b
end

-- The gold slider ---------------------------------------------------------------------------------------------
-- The slider's right end is what the best list costs (on top of what is spent); before a scan, a round amount.
local function Top()
    local me = ns.me
    local top = Shop.Top()
    if not Shop.curve then top = 2000000 end
    return max(top, me and me.budget or 0, 10000)
end

local function Nice(copper)                     -- round amounts: 50 silver, then 1 gold, then 5 gold
    local step = (copper < 200000 and 5000) or (copper < 1000000 and 10000) or 50000
    return floor(copper / step + 0.5) * step
end

local function FromSlider(value, top)
    if value >= STEPS then return top end
    local part = max(0, value) / STEPS
    return min(top, Nice(top * part * part))
end

local function ToSlider(copper, top)
    if copper >= top then return STEPS end
    return floor(STEPS * sqrt(max(0, copper) / top) + 0.5)
end

UI.FromSlider, UI.ToSlider = FromSlider, ToSlider

local function GoldText(copper)                 -- for the box: "25" or "12.5"
    local gold = floor(copper / 100 + 0.5) / 100
    return gold == floor(gold) and tostring(floor(gold)) or tostring(gold)
end

-- Puts the slider and the box where the gold limit is (without that counting as the player moving them).
local function ShowBudget()
    local me = ns.me
    if not me or not frame then return end
    local top = Top()
    if top == UI.top and me.budget == UI.budget then return end
    UI.top, UI.budget = top, me.budget
    UI.setting = true
    frame.slider:SetValue(ToSlider(me.budget, top))
    UI.setting = false
    if frame.box and not frame.box:HasFocus() then frame.box:SetText(GoldText(me.budget)) end
end

local function SliderMoved(value)
    if UI.setting or not ns.me then return end
    local budget = FromSlider(floor((value or 0) + 0.5), UI.top or Top())
    if budget == ns.me.budget then return end
    UI.budget = budget                          -- the thumb is already where the player put it
    Shop.DropWish()                             -- (a Cheapest / Smart / Best click still waiting must not override this)
    Shop.SetBudget(budget)
    if frame.box and not frame.box:HasFocus() then frame.box:SetText(GoldText(budget)) end
end

local function BoxEntered(box)
    local gold = tonumber((box:GetText() or ""):match("^%s*(.-)%s*$"))
    if gold and gold == gold and gold >= 0 and gold < 1000000 then
        Shop.DropWish()
        Shop.SetBudget(floor(gold * 10000 + 0.5))
    end
    box:ClearFocus()
    UI.budget = nil                             -- so the slider and the box are set again from the limit
    ns.dirty = true
end

-- Rows -----------------------------------------------------------------------------------------------------
local function LinkOf(r)
    local o = Scan.Offer(r.key)
    if o and o.listing and o.listing.link then return o.listing.link end
    return "item:" .. r.item.id .. (r.item.bonus ~= 0 and ("::::::::::::1:" .. r.item.bonus) or "")
end

local function ScrollTip(row, r)
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    if not pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. r.id) then GameTooltip:SetText(r.name, 1, 1, 1) end
    if r.instead then
        GameTooltip:AddLine(("%s: a weaker one, because no %s is on sale right now."):format(r.kind, r.instead), 1, 0.82, 0, true)
    else
        GameTooltip:AddLine(("%s: the best one from level %d to %d."):format(r.kind, r.from, r.to), 1, 0.82, 0)
    end
    if r.note then GameTooltip:AddLine(r.note, 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine(("About %d last through these levels, at %d an hour of play. Click the amount to change it.")
        :format(Scroll.Suggest(r.from, r.to, r.perHour), r.perHour or 2), 0.8, 0.8, 0.8, true)
    local bought = ns.me and ns.me.scrollBought[r.id]
    GameTooltip:AddLine(("In your bags: %d.%s"):format(ns.Have(r.id), bought and ("  Bought so far: " .. bought .. ".") or ""),
        0.3, 1, 0.3)
    local state = Scroll.State(r)
    local line = SCROLL_EXPLAIN[state]
    if state == "ready" then
        local can, why = Scroll.CanBuy(r)
        line = not can and why or "One click buys at the total shown, or for less. If the price went up meanwhile the "
            .. "button turns into Pay with the new total."
    end
    if line then GameTooltip:AddLine(line, 1, 0.82, 0, true) end
    GameTooltip:Show()
end

local function RowTip(row)
    local r = row.data
    if not r or r.header then return end
    if UI.view == "scrolls" then return ScrollTip(row, r) end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    if not pcall(GameTooltip.SetHyperlink, GameTooltip, LinkOf(r)) then GameTooltip:SetText(r.name, 1, 1, 1) end
    GameTooltip:AddLine(("%s: this list has you wear it from level %d to %d."):format(r.slot, r.from, r.to), 1, 0.82, 0)
    if r.req then
        local level = ns.Level()
        local wear = r.wear or r.req
        GameTooltip:AddLine(wear <= level and "You can put it on right now."
            or (wear > r.req and ("It goes in the off hand from level %d (the item itself needs level %d)."):format(wear, r.req)
            or ("You can put it on at level %d."):format(wear)), 0.8, 0.8, 0.8, true)
    end
    if r.why and r.why ~= "" then GameTooltip:AddLine(r.why, 0.8, 0.8, 0.8, true) end
    if r.gain then
        GameTooltip:AddLine(("%d%% better than the piece before it."):format(floor(r.gain * 100 + 0.5)), 0.8, 0.8, 0.8)
    end
    local state, price = Shop.RowState(r)
    local line = EXPLAIN[state]
    if state == "bought" then
        line = "Bought for " .. ns.Coins(price, true) .. "."
    elseif state == "unsure" then
        line = Scan.UNSURE
    elseif state == "ready" then
        local can, why = Shop.CanBuy(r)
        line = not can and why or nil
    end
    if line then GameTooltip:AddLine(line, 1, 0.82, 0, true) end
    GameTooltip:Show()
end

-- Consumables only: the press of the mouse button on a row's Buy button. The game wants two inputs from the
-- player for one such purchase, asking the price and paying it, and a click is two: this press asks, the release
-- (BuyClicked) pays when the price has come by then.
local function BuyPressed(button)
    button.pressed = nil
    local r = button.row.data
    if UI.view ~= "scrolls" or not r or r.header then return end
    Scroll.Pressed(r)                                   -- a press on a Pay button whose total is on show
    if not Scroll.Press() then return end
    button.pressed = true                               -- the release only pays: it does not ask a second time
    if Scroll.purchase or not button.on or not button.price then return end
    local ok, why = Scroll.Buy(r, button.price, true)
    if not ok and why then Scan.Say(why, why ~= Scan.BUSY and "bad" or nil) end
    ns.dirty = true
end

-- The one place a click turns into a purchase. A greyed-out button swallows the click, with one exception: a
-- consumable whose price came while the button was held is paid on the release whatever the button still shows
-- (Scroll.Pay decides whether that total may be paid). A price that comes later goes on the button as Pay.
local function BuyClicked(button)
    local r = button.row.data
    if not r or r.header then return end
    local ok, why
    if UI.view == "scrolls" then
        local p, pressed = Scroll.purchase, button.pressed
        button.pressed = nil
        if p and p.id == r.id then
            if p.state ~= "quoted" then return end      -- still asking, or the payment is out already
            ok, why = Scroll.Pay(r, button.price)
        elseif pressed or not button.on or not button.price then
            return                                      -- the press asked already (or said why not)
        else
            ok, why = Scroll.Buy(r, button.price)       -- no press came first: this click asks, the next one pays
        end
    else
        if not button.on or not button.price then return end
        ok, why = Shop.Buy(r, button.price)
    end
    if not ok and why then Scan.Say(why, why ~= Scan.BUSY and "bad" or nil) end
    ns.dirty = true
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(W - 2 * PAD, ROW_H)
    row:SetPoint("TOPLEFT", PAD, LIST_TOP - (i - 1) * ROW_H)
    if i % 2 == 0 then Fill(row, "BACKGROUND", 1, 1, 1, 0.03):SetAllPoints() end
    -- a headline row ("Put on now", "Scrolls"): one bright text over the whole width, with a thin line under it
    row.head = Text(row, "GameFontNormalSmall", "LEFT", GOLD)
    row.head:SetPoint("LEFT", 2, -2)
    row.head:SetWidth(W - 2 * PAD - 8)
    row.rule = Fill(row, "ARTWORK", 1, 0.82, 0, 0.3)
    row.rule:SetPoint("BOTTOMLEFT", 0, 1)
    row.rule:SetPoint("BOTTOMRIGHT", 0, 1)
    row.rule:SetHeight(1)
    row.rule:Hide()
    row.level = Text(row, nil, "LEFT", DIM)
    row.level:SetPoint("LEFT", 2, 0)
    row.level:SetWidth(26)
    row.slot = Text(row, nil, "LEFT", DIM)
    row.slot:SetPoint("LEFT", 30, 0)
    row.slot:SetWidth(66)
    row.name = Text(row, nil, "LEFT")
    row.name:SetPoint("LEFT", 98, 0)
    row.name:SetWidth(214)
    row.why = Text(row, nil, "LEFT", DIM)
    row.why:SetPoint("LEFT", 316, 0)
    row.why:SetWidth(136)
    row.price = Text(row, nil, "RIGHT")
    row.price:SetPoint("RIGHT", -80, 0)
    row.price:SetWidth(78)
    row.buy = Button(row, 72, ROW_H - 4, "Buy")
    row.buy:SetScript("OnClick", BuyClicked)            -- it decides by itself what a click may do
    row.buy:SetScript("OnMouseDown", function(self, mouse)
        if mouse == nil or mouse == "LeftButton" then BuyPressed(self) end
    end)
    row.buy:SetPoint("RIGHT", -2, 0)
    row.buy.row = row
    -- scroll rows only: how many to buy; a click steps through 5, 10, 20, 40
    row.amount = Button(row, 38, ROW_H - 4, "", function(self)
        local r = self.row.data
        if r and not r.header and UI.view == "scrolls" then
            local p = Scroll.purchase
            if p and p.id == r.id then Scroll.Leave() end      -- this row's own asked price no longer fits
            Scroll.CycleAmount(r)
        end
    end)
    row.amount:SetPoint("LEFT", 28, 0)
    row.amount.row = row
    row.amount.tip = "How many to buy. Click to change."
    row.amount:Hide()
    row:SetScript("OnEnter", RowTip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        local r = self.data
        if UI.view == "scrolls" or (r and r.header) then return end
        local o = r and Scan.Offer(r.key)
        local link = o and o.listing and o.listing.link
        if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end      -- shift: chat, ctrl: try on
    end)
    return row
end

-- A row's Buy button: what it says and whether a click would go through right now.
local function PaintBuy(row, r)
    local state, price = Shop.RowState(r)
    local b = row.buy
    if state == "ready" then
        local can, why = Shop.CanBuy(r)
        if can or why == Scan.BUSY then
            b.price = price
            b:Able(true, "Buy")
        else
            b.price = nil
            b:Able(false, SHORT[why] or "Wait")
        end
    else
        b.price = nil
        b:Able(false, LABEL[state] or "-", (state == "bought" or state == "own") and GOOD or (state == "dearer" or state == "gone"
            or state == "unsure") and BAD or nil)
    end
    return state, price
end

-- The same for a scroll row. "Buy 20" buys with one click when the auction house names its price before the
-- mouse button is let go; when it comes later the button reads "Pay" and a click buys at the total in the price
-- column.
local function PaintScroll(row, r)
    local state, qty, total, each, short = Scroll.State(r)
    local b = row.buy
    b.mode = nil
    if state == "ready" then
        local can, why = Scroll.CanBuy(r)
        if can or why == Scan.BUSY then
            b.price = total
            b:Able(true, "Buy " .. qty)
        else
            b.price = nil
            b:Able(false, SHORT[why] or "Wait")
        end
    elseif state == "quoted" then
        b.price, b.mode = total, "pay"
        b:Able(true, "Pay", nil, true)
    else
        b.price = nil
        b:Able(false, SCROLL_LABEL[state] or "-", (state == "gone" or state == "unsure") and BAD or nil)
    end
    return state, qty, total, each, short
end

local EMPTY = {}
-- what the ranged slot takes, for the line that says why it is empty
local RANGED_WORD = { ROGUE = "throwing weapon", HUNTER = "bow, gun or crossbow", PRIEST = "wand", MAGE = "wand",
    WARLOCK = "wand" }
-- The pieces (or consumables) to show, without headlines.
local function SourceRows()
    if UI.view == "scrolls" then
        if not ns.Known() then return EMPTY end
        return UI.usable and Scroll.Usable() or Scroll.Rows(Shop.segment)
    end
    local view = Shop.view
    local seg = view and view.segments[Shop.segment]
    return seg and seg.rows or EMPTY
end

-- The list as it is drawn: the same rows with a headline before each group, so it reads at a glance.
--   gear:        "Put on now" (what the character can wear at its level), then "For later levels"
--   consumables: Scrolls, Elixirs and drinks, Potions, Weapon stones, Food (the order of Data.lua's `sections`)
-- A headline is a row of its own: { header = "text", note = "smaller text behind it" }. Built again only when the
-- rows behind it changed (the window asks several times a second).
local SECTION = {}
for _, k in ipairs(ns.DATA.kinds or {}) do SECTION[k[1]] = k[4] end
-- what each section is, in a few plain words (shown behind its headline)
local SECTION_NOTE = { ["Scrolls"] = "read one: a buff for a while", ["Elixirs and drinks"] = "drink one: a longer buff",
    ["Potions"] = "for the middle of a fight", ["Weapon stones"] = "use one on your weapon: it hits harder for a while",
    ["Food"] = "eat between fights for a buff" }
local shown = { src = {}, list = EMPTY }
local function Display(src)
    local kind, level = UI.view, ns.Level()
    local same = shown.kind == kind and shown.level == level and #shown.src == #src
    if same then
        for i = 1, #src do
            if shown.src[i] ~= src[i] then
                same = false
                break
            end
        end
    end
    if same then return shown.list end
    local copy, list = {}, {}
    for i = 1, #src do copy[i] = src[i] end
    if #src == 0 then
        list = EMPTY
    elseif kind == "scrolls" then
        local groups = {}
        for i = 1, #src do
            local name = SECTION[src[i].kind] or "Other"
            groups[name] = groups[name] or {}
            groups[name][#groups[name] + 1] = src[i]
        end
        local order = {}
        for _, name in ipairs(ns.DATA.sections or {}) do order[#order + 1] = name end
        order[#order + 1] = "Other"
        for _, name in ipairs(order) do
            local g = groups[name]
            if g then
                list[#list + 1] = { header = name, note = SECTION_NOTE[name] }
                for i = 1, #g do list[#list + 1] = g[i] end
            end
        end
    else
        local now, later, ranged = {}, {}, false
        for i = 1, #src do
            local r = src[i]
            if r.slot == "Ranged" then ranged = true end
            if r.from <= level then now[#now + 1] = r else later[#later + 1] = r end
        end
        if #now > 0 then
            list[#list + 1] = { header = "Put on now", note = "you can wear these at level " .. level }
            for i = 1, #now do list[#list + 1] = now[i] end
        end
        if #later > 0 then
            list[#list + 1] = { header = "For later levels", note = "buy ahead: Lvl is the level each one can be worn" }
            for i = 1, #later do list[#list + 1] = later[i] end
        end
        local what = RANGED_WORD[ns.class or ""]
        if not ranged and what then
            -- an empty ranged slot: say why (none on sale, or not worth its price at this limit). The rogue takes
            -- thrown weapons only; classes whose ranged slot holds little (warriors, relics) get no line.
            local _, to = ns.Range()
            local onSale = false
            for _, c in ipairs(ns.cands["Ranged"]) do
                if c.req <= to and Scan.Offer(c.key) then
                    onSale = true
                    break
                end
            end
            list[#list + 1] = { header = "Ranged slot", note = onSale
                and ("a " .. what .. " is on sale, but not worth its price at this gold limit (raise the limit to get it)")
                or ("no " .. what .. " on sale for these levels" .. (ns.class == "ROGUE" and " (weapon vendors sell them)" or "")) }
        end
    end
    shown.kind, shown.level, shown.src, shown.list = kind, level, copy, list
    return list
end

local function SegmentRows()
    return Display(SourceRows())
end
UI.List = SegmentRows

-- Status line: what is going on, else the last message for a while, else a standing hint.
local function Status()
    local busy = Shop.Busy()
    if busy then return ("Working out the list...  %d%%"):format(floor(busy * 100)), nil end
    local progress = Scan.Progress()
    local state = Scan.state
    if progress and state.phase ~= "idle" then return progress, nil end
    if state.message ~= "" and state.messageAt and GetTime() - state.messageAt < MESSAGE_FOR then
        return state.message, state.tone
    end
    if progress then return progress, nil end
    if not ns.Known() then return "Level Outfitter has no lists for this class yet (it knows rogue, warrior and warlock).", "bad" end
    if Shop.error then return "Something went wrong working out the list. Press Scan to try again.", "bad" end
    if not state.scanned then
        return ns.ahOpen and "Press Scan to read the auction house." or "Open the auction house and press Scan.", nil
    end
    local minutes = floor((time() - state.scanned) / 60)
    if not Shop.view then return "No list yet.", nil end
    if minutes >= 15 then
        return ("Prices are %d minutes old.%s"):format(minutes, ns.ahOpen and " Press Scan for fresh ones." or ""), nil
    end
    local other = ns.Score.OtherSpec()
    if other then
        return ("Forever Leveling BiS is set to %s for this character. Pick Combat there so both addons agree.")
            :format(other:sub(1, 1):upper() .. other:sub(2)), "bad"
    end
    local seg = Shop.view.segments[Shop.segment]
    if seg and #seg.rows == 0 then
        return "Nothing to buy for these levels at this gold limit. Try more levels or a higher limit.", nil
    end
    return ns.ahOpen and "Hover a piece for details. One click on Buy buys one piece."
        or "Open the auction house to buy.", nil
end

-- The standing hint for the scroll view (messages and progress come first, as for gear).
local function ScrollStatus()
    local progress = Scan.Progress()
    local state = Scan.state
    if progress and state.phase ~= "idle" then return progress, nil end
    if state.message ~= "" and state.messageAt and GetTime() - state.messageAt < MESSAGE_FOR then
        return state.message, state.tone
    end
    if not ns.Known() then return "Level Outfitter has no lists for this class yet (it knows rogue, warrior and warlock).", "bad" end
    return ns.ahOpen and "One click on Buy buys that amount at the total shown, or for less. Have = in your bags."
        or "Open the auction house to see prices and buy.", nil
end

-- Buttons and the status line: cheap, done several times a second (prices go stale, the auction house gets busy).
function UI.Buttons()
    if not frame then return end
    local list, holding, scrolls = SegmentRows(), false, UI.view == "scrolls"
    local want = UI.want or {}
    UI.want = want
    for i = #want, 1, -1 do want[i] = nil end
    for i = 1, ROWS do
        local row, r = rows[i], list[i + UI.scroll]
        if r ~= row.data then
            ns.dirty = true                     -- the list changed under the rows (a level-up): draw it all again first
        elseif r and not r.header then
            if scrolls then
                PaintScroll(row, r)
                want[#want + 1] = r.id
            else
                PaintBuy(row, r)
            end
            if row.buy.hot and row.buy.on then holding = true end
        end
    end
    Scroll.Want(want)                           -- the scrolls on show get their prices read (none in the gear view)
    -- the mouse rests on a Buy button that works: no new price check starts, so the click is not kept waiting
    if holding then Scan.Hold(1) end
    local text, tone
    if scrolls then text, tone = ScrollStatus() else text, tone = Status() end
    Put(frame.status, text)
    if tone ~= frame.status.tone then
        frame.status.tone = tone
        local c = (tone == "good" and GOOD) or (tone == "bad" and BAD) or DIM
        frame.status:SetTextColor(c[1], c[2], c[3])
    end
    frame.scan:Able(ns.ahOpen == true and Scan.state.phase == "idle" and not Scan.buy.pending and ns.Known())
end

function UI.Render()
    if not frame then return end
    ns.dirty = false
    local me, view, scrolls = ns.me, Shop.view, UI.view == "scrolls"
    ShowBudget()
    frame.viewGear:Able(true, nil, nil, not scrolls)
    frame.viewScrolls:Able(true, nil, nil, scrolls)
    Put(frame.lvlHead, scrolls and "Have" or "Lvl")
    Put(frame.slotHead, scrolls and "Amount" or "Slot")
    Put(frame.whyHead, scrolls and "Best for levels" or "Stats")
    local usable = scrolls and UI.usable
    if scrolls then
        frame.usable:Show()
        frame.usable:Able(true, nil, nil, usable)
    else
        frame.usable:Hide()
    end
    local totals = Shop.Totals()
    if usable then
        Put(frame.summary, me and ("Usable now, at level %d: the best of each kind     Spent on consumables so far: %s (not part of the gear gold limit)")
            :format(ns.Level(), ns.Coins(me.scrollSpent)) or "")
    elseif scrolls then
        local seg = ns.SEGMENTS[Shop.segment]
        Put(frame.summary, me and ("Scrolls, elixirs, potions, stones and food for levels %d-%d     Spent on them so far: %s (not part of the gear gold limit)")
            :format(seg[1], seg[2], ns.Coins(me.scrollSpent)) or "")
    elseif view and me then
        Put(frame.summary, ("To pay: %s for %d pieces     Spent so far: %s     Strength: %d%% of the best gear on sale")
            :format(ns.Coins(totals.left), totals.buys, ns.Coins(me.spent), floor(view.power * 100 + 0.5)))
    else
        Put(frame.summary, me and ("Spent so far: " .. ns.Coins(me.spent)) or "")
    end
    -- the level range: two numbers with - and + (off while the consumables show "Usable now")
    local from, to = ns.Range()
    ns.SEGMENTS[1][1], ns.SEGMENTS[1][2] = from, to       -- (a level-up moves an automatic range: the consumables follow at once)
    local auto = me and me.from == nil and me.to == nil
    Put(range.fromText, tostring(from))
    Put(range.toText, tostring(to))
    range.fromMinus:Able(not usable and from > ns.Level())      -- (levels already passed are not shopped for)
    range.fromPlus:Able(not usable and from < 60)
    range.toMinus:Able(not usable and to > from)
    range.toPlus:Able(not usable and to < 60)
    range.auto:Able(not usable, nil, nil, auto and not usable)
    range.all:Able(not usable, nil, nil, to == 60 and not auto and not usable)
    Put(range.note, usable and "Usable now: the level range is not used" or (scrolls and "consumables for these levels")
        or (view and (totals.buys > 0 and (totals.buys .. " to buy: " .. ns.Coins(totals.left)) or "nothing left to buy")) or "")
    Put(frame.sub, ns.ClassLabel() .. "   |   stat weights: Forever Leveling BiS, " .. (ns.Score.source == "live" and "live"
        or ("built-in copy " .. tostring(ns.DATA.flb))))
    local list = SegmentRows()
    -- the row a price was asked for is no longer in the list (a stand-in made way, a level-up): that request is let go
    local p = scrolls and Scroll.purchase
    if p then
        local there = false
        for i = 1, #list do
            if list[i] == p.row then
                there = true
                break
            end
        end
        if not there then Scroll.Leave() end
    end
    UI.scroll = max(0, min(UI.scroll, #list - ROWS))
    for i = 1, ROWS do
        local row, r = rows[i], list[i + UI.scroll]
        row.data = r
        local head = r and r.header
        if head then
            -- a headline: its text over the whole row, no button, nothing in the columns
            Put(row.head, r.note and (head .. "   |cff999999" .. r.note .. "|r") or head)
            row.rule:Show()
            row.amount:Hide()
            row.buy:Able(false, "")             -- nothing to click, even for code that looks at the button
            row.buy:Hide()
            row.buy.price = nil
            Put(row.level, "")
            Put(row.slot, "")
            Put(row.name, "")
            Put(row.why, "")
            Put(row.price, "")
            row:Show()
        elseif r then
            Put(row.head, "")
            row.rule:Hide()
            row.buy:Show()
        end
        if head then
            -- (drawn above)
        elseif r and scrolls then
            local state, qty, total, each, short = PaintScroll(row, r)
            -- first column: how many are in the bags already, bright when there are some
            local have = ns.Have(r.id)
            Put(row.level, tostring(have))
            local tone = have > 0 and GOOD or DIM
            if row.haveTone ~= tone then
                row.haveTone = tone
                row.level:SetTextColor(tone[1], tone[2], tone[3])
            end
            Put(row.slot, "")
            row.amount:Able(true, "x" .. Scroll.Amount(r))
            row.amount:Show()
            local q = QUALITY[1]
            if row.q ~= q then
                row.q = q
                row.name:SetTextColor(q[1], q[2], q[3])
            end
            Put(row.name, r.name)
            -- fewer on sale than wanted is said outright; else the price each of the cheapest
            Put(row.why, (r.instead and "weaker: the better one is sold out" or ("lvl " .. r.from .. "-" .. r.to))
                .. ((short and qty and ("   only " .. qty .. " on sale"))
                or (each and ("   " .. ns.Coins(each) .. " each")) or ""))
            Put(row.price, total and total > 0 and ns.Coins(total) or "")
            row:Show()
        elseif r then
            local state, price = PaintBuy(row, r)
            row.amount:Hide()
            -- first column: the level the piece needs (what its tooltip says), green when it can be worn right now
            local tone = (r.wear or r.from) <= ns.Level() and GOOD or DIM
            if row.haveTone ~= tone then
                row.haveTone = tone
                row.level:SetTextColor(tone[1], tone[2], tone[3])
            end
            Put(row.level, tostring(r.req or r.from))
            Put(row.slot, r.slot)
            local q = QUALITY[r.item and r.item.quality or 1] or QUALITY[1]
            if row.q ~= q then
                row.q = q
                row.name:SetTextColor(q[1], q[2], q[3])
            end
            Put(row.name, r.name)
            Put(row.why, r.why or "")
            -- a price that is still the row's guess is marked "~"
            Put(row.price, price and ((state == "checking" and "~ " or "") .. ns.Coins(price)) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    local more = #list - ROWS - UI.scroll
    Put(frame.more, (#list > ROWS) and ((UI.scroll > 0 and "more above   " or "")
        .. (more > 0 and (more .. " more below: scroll with the mouse wheel") or "")) or "")
    UI.Buttons()
end

local function Build()
    frame = CreateFrame("Frame", "LevelOutfitterFrame", UIParent)
    frame:SetSize(W, H)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relative, x, y = self:GetPoint(1)
        if point then ns.db.pos = { point, relative, x, y } end
    end)
    -- a saved place that the game will not take (a hand-edited file) falls back to the usual spot
    local pos = ns.db.pos
    local placed = type(pos) == "table" and type(pos[1]) == "string" and pcall(frame.SetPoint, frame, pos[1], UIParent,
        type(pos[2]) == "string" and pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    if not placed then
        frame:ClearAllPoints()
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -80, 0)
    end
    local scale = tonumber(ns.db.scale)
    if not scale or scale ~= scale or scale < 0.5 or scale > 3 then
        scale = max(0.5, (UIParent:GetHeight() or 768) / 768 * 0.9)
    end
    frame:SetScale(scale)
    Fill(frame, "BACKGROUND", 0.05, 0.05, 0.06, 0.97):SetAllPoints()
    Border(frame, 0, 0, 0, 1)

    local title = Text(frame, "GameFontNormal", "LEFT", GOLD)
    title:SetPoint("TOPLEFT", PAD, -10)
    title:SetText("Level Outfitter")
    local sub = Text(frame, "GameFontDisableSmall", "LEFT")
    sub:SetPoint("LEFT", title, "RIGHT", 10, 0)
    sub:SetText(ns.ClassLabel())
    frame.sub = sub
    local close = Button(frame, 20, 20, "x", function() frame:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)
    -- what the rows show: the gear list, or the stat scrolls for the same level ranges
    frame.viewScrolls = Button(frame, 92, 20, "Consumables", function() UI.SetView("scrolls") end)
    frame.viewScrolls:SetPoint("TOPRIGHT", -32, -6)
    frame.viewScrolls.tip = "Scrolls, elixirs, potions, weapon stones and food: the best of each kind"
    frame.viewGear = Button(frame, 56, 20, "Gear", function() UI.SetView("gear") end)
    frame.viewGear:SetPoint("TOPRIGHT", -128, -6)
    frame.viewGear.tip = "The gear list"
    -- consumables only: what can be used right now (the level tabs are off then), or what a level range needs
    frame.usable = Button(frame, 84, 20, "Usable now", function()
        Scroll.Leave()                          -- a price asked for in the list being left is let go
        UI.usable, UI.scroll = not UI.usable, 0
        UI.Render()
    end)
    frame.usable:SetPoint("TOPRIGHT", -188, -6)
    frame.usable.tip = "On: only the best of each kind you can use at your level right now (a weaker one only when the better one is sold out). Off: everything for the levels picked below."
    frame.usable:Hide()

    -- the gold limit: slider, box, three shortcuts
    local label = Text(frame, "GameFontHighlightSmall", "LEFT")
    label:SetPoint("TOPLEFT", PAD, -42)
    label:SetText("Gold limit")
    local s = CreateFrame("Slider", nil, frame)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(250, 14)
    s:SetPoint("TOPLEFT", PAD + 62, -41)
    s:SetMinMaxValues(0, STEPS)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    local track = Fill(s, "BACKGROUND", 0.2, 0.2, 0.23, 1)
    track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(4)
    local thumb = Fill(s, "ARTWORK", 1, 0.82, 0, 1)
    thumb:SetSize(8, 14)
    s:SetThumbTexture(thumb)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(max(0, min(STEPS, floor((self:GetValue() or 0) + 0.5) + delta * 10)))
    end)
    s:SetScript("OnValueChanged", function(_, value) SliderMoved(value) end)
    frame.slider = s
    -- the box is a convenience: the window works without it on a game that cannot make one
    local okBox, box = pcall(CreateFrame, "EditBox", nil, frame)
    if okBox and box then
        box:SetSize(52, 18)
        box:SetPoint("LEFT", s, "RIGHT", 10, 0)
        box:SetAutoFocus(false)
        box:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
        box:SetJustifyH("RIGHT")
        box:SetMaxLetters(8)
        Fill(box, "BACKGROUND", 0.1, 0.1, 0.11, 1):SetAllPoints()
        Border(box, 0.32, 0.32, 0.36, 1)
        box:SetScript("OnEnterPressed", BoxEntered)
        box:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            UI.budget = nil
            ns.dirty = true
        end)
        local g = Text(frame, "GameFontHighlightSmall", "LEFT", GOLD)
        g:SetPoint("LEFT", box, "RIGHT", 3, 0)
        g:SetText("g")
        frame.box = box
    end
    local presets = { { "cheap", "Cheapest", "The list that leans hardest on cheap pieces" },
        { "smart", "Smart", "Pays for a piece only when it is clearly worth its price" },
        { "best", "Best", "The strongest list, whatever it costs" } }
    for i, p in ipairs(presets) do
        local b = Button(frame, 70, 20, p[2], function()
            if not Shop.Preset(p[1]) then Scan.Say("Scan first: the lists come from live prices.", "bad") end
            UI.budget = nil
            ns.dirty = true
        end)
        b:SetPoint("TOPRIGHT", -PAD - (3 - i) * 74, -38)
        b.tip = p[3]
        frame[p[1]] = b
    end

    frame.summary = Text(frame, "GameFontHighlightSmall", "LEFT")
    frame.summary:SetPoint("TOPLEFT", PAD, -68)
    frame.summary:SetWidth(W - 2 * PAD)

    -- the levels to shop for: "Levels  - 14 +  to  - 24 +", two shortcuts, and what is left to buy
    local function Move(dFrom, dTo)
        return function()
            local me = ns.me
            if not me then return end
            local step = (IsShiftKeyDown and IsShiftKeyDown()) and 5 or 1
            local from, to = ns.Range()
            if dFrom ~= 0 then
                ns.SetRange(from + dFrom * step, me.to)                 -- an end picked by hand stays where it is
            else
                ns.SetRange(me.from, max(from, to + dTo * step))
            end
            UI.scroll = 0
            Scroll.Leave()                      -- a price asked for in the list being left is let go
            Shop.RangeChanged()
            UI.Render()
        end
    end
    local function Shortcut(setTo)
        return function()
            local me = ns.me
            if not me then return end
            if setTo then ns.SetRange(me.from, setTo) else ns.SetRange(nil, nil) end
            UI.scroll = 0
            Scroll.Leave()
            Shop.RangeChanged()
            UI.Render()
        end
    end
    local lv = Text(frame, "GameFontHighlightSmall", "LEFT")
    lv:SetPoint("TOPLEFT", PAD, -94)
    lv:SetText("Levels")
    local x = PAD + 44
    local function Stepper(key, dFrom, dTo, tip)
        local minus = Button(frame, 20, 22, "-", Move(-dFrom, -dTo))
        minus:SetPoint("TOPLEFT", x, -89)
        local num = Text(frame, "GameFontNormal", "CENTER", GOLD)
        num:SetPoint("TOPLEFT", x + 22, -93)
        num:SetWidth(26)
        local plus = Button(frame, 20, 22, "+", Move(dFrom, dTo))
        plus:SetPoint("TOPLEFT", x + 50, -89)
        minus.tip, plus.tip = tip, tip
        range[key .. "Minus"], range[key .. "Text"], range[key .. "Plus"] = minus, num, plus
        x = x + 74
    end
    Stepper("from", 1, 0, "The level to shop from. Hold Shift for steps of 5.")
    local toLabel = Text(frame, "GameFontHighlightSmall", "LEFT")
    toLabel:SetPoint("TOPLEFT", x + 2, -94)
    toLabel:SetText("to")
    x = x + 20
    Stepper("to", 0, 1, "The last level to shop for. Hold Shift for steps of 5.")
    range.auto = Button(frame, 96, 22, "My next 10", Shortcut(nil))
    range.auto:SetPoint("TOPLEFT", x + 6, -89)
    range.auto.tip = "From your level, ten levels far. It moves along as you level up."
    range.all = Button(frame, 64, 22, "Up to 60", Shortcut(60))
    range.all:SetPoint("TOPLEFT", x + 106, -89)
    range.all.tip = "Everything from the first level picked up to level 60"
    range.note = Text(frame, "GameFontHighlightSmall", "RIGHT", DIM)
    range.note:SetPoint("TOPRIGHT", -PAD, -94)
    range.note:SetWidth(W - 2 * PAD - (x + 176))

    local head = { { "Lvl", 2, "lvlHead" }, { "Slot", 30, "slotHead" }, { "Piece", 98 }, { "Stats", 316, "whyHead" } }
    for _, h in ipairs(head) do
        local t = Text(frame, "GameFontDisableSmall", "LEFT")
        t:SetPoint("TOPLEFT", PAD + h[2], -120)
        t:SetText(h[1])
        if h[3] then frame[h[3]] = t end
    end
    local priceHead = Text(frame, "GameFontDisableSmall", "RIGHT")
    priceHead:SetPoint("TOPRIGHT", -PAD - 80, -120)
    priceHead:SetText("Price")
    for i = 1, ROWS do rows[i] = MakeRow(i) end

    -- bright, so a list longer than the window is not missed
    frame.more = Text(frame, "GameFontHighlightSmall", "RIGHT", GOLD)
    frame.more:SetPoint("BOTTOMRIGHT", -PAD, 44)
    frame.status = Text(frame, "GameFontHighlightSmall", "LEFT", DIM)
    frame.status:SetPoint("BOTTOMLEFT", PAD + 104, 17)
    frame.status:SetWidth(W - 2 * PAD - 104)
    frame.scan = Button(frame, 96, 26, "Scan", function()
        UI.scroll = 0
        Scan.Start()
        ns.dirty = true
    end)
    frame.scan:SetPoint("BOTTOMLEFT", PAD, 10)
    frame.scan.tip = "Read every piece of armor and every weapon on the auction house"

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local to = max(0, min(UI.scroll - delta, #SegmentRows() - ROWS))
        if to == UI.scroll then return end
        -- a price asked for must not scroll out of sight with its Pay button (it would hold up every other buy)
        if UI.view == "scrolls" then Scroll.Leave() end
        UI.scroll = to
        ns.dirty = true
    end)
    -- ten times a second while the window is open: draw again only when something changed
    local fast = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        fast = fast + (elapsed or 0)
        if fast >= 0.1 then
            fast = 0
            if ns.dirty then UI.Render() else UI.Buttons() end
        end
    end)
    frame:SetScript("OnShow", function()
        Shop.Open()
        ns.dirty = true
    end)
    frame:SetScript("OnHide", function()
        Shop.Close()
        Scroll.Leave()                          -- a price asked for is let go; a payment already out runs its course
        Scroll.Want({})
        UI.auto = nil
        GameTooltip:Hide()
    end)
    if type(UISpecialFrames) == "table" then UISpecialFrames[#UISpecialFrames + 1] = "LevelOutfitterFrame" end
    UI.frame, UI.rows, UI.range = frame, rows, range
end

function UI.Show()
    if not ns.db or not ns.me then return end
    if not frame then
        Build()
        Shop.segment = Shop.HomeSegment()
    end
    frame:Show()
    Shop.Open()
    UI.budget = nil
    UI.Render()
end

-- "gear" or "scrolls"
function UI.SetView(view)
    if view ~= "gear" and view ~= "scrolls" then return end
    if view ~= UI.view then
        Scroll.Leave()
        UI.view, UI.scroll = view, 0
    end
    ns.dirty = true
    if frame then UI.Render() end           -- at once: no button may keep what it showed in the other view
end

function UI.Toggle()
    if frame and frame:IsShown() then frame:Hide() else UI.Show() end
end

-- /lo scale 1.2
function UI.Scale(scale)
    scale = tonumber(scale)
    if not scale or not ns.db then return false end
    ns.db.scale = max(0.5, min(3, scale))
    if frame then frame:SetScale(ns.db.scale) end
    return true
end

-- The window comes up with the auction house (unless switched off with /lo auto) and leaves with it again when it
-- was not opened by hand.
function ns.OnAuctionHouse(open)
    if open then
        if ns.db and ns.db.auto ~= false and ns.me and ns.Known() and not (frame and frame:IsShown()) then
            UI.Show()
            UI.auto = true
        end
    elseif frame and UI.auto then
        frame:Hide()
    end
    ns.dirty = true
end
