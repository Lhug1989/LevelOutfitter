-- Scan.lua: reads the auction house. One sweep of all armor and weapons (kept only for pieces on our lists), then
-- the real listings of the pieces a list wants, and the buyout itself. Based on Alt Outfitter's scan.
-- Nothing here spends gold except Scan.Buy, which the window only calls straight from a mouse click.
--
-- Words used below:
--   row     = one line of the auction house list: an item + suffix, its lowest price and how many are on sale.
--             The lowest price can be a bid, and the suffix only hints at the random stats.
--   listing = one real auction of a row, with its buyout and its item link (which says the exact stats).
--   key     = "itemId:bonusId", the name our lists use for one exact piece.
--   offer   = the cheapest way to get a key right now. offer.read = false while it rests on a row only (a guess):
--             such a piece shows no firm price and cannot be bought until its listings were read.
local ADDON, ns = ...
local Scan = {}
ns.Scan = Scan

local AH = C_AuctionHouse
local GetTime, GetMoney, time = GetTime, GetMoney, time
local pairs, ipairs, type, pcall, sort, remove, insert = pairs, ipairs, type, pcall, table.sort, table.remove, table.insert
local wipe = table.wipe or function(t)
    for k in pairs(t) do t[k] = nil end
    return t
end

local STEP_TIMEOUT, READY_TIMEOUT, VERIFY_TIMEOUT, BUY_TIMEOUT = 10, 30, 5, 6
local GRACE = 2                    -- after an error, a buy still waits this long for news that it went through after all
local WATCH = 10                   -- ... and its piece stays blocked this much longer, unless its auction is seen still on sale
local KEY_POLL, KEY_TIMEOUT = 0.2, 5
local MORE_PAGES, MORE_RETRIES, RECHECK_AFTER_FAIL = 3, 2, 15
local BACK_MAX = 60                -- rows with a suffix no rule explains, read in quiet moments (per scan)

local state = { phase = "idle", message = "", odd = 0, found = 0 }      -- phase: idle | browse
local rows = {}                    -- [row name] = row, from the last finished scan
local verify = { queue = {}, back = {}, hold = 0 }
local buy = { spent = 0, count = 0, late = {} }    -- late[auctionID] = a buy that got no answer but may still land
Scan.state, Scan.rows, Scan.verify, Scan.buy = state, rows, verify, buy
Scan.rev = 0                       -- goes up whenever a row, a listing or a price changed
Scan.BUSY = "One moment..."        -- CanBuy's answer while the auction house still works on an earlier request
Scan.UNSURE = "An earlier buy of this may have gone through. Check your mail first."
Scan.WATCHING = "Making sure the last buy did not go through..."

local driver                       -- its OnUpdate runs Scan.Tick; shown only while there is work
local function Wake()
    if driver then driver:Show() end
end
local function Changed()
    Scan.rev = Scan.rev + 1
    ns.dirty = true
end
-- The status line. tone: "good" (green), "bad" (red) or nil.
local function Say(text, tone)
    state.message, state.tone, state.messageAt = text or "", tone, GetTime()
    ns.dirty = true
end
Scan.Say = Say
local function Ready()
    return AH.IsThrottledMessageSystemReady() == true
end
Scan.Ready = Ready

