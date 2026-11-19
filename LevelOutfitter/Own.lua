-- Own.lua: what this character already has: worn, in the bags, in the bank, in the mailbox, or bought and on its
-- way. It only reads. Nothing here moves, uses or buys an item.
--
-- A piece bought at the auction house arrives by mail, where the game cannot see it until the mailbox is opened.
-- So every buy is written down as "on its way" until the mailbox shows it. A buy is written down as a "maybe"
-- the moment the bid goes out (so a reload or a disconnect cannot lose it) and stays one until the auction house
-- says it went through, says it was refused, or the mailbox shows whether it came. A "maybe" counts as owned,
-- blocks buying that piece again, and its price is held back from the gold limit.
--
-- me.transit[key] = { n = copies bought that the mailbox has not shown yet, maybe = { prices of the doubted ones
--                     among them }, at = time() of the last buy }
local ADDON, ns = ...
local Own = {}
ns.Own = Own

local pairs, ipairs, type, max, min, pcall, remove, time = pairs, ipairs, type, math.max, math.min, pcall, table.remove, time
local GetTime = GetTime
local SETTLE = 60          -- a "maybe" must be this old (seconds) before a look in the mailbox may say it never came
local GIVE_UP = 3600       -- a buy that went through but never showed up in the mailbox is dropped after this long
local VISIT = 3            -- the mailbox must have been open this long before "it is not there" is believed

local dirty, bankOpen, mailOpen = true, false, false
local bankDue = false      -- the bank changed while open and was not read again yet (it is read once per burst)
local visit                -- the mailbox visit in progress: { at, top = { [key] = most copies in sight so far }, reads,
                           -- complete, told = the player heard that the mailbox is too full }
local counts, seen, carried = {}, {}, {}
ns.ownRev = 0              -- goes up whenever the counts change

function Own.Dirty()
    dirty = true
end

local function Add(into, link)
    if not link then return end
    local key = ns.LinkKey(link)
    if key then into[key] = (into[key] or 0) + 1 end
end

-- Bags: newer games keep these calls in C_Container, older ones as plain functions. Either way a failure reads
-- as "nothing there".
local function NumSlots(bag)
    local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not f then return 0 end
    local ok, n = pcall(f, bag)
    return ok and type(n) == "number" and n or 0
end

