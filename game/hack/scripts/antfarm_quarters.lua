-- antfarm_quarters.lua
-- Turn dug-out rooms into bedrooms dwarves actually own.
--
-- Digging an apartment block is not the same as housing anyone. On the fort this
-- was written against: 59 citizens, 6 beds, exactly one bed defined as a room,
-- none of them assigned to anybody, and not a single cabinet or chest in the
-- fort. Everyone was sleeping on the floor, which is a standing, cumulative
-- unhappiness source -- the kind that kills mature forts long before a siege.
--
-- Three separate things have to happen, and Dreamfort only does the first:
--   1. dig the rooms                (blueprint steps /apartments2, /apartments3)
--   2. build bed + door + chest + cabinet in each
--   3. define each bed as a room and give it an owner
--
-- Usage:
--   antfarm_quarters            report housing: beds, rooms, owners, shortfall
--   antfarm_quarters assign     define beds as rooms and assign them
--   antfarm_quarters orders     queue furniture for the unhoused

--@module = true

-- Cap on how much furniture is queued or placed at once, so a fort with fifty
-- unhoused dwarves does not queue two hundred jobs and starve every other
-- industry of workers. Declared here because place_beds() uses it too, and it
-- was previously defined further down the file -- where it read as nil.
local MAX_BATCH = 20

-- Per dwarf, a finished bedroom is a bed, a door, a chest and a cabinet.
local PER_ROOM = {
    {job = 'ConstructBed',     name = 'beds'},
    {job = 'ConstructDoor',    name = 'doors'},
    {job = 'ConstructChest',   name = 'chests'},
    {job = 'ConstructCabinet', name = 'cabinets'},
}

local function citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        local okl, alive = pcall(dfhack.units.isActive, u)
        if ok and is and (not okl or alive) then table.insert(out, u) end
    end
    return out
end

local function buildings_of(btype)
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == btype then table.insert(out, b) end
    end
    return out
end

function housing()
    local beds = buildings_of(df.building_type.Bed)
    local rooms, owned, free = 0, 0, {}
    for _, b in ipairs(beds) do
        local okr, is_room = pcall(function() return b.is_room end)
        local oko, owner = pcall(function() return b.owner_id end)
        if okr and is_room then rooms = rooms + 1 end
        if oko and owner and owner ~= -1 then
            owned = owned + 1
        else
            table.insert(free, b)
        end
    end
    return {
        citizens = #citizens(),
        beds = #beds,
        rooms = rooms,
        owned = owned,
        free = free,
        doors = #buildings_of(df.building_type.Door),
        chests = #buildings_of(df.building_type.Box),
        cabinets = #buildings_of(df.building_type.Cabinet),
    }
end

-- Who has nowhere to sleep. A dwarf already owning any bed is housed.
local function unhoused()
    local has_bed = {}
    for _, b in ipairs(buildings_of(df.building_type.Bed)) do
        local ok, owner = pcall(function() return b.owner_id end)
        if ok and owner and owner ~= -1 then has_bed[owner] = true end
    end
    local out = {}
    for _, u in ipairs(citizens()) do
        if not has_bed[u.id] then table.insert(out, u) end
    end
    return out
end

-- ---------------------------------------------------------------- --
-- placing beds                                                     --
-- ---------------------------------------------------------------- --

