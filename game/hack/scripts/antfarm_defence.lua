-- antfarm_defence.lua
-- Cage traps and guard animals at the fort entrance.
--
-- The fort this was written against had five "traps" that were all minecart
-- TrackStops, no restraints, and no guard animals -- while holding 31 unused
-- cages and five idle dogs. So: no thief detection and no capture, on a map
-- with goblins.
--
-- Two cheap mechanisms do most of the work:
--
--   * A chained dog sees sneaking thieves. Animals have no sneak-detection
--     penalty, so a leashed dog at the entrance reveals ambushers and kobolds
--     that dwarves walk straight past. This is the classic counter and it costs
--     one rope and one dog.
--   * Cage traps capture instead of killing: no combat, no injuries, and a
--     supply of caged enemies. They also need no metal, which matters on an
--     embark whose best martial metal is bronze.
--
-- Usage:
--   antfarm_defence            report traps, restraints and guard animals
--   antfarm_defence site       show where traps/chains would go, build nothing
--   antfarm_defence traps      build cage traps at the entrance
--   antfarm_defence dogs       build restraints and chain dogs to them

--@module = true

local MAX_TRAPS = 6
local MAX_CHAINS = 2
local SEARCH_RADIUS = 12

local BUILDABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

-- ---------------------------------------------------------------- --
-- inventory                                                        --
-- ---------------------------------------------------------------- --

-- A free item is one nobody has claimed, that is not forbidden, and that is not
-- already part of a building. Building with a claimed item is how you steal a
-- dwarf's backpack.
local function free_items(item_type)
    local out = {}
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == item_type then
            local ok, usable = pcall(function()
                if it.flags.forbid or it.flags.in_job or it.flags.in_building then
                    return false
                end
                if it.flags.dead_dwarf or it.flags.trader or it.flags.owned then
                    return false
                end
                return true
            end)
            if ok and usable then table.insert(out, it) end
        end
    end
    return out
end

function guard_dogs()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, tame = pcall(dfhack.units.isTame, u)
        if ok and tame then
            local okr, race = pcall(function()
                return df.global.world.raws.creatures.all[u.race].creature_id
            end)
            -- Dogs specifically: they are the fort's sentries, and chaining a
            -- breeding animal or a war-trained one would be a net loss.
            if okr and race == 'DOG' then
                local oka, adult = pcall(dfhack.units.isAdult, u)
                if not oka or adult then table.insert(out, u) end
            end
        end
    end
    return out
end

function existing_defence()
    local traps, chains = 0, 0
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        if t == df.building_type.Trap then
            local ok, tt = pcall(function() return df.trap_type[b.trap_type] end)
            -- TrackStops are minecart furniture, not defence. Counting them as
            -- traps is how a fort looks defended while being wide open.
            if ok and tt == 'CageTrap' then traps = traps + 1 end
        elseif t == df.building_type.Chain then
            chains = chains + 1
        end
    end
    return traps, chains
end

-- ---------------------------------------------------------------- --
-- siting                                                           --
-- ---------------------------------------------------------------- --

-- Traffic funnels through the central stairs, so the entrance is the best proxy
-- we have without pathfinding the whole map.
local function entrance()
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if ok and bp and bp.plan_summary then
        local okp, s = pcall(bp.plan_summary)
        if okp and s and s.anchor and s.levels and s.levels.surface then
            return {x = s.anchor.x, y = s.anchor.y, z = s.levels.surface}
        end
    end
    for _, u in ipairs(df.global.world.units.active) do
        local oki, is = pcall(dfhack.units.isCitizen, u)
        if oki and is then return {x = u.pos.x, y = u.pos.y, z = u.pos.z} end
    end
    return nil
end

