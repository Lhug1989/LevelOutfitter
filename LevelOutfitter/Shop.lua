-- Shop.lua: turns the scan into a shopping list. It asks the planner for the whole range of plans (cheapest to
-- best), shows the strongest one the gold limit allows, keeps that list's prices checked against the real
-- listings, and works the list out again when they disagree. The window only reads from here, and buying goes
-- through Shop.Buy alone (which the window calls straight from a mouse click).
--
-- The planning is heavy (seconds), so it runs in small pieces, one or two slots per frame.
local ADDON, ns = ...
local Shop = {}
ns.Shop = Shop

local Plan, Scan, Own = ns.Plan, ns.Scan, ns.Own
local ipairs, type, max, min, floor = ipairs, type, math.max, math.min, math.floor
local create, resume, status, yield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield
local GetTime = GetTime

local FRAME_MS = 10                -- planning time per frame; the rest of the frame stays for the game
local REFINE_TRIES = 4             -- extra plans tried to fill a gold limit better
local CHECK_EVERY, WANT_EVERY = 0.5, 2
local REST = 0.4                   -- the slider must rest this long before a search for its amount starts
local OWN_GAP = 30                 -- seconds between re-plans caused by a change in the bags
local MAX_AUTO = 8                 -- re-plans a scan may trigger by itself (prices that keep moving need a new scan)
local LAST_RESORT = 1e6            -- a gold weight at which nothing that costs money is worth buying
local REV_RESTARTS = 3             -- plans made anew in a row because the weights changed meanwhile; then the list is shown

Shop.segment = 1                   -- the level segment on show (index into ns.SEGMENTS: there is one, the chosen range)
Shop.auto = 0

local driver
local function Wake()
    if driver then driver:Show() end
end

-- Gold the limit still allows. The limit counts everything spent through the addon so far, and holds back the
-- price of every buy that may have gone through ("maybe bought") until the mailbox settles it.
local function Left()
    local me = ns.me
    return me and max(0, me.budget - me.spent - Own.Held()) or 0
end
Shop.Left = Left

-- The list as the window shows it ------------------------------------------------------------------------------
-- view = { plan, cost, power, buys, segments = { { from, to, cost, buys, rows = { row, ... } }, ... } }
-- row  = { slot, key, name, item, from, to, cost, kind, why, gain, seg, view, req, wear }
--   from/to: the levels the list has the piece worn.  req: the level the item itself needs (as its tooltip says).
--   wear: the level it can be worn in this slot (an off hand not before level 10).
--   kind: "buy" (costs gold), "own" (you have it), "moved" (comes over from the other hand or ring slot),
--         "again" (worn earlier in this slot, still in the bags)
local function Build(plan)
    local view = { plan = plan, cost = plan.cost, power = plan.power, buys = plan.buys, segments = {} }
    -- the levels this plan was made for (the range picked may have moved on since: its new list is on its way)
    local env = Shop.env
    for s, seg in ipairs(Plan.Segments(plan, env and { { env.first, env.last } })) do
        local rows = {}
        for i, entry in ipairs(seg.rows) do
            local r = entry.row
            local c = r.cand
            rows[i] = { slot = entry.slot, key = r.key, name = ns.Name(r.key), item = ns.item[r.key], from = r.from,
                to = r.to, cost = r.cost, gain = r.gain, seg = s, view = view,
                why = c and ns.Score.Text(c, ns.DATA.base[entry.slot] or entry.slot) or "",
                req = c and c.item.req or r.from, wear = c and c.req or r.from,
                kind = (r.owned and "own") or (r.again and "again") or (r.moved and "moved") or "buy" }
        end
        view.segments[s] = { from = seg.from, to = seg.to, cost = seg.cost, buys = seg.buys, rows = rows }
    end
    return view
end

