-- antfarm_trade.lua
-- Make the fort able to trade at all, then trade deliberately.
--
-- Two caravans reached this fort and left untraded, because there was no trade
-- depot: Dreamfort places one, but only at a step the stalled build never
-- reached. On an embark with no iron ore, trade is the *only* route to iron, so
-- a missing depot is not an economic inconvenience -- it is a hard ceiling on
-- what the fort can ever become.
--
-- Usage:
--   antfarm_trade            report depot, caravan and shopping list
--   antfarm_trade site       show where a depot would go, build nothing
--   antfarm_trade depot      build a trade depot if the fort has none
--   antfarm_trade goods      queue trade goods for export

--@module = true

local DEPOT_SIZE = 5          -- trade depots are 5x5
local SEARCH_RADIUS = 30      -- how far from the anchor to look for a site

-- ---------------------------------------------------------------- --
-- depot                                                            --
-- ---------------------------------------------------------------- --

function find_depot()
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.TradeDepot then return b end
    end
    return nil
end

-- A depot needs 5x5 of flat, walkable, building-free floor a wagon can reach.
-- Proper reachability is expensive, so this uses walkable-and-undesignated as
-- the proxy and leaves the final say to DF, which refuses to place a depot it
-- cannot path a wagon to.
-- Shapes a depot can actually be built on. Restricting this to FLOOR finds
-- nothing on a real surface: the ground is mostly SHRUB, SAPLING, PEBBLES and
-- BOULDER, which are floors with something lying on them and are perfectly
-- buildable. RAMP_TOP and WALL are not, and EMPTY is open air.
local BUILDABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

local function site_is_clear(x0, y0, z)
    for x = x0, x0 + DEPOT_SIZE - 1 do
        for y = y0, y0 + DEPOT_SIZE - 1 do
            local block = dfhack.maps.getTileBlock(x, y, z)
            if not block then return false end
            local tt = block.tiletype[x % 16][y % 16]
            local des = block.designation[x % 16][y % 16]
            local shape = df.tiletype.attrs[tt].shape
            local mat = df.tiletype.attrs[tt].material
            if not BUILDABLE[shape] then return false end
            if des.flow_size and des.flow_size > 0 then return false end
            if mat == df.tiletype_material.POOL or mat == df.tiletype_material.RIVER
                    or mat == df.tiletype_material.BROOK then return false end
            -- Never drop a depot onto the fort's own construction plan.
            if des.dig ~= df.tile_dig_designation.No then return false end
            if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
        end
    end
    return true
end

-- Prefer a site close to the fort anchor: the wagon should park by the
-- entrance, not across the map.
function find_depot_site()
    local anchor, z
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if ok and bp and bp.plan_summary then
        local okp, summary = pcall(bp.plan_summary)
        if okp and summary and summary.anchor and summary.levels then
            anchor = summary.anchor
            z = summary.levels.surface
        end
    end
    if not anchor then
        -- No plan: use a citizen's own position, which is demonstrably where
        -- the dwarves are standing.
        local u
        for _, cand in ipairs(df.global.world.units.active) do
            if dfhack.units.isCitizen(cand) then u = cand break end
        end
        if not u then return nil, 'no anchor and no citizens to locate the surface' end
        anchor = {x = u.pos.x, y = u.pos.y}
        z = u.pos.z
    end
    if not z then return nil, 'no surface level known' end

    local best, best_d
    for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
        for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
            local x, y = anchor.x + dx, anchor.y + dy
            if site_is_clear(x, y, z) then
                local d = dx * dx + dy * dy
                if not best_d or d < best_d then
                    best_d, best = d, {x = x, y = y, z = z}
                end
            end
        end
    end
    if not best then
        return nil, ('no clear %dx%d site within %d tiles of the anchor on z=%d')
            :format(DEPOT_SIZE, DEPOT_SIZE, SEARCH_RADIUS, z)
    end
    return best
end

function ensure_depot()
    if find_depot() then return false, 'depot already exists' end
    local site, err = find_depot_site()
    if not site then return false, err end

    -- constructBuilding takes the CENTRE of a 5x5 depot.
    local cx = site.x + math.floor(DEPOT_SIZE / 2)
    local cy = site.y + math.floor(DEPOT_SIZE / 2)
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.TradeDepot,
        pos = xyz2pos(cx, cy, site.z),
    })
    if not ok or not bld then
        return false, 'constructBuilding failed: ' .. tostring(bld)
    end
    -- A depot nobody builds is no better than no depot.
    pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
    return true, ('trade depot placed at %d,%d,%d'):format(cx, cy, site.z)
end

-- ---------------------------------------------------------------- --
-- caravan                                                          --
-- ---------------------------------------------------------------- --

