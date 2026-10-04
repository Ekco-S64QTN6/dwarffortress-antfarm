-- antfarm_sustenance.lua
-- Keep the fort fed and watered, independently of the build schedule.
--
-- WHY
--
-- A live fort reached twelve drinks with no still, no kitchen and no farm plot,
-- while four dwarves stood idle. Everything that produces food or drink sits in
-- Dreamfort's /farming2 step, which is gated on the farming level being fully
-- dug -- and digging was limited to two dwarves because the embark carried two
-- picks. So the fort's entire food industry waited on its slowest possible
-- bottleneck. AGENTS.md 6.9 records the same shape of failure once already:
-- gating on excavation starved a fort of booze.
--
-- Sustenance must not be gated on anything. This module guarantees it:
--
--   * a still, a kitchen and a farmer's workshop exist on the surface early,
--     whatever the blueprint is doing;
--   * a plant-gathering zone sits on the densest shrubs near the fort, which is
--     the cheapest possible jump-start for brewing -- no workshop, no farm, no
--     dug level, just dwarves walking outside;
--   * labours that need a tool are capped to the number of tools on hand, so
--     autolabor stops parking dwarves on mining jobs they have no pick for;
--   * gathering and planting keep a guaranteed minimum of staff.
--
-- Gathering is ground-only on purpose. AGENTS.md 6.22: herbalists sent up trees
-- get stranded when a hauler steals the stepladder.
--
-- Usage:
--   antfarm_sustenance            report stocks, workshops and labour caps
--   antfarm_sustenance gather     site (or re-site) the gathering zone
--   antfarm_sustenance workshops  build still / kitchen / farmer's workshop
--   antfarm_sustenance labour     cap tool labours, guarantee gatherers
--   antfarm_sustenance all        do all three

--@module = true

local GATHER_SIZE = 20
local GATHER_SEARCH = 26
local MIN_HERBALISTS = 3
local MIN_PLANTERS = 2
-- Below this many drinks per citizen the fort is heading for trouble.
local DRINK_PER_CITIZEN = 2

-- Tool-limited labours: assigning more dwarves than there are tools just parks
-- them. The item subtype that each one needs.
local TOOL_LABOURS = {
    {labor = 'MINE',    tool = 'ITEM_WEAPON_PICK',       floor = 1},
    {labor = 'CUTWOOD', tool = 'ITEM_WEAPON_AXE_BATTLE', floor = 1},
}

local BUILDABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

local function citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is then table.insert(out, u) end
    end
    return out
end

local function count_items(item_type)
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == item_type then n = n + 1 end
    end
    return n
end

local function count_tool(subtype_id)
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        local t = it:getType()
        if t == df.item_type.WEAPON or t == df.item_type.TOOL then
            local ok, def = pcall(function() return it.subtype end)
            if ok and def and def.id == subtype_id then n = n + 1 end
        end
    end
    return n
end

local function anchor()
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if ok and bp and bp.plan_summary then
        local okp, s = pcall(bp.plan_summary)
        if okp and s and s.anchor and s.levels and s.levels.surface then
            return s.anchor.x, s.anchor.y, s.levels.surface
        end
    end
    for _, u in ipairs(citizens()) do return u.pos.x, u.pos.y, u.pos.z end
    return nil
end

-- ---------------------------------------------------------------- --
-- gathering                                                        --
-- ---------------------------------------------------------------- --

local function civzones()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Civzone then table.insert(out, b) end
    end
    return out
end

function gather_zone()
    for _, z in ipairs(civzones()) do
        local ok, g = pcall(function() return z.zone_flags.gather end)
        if ok and g then return z end
    end
    return nil
end

local function shrubs_in(x0, y0, w, z)
    local n = 0
    for x = x0, x0 + w - 1 do
        for y = y0, y0 + w - 1 do
            local b = dfhack.maps.getTileBlock(x, y, z)
            if not b then return nil end
            if df.tiletype.attrs[b.tiletype[x % 16][y % 16]].shape
                    == df.tiletype_shape.SHRUB then
                n = n + 1
            end
        end
    end
    return n
end

