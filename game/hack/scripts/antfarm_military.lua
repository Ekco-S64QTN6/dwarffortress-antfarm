-- antfarm_military.lua
-- Squads, enlistment and training schedules.
--
-- Gap #7 in AUTOMATION-GAPS.md was recorded as "squad creation hooked via noble
-- appointments". It was not: antfarm_nobles.lua fills MILITIA_COMMANDER and the
-- other posts, which is the prerequisite, but nothing ever created a squad, put
-- a dwarf in one, or set a training schedule. A fort with a commander and no
-- squad is exactly as defended as a fort with neither.
--
-- The squad-creation path is a port of df-ai's `military_find_free_squad`
-- (tools/df-ai/population.rb), which drove unattended 0.47 forts for years --
-- per CLAUDE.md, port that rather than reinvent it. Enlistment and schedule
-- tuning are ports of `update_military` / `military_find_new_soldier`.
--
-- Squads cannot be built from Lua in this build, so create_squad() drives DF's
-- own military screen instead (antfarm_ui). Everything else tick() does
-- (enlist, retune schedules) only touches squads DF itself created.
--
-- Usage:
--   antfarm_military              report squads, soldiers and uniforms
--   antfarm_military enlist       fill existing squads from the population
--   antfarm_military schedule     retune training minimums
--   antfarm_military create       create a squad through the military screen

--@module = true

-- df-ai's ratio: roughly one soldier per five able citizens. A fort that drafts
-- harder than this starves its own industry.
local SOLDIER_RATIO = 5
local SQUAD_SLOTS = 10

local function fort_entity()
    local ok, ent = pcall(function()
        return df.historical_entity.find(df.global.ui.group_id)
    end)
    return ok and ent or nil
end

local function citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is then table.insert(out, u) end
    end
    return out
end

-- Who may be drafted. df-ai excludes children, babies and any dwarf in a mood;
-- conscripting a moody dwarf loses both the artifact and the dwarf.
local function draftable()
    local out = {}
    for _, u in ipairs(citizens()) do
        local ok = pcall(function()
            if u.mood ~= -1 and u.mood ~= nil then error('moody') end
        end)
        local adult = true
        local oka, a = pcall(dfhack.units.isAdult, u)
        if oka then adult = a end
        if ok and adult then table.insert(out, u) end
    end
    return out
end

function fort_squads()
    local ent = fort_entity()
    local out = {}
    if not ent then return out end
    pcall(function()
        for _, sid in ipairs(ent.squads) do
            local sq = df.squad.find(sid)
            if sq then table.insert(out, sq) end
        end
    end)
    return out
end

local function squad_occupancy(sq)
    local filled, total = 0, 0
    pcall(function()
        for _, p in ipairs(sq.positions) do
            total = total + 1
            if p.occupant ~= -1 then filled = filled + 1 end
        end
    end)
    return filled, total
end

function soldiers()
    local n = 0
    for _, u in ipairs(citizens()) do
        local ok, sid = pcall(function() return u.military.squad_id end)
        if ok and sid and sid ~= -1 then n = n + 1 end
    end
    return n
end

-- The metal the fort can actually forge. Queueing an iron uniform on an embark
-- with no iron is the same failure as the anvil order: the jobs never complete
-- and the squad never equips.
function uniform_metal()
    local ok, m = pcall(reqscript, 'antfarm_metals')
    if ok and m and m.best_martial_metal then
        local ok2, metal = pcall(m.best_martial_metal)
        if ok2 then return metal end
    end
    return nil
end

-- ---------------------------------------------------------------- --
-- enlistment                                                       --
-- ---------------------------------------------------------------- --

-- Port of df-ai's military_find_new_soldier: prefer the most experienced dwarf
-- who holds no noble post (the +5000 per position is df-ai's way of keeping
-- officers out of the ranks).
local function unit_score(u)
    local xp = 0
    pcall(function()
        local soul = u.status.current_soul
        if not soul then return end
        for i = 0, #soul.skills - 1 do
            xp = xp + (soul.skills[i].experience or 0) + (soul.skills[i].rating or 0) * 100
        end
    end)
    local posts = 0
    local ent = fort_entity()
    if ent and u.hist_figure_id and u.hist_figure_id ~= -1 then
        pcall(function()
            for _, a in ipairs(ent.positions.assignments) do
                if a.histfig == u.hist_figure_id then posts = posts + 1 end
            end
        end)
    end
    return xp + 5000 * posts
end