function caravan_present()
    local ok, n = pcall(function() return #df.global.world.caravans end)
    if not ok then return false, 0 end
    return (n or 0) > 0, n or 0
end

-- Which civilisations are at the depot. The elven case is not cosmetic:
-- offering a wooden bin or barrel -- or anything made of wood -- reads to Elves
-- as a religious atrocity, and the documented outcome is trade abandonment and
-- war (AGENTS.md 6.27). Knowing who is here decides what may be offered.
function caravan_races()
    local races = {}
    pcall(function()
        for _, car in ipairs(df.global.world.caravans) do
            local ent = car.entity and df.historical_entity.find(car.entity)
            local id = ent and ent.race
            local name = id and df.global.world.raws.creatures.all[id]
                and df.global.world.raws.creatures.all[id].creature_id
            if name then races[name] = true end
        end
    end)
    return races
end

function elves_present()
    return caravan_races()['ELF'] and true or false
end

-- Export goods that will not offend whoever is actually at the depot. Stone
-- crafts are the safe default everywhere; wood is safe with everyone *except*
-- Elves, which is why the standing craft order is pinned to INORGANIC rather
-- than left to pick whatever boulder or log is nearest.
function safe_export_material()
    if elves_present() then
        return 'INORGANIC', 'elven caravan present -- no wood may be offered'
    end
    return 'INORGANIC', 'stone crafts are the default export'
end

-- ---------------------------------------------------------------- --
-- shopping list                                                    --
-- ---------------------------------------------------------------- --

-- What the fort should be buying. The metals survey answers the important half
-- exactly: a metal with no ore on the map can only ever be traded for.
function shopping_list()
    local list = {}
    local ok, m = pcall(reqscript, 'antfarm_metals')
    if ok and m and m.report then
        local okr, rep = pcall(m.report)
        if okr and rep then
            for _, metal in ipairs(rep.missing or {}) do
                table.insert(list, {
                    what = metal .. ' bars',
                    why = 'no ore on this embark -- trade is the only source',
                    priority = (metal == 'IRON') and 1 or 3,
                })
            end
            if rep.martial then
                table.insert(list, {
                    what = 'weapons and armour',
                    why = 'best local metal is ' .. rep.martial,
                    priority = 2,
                })
            end
        end
    end
    -- Things a young fort reliably lacks regardless of geology.
    table.insert(list, {what = 'cloth and thread', why = 'no textile industry yet', priority = 2})
    table.insert(list, {what = 'leather', why = 'armour and crafts', priority = 3})
    table.insert(list, {what = 'breeding pairs of livestock', why = 'long-term food security', priority = 2})
    table.insert(list, {what = 'seeds not native to this biome', why = 'farm variety', priority = 4})
    table.insert(list, {what = 'booze variety', why = 'variety is a real happiness input', priority = 4})
    table.sort(list, function(a, b) return a.priority < b.priority end)
    return list
end

-- ---------------------------------------------------------------- --
-- export goods                                                     --
-- ---------------------------------------------------------------- --

-- Rock crafts are the default export: the fort sits on unlimited stone, crafts
-- are high value per unit of hauling, and a craftsdwarf's workshop already
-- exists. Capped, because an uncapped order eats every boulder and every idle
-- dwarf.
local CRAFT_TARGET = 30

local function count_items(item_type)
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == item_type then n = n + 1 end
    end
    return n
end

function queue_trade_goods()
    local have = count_items(df.item_type.CRAFTS)
    if have >= CRAFT_TARGET then
        return false, ('%d crafts in stock, target %d -- nothing queued'):format(have, CRAFT_TARGET)
    end
    local want = CRAFT_TARGET - have
    local ok, err = pcall(dfhack.run_command, 'workorder',
        ('{"job":"MakeCrafts","amount_total":%d,"material":"INORGANIC"}'):format(want))
    if not ok then
        return false, 'could not queue crafts: ' .. tostring(err)
    end
    return true, ('queued %d rock crafts for export (had %d)'):format(want, have)
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_trade_state = antfarm_trade_state or {last_depot_try = 0, notes = {}}

local function note(text)
    table.insert(antfarm_trade_state.notes, 1, text)
    while #antfarm_trade_state.notes > 8 do table.remove(antfarm_trade_state.notes) end
end

local DEPOT_RETRY_SEC = 120

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    -- The depot is the one thing worth retrying on its own: everything else
    -- about trading is pointless without it.
    if not find_depot() and now - antfarm_trade_state.last_depot_try > DEPOT_RETRY_SEC then
        antfarm_trade_state.last_depot_try = now
        local built, msg = ensure_depot()
        note(built and msg or ('depot not placed: ' .. tostring(msg)))
    end
end

function report()
    local depot = find_depot()
    local present, count = caravan_present()
    local list = {}
    local ok, want = pcall(shopping_list)
    if ok then
        for i = 1, math.min(#want, 6) do table.insert(list, want[i].what) end
    end
    local races = {}
    for race in pairs(caravan_races()) do table.insert(races, race) end
    table.sort(races)
    return {
        depot = depot and true or false,
        depot_id = depot and depot.id or nil,
        caravan = present,
        caravans = count,
        races = races,
        elves = elves_present(),
        wants = list,
        notes = antfarm_trade_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'site' then
    local site, err = find_depot_site()
    if not site then
        print('antfarm_trade: ' .. tostring(err))
    else
        print(('antfarm_trade: a %dx%d depot would go at %d,%d,%d (top-left corner)')
            :format(DEPOT_SIZE, DEPOT_SIZE, site.x, site.y, site.z))
    end
elseif verb == 'depot' then
    local _, msg = ensure_depot()
    print('antfarm_trade: ' .. tostring(msg))
elseif verb == 'goods' then
    local _, msg = queue_trade_goods()
    print('antfarm_trade: ' .. tostring(msg))
else
    local depot = find_depot()
    local present, count = caravan_present()
    print('antfarm_trade: depot   = ' .. (depot and ('yes (#' .. depot.id .. ')') or 'NONE'))
    print('antfarm_trade: caravan = ' .. (present and (count .. ' on map') or 'none'))
    if elves_present() then
        print('antfarm_trade: ELVEN caravan -- offer no wood, and never a wooden')
        print('antfarm_trade: bin or barrel: it is read as an atrocity (AGENTS.md 6.27)')
    end
    print('antfarm_trade: shopping list')
    for _, w in ipairs(shopping_list()) do
        print(('   [%d] %-36s %s'):format(w.priority, w.what, w.why))
    end
end
