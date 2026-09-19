-- antfarm_nobles.lua
-- Fill the fort's vacant positions, and give the holders the rooms they demand.
--
-- DF and Dreamfort's own setup fill the civilian seats (manager, bookkeeper,
-- broker, chief medical dwarf), so this is not "nobody is appointed". What is
-- never filled is everything the game expects a *player* to appoint: every
-- military and justice position. On the fort this was written against, sheriff,
-- captain of the guard, militia commander, militia captain, hammerer and
-- dungeon master were all vacant, and nothing would ever have filled them.
--
-- There is no assignNoblePosition in this DFHack build, so appointment writes
-- the same structures the game writes: the assignment's histfig, plus a
-- position entity-link on the historical figure. Both halves were read off a
-- position DF had filled itself rather than guessed -- an appointment that sets
-- only one of them leaves a noble the game half-believes in.
--
-- Usage:
--   antfarm_nobles            report every position and its holder
--   antfarm_nobles appoint    fill vacant positions
--   antfarm_nobles rooms      assign rooms to position holders

--@module = true

-- Which skills make a good candidate for each position. First match wins, so
-- order matters. Positions absent from this table are left alone: mayor is
-- elected, and fighting the election only confuses the game.
local POSITION_SKILLS = {
    MANAGER              = {'ORGANIZATION', 'CONSOLE', 'RECORD_KEEPING'},
    BOOKKEEPER           = {'RECORD_KEEPING', 'ORGANIZATION'},
    BROKER               = {'APPRAISAL', 'NEGOTIATION', 'CONSOLE'},
    CHIEF_MEDICAL_DWARF  = {'DIAGNOSE', 'SURGERY', 'SUTURE', 'SET_BONE'},
    SHERIFF              = {'AXE', 'SWORD', 'HAMMER', 'MACE', 'SPEAR', 'WRESTLING'},
    CAPTAIN_OF_THE_GUARD = {'AXE', 'SWORD', 'HAMMER', 'MACE', 'SPEAR', 'WRESTLING'},
    MILITIA_COMMANDER    = {'LEADERSHIP', 'AXE', 'SWORD', 'HAMMER', 'SPEAR'},
    MILITIA_CAPTAIN      = {'LEADERSHIP', 'AXE', 'SWORD', 'HAMMER', 'SPEAR'},
    HAMMERER             = {'HAMMER', 'MACE', 'AXE', 'WRESTLING'},
    DUNGEON_MASTER       = {'ANIMALTRAIN', 'ANIMALCARE'},
}

-- Positions we must never touch. MAYOR and EXPEDITION_LEADER are decided by the
-- game; writing them by hand desynchronises the election.
local NEVER_APPOINT = {MAYOR = true, EXPEDITION_LEADER = true}

-- Dwarves whose civilian job is too important to also carry a military post.
-- Conscripting the only broker on an embark whose sole iron supply is trade is
-- exactly the kind of own goal automation should not commit.
local CRITICAL_CIVILIAN = {MANAGER = true, BOOKKEEPER = true, BROKER = true,
                           CHIEF_MEDICAL_DWARF = true}
local MILITARY_POSITION = {SHERIFF = true, CAPTAIN_OF_THE_GUARD = true,
                           MILITIA_COMMANDER = true, MILITIA_CAPTAIN = true,
                           HAMMERER = true}

local function fort_entity()
    local ok, ent = pcall(function()
        return df.historical_entity.find(df.global.ui.group_id)
    end)
    return ok and ent or nil
end

-- {code -> {position=, assignment=, histfig=}}
function positions()
    local ent = fort_entity()
    if not ent then return {} end
    local byid = {}
    for _, p in ipairs(ent.positions.own) do byid[p.id] = p end
    local out = {}
    for _, a in ipairs(ent.positions.assignments) do
        local p = byid[a.position_id]
        if p then
            out[p.code] = {position = p, assignment = a, histfig = a.histfig}
        end
    end
    return out
end

local function skill_rating(unit, skill_name)
    local ok, rating = pcall(function()
        local id = df.job_skill[skill_name]
        if not id then return 0 end
        local soul = unit.status.current_soul
        if not soul then return 0 end
        for i = 0, #soul.skills - 1 do
            local sk = soul.skills[i]
            if sk.id == id then return sk.rating end
        end
        return 0
    end)
    return (ok and rating) or 0
end