local wanted = {}
-- Tells the scan which rows to read: everything unbought in the segment on show (kept fresh, so a click works),
-- then the rest of the list once (so the totals are real).
function Shop.WantNow()
    local view = Shop.view
    if not view or not ns.ahOpen then return end
    local n = 0
    for i = #wanted, 1, -1 do wanted[i] = nil end
    local cur = view.segments[Shop.segment]
    if cur then
        for _, row in ipairs(cur.rows) do
            if row.kind == "buy" and not row.bought then
                n = n + 1
                wanted[n] = row.key
            end
        end
    end
    for s, seg in ipairs(view.segments) do
        if s ~= Shop.segment then
            for _, row in ipairs(seg.rows) do
                if row.kind == "buy" and not row.bought then
                    local o = Scan.Offer(row.key)
                    if o and not o.read then
                        n = n + 1
                        wanted[n] = row.key
                    end
                end
            end
        end
    end
    Scan.Want(wanted)
end

local function Show(plan)
    Shop.plan = plan
    Shop.view = plan and Build(plan) or nil
    if Shop.view then Shop.view.env = Shop.env end      -- the prices and ownership this list was made from
    Shop.lastWant = GetTime()
    Shop.WantNow()
    ns.dirty = true
end

-- Planning in pieces ---------------------------------------------------------------------------------------
-- full = from the scan's prices and what is owned (the whole range); else only a better fit for the gold limit.
local function Start(full)
    local job = { full = full, steps = 0, budget = Left() }
    job.from, job.to = ns.Range()
    if full then ns.SEGMENTS[1][1], ns.SEGMENTS[1][2] = job.from, job.to end
    job.total = ((full and #Plan.WEIGHTS or 0) + REFINE_TRIES) * #ns.DATA.slots
    local function step()
        job.steps = job.steps + 1
        yield()
    end
    job.co = create(function()
        if full then
            local owned = Own.Counts()
            job.ownRev = ns.ownRev
            local prices, stock, _, second = Scan.Tables()
            job.env = Plan.Env(prices, owned, { first = job.from, last = job.to, side = ns.Side(), stock = stock,
                second = second })
            job.curve = Plan.Curve(job.env, step)
        else
            job.env, job.curve = Shop.env, Shop.curve
        end
        local pick, curve = Plan.Refine(job.env, job.curve, job.budget, REFINE_TRIES, step)
        if not pick then
            -- even the cheapest plan of the range costs too much: lean harder on gold until one fits
            local all = {}
            for i, p in ipairs(curve) do all[i] = p end
            local w = max(curve[#curve] and curve[#curve].weight or 1, 1)
            for _ = 1, 6 do
                w = w * 4
                local p = Plan.Run(job.env, w, step)
                all[#all + 1] = p
                if p.cost <= job.budget then break end
            end
            if all[#all].cost > job.budget then all[#all + 1] = Plan.Run(job.env, LAST_RESORT, step) end
            curve = Plan.Tidy(all)
            pick = Plan.Pick(curve, job.budget)
        end
        job.curve, job.pick = curve, pick
    end)
    Shop.job, Shop.again, Shop.restAt, Shop.startedAt, Shop.error = job, nil, nil, GetTime(), nil
    ns.dirty = true
    Wake()
end

local function Finish(job)
    Shop.job = nil
    if job.full then
        Shop.env, Shop.ownRev, Shop.stale = job.env, job.ownRev, false
        Shop.curveRev = job.ownRev              -- what was owned (and doubted) when these plans were worked out
    end
    Shop.curve = job.curve
    if Shop.again == "full" then return Start(true) end
    -- the weights or the spec changed while it was worked out (pieces fit other levels now): made anew, at most
    -- REV_RESTARTS times in a row (an addon whose answer keeps flipping must not keep the list away for good: then
    -- it is shown, and Buy waits for a list made for the weights in force)
    if job.env and job.env.rev ~= ns.Score.rev and (Shop.revRestarts or 0) < REV_RESTARTS then
        Shop.revRestarts = (Shop.revRestarts or 0) + 1
        return Start(true)
    end
    if job.env and job.env.rev == ns.Score.rev then Shop.revRestarts = nil end
    Show(job.pick)
    if Shop.wish then                           -- a "Cheapest / Smart / Best" click that waited for these fresh plans
        local name = Shop.wish
        Shop.wish = nil
        Shop.wishTries = (Shop.wishTries or 0) + 1
        Shop.Preset(name, Shop.wishTries >= 3)  -- (after three rounds of planning it is taken as it is)
        if not Shop.wish then Shop.wishTries = nil end
    end
    if Shop.again == "fit" or job.budget ~= Left() then return Start(false) end     -- the limit moved meanwhile
end

local function RunJob(job)
    local clock = debugprofilestop
    local t0 = clock and clock()
    repeat
        local ok, err = resume(job.co)
        if not ok then
            Shop.job, Shop.error = nil, tostring(err)
            Shop.errorRev = job.env and job.env.rev or ns.Score.rev  -- the weights it failed with
            Shop.restAt = nil                                         -- only a new scan or new weights try again
            Shop.wish, Shop.wishTries = nil, nil        -- a shortcut that waited for these plans is off
            Scan.Say("Level Outfitter could not work out the list: " .. tostring(err), "bad")
            return
        end
        if status(job.co) == "dead" then return Finish(job) end
    until not t0 or clock() - t0 > FRAME_MS
end

-- Works the lists out again from the scan and from what is owned. false when there is nothing to plan from.
function Shop.Replan()
    if not ns.me or not ns.Known() or not Scan.state.scanned then return false end
    if Shop.job then
        Shop.again = "full"
    else
        Start(true)
    end
    return true
end

-- What the window calls ----------------------------------------------------------------------------------------
-- The gold limit (copper). The list for it shows at once from the plans at hand; a moment later the planner
-- searches for one that fills the amount better.
function Shop.SetBudget(copper)
    local me = ns.me
    if not me or type(copper) ~= "number" or copper ~= copper or copper < 0 or copper == math.huge then return false end
    me.budget = floor(copper + 0.5)
    if Shop.job then
        Shop.again = Shop.again or "fit"
    elseif Shop.curve then
        if not Shop.stale then
            -- below the cheapest plan at hand the list on show stays (its Buy buttons obey the limit anyway) until
            -- the search that follows has found a cheaper one: never an empty window while the slider moves
            local pick = Plan.Pick(Shop.curve, Left())
            if pick then Show(pick) end
        end
        Shop.restAt = GetTime() + REST
        Wake()
    end
    ns.dirty = true
    return true
end

-- Gold already counted against the limit: spent through the addon, plus buys that may have gone through.
local function Counted()
    local me = ns.me
    return me and (me.spent + Own.Held()) or 0
end

-- The plans at hand were worked out before the buys ticked off in the list on show: those pieces are part of
-- "spent" now, and still part of every plan's cost. What they cost, so nothing is counted twice.
local function BoughtSince()
    local view, sum = Shop.view, 0
    if not Shop.stale or not view then return 0 end
    for _, seg in ipairs(view.segments) do
        for _, row in ipairs(seg.rows) do
            if row.kind == "buy" and row.bought then sum = sum + (row.cost or 0) end
        end
    end
    return sum
end

-- Whether the plans at hand are still the ones for this moment: the level range and the stat weights they were
-- made for, and what was owned, bought and doubted ("maybe bought") when they were made.
local function Fresh()
    local env = Shop.env
    if not env or Shop.stale then return false end
    local from, to = ns.Range()
    if env.first ~= from or env.last ~= to then return false end
    ns.Score.Use()
    if env.rev ~= ns.Score.rev then return false end
    Own.Counts()
    return ns.ownRev == Shop.curveRev
end

-- "cheap", "smart" or "best": moves the gold limit to what that plan costs (on top of what is counted as spent).
-- The plans must be fresh for that: made for another level range, or before a buy or an unanswered bid, they would
-- name a wrong amount (a bought piece counted twice). Then they are worked out again first and the limit is set
-- when they are there (Shop.wish). `anyway` skips that (Finish, after three rounds).
function Shop.Preset(name, anyway)
    local curve, me = Shop.curve, ns.me
    if not curve or not curve[1] or not me then return false end
    if name ~= "cheap" and name ~= "smart" and name ~= "best" then return false end
    if Shop.job then
        Shop.wish = name                        -- plans are being worked out: the limit is set when they are done
        return true
    end
    if not anyway and not Fresh() then
        Shop.wish = name
        Start(true)
        return true
    end
    local plan = (name == "best" and curve[1]) or Plan.Near(curve, name == "cheap" and Plan.CHEAP or Plan.SMART)
    return Shop.SetBudget(Counted() + plan.cost)
end

-- The player set the gold limit by hand (the slider, the box): a shortcut still waiting for fresh plans must not
-- override that when they come.
function Shop.DropWish()
    Shop.wish, Shop.wishTries = nil, nil
end

-- The most the slider needs to reach: what the best plan still costs, on top of what is counted as spent. A bid
-- nobody answered after the plans were made is in those plans as a buy already: its held-back price is not added
-- a second time.
function Shop.Top()
    local curve, me = Shop.curve, ns.me
    local counted = (ns.ownRev == Shop.curveRev) and Counted() or (me and me.spent or 0)
    return counted + max(0, (curve and curve[1] and curve[1].cost or 0) - BoughtSince())
end

-- The level range moved (the window's steppers, /lo levels): the lists are worked out again for it, once the
-- steppers have rested a moment.
function Shop.RangeChanged()
    Shop.rangeAt = GetTime() + REST
    Shop.lastCheck = nil
    if Shop.job then Shop.again = "full" end
    ns.dirty = true
    Wake()
end

function Shop.SetSegment(i)
    if type(i) ~= "number" or not ns.SEGMENTS[i] then return end
    Shop.segment = i
    Shop.WantNow()
    ns.dirty = true
end

-- The segment to show first: there is only the chosen range.
function Shop.HomeSegment()
    return 1
end

-- Where a row stands right now, and the price that goes with it:
--   "bought"                       ticked off
--   "buying"                       its bid is out, waiting for the answer
--   "own" / "moved" / "again"     nothing to buy
--   "unsure"                       an earlier buy may have gone through: check the mail
--   "gone"                         not on sale any more
--   "checking"                     the real listing was not read yet (the price is the row's guess)
--   "dearer"                       the real price is above what the list counted (price = the real one)
--   "ready"                        on sale at the planned price or below (price = what a click pays)
function Shop.RowState(row)
    if row.bought then return "bought", row.paid end
    local pending = Scan.buy.pending
    if (pending and pending.key == row.key) or Scan.Watching(row.key) then return "buying", row.cost end
    if Own.IsUnsure(row.key) then return "unsure", row.cost end
    if row.kind ~= "buy" then return row.kind, nil end
    local o = Scan.Offer(row.key)
    if not o then return "gone", nil end
    if not o.read then return "checking", row.cost end
    if o.price > row.cost then return "dearer", o.price end
    return "ready", o.price
end

local WHY = { bought = "Already bought.", buying = "Buying...", own = "You have it.", moved = "Nothing to buy.", again = "Nothing to buy.",
    unsure = Scan.UNSURE, gone = "Sold out.", checking = "Checking the price...", dearer = "The price went up." }

-- Whether a click on this row's Buy button would go through right now: true and the price, or false and why.
function Shop.CanBuy(row)
    local me = ns.me
    if not me or type(row) ~= "table" then return false, "Nothing to buy." end
    if row.view ~= Shop.view then return false, "The list changed." end
    -- made for other weights or another spec (Forever Leveling BiS changed meanwhile): it is being worked out again
    -- (or that failed: then a new scan is the way on)
    if Shop.error and not Shop.job and Shop.env and Shop.env.rev ~= ns.Score.rev then
        return false, "The list could not be worked out for the new weights. Press Scan to try again."
    end
    if Shop.env and Shop.env.rev ~= ns.Score.rev then return false, "The list is being worked out again." end
    -- a consumable payment nobody answered yet: the purse must stay readable until it is settled
    if ns.Scroll and ns.Scroll.Unsettled() then return false, ns.Scroll.late and ns.Scroll.UNSURE or ns.Scroll.WAITING end
    if ns.Scroll and ns.Scroll.Busy() then return false, "Buying..." end      -- a consumable purchase is under way
    local state, price = Shop.RowState(row)
    if state ~= "ready" then return false, WHY[state] or "Nothing to buy." end
    local left = Left()
    if price > left then return false, "That would go past your gold limit." end
    local listing, why = Scan.CanBuy(row.key, price, min(row.cost, left))
    if not listing then return false, why end
    return true, price
end

-- Buys this row's piece. shown = the price the window showed on the button. Call it only from a mouse click.
function Shop.Buy(row, shown)
    if not ns.Known() then return false, "Level Outfitter has no lists for this class yet." end    -- (no rows either)
    local ok, price = Shop.CanBuy(row)
    if not ok then
        if price == Scan.BUSY then Scan.Hold(3) end        -- keep the auction house free for the next click
        return false, price
    end
    if type(shown) ~= "number" or shown ~= price then return false, "The price changed." end
    local sent, why = Scan.Buy(row.key, price, min(row.cost, Left()), row)
    if sent then Shop.ownRev = ns.ownRev end        -- the "maybe bought" note of our own bid is no change from outside
    return sent, why
end

-- Gold still to pay for the list on show: in all, and per segment. Rows already bought do not count.
function Shop.Totals()
    local view = Shop.view
    local out = { left = 0, buys = 0, segments = {} }
    if not view then return out end
    for s, seg in ipairs(view.segments) do
        local left, buys = 0, 0
        for _, row in ipairs(seg.rows) do
            if row.kind == "buy" and not row.bought then
                left, buys = left + row.cost, buys + 1
            end
        end
        out.segments[s] = { left = left, buys = buys }
        out.left, out.buys = out.left + left, out.buys + buys
    end
    return out
end

-- How far the planning is (0..1), or nil when none runs.
function Shop.Busy()
    local job = Shop.job
    return job and min(1, job.steps / max(1, job.total)) or nil
end

-- A buy landed: tick its row off where it stands. The list is not worked out again (it would only reshuffle
-- under the player's hands); the range of plans is, the next time the gold limit moves.
ns.OnBought = function(key, price, row)
    local view = Shop.view
    if type(row) == "table" and row.view == view and not row.bought then
        row.bought, row.paid = true, price
    elseif view then                        -- the list changed meanwhile: tick the same piece off if it is still on it
        local done = false
        for _, seg in ipairs(view.segments) do
            for _, r in ipairs(seg.rows) do
                if not done and r.key == key and r.kind == "buy" and not r.bought then
                    r.bought, r.paid, done = true, price, true
                end
            end
        end
    end
    Shop.ownRev = ns.ownRev                 -- our own buy is no change from outside
    Shop.stale = true
    if Shop.job then Shop.again = "full" end
    ns.dirty = true
end

-- A buy that got no answer (unsure: "maybe bought" was written down) or one that was refused for certain (the note
-- was taken back). Both change what is owned, and both are our own doing: no reason to work the list out again.
-- Except when the list was worked out again while the note stood: then it counts the piece as owned ("You have
-- it") although it was never bought, and has to be made anew.
ns.OnBuyFailed = function(_, row, unsure)
    if unsure or (type(row) == "table" and row.view and row.view.env == Shop.env) then
        Shop.ownRev = ns.ownRev
    else
        Shop.stale = true
    end
    ns.dirty = true
end

ns.OnScanned = function()
    Shop.auto = 0
    Shop.revRestarts, Shop.errorRetryAt = nil, nil
    Shop.Replan()
end

-- Looks whether the list still agrees with the world; called a few times a second while the window is open.
function Shop.Check(now)
    if Shop.job or not ns.me or not ns.Known() then return end
    if not Scan.state.scanned or Scan.state.phase ~= "idle" then return end
    -- after a failure only a new scan tries again, or new weights or a new spec (once for each: it may have been
    -- them, and the list on show is for the old ones)
    -- (at most once every OWN_GAP seconds: weights that keep changing must not start plan after failing plan)
    if Shop.error then
        ns.Score.Use()
        if Shop.errorRev ~= ns.Score.rev and (not Shop.errorRetryAt or now - Shop.errorRetryAt > OWN_GAP) then
            Shop.errorRetryAt = now
            return Start(true)
        end
        Shop.restAt = nil                       -- (the gold slider moved meanwhile: with the same weights no new try)
    end
    if not Shop.curve then
        if Shop.error then return end           -- it failed: only a new scan tries again, not this check
        return Start(true)
    end
    if Shop.restAt then
        if now < Shop.restAt then return end
        Shop.restAt = nil
        return Start(Shop.stale == true)
    end
    if Shop.error then return end               -- nothing below may start planning by itself after a failure
    -- the level range the list was made for is no longer the one wanted (the steppers, a level-up)
    local from, to = ns.Range()
    if Shop.env and (Shop.env.first ~= from or Shop.env.last ~= to) then
        if Shop.rangeAt and now < Shop.rangeAt then return end
        Shop.rangeAt = nil
        return Start(true)
    end
    -- the stat weights changed (the other addon was updated, or a profile was picked there): every score is new
    ns.Score.Use()
    if Shop.env and Shop.env.rev == ns.Score.rev then Shop.revRestarts = nil end     -- they hold still: count anew
    -- (after REV_RESTARTS rounds in a row that the weights outran, the list on show stays for a while: OWN_GAP)
    if Shop.env and Shop.env.rev ~= ns.Score.rev
        and ((Shop.revRestarts or 0) < REV_RESTARTS or now - (Shop.startedAt or 0) > OWN_GAP) then return Start(true) end
    Own.Counts()
    if ns.ownRev ~= Shop.ownRev and now - (Shop.startedAt or 0) > OWN_GAP then return Start(true) end
    local view, v = Shop.view, Scan.verify
    if view and ns.ahOpen then
        -- once every wanted row was read: a piece that sold out or costs more than the list counted means the list
        -- is no longer the best one, so it is worked out again from the real prices
        if not v.current and not v.queue[1] and Shop.auto < MAX_AUTO then
            for _, seg in ipairs(view.segments) do
                for _, row in ipairs(seg.rows) do
                    if row.kind == "buy" and not row.bought then
                        local state = Shop.RowState(row)
                        if state == "gone" or state == "dearer" then
                            Shop.auto = Shop.auto + 1
                            return Start(true)
                        end
                    end
                end
            end
        end
        if now - (Shop.lastWant or 0) >= WANT_EVERY then
            Shop.lastWant = now
            Shop.WantNow()
        end
    end
end

-- The window is on screen (or not): the checks above only run while it is.
function Shop.Open()
    Shop.active = true
    Shop.lastCheck = nil
    Wake()
end

function Shop.Close()
    Shop.active = false
end

function Shop.Tick(now)
    now = now or GetTime()
    if Shop.job then
        RunJob(Shop.job)
    elseif Shop.active or Shop.restAt then
        if not Shop.lastCheck or now - Shop.lastCheck >= CHECK_EVERY then
            Shop.lastCheck = now
            Shop.Check(now)
        end
    end
    if driver and not Shop.job and not Shop.active and not Shop.restAt then driver:Hide() end
end

if CreateFrame then
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", function() Shop.Tick(GetTime()) end)
    Shop.frame = driver
end
