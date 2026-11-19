-- Scroll.lua: the things worth using up while leveling (stat scrolls, elixirs, potions, weapon stones, food),
-- the best one of each kind for each level, their live prices, and buying them. (The file and its saved fields
-- are named after the scrolls it started with.)
--
-- These things stack, and the auction house sells stackable things differently from gear: one price list per
-- item ("so many at this price each"), the game quotes a total for the amount wanted, and the purchase is
-- confirmed at that quote. The game wants a separate input from the player for each of the two: asking, and
-- paying. One click is two inputs, the press and the release: pressing "Buy 20" asks for the quote, letting go
-- pays it when it has come and is no more than the total the button showed. A quote that comes later, or is
-- dearer, goes on the button as "Pay" and the next click pays the total then shown. The calls are the ones
-- NaowhForever's market window makes on this game. This gold is counted on its own (me.scrollSpent); it is not
-- part of the gear gold limit.
--
-- The game's answers (a quote, "paid", "not paid") do not say which request they belong to. So there is never
-- more than one request out, a new one waits until an unanswered one cannot answer any more, a quote must fit
-- the prices that were read, and after a payment nobody answered nothing more is bought until that is settled.
local ADDON, ns = ...
local Scroll = {}
ns.Scroll = Scroll

local AH, Scan = C_AuctionHouse, ns.Scan
local GetTime, GetMoney, time = GetTime, GetMoney, time
local pairs, ipairs, type, pcall, tonumber, sort, max, min, ceil, floor = pairs, ipairs, type, pcall, tonumber, table.sort,
    math.max, math.min, math.ceil, math.floor

local AMOUNTS = { 5, 10, 20, 40 }  -- a click on a row's amount steps through these
local KEY_POLL, KEY_TIMEOUT, READ_TIMEOUT, RETRY_AFTER, READY_TIMEOUT = 0.2, 5, 5, 15, 30
local QUOTE_TIMEOUT = 6            -- seconds to wait for the game's price quote
local QUIET = 15                   -- after a quote request nobody answered, no new one for this long (its answer may be late)
local PAY_WINDOW = 12              -- seconds a quote waits for the Pay click before it is let go
local PAY_TIMEOUT = 10             -- seconds to wait for the answer to a payment
local ARM = 0.4                    -- a total dearer than the Buy button said must have been on screen this long before a Pay click counts
local REST = 1.5                   -- after a purchase nothing new is asked for this long (a click too many must not buy again)
local LATE_FOR = 15                -- an unanswered payment is kept at least this long, even when the auction house is reopened
local GHOST_FOR = 120              -- a payment buying no longer waits for is still counted if "paid" comes within this long
local OVER, UNDER = 1.05, 0.8      -- a quote must lie between 80% and 105% of the total by the prices that were read