function enlist()
    local squads = fort_squads()
    if #squads == 0 then
        return {}, 'no squads exist yet -- `antfarm_military create` makes one through the military screen'
    end
    local able = draftable()
    local target = math.floor(#able / SOLDIER_RATIO)
    local have = soldiers()
    local done = {}

    -- Candidates not already enlisted, weakest-claim first.
    local pool = {}
    for _, u in ipairs(able) do
        local ok, sid = pcall(function() return u.military.squad_id end)
        if ok and sid == -1 then table.insert(pool, u) end
    end
    table.sort(pool, function(a, b) return unit_score(a) < unit_score(b) end)

    local idx = 1
    while have < target and idx <= #pool do
        local u = pool[idx]
        idx = idx + 1
        -- First squad with a free slot.
        local placed = false
        for _, sq in ipairs(squads) do
            local filled, total = squad_occupancy(sq)
            if filled < total then
                local ok = pcall(function()
                    for i = 0, #sq.positions - 1 do
                        local p = sq.positions[i]
                        if p.occupant == -1 then
                            p.occupant = u.hist_figure_id
                            u.military.squad_id = sq.id
                            u.military.squad_position = i
                            return
                        end
                    end
                    error('no free slot after all')
                end)
                if ok then
                    placed = true
                    have = have + 1
                    local name = 'a dwarf'
                    local okn, vis = pcall(dfhack.units.getVisibleName, u)
                    if okn and vis then
                        local okt, t = pcall(dfhack.TranslateName, vis)
                        if okt then name = t end
                    end
                    table.insert(done, ('enlisted %s'):format(name))
                    break
                end
            end
        end
        if not placed then break end
    end
    return done, ('%d/%d soldiers for %d able citizens'):format(have, target, #able)
end

-- ---------------------------------------------------------------- --
-- schedule                                                         --
-- ---------------------------------------------------------------- --

-- df-ai's rule: a training order's min_count is one below the squad's strength,
-- so training never consumes the whole squad and someone is always available.
function retune_schedules()
    local tuned = 0
    for _, sq in ipairs(fort_squads()) do
        local filled = squad_occupancy(sq)
        local want = (filled > 3) and (filled - 1) or filled
        pcall(function()
            -- schedule[1] is the training alert, as in df-ai.
            local sched = sq.schedule[1]
            if not sched then return end
            for i = 0, 11 do
                local month = sched[i]
                if month then
                    for _, so in ipairs(month.orders) do
                        local ok = pcall(function() so.min_count = want end)
                        if ok then tuned = tuned + 1 end
                    end
                end
            end
        end)
    end
    return tuned
end

-- ---------------------------------------------------------------- --
-- squad creation: not possible from Lua in this build                --
-- ---------------------------------------------------------------- --

-- This used to build a df.squad by hand, ported from df-ai's
-- military_find_free_squad. It cannot work here, measured on 0.47.05-r8:
-- `squad.schedule` is a vector<squad_schedule_entry[12]*> -- one contiguous
-- block of twelve months per alert, which df-ai allocated with a raw malloc --
-- and DFHack's Lua refuses both ways of making one ("Cannot allocate arrays of
-- non-primitive types"; inserting a table of twelve entries is rejected too).
--
-- So squads are created the way a player creates them: antfarm_ui's
-- military-screen driver (m, c, Enter), mapped against a live fort and
-- verified to produce a real squad. Nothing here writes a squad structure.

-- Appointed squad leaders (militia commander, captains...) who have no squad:
-- each is a squad DF's military screen will let us create.
function leaders_without_squad()
    local ent = fort_entity()
    local out = {}
    if not ent then return out end
    pcall(function()
        local by_id = {}
        for i = 0, #ent.positions.own - 1 do
            local p = ent.positions.own[i]
            by_id[p.id] = p
        end
        for i = 0, #ent.positions.assignments - 1 do
            local a = ent.positions.assignments[i]
            local p = by_id[a.position_id]
            if p and p.squad_size > 0 and a.histfig ~= -1 and a.squad_id == -1 then
                table.insert(out, p.code)
            end
        end
    end)
    return out
end

local function ui()
    local ok, mod = pcall(reqscript, 'antfarm_ui')
    return ok and type(mod) == 'table' and mod or nil
end

function create_squad(operator)
    if #leaders_without_squad() == 0 then
        return false, 'every appointed squad leader already has a squad (antfarm_nobles '
            .. 'appoints the militia commander and captains)'
    end
    local u = ui()
    if not u or not u.request_squad then return false, 'antfarm_ui unavailable' end
    return u.request_squad(operator)
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_military_state = antfarm_military_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 900

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_military_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_military_state.last_run = now
    -- Below df-ai's one-soldier-in-five target with a leader free to lead a
    -- squad: ask the UI driver for one. It only runs while a client drives the
    -- fort, and enlist() fills the new squad on a later pass.
    local okr, rep = pcall(report)
    if okr and rep.slots < rep.target and #leaders_without_squad() > 0 then
        local okc, created, why = pcall(create_squad)
        if okc and created then
            table.insert(antfarm_military_state.notes, 1,
                ('%d soldier(s) wanted, %d slot(s): creating a squad'):format(rep.target, rep.slots))
        end
    end
    local ok, done = pcall(enlist)
    if ok then
        for _, m in ipairs(done) do
            table.insert(antfarm_military_state.notes, 1, m)
        end
    end
    pcall(retune_schedules)
    while #antfarm_military_state.notes > 10 do table.remove(antfarm_military_state.notes) end
end

function report()
    local squads = fort_squads()
    local slots = 0
    for _, sq in ipairs(squads) do
        local _, total = squad_occupancy(sq)
        slots = slots + total
    end
    local able = #draftable()
    return {
        squads = #squads,
        soldiers = soldiers(),
        slots = slots,
        target = math.floor(able / SOLDIER_RATIO),
        metal = uniform_metal(),
        notes = antfarm_military_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'enlist' then
    local done, why = enlist()
    print('antfarm_military: ' .. tostring(why))
    for _, m in ipairs(done) do print('antfarm_military: ' .. m) end
elseif verb == 'schedule' then
    print(('antfarm_military: retuned %d training order(s)'):format(retune_schedules()))
elseif verb == 'create' then
    local _, msg = create_squad(true)
    print('antfarm_military: ' .. tostring(msg))
else
    local squads = fort_squads()
    local able = #draftable()
    print(('antfarm_military: squads=%d  soldiers=%d  target=%d (of %d able citizens)')
        :format(#squads, soldiers(), math.floor(able / SOLDIER_RATIO), able))
    print('antfarm_military: uniform metal = ' ..
        (uniform_metal() or 'NONE -- trade for arms'))
    for _, sq in ipairs(squads) do
        local filled, total = squad_occupancy(sq)
        print(('   squad #%d  %d/%d filled'):format(sq.id, filled, total))
    end
end