-- Score on SHRUB tiles, not grass. Scoring grass picked a meadow 50 tiles away
-- holding eight gatherable shrubs while 1223 sat nearer the fort.
function ensure_gather_zone(force)
    local ax, ay, z = anchor()
    if not ax then return false, 'no anchor and no citizens' end

    local existing = gather_zone()
    if existing and not force then
        local n = shrubs_in(existing.x1, existing.y1,
                            existing.x2 - existing.x1 + 1, existing.z) or 0
        -- Shrubs regrow where they stood, and a harvested zone looks empty for a
        -- while, so a high threshold here just moves the zone around forever.
        -- Only abandon a zone that is genuinely barren.
        if n >= 3 then return false, ('gather zone already has %d shrubs'):format(n) end
        pcall(dfhack.buildings.deconstruct, existing)
    elseif existing then
        pcall(dfhack.buildings.deconstruct, existing)
    end

    local best, best_score
    for ox = -GATHER_SEARCH, GATHER_SEARCH, 4 do
        for oy = -GATHER_SEARCH, GATHER_SEARCH, 4 do
            local n = shrubs_in(ax + ox, ay + oy, GATHER_SIZE, z)
            if n then
                -- Shrub density first, nearness as a tie-break: a closer zone
                -- means less walking and it regrows under the dwarves' feet.
                local score = n - (math.abs(ox) + math.abs(oy)) * 0.15
                if not best_score or score > best_score then
                    best_score, best = score, {x = ax + ox, y = ay + oy, n = n}
                end
            end
        end
    end
    if not best then return false, 'nowhere to put a gathering zone' end

    local cx = best.x + math.floor(GATHER_SIZE / 2)
    local cy = best.y + math.floor(GATHER_SIZE / 2)
    local ok, zone = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.Civzone,
        subtype = df.civzone_type.ActivityZone,
        pos = xyz2pos(cx, cy, z),
        width = GATHER_SIZE, height = GATHER_SIZE,
        abstract = true,
    })
    if not ok or not zone then return false, 'zone creation failed: ' .. tostring(zone) end
    pcall(function()
        zone.zone_flags.active = true
        zone.zone_flags.gather = true
        zone.gather_flags.pick_shrubs = true
        zone.gather_flags.gather_fallen = true
        -- Never trees: AGENTS.md 6.22.
        zone.gather_flags.pick_trees = false
    end)
    return true, ('gathering zone %dx%d at %d,%d (%d shrubs)')
        :format(GATHER_SIZE, GATHER_SIZE, best.x, best.y, best.n)
end

-- ---------------------------------------------------------------- --
-- workshops                                                        --
-- ---------------------------------------------------------------- --

local WANTED_SHOPS = {
    {name = 'Still',   subtype = df.workshop_type.Still},
    {name = 'Kitchen', subtype = df.workshop_type.Kitchen},
    {name = 'Farmers', subtype = df.workshop_type.Farmers},
}

-- A workshop's kind lives in `type` (df.workshop_type); `subtype` does not
-- exist on building_workshopst in this build and raises.
local function have_shop(kind)
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Workshop then
            local ok, t = pcall(function() return b.type end)
            if ok and t == kind then return true end
        end
    end
    return false
end

local function clear_3x3(x0, y0, z)
    for x = x0, x0 + 2 do
        for y = y0, y0 + 2 do
            local b = dfhack.maps.getTileBlock(x, y, z)
            if not b then return false end
            local a = df.tiletype.attrs[b.tiletype[x % 16][y % 16]]
            local d = b.designation[x % 16][y % 16]
            if not BUILDABLE[a.shape] then return false end
            if d.dig ~= df.tile_dig_designation.No then return false end
            if d.flow_size and d.flow_size > 0 then return false end
            if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
        end
    end
    return true
end

function ensure_workshops()
    local ax, ay, z = anchor()
    if not ax then return {}, 'no anchor and no citizens' end
    local placed = {}
    for _, want in ipairs(WANTED_SHOPS) do
        if not have_shop(want.subtype) then
            local done = false
            for r = 2, 18 do
                for dx = -r, r do
                    for dy = -r, r do
                        if not done and math.max(math.abs(dx), math.abs(dy)) == r then
                            local x0, y0 = ax + dx, ay + dy
                            if clear_3x3(x0, y0, z) then
                                local ok, b = pcall(dfhack.buildings.constructBuilding, {
                                    type = df.building_type.Workshop,
                                    subtype = want.subtype,
                                    pos = xyz2pos(x0 + 1, y0 + 1, z),
                                })
                                if ok and b then
                                    table.insert(placed, want.name)
                                    done = true
                                end
                            end
                        end
                    end
                end
                if done then break end
            end
        end
    end
    if #placed > 0 then
        pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
    end
    return placed
