-- antfarm_mood.lua
-- Watch strange moods, and make sure the moody dwarf can reach what they want.
--
-- WHY
--
-- A moody dwarf who cannot gather their materials goes insane, and the fort
-- loses them for good. The one mood the old live fort had succeeded by luck: it
-- wanted bauxite and the fort sat on 367 blocks of it. Nothing was watching.
--
-- The demand is exactly readable -- the mood job's `job_items` give item type,
-- material and quantity, and the items already attached say how much has been
-- gathered -- so this module never guesses from announcement text.
-- docs/AUTOMATION-GAPS.md section 12 has the full design.
--
-- What it does, in order of how often it is the real problem:
--
--   * reports every mood: dwarf, kind, claimed workshop, each requirement with
--     needed / gathered / reachable-in-fort amounts;
--   * unforbids matching items when only forbidden ones exist, which is the
--     commonest reason a satisfiable mood stalls;
--   * flags a requirement that nothing in the fort matches, early and loudly,
--     while there is still time to trade or produce it;
--   * places the workshop a mood needs when the fort has none of that kind --
--     an unclaimable mood is as fatal as a missing material;
--   * reports moody dwarves that have not claimed a workshop, and dwarves whose
--     mood has already failed.
--
-- What it deliberately does NOT do (yet): queue production, butcher animals for
-- bone, or conjure items with createitem. Each needs an operator decision; see
-- docs/ROADMAP.md section 3.2.
--
-- Usage:
--   antfarm_mood            report active moods and what each one still needs
--   antfarm_mood fix        unforbid what the moods need (also runs on tick)

--@module = true

local utils = require('utils')

local RUN_INTERVAL_SEC = 60

-- Mood kinds that still lead to an artifact. Melancholy, Raving and Berserk are
-- what a failed mood turns into.
local ACTIVE = {Fey = true, Secretive = true, Possessed = true,
                Macabre = true, Fell = true}
local FAILED = {Melancholy = true, Raving = true, Berserk = true}

antfarm_mood_state = antfarm_mood_state or {last_run = 0, notes = {}, flagged = {}}

local function note(text)
    table.insert(antfarm_mood_state.notes, 1, text)
    while #antfarm_mood_state.notes > 10 do
        table.remove(antfarm_mood_state.notes)
    end
end

local function unit_name(u)
    local ok, name = pcall(function()
        return dfhack.TranslateName(dfhack.units.getVisibleName(u))
    end)
    return (ok and name and name ~= '') and name or ('unit ' .. tostring(u.id))
end

local function mood_name(u)
    local ok, name = pcall(function() return df.mood_type[u.mood] end)
    return ok and name or nil
end

local function is_mood_job(job)
    local t = job.job_type
    return t >= df.job_type.StrangeMoodCrafter and t <= df.job_type.StrangeMoodMechanics
end

-- The dwarf and the claimed workshop hang off the job's general refs, exactly
-- as DFHack's own showmood finds them.
local function job_refs(job)
    local unit, building
    for i = 0, #job.general_refs - 1 do
        local ref = job.general_refs[i]
        local t = ref:getType()
        if t == df.general_ref_type.UNIT_WORKER then unit = ref:getUnit()
        elseif t == df.general_ref_type.BUILDING_HOLDER then building = ref:getBuilding() end
    end
    return unit, building
end

-- Bars and cloth are measured in dimension units (150 to a bar), everything
-- else by count -- the same rule showmood uses.
local function by_dimension(item_type)
    return item_type == df.item_type.BAR or item_type == df.item_type.CLOTH
end

local function amount_of(it, item_type)
    if not by_dimension(item_type) then return 1 end
    local ok, d = pcall(function() return it:getTotalDimension() end)
    return (ok and type(d) == 'number') and d or 0
end

local BODY_PARTS = {'bone', 'shell', 'horn', 'pearl', 'ivory_tooth'}

-- Names as showmood prints them; anything else falls back to the enum key.
local LABELS = {BOULDER = 'boulder', BLOCKS = 'blocks', WOOD = 'log', BAR = 'bar',
                SMALLGEM = 'cut gem', ROUGH = 'rough gem', SKIN_TANNED = 'leather',
                CLOTH = 'cloth', REMAINS = 'remains', CORPSE = 'corpse'}