-- Assigning beds is useless when there are none. Dreamfort builds them at
-- /apartments2, step 18 of 22 -- so on a young fort everyone sleeps on the floor
-- for most of the build, which is a standing stress penalty for no reason: a bed
-- costs one log and the embark arrives with over a hundred.
--
-- Beds are placed in already-dug indoor space. Sleeping underground in a plain
-- room beats sleeping in a field, and antfarm_quarters assigns and defines them
-- as bedrooms on its next pass.
local function indoor_floor(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    if not b then return false end
    local a = df.tiletype.attrs[b.tiletype[x % 16][y % 16]]
    local d = b.designation[x % 16][y % 16]
    if a.shape ~= df.tiletype_shape.FLOOR or d.outside then return false end
    if d.dig ~= df.tile_dig_designation.No then return false end
    if d.flow_size and d.flow_size > 0 then return false end
    return not dfhack.buildings.findAtTile(xyz2pos(x, y, z))
end

local function fort_levels()
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if not ok or not bp or not bp.plan_summary then return nil, nil end
    local okp, sum = pcall(bp.plan_summary)
    if not okp or not sum or not sum.anchor then return nil, nil end
    local zs = {}
    for _, name in ipairs({'farming', 'services', 'industry', 'guildhall', 'apartments'}) do
        local z = sum.levels and sum.levels[name]
        if type(z) == 'number' then table.insert(zs, z) end
    end
    table.sort(zs, function(a, b) return a > b end)
    return sum.anchor, zs
end

-- Logs on hand; a bed needs one and nothing else.
local function logs_available()
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == df.item_type.WOOD then
            local ok, free = pcall(function()
                return not (it.flags.forbid or it.flags.in_job or it.flags.in_building)
            end)
            if ok and free then n = n + 1 end
        end
    end
    return n
end

function place_beds()
    local h = housing()
    local short = math.max(0, h.citizens - h.beds)
    if short == 0 then return {}, 'every citizen already has a bed' end

    local anchor, levels = fort_levels()
    if not anchor then return {}, 'no fort anchor yet' end
    local budget = math.min(short, logs_available(), MAX_BATCH)
    if budget == 0 then return {}, 'no free logs to build beds from' end

    local placed = 0
    for _, z in ipairs(levels) do
        -- Leave a gap between beds so each can become its own small bedroom
        -- later rather than one shared dormitory.
        for r = 2, 18 do
            for dx = -r, r, 2 do
                for dy = -r, r, 2 do
                    if placed >= budget then break end
                    if math.max(math.abs(dx), math.abs(dy)) == r then
                        local x, y = anchor.x + dx, anchor.y + dy
                        if indoor_floor(x, y, z) then
                            local ok, b = pcall(dfhack.buildings.constructBuilding, {
                                type = df.building_type.Bed,
                                pos = xyz2pos(x, y, z),
                            })
                            if ok and b then placed = placed + 1 end
                        end
                    end
                end
                if placed >= budget then break end
            end
            if placed >= budget then break end
        end
        if placed >= budget then break end
    end
    if placed > 0 then
        pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
    end
    return {('placed %d bed(s) in dug rooms'):format(placed)},
           ('%d citizens short, %d logs free'):format(short, logs_available())
end

-- A bed only becomes a bedroom when it is *defined as a room*; an undefined bed
-- is furniture a dwarf may sleep in but does not own, and confers none of the
-- happiness a bedroom does.
function assign_beds()
    local h = housing()
    local waiting = unhoused()
    local done = {}
    local idx = 1
    for _, bed in ipairs(h.free) do
        if idx > #waiting then break end
        local unit = waiting[idx]
        -- Define it as a room first: assigning an owner to a bed that is not a
        -- room gives the dwarf a place to sleep but not a bedroom.
        pcall(function()
            if not bed.is_room then
                bed.is_room = true
                -- A room with no extent covers just its own tile, which is a
                -- valid (if small) bedroom; DF grows it to the walls itself
                -- when the room is next recalculated.
            end
        end)
        local ok = pcall(dfhack.buildings.setOwner, bed, unit)
        if ok then
            idx = idx + 1
            local name = 'a dwarf'
            local okn, vis = pcall(dfhack.units.getVisibleName, unit)
            if okn and vis then
                local okt, t = pcall(dfhack.TranslateName, vis)
                if okt then name = t end
            end
            table.insert(done, ('gave %s a bedroom'):format(name))
        end
    end
    return done
end

-- Queue the furniture the fort is short of.

function queue_furniture()
    local h = housing()
    local short = math.max(0, h.citizens - h.beds)
    if short == 0 then return {}, 'every citizen has a bed' end
    local batch = math.min(short, MAX_BATCH)
    local queued = {}
    for _, item in ipairs(PER_ROOM) do
        local have = ({
            beds = h.beds, doors = h.doors, chests = h.chests, cabinets = h.cabinets,
        })[item.name] or 0
        local want = math.max(0, math.min(batch, h.citizens - have))
        if want > 0 then
            local ok = pcall(dfhack.run_command, 'workorder',
                ('{"job":"%s","amount_total":%d,"material":"INORGANIC"}'):format(item.job, want))
            if ok then
                table.insert(queued, ('%d %s'):format(want, item.name))
            end
        end
    end
    return queued, ('%d citizens without a bed'):format(short)
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_quarters_state = antfarm_quarters_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 600

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_quarters_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_quarters_state.last_run = now
    -- Place first, then assign: assigning is a no-op while there are no beds.
    local okp, made = pcall(place_beds)
    if okp and type(made) == 'table' then
        for _, m in ipairs(made) do
            table.insert(antfarm_quarters_state.notes, 1, m)
        end
    end
    local ok, done = pcall(assign_beds)
    if ok then
        for _, msg in ipairs(done) do
            table.insert(antfarm_quarters_state.notes, 1, msg)
        end
    end
    pcall(queue_furniture)
    while #antfarm_quarters_state.notes > 10 do table.remove(antfarm_quarters_state.notes) end
end

function report()
    local h = housing()
    return {
        citizens = h.citizens,
        beds = h.beds,
        rooms = h.rooms,
        owned = h.owned,
        doors = h.doors,
        chests = h.chests,
        cabinets = h.cabinets,
        unhoused = math.max(0, h.citizens - h.owned),
        notes = antfarm_quarters_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'assign' then
    local done = assign_beds()
    if #done == 0 then print('antfarm_quarters: no free beds to assign') end
    for _, m in ipairs(done) do print('antfarm_quarters: ' .. m) end
elseif verb == 'beds' then
    local made, why = place_beds()
    print('antfarm_quarters: ' .. tostring(why))
    for _, m in ipairs(made) do print('antfarm_quarters: ' .. m) end
elseif verb == 'orders' then
    local queued, why = queue_furniture()
    print('antfarm_quarters: ' .. tostring(why))
    if #queued > 0 then
        print('antfarm_quarters: queued ' .. table.concat(queued, ', '))
    end
else
    local h = housing()
    print(('antfarm_quarters: %d citizens, %d beds (%d defined as rooms, %d owned)')
        :format(h.citizens, h.beds, h.rooms, h.owned))
    print(('antfarm_quarters: doors=%d chests=%d cabinets=%d')
        :format(h.doors, h.chests, h.cabinets))
    local short = math.max(0, h.citizens - h.owned)
    if short > 0 then
        print(('antfarm_quarters: %d citizens have no bedroom of their own'):format(short))
    end
end
