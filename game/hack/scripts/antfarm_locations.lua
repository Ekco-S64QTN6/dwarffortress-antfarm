-- antfarm_locations.lua
-- Give the fort somewhere to be that is not the wagon.
--
-- A fort embarks with one meeting area: a big zone on the surface where the
-- wagon lands. Nothing ever replaces it, so no matter how much dining hall gets
-- dug, every idle dwarf walks back up to stand in a field. On the fort this was
-- written against that zone was 25x11 on the surface and was the *only* meeting
-- area in the fort, with 12 tables and chairs sitting unused a level below.
--
-- Moving the meeting area underground is the single cheapest change to how a
-- fort behaves: it decides where dwarves idle, socialise, hold meetings and
-- hold elections.
--
-- Usage:
--   antfarm_locations             report zones, dining area and deities
--   antfarm_locations hall        put the meeting area in the dining room
--   antfarm_locations deities     who the fort worships, and what temples it wants

--@module = true

local MIN_DINING_FURNITURE = 4   -- fewer than this is not a dining room yet

-- A meeting hall is where the whole fort stands around at once, plus whatever
-- livestock wanders in. Sizing it to the furniture footprint alone gave a
-- 16x5 hall (80 tiles) for 59 citizens -- everyone shoulder to shoulder, which
-- is a pathing jam and a stress source rather than a dining room.
local TILES_PER_CITIZEN = 3
local MIN_HALL_TILES = 80
local MAX_HALL_TILES = 900      -- past this the zone is swallowing corridors

-- ---------------------------------------------------------------- --
-- zones                                                            --
-- ---------------------------------------------------------------- --

local function civzones()
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Civzone then table.insert(out, b) end
    end
    return out
end

local function is_meeting(zone)
    local ok, v = pcall(function() return zone.zone_flags.meeting_area end)
    return ok and v and true or false
end

function meeting_areas()
    local out = {}
    for _, z in ipairs(civzones()) do
        if is_meeting(z) then table.insert(out, z) end
    end
    return out
end

-- ---------------------------------------------------------------- --
-- finding the dining room                                          --
-- ---------------------------------------------------------------- --

-- The dining room is wherever the fort's tables and chairs actually are. That
-- is more reliable than trusting a blueprint step to have run, and it is how a
-- human would find it.
function dining_area()
    local byz = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        if t == df.building_type.Table or t == df.building_type.Chair then
            local e = byz[b.z]
            if not e then
                e = {count = 0, x1 = 99999, y1 = 99999, x2 = -1, y2 = -1, z = b.z}
                byz[b.z] = e
            end
            e.count = e.count + 1
            if b.x1 < e.x1 then e.x1 = b.x1 end
            if b.y1 < e.y1 then e.y1 = b.y1 end
            if b.x2 > e.x2 then e.x2 = b.x2 end
            if b.y2 > e.y2 then e.y2 = b.y2 end
        end
    end
    local best
    for _, e in pairs(byz) do
        if e.count >= MIN_DINING_FURNITURE and (not best or e.count > best.count) then
            best = e
        end
    end
    return best
end

-- ---------------------------------------------------------------- --
-- indoor space, before there is any furniture                      --
-- ---------------------------------------------------------------- --

-- A dining room needs tables and chairs, and Dreamfort does not build those
-- until step 9. Until then the only meeting area is the embark default on the
-- surface, so the whole fort stands outside -- in the rain, which in 0.47 is a
-- real and compounding stress source (AGENTS.md 4.3). An empty dug room is not
-- a dining hall, but it has a roof, and that is the part that matters.
--
-- Finds the biggest block of already-dug indoor floor on the shallowest dug
-- level near the anchor.
local function indoor_rect(ax, ay, z, want)
    local function indoor(x, y)
        local b = dfhack.maps.getTileBlock(x, y, z)
        if not b then return false end
        local a = df.tiletype.attrs[b.tiletype[x % 16][y % 16]]
        local d = b.designation[x % 16][y % 16]
        return a.shape == df.tiletype_shape.FLOOR and not d.outside
            and (not d.flow_size or d.flow_size == 0)
    end
    -- Grow a square outward from the densest indoor spot we can find.
    local best, best_n
    for size = want, 5, -1 do
        for ox = -20, 20, 2 do
            for oy = -20, 20, 2 do
                local x0, y0, n, total = ax + ox, ay + oy, 0, 0
                for x = x0, x0 + size - 1 do
                    for y = y0, y0 + size - 1 do
                        total = total + 1
                        if indoor(x, y) then n = n + 1 end
                    end
                end
                if total > 0 and n == total and (not best_n or n > best_n) then
                    best_n, best = n, {x1 = x0, y1 = y0, x2 = x0 + size - 1,
                                       y2 = y0 + size - 1, z = z, count = 0}
                end
            end
        end
        if best then return best end
    end
    return nil