local function describe(ji)
    local mat = ''
    if ji.mat_type == 0 and ji.mat_index < 0 then
        -- The inorganic wildcard: matinfo calls it "rock", but it means any
        -- stone, metal or gem of the right item type.
        mat = 'any '
    elseif ji.mat_type >= 0 then
        local ok, mi = pcall(dfhack.matinfo.decode, ji.mat_type, ji.mat_index)
        if ok and mi then mat = mi:toString() .. ' ' end
    end
    if ji.item_type < 0 then
        for _, part in ipairs(BODY_PARTS) do
            local ok, set = pcall(function() return ji.flags2[part] end)
            if ok and set then return mat .. part:gsub('_', '/') end
        end
        return mat .. 'item'
    end
    local key = df.item_type[ji.item_type]
    local name = LABELS[key] or (key and key:lower():gsub('_', ' ')) or 'item'
    return mat .. name
end

-- An item the moody dwarf could actually go and fetch, forbidden or not.
local function fetchable(it)
    local f = it.flags
    if f.in_job or f.construction or f.in_building or f.garbage_collect
        or f.trader or f.hostile or f.removed or f.artifact or f.owned then
        return false
    end
    -- Held or worn by somebody: not lying about to be picked up.
    local ok, holder = pcall(dfhack.items.getHolderUnit, it)
    return not (ok and holder)
end

-- isSuitableItem checks the item against the requirement's FLAGS, not its
-- type: on a live fort a "rough gem" demand matched 1086 ordinary stones. Check
-- the type and subtype here first.
local function matches(ji, it)
    local ok, r = pcall(function()
        local t = it:getType()
        if ji.item_type >= 0 and t ~= ji.item_type then return false end
        if ji.item_subtype >= 0 and it:getSubtype() ~= ji.item_subtype then return false end
        return dfhack.job.isSuitableItem(ji, t, it:getSubtype())
            and dfhack.job.isSuitableMaterial(ji, it:getMaterial(),
                                              it:getMaterialIndex(), t)
    end)
    return ok and r == true
end

-- What the fort holds for one requirement: reachable now, and forbidden.
local function candidates(ji)
    local free, forbidden, forbidden_items = 0, 0, {}
    local items = df.global.world.items.other.IN_PLAY
    for i = 0, #items - 1 do
        local it = items[i]
        if fetchable(it) and matches(ji, it) then
            local n = amount_of(it, ji.item_type)
            if it.flags.forbid then
                forbidden = forbidden + n
                table.insert(forbidden_items, it)
            else
                free = free + n
            end
        end
    end
    return free, forbidden, forbidden_items
end

local function requirements(job)
    local out = {}
    for i = 0, #job.job_items - 1 do
        local ji = job.job_items[i]
        local got = 0
        for j = 0, #job.items - 1 do
            local ref = job.items[j]
            if ref.job_item_idx == i then
                got = got + amount_of(ref.item, ji.item_type)
            end
        end
        local free, forbidden, forbidden_items = candidates(ji)
        table.insert(out, {
            index = i,
            what = describe(ji),
            need = ji.quantity,
            got = got,
            free = free,
            forbidden = forbidden,
            unit = by_dimension(ji.item_type) and 'dimension' or 'count',
            _forbidden_items = forbidden_items,
        })
    end
    return out
end