-- Browse ----------------------------------------------------------------------------------------------
-- Two searches: all armor, all weapons, white to epic. A quality name this game does not know would leave a hole
-- in the filter list, so then no quality filter is sent at all (every quality comes back; pieces that are not on
-- our lists are dropped anyway).
local E = type(Enum) == "table" and Enum or {}
local Filter, Order = E.AuctionHouseFilter or {}, E.AuctionHouseSortOrder or {}
local QUALITY_NAMES = { "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality" }
local QUALITY = {}
for _, name in ipairs(QUALITY_NAMES) do
    if Filter[name] ~= nil then QUALITY[#QUALITY + 1] = Filter[name] end
end
if #QUALITY ~= #QUALITY_NAMES then QUALITY = {} end
Scan.filter = #QUALITY > 0 and "white to epic" or "every quality"
local function Sorts(first, second)
    local list = {}
    if first ~= nil then list[#list + 1] = { sortOrder = first, reverseSort = false } end
    if second ~= nil then list[#list + 1] = { sortOrder = second, reverseSort = false } end
    return list
end
local BROWSE_SORTS, ITEM_SORTS = Sorts(Order.Price, Order.Name), Sorts(Order.Buyout, Order.Bid)
local QUERIES = {
    { label = "armor", query = { searchString = "", sorts = BROWSE_SORTS, filters = QUALITY,
        itemClassFilters = { { classID = 4 } } } },
    { label = "weapons", query = { searchString = "", sorts = BROWSE_SORTS, filters = QUALITY,
        itemClassFilters = { { classID = 2 } } } },
}
Scan.QUERIES = QUERIES
-- the same two searches with no quality filter, for a game that answers nothing when given one
local BARE = {}
for i, q in ipairs(QUERIES) do
    BARE[i] = { label = q.label, query = { searchString = "", sorts = BROWSE_SORTS, filters = {},
        itemClassFilters = q.query.itemClassFilters } }
end

local function KeyString(key)
    return (key.itemID or 0) .. ":" .. (key.itemSuffix or 0) .. ":" .. (key.itemLevel or 0)
end

local function Stop(text, tone)
    state.phase, state.raw, state.seen = "idle", nil, nil
    Say(text, tone)
end

-- A scan that broke off: the rows of the scan before it stay (as old as they were).
local function Abort(text)
    Stop(text, "bad")
    Changed()
end

-- One browse row -> one row of ours, kept only when its item is on the lists.
local function Take(list)
    if type(list) ~= "table" then return end
    local seen, raw, byId = state.seen, state.raw, ns.byId
    for i = 1, #list do
        local r = list[i]
        local key = type(r) == "table" and r.itemKey
        local id = type(key) == "table" and key.itemID
        local price = id and r.minPrice
        if id and byId[id] and type(price) == "number" and price > 0 then
            local ks = KeyString(key)
            if not seen[ks] then
                seen[ks] = true
                local qty = r.totalQuantity
                raw[ks] = { ks = ks, key = key, id = id, suffix = key.itemSuffix or 0, price = price,
                    qty = type(qty) == "number" and qty > 0 and qty or 1 }
                state.found = state.found + 1
            end
        end
    end
end

-- The sweep is over: the new rows replace the old ones.
local function Finish()
    -- nothing came back and part of it timed out: that is no scan at all, so the rows of the scan before it stay
    if state.partial and state.found == 0 then return Abort("The auction house did not answer. Try Scan again.") end
    if state.found == 0 and not state.bare and #QUALITY > 0 then
        -- not one row with the quality filter on: this game may not take it, so the sweep runs once more without
        state.bare = true
        state.qi, state.step, state.waitSince, state.retried, state.moreTries = 1, "send", nil, false, 0
        return
    end
    if state.bare and state.found > 0 and not Scan.bare then
        Scan.bare, Scan.filter = true, "every quality (the quality filter gave nothing)"
    end
    local kept = 0
    if state.partial then
        -- Part of the sweep timed out. What it did not reach is not gone from the auction house: the rows of the
        -- scan before stay for it (they are read again before anything is bought from them). Else a stalled
        -- rescan would drop every weapon it never got to.
        for ks, e in pairs(rows) do
            if not state.raw[ks] then
                state.raw[ks] = e
                kept = kept + 1
            end
        end
    end
    rows = state.raw
    Scan.rows = rows
    state.odd = 0                       -- the count of unmatched listings belongs to the rows it was read from
    for _, e in pairs(rows) do state.odd = state.odd + (e.odd or 0) end      -- (rows kept from before bring theirs)
    local n, back = 0, verify.back
    wipe(back)
    for _, e in pairs(rows) do
        n = n + 1
        local guess, sure = ns.Guess(e.id, e.suffix)
        e.guess = guess
        if not guess and not sure and e.suffix ~= 0 then
            back[#back + 1] = e                 -- only a real listing can say which piece this row is
        end
    end
    sort(back, function(a, b) return a.ks < b.ks end)
    for i = #back, BACK_MAX + 1, -1 do back[i] = nil end
    state.rows, state.scanned, state.scannedAt = n, time(), GetTime()
    local note = state.partial and ((kept > 0) and " Part of the scan timed out: the rest is from the scan before. Scan again for fresh prices."
        or " Part of the scan timed out; scan again for the rest.") or ""
    Stop(("Found %d pieces from the lists on sale.%s"):format(n, note), state.partial and "bad" or "good")
    Changed()
    if #back > 0 then Wake() end
    if ns.OnScanned then ns.OnScanned() end
end

local function NextQuery()
    -- whatever the game holds for this search, including a page whose news was missed while asking again
    if state.step ~= "send" then Take(AH.GetBrowseResults()) end
    state.qi, state.step, state.waitSince, state.retried, state.moreTries = state.qi + 1, "send", nil, false, 0
    if not QUERIES[state.qi] then Finish() end
end

local function AfterPage()
    state.moreTries = 0
    if AH.HasFullBrowseResults() then return NextQuery() end
    state.step, state.waitSince = "more", nil
end

-- A search or a page that did not come: ask again (a few times), else carry on and say the scan is partial.
local function BrowseMissed()
    if state.step == "wait" and not state.retried then
        state.retried, state.step = true, "send"
    elseif state.step == "waitmore" and state.moreTries < MORE_RETRIES then
        state.moreTries, state.step = state.moreTries + 1, "more"
    else
        state.partial = true
        NextQuery()
    end
end

local function BrowseTick(now)
    local step = state.step
    if step == "send" or step == "more" then
        state.waitSince = state.waitSince or now
        if not Ready() then
            if now - state.waitSince > READY_TIMEOUT then
                -- pages already read are good: keep them and say the scan is partial (as a missed page does),
                -- rather than throw the whole sweep away. With nothing found yet there is nothing to keep.
                if step == "more" or state.found > 0 then
                    state.partial = true
                    return NextQuery()
                end
                Abort("The auction house is not answering. Try Scan again.")
            end
            return
        end
        state.waitSince, state.deadline = nil, now + STEP_TIMEOUT
        if step == "send" then
            state.ours = true
            AH.SendBrowseQuery((state.bare and BARE or QUERIES)[state.qi].query)
            state.ours = false
            state.step = "wait"
        else
            AH.RequestMoreBrowseResults()
            state.step = "waitmore"
        end
    elseif now > state.deadline then
        BrowseMissed()
    end
end

function Scan.Start()
    if not ns.Known() then return false end         -- a class without lists: nothing to scan for (the button is grey too)
    if not ns.ahOpen then
        Say("Open the auction house first.", "bad")
        return false
    end
    if state.phase ~= "idle" or buy.pending or (ns.Scroll and ns.Scroll.purchase and ns.Scroll.purchase.state == "buying") then
        return false
    end
    wipe(verify.queue)
    wipe(verify.back)
    verify.current = nil
    state.phase, state.qi, state.step, state.retried, state.moreTries = "browse", 1, "send", false, 0
    state.raw, state.seen, state.partial, state.waitSince, state.found = {}, {}, false, nil, 0
    state.bare = Scan.bare == true
    Say("")
    Changed()
    Wake()
    return true
end

function Scan.Progress()
    if state.phase == "browse" then
        local q = QUERIES[state.qi]
        return ("Scanning %s (%d of %d)...  %d found"):format(q and q.label or "", state.qi, #QUERIES, state.found)
    end
    local left = #verify.queue + (verify.current and 1 or 0)
    if left > 0 then return ("Checking prices...  %d to go"):format(left) end
    return nil
end

-- Offers ------------------------------------------------------------------------------------------------
-- offers[key] = { price, n = how many on sale, listing = the real auction (nil while only guessed), row, read }
-- Built again, in place, whenever something changed. An entry without a price is not on sale.
local offers, offersRev = {}, -1
local function Offers()
    if offersRev == Scan.rev then return offers end
    offersRev = Scan.rev
    for _, o in pairs(offers) do o.price, o.n, o.listing, o.row, o.read, o.first, o.second = nil, 0, nil, nil, false, nil, nil end
    for _, e in pairs(rows) do
        local list = e.listings
        if list then                                    -- read: every listing says exactly which piece it is
            for i = 1, #list do
                local l = list[i]
                local key = l.planKey
                if key then
                    local o = offers[key]
                    if not o then
                        o = { n = 0, read = false }
                        offers[key] = o
                    end
                    o.n = o.n + 1
                    -- the two cheapest read buyouts: a second copy (two rings, two daggers) costs the second one
                    if not o.first or l.price < o.first then
                        o.first, o.second = l.price, o.first
                    elseif not o.second or l.price < o.second then
                        o.second = l.price
                    end
                    local best = o.listing
                    if not o.price or l.price < o.price or (l.price == o.price and (not best or l.auctionID < best.auctionID)) then
                        o.price, o.listing, o.row, o.read = l.price, l, e, true
                    end
                end
            end
        elseif e.guess then                             -- not read yet: the row's lowest price, for the likely piece
            local o = offers[e.guess]
            if not o then
                o = { n = 0, read = false }
                offers[e.guess] = o
            end
            o.n = o.n + e.qty
            if not o.price or e.price < o.price then
                o.price, o.listing, o.row, o.read = e.price, nil, e, false
            end
        end
    end
    return offers
end

-- The cheapest way to get this piece right now, or nil when it is not on sale.
function Scan.Offer(key)
    local o = Offers()[key]
    return o and o.price and o or nil
end

-- For the planner: prices[key] = copper, stock[key] = how many on sale. guessed[key] = true where the price rests on
-- a row that was not read yet. second[key] = what a second copy costs: the second-cheapest read buyout, only known
-- with two read listings and no cheaper unread row. New tables on every call.
function Scan.Tables()
    local prices, stock, guessed, second = {}, {}, {}, {}
    for key, o in pairs(Offers()) do
        if o.price then
            prices[key], stock[key] = o.price, o.n
            if not o.read then
                guessed[key] = true
            elseif o.second then
                second[key] = o.second
            end
        end
    end
    return prices, stock, guessed, second
end

-- Reading the listings of a row -----------------------------------------------------------------------------
function Scan.Fresh(e, now)
    return e.listings ~= nil and e.checkedAt ~= nil and (now or GetTime()) - e.checkedAt < ns.FRESH
end

local function Skip(e, now)
    return Scan.Fresh(e, now) or (e.failedAt ~= nil and now - e.failedAt < RECHECK_AFTER_FAIL)
end

-- The window hands over the pieces it wants checked, most important first.
local queued = {}
function Scan.Want(keys)
    local queue, now, n, all = verify.queue, GetTime(), 0, Offers()
    wipe(queue)
    wipe(queued)
    for i = 1, #keys do
        local o = all[keys[i]]
        local e = o and o.price and o.row
        if e and e ~= verify.current and not queued[e] and not Skip(e, now) then
            queued[e] = true
            n = n + 1
            queue[n] = e
        end
    end
    if n > 0 then Wake() end
    return n
end

-- No new price check starts for this many seconds (the window calls it when the mouse is on a Buy button, so the
-- auction house is free for the click).
function Scan.Hold(seconds)
    local untilTime = GetTime() + (seconds or 3)
    if untilTime > verify.hold then verify.hold = untilTime end
end

-- Answers for an earlier search can arrive after the next one was sent: only an exact match counts.
local function SameKey(a, b)
    return type(a) == "table" and a.itemID == b.itemID and (a.itemSuffix or 0) == (b.itemSuffix or 0)
        and (a.itemLevel or 0) == (b.itemLevel or 0)
end

local function Cheaper(a, b)
    if a.price ~= b.price then return a.price < b.price end
    return a.auctionID < b.auctionID
end

local function VerifyFailed(e, now)
    e.failedAt, verify.current = now, nil
    ns.dirty = true
end

-- Which piece of our lists a listing is, judged by its link alone. nil = not one we may buy: another item, stats
-- the lists do not know, or a link that does not fit the row it is listed under.
local function PieceOf(e, link)
    local key, exact, id, first, count = ns.LinkKey(link)
    if id ~= e.id then return nil end
    if e.suffix ~= 0 and count == 1 and first and first > 0 then
        ns.Learn(e.id, e.suffix, first)                 -- this is what that suffix stands for on this item
    end
    if not key or not exact then return nil end
    if (e.suffix == 0) ~= (ns.item[key].bonus == 0) then return nil end
    return key
end

local StillOnSale                  -- defined with the buying code below

local function ReadListings(e, now, final)
    local key, list, odd = e.key, {}, 0
    for i = 1, tonumber(AH.GetNumItemSearchResults(key)) or 0 do
        local r = AH.GetItemSearchResultInfo(key, i)
        if type(r) == "table" and type(r.auctionID) == "number" then
            -- a fresh answer that still lists an auction we bid on proves that bid bought nothing
            if not final then StillOnSale(e, r.auctionID) end
            local buyout = r.buyoutAmount
            if type(buyout) == "number" and buyout > 0 and r.quantity == 1 and not r.containsOwnerItem
                and not r.containsAccountItem then
                local piece = r.itemLink and PieceOf(e, r.itemLink) or nil
                if not piece then odd = odd + 1 end
                list[#list + 1] = { auctionID = r.auctionID, price = buyout, link = r.itemLink, planKey = piece }
            elseif r.itemLink then
                PieceOf(e, r.itemLink)                  -- even a listing that cannot be bought shows the random stats
            end
        end
    end
    -- An empty page is not proof that nothing can be bought (bid-only listings sort first): read on.
    if #list == 0 and not final and verify.more < MORE_PAGES and not AH.HasFullItemSearchResults(key) then
        verify.more, verify.deadline = verify.more + 1, now + VERIFY_TIMEOUT
        -- like every other request: only when the auction house says it is ready (else the tick sends it)
        if Ready() then AH.RequestMoreItemSearchResults(key) else verify.wantMore = true end
        return
    end
    verify.wantMore = nil
    sort(list, Cheaper)
    e.listings, e.checkedAt, e.failedAt = list, now, nil
    -- counted per row: reading a row again replaces its count instead of adding the same listings once more
    state.odd = state.odd - (e.odd or 0) + odd
    e.odd = odd
    if e.suffix ~= 0 then e.guess = ns.Guess(e.id, e.suffix) end
    verify.current = nil
    Changed()
end

local function VerifyTick(now)
    if not ns.ahOpen or buy.pending then return end
    if ns.Scroll and ns.Scroll.purchase then return end     -- a consumable price or payment is out: no other request now
    local e = verify.current
    if e then
        if verify.sent then
            if verify.wantMore and Ready() then
                verify.wantMore = nil
                AH.RequestMoreItemSearchResults(e.key)
            end
            if now > verify.deadline then
                if (tonumber(AH.GetNumItemSearchResults(e.key)) or 0) > 0 then return ReadListings(e, now, true) end
                VerifyFailed(e, now)
            end
        elseif now >= verify.pollAt then
            -- the server ignores a price search for an item it has not described to us yet
            if AH.GetItemKeyInfo(e.key) then
                if Ready() then
                    verify.sent, verify.deadline, verify.more = true, now + VERIFY_TIMEOUT, 0
                    AH.SendSearchQuery(e.key, ITEM_SORTS, false)
                elseif now > verify.deadline + READY_TIMEOUT then
                    VerifyFailed(e, now)
                end
            elseif now > verify.deadline then
                VerifyFailed(e, now)
            else
                verify.pollAt = now + KEY_POLL
            end
        end
        return
    end
    if now < verify.hold then return end
    local queue = verify.queue
    while queue[1] and Skip(queue[1], now) do remove(queue, 1) end
    e = remove(queue, 1)
    if not e then                           -- nothing wanted: a row whose suffix no rule explains
        local back = verify.back
        while back[1] and (back[1].listings or Skip(back[1], now)) do remove(back, 1) end
        e = remove(back, 1)
    end
    if e then
        verify.current, verify.sent, verify.pollAt, verify.deadline = e, false, now, now + KEY_TIMEOUT
        verify.wantMore = nil
    end
end

-- Buying ------------------------------------------------------------------------------------------------
-- The listing a click would buy right now, or nil and the reason it cannot.
--   expect = the price the player was shown: the buyout must be exactly that.
--   limit  = the most this buy may cost (what the list planned for, and what the gold limit still allows).
function Scan.CanBuy(key, expect, limit, now)
    now = now or GetTime()
    if not ns.ahOpen then return nil, "Open the auction house to buy." end
    if state.phase ~= "idle" then return nil, "Scanning..." end
    if buy.pending then return nil, "Buying..." end
    if Scan.Watching(key) then return nil, Scan.WATCHING end
    if ns.Own.IsUnsure(key) then return nil, Scan.UNSURE end
    local o = Offers()[key]
    if not o or not o.price then return nil, "Sold out." end
    local l, e = o.listing, o.row
    if not o.read or not l or not Scan.Fresh(e, now) then return nil, "Checking the price..." end
    if l.planKey ~= key then return nil, "Sold out." end
    if expect ~= nil and l.price ~= expect then return nil, "The price changed." end
    if limit ~= nil and l.price > limit then return nil, "That costs more than the list allows." end
    if GetMoney() < l.price then return nil, "Not enough gold." end
    if not Ready() then return nil, Scan.BUSY end
    return l, e
end

-- Buys the cheapest listing that is exactly this piece. Call it only from a mouse click.
-- note = whatever the window wants handed back to ns.OnBought once the buy lands.
function Scan.Buy(key, expect, limit, note)
    if type(expect) ~= "number" or type(limit) ~= "number" then return false, "The price changed." end
    local now = GetTime()
    local l, e = Scan.CanBuy(key, expect, limit, now)
    if not l then return false, e end
    local p = { key = key, e = e, auctionID = l.auctionID, price = l.price, deadline = now + BUY_TIMEOUT,
        money = GetMoney(), note = note, unsure = true }
    buy.pending = p
    buy.late[l.auctionID] = nil                 -- an older bid on this very auction is history now
    -- written down (and saved) as "maybe bought" before the bid goes out: a reload or a disconnect in the next
    -- second cannot lose it. The answer turns it into bought, or takes it back.
    ns.Own.Unsure(key, l.price)
    local ok, err = pcall(AH.PlaceBid, l.auctionID, l.price)
    if not ok then
        buy.pending = nil
        ns.Own.Clear(key, l.price)
        Say("The game refused that buy.", "bad")
        return false, "The game refused that buy: " .. tostring(err)
    end
    Say("Buying " .. ns.Name(key) .. "...")
    Wake()
    return true
end

local function Bought(p)
    -- bids still being watched compare the purse with what it held: this purchase is no news about them
    for _, q in pairs(buy.late) do
        if q.watch and q ~= p then q.expect = q.expect - p.price end
    end
    -- ... and neither about the bid in flight (late news of an older bid): else the older bid's gold, gone after
    -- the purse was noted, would make a refused bid look bought
    local cur = buy.pending
    if cur and cur ~= p then cur.money = cur.money - p.price end
    p.watch = nil
    local list = p.e.listings
    if list then
        for i = #list, 1, -1 do
            if list[i].auctionID == p.auctionID then remove(list, i) end
        end
    end
    buy.spent, buy.count = buy.spent + p.price, buy.count + 1
    ns.Own.Bought(p.key, p.price, p.unsure)
    Say("Bought " .. ns.Name(p.key) .. " for " .. ns.Coins(p.price, true) .. ".", "good")
    Changed()
    if ns.OnBought then ns.OnBought(p.key, p.price, p.note) end
end

-- The wait for purchase news is over without any. Other pieces can be bought again; this one stays "maybe
-- bought" (the note written down before the bid), and its auction is remembered so late news still counts.
--   watch = an error came meanwhile, so the bid was probably refused. That is only believed once it is certain:
--           the auction is seen still on sale (StillOnSale), or WATCH seconds pass with no news and the purse
--           untouched (Scan.Tick). Until then the piece stays blocked.
--   else nobody knows: the mailbox will tell.
local function BuyEnded(text, watch)
    local p = buy.pending
    buy.pending = nil
    if not p then return end
    local e = p.e
    e.checkedAt, e.failedAt = nil, nil          -- its listings are read again before anything else is bought from it
    insert(verify.queue, 1, e)
    buy.late[p.auctionID] = p
    if watch then p.watch, p.expect = GetTime() + WATCH, GetMoney() end
    Say(text, "bad")
    Changed()
    Wake()
    if ns.OnBuyFailed then ns.OnBuyFailed(p.key, p.note, true) end
end

-- It is certain that this bid bought nothing: the "maybe" written down for it is taken back.
local function Refused(p)
    p.watch, p.unsure = nil, false
    ns.Own.Clear(p.key, p.price)
    Changed()
    if ns.OnBuyFailed then ns.OnBuyFailed(p.key, p.note, false) end
end

StillOnSale = function(e, auctionID)
    local p = buy.late[auctionID]
    if p and p.watch and p.e.ks == e.ks then Refused(p) end
end

-- true while a bid on this piece is still being watched (see BuyEnded)
function Scan.Watching(key)
    for _, p in pairs(buy.late) do
        if p.watch and p.key == key then return true end
    end
    return false
end

local function AnyWatch()
    for _, p in pairs(buy.late) do
        if p.watch then return true end
    end
    return false
end
Scan.AnyWatch = AnyWatch

-- Gold left the purse for something that is no gear bid (a scroll purchase): bids that compare the purse with
-- what it held must not take that gold for their own price.
function Scan.Outside(amount)
    for _, q in pairs(buy.late) do
        if q.watch then q.expect = q.expect - amount end
    end
    if buy.pending then buy.pending.money = buy.pending.money - amount end
end

-- The watch is over: the purse tells. Exactly the price gone = it went through and the news was lost; untouched =
-- someone else got the auction; anything else tells nothing and the mailbox will.
local function WatchTick(now)
    for auctionID, p in pairs(buy.late) do
        if p.watch and now > p.watch then
            local money = GetMoney()
            if money == p.expect - p.price then
                buy.late[auctionID] = nil
                Bought(p)
            elseif money == p.expect then
                Refused(p)
            else
                p.watch = nil
                Changed()
            end
        end
    end
end

-- The wait for purchase news is over. If exactly the price left the purse, the buy went through and only the news
-- was lost. Else, with an error seen meanwhile, the bid was probably refused (watched until certain); with no
-- error either, nobody knows.
local function NoNews(text)
    local p = buy.pending
    if not p then return end
    if GetMoney() == p.money - p.price then
        buy.pending = nil
        return Bought(p)
    end
    if p.refused then return BuyEnded(p.refused, true) end
    BuyEnded(text, false)
end

-- A "maybe" of this piece was settled at the mailbox: late news about it must not be counted on top.
function Scan.DropLate(key)
    for auctionID, p in pairs(buy.late) do
        if p.key == key then buy.late[auctionID] = nil end
    end
end

-- Auction house errors that mean "your bid was refused", looked up by name (the numbers differ between clients).
-- REFUSED[code] = "gone" when the auction itself is no longer there to buy, else "refused".
local REFUSED
do
    local errors = E.AuctionHouseError
    if type(errors) == "table" then
        for name, kind in pairs({ NotEnoughMoney = "refused", HigherBid = "gone", BidIncrement = "gone",
            BidOwn = "refused", ItemNotFound = "gone", IsBusy = "refused", Unavailable = "gone", MinBid = "gone",
            DatabaseError = "refused", RestrictedAccountTrial = "refused", HasRestriction = "refused" }) do
            if errors[name] ~= nil then
                REFUSED = REFUSED or {}
                REFUSED[errors[name]] = kind
            end
        end
    end
end

-- Events -----------------------------------------------------------------------------------------------------
function Scan.Tick(now)
    now = now or GetTime()
    if state.phase == "browse" then
        BrowseTick(now)
    else
        VerifyTick(now)
    end
    if buy.pending then
        if now > buy.pending.deadline then
            NoNews("No answer from the auction house. Check your mail before buying that one again.")
        end
    elseif AnyWatch() then
        -- never while another bid or a consumable payment is out: the purse would be ambiguous. The driver stays
        -- awake, so the watch is settled once that payment is.
        if not (ns.Scroll and (ns.Scroll.purchase or ns.Scroll.late)) then WatchTick(now) end
    elseif driver and state.phase == "idle" and (not ns.ahOpen or (not verify.current and not verify.queue[1]
        and not verify.back[1])) then
        driver:Hide()                       -- nothing left to do: no per-frame work at all
    end
end

local AH_EVENTS = { "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_BROWSE_FAILURE", "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR", "PLAYER_MONEY" }

local hooked
local function Opened()
    ns.ahOpen = true
    for i = 1, #AH_EVENTS do ns.Listen(driver, AH_EVENTS[i]) end
    if not hooked then
        hooked = true
        -- someone else searching (the game's own window, another addon) throws our sweep's pages away
        pcall(hooksecurefunc, AH, "SendBrowseQuery", function()
            if state.phase == "browse" and not state.ours then
                Abort("Another search started, so the scan stopped. Press Scan again.")
            end
        end)
    end
    if verify.back[1] then Wake() end
    ns.dirty = true
    if ns.OnAuctionHouse then ns.OnAuctionHouse(true) end
end

local function Closed()
    ns.ahOpen = false
    for i = 1, #AH_EVENTS do pcall(driver.UnregisterEvent, driver, AH_EVENTS[i]) end
    if state.phase == "browse" then Abort("The auction house closed before the scan finished.") end
    wipe(verify.queue)
    verify.current = nil
    if buy.pending then
        local name = ns.Name(buy.pending.key)
        local text = "The auction house closed while buying " .. name .. ". Check your mail before buying it again."
        buy.pending.refused = nil               -- an error seen a moment ago proves nothing once the window is gone
        NoNews(text)
        if state.message == text then print("|cffffd100Level Outfitter:|r " .. text) end
    end
    wipe(verify.queue)
    wipe(buy.late)                          -- purchase news only arrives while the auction house is open
    Changed()
    if ns.OnAuctionHouse then ns.OnAuctionHouse(false) end
end

local function BrowsePage(list)
    if state.phase ~= "browse" or (state.step ~= "wait" and state.step ~= "waitmore") then return end
    Take(list)
    AfterPage()
    ns.dirty = true
end

local function SearchResults(itemKey)
    local e = verify.current
    if e and verify.sent and SameKey(itemKey, e.key) then ReadListings(e, GetTime()) end
end

local handlers = {
    AUCTION_HOUSE_SHOW = Opened,
    AUCTION_HOUSE_CLOSED = Closed,
    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function() BrowsePage(AH.GetBrowseResults()) end,
    AUCTION_HOUSE_BROWSE_RESULTS_ADDED = BrowsePage,
    AUCTION_HOUSE_BROWSE_FAILURE = function()
        -- only a search that is still waiting for its answer can have failed
        if state.phase ~= "browse" or (state.step ~= "wait" and state.step ~= "waitmore") then return end
        BrowseMissed()
    end,
    ITEM_SEARCH_RESULTS_UPDATED = SearchResults,
    ITEM_SEARCH_RESULTS_ADDED = SearchResults,
    AUCTION_HOUSE_PURCHASE_COMPLETED = function(auctionID)
        local p = buy.pending
        if p and p.auctionID == auctionID then
            buy.pending = nil
            buy.late[auctionID] = nil
            Bought(p)
        elseif auctionID ~= nil and buy.late[auctionID] then
            p, buy.late[auctionID] = buy.late[auctionID], nil
            Bought(p)
        end
    end,
    AUCTION_HOUSE_SHOW_ERROR = function(err)
        -- An error carries no auction id, so it may be about something else (a post, another addon, an earlier
        -- buy). It therefore never ends the buy by itself: the buy waits a moment longer for purchase news, then
        -- checks the purse, and only then believes the refusal. An error that is no bid refusal is ignored (a
        -- client without error names counts every error as one).
        local p = buy.pending
        if p and not p.refused and (not REFUSED or err == nil or REFUSED[err]) then
            local gone = REFUSED and err ~= nil and REFUSED[err] == "gone"
            p.refused = gone and "That one was already gone. Checking the next cheapest..."
                or "The auction house refused that buy. Checking the price again..."
            local soon = GetTime() + GRACE
            if soon < p.deadline then p.deadline = soon end
            Wake()
        end
    end,
    PLAYER_MONEY = function() ns.dirty = true end,
}
Scan.handlers = handlers

-- What /lo status prints.
function Scan.Status()
    local out = { ("Auction house search: %s. %d pieces from the lists on sale at the last scan."):format(Scan.filter,
        state.rows or 0) }
    if state.odd > 0 then
        out[#out + 1] = ("%d listings could not be matched to a piece on the lists (they cannot be bought here)."):format(state.odd)
    end
    if buy.count > 0 then
        out[#out + 1] = ("Bought %d pieces for %s since logging in."):format(buy.count, ns.Coins(buy.spent, true))
    end
    return out
end

if CreateFrame then
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:RegisterEvent("AUCTION_HOUSE_SHOW")
    driver:RegisterEvent("AUCTION_HOUSE_CLOSED")
    driver:SetScript("OnEvent", function(_, event, ...)
        local handler = handlers[event]
        if handler then handler(...) end
    end)
    driver:SetScript("OnUpdate", function() Scan.Tick(GetTime()) end)
    Scan.frame = driver
end
