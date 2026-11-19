-- Bar.lua: a small row of buttons under the character for the buffs from scrolls, elixirs and drinks that have
-- run out, and a watch on how many of each consumable are left in the bags.
--
-- An addon cannot use an item by itself: the game only lets a real click or key press do that. So for each kind
-- whose buff is not on the character and that is in the bags, a button appears, the size of an action button; a
-- click uses the best one the character can use at its level, a lesser one when that is all there is. The button
-- goes away when the buff is on. The buttons are the game's own "secure" item buttons, set up the way
-- NaowhForever's consumable bar sets its buttons up on this game. The game lets nothing about such a button
-- change during a fight, so the row is brought up to date when the fight is over; a button whose buff came on
-- meanwhile is dimmed.
--
-- Some buffs cannot be put on while a stronger one of the same sort is on the character: the game refuses with
-- "A more powerful spell is already active" (a stamina scroll under a priest's Fortitude, say). Such a kind is
-- not offered. The classic pairs are known from the start; anything else is learned the first time the game
-- refuses a click on one of these buttons: the lasting buffs on the character at that moment are noted, and
-- the kind is left out while they are all still there. A further refusal narrows the note down to the buff that
-- does it. No note is trusted for ever: after a rest (an hour at first, longer each time the game confirms it)
-- the kind is offered once more, and a note that turns out wrong goes the moment the kind's own buff is seen on
-- the character together with the noted buffs. What was learned is kept for every character ("/lo bar reset"
-- forgets it).
--
-- Stock: when a kind is down to its last one the button says LAST ONE and a line on screen says so; on entering
-- a city (and at the auction house) the kinds that are down to one or none are listed. Only kinds the character
-- has carried before count, so nobody is nagged about things they never use. Shift + right-click on a button
-- takes its kind off the bar and out of the reminders ("/lo bar reset" brings all back).
local ADDON, ns = ...
local Bar = {}
ns.Bar = Bar

local Scroll = ns.Scroll
local GetTime, time, pairs, ipairs, type, pcall, tonumber, max, min, floor, concat = GetTime, time, pairs, ipairs, type, pcall,
    tonumber, math.max, math.min, math.floor, table.concat

local SIZE, GAP, AT = 40, 6, 33    -- a button's size, the gap between two, how far up the screen (percent of its height)
local MAX = 8                      -- buttons at most
local WAIT = 0.3                   -- news about bags and buffs is gathered this long before the row is done again
local HOLD = 6                     -- after a loading screen the bags are still filling: no stock news for this long
local CITY_AFTER = 2               -- a city's reminder comes this long after arriving
local CITY_EVERY = 60              -- ... and not again within this many seconds (a city's border, a /reload)
local AH_AFTER = 600               -- the auction house reminds too, unless a reminder came within this long
local ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local LONG = 60                    -- a buff that lasts this long, or has no end, can be what blocks a consumable
-- how long a note keeps its kind off the bar, by the number of refusals behind it; then the kind is offered once more
local REST = { 3600, 6 * 3600, 36 * 3600, 9 * 86400, 30 * 86400 }
local CLICK_FOR = 1.5              -- a "more powerful spell" refusal this soon after a click on a button is about that button
local SNOOZE = 300                 -- a refused kind is left out this long when the buffs on the character cannot be listed
local GROUPS, NAMES = 8, 24        -- notes kept per kind, buff names per note
local BOUNCE = "more powerful spell"   -- part of the game's refusal, for when its own text for it is not to be had
local NONE = {}

-- the kinds whose buff the bar watches (the others are used at a moment of the player's choosing)
local BUFFS = { ["Agility elixir"] = true, ["Strength elixir"] = true, ["Agility scroll"] = true, ["Strength scroll"] = true,
    ["Attack power drink"] = true, ["Stamina scroll"] = true, ["Health elixir"] = true, ["Armor elixir"] = true,
    ["Protection scroll"] = true, ["Regeneration elixir"] = true, ["Spirit scroll"] = true }
Bar.BUFFS = BUFFS
local CITIES = { ["Stormwind City"] = true, ["Stormwind"] = true, ["Ironforge"] = true, ["City of Ironforge"] = true,
    ["Darnassus"] = true, ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true, ["The Undercity"] = true,
    ["The Exodar"] = true, ["Silvermoon City"] = true, ["Shattrath City"] = true }
-- Buffs from other players that classic rules put above a scroll. Taken as blocking (like a note the game has
-- confirmed once) until one of them is seen on the character together with the scroll's own buff.
local SEEDS = { ["Stamina scroll"] = { "Power Word: Fortitude", "Prayer of Fortitude" },
    ["Spirit scroll"] = { "Divine Spirit", "Prayer of Spirit" } }
local EVENTS = { "UI_ERROR_MESSAGE", "BAG_UPDATE", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_LEVEL_UP",
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "AUCTION_HOUSE_SHOW",
    "GET_ITEM_INFO_RECEIVED" }

local holder, driver
local buttons = {}                 -- the row's buttons, made as they are needed
local seen = {}                    -- kind -> how many usable ones were in the bags at the last look
local spells = {}                  -- item id -> { name, id } of the spell it casts
local snooze = {}                  -- kind -> left out until this time (a refusal that could not be pinned on a buff)
Bar.buttons, Bar.seen, Bar.spells, Bar.snooze = buttons, seen, spells, snooze
Bar.showing = {}                   -- kind -> true: it had a button at the last look

-- The game hides some answers from addons at times (during a fight, mostly). Such a value may be passed on but
-- never tested or compared. Plain = an ordinary value.
local function Plain(v)
    return not (type(issecretvalue) == "function" and issecretvalue(v))
end

-- A game function that may be missing or fail: its first two results, else nothing. A third result of true means
-- the game hid its answer.
local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    if not Plain(a) or not Plain(b) then return nil, nil, true end
    return a, b
end

-- Settings ------------------------------------------------------------------------------------------------------
local function Settings()
    local db = ns.db
    if type(db) ~= "table" then return {} end
    if type(db.bar) ~= "table" then db.bar = {} end
    return db.bar
end
local function Clamp(value, lo, hi, default)
    local n = tonumber(value)
    if not n or n ~= n then return default end
    return max(lo, min(hi, n))
end
function Bar.Off() return Settings().off == true end
local function Size() return Clamp(Settings().size, 20, 80, SIZE) end
local function At() return Clamp(Settings().at, 5, 95, AT) end

-- What is on the character and in the bags ---------------------------------------------------------------------
-- The spell an item casts (its buff has that spell's id, or at least its name). nil while the game does not know
-- the item yet.
local function SpellOf(id)
    local s = spells[id]
    if s then return s end
    local name, spell = Call(type(C_Item) == "table" and C_Item.GetItemSpell or GetItemSpell, id)
    if type(name) == "string" or type(spell) == "number" then
        s = { name = type(name) == "string" and name or nil, id = type(spell) == "number" and spell or nil }
        spells[id] = s
    end
    return s
end

-- Whether this game lets an addon look for a buff on the character at all.
local function Sees()
    local A = C_UnitAuras
    return type(A) == "table" and (type(A.GetPlayerAuraBySpellID) == "function" or type(A.GetAuraDataBySpellName) == "function")
end

-- true = on the character, false = not, nil = the game will not say right now.
-- A buff found by its NAME that really is the spell of an item of ANOTHER kind (an Agility scroll and an Agility
-- elixir show the same name): it says nothing about this kind. own = the spell ids of this kind's items.
local function Foreign(aura, own, kind)
    local sid = type(aura) == "table" and aura.spellId
    if type(sid) ~= "number" or not Plain(sid) or own[sid] then return false end
    for id, item in pairs(Scroll.byId) do
        if item.kind ~= kind then
            local s = SpellOf(id)
            if s and s.id == sid then return true end
        end
    end
    return false
end

local function HasBuff(s, own, kind)
    local A, unsure = C_UnitAuras, false
    local hides = type(C_Secrets) == "table" and C_Secrets.ShouldSpellAuraBeSecret
    if s.id then
        if hides and Call(hides, s.id) == true then return nil end
        local aura, _, hidden = Call(A.GetPlayerAuraBySpellID, s.id)
        if hidden then unsure = true elseif aura then return true end
    end
    if s.name then
        local aura, _, hidden = Call(A.GetAuraDataBySpellName, "player", s.name, "HELPFUL")
        if hidden then unsure = true elseif aura and not Foreign(aura, own, kind) then return true end
    end
    if unsure then return nil end
    return false
end

-- Whether the buff of one kind is on the character: any rank's. nil = cannot be told right now.
local function Covered(list)
    local unsure, own, kind = false, {}, list[1] and list[1].kind
    for _, item in ipairs(list) do
        local s = SpellOf(item.id)
        if s and s.id then own[s.id] = true end
    end
    for _, item in ipairs(list) do
        local s = SpellOf(item.id)
        if s then
            local has = HasBuff(s, own, kind)
            if has then return true end
            if has == nil then unsure = true end
        else
            unsure = true       -- the game does not know this rank yet: its buff may be the one that is on
        end
    end
    if unsure then return nil end
    return false
end

-- The names of the lasting buffs on the character (one of a few seconds blocks no consumable): name -> true.
-- nil = the game will not say right now; false = this game cannot list them at all.
local function Present()
    local A = C_UnitAuras
    local byIndex = type(A) == "table" and A.GetAuraDataByIndex
    if type(byIndex) ~= "function" then return false end
    local out = {}
    for i = 1, 80 do
        local ok, aura = pcall(byIndex, "player", i, "HELPFUL")
        if not ok or not Plain(aura) then return nil end
        if type(aura) ~= "table" then break end
        local name, duration = aura.name, aura.duration
        if not Plain(name) or not Plain(duration) then return nil end
        if type(name) == "string" and (type(duration) ~= "number" or duration <= 0 or duration >= LONG) then out[name] = true end
    end
    return out
end

-- What was learned about buffs that keep a kind from being used (the same for every character):
--   block[kind] = { note, ... }     note = { buff names..., n = refusals behind it, at = when the last one was
--                                   (time()), firm = true when seeing the buffs together must not undo it }
--                                   With all of a note's buffs on the character, the kind was refused.
--   clear[kind] = { name = true }   seen on the character together with the kind's own buff: it blocks nothing
local function Learned()
    local s = Settings()
    if type(s.block) ~= "table" then s.block = {} end
    if type(s.clear) ~= "table" then s.clear = {} end
    return s.block, s.clear
end

local function AddNote(notes, note)
    notes[#notes + 1] = note
    while #notes > GROUPS do table.remove(notes, 1) end
    return note
end

-- Whether a note keeps its kind off the bar right now: all its buffs are on, and its rest is not over yet.
local function Holds(note, present, wall)
    if #note == 0 then return false end
    for _, name in ipairs(note) do
        if not present[name] then return false end
    end
    local n, at = floor(tonumber(note.n) or 1), tonumber(note.at) or 0
    if at > wall then                       -- the clock was set back: the rest counts from now
        at = wall
        note.at = wall
    end
    return wall - at < REST[max(1, min(#REST, n))]
end

-- Whether a kind would be refused with the buffs now on the character. nil = cannot be told right now.
local function Blocked(kind, present)
    if (snooze[kind] or 0) > GetTime() then return true end
    if present == nil then return nil end
    if not present then return false end
    local block, clear = Learned()
    local innocent, wall = clear[kind] or NONE, time()
    -- a buff classic rules put above this kind is on: noted as if the game had refused it twice
    for _, name in ipairs(SEEDS[kind] or NONE) do
        if present[name] and not innocent[name] then
            local notes, known = block[kind] or {}, false
            block[kind] = notes
            for _, note in ipairs(notes) do known = known or (#note == 1 and note[1] == name) end
            if not known then AddNote(notes, { name, n = 2, at = wall }) end
        end
    end
    for _, note in ipairs(block[kind] or NONE) do
        if Holds(note, present, wall) then return true end
    end
    return false
end

-- The kind's own buff is on the character together with these: none of them keeps it off. (Not a firm note: on
-- a game where the two can be on together and the kind is refused all the same, a refusal has shown as much.)
local function Innocent(kind, present)
    local block, clear = Learned()
    local notes = block[kind]
    if not notes then return end
    for g = #notes, 1, -1 do
        local note = notes[g]
        if not note.firm then
            for i = #note, 1, -1 do
                if present[note[i]] then
                    clear[kind] = clear[kind] or {}
                    clear[kind][note[i]] = true
                    table.remove(note, i)
                end
            end
            if #note == 0 then table.remove(notes, g) end
        end
    end
    if #notes == 0 then block[kind] = nil end
end

-- Of one kind: the one to use, which is the best the character can use at its level that is in the bags (so a
-- lesser one when the best is not there); and how many usable ones there are in all.
local function Pick(list, level)
    local pick, stock = nil, 0
    for _, item in ipairs(list) do
        if Scroll.Req(item) <= level then
            local n = ns.Have(item.id)
            if n > 0 then
                stock = stock + n
                if not pick or item.rank > pick.rank then pick = item end
            end
        end
    end
    return pick, stock
end

-- One look at the bags and the buffs:
--   lines = the buttons wanted, the most important kind first: { kind, id, name, stock }
--   low   = the kinds down to one or none: { kind, stock }       stock = kind -> how many usable ones in the bags
function Bar.Look()
    local lines, low, stock, why = {}, {}, {}, {}
    local me = ns.me
    if not me or not ns.Known() then return lines, low, stock, why end
    if type(me.barHad) ~= "table" then me.barHad = {} end       -- (the login check did not get to run)
    if type(me.barOff) ~= "table" then me.barOff = {} end
    local level, sees = ns.Level(), Sees()
    -- the list of lasting buffs is made only when a kind needs it (it walks every aura)
    local present, got
    local function Lasting()
        if not got then
            got = true
            present = sees and Present()
        end
        return present
    end
    for _, kind in ipairs(Scroll.kinds) do
        local name, list = kind.name, Scroll.byKind[kind.name]
        local pick, n = Pick(list, level)
        stock[name] = n
        if n > 0 then me.barHad[name] = true end
        if not me.barOff[name] then
            if me.barHad[name] and n <= 1 then low[#low + 1] = { kind = name, stock = n } end
            if pick and BUFFS[name] and sees and #lines < MAX then
                local covered = Covered(list)
                local blocked = covered == false and Blocked(name, Lasting())
                local show
                if covered == nil or blocked == nil then
                    show = Bar.showing[name] == true            -- the game will not say right now: as it was
                else
                    show = not covered and not blocked
                end
                if show then lines[#lines + 1] = { kind = name, id = pick.id, name = pick.name, stock = n } end
                if covered and (Learned())[name] then
                    local now = Lasting()
                    if now then Innocent(name, now) end
                end
                why[name] = (covered == nil or blocked == nil) and "hidden" or (blocked and "blocked") or nil
            end
        end
    end
    return lines, low, stock, why
end

-- For "/lo status": what the bar is doing, in one line.
function Bar.Status()
    local blocked, hidden = {}, {}
    for kind, reason in pairs(Bar.why or NONE) do
        if reason == "blocked" then blocked[#blocked + 1] = kind else hidden[#hidden + 1] = kind end
    end
    table.sort(blocked)
    table.sort(hidden)
    return ("Buff bar %s, %d buttons.%s%s"):format(Bar.Off() and "off" or "on", #(Bar.lines or NONE),
        #blocked > 0 and (" Left out, a stronger buff is on: " .. concat(blocked, ", ") .. ".") or "",
        #hidden > 0 and (" The game will not say whether these are on: " .. concat(hidden, ", ") .. ".") or "")
end

-- A line for the player: in the chat window and in the middle of the screen.
function Bar.Tell(text)
    print("|cffffd100Level Outfitter:|r " .. text)
    local f = UIErrorsFrame
    if type(f) == "table" and type(f.AddMessage) == "function" then pcall(f.AddMessage, f, text, 1, 0.82, 0) end
end

-- A line in the chat window only.
function Bar.Say(text)
    print("|cffffd100Level Outfitter:|r " .. text)
end

-- The game refused a click on this kind's button with "a more powerful spell is already active": note which
-- lasting buffs are on the character, so the kind is not offered again while they are.
function Bar.Bounced(kind)
    if not Scroll.byKind[kind] then return false end
    local present = Present()
    local block, clear = Learned()
    local wall, culprit, noted = time(), nil, false
    if present then
        local notes, innocent = block[kind] or {}, clear[kind] or NONE
        local now, forced = {}, false       -- the lasting buffs on right now that are not known to be harmless
        for name in pairs(present) do
            if not innocent[name] then now[#now + 1] = name end
        end
        if #now == 0 then                   -- every one of them was thought harmless: one of them is not
            for name in pairs(present) do now[#now + 1] = name end
            forced = true
        end
        table.sort(now)
        while #now > NAMES do table.remove(now) end
        if #now > 0 then
            local done = false
            -- 1. notes all of whose buffs are on (the kind was being offered once more): they still hold. A note
            --    counts as confirmed only when no other lasting buff is on that could have done it.
            for _, note in ipairs(notes) do
                local all, named = #note > 0, {}
                for _, name in ipairs(note) do
                    named[name] = true
                    all = all and present[name] == true
                end
                if all then
                    local alone = true
                    for _, name in ipairs(now) do alone = alone and named[name] == true end
                    if alone then note.n = floor(tonumber(note.n) or 1) + 1 end
                    note.at, done = wall, true
                    if #note == 1 then culprit = note[1] end
                end
            end
            -- 2. a buff classic rules put above this kind is on, and was only thought harmless because it had been
            --    seen together with the kind's own buff: on this game the two go together and the kind is refused
            --    all the same
            if not done then
                for _, name in ipairs(SEEDS[kind] or NONE) do
                    if present[name] and innocent[name] and not done then
                        AddNote(notes, { name, n = 2, at = wall, firm = true })
                        clear[kind][name] = nil
                        culprit, done = name, true
                    end
                end
            end
            -- 3. an earlier note, some of whose buffs are still on, and no buff has come that it does not name:
            --    it is one of those that are still on
            if not done then
                for _, note in ipairs(notes) do
                    if not done then
                        local keep, named = {}, {}
                        for _, name in ipairs(note) do
                            named[name] = true
                            if present[name] then keep[#keep + 1] = name end
                        end
                        local nothingNew = #keep > 0
                        for _, name in ipairs(now) do nothingNew = nothingNew and named[name] == true end
                        if nothingNew then
                            for i = #note, 1, -1 do note[i] = nil end
                            for i, name in ipairs(keep) do note[i] = name end
                            note.at = wall
                            done = true
                            if #keep == 1 then culprit = keep[1] end
                        end
                    end
                end
            end
            -- 4. else a new note: every lasting buff that is on
            if not done then
                now.n, now.at = 1, wall
                if forced then
                    if #now == 1 then now.firm = true end
                    if clear[kind] then
                        for _, name in ipairs(now) do clear[kind][name] = nil end
                    end
                end
                AddNote(notes, now)
                if #now == 1 then culprit = now[1] end
            end
            block[kind], noted = notes, true
        end
    end
    if not noted then snooze[kind] = GetTime() + SNOOZE end       -- nothing to pin it on: left out for a while
    Bar.Say((culprit and ("%s cannot be used while %s is on you. It will not be offered then.")
        or noted and "%s was refused: a stronger buff is on you. It is left out while the buffs you have now are on."
        or "%s was refused. It is left out for five minutes."):format(kind, culprit))
    Bar.Wake(0)
    return true
end

-- The kinds that are down to one or none, said in one line. false when there is nothing to say.
function Bar.Remind()
    if Bar.Off() then return false end
    local _, low = Bar.Look()
    if #low == 0 then return false end
    local parts = {}
    for i, l in ipairs(low) do parts[i] = l.kind .. (l.stock == 0 and " (none left)" or " (last one)") end
    Bar.Tell("Stock up: " .. concat(parts, ", ") .. ".")
    Bar.remindedAt = GetTime()
    return true
end

-- The buttons ---------------------------------------------------------------------------------------------------
-- What a button shows (never anything the game forbids during a fight). l = its line, nil = no longer wanted.
local function Paint(b, l)
    if not l then
        b.icon:SetAlpha(0.25)
        b.count:SetText("")
        b.last:SetText("")
        b.dim = true
        return
    end
    b.icon:SetAlpha(1)
    b.count:SetText(l.stock > 1 and tostring(l.stock) or "")
    b.last:SetText(l.stock == 1 and "LAST ONE" or "")
    b.dim, b.stock = nil, l.stock
end

local function Tip(self)
    if not self.id or not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if not pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.id) then GameTooltip:SetText(self.kind or "", 1, 1, 1) end
    GameTooltip:AddLine("Level Outfitter: this buff is not on you. Click to use one.", 1, 0.82, 0, true)
    GameTooltip:AddLine("Shift + right-click: never show this kind.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

local function Make(i)
    local b = CreateFrame("Button", "LevelOutfitterBarButton" .. i, holder, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")     -- both, as this game's own bars do: the game picks the one that counts
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", 1, -1)
    bg:SetColorTexture(0, 0, 0, 0.8)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local hot = b:CreateTexture(nil, "HIGHLIGHT")
    hot:SetAllPoints()
    hot:SetColorTexture(1, 1, 1, 0.2)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.last = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.last:SetPoint("TOP", b, "BOTTOM", 0, -3)
    b.last:SetTextColor(1, 0.25, 0.2)
    pcall(function()                            -- an outline, so the words read over the game world
        local font, height = b.last:GetFont()
        if font then b.last:SetFont(font, height, "OUTLINE") end
    end)
    b:SetScript("OnEnter", Tip)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    -- runs before the game's own handling of the click (which uses the item on a left click): a refusal that
    -- follows at once is about this kind
    b:SetScript("PreClick", function(self, mouse)
        if self.kind and (mouse == nil or mouse == "LeftButton") then Bar.clicked = { kind = self.kind, at = GetTime() } end
    end)
    -- runs after it
    b:SetScript("PostClick", function(self, mouse, down)
        if down or mouse ~= "RightButton" or not self.kind then return end
        if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then Bar.Ignore(self.kind) end
    end)
    buttons[i] = b
    return b
end

-- Brings the row in line with Bar.lines.
function Bar.Apply(force)
    local lines = Bar.lines or {}
    if #lines == 0 and #buttons == 0 then return end            -- nothing was ever shown: no frames needed
    if not force and type(InCombatLockdown) == "function" and InCombatLockdown() then
        -- a fight: only what the buttons show is kept honest; the row is done again when it is over
        Bar.pending = true
        local want = {}
        for _, l in ipairs(lines) do want[l.kind] = l end
        for _, b in ipairs(buttons) do
            if b.kind then
                local l = want[b.kind]
                if l and b.id and ns.Have(b.id) == 0 then l = nil end   -- its own item is gone: a click would do nothing
                Paint(b, l)
            end
        end
        return
    end
    Bar.pending = nil
    if not holder then
        if not CreateFrame or not UIParent then return end
        holder = CreateFrame("Frame", "LevelOutfitterBar", UIParent)
        holder:SetSize(1, 1)
        Bar.holder = holder
    end
    local size, n = Size(), #lines
    holder:ClearAllPoints()
    holder:SetPoint("CENTER", UIParent, "BOTTOM", 0, (tonumber(UIParent:GetHeight()) or 768) * At() / 100)
    for i = 1, max(n, #buttons) do
        local l, b = lines[i], buttons[i]
        if l then
            b = b or Make(i)
            if b.id ~= l.id then
                b.id = l.id
                b:SetAttribute("type1", "item")
                b:SetAttribute("item1", "item:" .. l.id)
                b.icon:SetTexture(Call(type(C_Item) == "table" and C_Item.GetItemIconByID or GetItemIcon, l.id) or ICON)
            end
            b.kind = l.kind
            b:SetSize(size, size)
            b:ClearAllPoints()
            b:SetPoint("CENTER", holder, "CENTER", (i - (n + 1) / 2) * (size + GAP), 0)
            Paint(b, l)
            b:Show()
        elseif b.id then
            b.id, b.kind = nil, nil
            b:SetAttribute("type1", nil)
            b:SetAttribute("item1", nil)
            b:Hide()
        end
    end
end

-- Looks again: says what changed in the stock, then does the row.
function Bar.Refresh(now, force)
    now = now or GetTime()
    local lines, _, stock, why = Bar.Look()
    Bar.why = why
    local me, off = ns.me, Bar.Off()
    local quiet = off or now < (Bar.holdUntil or 0)
    for name, n in pairs(stock) do
        local was = seen[name]
        seen[name] = n
        if was and n < was and not quiet and not me.barOff[name] then
            if n == 1 then
                Bar.Tell(("LAST ONE: %s."):format(name))
            elseif n == 0 then
                Bar.Tell(("Out of %s. Stock up in a city."):format(name))
            end
        end
    end
    Bar.lines = off and {} or lines
    local showing = {}
    for _, l in ipairs(Bar.lines) do showing[l.kind] = true end
    Bar.showing = showing
    Bar.Apply(force)
    -- a kind that is resting after a refusal: look again when its rest is over
    local soonest
    for kind, till in pairs(snooze) do
        if till <= now then
            snooze[kind] = nil
        elseif not soonest or till < soonest then
            soonest = till
        end
    end
    if soonest then Bar.Wake(soonest - now + 0.1) end
end

-- Timing --------------------------------------------------------------------------------------------------------
-- Look again soon (news comes in bursts: one look for the lot).
function Bar.Wake(delay)
    local at = GetTime() + (delay or WAIT)
    if not Bar.due or at < Bar.due then Bar.due = at end
    if driver then driver:Show() end
end

local function Due(delay)
    local at = GetTime() + delay
    if not Bar.remindDue or at < Bar.remindDue then Bar.remindDue = at end
    if driver then driver:Show() end
end

function Bar.Tick(now)
    if Bar.due and now >= Bar.due then
        Bar.due = nil
        Bar.Refresh(now)
    end
    if Bar.remindDue and now >= Bar.remindDue and now >= (Bar.holdUntil or 0) then
        Bar.remindDue = nil
        Bar.Remind()
    end
    if driver and not Bar.due and not Bar.remindDue then driver:Hide() end
end

-- Arriving in a city: the reminder is due.
local function Zone()
    local me = ns.me
    if not me then return end
    local zone = Call(GetRealZoneText)
    local city = type(zone) == "string" and CITIES[zone] == true
    if city and not Bar.inCity then
        local wall, last = time(), tonumber(me.barCityAt) or 0
        if wall - last >= CITY_EVERY or wall < last then
            me.barCityAt = wall
            Due(CITY_AFTER)
        end
    end
    Bar.inCity = city
end

function Bar.OnEvent(event, a, b)
    if event == "UI_ERROR_MESSAGE" then
        -- (error number, text) on this game; older ones gave the text alone
        if not Plain(a) or not Plain(b) then return end
        local text = (type(b) == "string" and b) or (type(a) == "string" and a) or nil
        local c = Bar.clicked
        if text and c and GetTime() - c.at <= CLICK_FOR
            and (text == SPELL_FAILED_AURA_BOUNCED or text:lower():find(BOUNCE, 1, true)) then
            Bar.clicked = nil
            Bar.Bounced(c.kind)
        end
    elseif event == "UNIT_AURA" then
        if a == "player" then Bar.Wake() end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if Scroll.byId[a] then Bar.Wake() end                   -- one of ours got known: its buff can be looked for now
    elseif event == "PLAYER_ENTERING_WORLD" then
        Bar.holdUntil = GetTime() + HOLD
        Zone()
        Bar.Wake(1)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        Zone()
    elseif event == "AUCTION_HOUSE_SHOW" then
        if GetTime() - (Bar.remindedAt or -1e9) >= AH_AFTER then Due(0) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- a fight is about to start: the last moment the row may change
        if Bar.due then
            Bar.due = nil
            Bar.Refresh(nil, true)      -- the game already says "in a fight" here, but may still be changed inside this handler
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        Bar.Wake(0)
    else
        if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then ns.dirty = true end      -- the window shows how many are in the bags
        Bar.Wake()
    end
end

-- The player's words --------------------------------------------------------------------------------------------
-- Takes one kind off the bar and out of the reminders.
function Bar.Ignore(kind)
    local me = ns.me
    if not me or not Scroll.byKind[kind] then return false end
    if type(me.barOff) ~= "table" then me.barOff = {} end
    me.barOff[kind] = true
    Bar.Tell(kind .. ": off the bar. \"/lo bar reset\" brings every kind back.")
    Bar.Wake(0)
    return true
end

-- "/lo bar", "/lo bar off", "/lo bar size 40", "/lo bar height 33", "/lo bar reset": returns the line to print.
function Bar.Set(word, number)
    local s, me = Settings(), ns.me
    if word == "" or word == nil then
        s.off = not Bar.Off() or nil
    elseif word == "on" then
        s.off = nil
    elseif word == "off" then
        s.off = true
    elseif word == "size" and number then
        s.size = Clamp(number, 20, 80, SIZE)
    elseif word == "height" and number then
        s.at = Clamp(number, 5, 95, AT)
    elseif word == "reset" then
        s.size, s.at, s.off, s.block, s.clear = nil, nil, nil, nil, nil
        for kind in pairs(snooze) do snooze[kind] = nil end
        if me then me.barOff = {} end
    else
        return "/lo bar (on or off)   /lo bar size 40   /lo bar height 33   /lo bar reset"
    end
    Bar.Wake(0)
    if Bar.Off() then return "the buff buttons and the stock reminders are off." end
    return ("the buff buttons are on: size %d, %d%% up the screen."):format(Size(), At())
end

-- This character's notes, checked when it logs in (Core.lua calls this).
function Bar.Login(me)
    for _, field in ipairs({ "barHad", "barOff" }) do
        local t = me[field]
        if type(t) ~= "table" then
            t = {}
            me[field] = t
        end
        for kind, v in pairs(t) do
            if type(kind) ~= "string" or v ~= true or not Scroll.byKind[kind] then t[kind] = nil end
        end
    end
    for kind in pairs(seen) do seen[kind] = nil end
    -- what was learned about blocking buffs: anything that is not in its proper shape goes
    local s = Settings()
    if type(s.block) ~= "table" then s.block = nil end
    if type(s.clear) ~= "table" then s.clear = nil end
    for kind, notes in pairs(s.block or NONE) do
        local fine = type(kind) == "string" and Scroll.byKind[kind] and type(notes) == "table"
        if fine then
            for g = #notes, 1, -1 do
                local note = notes[g]
                local good = type(note) == "table" and #note > 0 and #note <= NAMES
                if good then
                    for _, name in ipairs(note) do good = good and type(name) == "string" end
                end
                if good then
                    local at = tonumber(note.at)
                    if not at or at ~= at or at < 0 then at = 0 end
                    note.n, note.at = floor(Clamp(note.n, 1, 99, 1)), min(at, time())      -- (never a time still to come)
                    note.firm, note.sure = (note.firm == true) or nil, nil
                else
                    table.remove(notes, g)
                end
            end
            fine = #notes > 0 and #notes <= GROUPS
        end
        if not fine then s.block[kind] = nil end
    end
    for kind, names in pairs(s.clear or NONE) do
        local fine = type(kind) == "string" and Scroll.byKind[kind] and type(names) == "table"
        if fine then
            for name, v in pairs(names) do
                if type(name) ~= "string" or v ~= true then names[name] = nil end
            end
        end
        if not fine then s.clear[kind] = nil end
    end
    Bar.holdUntil = GetTime() + HOLD
    -- the game is asked to load what these items are, so their buffs can be recognised even when not in the bags
    local load = type(C_Item) == "table" and C_Item.RequestLoadItemDataByID
    if type(load) == "function" then
        for kind in pairs(BUFFS) do
            for _, item in ipairs(Scroll.byKind[kind] or {}) do pcall(load, item.id) end
        end
    end
    Bar.Wake(1)
end

if CreateFrame then
    driver = CreateFrame("Frame")
    driver:Hide()
    for _, event in ipairs(EVENTS) do ns.Listen(driver, event) end
    -- aura news only for the player when the game allows it (else for every unit; OnEvent filters)
    if not (type(driver.RegisterUnitEvent) == "function" and pcall(driver.RegisterUnitEvent, driver, "UNIT_AURA", "player")) then
        ns.Listen(driver, "UNIT_AURA")
    end
    driver:SetScript("OnEvent", function(_, event, ...) Bar.OnEvent(event, ...) end)
    driver:SetScript("OnUpdate", function() Bar.Tick(GetTime()) end)
    Bar.frame = driver
end
