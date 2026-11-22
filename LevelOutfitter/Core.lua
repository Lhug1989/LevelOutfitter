-- Core.lua: the item lists (from Data.lua), saved settings, and small helpers the other files share.
-- Nothing here talks to the auction house or spends gold.
local ADDON, ns = ...
_G.LevelOutfitter = ns

local tonumber, pairs, ipairs, type, floor, pcall, huge = tonumber, pairs, ipairs, type, math.floor, pcall, math.huge

ns.VERSION = "0.8.2"
-- The levels the lists are made for: one range, chosen by the player (ns.Range, ns.SetRange). It is kept here as a
-- list of one, because the lists are built per "segment".
ns.SEGMENTS = { { 1, 60 } }
ns.SPAN = 10                                 -- levels a range covers when the player has not said where it ends
ns.DEFAULTS = { budget = 100 * 10000 }       -- money is whole copper everywhere: 100 gold
ns.FRESH = 120                               -- seconds a listing that was read stays good enough to buy from
ns.dirty = false                             -- something on show changed: the window draws again

-- Item lists -------------------------------------------------------------------------------------------
-- ns.item[key]    = { key, id, bonus, name, quality, unique, side, req, stats = { stat = value } }
--                   (req = the level the item itself needs, as its tooltip says)
-- ns.cands[group] = { { key, item, req, upto, kind, dps, speed, inv, t, n }, ... }   one entry per piece and slot it fits
--                   (req..upto = the levels it can be worn in that slot: an off hand not before the class's dual wield
--                    level, mail or plate not before 40, a fury warrior's two-hander only until 19 (ns.Refit);
--                    inv = its inventory type; t = "item class.subclass.inventory type"; n = its place in the lists, the same whenever it was made: the planner
--                    sorts by it)
-- ns.byId[id]     = { [bonus] = key, or false for a version of no use to this class }   every item the lists hold has
--                   a table here, also before any of its versions was made
-- A green with a random suffix ("of the Monkey") is in Data.lua once, with the list of suffixes it can come with.
-- A version is only worked out when something asks about it (ns.Variant): a row of the auction house, a link in
-- the bags, a price handed to the planner. All of them at once would be over twenty thousand pieces in memory.
-- A suffix gives each of its stats a share of the item's stat budget: stat = floor(share x budget / 10000 + 0.5).
-- Data.lua holds the pieces of every class; only the character's own class is loaded (ns.class, from UnitClass).
ns.item, ns.cands, ns.byId = {}, {}, {}

local function Split(line)
    local out, n = {}, 0
    for field in (line .. "|"):gmatch("([^|]*)|") do
        n = n + 1
        out[n] = field
    end
    return out
end

local function Pairs(text)          -- "agi=3,sta=4" -> { agi = 3, sta = 4 }
    local out = {}
    for k, v in (text or ""):gmatch("(%a+)=([^,]+)") do out[k] = tonumber(v) end
    return out
end

local base, suffix, useful = {}, {}, {}     -- base[id] = the item as Data.lua has it; suffix[bonus]; useful[stat]
local SPREAD = 64                           -- places kept free after every Data.lua line for its suffix versions
local HANDS = { ["Main Hand"] = "main", ["Off Hand"] = "off" }
local ARMOR_INV = { [1] = true, [3] = true, [5] = true, [20] = true, [6] = true, [7] = true, [8] = true, [9] = true,
    [10] = true }
local lines = {}                            -- every Data.lua row loaded (ns.Refit sets their levels again)

-- The class the lists are made for: the character's own (UnitClass), the rogue when the game cannot say (the tests).
-- nil while the game does not know it yet (then the lists are made at the login).
function ns.Class()
    if ns.class then return ns.class end
    if not UnitClass then return "ROGUE" end
    local ok, _, file = pcall(UnitClass, "player")
    return ok and type(file) == "string" and file ~= "" and file or nil
end

-- The rules of the class the lists are made for (Data.lua `classes`), nil for a class the addon does not know.
function ns.ClassData()
    return ns.class and ns.DATA.classes[ns.class] or nil
end

-- true when the lists are made and the class is one the addon has lists for (0.8.0: all nine; `ready` in Data.lua
-- can still switch one off)
function ns.Known()
    local C = ns.ClassData()
    return C ~= nil and C.ready == true
end

