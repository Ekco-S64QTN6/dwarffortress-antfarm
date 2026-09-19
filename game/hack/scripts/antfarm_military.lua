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
-- SAFETY: `create` builds df.squad structures by hand, because this DFHack has
-- no dfhack.military module. That is the highest-risk operation in the project,
-- so it is NOT run from tick() -- it is an explicit verb, and it must be
-- verified once against a live fort before being trusted. Everything tick()
-- does (enlist into existing squads, retune schedules) only touches squads DF
-- already accepted.
--
-- Usage:
--   antfarm_military              report squads, soldiers and uniforms
--   antfarm_military enlist       fill existing squads from the population
--   antfarm_military schedule     retune training minimums
--   antfarm_military create       create a squad (manual, see SAFETY above)

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
        return {}, 'no squads exist yet -- run `antfarm_military create` first'
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
-- squad creation (manual; see SAFETY at the top)                   --
-- ---------------------------------------------------------------- --

local UNIFORM_SLOTS = {
    {slot = 'Body',   item = 'ARMOR'},
    {slot = 'Head',   item = 'HELM'},
    {slot = 'Pants',  item = 'PANTS'},
    {slot = 'Gloves', item = 'GLOVES'},
    {slot = 'Shoes',  item = 'SHOES'},
    {slot = 'Shield', item = 'SHIELD'},
    {slot = 'Weapon', item = 'WEAPON'},
}

function create_squad()
    local ent = fort_entity()
    if not ent then return false, 'no fort entity' end

    -- A squad with no commander is not commandable; nobles fills that post.
    local has_officer = false
    pcall(function()
        for _, a in ipairs(ent.positions.assignments) do
            if a.histfig ~= -1 then has_officer = true end
        end
    end)
    if not has_officer then
        return false, 'appoint a militia commander first (antfarm_nobles appoint)'
    end

    local ok, err = pcall(function()
        local sid = df.global.squad_next_id
        df.global.squad_next_id = sid + 1

        local squad = df.squad:new()
        squad.id = sid
        squad.entity_id = ent.id
        squad.name.first_name = 'Antfarm Squad ' .. tostring(sid)
        squad.name.has_name = true
        squad.cur_alert_idx = 1      -- the training alert
        squad.uniform_priority = 2
        squad.carry_food = 2
        squad.carry_water = 2

        for _ = 1, SQUAD_SLOTS do
            local pos = df.squad_position:new()
            for _, u in ipairs(UNIFORM_SLOTS) do
                local spec = df.squad_uniform_spec:new()
                spec.color = -1
                spec.item_filter.item_type = df.item_type[u.item]
                spec.item_filter.material_class = df.entity_material_category.Armor
                spec.item_filter.mattype = -1
                spec.item_filter.matindex = -1
                pos.uniform[df.uniform_category[u.slot]]:insert('#', spec)
            end
            -- The weapon slot is a melee choice, not an armour-class match.
            local w = pos.uniform[df.uniform_category.Weapon][0]
            w.indiv_choice.melee = true
            w.item_filter.material_class = df.entity_material_category.None
            pos.flags.exact_matches = true
            squad.positions:insert('#', pos)
        end

        -- One schedule block per alert, twelve months each: train two months in
        -- three, leaving the third free so needs recover.
        for _ = 0, #df.global.ui.alerts.list - 1 do
            local months = {}
            for i = 0, 11 do
                local scm = df.squad_schedule_entry:new()
                for _ = 1, SQUAD_SLOTS do scm.order_assignments:insert('#', -1) end
                if i % 3 ~= 0 then
                    local order = df.squad_order_trainst:new()
                    local so = df.squad_schedule_order:new()
                    so.min_count = 0
                    so.order = order
                    scm.orders:insert('#', so)
                end
                months[i] = scm
            end
            squad.schedule:insert('#', months)
        end

        -- Linking into the world happens LAST, on purpose. Everything above
        -- builds a detached object, so if any of it raises -- the schedule
        -- construction is the least certain part, since DF stores twelve
        -- entries per alert as one block -- the pcall unwinds with nothing
        -- referenced by the world. A partially-linked squad would be
        -- corruption; a leaked unreferenced one is merely garbage.
        df.global.world.squads.all:insert('#', squad)
        df.global.ui.squads.list:insert('#', squad)
        ent.squads:insert('#', squad.id)
    end)

    if not ok then return false, 'squad creation failed: ' .. tostring(err) end
    return true, 'squad created'
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
    -- Deliberately does NOT create squads: see SAFETY at the top of the file.
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
    local ok, msg = create_squad()
    print('antfarm_military: ' .. tostring(msg))
    if ok then
        print('antfarm_military: VERIFY IN GAME before relying on this -- open the')
        print('antfarm_military: military screen and confirm the squad is usable.')
    end
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