local E = type(Enum) == "table" and Enum or {}
local order = E.AuctionHouseSortOrder and E.AuctionHouseSortOrder.Price
local SORTS = order ~= nil and { { sortOrder = order, reverseSort = false } } or {}
local EVENTS = { "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "PLAYER_MONEY" }
Scroll.UNSURE = "A payment got no clear answer. Check your mail, then open the auction house again."
Scroll.WAITING = "Waiting for news of an earlier payment (two minutes at most)."

-- What there is -----------------------------------------------------------------------------------------------
-- byId[id]     = { id, name, kind, rank, req }      rank 1 = the weakest of its kind, req = usable from this level
-- byKind[kind] = those of one kind, by rank
-- kinds        = the kinds on show, most important first: { name, perHour = used per hour of play, note }
local byId, byKind, kinds, kindInfo = {}, {}, {}, {}
for _, c in ipairs(ns.DATA.consumables or {}) do
    local item = { id = c[1], name = c[2], kind = c[3], rank = c[4], req = c[5] }
    byId[item.id] = item
    byKind[item.kind] = byKind[item.kind] or {}
    byKind[item.kind][item.rank] = item
end
for _, k in ipairs(ns.DATA.kinds or {}) do
    kindInfo[k[1]] = { name = k[1], perHour = k[2], note = k[3] ~= "" and k[3] or nil }
end
Scroll.byId, Scroll.byKind, Scroll.kinds = byId, byKind, kinds

-- Which kinds are shown, in this order (the class's own list from the data unless told otherwise).
function Scroll.SetKinds(names)
    for i = #kinds, 1, -1 do kinds[i] = nil end
    local C = ns.ClassData and ns.ClassData()
    for _, name in ipairs(names) do
        -- a kind for some specs only (spell damage, a school's elixir): shown for those (ns.spec, from Forever
        -- Leveling BiS)
        local only, fits = C and C.specKinds and C.specKinds[name], true
        if only then
            fits = false
            for _, sp in ipairs(only) do fits = fits or sp == ns.spec end
        end
        if byKind[name] and fits then
            local info = kindInfo[name] or { name = name, perHour = 2 }
            local note = C and C.notes and C.notes[name]       -- the class's own words (the rogue's: the data's)
            if note then info = { name = info.name, perHour = info.perHour, note = note } end
            kinds[#kinds + 1] = info
        end
    end
    ns.dirty = true
end
-- The character's class's kinds (Data.lua classes.<CLASS>.kinds); none for a class without lists.
function Scroll.ForClass()
    local C = ns.ClassData and ns.ClassData()
    Scroll.SetKinds(C and C.ready and C.kinds or {})
end
Scroll.ForClass()

-- [id] = { rows = { { price, quantity }, ... cheapest first }, at, commodity, noAnswer }
--   commodity = false: the game says this item is not sold by price list
--   noAnswer  = true : the price list could not be read; shown as "none on sale" and asked again soon
local books = {}
local wanted = {}                  -- ids the window has on show
local passed = {}                  -- sold out ones a stand-in was looked for below: not on show, but read again all the same
local reads = {}                   -- the price list being asked for: { id, key, sent, pollAt, deadline }
Scroll.books = books

local driver
local function Wake()
    if driver then driver:Show() end
end

-- The level an item can be used from. The game decides that, so its own word (a level from 1 to 60) counts once
-- it has described the item (asked for at most every REQ_ASK seconds); until then, and when it says nothing
-- sensible, the list's level.
local REQ_ASK = 2
local reqSeen, reqAsked = {}, {}
local function Req(item)
    local seen = reqSeen[item.id]
    if seen then return seen end
    local now = GetTime()
    if reqAsked[item.id] and now - reqAsked[item.id] < REQ_ASK then return item.req end
    reqAsked[item.id] = now
    local info = type(C_Item) == "table" and C_Item.GetItemInfo or GetItemInfo
    if type(info) ~= "function" then return item.req end
    local ok, _, _, _, _, level = pcall(info, item.id)
    if ok and type(level) == "number" and level >= 1 and level <= 60 then    -- (0 says nothing: the list's level stands)
        seen = floor(level)
        reqSeen[item.id] = seen
        return seen
    end
    return item.req
end
Scroll.Req = Req

-- The best of one kind at a level: the highest rank that can be used yet (nil when none can).
local function BestAt(list, level)
    local best
    for _, item in ipairs(list) do
        if Req(item) <= level and (not best or item.rank > best.rank) then best = item end
    end
    return best
end

-- None on sale, by the last look at its price list. (A list that was never read says nothing either way, and a
-- thing this game sells as single auctions has no price list to go by.)
local function SoldOut(id)
    local b = books[id]
    return b ~= nil and b.commodity ~= false and #b.rows == 0
end

-- A weaker one is only shown when none of the better one is on sale: then the next one down of its kind that
-- can be used and is not sold out as well stands in for it. (One whose price list was not read yet counts: it
-- goes on show, gets read, and makes way for the next one down when it has none either.)
local function StandIn(list, best, level)
    if not SoldOut(best.id) then return nil end
    for rank = best.rank - 1, 1, -1 do
        local item = list[rank]
        if item and Req(item) <= level then
            if not SoldOut(item.id) then return item end
            passed[#passed + 1] = item.id   -- sold out too: kept an eye on, so it can step in when some are put up
        end
    end
end

-- The level segment's rows, for the window: for each kind the best one, for the levels it is the best one (from
-- the character's level on).
-- row = { id, name, kind, rank, from, to, perHour, note, instead }   (the same table every time, so the window can
-- hold on to it). instead = the name of the better one this row stands in for while that one is sold out.
local rowCache = {}
local function Row(item, from, to, k, kind, better)
    local name = item.id .. ":" .. from .. ":" .. to .. (better and ":" .. better.id or "")
    local row = rowCache[name]
    if not row then
        row = { id = item.id, name = item.name, kind = item.kind, rank = item.rank, from = from, to = to,
                instead = better and better.name or nil }
        rowCache[name] = row
    end
    row.order, row.perHour, row.note = k, kind.perHour, kind.note
    return row
end

function Scroll.Rows(s)
    local seg, out = ns.SEGMENTS[s], {}
    for i = #passed, 1, -1 do passed[i] = nil end
    if not seg then return out end
    local now = ns.Level()
    local lo, hi = max(seg[1], now), seg[2]
    for k, kind in ipairs(kinds) do
        local list, item, from = byKind[kind.name], nil, nil
        for level = lo, hi + 1 do
            local best = level <= hi and BestAt(list, level) or nil
            if best ~= item then
                if item then
                    out[#out + 1] = Row(item, from, level - 1, k, kind)
                    -- the one in use right now is sold out: the next one down stands in
                    local weaker = from == now and StandIn(list, item, now)
                    if weaker then out[#out + 1] = Row(weaker, from, level - 1, k, kind, item) end
                end
                item, from = best, level
            end
        end
    end
    sort(out, function(a, b)
        if a.from ~= b.from then return a.from < b.from end
        if a.order ~= b.order then return a.order < b.order end
        return a.instead == nil and b.instead ~= nil       -- a stand-in comes right after the one it stands in for
    end)
    return out
end

-- What the character can use right now: for each kind the best one at its level, for the levels until a better
-- one of that kind opens up. Nothing it is too low for yet, and nothing weaker than the best unless that one is
-- sold out (then the next one down, right after it).
function Scroll.Usable()
    local out, level, top = {}, ns.Level(), ns.DATA.P.levels
    for i = #passed, 1, -1 do passed[i] = nil end
    for k, kind in ipairs(kinds) do
        local list = byKind[kind.name]
        local best, to = BestAt(list, level), top
        if best then
            for _, item in ipairs(list) do
                local req = Req(item)
                if item.rank > best.rank and req - 1 < to then to = req - 1 end
            end
            to = max(level, to)
            out[#out + 1] = Row(best, level, to, k, kind)
            local weaker = StandIn(list, best, level)
            if weaker then out[#out + 1] = Row(weaker, level, to, k, kind, best) end
        end
    end
    return out
end

-- How many the levels from..to use up, by the planner's guess of the hours they take (level 60 has no end, so it
-- counts as nothing here) and how many go per hour, rounded down to one of the amounts and never more than 20.
function Scroll.Suggest(from, to, perHour)
    local P, hours = ns.DATA.P, 0
    for level = from, min(to, P.levels - 1) do hours = hours + P.hours0 * P.hoursGrow ^ level end
    local n, pick = ceil(hours * (perHour or 2)), AMOUNTS[1]
    for _, a in ipairs(AMOUNTS) do
        if a <= n and a <= 20 then pick = a end
    end
    return pick
end

function Scroll.Amount(row)
    local saved = ns.me and ns.me.scrollAmount[row.id]
    return saved or Scroll.Suggest(row.from, row.to, row.perHour)
end

-- A click on the amount: the next one of 5, 10, 20, 40.
function Scroll.CycleAmount(row)
    local me = ns.me
    if not me then return end
    local now, pick = Scroll.Amount(row), AMOUNTS[1]
    for i, a in ipairs(AMOUNTS) do
        if a == now then pick = AMOUNTS[i + 1] or AMOUNTS[1] end
    end
    me.scrollAmount[row.id] = pick
    ns.dirty = true
    return pick
end

-- What `want` of this scroll cost by its price list, cheapest first: total, and how many of them are on sale.
local function Cost(id, want)
    local b, total, got = books[id], 0, 0
    if not b then return 0, 0 end
    for _, r in ipairs(b.rows) do
        local take = min(want - got, r.quantity)
        if take > 0 then
            total, got = total + take * r.price, got + take
        end
        if got >= want then break end
    end
    return total, got
end
Scroll.Cost = Cost

-- Where a scroll row stands; then how many a click would buy, for what total, the price each of the cheapest,
-- and whether fewer are on sale than wanted:
--   "checking"  its price list was not read yet          "gone"     none on sale
--   "manual"    this game sells it as single auctions, not by price list: buy it in the auction window
--   "unsure"    a payment for it got no clear answer: check the mail
--   "ready"     prices known                             "quoting"  waiting for the game's quote
--   "quoted"    the quote is on the button, a Pay click buys            "buying"   the payment is out
function Scroll.State(row)
    local id, p, late = row.id, Scroll.purchase, Scroll.late
    local b = books[id]
    local each = b and b.rows[1] and b.rows[1].price or nil
    if p and p.id == id then return p.state, p.qty, p.total or p.expected, each, false end
    if late and late.id == id then return "unsure" end
    if not b then return "checking" end
    if b.commodity == false then return "manual" end
    if #b.rows == 0 then return "gone" end
    local want = Scroll.Amount(row)
    local total, got = Cost(id, want)
    return "ready", got, total, each, got < want
end

-- Reading price lists -----------------------------------------------------------------------------------------
local function KeyOf(id)
    if AH.MakeItemKey then
        local ok, key = pcall(AH.MakeItemKey, id)
        if ok and type(key) == "table" then return key end
    end
    return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function Fresh(id, now)
    local b = books[id]
    return b ~= nil and b.at ~= nil and now - b.at < (b.noAnswer and RETRY_AFTER or ns.FRESH)
end

-- No answer (the item is not described yet, the auction house is busy, or it has none and stays silent): it
-- shows as "none on sale" and is asked again soon. Only the game saying so makes an item "not sold by price list".
local function ReadFailed(id, now)
    books[id] = { rows = {}, at = now, commodity = true, noAnswer = true }
    reads.id = nil
    ns.dirty = true
end

local function ReadBook(id, now)
    local rows = {}
    for i = 1, tonumber(AH.GetNumCommoditySearchResults(id)) or 0 do
        local r = AH.GetCommoditySearchResultInfo(id, i)
        if type(r) == "table" and type(r.unitPrice) == "number" and r.unitPrice > 0 and type(r.quantity) == "number" then
            local mine = type(r.numOwnerItems) == "number" and r.numOwnerItems or 0     -- our own cannot be bought
            if r.quantity - mine > 0 then rows[#rows + 1] = { price = r.unitPrice, quantity = r.quantity - mine } end
        end
    end
    sort(rows, function(a, b) return a.price < b.price end)
    books[id] = { rows = rows, at = now, commodity = true }
    reads.id = nil
    ns.dirty = true
end

-- The window hands over the scrolls it has on show.
function Scroll.Want(ids)
    for i = #wanted, 1, -1 do wanted[i] = nil end
    for i = 1, #ids do wanted[i] = ids[i] end
    if #wanted > 0 then
        Wake()
    else
        for i = #passed, 1, -1 do passed[i] = nil end      -- nothing on show: nothing is read
    end
end

local function Due(id, now)
    local b = books[id]
    return byId[id] ~= nil and not Fresh(id, now) and not (b and b.commodity == false)
end

-- What is on show comes first; then the sold out ones a stand-in was looked for below.
local function NextRead(now)
    for i = 1, #wanted do
        if Due(wanted[i], now) then return wanted[i] end
    end
    for i = 1, #passed do
        if Due(passed[i], now) then return passed[i] end
    end
end

local function ReadTick(now)
    local id = reads.id
    if id then
        if reads.sent then
            if now > reads.deadline then ReadFailed(id, now) end
        elseif now >= reads.pollAt then
            -- the server ignores a price search for an item it has not described to us yet
            local info = AH.GetItemKeyInfo(reads.key)
            if info then
                if type(info) == "table" and info.isCommodity == false then
                    books[id] = { rows = {}, at = now, commodity = false }
                    reads.id = nil
                    ns.dirty = true
                elseif Scan.Ready() then
                    reads.sent, reads.deadline = true, now + READ_TIMEOUT
                    AH.SendSearchQuery(reads.key, SORTS, true)
                elseif now > reads.deadline + READY_TIMEOUT then
                    ReadFailed(id, now)
                end
            elseif now > reads.deadline then
                ReadFailed(id, now)
            else
                reads.pollAt = now + KEY_POLL
            end
        end
        return
    end
    -- gear price checks and the mouse resting on a Buy button come first
    if Scan.verify.current or now < Scan.verify.hold then return end
    id = NextRead(now)
    if id then
        reads.id, reads.key, reads.sent, reads.pollAt, reads.deadline = id, KeyOf(id), false, now, now + KEY_TIMEOUT
    end
end

-- Buying --------------------------------------------------------------------------------------------------------
-- Scroll.purchase = { id, row, qty, expected, state, deadline, total, unit, quotedAt, money }
--   expected = the total by the price list when Buy was clicked.
-- Scroll.late     = a payment nobody answered: it may still go through. Nothing more is bought until the game
--                   says how it ended, the purse shows it, or the auction house is opened again.
local function Stale(id)
    local b = books[id]
    if b then b.at = nil end           -- read again before anything else is bought from it
    Wake()
end

-- Lets a price request go. quiet = its answer has not come yet and may still arrive: no new request for a while,
-- so that late answer cannot be taken for the next one's.
local function Cancel(text, quiet)
    local p = Scroll.purchase
    Scroll.purchase = nil
    if p and (p.state == "quoting" or p.state == "quoted") then
        if AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
        if quiet then Scroll.quietUntil = GetTime() + QUIET end
    end
    if p then Stale(p.id) end
    if text then Scan.Say(text, "bad") end
    ns.dirty = true
end

function Scroll.Busy()
    return Scroll.purchase ~= nil
end

-- A payment buying no longer waits for (Scroll.ghost) whose answer may still come. Its answer would be taken for
-- the next payment's ("paid" and "not paid" do not say which payment they mean), so none is started meanwhile.
local function Haunts(g, now)
    return g ~= nil and (now or GetTime()) - g.ghostAt < GHOST_FOR
end

-- True while an earlier payment may still be answered (no news came for it yet): nothing else may be bought then,
-- gear neither (Shop.CanBuy asks), or the purse could no longer tell which payment went through.
function Scroll.Unsettled(now)
    return Scroll.late ~= nil or Haunts(Scroll.ghost, now)
end

-- Whether exactly this payment's total has left the purse. "Paid" news alone does not say whose it is: it also
-- comes for a buy made by hand or by another addon.
local function Spent(p)
    return GetMoney() == p.money - p.total
end

-- The purse moved while payment x has no answer. True when exactly its total left: it was paid after all. Any
-- other change (loot, a sale, gold from the mailbox the player was sent to) moves along what the purse would show
-- had it been paid, so the payment is still known when its gold leaves later.
local function Moved(x)
    local now = GetMoney()
    if now == x.money - x.total then return true end
    x.money = x.money + (now - (x.purse or x.money))
    x.purse = now
    return false
end

-- The window moved on (another tab, another view, another amount, closed): a quote nobody can pay any more is
-- let go. A payment already out runs its course.
function Scroll.Leave()
    local p = Scroll.purchase
    if p and p.state ~= "buying" then Cancel(nil, p.state == "quoting") end
end

-- Whether a click on this row's Buy button would ask for a quote right now: true, the total and the amount, or
-- false and why.
function Scroll.CanBuy(row, now)
    now = now or GetTime()
    if not ns.me then return false, "Nothing to buy." end
    -- a kind no longer listed (a new spec dropped it) before the window drew again: not bought
    local listed = false
    for i = 1, #kinds do listed = listed or kinds[i].name == row.kind end
    if not listed then return false, "The list changed." end
    if not ns.ahOpen then return false, "Open the auction house to buy." end
    if Scan.state.phase ~= "idle" then return false, "Scanning..." end
    if Scan.buy.pending or Scroll.purchase then return false, "Buying..." end
    if Scroll.late then return false, Scroll.UNSURE end
    if Haunts(Scroll.ghost, now) then return false, Scroll.WAITING end  -- an old payment can still answer: wait for it
    if Scan.AnyWatch() then return false, Scan.WATCHING end     -- a gear bid is being settled by the purse: no other spending now
    local state, qty, total = Scroll.State(row)
    if state ~= "ready" then return false, "Checking the price..." end
    if not Fresh(row.id, now) then return false, "Checking the price..." end
    if qty < 1 or total < 1 then return false, "Sold out." end
    if GetMoney() < total then return false, "Not enough gold." end
    if now < (Scroll.quietUntil or 0) then return false, Scan.BUSY end
    if now < (Scroll.restUntil or 0) then return false, Scan.BUSY end
    if not Scan.Ready() then return false, Scan.BUSY end
    return true, total, qty
end

-- Whether a press of the mouse button may already ask for the price (so that letting go can pay): yes, until this
-- game has shown that it takes no such call from a press. "/lo press" tries again.
function Scroll.Press()
    return not (ns.db and ns.db.pressBuy == false)
end

-- Asks the game what `qty` of this scroll cost right now. shown = the total the button showed; press = this came
-- from the press of the mouse button, not from a full click.
function Scroll.Buy(row, shown, press)
    if not ns.Known() then return false, "Level Outfitter has no lists for this class yet." end    -- (no rows either)
    local ok, total, qty = Scroll.CanBuy(row)
    if not ok then return false, total end
    if type(shown) ~= "number" or shown ~= total then return false, "The price changed." end
    reads.id = nil                      -- a price list still being asked for is asked again later
    Scroll.purchase = { id = row.id, row = row, qty = qty, expected = total, state = "quoting",
        deadline = GetTime() + QUOTE_TIMEOUT, press = press and true or nil }
    local called, err = pcall(AH.StartCommoditiesPurchase, row.id, qty)
    if not called then
        Scroll.purchase = nil
        return false, "The game refused that: " .. tostring(err)
    end
    Scan.Say(("Asking the price for %d x %s..."):format(qty, row.name))
    ns.dirty = true
    Wake()
    return true
end

-- The mouse button went down on this row's button. When that is a Pay button whose total has been on show for a
-- moment, the release that follows may pay a total dearer than the Buy button said (see Scroll.Pay).
function Scroll.Pressed(row)
    Scroll.pressSeen = true                 -- this game tells of the press of a mouse button
    local p = Scroll.purchase
    if p and p.id == row.id and p.state == "quoted" and GetTime() - p.quotedAt >= ARM then p.again = true end
end

-- Pays the quoted total. shown = the total the button showed. A quote of no more than the total the Buy button
-- showed was agreed to with that first click and is paid as it is. A dearer one is only paid once it has been
-- on the Pay button for a moment, at exactly the total shown there, and by a click of its own.
function Scroll.Pay(row, shown)
    local p, me, now = Scroll.purchase, ns.me, GetTime()
    if not me or not p or p.id ~= row.id or p.state ~= "quoted" then return false, "Press Buy first." end
    if p.total > p.expected then
        if type(shown) ~= "number" or shown ~= p.total then return false, "The price went up. Press Pay to buy at the new total." end
        if now - p.quotedAt < ARM then return false, Scan.BUSY end
        -- ... and by a click of its own: the mouse button must have gone down while that total was on show. The
        -- release of a press made earlier never pays it, however long the button was held. (A game that never
        -- tells of a press is left with the two rules above.)
        if (p.press or Scroll.pressSeen) and not p.again then return false, "The price went up. Press Pay to buy at the new total." end
    end
    if not ns.ahOpen then return false, "Open the auction house to buy." end
    if Scan.buy.pending or Scan.AnyWatch() then return false, "Buying..." end
    if Scroll.late or Haunts(Scroll.ghost, now) then   -- (Buy already waits for these; this is the last door)
        Cancel()
        return false, Scroll.late and Scroll.UNSURE or Scroll.WAITING
    end
    if GetMoney() < p.total then
        Cancel()
        return false, "Not enough gold."
    end
    p.state, p.money, p.deadline = "buying", GetMoney(), now + PAY_TIMEOUT
    Scroll.ghost = nil                      -- an old payment too old to answer now: from here on an answer is this one's
    -- written down before the payment goes out, so a reload cannot lose it without a trace
    me.scrollPending = { id = p.id, qty = p.qty, total = p.total, at = time() }
    local called, err = pcall(AH.ConfirmCommoditiesPurchase, p.id, p.qty)
    if not called then
        me.scrollPending = nil
        p.state = "quoted"
        Cancel()
        return false, "The game refused that: " .. tostring(err)
    end
    Scan.Say(("Buying %d x %s..."):format(p.qty, row.name))
    ns.dirty = true
    Wake()
    return true
end

-- p is the purchase that was paid: the one out, or the one nobody had answered.
local function Paid(p)
    local me = ns.me
    if Scroll.purchase == p then Scroll.purchase = nil end
    if Scroll.late == p then Scroll.late = nil end
    if Scroll.ghost == p then Scroll.ghost = nil end
    if me then
        me.scrollSpent = me.scrollSpent + p.total
        me.scrollBought[p.id] = (me.scrollBought[p.id] or 0) + p.qty
        me.scrollPending = nil
    end
    Scan.Outside(p.total)               -- gear bids that watch the purse must not take this gold for their own price
    Scroll.restUntil = GetTime() + REST
    Stale(p.id)
    Scan.Say(("Bought %d x %s for %s."):format(p.qty, p.row.name, ns.Coins(p.total, true)), "good")
    ns.dirty = true
end

local function NotPaid(p, text)
    if Scroll.purchase == p then Scroll.purchase = nil end
    if Scroll.late == p then Scroll.late = nil end
    if Scroll.ghost == p then Scroll.ghost = nil end
    if ns.me then ns.me.scrollPending = nil end
    Stale(p.id)
    Scan.Say(text, "bad")
    ns.dirty = true
end

-- A payment that buying no longer waits for (the auction house was opened again and its time ran out) can still
-- be answered much later. It is remembered for a while, so that "paid" is counted all the same. The while runs
-- from the moment its answer went missing, not from now: a payment minutes old holds nothing up any more.
local function Ghost(p)
    p.ghostAt = p.lateAt or GetTime()
    Scroll.ghost = p
end

-- A payment got no answer in time. If exactly the total left the purse it was paid and only the news was lost.
-- Else nobody knows: it may still go through, so it is kept (Scroll.late) and nothing more is bought until the
-- game says how it ended, the purse shows it, or the auction house is opened again.
local function NoAnswer(p, text)
    if GetMoney() == p.money - p.total then return Paid(p) end
    Scroll.purchase = nil
    Scroll.late = p
    p.lateAt, p.reopened = GetTime(), nil
    Scan.Say(text or "No answer from the auction house. Check your mail before buying more.", "bad")
    ns.dirty = true
end

function Scroll.Tick(now)
    now = now or GetTime()
    local p = Scroll.purchase
    if p then
        if (p.state == "quoting" or p.state == "quoted") and (Scan.state.phase ~= "idle" or Scan.buy.pending) then
            Cancel(nil, p.state == "quoting")   -- something else needs the auction house
        elseif now > p.deadline then
            if p.state == "quoting" then
                local text = "No answer from the auction house. Try again in a moment."
                if p.press and ns.db and ns.db.pressBuy == nil then
                    -- a price asked for from the press of the button got no answer. Once can be a slow moment;
                    -- twice in a row, with never an answer to one, means this game only takes it from a full
                    -- click: from here on Buy asks on the click, and Pay pays.
                    ns.db.pressMiss = (tonumber(ns.db.pressMiss) or 0) + 1
                    if ns.db.pressMiss >= 2 then
                        ns.db.pressBuy, ns.db.pressMiss = false, nil
                        text = "No answer from the auction house. From now on: click Buy, then click Pay."
                    end
                end
                Cancel(text, true)
            elseif p.state == "quoted" then
                Cancel()                        -- nobody pressed Pay: the quote is let go
            else
                NoAnswer(p)
            end
        end
    elseif ns.ahOpen and Scan.state.phase == "idle" and not Scan.buy.pending and not Scroll.late then
        ReadTick(now)
    end
    -- reopened with an unanswered payment still young: it gets its time, then buying is open again
    local late = Scroll.late
    if late and late.reopened and now - late.lateAt >= LATE_FOR then
        Scroll.late = nil
        Ghost(late)
        if ns.me then ns.me.scrollPending = nil end
        ns.dirty = true
    end
    if driver and not Scroll.purchase and not reads.id and not (Scroll.late and Scroll.late.reopened)
        and not (ns.ahOpen and not Scroll.late and NextRead(now)) then
        driver:Hide()
    end
end

local handlers = {
    AUCTION_HOUSE_SHOW = function()
        -- a payment nobody answered: the purse settles it now if it can; either way buying is open again (the
        -- player was told to check the mail)
        local late = Scroll.late
        if late then
            if GetMoney() == late.money - late.total then
                Paid(late)
            elseif GetTime() - late.lateAt >= LATE_FOR then
                Scroll.late = nil
                Ghost(late)
                if ns.me then ns.me.scrollPending = nil end
            else
                late.reopened = true        -- closed and opened again in a hurry: its answer may still be on its way
                Wake()
            end
        end
        -- (the quiet time after an unanswered price request runs on: its answer may still be on its way)
        if #wanted > 0 then Wake() end
        ns.dirty = true
    end,
    AUCTION_HOUSE_CLOSED = function()
        local p = Scroll.purchase
        if p and p.state == "buying" then
            NoAnswer(p, ("The auction house closed while paying for %d x %s. Check your mail."):format(p.qty, p.row.name))
        elseif p then
            Cancel(nil, p.state == "quoting")
        end
        reads.id = nil
        ns.dirty = true
    end,
    COMMODITY_SEARCH_RESULTS_UPDATED = function(itemID)
        if reads.id and reads.sent and itemID == reads.id then ReadBook(itemID, GetTime()) end
    end,
    -- The game's quote. It does not say what it is for, so it only counts while exactly one request is waiting for
    -- it, and only when it fits the prices that were read. Any quote that arrives once a total is on the Pay
    -- button means prices moved: the purchase starts over rather than change the total under the mouse.
    COMMODITY_PRICE_UPDATED = function(unit, total)
        local p = Scroll.purchase
        if not p then return end
        if p.state == "quoted" then
            if total ~= p.total then Cancel("The price changed. Checking it again...") end
            return
        end
        if p.state ~= "quoting" then return end
        if p.press and ns.db then ns.db.pressBuy, ns.db.pressMiss = true, nil end   -- this game answers a price asked for from the press
        if type(total) ~= "number" or total < 1 or total > p.expected * OVER then
            return Cancel("The price went up. Checking it again...")
        end
        if total < p.expected * UNDER then return Cancel("The price changed. Checking it again...") end
        local now = GetTime()
        p.state, p.total, p.unit, p.quotedAt, p.deadline = "quoted", total, unit, now, now + PAY_WINDOW
        Scan.Say((total > p.expected and "%d x %s went up to %s. Press Pay to buy at that."
            or "%d x %s cost %s. Click once more to buy."):format(p.qty, p.row.name, ns.Coins(total, true)))
        ns.dirty = true
    end,
    COMMODITY_PRICE_UNAVAILABLE = function()
        local p = Scroll.purchase
        if p and (p.state == "quoting" or p.state == "quoted") then Cancel("Those are not on sale right now.") end
    end,
    -- "Paid" and "not paid" do not say which payment they mean either: there is only ever one out, or one that
    -- nobody answered (and then no new one is started). "Paid" also comes for a buy made by hand or by another
    -- addon, so with no payment out it only counts for the unanswered one when the purse shows its gold gone;
    -- gold that leaves after the news is booked by PLAYER_MONEY below.
    COMMODITY_PURCHASE_SUCCEEDED = function()
        local p = Scroll.purchase
        if p and p.state == "buying" then
            Paid(p)
        elseif Scroll.late and not p then
            if Spent(Scroll.late) then Paid(Scroll.late) end
        elseif Scroll.ghost then
            local ghost = Scroll.ghost
            if not Haunts(ghost) then
                Scroll.ghost = nil          -- too old: this news could be anybody's
            elseif Spent(ghost) then
                Paid(ghost)
            end
        end
    end,
    COMMODITY_PURCHASE_FAILED = function()
        local p = Scroll.purchase
        if p and p.state == "buying" then
            NotPaid(p, "The auction house refused that buy. Checking the price again...")
        elseif Scroll.late and not p then
            NotPaid(Scroll.late, "That payment did not go through after all.")
        else
            Scroll.ghost = nil
        end
    end,
    PLAYER_MONEY = function()
        local late = Scroll.late
        if late and not Scroll.purchase and not Scan.buy.pending and Moved(late) then Paid(late) end
        -- the same for a payment buying no longer waits for, while its answer may still come
        local ghost = Scroll.ghost
        if ghost and Haunts(ghost) and not Scroll.purchase and not Scan.buy.pending and Moved(ghost) then Paid(ghost) end
    end,
}
Scroll.handlers = handlers

-- This character's scroll notes, checked when it logs in (Core.lua calls this).
function Scroll.Login(me)
    local spent = me.scrollSpent
    if type(spent) ~= "number" or spent ~= spent or spent < 0 or spent == math.huge then me.scrollSpent = 0 end
    for _, field in ipairs({ "scrollAmount", "scrollBought" }) do
        local t = me[field]
        if type(t) ~= "table" then
            t = {}
            me[field] = t
        end
        for id, n in pairs(t) do
            if not byId[id] or type(n) ~= "number" or n ~= n or n < 1 or n > 100000 then t[id] = nil end
        end
    end
    for id, n in pairs(me.scrollAmount) do
        local known = false
        for _, a in ipairs(AMOUNTS) do known = known or a == n end
        if not known then me.scrollAmount[id] = nil end
    end
    -- a payment that was out when the game reloaded: nobody knows how it ended
    local pending = me.scrollPending
    me.scrollPending = nil
    if type(pending) == "table" and byId[pending.id] then
        print(("|cffffd100Level Outfitter:|r a payment for %s was under way when the game reloaded. Check your mail to see whether it went through.")
            :format(byId[pending.id].name))
    end
end

if CreateFrame then
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:RegisterEvent("AUCTION_HOUSE_SHOW")
    driver:RegisterEvent("AUCTION_HOUSE_CLOSED")
    -- kept on all the time: the answer to a payment may come after the auction house window has closed
    for _, event in ipairs(EVENTS) do ns.Listen(driver, event) end
    driver:SetScript("OnEvent", function(_, event, ...)
        local handler = handlers[event]
        if handler then handler(...) end
    end)
    driver:SetScript("OnUpdate", function() Scroll.Tick(GetTime()) end)
    Scroll.frame = driver
end