local function tile_free(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    local tt = block.tiletype[x % 16][y % 16]
    local des = block.designation[x % 16][y % 16]
    local a = df.tiletype.attrs[tt]
    if not BUILDABLE[a.shape] then return false end
    if des.flow_size and des.flow_size > 0 then return false end
    if des.dig ~= df.tile_dig_designation.No then return false end
    if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
    return true
end

-- Spread sites out rather than clustering: a solid block of traps is one
-- unlucky pathing choice away from being walked around entirely.
function find_sites(count, spacing)
    local e = entrance()
    if not e then return {}, 'no entrance found' end
    local sites = {}
    local used = {}
    for r = 1, SEARCH_RADIUS do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local x, y = e.x + dx, e.y + dy
                    local key = ('%d:%d'):format(math.floor(x / spacing), math.floor(y / spacing))
                    if not used[key] and tile_free(x, y, e.z) then
                        used[key] = true
                        table.insert(sites, {x = x, y = y, z = e.z})
                        if #sites >= count then return sites end
                    end
                end
            end
        end
    end
    return sites
end

-- ---------------------------------------------------------------- --
-- building                                                         --
-- ---------------------------------------------------------------- --

function build_cage_traps()
    local have = existing_defence()
    local want = MAX_TRAPS - have
    if want <= 0 then return {}, ('already have %d cage traps'):format(have) end
    local cages = free_items(df.item_type.CAGE)
    if #cages == 0 then return {}, 'no free cages (build or buy some first)' end
    want = math.min(want, #cages)

    local sites = find_sites(want, 2)
    local built = {}
    for i, site in ipairs(sites) do
        local cage = cages[i]
        if not cage then break end
        local ok, bld = pcall(dfhack.buildings.constructBuilding, {
            type = df.building_type.Trap,
            subtype = df.trap_type.CageTrap,
            pos = xyz2pos(site.x, site.y, site.z),
            items = {cage},
        })
        if ok and bld then
            table.insert(built, ('cage trap at %d,%d,%d'):format(site.x, site.y, site.z))
        end
    end
    if #built > 0 then pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding') end
    return built, ('%d free cages, %d sites'):format(#cages, #sites)
end

function chain_dogs()
    local _, have = existing_defence()
    local want = MAX_CHAINS - have
    if want <= 0 then return {}, ('already have %d restraints'):format(have) end
    local ropes = free_items(df.item_type.CHAIN)
    if #ropes == 0 then return {}, 'no free rope or chain (weave one, or buy one)' end
    local dogs = guard_dogs()
    if #dogs == 0 then return {}, 'no adult dogs to post' end
    want = math.min(want, #ropes, #dogs)

    local sites = find_sites(want, 3)
    local built = {}
    for i, site in ipairs(sites) do
        local rope = ropes[i]
        if not rope then break end
        local ok, bld = pcall(dfhack.buildings.constructBuilding, {
            type = df.building_type.Chain,
            pos = xyz2pos(site.x, site.y, site.z),
            items = {rope},
        })
        if ok and bld then
            -- Assigning the animal is what makes it a sentry rather than
            -- furniture. The field name is not stable across builds, so try the
            -- known spellings and report honestly if none took.
            local dog = dogs[i]
            local assigned = false
            if dog then
                assigned = pcall(function() bld.assigned = dog end)
                if not assigned then
                    assigned = pcall(function() bld.assigned_unit_id = dog.id end)
                end
            end
            table.insert(built, ('restraint at %d,%d,%d%s')
                :format(site.x, site.y, site.z,
                        assigned and ' (dog assigned)' or ' (assign a dog by hand)'))
        end
    end
    if #built > 0 then pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding') end
    return built, ('%d ropes, %d dogs'):format(#ropes, #dogs)
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_defence_state = antfarm_defence_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 900

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_defence_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_defence_state.last_run = now
    local ok, built = pcall(build_cage_traps)
    if ok then
        for _, m in ipairs(built) do table.insert(antfarm_defence_state.notes, 1, m) end
    end
    local ok2, chained = pcall(chain_dogs)
    if ok2 then
        for _, m in ipairs(chained) do table.insert(antfarm_defence_state.notes, 1, m) end
    end
    while #antfarm_defence_state.notes > 10 do table.remove(antfarm_defence_state.notes) end
end

function report()
    local traps, chains = existing_defence()
    return {
        cage_traps = traps,
        restraints = chains,
        dogs = #guard_dogs(),
        spare_cages = #free_items(df.item_type.CAGE),
        spare_rope = #free_items(df.item_type.CHAIN),
        notes = antfarm_defence_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'site' then
    local sites, err = find_sites(MAX_TRAPS, 2)
    if err then print('antfarm_defence: ' .. err) end
    for _, s in ipairs(sites) do
        print(('antfarm_defence: candidate %d,%d,%d'):format(s.x, s.y, s.z))
    end
elseif verb == 'traps' then
    local built, why = build_cage_traps()
    print('antfarm_defence: ' .. tostring(why))
    for _, m in ipairs(built) do print('antfarm_defence: built ' .. m) end
elseif verb == 'dogs' then
    local built, why = chain_dogs()
    print('antfarm_defence: ' .. tostring(why))
    for _, m in ipairs(built) do print('antfarm_defence: built ' .. m) end
else
    local traps, chains = existing_defence()
    print(('antfarm_defence: cage traps=%d  restraints=%d  adult dogs=%d')
        :format(traps, chains, #guard_dogs()))
    print(('antfarm_defence: spare cages=%d  spare rope/chain=%d')
        :format(#free_items(df.item_type.CAGE), #free_items(df.item_type.CHAIN)))
end