end

-- The shallowest level that has been dug out, which is where dwarves will
-- actually go: deeper is a longer walk from the stairs.
local function dug_levels(ax, ay)
    local out = {}
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    local levels
    if ok and bp and bp.plan_summary then
        local okp, sum = pcall(bp.plan_summary)
        if okp and sum then levels = sum.levels end
    end
    if not levels then return out end
    for _, name in ipairs({'farming', 'services', 'industry', 'guildhall'}) do
        local z = levels[name]
        if type(z) == 'number' then table.insert(out, z) end
    end
    table.sort(out, function(a, b) return a > b end)   -- shallowest first
    return out
end

-- ---------------------------------------------------------------- --
-- the meeting hall                                                 --
-- ---------------------------------------------------------------- --

local WALKABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.STAIR_UP] = true,
    [df.tiletype_shape.STAIR_DOWN] = true,
    [df.tiletype_shape.STAIR_UPDOWN] = true,
    [df.tiletype_shape.RAMP] = true,
}

local function strip_is_open(x1, y1, x2, y2, z)
    local open, total = 0, 0
    for x = x1, x2 do
        for y = y1, y2 do
            local block = dfhack.maps.getTileBlock(x, y, z)
            if not block then return false end
            total = total + 1
            local tt = block.tiletype[x % 16][y % 16]
            if WALKABLE[df.tiletype.attrs[tt].shape] then open = open + 1 end
        end
    end
    -- A mostly-open strip is room; a mostly-solid one is the wall we stop at.
    return total > 0 and open >= total * 0.7
end

-- Grow the furniture bounding box outward into whatever room it sits in, until
-- the hall is big enough for the population or it runs into walls.
local function grow_to_fit(area, citizens)
    local target = math.max(MIN_HALL_TILES, citizens * TILES_PER_CITIZEN)
    target = math.min(target, MAX_HALL_TILES)
    local x1, y1, x2, y2 = area.x1, area.y1, area.x2, area.y2
    local blocked = {}
    -- Round-robin the four directions so the hall grows evenly rather than
    -- becoming a long corridor in whichever direction happened to be open.
    local dirs = {'w', 'e', 'n', 's'}
    local i = 0
    while (x2 - x1 + 1) * (y2 - y1 + 1) < target and #dirs > 0 do
        i = i % #dirs + 1
        local d = dirs[i]
        local ok
        if d == 'w' then
            ok = strip_is_open(x1 - 1, y1, x1 - 1, y2, area.z)
            if ok then x1 = x1 - 1 end
        elseif d == 'e' then
            ok = strip_is_open(x2 + 1, y1, x2 + 1, y2, area.z)
            if ok then x2 = x2 + 1 end
        elseif d == 'n' then
            ok = strip_is_open(x1, y1 - 1, x2, y1 - 1, area.z)
            if ok then y1 = y1 - 1 end
        else
            ok = strip_is_open(x1, y2 + 1, x2, y2 + 1, area.z)
            if ok then y2 = y2 + 1 end
        end
        if not ok then
            table.remove(dirs, i)
            i = i - 1
        end
    end
    return {x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = area.z, count = area.count}
end