-- (kept for the windows' old checks: the rogue is one of the known classes now)
function ns.IsRogue()
    return ns.Class() == "ROGUE"
end

-- The spec the lists are planned for, and how the hands are filled at each level ---------------------------------
-- The rogue: always combat (the owner's rule). Any other class: the spec Forever Leveling BiS has for the character
-- (Score.Load asks it), else the class's first one. The setup ("twohand", "dualwield", "shield", "held", "onehand")
-- at a level: the one picked in Forever Leveling BiS when the class can use it then, else the spec's first one it can
-- use (dual wield only from the class's dual wield level), else a one-hander alone.
ns.spec, ns.pick = nil, nil
local handsAt = {}                          -- handsAt[L] = { main = { [inv] = true }, off = { ... } }, setupAt[L]
local setupAt = {}
-- The level from which the character wields weapon type `sub` (Forever Leveling BiS's Wields): below trainLevel only
-- the types its race and class start with (the race from UnitRace; not known: what every race of the class starts
-- with), from it every type its class learns (polearms from 20). NOT the rogue: its rules are the owner's own (no
-- daggers, its own swords) and its plans stay as they were: polearms from 20, else from level 1.
ns.race = nil
local function WeaponFrom(C, sub)
    local D = ns.DATA
    local t = D.train[sub] or 1
    local start = C.start and (C.start[ns.race or 0] or C.startAny)
    if not start then return t end
    if start[sub] then return 1 end
    return t > D.trainLevel and t or D.trainLevel
end
ns.WeaponFrom = function(sub)
    local C = ns.ClassData()
    return C and WeaponFrom(C, sub) or 61
end
local function CanSetup(C, key, L)
    if key == "dualwield" then return C.dw ~= nil and L >= C.dw end
    if key == "shield" then return C.shield == true end
    if key == "twohand" then
        if not C.twohandSubs then return C.twohand ~= nil and L >= C.twohand end      -- (the rogue: never)
        for _, sub in ipairs(C.twohandSubs) do
            if L >= WeaponFrom(C, sub) then return true end
        end
        return false
    end
    return ns.DATA.setups[key] ~= nil
end
-- The setups Forever Leveling BiS offers this spec at level L (its WeaponSetupOptions): the spec's own ones the class
-- can use then, the default first, and "onehand" only when none of them takes a one-hander (an arms or fury warrior
-- below 20, a rogue below 10). Returns the list and whether `key` is in it.
local function Options(C, spec, L, key)
    local out, oneHand, has = {}, false, false
    for _, k in ipairs(C.setups[spec] or {}) do
        if CanSetup(C, k, L) then
            out[#out + 1] = k
            if ns.DATA.setups[k].main[13] then oneHand = true end
            if k == key then has = true end
        end
    end
    if not oneHand then
        out[#out + 1] = "onehand"
        if key == "onehand" then has = true end
    end
    return out, has
end

local function Hands()
    local C, D = ns.ClassData(), ns.DATA
    for L = 1, 60 do
        local key = "onehand"
        if C then
            -- a pick counts only at the levels where that addon offers it; elsewhere the spec's default order
            local list, has = Options(C, ns.spec, L, ns.pick)
            key = has and ns.pick or list[1]
        end
        local set = D.setups[key]
        local off = {}
        for inv in pairs(set.off) do
            if inv ~= 14 or (C and C.shield) then off[inv] = true end      -- a shield only for a class that carries one
        end
        handsAt[L] = { main = set.main, off = off }
        setupAt[L] = key
    end
end
function ns.SetupAt(level)
    return setupAt[level] or "onehand"
end

-- The first and last level line `l` can be worn in its slot by this class and spec (61, 0 when never).
local function Fit(l)
    local hand = HANDS[l.group]
    if not hand then return l.lo, 60 end
    local lo
    for L = l.lo, 60 do
        if handsAt[L][hand][l.inv] then
            lo = L
            break
        end
    end
    if not lo then return 61, 0 end
    local hi = lo
    while hi < 60 and handsAt[hi + 1][hand][l.inv] do hi = hi + 1 end
    return lo, hi
end

-- Sets the spec (and Forever Leveling BiS's setup pick). Returns true when the levels pieces fit their slots changed.
-- That addon answers with the setup in force at the character's level, which is the spec's default whenever nothing
-- else was picked (a fury warrior below 20: "twohand"): such an answer is no pick, or the plan would never dual wield.
function ns.SetSpec(spec, pick)
    local C = ns.ClassData()
    if not C then return false end
    local valid = false
    for _, s in ipairs(C.specs) do
        if s == spec then valid = true end
    end
    if not valid then spec = C.specs[1] end
    if pick then
        local list = Options(C, spec, ns.Level())
        if pick == list[1] then pick = nil end
    end
    if spec == ns.spec and pick == ns.pick and handsAt[1] then return false end
    local newSpec = spec ~= ns.spec
    ns.spec, ns.pick = spec, pick
    Hands()
    if newSpec and ns.Scroll and ns.Scroll.ForClass then ns.Scroll.ForClass() end     -- (kinds for some specs only)
    return ns.Refit()
end

-- Works out again from which to which level every piece fits its slot (after a change of spec). Returns true when
-- one changed.
function ns.Refit()
    local changed = false
    for _, l in ipairs(lines) do
        local req, upto = Fit(l)
        if req ~= l.req or upto ~= l.upto then
            changed = true
            l.req, l.upto = req, upto
            for _, c in ipairs(l.entries) do c.req, c.upto = req, upto end
        end
    end
    return changed
end

-- The level this class can wear a row of Data.lua from, whatever the hands: mail and plate from 40, polearms from 20.
-- nil when it cannot wear it at all (armor too heavy, a relic of another class, a shield it does not carry).
local function From(C, req, cls, sub, inv)
    local D = ns.DATA
    if cls == 4 and ARMOR_INV[inv] and sub >= 1 and sub <= 4 then
        if sub > C.armor then return nil end
        if C.armor >= 3 and sub == C.armor and req < D.armorUpgrade then req = D.armorUpgrade end
    elseif cls == 4 and inv == 28 and sub ~= C.relic then
        return nil                                      -- a relic of another class (or a class that carries none)
    elseif inv == 14 and not C.shield then
        return nil                                      -- a shield for a class that carries none
    elseif cls == 2 and req < WeaponFrom(C, sub) then
        req = WeaponFrom(C, sub)                        -- (polearms from 20; below 10 only the start weapons)
    end
    return req
end

-- `final`: entering the world, the last chance: a race the game still cannot tell counts as unknown (startAny)
function ns.LoadData(final)
    if ns.loaded then return ns.loaded.items, ns.loaded.cands end       -- the raw lines are gone after the first run
    local D = ns.DATA
    local class = ns.Class()
    if not class then return 0, 0 end                                  -- the game does not know it yet: at the login
    if type(UnitRace) == "function" then                               -- (the third answer is the race id)
        local ok, _, _, id = pcall(UnitRace, "player")
        ns.race = ok and type(id) == "number" and id or nil
        -- a class with start weapons waits for its race like an unknown class (tried again at the login and on
        -- entering the world); the rogue has none and never waits
        if not ns.race and not final and D.classes[class] and D.classes[class].start then return 0, 0 end
    end
    ns.class = class
    local C = D.classes[class]
    local item, byId = ns.item, ns.byId
    ns.loaded = { items = 0, cands = 0 }
    for _, group in ipairs(D.groups) do ns.cands[group] = {} end
    if not C then                                                      -- a class the addon does not know: no lists
        D.items, D.cands = nil, nil
        return 0, 0
    end
    ns.spec = C.specs[1]
    Hands()
    for _, k in ipairs(C.useful) do useful[k] = true end
    -- the random suffixes: bonus id -> { no, name, share = { stat = share }, caster, got = { [budget] = stats } }
    for bonus, line in pairs(D.suffix) do
        local f = Split(line)
        suffix[bonus] = { no = tonumber(f[1]), name = f[2], share = Pairs(f[3]), caster = f[4] == "c", got = {} }
    end
    -- per suffix list: which bonus ids are in it, and which bonus id an auction house suffix number stands for
    -- (0 when two of the list share a number: then only a real listing can tell)
    local trees = {}
    for i, list in ipairs(D.trees) do
        local t = { list = list, has = {}, byNo = {} }
        for pos, bonus in ipairs(list) do
            t.has[bonus] = pos
            local no = suffix[bonus].no
            t.byNo[no] = (t.byNo[no] == nil) and bonus or 0
        end
        trees[i] = t
    end
    -- only the rows of this class (its letter in the last field), and only their items
    local mine, letter = {}, C.letter
    for _, group in ipairs(D.groups) do
        local rows = {}
        for i, line in ipairs(D.cands[group] or {}) do
            local f = Split(line)
            if f[8] and f[8]:find(letter, 1, true) then
                local cls, sub, inv = (f[7] or ""):match("^(%-?%d+)%.(%-?%d+)%.(%-?%d+)$")
                local lo = From(C, tonumber(f[2]), tonumber(cls), tonumber(sub), tonumber(inv))
                if lo then
                    rows[#rows + 1] = { f = f, i = i, lo = lo, inv = tonumber(inv), t = f[7] }
                    mine[tonumber(f[1])] = true
                end
            end
        end
        mine[group] = rows
    end
    for _, line in ipairs(D.items) do
        local f = Split(line)
        local id = tonumber(f[1])
        if mine[id] then
            base[id] = { id = id, name = f[2], quality = tonumber(f[3]), unique = f[4] == "1", side = tonumber(f[5]),
                req = tonumber(f[6]), tree = trees[tonumber(f[7])], budget = tonumber(f[8]), cdps = tonumber(f[9]), lines = {} }
            byId[id] = {}
        end
    end
    for _, group in ipairs(D.groups) do
        local list = ns.cands[group]
        for _, r in ipairs(mine[group]) do
            local f = r.f
            local b = base[tonumber(f[1])]
            local l = { group = group, lo = r.lo, inv = r.inv, t = r.t, kind = f[3], dps = tonumber(f[4]) or 0, speed = tonumber(f[5]) or 0,
                own = Pairs(f[6]), n = r.i * SPREAD, entries = {} }
            l.req, l.upto = Fit(l)
            lines[#lines + 1] = l
            if b.tree then
                b.lines[#b.lines + 1] = l           -- its versions are made when asked for (ns.Variant)
            else
                local key = b.id .. ":0"
                local it = item[key]
                if not it then
                    it = { key = key, id = b.id, bonus = 0, name = b.name, quality = b.quality, unique = b.unique, side = b.side,
                        req = b.req, stats = l.own }
                    item[key] = it
                    byId[b.id][0] = key
                    ns.loaded.items = ns.loaded.items + 1
                end
                local c = { key = key, item = it, req = l.req, upto = l.upto, kind = l.kind, dps = l.dps, speed = l.speed,
                    inv = l.inv, t = l.t, n = l.n }
                l.entries[1] = c
                list[#list + 1] = c
                ns.loaded.cands = ns.loaded.cands + 1
            end
        end
    end
    D.items, D.cands = nil, nil        -- the raw lines are not needed again
    return ns.loaded.items, ns.loaded.cands
end

-- The list key of one version of an item ("id:bonus"), made now if it was not there yet. nil when the lists hold
-- no such piece: an item they do not know, a suffix it does not come with, or a version of no use to this class
-- (armor or jewelry without a stat it values; a weapon whose caster suffix cuts its damage to a number the
-- lists do not have).
function ns.Variant(id, bonus)
    local known = ns.byId[id]
    if not known then return nil end
    local key = known[bonus]
    if key ~= nil then return key or nil end
    local b = base[id]
    local t = b.tree
    if not t or not t.has[bonus] then return nil end
    local suf = suffix[bonus]
    local got = suf.got[b.budget]
    if not got then                             -- what this suffix gives on an item of this stat budget
        got = {}
        for k, share in pairs(suf.share) do
            local v = floor(share * b.budget / 10000 + 0.5)
            if v ~= 0 then got[k] = v end
        end
        suf.got[b.budget] = got
    end
    local it
    for _, l in ipairs(b.lines) do
        local weapon = l.kind ~= ""
        local cut = weapon and suf.caster
        local ok = weapon and not (cut and not b.cdps)
        if not weapon then
            for k, v in pairs(got) do
                if useful[k] and v > 0 then
                    ok = true
                    break
                end
            end
            if not ok then
                for k, v in pairs(l.own) do
                    if useful[k] and v > 0 then
                        ok = true
                        break
                    end
                end
            end
        end
        if ok then
            if not it then
                local stats = {}
                for k, v in pairs(l.own) do stats[k] = v end
                for k, v in pairs(got) do stats[k] = (stats[k] or 0) + v end
                key = id .. ":" .. bonus
                it = { key = key, id = id, bonus = bonus, quality = b.quality, unique = b.unique, side = b.side, req = b.req,
                    name = (suf.name ~= "") and (b.name .. " " .. suf.name) or b.name, stats = stats }
                ns.item[key] = it
                ns.loaded.items = ns.loaded.items + 1
            end
            local list = ns.cands[l.group]
            local c = { key = key, item = it, req = l.req, upto = l.upto, kind = l.kind, dps = cut and b.cdps or l.dps,
                speed = l.speed, inv = l.inv, t = l.t, n = l.n + t.has[bonus] }
            l.entries[#l.entries + 1] = c
            list[#list + 1] = c
            ns.loaded.cands = ns.loaded.cands + 1
        end
    end
    known[bonus] = it and key or false
    return it and key or nil
end

-- Makes every version of every item (the tests count them; the game never needs them all).
function ns.ExpandAll()
    for id, b in pairs(base) do
        if b.tree then
            for _, bonus in ipairs(b.tree.list) do ns.Variant(id, bonus) end
        end
    end
    return ns.loaded.items, ns.loaded.cands
end

-- The auction house suffix number a bonus id goes by (nil for one the lists do not know).
function ns.SuffixNo(bonus)
    local suf = suffix[bonus]
    return suf and suf.no or nil
end

-- The bonus id a row "item + suffix number" stands for: a number, 0 when two versions of that item share the
-- number, nil when the item does not come with that suffix (or is not on the lists).
local function BonusOf(id, no)
    local b = base[id]
    return b and b.tree and b.tree.byNo[no] or nil
end

function ns.Name(key)
    local it = ns.item[key]
    return it and it.name or ("Item " .. tostring(key))
end

-- Item links -------------------------------------------------------------------------------------------
-- A link reads "item:id:" + 11 fields + how many bonus ids follow + those bonus ids. Random stats ("of the
-- Monkey") are one of the bonus ids, and the lists know every variant of an item by that id.
-- -> key, exact, item id, first bonus id, how many bonus ids
-- exact = false when the link carries bonus ids the lists do not know: then the key is only the plain item,
-- good enough to count as owned but never to buy.
local parts = {}
function ns.LinkKey(link)
    local body = type(link) == "string" and link:match("item:([%-%d:]+)")
    if not body then return nil, false end
    local id = tonumber(body:match("^(%d+)"))
    local known = id and ns.byId[id]
    if not known then return nil, false, id end
    local n = 0
    for field in (body .. ":"):gmatch("([^:]*):") do
        n = n + 1
        parts[n] = field
        if n == 40 then break end
    end
    local count = n >= 13 and tonumber(parts[13]) or 0
    if count == 0 then return known[0], known[0] ~= nil, id, nil, 0 end
    if count < 0 or count ~= floor(count) or 13 + count > n then return nil, false, id end     -- not a link we can read
    local first = tonumber(parts[14])
    for i = 14, 13 + count do
        local bonus = tonumber(parts[i])
        local key = bonus and bonus ~= 0 and ns.Variant(id, bonus)
        if key then return key, true, id, first, count end
    end
    return known[0], false, id, first, count
end

-- The auction house list names a random-stat piece by a suffix number; the link (and our lists) use a bonus id.
-- The lists know which suffix number each version of an item carries; a real listing that showed otherwise is
-- believed first (db.seen).
-- The list key a row "item id + suffix" stands for, or nil when the lists hold no such piece.
-- Second result: true when that answer is firm (nothing a real listing still has to tell).
local SEEN_FOR = 7 * 24 * 3600     -- seconds a listing's "this is no piece of ours" is believed before it is read again
function ns.Guess(id, suffix)
    local known = ns.byId[id]
    if not known then return nil, false end
    if suffix == 0 then return known[0], true end
    local db, name = ns.db, id .. ":" .. suffix
    local seen = db and db.seen[name]
    local key = seen and ns.Variant(id, seen)
    if key then return key, true end
    local bonus = BonusOf(id, suffix)
    if bonus and bonus ~= 0 then
        key = ns.Variant(id, bonus)
        if key then return key, false end       -- the lists' own answer: right, but only a real listing may be bought
        return nil, true                        -- a version of no use to this class: nothing to read
    end
    -- a number the lists do not know for this item (or two versions share it). A real listing that said "none of
    -- ours" is believed, but only for a while: one listing can be wrong about the next (read again after a week).
    local at = seen and db.seenAt[name]
    return nil, type(at) == "number" and time() - at < SEEN_FOR
end

-- A real listing showed which bonus id this item + suffix carries.
function ns.Learn(id, suffix, bonus)
    local db, name = ns.db, id .. ":" .. suffix
    if not db then return end
    db.seen[name], db.seenAt[name] = bonus, time()
end

-- Money ------------------------------------------------------------------------------------------------
local GOLD, SILVER, COPPER = "|cffffd100g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
function ns.Coins(copper, exact)
    copper = floor((tonumber(copper) or 0) + 0.5)
    local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
    if g > 0 then
        if exact and c > 0 then return g .. GOLD .. " " .. s .. SILVER .. " " .. c .. COPPER end
        return s > 0 and (g .. GOLD .. " " .. s .. SILVER) or (g .. GOLD)
    end
    if s > 0 then return c > 0 and (s .. SILVER .. " " .. c .. COPPER) or (s .. SILVER) end
    return c .. COPPER
end

-- Who is playing ---------------------------------------------------------------------------------------
function ns.Level()
    local level = tonumber(UnitLevel and UnitLevel("player")) or 1
    if level < 1 then return 1 end
    if level > 60 then return 60 end
    return floor(level)
end

-- The level range the lists are made for: from, to. "From" follows the character's level until the player picks
-- another start; "to" is `ns.SPAN` levels further until the player picks another end (an end the character has
-- outgrown no longer counts).
function ns.Range()
    local me, level = ns.me, ns.Level()
    local from = me and tonumber(me.from) or level
    -- a start picked to shop ahead only counts until the character gets there: levels already passed are not shopped for
    if from ~= from or from < level then from = level elseif from > 60 then from = 60 end
    from = floor(from)
    local to = me and tonumber(me.to)
    if not to or to ~= to or to < from then to = from + ns.SPAN end
    if to > 60 then to = 60 end
    return from, floor(to)
end

-- Sets the range (nil = automatic: from the character's level, ns.SPAN levels far). Returns the range now in force.
function ns.SetRange(from, to)
    local me = ns.me
    if me then
        from, to = tonumber(from), tonumber(to)
        if from and from == from then
            from = floor(from < 1 and 1 or from > 60 and 60 or from)
            me.from = (from > ns.Level()) and from or nil        -- the character's own level (or below) means "follow my level"
        else
            me.from = nil
        end
        if to and to == to then
            to = floor(to < 1 and 1 or to > 60 and 60 or to)
            local start = me.from or ns.Level()
            if to < start then to = start end
            me.to = to
        else
            me.to = nil
        end
    end
    local a, b = ns.Range()
    ns.SEGMENTS[1][1], ns.SEGMENTS[1][2] = a, b
    ns.dirty = true
    return a, b
end

-- 1 = Alliance, 2 = Horde, nil = not known (then pieces of both sides stay in the lists)
function ns.Side()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return (faction == "Alliance" and 1) or (faction == "Horde" and 2) or nil
end

-- An event this game does not know makes RegisterEvent fail: never let that stop the addon.
function ns.Listen(frame, event)
    return (pcall(frame.RegisterEvent, frame, event))
end

-- Saved settings ---------------------------------------------------------------------------------------
local function Amount(v, default)
    if type(v) ~= "number" or v ~= v or v < 0 or v == huge then return default end
    return floor(v + 0.5)
end

-- The account-wide part: what real listings taught about random stats.
function ns.InitDB()
    local db = _G.LevelOutfitterDB
    if type(db) ~= "table" then
        db = {}
        _G.LevelOutfitterDB = db
    end
    if type(db.chars) ~= "table" then db.chars = {} end
    if type(db.seen) ~= "table" then db.seen = {} end       -- "itemId:suffix" -> the bonus id a real listing showed
    if type(db.seenAt) ~= "table" then db.seenAt = {} end   -- ... and when (time())
    ns.db = db
    return db
end

-- This character's part (gold limit, gold spent, what it owns), set up at login when the game knows who plays.
function ns.Login(final)
    local db = ns.db or ns.InitDB()
    if not ns.loaded then                             -- the class (or its race) was not known while the files loaded
        ns.LoadData(final)
        if ns.Scroll and ns.Scroll.ForClass then ns.Scroll.ForClass() end
    end
    local name = UnitName and UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    local id = tostring(name) .. "-" .. tostring(realm)
    local me = db.chars[id]
    if type(me) ~= "table" then
        me = {}
        db.chars[id] = me
    end
    me.budget = Amount(me.budget, ns.DEFAULTS.budget)
    me.spent = Amount(me.spent, 0)
    -- the level range picked for the lists (nil = automatic); anything that is no level is dropped
    for _, field in ipairs({ "from", "to" }) do
        local v = me[field]
        if type(v) ~= "number" or v ~= v or v < 1 or v > 60 then me[field] = nil else me[field] = floor(v) end
    end
    -- pieces the player says they have: "itemId:bonusId" -> how many copies. They cost nothing in a plan.
    -- (a new character starts with what its class's data says it owns: the rogue's two swords. When the class is
    -- not known yet that waits for the next login step: me.unseeded)
    if type(me.owned) ~= "table" then
        me.owned, me.unseeded = {}, true
    end
    local C = ns.ClassData()
    if me.unseeded and C then
        for key, count in pairs(C.owned) do me.owned[key] = count end
        me.unseeded = nil
    end
    -- 0.6.0 gave every character that logged in the rogue's two swords as "owned", alts of other classes too. Taken
    -- off once from a character of another class (a sword really in its bags is found by the normal reading anyway).
    if C and ns.class ~= "ROGUE" and not me.rogueSeedOff and type(me.owned) == "table" then
        for key, count in pairs(ns.DATA.classes.ROGUE.owned) do
            if me.owned[key] == count then me.owned[key] = nil end
        end
        me.rogueSeedOff = true
    end
    for _, field in ipairs({ "owned", "bank", "mail" }) do
        local t = me[field]
        if type(t) ~= "table" then
            t = {}
            me[field] = t
        end
        for key, count in pairs(t) do
            if type(key) ~= "string" or type(count) ~= "number" or count ~= count or count < 1 then t[key] = nil end
        end
    end
    -- bought and on its way: key -> { n = copies the mailbox has not shown yet, maybe = { prices of doubted buys }, at }
    if type(me.transit) ~= "table" then me.transit = {} end
    for key, t in pairs(me.transit) do
        if type(key) ~= "string" or type(t) ~= "table" or type(t.n) ~= "number" or t.n ~= t.n or type(t.maybe) ~= "table"
            or t.n < 1 or t.n > 1000 or t.base ~= nil then      -- (t.base: a note in an older, different format)
            me.transit[key] = nil
        else
            for i = #t.maybe, 1, -1 do
                local price = t.maybe[i]
                if type(price) ~= "number" or price ~= price or price < 0 then table.remove(t.maybe, i) end
            end
            t.n = floor(t.n)
            if #t.maybe > t.n then t.n = #t.maybe end       -- every doubted buy is one of the copies on their way
            if type(t.at) ~= "number" then t.at = 0 end
        end
    end
    ns.me = me
    ns.SEGMENTS[1][1], ns.SEGMENTS[1][2] = ns.Range()      -- (a saved end the character has outgrown no longer counts)
    if ns.Score then ns.Score.stale = true end       -- the other addon's weights can be asked for from now on
    -- (while the class is still unknown the consumables and the bar wait for the second login step: with no
    -- kinds known yet the bar would throw away what it has saved about them)
    if ns.loaded then
        if ns.Scroll then ns.Scroll.Login(me) end
        if ns.Bar then ns.Bar.Login(me) end
    end
    if ns.Own then ns.Own.Dirty() end
    return me
end

ns.LoadData()

-- Saved settings only exist once the game says the addon has loaded (not while these files run).
if CreateFrame then
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    ns.Listen(loader, "PLAYER_LOGIN")
    ns.Listen(loader, "PLAYER_ENTERING_WORLD")
    loader:SetScript("OnEvent", function(self, event, name)
        if event == "PLAYER_LOGIN" then
            ns.Login()
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- the class was still unknown at the login: try again now (Login makes the lists, then the rest)
            if not ns.loaded and ns.db then ns.Login(true) end
        elseif name == ADDON then
            self:UnregisterEvent("ADDON_LOADED")
            ns.InitDB()
            if IsLoggedIn and IsLoggedIn() then ns.Login() end      -- loaded after login: nobody will say PLAYER_LOGIN
        end
    end)
end

-- How many of an item are in the bags (not the bank).
function ns.Have(id)
    local count = (type(C_Item) == "table" and C_Item.GetItemCount) or GetItemCount
    if type(count) ~= "function" then return 0 end
    local ok, n = pcall(count, id)
    n = ok and tonumber(n) or 0
    return (n == n and n > 0) and floor(n) or 0
end

-- /lo bar        the buff buttons under the character: on or off, "size 40", "height 33", "reset"
-- /lo press      try buying consumables with one click again (after the game once gave no answer to it)
-- /lo            opens or closes the window
-- /lo status     what the addon knows right now
-- /lo forget     forget buys that are still marked "on their way" (after a buy that never arrived)
-- /lo spent 0    set the gold counted as spent so far (in gold)
-- /lo scale 1.2  window size        /lo auto   open with the auction house or not
-- /lo levels 14 24   the levels the lists are made for      /lo levels auto   from my level, ten levels far
function ns.Status()
    local C = ns.ClassData()
    local out = { C and C.ready and ("Level Outfitter %s: knows %d pieces for a %s (every suffix of every green), item data from %s."):format(
        ns.VERSION, C.counts.items, C.name, ns.DATA.made)
        or ("Level Outfitter %s: no lists for this class yet (it knows rogue, warrior and warlock)."):format(ns.VERSION) }
    if ns.Scan and ns.Scan.Status then
        for _, line in ipairs(ns.Scan.Status()) do out[#out + 1] = line end
    end
    if ns.Score then out[#out + 1] = ns.Score.Status() end
    if ns.me then
        local from, to = ns.Range()
        out[#out + 1] = ("Lists for levels %d to %d. Gold limit %s, spent so far %s."):format(from, to, ns.Coins(ns.me.budget),
            ns.Coins(ns.me.spent))
    end
    if ns.Bar and ns.Bar.Status then out[#out + 1] = ns.Bar.Status() end
    return out
end

if SlashCmdList then
    SLASH_LEVELOUTFITTER1, SLASH_LEVELOUTFITTER2 = "/lo", "/leveloutfitter"
    SlashCmdList.LEVELOUTFITTER = function(msg)
        local word, value, third = (type(msg) == "string" and msg or ""):lower():match("^%s*(%S*)%s*(%S*)%s*(%S*)")
        local number = tonumber(value)
        local function Print(line) print("|cffffd100Level Outfitter:|r " .. line) end
        if word == "bar" and ns.Bar then
            Print(ns.Bar.Set(value, tonumber(third)))
        elseif word == "press" and ns.db then
            ns.db.pressBuy, ns.db.pressMiss = nil, nil
            Print("one click on Buy tries to buy a consumable outright again.")
        elseif word == "forget" and ns.Own then
            Print(ns.Own.Forget() and "forgot the buys that were still on their way."
                or "a buy may still be answered. Close the auction house, then try again.")
        elseif word == "spent" and number and number == number and number >= 0 and number < 1000000 and ns.me then
            ns.me.spent = floor(number * 10000 + 0.5)
            if ns.Shop then ns.Shop.SetBudget(ns.me.budget) end       -- the list is fitted to what is left now
            Print("counting " .. ns.Coins(ns.me.spent) .. " as spent so far.")
        elseif word == "levels" and ns.me then
            local from, to
            if value == "auto" or value == "" then
                from, to = ns.SetRange(nil, nil)
            else
                from, to = ns.SetRange(number, tonumber(third))
            end
            if ns.Shop and ns.Shop.RangeChanged then ns.Shop.RangeChanged() end
            Print(("lists for levels %d to %d."):format(from, to))
        elseif word == "scale" and number and ns.UI and ns.UI.Scale(number) then
            Print("window size set to " .. ns.db.scale .. ".")
        elseif word == "auto" and ns.db then
            ns.db.auto = ns.db.auto == false
            Print(ns.db.auto and "opens with the auction house." or "opens only with /lo.")
        elseif word == "" and ns.UI and ns.UI.Toggle then
            ns.UI.Toggle()
        elseif word == "status" or word == "" then
            for _, line in ipairs(ns.Status()) do print(line) end
        else
            Print("/lo   /lo status   /lo levels 14 24   /lo spent 0   /lo forget   /lo scale 1.2   /lo auto   /lo bar   /lo press")
        end
    end
end

-- ==============================================================================================================
-- Scores (kept in this file so that an update of the addon needs no new file: /reload is enough)
do
-- Score.lua: what a piece is worth at a level. Pure logic, plus one optional read of another addon's numbers.
--
-- The stat weights are those of the Forever Leveling BiS addon for the character's class and spec (the rogue: combat),
-- read LIVE from it when it is loaded (its public table ForeverLevelingBiS_API), so an update of that addon, a weight
-- profile or another spec picked there is followed at once. Without it, the copy in Data.lua is used. A piece bought
-- from our lists is then an upgrade there too.
--
-- The score follows that addon's own (its Scoring.lua ScoreParts): every stat times its weight, plus the weapon:
--   main hand:  damage per second x dps + (speed - speedRef) x 10 x speed     (never below 0; speedRef when the
--               weights have none: 3.3 for a two-hander, 2.4 for any other)
--   off hand:   damage per second x ohDps (half of dps without one) + (speed - ohSpeedRef) x 10 x ohSpeed
--   ranged:     damage per second x rangedDps (0 without one) + (speed - rangedSpeedRef) x 10 x rangedSpeed
-- The ROGUE has the player's own rules on top (the same ones tools/wowhead/build_rogue.py plans with):
--   off hand:   damage per second x ohDps, counted `offSlow` lower for a weapon of speed `offFast` or slower.
--               A fast off hand is wanted for poisons, so that addon's own off-hand speed weight is not used.
--   thrown:     1 point per point of damage when the weights have no rangedDps.
--   no daggers, and only thrown weapons in the ranged slot: Data.lua holds nothing else for those slots.
local Score = {}
ns.Score = Score

local floor, max, type, pairs, pcall, sort, tonumber, huge = math.floor, math.max, type, pairs, pcall, table.sort,
    tonumber, math.huge
local NLEV = ns.DATA.P.levels
local R = ns.DATA.S
local ROLE = { ["Main Hand"] = 1, ["Off Hand"] = 2, ["Ranged"] = 3 }

Score.SPEC = "combat"  -- the rogue's spec
Score.rev = 0          -- goes up when the weights change: every score worked out before, and every plan, is stale
Score.source = nil     -- "live" or "built-in"
Score.stale = true     -- the weights have to be read (again) before the next use

local rows, at         -- rows[b] = the weights of bracket b; at[level] = b

-- Only whole, finite numbers are weights. Anything else in a table we are handed is dropped.
local function Clean(w)
    local out = {}
    for k, v in pairs(w) do
        if type(k) == "string" and type(v) == "number" and v == v and v ~= huge and v ~= -huge then out[k] = v end
    end
    return out
end

-- Schools a spec never scores, whatever Forever Leveling BiS says (user 22 Nov, arcane mage offered "of Frozen Wrath":
-- "we should be searching for just spell damage and not frozen dmg"). Same table in tools/wowhead/build_rogue.py.
local SCHOOL_OFF = { MAGE = { arcane = { frosplpwr = true, firsplpwr = true } } }
local function SchoolOff(w)
    local off = SCHOOL_OFF[ns.class] and SCHOOL_OFF[ns.class][ns.spec]
    if off then
        for k in pairs(off) do w[k] = nil end
    end
    return w
end

local function Same(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function SameRows(r1, a1, r2, a2)
    if not r1 or not r2 or #r1 ~= #r2 then return false end
    for i = 1, #r1 do
        if not Same(r1[i], r2[i]) then return false end
    end
    for L = 1, NLEV do
        if a1[L] ~= a2[L] then return false end
    end
    return true
end

-- The setup the other addon's weights are asked for at a level: the rogue's always "dualwield" (as it was).
local function SetupFor(L)
    if ns.class == "ROGUE" then return "dualwield" end
    return ns.SetupAt(L)
end

-- The copy in Data.lua for the class and spec: one row per bracket (a setup with weights of its own, the shaman's
-- enhancement with a shield, takes those), each with the last level it covers.
local function BuiltIn()
    local C = ns.ClassData()
    local spec = ns.spec or (C and C.specs[1])
    local out, map, n, prev = {}, {}, 0, nil
    if not C then return out, map end
    local own = C.setupWeights and C.setupWeights[spec]
    for L = 1, NLEV do
        local list = own and own[SetupFor(L)] or C.weights[spec]
        local row = list[#list]
        for _, r in ipairs(list) do
            if L <= (tonumber(r.upTo) or NLEV) then
                row = r
                break
            end
        end
        if row ~= prev then
            local w = SchoolOff(Clean(row))
            w.upTo = nil
            n = n + 1
            out[n], prev = w, row
        end
        map[L] = n
    end
    return out, map
end

-- The other addon's weights for every level, or nil when it is not there (or answers nonsense).
local function Live()
    local api = _G.ForeverLevelingBiS_API
    if type(api) ~= "table" or type(api.GetWeights) ~= "function" or not ns.Known() then return nil end
    local rogue = ns.class == "ROGUE"
    local out, map, n, prev = {}, {}, 0, nil
    for L = 1, NLEV do
        local ok, w = pcall(api.GetWeights, ns.class, rogue and Score.SPEC or ns.spec, L, SetupFor(L))
        if not ok or type(w) ~= "table" then return nil end
        w = SchoolOff(Clean(w))
        w.upTo = nil
        if rogue then
            -- weights that give a main-hand weapon's damage no value are no weights for a rogue: not believed
            if not (w.dps and w.dps > 0) then return nil, nil, "its weights give weapon damage no value" end
        elseif next(w) == nil then
            return nil, nil, "its weights are empty"
        end
        if not prev or not Same(prev, w) then
            n = n + 1
            out[n], prev = w, w
        end
        map[L] = n
    end
    return out, map
end

-- Told by the other addon that its answers may have changed (level, spec, weights): read again before the next use.
local hooked = false
local function Hook()
    if hooked then return end
    local api = _G.ForeverLevelingBiS_API
    if type(api) ~= "table" or type(api.OnChanged) ~= "function" then return end
    hooked = pcall(api.OnChanged, function()
        Score.stale = true
        if ns.OnWeights then ns.OnWeights() end
    end)
end

-- The spec (and the weapon setup picked) the other addon has for this character, when it is this class's.
local function TheirSpec()
    local api = _G.ForeverLevelingBiS_API
    if type(api) ~= "table" or type(api.GetSpec) ~= "function" then return nil end
    local ok, spec, setup, class = pcall(api.GetSpec)
    if ok and type(spec) == "string" and class == ns.class then
        return spec, type(setup) == "string" and setup or nil
    end
end

-- Reads the weights. Returns true when they are not the ones used so far.
function Score.Load()
    Hook()
    -- the spec: the rogue's is always combat; another class plans for the spec the other addon has for it (asked
    -- here, not every time the window draws: it is heavy)
    local spec, setup = TheirSpec()
    Score.other = nil
    local refit = false
    if ns.class == "ROGUE" then
        if spec and spec ~= Score.SPEC then Score.other = spec end
        refit = ns.SetSpec(Score.SPEC, nil)
    elseif ns.Known() then
        refit = ns.SetSpec(spec, setup)
    end
    Score.otherAt = GetTime and GetTime() or nil
    local r, a, why = Live()
    local source = "live"
    if not r then
        r, a = BuiltIn()
        source = "built-in"
    end
    Score.stale = false
    Score.source = source
    -- the other addon is there but its answer was not usable: say so (not "not loaded")
    if source ~= "live" and not why and type(_G.ForeverLevelingBiS_API) == "table" then
        why = ns.Known() and ("it gave no usable weights for " .. ns.ClassLabel()) or "no lists for this class yet"
    end
    Score.why = (source ~= "live") and why or nil
    if SameRows(rows, at, r, a) and not refit then return false end
    rows, at = r, a
    Score.rev = Score.rev + 1
    return true
end

-- The level -> bracket map and the number of brackets, with the weights fresh. While the other addon has not
-- answered yet (it only does after the login) every use asks again: its numbers win as soon as they are there.
local askedAt
function Score.Use()
    local again = Score.stale or not rows
    if not again and Score.source ~= "live" and _G.ForeverLevelingBiS_API then
        local now = GetTime and GetTime() or nil
        again = not now or not askedAt or now - askedAt >= 1        -- at most once a second
        if again then askedAt = now end
    end
    if again then Score.Load() end
    return at, #rows
end

function Score.Weights(level)
    local map = Score.Use()
    return rows[map[level] or #rows]
end

-- The weights of bracket b exactly as Score.Of reads them (no reload: for a caller that just ran Score.Use).
function Score.Row(b)
    return rows and rows[b]
end

local function Order(stats)        -- stat names in a fixed order, so a score adds up the same way everywhere
    local order = {}
    for k in pairs(stats) do order[#order + 1] = k end
    sort(order)
    return order
end

-- The score of entry `c` (one of ns.cands[group]) in weight bracket `b`, to one decimal. Cached on the entry.
function Score.Of(c, group, b)
    local s = c.s
    if not s or c.rev ~= Score.rev then
        s = {}
        c.s, c.rev = s, Score.rev
    end
    local v = s[b]
    if v then return v end
    local w, it = rows[b], c.item
    local stats, order = it.stats, it.order
    if not order then
        order = Order(stats)
        it.order = order
    end
    local t = 0
    for i = 1, #order do
        local k = order[i]
        t = t + stats[k] * (w[k] or 0)
    end
    local role, dps, speed = ROLE[group], c.dps, c.speed
    if ns.class ~= "ROGUE" then
        -- every other class: Forever Leveling BiS's own weapon parts (only weapons have damage)
        if dps > 0 then
            if role == 1 then
                local ref = w.speedRef or (c.inv == 17 and R.twoHandRef or R.speedRef)
                t = t + max(0, dps * (w.dps or 0) + (speed - ref) * 10 * (w.speed or 0))
            elseif role == 2 then
                t = t + max(0, dps * (w.ohDps or 0.5 * (w.dps or 0))
                    + (speed - (w.ohSpeedRef or R.speedRef)) * 10 * (w.ohSpeed or 0))
            elseif role == 3 then
                t = t + max(0, dps * (w.rangedDps or 0)
                    + (speed - (w.rangedSpeedRef or R.rangedSpeedRef)) * 10 * (w.rangedSpeed or 0))
            end
        end
    elseif role == 1 then
        t = t + max(0, dps * (w.dps or 0) + (speed - (w.speedRef or R.speedRef)) * 10 * (w.speed or 0))
    elseif role == 2 then
        local part = max(0, dps * (w.ohDps or 0.5 * (w.dps or 0)))
        t = t + (speed < R.offFast and part or part * (1 - R.offSlow))
    elseif role == 3 then
        t = t + max(0, dps * (w.rangedDps or R.thrownDps)
            + (speed - (w.rangedSpeedRef or R.rangedSpeedRef)) * 10 * (w.rangedSpeed or 0))
    end
    v = floor(t * 10 + 0.5) / 10
    s[b] = v
    return v
end

-- The score at a level (for the tests and the window).
function Score.At(c, group, level)
    local map = Score.Use()
    return Score.Of(c, group, map[level] or #rows)
end

-- The rogue only: the spec the other addon scores this character for, when it is not combat. The answer is
-- remembered: it is asked again when that addon says something changed, and every few seconds at most.
local OTHER_EVERY = 5
function Score.OtherSpec()
    local now = GetTime and GetTime() or nil
    if Score.stale or not rows or not now or not Score.otherAt or now - Score.otherAt >= OTHER_EVERY then Score.Load() end
    return Score.other
end

-- What the lists are made for, in plain words: "combat rogue", "arms warrior", "destruction warlock".
function ns.ClassLabel()
    local C = ns.ClassData()
    if not C then return "this class" end
    local spec = ns.class == "ROGUE" and Score.SPEC or ns.spec or C.specs[1]
    return (C.specNames[spec] or spec) .. " " .. C.name
end

-- One line for /lo status.
function Score.Status()
    Score.Use()
    local line = (Score.source == "live") and ("Stat weights: live from Forever Leveling BiS (" .. ns.ClassLabel() .. ").")
        or ("Stat weights: built-in copy of Forever Leveling BiS " .. tostring(ns.DATA.flb) .. " for " .. ns.ClassLabel() .. " ("
            .. (Score.why or "that addon is not loaded") .. ").")
    local other = Score.OtherSpec()
    if other then
        line = line .. " Forever Leveling BiS is set to " .. other .. " for this character: pick Combat there so both agree."
    end
    return line
end

-- What a piece gives, for the Stats column: "9.1 dps fast, +3 Agi, +3 Sta".
local LABELS = { { "agi", "Agi" }, { "str", "Str" }, { "sta", "Sta" }, { "atkpwr", "AP" }, { "critPct", "% crit" },
    { "hitPct", "% hit" }, { "expPct", "% expertise" }, { "hastertng", "haste" }, { "dodgePct", "% dodge" },
    { "defrtng", "defense" }, { "spi", "Spi" }, { "int", "Int" } }
-- (classes other than the rogue: their spell and ranged stats too)
local MORE = { { "splpwr", "spell power" }, { "spldmg", "spell damage" }, { "splheal", "healing" },
    { "shasplpwr", "shadow power" }, { "firsplpwr", "fire power" }, { "frosplpwr", "frost power" },
    { "arcsplpwr", "arcane power" }, { "holsplpwr", "holy power" }, { "natsplpwr", "nature power" },
    { "manargn", "mana per 5 s" }, { "rgdatkpwr", "ranged AP" }, { "parryPct", "% parry" }, { "blockPct", "% block" } }
function Score.Text(c, group)
    local parts, n, stats = {}, 0, c.item.stats
    local rogue = ns.class == "ROGUE"
    if c.dps > 0 then
        n = n + 1
        parts[n] = ("%.1f dps"):format(c.dps) .. ((rogue and ROLE[group] == 2) and (c.speed < R.offFast and " fast" or " slow") or "")
    end
    for pass = 1, rogue and 1 or 2 do
        local labels = pass == 1 and LABELS or MORE
        for i = 1, #labels do
            local v = stats[labels[i][1]]
            if v and v ~= 0 then
                n = n + 1
                local label = labels[i][2]
                if label:sub(1, 1) == "%" then
                    parts[n] = v .. label
                else
                    parts[n] = (v > 0 and "+" or "") .. v .. " " .. label
                end
            end
        end
    end
    if n == 0 then return stats.armor and (stats.armor .. " armor") or "" end
    return table.concat(parts, ", ")
end
end