-- Every mood in the fort: those at work, those still looking for a workshop,
-- and those that have already failed.
function scan()
    local moods, seen = {}, {}
    for _, job in utils.listpairs(df.global.world.jobs.list) do
        if is_mood_job(job) then
            local u, b = job_refs(job)
            if u then
                seen[u.id] = true
                local ok_t, timeout = pcall(function() return u.job.mood_timeout end)
                table.insert(moods, {
                    unit_id = u.id,
                    name = unit_name(u),
                    mood = mood_name(u) or 'unknown',
                    job = df.job_type[job.job_type],
                    workshop = b and b.id or -1,
                    timeout = ok_t and timeout or nil,
                    requirements = requirements(job),
                })
            end
        end
    end
    local waiting, failed = {}, {}
    local units = df.global.world.units.active
    for i = 0, #units - 1 do
        local u = units[i]
        local ok, citizen = pcall(dfhack.units.isCitizen, u)
        if ok and citizen and not seen[u.id] then
            local kind = mood_name(u)
            if ACTIVE[kind] then
                local ok_s, skill = pcall(function() return df.job_skill[u.job.mood_skill] end)
                table.insert(waiting, {unit_id = u.id, name = unit_name(u), mood = kind,
                                       skill = ok_s and skill or nil})
            elseif FAILED[kind] then
                table.insert(failed, {unit_id = u.id, name = unit_name(u), mood = kind})
            end
        end
    end
    return moods, waiting, failed
end

local function remaining(r) return math.max(0, r.need - r.got) end

-- Which building a mood job claims. Brooding (macabre) and fell moods have no
-- single workshop, so they are left alone.
local MOOD_SHOP = {
    StrangeMoodCrafter    = {'Workshop', 'Craftsdwarfs',     "craftsdwarf's workshop"},
    StrangeMoodJeweller   = {'Workshop', 'Jewelers',         "jeweler's workshop"},
    StrangeMoodForge      = {'Workshop', 'MetalsmithsForge', "metalsmith's forge"},
    StrangeMoodMagmaForge = {'Workshop', 'MagmaForge',       'magma forge'},
    StrangeMoodCarpenter  = {'Workshop', 'Carpenters',       "carpenter's workshop"},
    StrangeMoodMason      = {'Workshop', 'Masons',           "mason's workshop"},
    StrangeMoodBowyer     = {'Workshop', 'Bowyers',          "bowyer's workshop"},
    StrangeMoodTanner     = {'Workshop', 'Leatherworks',     'leather works'},
    StrangeMoodWeaver     = {'Workshop', 'Clothiers',        "clothier's shop"},
    StrangeMoodMechanics  = {'Workshop', 'Mechanics',        "mechanic's workshop"},
    StrangeMoodGlassmaker = {'Furnace',  'GlassFurnace',     'glass furnace'},
}

local function sustenance()
    local ok, mod = pcall(reqscript, 'antfarm_sustenance')
    return ok and type(mod) == 'table' and mod or nil
end

-- A mood that has not claimed a workshop yet, in a fort that has none of the
-- kind it needs, will never claim one: the dwarf goes insane. Place one.
-- Magma forges are never placed blind -- they need magma.
local function ensure_mood_workshop(m)
    if m.workshop >= 0 then return nil end
    local want = MOOD_SHOP[m.job]
    if not want or want[2] == 'MagmaForge' then return nil end
    local btype = df.building_type[want[1]]
    local kind = (want[1] == 'Furnace' and df.furnace_type or df.workshop_type)[want[2]]
    if btype == nil or kind == nil then return nil end
    local sus = sustenance()
    if not sus or not sus.have_building or not sus.place_building then
        return false, 'antfarm_sustenance unavailable'
    end
    if sus.have_building(btype, kind) then return nil end
    local ok, why = sus.place_building(btype, kind)
    if ok then return true, want[3] end
    return false, ('needs a %s and none could be placed: %s'):format(want[3], tostring(why))
end

-- Unforbid just enough to cover what is still missing. Returns how many items
-- were released.
local function release(r)
    local short = remaining(r) - r.free
    local released = 0
    for _, it in ipairs(r._forbidden_items) do
        if short <= 0 then break end
        it.flags.forbid = false
        released = released + 1
        short = short - amount_of(it, it:getType())
    end
    return released
end