-- Create the zone, then retire the surface one. Order matters: clearing the old
-- meeting area first would leave the fort with none at all, and dwarves with no
-- meeting area pick their own spot, which is how they ended up at the wagon.
function ensure_meeting_hall()
    local area = dining_area()
    if not area then
        -- No furniture yet: take any roofed, dug room over leaving the fort
        -- standing in a field. This is replaced automatically once the dining
        -- room exists, because dining_area() then wins.
        local ax, ay = nil, nil
        local ok, bp = pcall(reqscript, 'antfarm_blueprint')
        if ok and bp and bp.plan_summary then
            local okp, sum = pcall(bp.plan_summary)
            if okp and sum and sum.anchor then ax, ay = sum.anchor.x, sum.anchor.y end
        end
        if not ax then
            return false, ('no dining room and no anchor (need %d tables/chairs, '
                .. 'or a dug room)'):format(MIN_DINING_FURNITURE)
        end
        for _, z in ipairs(dug_levels(ax, ay)) do
            area = indoor_rect(ax, ay, z, 11)
            if area then break end
        end
        if not area then
            return false, ('no dining room and nothing dug indoors yet (need %d '
                .. 'tables/chairs, or a dug room)'):format(MIN_DINING_FURNITURE)
        end
    end

    -- Already have a meeting area on the dining level? Then only the surface
    -- zone needs retiring.
    local existing
    for _, z in ipairs(meeting_areas()) do
        if z.z == area.z then existing = z break end
    end

    local made
    if not existing then
        -- Size to the population, not to the tables.
        local pop = 0
        for _, u in ipairs(df.global.world.units.active) do
            local okc, is = pcall(dfhack.units.isCitizen, u)
            if okc and is then pop = pop + 1 end
        end
        local okg, grown = pcall(grow_to_fit, area, pop)
        if okg and grown then area = grown end

        local w = area.x2 - area.x1 + 1
        local h = area.y2 - area.y1 + 1
        local cx = math.floor((area.x1 + area.x2) / 2)
        local cy = math.floor((area.y1 + area.y2) / 2)
        local ok, bld = pcall(dfhack.buildings.constructBuilding, {
            type = df.building_type.Civzone,
            subtype = df.civzone_type.ActivityZone,
            pos = xyz2pos(cx, cy, area.z),
            width = w, height = h,
            -- Zones are abstract: they consume no materials and need no items,
            -- and constructBuilding rejects them outright without this.
            abstract = true,
        })
        if not ok or not bld then
            return false, 'could not create the zone: ' .. tostring(bld)
        end
        pcall(function()
            bld.zone_flags.active = true
            bld.zone_flags.meeting_area = true
        end)
        made = bld
    end

    -- Retire every meeting area that is not the dining room. The zone itself is
    -- left in place (it is usually also a pasture, and deleting it would unpen
    -- the fort's animals) -- only the meeting_area flag is cleared.
    local retired = 0
    for _, z in ipairs(meeting_areas()) do
        if z.z ~= area.z then
            local ok = pcall(function() z.zone_flags.meeting_area = false end)
            if ok then retired = retired + 1 end
        end
    end

    return true, ('meeting area %s at z=%d (%dx%d); retired %d surface meeting area(s)')
        :format(made and 'created' or 'already present', area.z,
                area.x2 - area.x1 + 1, area.y2 - area.y1 + 1, retired)
end

-- ---------------------------------------------------------------- --
-- the grazing pasture                                              --
-- ---------------------------------------------------------------- --

-- Grazers starve in a 1x1 pen: DF feeds them from the grass under their feet,
-- and a pen that is too small is a slow death sentence rather than a pasture.
-- The embark default is a scatter of 1x1 pasture zones -- on the fort this was
-- written against, fourteen of them -- which is the shape that kills livestock.
--
-- One large grass paddock near the entrance, with a farmer's workshop beside it
-- for milking, cheese and shearing, is both kinder and far less hauling.
local PASTURE_SIZE = 10
local PASTURE_SEARCH = 25

local GRASS = {
    [df.tiletype_material.GRASS_LIGHT] = true,
    [df.tiletype_material.GRASS_DARK] = true,
    [df.tiletype_material.GRASS_DRY] = true,
    [df.tiletype_material.GRASS_DEAD] = true,
}

local PASTURE_SHAPES = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

local function pasture_tile_ok(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    local tt = block.tiletype[x % 16][y % 16]
    local des = block.designation[x % 16][y % 16]
    local a = df.tiletype.attrs[tt]
    if not PASTURE_SHAPES[a.shape] then return false end
    if des.flow_size and des.flow_size > 0 then return false end
    if des.dig ~= df.tile_dig_designation.No then return false end
    if dfhack.buildings.findAtTile(xyz2pos(x, y, z)) then return false end
    return true, GRASS[a.material] and true or false
end

-- Prefer the grassiest square available: grass is the whole point.
function find_pasture_site()
    local anchor, z
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if ok and bp and bp.plan_summary then
        local okp, sum = pcall(bp.plan_summary)
        if okp and sum and sum.anchor and sum.levels then
            anchor, z = sum.anchor, sum.levels.surface
        end
    end
    if not anchor then return nil, 'no fort anchor -- run antfarm_blueprint here first' end

    local best, best_grass
    for dx = -PASTURE_SEARCH, PASTURE_SEARCH do
        for dy = -PASTURE_SEARCH, PASTURE_SEARCH do
            local x0, y0 = anchor.x + dx, anchor.y + dy
            local okall, grass = true, 0
            for x = x0, x0 + PASTURE_SIZE - 1 do
                for y = y0, y0 + PASTURE_SIZE - 1 do
                    local fine, is_grass = pasture_tile_ok(x, y, z)
                    if not fine then okall = false break end
                    if is_grass then grass = grass + 1 end
                end
                if not okall then break end
            end
            if okall and (not best_grass or grass > best_grass) then
                best_grass, best = grass, {x = x0, y = y0, z = z}
            end
        end
    end
    if not best then
        return nil, ('no clear %dx%d site within %d tiles of the anchor')
            :format(PASTURE_SIZE, PASTURE_SIZE, PASTURE_SEARCH)
    end
    best.grass = best_grass
    return best
end

function existing_pastures()
    local big, small = 0, 0
    for _, z in ipairs(civzones()) do
        local ok, pen = pcall(function() return z.zone_flags.pen_pasture end)
        if ok and pen then
            local area = (z.x2 - z.x1 + 1) * (z.y2 - z.y1 + 1)
            if area >= 25 then big = big + 1 else small = small + 1 end
        end
    end
    return big, small
end

function ensure_pasture()
    local big = existing_pastures()
    if big > 0 then return false, 'a real pasture already exists' end
    local site, err = find_pasture_site()
    if not site then return false, err end

    local cx = site.x + math.floor(PASTURE_SIZE / 2)
    local cy = site.y + math.floor(PASTURE_SIZE / 2)
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.Civzone,
        subtype = df.civzone_type.ActivityZone,
        pos = xyz2pos(cx, cy, site.z),
        width = PASTURE_SIZE, height = PASTURE_SIZE,
        abstract = true,
    })
    if not ok or not bld then
        return false, 'could not create the pasture zone: ' .. tostring(bld)
    end
    pcall(function()
        bld.zone_flags.active = true
        bld.zone_flags.pen_pasture = true
    end)

    -- A farmer's workshop beside the paddock turns the walk to the milk into a
    -- few tiles instead of a trip through the whole fort.
    local shop = 'no farmer workshop sited'
    for _, d in ipairs({{PASTURE_SIZE + 1, 0}, {-4, 0}, {0, PASTURE_SIZE + 1}, {0, -4}}) do
        local sx, sy = site.x + d[1], site.y + d[2]
        local clear = true
        for x = sx, sx + 2 do
            for y = sy, sy + 2 do
                if not pasture_tile_ok(x, y, site.z) then clear = false break end
            end
            if not clear then break end
        end
        if clear then
            local oks = pcall(dfhack.buildings.constructBuilding, {
                type = df.building_type.Workshop,
                subtype = df.workshop_type.Farmers,
                pos = xyz2pos(sx + 1, sy + 1, site.z),
            })
            if oks then
                shop = ('farmer workshop at %d,%d'):format(sx + 1, sy + 1)
                pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
                break
            end
        end
    end

    return true, ('%dx%d pasture at %d,%d,%d (%d grass tiles); %s')
        :format(PASTURE_SIZE, PASTURE_SIZE, site.x, site.y, site.z, site.grass or 0, shop)
