-- Plan.lua: works out what to buy at which level. Pure logic: no game calls, so it also runs in the test harness.
-- It is the same planner as tools/wowhead/build_rogue.py (plan_paced + the budget search), fed with live prices,
-- for the character's class and spec (ns.class, ns.spec; the rogue's own rules where it says so):
--   every slot wants an upgrade about every 8 levels when a clearly better piece can be bought,
--   each purchase costs "lam" plus (gold weight x its price), and a higher gold weight gives a cheaper plan.
-- Sliding the gold budget = picking the plan along that range that costs no more than the budget.
-- Money is whole copper everywhere (never a float sum of gold).
local ADDON, ns = ...
local Plan = {}
ns.Plan = Plan

local huge, max, min, floor, abs, sort = math.huge, math.max, math.min, math.floor, math.abs, table.sort
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber

local Score = ns.Score
local NLEV = ns.DATA.P.levels
local hoursAt = {}
for L = 1, NLEV do
    hoursAt[L] = ns.DATA.P.hours0 * ns.DATA.P.hoursGrow ^ L      -- later levels take longer, so they count more
end
Plan.NLEV = NLEV

-- gold weights tried for the price range, from "best at any price" to "buy next to nothing"
Plan.WEIGHTS = { 0, 0.004, 0.006, 0.009, 0.0135, 0.02, 0.03, 0.045, 0.07, 0.1, 0.15, 0.22, 0.33, 0.5, 0.75, 1.1, 1.7,
    2.5, 4, 8 }
Plan.SMART, Plan.CHEAP = 0.1, 0.5      -- the gold weights behind the "Smart" and "Cheapest" buttons

-- a price is whole copper, zero or more; anything else (nil, text, negative, not-a-number) means "not for sale"
local function Copper(p)
    if type(p) ~= "number" or p ~= p or p < 0 or p == huge then return nil end
    return floor(p + 0.5)
end
-- how many copies: true = 1, a number = that many, anything else = none
local function Count(v)
    if v == true then return 1 end
    v = tonumber(v)
    if v and v == v and v >= 1 and v < huge then return floor(v) end
    return nil