-- Act on what scan() found. Returns a list of human-readable actions taken.
function fix()
    local actions = {}
    local moods, waiting, failed = scan()
    for _, m in ipairs(moods) do
        local placed, what = ensure_mood_workshop(m)
        if placed then
            table.insert(actions, ('%s (%s) needs a %s the fort did not have -- placed one')
                :format(m.name, m.mood, what))
        elseif placed == false then
            local key = ('%d:shop'):format(m.unit_id)
            if not antfarm_mood_state.flagged[key] then
                antfarm_mood_state.flagged[key] = true
                table.insert(actions, ('%s (%s) %s'):format(m.name, m.mood, what))
            end
        end
        for _, r in ipairs(m.requirements) do
            local short = remaining(r)
            if short > 0 and r.free < short and r.forbidden > 0 then
                local n = release(r)
                if n > 0 then
                    table.insert(actions, ('%s: unforbade %d %s'):format(m.name, n, r.what))
                end
            end
            local key = ('%d:%d'):format(m.unit_id, r.index)
            if short > 0 and r.free + r.forbidden == 0
                    and not antfarm_mood_state.flagged[key] then
                antfarm_mood_state.flagged[key] = true
                table.insert(actions, ('%s (%s) needs %s and NOTHING in the fort matches -- '
                    .. 'trade or produce it before the mood fails'):format(m.name, m.mood, r.what))
            end
        end
    end
    for _, w in ipairs(waiting) do
        local key = ('%d:wait'):format(w.unit_id)
        if not antfarm_mood_state.flagged[key] then
            antfarm_mood_state.flagged[key] = true
            table.insert(actions, ('%s is in a %s mood and has not claimed a workshop '
                .. '(skill %s) -- does the fort have one?'):format(w.name, w.mood, tostring(w.skill)))
        end
    end
    for _, f in ipairs(failed) do
        local key = ('%d:failed'):format(f.unit_id)
        if not antfarm_mood_state.flagged[key] then
            antfarm_mood_state.flagged[key] = true
            table.insert(actions, ('%s has gone %s -- the mood failed'):format(f.name, f.mood))
        end
    end
    return actions
end

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_mood_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_mood_state.last_run = now
    for _, a in ipairs(fix()) do note(a) end
end

-- Plain data only: requirement rows lose their item references.
function report()
    local moods, waiting, failed = scan()
    local out = {}
    for _, m in ipairs(moods) do
        local reqs, unmet, impossible = {}, 0, 0
        for _, r in ipairs(m.requirements) do
            local short = remaining(r)
            if short > 0 then unmet = unmet + 1 end
            if short > 0 and r.free + r.forbidden == 0 then impossible = impossible + 1 end
            table.insert(reqs, {what = r.what, need = r.need, got = r.got,
                                free = r.free, forbidden = r.forbidden, unit = r.unit})
        end
        table.insert(out, {name = m.name, mood = m.mood, job = m.job,
                           workshop = m.workshop, timeout = m.timeout,
                           unmet = unmet, impossible = impossible,
                           requirements = reqs})
    end
    return {
        moods = out,
        waiting = waiting,
        failed = failed,
        notes = antfarm_mood_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local verb = (({...})[1] or 'status'):lower()

if verb == 'fix' then
    local actions = fix()
    if #actions == 0 then print('antfarm_mood: nothing to do') end
    for _, a in ipairs(actions) do print('antfarm_mood: ' .. a) end
else
    local r = report()
    if #r.moods == 0 and #r.waiting == 0 and #r.failed == 0 then
        print('antfarm_mood: no strange moods')
    end
    for _, m in ipairs(r.moods) do
        print(('antfarm_mood: %s -- %s mood, %s, workshop %d, timeout %s')
            :format(m.name, m.mood, m.job, m.workshop, tostring(m.timeout)))
        for _, q in ipairs(m.requirements) do
            local state = q.got >= q.need and 'have'
                or (q.free + q.forbidden == 0 and 'NONE IN FORT')
                or (q.free >= q.need - q.got and 'reachable')
                or 'forbidden/short'
            print(('    %-28s got %d/%d %s  (reachable %d, forbidden %d)  %s')
                :format(q.what, q.got, q.need, q.unit == 'dimension' and 'units' or '',
                        q.free, q.forbidden, state))
        end
    end
    for _, w in ipairs(r.waiting) do
        print(('antfarm_mood: %s -- %s mood, no workshop claimed yet (skill %s)')
            :format(w.name, w.mood, tostring(w.skill)))
    end
    for _, f in ipairs(r.failed) do
        print(('antfarm_mood: %s -- mood FAILED (%s)'):format(f.name, f.mood))
    end
end