end

-- ---------------------------------------------------------------- --
-- worship                                                          --
-- ---------------------------------------------------------------- --

-- Temples should follow what the fort actually believes, not a generic plan.
-- Counting deity links across citizens is how to find that out.
local TEMPLE_THRESHOLD = 5   -- worshippers before a deity earns a dedicated temple

function deities()
    local tally = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is and u.hist_figure_id and u.hist_figure_id ~= -1 then
            local hf = df.historical_figure.find(u.hist_figure_id)
            if hf then
                pcall(function()
                    for _, l in ipairs(hf.histfig_links) do
                        if l:getType() == df.histfig_hf_link_type.DEITY then
                            local d = df.historical_figure.find(l.target_hf)
                            local name = d and dfhack.TranslateName(d.name)
                                or ('hf#' .. tostring(l.target_hf))
                            tally[name] = (tally[name] or 0) + 1
                        end
                    end
                end)
            end
        end
    end
    local rows = {}
    for name, n in pairs(tally) do
        table.insert(rows, {deity = name, worshippers = n,
                            wants_temple = n >= TEMPLE_THRESHOLD})
    end
    table.sort(rows, function(a, b) return a.worshippers > b.worshippers end)
    return rows
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

antfarm_locations_state = antfarm_locations_state or {last_run = 0, notes = {}}
local RUN_INTERVAL_SEC = 600

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_locations_state.last_run < RUN_INTERVAL_SEC then return end
    antfarm_locations_state.last_run = now
    -- Only act when the fort is still idling on the surface; once the meeting
    -- area is underground this is a no-op.
    local surface_meeting = false
    local area = dining_area()
    if area then
        for _, z in ipairs(meeting_areas()) do
            if z.z ~= area.z then surface_meeting = true end
        end
        if surface_meeting then
            local ok, msg = ensure_meeting_hall()
            if ok then table.insert(antfarm_locations_state.notes, 1, msg) end
        end
    end
    -- pcall returns (pcall_ok, created, message); a pasture is only made when
    -- the fort has no large one already, so this is a no-op most cycles.
    local call_ok, created, why = pcall(ensure_pasture)
    if call_ok and created then
        table.insert(antfarm_locations_state.notes, 1, tostring(why))
    end
    while #antfarm_locations_state.notes > 8 do
        table.remove(antfarm_locations_state.notes)
    end