end

-- ---------------------------------------------------------------- --
-- labour                                                           --
-- ---------------------------------------------------------------- --

-- autolabor assigned four dwarves to MINE on an embark carrying two picks; the
-- surplus two stood still for an in-game season. Cap each tool labour at the
-- number of tools that exist, and let the freed dwarves do anything else.
function tune_labour()
    local notes = {}
    for _, t in ipairs(TOOL_LABOURS) do
        local n = count_tool(t.tool)
        local cap = math.max(t.floor, n)
        local ok = pcall(dfhack.run_command, 'autolabor', t.labor,
                         tostring(math.min(t.floor, cap)), tostring(cap))
        if ok then
            table.insert(notes, ('%s capped at %d (%d tool%s on hand)')
                :format(t.labor, cap, n, n == 1 and '' or 's'))
        end
    end
    -- Gathering and planting are how a young fort eats; guarantee staff for both.
    if pcall(dfhack.run_command, 'autolabor', 'HERBALIST', tostring(MIN_HERBALISTS)) then
        table.insert(notes, ('HERBALIST minimum %d'):format(MIN_HERBALISTS))
    end
    if pcall(dfhack.run_command, 'autolabor', 'PLANT', tostring(MIN_PLANTERS)) then
        table.insert(notes, ('PLANT minimum %d'):format(MIN_PLANTERS))
    end
    return notes
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_sustenance_state = antfarm_sustenance_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 300

local function note(text)
    table.insert(antfarm_sustenance_state.notes, 1, text)
    while #antfarm_sustenance_state.notes > 10 do
        table.remove(antfarm_sustenance_state.notes)
    end
end

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_sustenance_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_sustenance_state.last_run = now

    local placed = select(1, pcall(ensure_workshops)) and ensure_workshops() or {}
    for _, p in ipairs(placed) do note('placed a ' .. p) end

    local ok, msg = pcall(ensure_gather_zone, false)
    if ok and msg == true then note('sited a gathering zone') end

    pcall(tune_labour)
end

function report()
    local pop = #citizens()
    local drink = count_items(df.item_type.DRINK)
    local zone = gather_zone()
    local shrubs = 0
    if zone then
        shrubs = shrubs_in(zone.x1, zone.y1, zone.x2 - zone.x1 + 1, zone.z) or 0
    end
    local shops = {}
    for _, w in ipairs(WANTED_SHOPS) do
        if have_shop(w.subtype) then table.insert(shops, w.name) end
    end
    return {
        citizens = pop,
        drink = drink,
        plants = count_items(df.item_type.PLANT),
        seeds = count_items(df.item_type.SEEDS),
        -- The number that actually matters: thin stock with no still is a
        -- countdown, not a statistic.
        drink_short = pop > 0 and drink < pop * DRINK_PER_CITIZEN or false,
        workshops = shops,
        gather_zone = zone ~= nil,
        gather_shrubs = shrubs,
        notes = antfarm_sustenance_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'gather' then
    local _, msg = ensure_gather_zone(true)
    print('antfarm_sustenance: ' .. tostring(msg))
elseif verb == 'workshops' then
    local placed = ensure_workshops()
    if #placed == 0 then print('antfarm_sustenance: still, kitchen and farmer\'s workshop all present')
    else print('antfarm_sustenance: placed ' .. table.concat(placed, ', ')) end
elseif verb == 'labour' or verb == 'labor' then
    for _, n in ipairs(tune_labour()) do print('antfarm_sustenance: ' .. n) end
elseif verb == 'all' then
    local placed = ensure_workshops()
    if #placed > 0 then print('antfarm_sustenance: placed ' .. table.concat(placed, ', ')) end
    local _, msg = ensure_gather_zone(false)
    print('antfarm_sustenance: ' .. tostring(msg))
    for _, n in ipairs(tune_labour()) do print('antfarm_sustenance: ' .. n) end
else
    local r = report()
    print(('antfarm_sustenance: %d citizens, %d drink%s, %d plants, %d seeds')
        :format(r.citizens, r.drink, r.drink_short and ' (SHORT)' or '', r.plants, r.seeds))
    print('antfarm_sustenance: workshops = ' ..
        (#r.workshops > 0 and table.concat(r.workshops, ', ') or 'NONE'))
    print(('antfarm_sustenance: gathering zone = %s (%d shrubs)')
        :format(r.gather_zone and 'yes' or 'NONE', r.gather_shrubs))
end