end
local function Copy(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end
local function Blocked(row, last)       -- the same scores, but not wearable up to level `last`
    local out = {}
    for L = 1, NLEV do out[L] = L > last and row[L] or false end
    return out
end

-- Everything that does not change with the gold weight -------------------------------------------------
-- prices[key] = copper for every piece on the auction house (key = "itemId:bonusId").
-- owned[key]  = true or a number of copies already bought: they cost nothing.
-- opt.first   = level to plan from (default 1).
-- opt.last    = level to plan up to (default 60): nothing is planned past it, and what a piece is worth after it
--               does not count.
-- opt.side    = 1 Alliance / 2 Horde: pieces of the other side are left out.
-- opt.stock   = { [key] = how many are listed }. With it, a second copy of a piece (both ring slots, both hands) is
--               only planned when two are listed, and a piece one slot stops using moves to its partner for free.
-- opt.second  = { [key] = copper }: what the second-cheapest listing of a piece costs. A second copy is planned at
--               that price (the cheapest listing is the one the first slot takes).
-- The tables passed in are copied: changing them later does not change this env. Build a new env after a new scan.
function Plan.Env(prices, owned, opt)
    opt = type(opt) == "table" and opt or {}
    prices = type(prices) == "table" and prices or {}
    local D = ns.DATA
    local first = max(1, min(NLEV, floor(tonumber(opt.first) or 1)))
    local last = max(first, min(NLEV, floor(tonumber(opt.last) or NLEV)))
    local at = Score.Use()               -- level -> weight bracket; the scores below are for the weights of this moment
    local have = {}
    for key, v in pairs(type(owned) == "table" and owned or {}) do have[key] = Count(v) end
    local stockIn = type(opt.stock) == "table" and opt.stock or nil
    local env = { owned = have, first = first, last = last, at = at, rev = Score.rev, groups = {}, ref = {},
        stock = stockIn and {} or nil, second = {} }
    for key, p in pairs(type(opt.second) == "table" and opt.second or {}) do env.second[key] = Copper(p) end
    -- a green's suffix versions are only made when asked for: every piece with a price or an owner is, here
    local Variant = ns.Variant
    local function Make(key)
        if type(key) ~= "string" or ns.item[key] then return end
        local id, bonus = key:match("^(%d+):(%d+)$")
        if id then Variant(tonumber(id), tonumber(bonus)) end
    end
    for key in pairs(prices) do Make(key) end
    for key in pairs(have) do Make(key) end
    local pick = {}
    for _, g in ipairs(D.groups) do
        local live, S, best, price, free, n = {}, {}, {}, {}, {}, 0
        -- in the order of the lists, whenever each piece was made: the same prices always give the same plan
        local m = 0
        for _, c in ipairs(ns.cands[g]) do
            if Copper(prices[c.key]) or have[c.key] then
                m = m + 1
                pick[m] = c
            end
        end
        for i = #pick, m + 1, -1 do pick[i] = nil end
        sort(pick, function(a, b) return a.n < b.n end)
        for i = 1, m do
            local c = pick[i]
            local p, side = Copper(prices[c.key]), c.item.side
            if (p or have[c.key]) and not (opt.side and (side == 1 or side == 2) and side ~= opt.side) then
                n = n + 1
                live[n], price[n], free[n] = c, p or false, have[c.key] ~= nil
                -- a priced piece has at least one listing, even when no count came with it
                if stockIn then env.stock[c.key] = p and (Count(stockIn[c.key]) or 1) or 0 end
                -- worn from c.req to c.upto (its class's dual wield level, mail/plate at 40, and its spec's hands)
                local row, req, upto = {}, c.req, c.upto or NLEV
                for L = 1, NLEV do row[L] = L >= req and L <= upto and Score.Of(c, g, at[L]) or false end
                S[n] = row
            end
        end
        if g == "Off Hand" and ns.class == "ROGUE" then
            -- The rogue: a fast off hand first (the player's rule: poisons). At every level where a fast one can be had, a
            -- slow one that does not beat it even after its handicap is out: it is neither bought for the off
            -- hand nor handed down into it from the main hand. (Without this the main hand's old slow weapons,
            -- which cost nothing, kept the off hand slow.)
            -- A slow one the player OWNS stays as a stopgap, counted at under half of the fast one: the planner
            -- treats that like a far weaker piece: better than an empty hand, and replaced as soon as a fast one
            -- is worth its price.
            local fastAt = D.S.offFast
            for L = 1, NLEV do
                local top = 0
                for i = 1, n do
                    local s = S[i][L]
                    if s and live[i].speed < fastAt and s > top then top = s end
                end
                if top > 0 then
                    local stopgap = floor(0.45 * top * 10) / 10
                    for i = 1, n do
                        local s = S[i][L]
                        if s and live[i].speed >= fastAt and s <= top then
                            S[i][L] = (free[i] and stopgap > 0) and min(s, stopgap) or false
                        end
                    end
                end
            end
        end
        for L = 1, NLEV do
            local b = 0
            for i = 1, n do
                local s = S[i][L]
                if s and s > b then b = s end
            end
            best[L] = b
        end
        env.groups[g] = { cands = live, S = S, best = best, price = price, free = free }
    end
    for L = 1, NLEV do       -- what the best buyable piece in every slot adds up to
        local t = 0
        for _, g in ipairs(D.groups) do t = t + env.groups[g].best[L] * (D.double[g] and 2 or 1) end
        env.ref[L] = max(1, t)
    end
    return env
end

-- Only pieces near the top at some level can matter: the 40 best by score, and everything near the best score for
-- its price. Returns their positions, in order.
local function KeepSet(cands, S, price, free, first, last, at)
    local n, keep, live, lv = #cands, {}, {}, first
    local function byScore(a, b)
        local sa, sb = S[a][lv], S[b][lv]
        if sa ~= sb then return sa > sb end
        return a < b
    end
    local function byPrice(a, b)
        local pa, pb = price[a] or 0, price[b] or 0
        if pa ~= pb then return pa < pb end
        local sa, sb = S[a][lv], S[b][lv]
        if sa ~= sb then return sa > sb end
        return a < b
    end
    local newAt = {}
    for i = 1, n do
        newAt[cands[i].req] = true
        local upto = cands[i].upto
        if upto and upto < NLEV then newAt[upto + 1] = true end     -- (a fury warrior's two-handers end at 19)
    end
    for L = first, last do
        -- the same pieces and the same scores as the level before: nothing new to find
        if L == first or newAt[L] or at[L] ~= at[L - 1] then
            lv = L
            local m = 0
            for i = 1, n do
                if S[i][L] then
                    m = m + 1
                    live[m] = i
                end
            end
            for i = #live, m + 1, -1 do live[i] = nil end
            sort(live, byScore)
            for i = 1, (m < 40 and m or 40) do keep[live[i]] = true end
            sort(live, byPrice)
            local top = 0
            for i = 1, m do
                local s = S[live[i]][L]
                if s > 0.97 * top then keep[live[i]] = true end
                if s > top then top = s end
            end
        end
    end
    for i = 1, n do
        if free[i] then keep[i] = true end
    end
    local idx = {}
    for i = 1, n do
        if keep[i] then idx[#idx + 1] = i end
    end
    return idx
end

-- One slot. States: empty, or wearing piece x for a levels (a = A means "longer than the limit").
-- Returns { { position in cands, from level, to level }, ... } and the cost of that path.
-- The buffers below are shared and reused (no garbage per level). That is safe because Paced never yields:
-- a coroutine can only be switched between two slots (Plan.Run's yield), never inside this function.
local m, ma, worn, wkey, keys, prefV, prefJ = {}, {}, {}, {}, {}, {}, {}
local bufA, bufB, backBuf, costBuf = {}, {}, {}, {}
local function byWorth(a, b)
    local ka, kb = wkey[a], wkey[b]
    if ka ~= kb then return ka < kb end
    local va, vb = m[a], m[b]
    if va ~= vb then return va < vb end
    return a < b
end

local function Paced(S, best, ref, free, price, gw, minGain, first, last, idx)
    local P = ns.DATA.P
    local lam, INF = P.lam, huge
    local BIG = lam * (1.0 / P.grace)                -- one level past the limit costs a third of a purchase
    -- A range shorter than the usual stretch (ns.SPAN levels) would make nothing worth its price: what a piece gives
    -- only counts inside the range. A piece bought now serves for about that stretch all the same, so a purchase
    -- is charged that much less (level 60 alone is a range of one level, and the character stays there).
    local stretch = max(1, (ns.SPAN or 10) / (last - first + 1))
    local n, A, step = #idx, P.maxGap + 1, 1.0 + minGain
    local nA = n * A
    local cost, f, nf, back, fe = costBuf, bufA, bufB, backBuf, 0.0
    for x = 1, n do
        local i = idx[x]
        if free[i] then
            cost[x] = 0.0
        elseif price[i] then
            cost[x] = (lam + gw * (price[i] / 10000.0)) / stretch
        else
            cost[x] = INF                             -- no price: can never be bought
        end
    end
    for i = 1, nA do f[i] = INF end
    for L = first, last do
        local wt = hoursAt[L] / ref[L]
        local forced, bestL = L <= P.lastForced, best[L]
        local bk = (L - first) * nA                  -- where this level's back pointers start
        local nw = 0
        for j = 1, n do
            local mv, mav, base = INF, 0, (j - 1) * A
            for a = 1, A do
                local v = f[base + a]
                if v < mv then mv, mav = v, a end
            end
            m[j], ma[j] = mv, mav
            if mv < INF then
                nw = nw + 1
                worn[nw] = j
                wkey[j] = S[idx[j]][L] or -1.0
            end
        end
        for i = #worn, nw + 1, -1 do worn[i] = nil end
        -- pieces worn so far, by what they are worth now, with the cheapest path up to each position:
        -- a buyer may only replace something it beats by minGain
        sort(worn, byWorth)
        local pv, pj = INF, 0
        for i = 1, nw do
            local j = worn[i]
            if m[j] < pv then pv, pj = m[j], j end
            keys[i], prefV[i], prefJ[i] = wkey[j], pv, pj
        end
        local fill = forced and bestL >= max(P.fillFloor, P.fillShare * ref[L])
        for x = 1, n do
            local base = (x - 1) * A
            for a = 1, A do nf[base + a] = INF end
            local s = S[idx[x]][L]
            if s and s > 0 then
                local loss = wt * (bestL - s)
                -- a piece worth less than half of the best one to be had is as bad as wearing nothing: it costs
                -- what an empty slot costs (a level-1 leftover is no off-hand at level 12)
                local junk = (fill and s < P.weakShare * bestL) and BIG or 0.0
                local bv, bj = fe, 0             -- buy x now: into an empty slot, or over something clearly worse
                local target, lo, hi = s / step, 0, nw
                while lo < hi do
                    local mid = floor((lo + hi) / 2)
                    if target < keys[mid + 1] then hi = mid else lo = mid + 1 end
                end
                if lo > 0 and prefV[lo] < bv then bv, bj = prefV[lo], prefJ[lo] end
                nf[base + 1] = bv + cost[x] + loss + junk
                back[bk + base + 1] = bj > 0 and ((bj - 1) * A + ma[bj]) or 0
                for a = 2, A do                  -- keep x one more level
                    local src, sa = f[base + a - 1], a - 1
                    if a == A and f[base + A] < src then src, sa = f[base + A], A end
                    if src < INF then
                        local late = a == A and forced and bestL >= step * s
                        nf[base + a] = src + loss + (late and BIG or junk)
                        back[bk + base + a] = base + sa
                    end
                end
            end
        end
        fe = fe + (wt * bestL + (fill and BIG or 0.0))
        f, nf = nf, f
    end
    local cur, cv = 0, fe
    for i = 1, nA do
        if f[i] < cv then cv, cur = f[i], i end
    end
    local path = {}
    for L = last, first, -1 do
        path[L] = cur
        if cur ~= 0 then cur = back[(L - first) * nA + cur] end
    end
    local segs = {}
    for L = first, last do
        local st = path[L]
        if st ~= 0 then
            local x = floor((st - 1) / A) + 1
            local a = st - (x - 1) * A
            local last = segs[#segs]
            if last and last[1] == idx[x] and a ~= 1 then
                last[3] = L
            else
                segs[#segs + 1] = { idx[x], L, L }
            end
        end
    end
    return segs, cv
end

-- One whole plan for one gold weight ---------------------------------------------------------------------
-- -> { weight, cost, buys, power, slots = { [slot] = { { cand, key, from, to, owned, moved, cost, gain }, ... } } }
-- cost is copper; a row's cost is nil for a piece that needs no purchase: owned (you have it already) or moved
-- (it comes over from the other hand / ring slot once that slot has replaced it).
-- yield (optional) is called after every slot so the caller can spread the work over frames. Call Plan.Run from
-- inside a coroutine when passing coroutine.yield.
function Plan.Run(env, gw, yield)
    local D = ns.DATA
    local P, first, last, stock = D.P, env.first, env.last, env.stock
    gw = tonumber(gw) or 0
    if gw ~= gw or gw < 0 then gw = 0 end
    local slots, total, buys, got = {}, 0, 0, {}
    for L = 1, NLEV do got[L] = 0.0 end
    for _, label in ipairs(D.slots) do
        local G = env.groups[D.base[label] or label]
        local cands, S, price, free, bav, clone = G.cands, G.S, G.price, G.free, G.best, nil
        local changed = false
        local partner = D.partner[label]
        if partner and #slots[partner] > 0 then
            -- what the partner slot wears: key -> { last level it wears it, whether it had to buy it }
            local theirs = {}
            for _, r in ipairs(slots[partner]) do
                local t = theirs[r.key]
                if not t then
                    t = { last = r.to, bought = false }
                    theirs[r.key] = t
                end
                if r.to > t.last then t.last = r.to end
                if r.cost then t.bought = true end
            end
            for i = 1, #G.cands do
                local c = G.cands[i]
                local t = theirs[c.key]
                local ownedN = env.owned[c.key] or 0
                if t and (c.item.unique or stock or ownedN > 0) then
                    if not changed then
                        changed = true
                        cands, S, price, free, clone = Copy(cands), Copy(S), Copy(price), Copy(free), {}
                    end
                    local spare = ownedN + (t.bought and 1 or 0) - 1     -- copies in hand the partner is not using
                    if c.item.unique or not stock then
                        -- one copy only: it reaches this slot after the partner slot has replaced it, for free
                        S[i], free[i] = Blocked(G.S[i], t.last), true
                    elseif spare >= 1 then
                        free[i] = true                                   -- a second copy is already in the bags
                    else
                        local n = #cands + 1                             -- the partner's copy, handed down later
                        cands[n], S[n], price[n], free[n], clone[n] = c, Blocked(G.S[i], t.last), false, true, true
                        local left = (stock[c.key] or 0) - (t.bought and 1 or 0)
                        if left >= 1 and price[i] then
                            free[i] = false                              -- or buy another copy while it is still worn
                            -- the partner slot takes the cheapest listing: this copy costs what the next one does
                            local p2 = t.bought and env.second[c.key]
                            if p2 and p2 > price[i] then price[i] = p2 end
                        else
                            S[i] = Blocked(G.S[i], NLEV)                 -- no second one listed
                        end
                    end
                end
            end
        end
        local idx
        if changed then
            bav = {}
            for L = 1, NLEV do
                local b = 0
                for i = 1, #cands do
                    local s = S[i][L]
                    if s and s > b then b = s end
                end
                bav[L] = b
            end
            idx = KeepSet(cands, S, price, free, first, last, env.at)
        else
            idx = G.keep
            if not idx then
                idx = KeepSet(cands, S, price, free, first, last, env.at)
                G.keep = idx
            end
        end
        local need = D.weapon[label] and P.weaponGain or P.armorGain
        local segs = Paced(S, bav, env.ref, free, price, gw, need, first, last, idx)
        local rows, hadKey = {}, {}
        for n = 1, #segs do
            local i, lo, hi = segs[n][1], segs[n][2], segs[n][3]
            local c = cands[i]
            for L = lo, hi do got[L] = got[L] + (S[i][L] or 0.0) end
            local isFree = free[i] == true
            local owned = isFree and env.owned[c.key] ~= nil
            local moved = isFree and (not owned or (clone ~= nil and clone[i] == true))
            local cost, again = nil, false
            if not isFree then cost = price[i] or nil end
            if hadKey[c.key] and not owned then
                -- worn again later in the same slot: it is still in the bags, nothing to buy
                cost, moved, again = nil, true, true
            end
            hadKey[c.key] = true
            local gain
            if n > 1 then
                local j = segs[n - 1][1]
                local before = (clone and clone[j]) and S[j][lo] or (G.S[j] and G.S[j][lo])
                if before and before ~= 0 then gain = S[i][lo] / before - 1 end
            end
            rows[n] = { cand = c, key = c.key, from = lo, to = hi, owned = owned, moved = moved, again = again,
                cost = cost, gain = gain, score = S[i][lo] }
            if cost then
                total = total + cost
                buys = buys + 1
            end
        end
        slots[label] = rows
        if yield then yield() end
    end
    local num, den = 0.0, 0.0
    for L = first, last do
        num = num + hoursAt[L] * got[L]
        den = den + hoursAt[L] * env.ref[L]
    end
    return { weight = gw, cost = total, buys = buys, power = den > 0 and num / den or 0, slots = slots }
end

-- The price range ---------------------------------------------------------------------------------------
-- Every plan along the gold weights, dearest first. A plan that is not stronger than a cheaper (or equally dear)
-- one is dropped, so going down the list always trades gold for strength.
function Plan.Curve(env, yield)
    local all = {}
    for i, w in ipairs(Plan.WEIGHTS) do all[i] = Plan.Run(env, w, yield) end
    return Plan.Tidy(all)
end

function Plan.Tidy(all)
    local list = Copy(all)
    sort(list, function(a, b)            -- cheapest first; at the same cost the stronger one first
        if a.cost ~= b.cost then return a.cost < b.cost end
        if a.power ~= b.power then return a.power > b.power end
        return a.weight < b.weight
    end)
    local up = {}
    for i = 1, #list do
        local p, top = list[i], up[#up]
        if not top or (p.cost > top.cost and p.power > top.power) then up[#up + 1] = p end
    end
    local curve = {}
    for i = #up, 1, -1 do curve[#curve + 1] = up[i] end
    return curve
end

-- The strongest plan on the curve that costs no more than `budget` copper (nil when none does, or the budget is
-- not a number).
function Plan.Pick(curve, budget)
    budget = tonumber(budget)
    if not budget or budget ~= budget then return nil end
    for i = 1, #curve do
        if curve[i].cost <= budget then return curve[i], i end
    end
    return nil
end

-- The plan whose gold weight is nearest to `weight` (for the Smart and Cheapest buttons).
function Plan.Near(curve, weight)
    local found, gap
    for i = 1, #curve do
        local d = abs(curve[i].weight - weight)
        if not gap or d < gap then found, gap = curve[i], d end
    end
    return found
end

-- Fill the budget better: search the gold weights between the picked plan and the next dearer one. Every plan
-- tried joins the curve. Returns the new pick and the new curve.
function Plan.Refine(env, curve, budget, tries, yield)
    budget = tonumber(budget)
    local pick, i = Plan.Pick(curve, budget)
    if not pick or i == 1 then return pick, curve end
    local hi, lo = pick.weight, curve[i - 1].weight          -- hi fits the budget, lo costs too much
    local all = Copy(curve)
    for _ = 1, tonumber(tries) or 6 do
        local w = lo > 0 and (lo * hi) ^ 0.5 or hi / 2
        local p = Plan.Run(env, w, yield)
        all[#all + 1] = p
        if p.cost <= budget then hi = w else lo = w end
    end
    curve = Plan.Tidy(all)
    return (Plan.Pick(curve, budget)), curve
end

-- Rows of one plan as a shopping list by level segment -----------------------------------------------------
-- -> { { from, to, cost, buys, rows = { { slot, row }, ... } }, ... }   rows sorted by level, then slot order
-- segments = { { from, to }, ... } (default: ns.SEGMENTS, the level range picked)
function Plan.Segments(plan, segments)
    local D, out = ns.DATA, {}
    for s, seg in ipairs(segments or ns.SEGMENTS) do
        local rows, cost, buys = {}, 0, 0
        for order, label in ipairs(D.slots) do
            for _, r in ipairs(plan.slots[label] or {}) do
                if r.from >= seg[1] and r.from <= seg[2] then
                    rows[#rows + 1] = { slot = label, row = r, order = order }
                    if r.cost then
                        cost = cost + r.cost
                        buys = buys + 1
                    end
                end
            end
        end
        sort(rows, function(a, b)
            if a.row.from ~= b.row.from then return a.row.from < b.row.from end
            return a.order < b.order
        end)
        out[s] = { from = seg[1], to = seg[2], cost = cost, buys = buys, rows = rows }
    end
    return out
end