local function SlotLink(bag, slot)
    local C = C_Container
    if C and C.GetContainerItemInfo then            -- the way other Forever addons read a slot
        local ok, info = pcall(C.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and info.hyperlink then return info.hyperlink end
    end
    local f = (C and C.GetContainerItemLink) or GetContainerItemLink
    if not f then return nil end
    local ok, link = pcall(f, bag, slot)
    return ok and link or nil
end

-- The bags carried: the backpack and every equipped bag.
local function LastBag()
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

-- The bank's containers. Forever keeps the bank in "character bank tabs" (Enum.BagIndex.CharacterBankTab_1 to _9);
-- an older game has the main bank (-1) and the bank bag slots after the carried bags.
local function BankBags()
    local list, index = {}, type(Enum) == "table" and Enum.BagIndex
    if type(index) == "table" then
        for i = 1, 9 do
            local bag = index["CharacterBankTab_" .. i]
            if bag ~= nil then list[#list + 1] = bag end
        end
    end
    if #list == 0 then
        local bags = NUM_BAG_SLOTS or 4
        list[1] = BANK_CONTAINER or -1
        for bag = bags + 1, bags + (NUM_BANKBAGSLOTS or 7) do list[#list + 1] = bag end
    end
    return list
end

local function ReadBags(into, first, last)
    local slots = 0
    for bag = first, last do
        local n = NumSlots(bag)
        slots = slots + n
        for slot = 1, n do Add(into, SlotLink(bag, slot)) end
    end
    return slots
end

local function ReadWorn(into)
    if not GetInventoryItemLink then return end
    for slot = 1, 19 do
        local ok, link = pcall(GetInventoryItemLink, "player", slot)
        if ok then Add(into, link) end
    end
end

-- The bank can only be read while it is open; what it held is remembered until the next visit.
local function ReadBank()
    local me = ns.me
    if not me then return end
    local into, slots = {}, 0
    for _, bag in ipairs(BankBags()) do slots = slots + ReadBags(into, bag, bag) end
    if slots > 0 then me.bank = into end
end

local function Changed()
    dirty = true
    Own.Counts()
end

-- A "maybe" of this key was settled by the mailbox: news about it that arrives after all must not count again.
local function DropLate(key)
    if ns.Scan and ns.Scan.DropLate then ns.Scan.DropLate(key) end
end

-- The same for the mailbox. Only a look that could tell every piece apart is remembered: the box shows all of
-- its mail (it lists 50 at most) and every attachment that is an item of ours gave its link. A look that could
-- not (a link the game has not loaded yet, mail that is hidden) changes nothing and returns false, plus "full"
-- when the reason is mail that is hidden.
local function ReadMail()
    local me = ns.me
    if not me or not GetInboxNumItems or not GetInboxItemLink then return false end
    local ok, shown, total = pcall(GetInboxNumItems)
    if not ok or type(shown) ~= "number" then return false end
    if type(total) == "number" and total > shown then return false, "full" end
    local into = {}
    for i = 1, shown do
        for j = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
            local ok2, link = pcall(GetInboxItemLink, i, j)
            if ok2 and link then
                Add(into, link)
            elseif GetInboxItem then
                -- no link: the item id alone tells whether it is one of ours, not which variant
                local ok3, _, id = pcall(GetInboxItem, i, j)
                if ok3 and id and ns.byId[id] then return false end
            end
        end
    end
    me.mail = into
    dirty = true
    return true
end

-- key -> copies this character has or is about to receive. The table must not be changed by the caller.
function Own.Counts()
    if not dirty then return counts end
    dirty = false
    if bankOpen and bankDue then           -- the bank changed and somebody asks before it was read again
        bankDue = false
        ReadBank()
    end
    for key in pairs(seen) do seen[key] = nil end
    for key in pairs(carried) do carried[key] = nil end
    ReadWorn(carried)
    ReadBags(carried, 0, LastBag())
    for key, n in pairs(carried) do seen[key] = n end
    local me, out = ns.me, {}
    if me then
        for key, n in pairs(me.bank) do seen[key] = (seen[key] or 0) + n end
        for key, n in pairs(me.mail) do seen[key] = (seen[key] or 0) + n end
    end
    for key, n in pairs(seen) do out[key] = n end
    if me then
        for key, t in pairs(me.transit) do out[key] = (out[key] or 0) + t.n end
        for key, n in pairs(me.owned) do
            if (out[key] or 0) < n then out[key] = n end
        end
    end
    local same = true
    for key, n in pairs(out) do
        if counts[key] ~= n then
            same = false
            break
        end
    end
    if same then
        for key in pairs(counts) do
            if out[key] == nil then
                same = false
                break
            end
        end
    end
    if not same then
        counts = out
        ns.ownRev = ns.ownRev + 1
        ns.dirty = true
    end
    return counts
end

local function Entry(me, key)
    local t = me.transit[key]
    if not t then
        t = { n = 0, maybe = {} }
        me.transit[key] = t
    end
    return t
end

-- Where a doubted buy at this price sits in the list (any doubted buy when none has that price), or nil.
local function Doubt(t, price)
    for i = 1, #t.maybe do
        if t.maybe[i] == price then return i end
    end
    return #t.maybe > 0 and #t.maybe or nil
end

-- A bid goes out, or a buy got no answer: the piece may or may not be bought.
function Own.Unsure(key, price)
    local me = ns.me
    if not me then return end
    local t = Entry(me, key)
    t.n = t.n + 1
    t.maybe[#t.maybe + 1] = price
    t.at = time()
    Changed()
end

-- A buy went through. wasMaybe = it was written down as a "maybe" before (always, unless that doubt was taken back).
function Own.Bought(key, price, wasMaybe)
    local me = ns.me
    if not me then return end
    me.spent = me.spent + price
    local t = me.transit[key]
    local at = wasMaybe and t and Doubt(t, price)
    if at then
        remove(t.maybe, at)                 -- still counted in t.n: only the doubt is gone
    else
        t = Entry(me, key)
        t.n = t.n + 1
    end
    t.at = time()
    Changed()
end

-- The auction house refused the bid: the "maybe" written down for it is taken back.
function Own.Clear(key, price)
    local me = ns.me
    local t = me and me.transit[key]
    local at = t and Doubt(t, price)
    if not at then return end
    remove(t.maybe, at)
    t.n = t.n - 1
    if t.n < 1 then me.transit[key] = nil end
    Changed()
end

function Own.IsUnsure(key)
    local me = ns.me
    local t = me and me.transit[key]
    return t ~= nil and #t.maybe > 0
end

-- Gold that doubted buys may have cost: held back from the gold limit until they are settled.
function Own.Held()
    local me = ns.me
    local held = 0
    if me then
        for _, t in pairs(me.transit) do
            for i = 1, #t.maybe do held = held + t.maybe[i] end
        end
    end
    return held
end

-- Bought copies that showed up during this mailbox visit: more of a piece is in sight (carried plus in the
-- mailbox) than at any moment of the visit so far. They are no longer "on their way". When more showed up than
-- were certain, doubted buys went through after all, and their price is counted as spent.
-- (Counting what is carried as well catches a piece taken out before the mailbox could tell what it was.)
-- When the mailbox could not be read to the end (too much mail, a link not loaded yet), only what is carried
-- counts: the bags can always be read, and a stale mailbox count next to fresh bags would count a piece twice.
-- So a piece taken into the bags from a full mailbox is still ticked off.
local function Arrivals(complete)
    local me = ns.me
    if not me or not visit then return end
    Changed()
    local landed                            -- doubted buys that went through: { key, price, key, price, ... }
    for key, t in pairs(me.transit) do
        local total = (carried[key] or 0) + (complete and me.mail[key] or 0)
        local top = visit.top[key]
        if not top then
            -- a note that did not exist when the mailbox was opened: counted from here on, the same way as at
            -- MAIL_SHOW (with the last mailbox count, so a copy that was already there is no arrival)
            visit.top[key] = (carried[key] or 0) + (me.mail[key] or 0)
        elseif total > top then
            visit.top[key] = total
            local arrived = min(t.n, total - top)
            local certain = t.n - #t.maybe
            if arrived > certain then
                landed = landed or {}
                for _ = 1, arrived - certain do
                    local price = remove(t.maybe, 1)
                    me.spent = me.spent + price
                    landed[#landed + 1], landed[#landed + 2] = key, price
                end
                DropLate(key)
            end
            t.n = t.n - arrived
            if t.n < 1 then me.transit[key] = nil end
        end
    end
    Changed()
    -- the shopping list ticks the row off, so it offers no second copy of a piece that came after all
    if landed and ns.OnBought then
        for i = 1, #landed, 2 do ns.OnBought(landed[i], landed[i + 1]) end
    end
end

-- A mailbox visit is over, and the mailbox could be read to the end. What arrived has been taken off the notes
-- already (Arrivals); a "maybe" that is old enough and still did not show up never went through: it is forgotten
-- and the piece can be bought again. A buy that did go through and is missing after an hour is given up on.
function Own.Settle(now)
    local me = ns.me
    if not me then return end
    now = now or time()
    for key, t in pairs(me.transit) do
        local age = now - (t.at or 0)
        if #t.maybe > 0 and age >= SETTLE then
            t.n = t.n - #t.maybe
            t.maybe = {}
            DropLate(key)
        end
        if t.n > 0 and #t.maybe == 0 and age >= GIVE_UP then t.n = 0 end
        if t.n < 1 then me.transit[key] = nil end
    end
    Changed()
end

-- /lo forget: drop every "on its way" note (for a piece that was bought and then lost or sold unseen).
-- Not while a bid is out, nor while a bid without an answer may still be answered (until the auction house
-- closes): its note is the only thing that keeps the piece from being bought twice.
function Own.Forget()
    local me = ns.me
    if not me then return false end
    local Scan = ns.Scan
    if Scan and (Scan.buy.pending or next(Scan.buy.late)) then
        if not Scan.buy.pending and Scan.Say then
            Scan.Say("A buy may still be answered. Close the auction house first.", "bad")
        end
        return false
    end
    for key in pairs(me.transit) do DropLate(key) end
    me.transit = {}
    Changed()
    return true
end

-- While the bank is open a change is read once per burst (sorting fires one event per bag): on the next frame,
-- when the burst is over (BAG_UPDATE_DELAYED), when somebody asks for the counts, or as the bank closes.
local function BankChanged()
    dirty = true
    if not bankOpen then return end
    bankDue = true
    if Own.frame then Own.frame:Show() end
end

local function BankNow()
    if bankOpen and bankDue then
        bankDue = false
        ReadBank()
    end
end

local handlers = {
    BAG_UPDATE = BankChanged,
    BAG_UPDATE_DELAYED = function()
        BankChanged()
        BankNow()
    end,
    PLAYER_EQUIPMENT_CHANGED = function() dirty = true end,
    PLAYER_ENTERING_WORLD = function() dirty = true end,
    BANKFRAME_OPENED = function()
        bankOpen, bankDue, dirty = true, false, true
        ReadBank()
    end,
    BANKFRAME_CLOSED = function()
        BankNow()                               -- a change nobody read yet (the bank only keeps what it can read)
        bankOpen, bankDue = false, false
    end,
    PLAYERBANKSLOTS_CHANGED = BankChanged,
    MAIL_SHOW = function()
        local me = ns.me
        mailOpen = true
        visit = { at = GetTime(), top = {}, reads = 0, complete = false, told = false }
        if me then
            Changed()
            for key in pairs(me.transit) do visit.top[key] = (carried[key] or 0) + (me.mail[key] or 0) end
        end
    end,
    MAIL_INBOX_UPDATE = function()
        if not mailOpen or not visit then return end
        visit.reads = visit.reads + 1
        local why
        visit.complete, why = ReadMail()
        local me = ns.me
        if why == "full" and not visit.told and me and next(me.transit) then
            visit.told = true                   -- once per visit: otherwise nothing tells why a piece stays blocked
            local text = "Your mailbox holds more than 50 mails, so pieces on their way cannot be checked until "
                .. "some are taken."
            if ns.Scan and ns.Scan.Say then ns.Scan.Say(text, "bad") end
            if print then print("|cffffd100Level Outfitter:|r " .. text) end
        end
        Arrivals(visit.complete)
    end,
    -- Nothing that never came is concluded from a mailbox that was barely opened (its list may not have loaded) or
    -- whose last look could not tell every piece apart. What was taken into the bags still counts (Arrivals).
    MAIL_CLOSED = function()
        local v = visit
        if not mailOpen or not v then return end
        Arrivals(v.complete)                    -- a piece taken out just before closing
        mailOpen, visit = false, nil
        if v.reads > 0 and v.complete and GetTime() - v.at >= VISIT then Own.Settle() end
    end,
}
Own.handlers = handlers

if CreateFrame then
    local frame = CreateFrame("Frame")
    for event in pairs(handlers) do ns.Listen(frame, event) end
    frame:SetScript("OnEvent", function(_, event, ...)
        local handler = handlers[event]
        if handler then
            handler(...)
            ns.dirty = true
        end
    end)
    -- shown only while a bank change waits to be read: the next frame reads it once
    frame:SetScript("OnUpdate", function(self)
        self:Hide()
        BankNow()
    end)
    frame:Hide()
    Own.frame = frame
end