local function citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is then
            local adult = true
            local oka, a = pcall(dfhack.units.isAdult, u)
            if oka then adult = a end
            local alive = true
            local okl, l = pcall(dfhack.units.isActive, u)
            if okl then alive = l end
            if adult and alive then table.insert(out, u) end
        end
    end
    return out
end

-- Which positions a dwarf already holds, so one dwarf is not made sheriff,
-- hammerer and militia commander at once.
local function held_by(hf_id, pos)
    local held = {}
    for code, entry in pairs(pos) do
        if entry.histfig == hf_id then held[code] = true end
    end
    return held
end

function best_candidate(code, pos)
    local skills = POSITION_SKILLS[code]
    if not skills then return nil end
    local best, best_score
    for _, u in ipairs(citizens()) do
        local hf = u.hist_figure_id
        if hf and hf ~= -1 then
            local held = held_by(hf, pos)
            -- Never stack a military post on a critical civilian officer.
            local conflict = false
            if MILITARY_POSITION[code] then
                for c in pairs(held) do
                    if CRITICAL_CIVILIAN[c] then conflict = true end
                end
            end
            if not conflict and not held[code] then
                local score = 0
                if code == 'HAMMERER' then
                    -- A lethal Hammerer kills dwarves who violate minor production mandates.
                    -- Appoint a candidate with zero hammer skill and low strength for survivable beatings.
                    local hammer_skill = skill_rating(u, 'HAMMER')
                    local str = 1000
                    pcall(function()
                        if u.body and u.body.physical_attrs and u.body.physical_attrs.STRENGTH then
                            str = u.body.physical_attrs.STRENGTH.value
                        end
                    end)
                    score = (20 - hammer_skill) * 10 - math.floor(str / 100)
                else
                    for i, skill in ipairs(skills) do
                        -- Earlier skills in the list count for more.
                        score = score + skill_rating(u, skill) * (#skills - i + 1)
                    end
                end
                -- Prefer a dwarf who is not already carrying a post.
                local n = 0
                for _ in pairs(held) do n = n + 1 end
                score = score - n * 3
                if not best_score or score > best_score then
                    best_score, best = score, u
                end
            end
        end
    end
    return best, best_score
end

-- Write both halves of an appointment, exactly as the game does: the assignment
-- points at the histfig, and the histfig carries a position link back.
local function link_histfig(hf, ent, assignment)
    local ok = pcall(function()
        for _, l in ipairs(hf.entity_links) do
            local okt, t = pcall(function() return l:getType() end)
            local oka, aid = pcall(function() return l.assignment_id end)
            if okt and oka and t == df.histfig_entity_link_type.POSITION
                    and aid == assignment.id then
                return  -- already linked
            end
        end
        local link = df.histfig_entity_link_positionst:new()
        link.entity_id = ent.id
        link.assignment_id = assignment.id
        link.link_strength = 100
        hf.entity_links:insert('#', link)
    end)
    return ok
end

function appoint(code, pos)
    pos = pos or positions()
    local entry = pos[code]
    if not entry then return false, 'no such position in this fort' end
    if NEVER_APPOINT[code] then return false, 'decided by the game, not appointed' end
    if entry.histfig ~= -1 then return false, 'already filled' end

    local unit = best_candidate(code, pos)
    if not unit then return false, 'no suitable candidate' end
    local ent = fort_entity()
    if not ent then return false, 'no fort entity' end

    local hf = df.historical_figure.find(unit.hist_figure_id)
    if not hf then return false, 'candidate has no historical figure' end

    local ok = pcall(function() entry.assignment.histfig = hf.id end)
    if not ok then return false, 'could not write the assignment' end
    link_histfig(hf, ent, entry.assignment)
    entry.histfig = hf.id

    local name = 'a dwarf'
    local okn, vis = pcall(dfhack.units.getVisibleName, unit)
    if okn and vis then
        local okt, t = pcall(dfhack.TranslateName, vis)
        if okt then name = t end
    end
    return true, ('appointed %s as %s'):format(name, code)
end

function ensure_bookkeeper_precision()
    local ok = pcall(function()
        if df.global.ui and df.global.ui.nobles then
            if df.ui_nobles_bookkeeper_settings and df.ui_nobles_bookkeeper_settings.AllAccurate then
                df.global.ui.nobles.bookkeeper_settings = df.ui_nobles_bookkeeper_settings.AllAccurate
            else
                df.global.ui.nobles.bookkeeper_settings = 4
            end
            df.global.ui.nobles.bookkeeper_precision = 4
        end
    end)
    return ok
end

function appoint_all()
    ensure_bookkeeper_precision()
    local pos = positions()
    local done = {}
    -- Deterministic order so the most important seats are filled first and the
    -- best candidates are not spent on the hammerer.
    local order = {'MANAGER', 'BOOKKEEPER', 'BROKER', 'CHIEF_MEDICAL_DWARF',
                   'MILITIA_COMMANDER', 'SHERIFF', 'CAPTAIN_OF_THE_GUARD',
                   'MILITIA_CAPTAIN', 'DUNGEON_MASTER', 'HAMMERER'}
    for _, code in ipairs(order) do
        if pos[code] and pos[code].histfig == -1 then
            local ok, msg = appoint(code, pos)
            if ok then table.insert(done, msg) end
        end
    end
    return done
end

-- ---------------------------------------------------------------- --
-- rooms                                                            --
-- ---------------------------------------------------------------- --

-- Nobles demand rooms, and unmet demands are a standing unhappiness source (and
-- for a mayor, a mandate risk). Dreamfort builds the suites; nothing binds them
-- to a dwarf.
local ROOM_TYPES = {df.building_type.Bed, df.building_type.Table,
                    df.building_type.Chair, df.building_type.Coffin}

local function unowned_rooms()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        for _, want in ipairs(ROOM_TYPES) do
            if t == want then
                local ok, owner = pcall(function() return b.owner_id end)
                if ok and (owner == nil or owner == -1) then
                    -- Only rooms that have actually been defined as such.
                    local okr, room = pcall(function() return b.is_room end)
                    if okr and room then table.insert(out, b) end
                end
            end
        end
    end
    return out
end

function assign_rooms()
    local pos = positions()
    local free = unowned_rooms()
    local done = {}
    if #free == 0 then return done, 'no unowned rooms defined yet' end
    local idx = 1
    for code, entry in pairs(pos) do
        if entry.histfig and entry.histfig ~= -1 and idx <= #free then
            local hf = df.historical_figure.find(entry.histfig)
            local unit = hf and df.unit.find(hf.unit_id)
            if unit then
                local already = false
                for _, b in ipairs(df.global.world.buildings.all) do
                    local ok, owner = pcall(function() return b.owner_id end)
                    if ok and owner == unit.id then already = true break end
                end
                if not already then
                    local b = free[idx]
                    local ok = pcall(dfhack.buildings.setOwner, b, unit)
                    if ok then
                        idx = idx + 1
                        table.insert(done, ('gave %s a room'):format(code))
                    end
                end
            end
        end
    end
    return done
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_nobles_state = antfarm_nobles_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 600

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_nobles_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_nobles_state.last_run = now
    local ok, done = pcall(appoint_all)
    if ok then
        for _, msg in ipairs(done) do
            table.insert(antfarm_nobles_state.notes, 1, msg)
        end
    end
    pcall(assign_rooms)
    while #antfarm_nobles_state.notes > 10 do table.remove(antfarm_nobles_state.notes) end
end

function report()
    local pos = positions()
    local filled, vacant = {}, {}
    for code, entry in pairs(pos) do
        if entry.histfig ~= -1 then table.insert(filled, code)
        elseif not NEVER_APPOINT[code] then table.insert(vacant, code) end
    end
    table.sort(filled); table.sort(vacant)
    return {filled = filled, vacant = vacant, notes = antfarm_nobles_state.notes}
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'appoint' then
    local done = appoint_all()
    if #done == 0 then print('antfarm_nobles: nothing to appoint') end
    for _, msg in ipairs(done) do print('antfarm_nobles: ' .. msg) end
elseif verb == 'rooms' then
    local done, err = assign_rooms()
    if err then print('antfarm_nobles: ' .. err) end
    for _, msg in ipairs(done) do print('antfarm_nobles: ' .. msg) end
else
    local pos = positions()
    local codes = {}
    for code in pairs(pos) do table.insert(codes, code) end
    table.sort(codes)
    for _, code in ipairs(codes) do
        local e = pos[code]
        local who = 'VACANT'
        if e.histfig ~= -1 then
            local hf = df.historical_figure.find(e.histfig)
            who = hf and dfhack.TranslateName(hf.name) or ('hf#' .. e.histfig)
        end
        print(('  %-22s %s'):format(code, who))
    end
end