end

function report()
    local area = dining_area()
    local halls = {}
    for _, z in ipairs(meeting_areas()) do table.insert(halls, z.z) end
    local want_temples = {}
    local ok, rows = pcall(deities)
    if ok then
        for _, r in ipairs(rows) do
            if r.wants_temple then
                table.insert(want_temples, ('%s (%d)'):format(r.deity, r.worshippers))
            end
        end
    end
    local big_pastures, tiny_pastures = existing_pastures()
    return {
        pastures = big_pastures,
        tiny_pastures = tiny_pastures,
        dining_z = area and area.z or nil,
        dining_furniture = area and area.count or 0,
        meeting_levels = halls,
        temples_wanted = want_temples,
        notes = antfarm_locations_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'hall' then
    local _, msg = ensure_meeting_hall()
    print('antfarm_locations: ' .. tostring(msg))
elseif verb == 'pasture' then
    local _, msg = ensure_pasture()
    print('antfarm_locations: ' .. tostring(msg))
elseif verb == 'deities' then
    print('antfarm_locations: who the fort worships')
    for _, r in ipairs(deities()) do
        print(('   %-38s %3d worshippers%s'):format(r.deity, r.worshippers,
            r.wants_temple and '   << wants a dedicated temple' or ''))
    end
else
    local area = dining_area()
    if area then
        print(('antfarm_locations: dining room on z=%d (%d tables/chairs, %dx%d)')
            :format(area.z, area.count, area.x2 - area.x1 + 1, area.y2 - area.y1 + 1))
    else
        print('antfarm_locations: no dining room found yet')
    end
    for _, z in ipairs(meeting_areas()) do
        print(('antfarm_locations: meeting area on z=%d%s'):format(z.z,
            (area and z.z ~= area.z) and '   << above ground; dwarves idle here' or ''))
    end
end
