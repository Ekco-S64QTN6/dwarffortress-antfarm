-- antfarm_embark.lua
-- Pick a flat embark site and start the fortress, with nobody at the keyboard.
--
-- WHY
--
-- Everything downstream assumed a fort already existed. `antfarm_blueprint`
-- picks where to put the fort *within* an embark; nothing chose the embark. On
-- a stream that meant a human had to sit through the site-selection screen
-- before the automation had anything to do.
--
-- WHAT "GOOD" MEANS HERE
--
-- Not what a player optimising for fun would pick. The constraints come from
-- what the rest of the system needs and from what reads clearly on camera:
--
--   * FLAT, above all else. The surface fort is what viewers actually see, and
--     a site with elevation changes running through it looks like rubble on
--     stream. Dreamfort also wants a large level area -- `footprint_quality`
--     warns below 85% usable. Flatness is scored on the world-tile elevation
--     spread across the whole embark rectangle, which is the same number DF
--     shows you in the embark elevation grid.
--   * No aquifer. `antfarm_blueprint.survey` rejects an aquifer column outright,
--     so an aquifer embark leaves the guided build with nowhere to dig.
--   * Not evil, not freezing. Evil biomes kill an unattended fort with husking
--     clouds; a freezing biome has no liquid water and no farming.
--   * Some trees. The first Dreamfort steps clear trees and build wooden
--     workshops; a barren desert stalls step 2 forever.
--
-- HOW
--
-- Two passes, because the cheap data is coarse and the exact data is expensive:
--
--   1. Scan `world_data.region_map` over the whole world -- elevation, biome,
--      evilness, savagery, drainage, vegetation -- and rank every candidate
--      rectangle. This is pure arithmetic, no UI.
--   2. Walk the cursor onto the best candidates in rank order and read DF's own
--      `in_embark_aquifer` / `in_embark_salt` / `in_embark_narrow`, which it
--      recomputes for the selected rectangle. That is the authoritative aquifer
--      check and there is no way to get it without selecting the site.
--
-- Then press the same keys a player would: resize to WIDTHxHEIGHT, and embark.
--
-- Usage (from the site selection screen):
--   antfarm_embark              scan, pick the best usable site and embark
--   antfarm_embark scan [N]     rank the top N sites and change nothing
--   antfarm_embark next         move the cursor to the next ranked site
--   antfarm_embark prev         ...and back
--   antfarm_embark here         embark where the cursor is now
--   antfarm_embark dry          pick a site but stop before embarking
--
-- `next`/`prev` are bound to Ctrl-N and Ctrl-P on the embark screen (see
-- game/dfhack-config/init/dfhack.init), so a site can be eyeballed on camera
-- before committing: each step prints the site's stats and DF's own live
-- aquifer/salt verdict for the rectangle under the cursor.

--@module = true

local gui = require('gui')

-- A 4x4 embark: 192x192 tiles. Dreamfort's surface fort is about 45x45, so this
-- leaves a wide flat apron around it for the camera, at a tolerable FPS cost.
local WIDTH, HEIGHT = 4, 4

-- Elevation spread across the embark's world tiles. 0 is dead flat; 1 tolerates
-- a single step. Anything more and the surface fort sits on a slope.
local MAX_ELEV_SPREAD = 1
-- DF elevation: below 100 is ocean, 100 is sea level.
local OCEAN_LEVEL = 100
-- Evil biomes husk the dwarves; there is no automation for that.
local MAX_EVILNESS = 65
-- Very savage biomes throw megabeasts at a fort with no military.
local MAX_SAVAGERY = 75
-- Below about 25 the biome is Cold or Freezing: surface water is ice all year,
-- which means no well, no fishing and no outdoor farming. Above 90 is scorching
-- and treeless. Measured on a real Tolkien-preset world, a floor of 10 happily
-- picked a site at temperature 15.
local MIN_TEMPERATURE, MAX_TEMPERATURE = 25, 90
-- Something has to be growing, for wood.
local MIN_VEGETATION = 5
-- How many ranked candidates to actually walk the cursor onto before giving up.
local MAX_PROBES = 24
-- Frames to wait after a cursor move for DF to recompute the embark flags.
local SETTLE_FRAMES = 2

local function world_data()
    local ok, wd = pcall(function() return df.global.world.world_data end)
    if ok then return wd end
    return nil
end

local function on_site_screen()
    local ok, scr = pcall(dfhack.gui.getCurViewscreen)
    if not ok or not scr then return nil end
    local ok2, hit = pcall(function()
        return df.viewscreen_choose_start_sitest:is_instance(scr)
    end)
    if ok2 and hit then return scr end
    return nil
end

-- ---------------------------------------------------------------- --
-- pass 1: rank every rectangle from the region map                  --
-- ---------------------------------------------------------------- --

-- Returns a list of {x, y, spread, score, why} sorted best-first.
function scan(width, height)
    width, height = width or WIDTH, height or HEIGHT
    local wd = world_data()
    if not wd then return {}, 'no world loaded' end

    local W, H = wd.world_width, wd.world_height
    if W < width or H < height then
        return {}, ('world is only %dx%d, smaller than the %dx%d embark')
            :format(W, H, width, height)
    end

    -- world_data.region_map is region_map_entry**: region_map[x] dereferences
    -- to the FIRST entry of column x, not to an indexable array, so the y index
    -- has to be pointer arithmetic. region_map[x][y] silently reads a field
    -- named "y" off an entry and raises.
    local map = wd.region_map
    local function at(x, y) return map[x]:_displace(y) end
    local out = {}
    local rejected = {ocean = 0, slope = 0, evil = 0, savage = 0,
                      cold = 0, barren = 0}

    for x = 0, W - width do
        for y = 0, H - height do
            local lo, hi = 9999, -9999
            local evil, savage, veg, temp, drain = 0, 0, 0, 0, 0
            local ok = true
            local n = 0

            for dx = 0, width - 1 do
                for dy = 0, height - 1 do
                    local e = at(x + dx, y + dy)
                    local elev = e.elevation
                    if elev < OCEAN_LEVEL then
                        rejected.ocean = rejected.ocean + 1
                        ok = false
                        break
                    end
                    if elev < lo then lo = elev end
                    if elev > hi then hi = elev end
                    if e.evilness > evil then evil = e.evilness end
                    if e.savagery > savage then savage = e.savagery end
                    veg = veg + e.vegetation
                    temp = temp + e.temperature
                    drain = drain + e.drainage
                    n = n + 1
                end
                if not ok then break end
            end
            if ok then
                local spread = hi - lo
                veg = veg / n
                temp = temp / n
                drain = drain / n

                if spread > MAX_ELEV_SPREAD then
                    rejected.slope = rejected.slope + 1
                elseif evil > MAX_EVILNESS then
                    rejected.evil = rejected.evil + 1
                elseif savage > MAX_SAVAGERY then
                    rejected.savage = rejected.savage + 1
                elseif temp < MIN_TEMPERATURE or temp > MAX_TEMPERATURE then
                    rejected.cold = rejected.cold + 1
                elseif veg < MIN_VEGETATION then
                    rejected.barren = rejected.barren + 1
                else
                    -- Flatness dominates by an order of magnitude; everything
                    -- else only separates equally flat sites.
                    local score = 1000 - spread * 500
                                + veg * 2
                                - evil * 1.5
                                - savage * 0.5
                    -- Middling drainage means soil without a swamp. Very high
                    -- drainage is desert rock, very low is wetland (and, in
                    -- practice, aquifers).
                    score = score - math.abs(drain - 50) * 0.6
                    table.insert(out, {
                        x = x, y = y, spread = spread, score = score,
                        evil = evil, savage = savage,
                        veg = math.floor(veg), temp = math.floor(temp),
                        drain = math.floor(drain),
                    })
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.score > b.score end)
    return out, nil, rejected
end

-- ---------------------------------------------------------------- --
-- pass 2: drive the site screen                                     --
-- ---------------------------------------------------------------- --

local function key(scr, k)
    pcall(gui.simulateInput, scr, k)
end

-- Resize the embark rectangle to width x height using the same keys a player
-- presses. DF clamps at 1 and 16, so pressing past the end is harmless.
local function set_embark_size(scr, width, height)
    for _ = 1, 16 do key(scr, 'SETUP_LOCAL_X_DOWN') end
    for _ = 2, width do key(scr, 'SETUP_LOCAL_X_UP') end
    for _ = 1, 16 do key(scr, 'SETUP_LOCAL_Y_DOWN') end
    for _ = 2, height do key(scr, 'SETUP_LOCAL_Y_UP') end
end

local function cursor_pos(scr)
    local ok, p = pcall(function() return scr.location.region_pos end)
    if ok and p then return p.x, p.y end
    return nil, nil
end

-- Walk the cursor to (tx, ty) with arrow keys. Direct assignment to
-- location.region_pos does not make DF recompute in_embark_aquifer, and that
-- flag is the whole reason for this pass.
local function move_cursor_to(scr, tx, ty, budget)
    budget = budget or 400
    for _ = 1, budget do
        local cx, cy = cursor_pos(scr)
        if not cx then return false end
        if cx == tx and cy == ty then return true end
        if cx < tx then key(scr, 'CURSOR_RIGHT')
        elseif cx > tx then key(scr, 'CURSOR_LEFT')
        elseif cy < ty then key(scr, 'CURSOR_DOWN')
        else key(scr, 'CURSOR_UP') end
    end
    return false
end

-- These are df-structures BooleanEnum fields, which DFHack hands to Lua as real
-- booleans -- not as 0/1. Testing them with `~= 0` reports every flag as set,
-- because in Lua `false ~= 0` is true: a boolean is never equal to a number.
-- That made every candidate site look like it had an aquifer.
local function truthy(v)
    return v == true or v == 1
end

local function embark_flags(scr)
    local f = {}
    pcall(function()
        f.aquifer = truthy(scr.in_embark_aquifer)
        f.salt = truthy(scr.in_embark_salt)
        f.narrow = truthy(scr.in_embark_narrow)
        f.civ_dying = truthy(scr.in_embark_civ_dying)
    end)
    return f
end

-- ---------------------------------------------------------------- --
-- the driver                                                        --
-- ---------------------------------------------------------------- --

antfarm_embark = antfarm_embark or {running = false, log = {}, cache = nil, idx = 0}

local function note(text)
    table.insert(antfarm_embark.log, text)
    while #antfarm_embark.log > 20 do table.remove(antfarm_embark.log, 1) end
    print('antfarm_embark: ' .. text)
end

-- Runs as a coroutine so it can yield between keystrokes; DF needs a frame to
-- process each one and to recompute the embark flags.
local function body(width, height, dry_run)
    local scr = on_site_screen()
    if not scr then
        dfhack.printerr('antfarm_embark: not on the embark site selection screen.')
        dfhack.printerr('  Start Playing -> pick a world, then run this.')
        return
    end

    local ranked, err, rejected = scan(width, height)
    if err then
        dfhack.printerr('antfarm_embark: ' .. err)
        return
    end
    note(('%d flat candidate site(s); rejected %d ocean, %d sloped, %d evil, '
          .. '%d savage, %d cold, %d barren')
        :format(#ranked, rejected.ocean, rejected.slope, rejected.evil,
                rejected.savage, rejected.cold, rejected.barren))
    if #ranked == 0 then
        dfhack.printerr('antfarm_embark: nowhere on this world is flat enough. '
            .. 'Regenerate, or raise MAX_ELEV_SPREAD at the top of this script.')
        return
    end

    set_embark_size(scr, width, height)
    coroutine.yield()

    local tried = 0
    for _, site in ipairs(ranked) do
        if tried >= MAX_PROBES then break end
        tried = tried + 1

        if not move_cursor_to(scr, site.x, site.y) then
            note(('could not reach %d,%d'):format(site.x, site.y))
        else
            for _ = 1, SETTLE_FRAMES do coroutine.yield() end
            local f = embark_flags(scr)
            local reason
            if f.aquifer then reason = 'aquifer'
            elseif f.salt then reason = 'salt water'
            elseif f.narrow then reason = 'too narrow'
            elseif f.civ_dying then reason = 'civilisation is dying'
            end

            if reason then
                note(('%d,%d rejected: %s'):format(site.x, site.y, reason))
            else
                note(('chose %d,%d -- elevation spread %d, vegetation %d, '
                      .. 'evil %d, savagery %d')
                    :format(site.x, site.y, site.spread, site.veg,
                            site.evil, site.savage))
                if dry_run then
                    note('dry run; not embarking')
                    return
                end
                key(scr, 'SETUP_EMBARK')
                coroutine.yield()
                -- DF asks for confirmation when something is unusual; the
                -- watchdog would eventually clear it, but answer it here so the
                -- embark is not left half-done.
                for _ = 1, 4 do
                    if not on_site_screen() then break end
                    key(select(1, dfhack.gui.getCurViewscreen()), 'MENU_CONFIRM')
                    coroutine.yield()
                end
                note('embarked.')
                return
            end
        end
    end

    dfhack.printerr(('antfarm_embark: tried %d site(s), all had an aquifer or '
        .. 'were otherwise unusable.'):format(tried))
end

local timer
local function pump(co)
    if coroutine.status(co) == 'dead' then
        antfarm_embark.running = false
        return
    end
    local ok, err = coroutine.resume(co)
    if not ok then
        dfhack.printerr('antfarm_embark: ' .. tostring(err))
        antfarm_embark.running = false
        return
    end
    if coroutine.status(co) == 'dead' then
        antfarm_embark.running = false
        return
    end
    timer = dfhack.timeout(1, 'frames', function() pump(co) end)
end

function run(width, height, dry_run)
    if antfarm_embark.running then
        print('antfarm_embark: already running')
        return false
    end
    antfarm_embark.running = true
    antfarm_embark.log = {}
    pump(coroutine.create(function() body(width or WIDTH, height or HEIGHT, dry_run) end))
    return true
end

-- ---------------------------------------------------------------- --
-- browsing the shortlist by hand                                    --
-- ---------------------------------------------------------------- --

local function ranked_cached(force)
    if force or not antfarm_embark.cache then
        local ranked, err = scan(WIDTH, HEIGHT)
        if err then
            dfhack.printerr('antfarm_embark: ' .. err)
            return nil
        end
        antfarm_embark.cache = ranked
        antfarm_embark.idx = 0
    end
    return antfarm_embark.cache
end

local function describe_here(scr, site, i, total)
    local f = embark_flags(scr)
    local warn = {}
    if f.aquifer then table.insert(warn, 'AQUIFER') end
    if f.salt then table.insert(warn, 'salt water') end
    if f.narrow then table.insert(warn, 'narrow') end
    if f.civ_dying then table.insert(warn, 'civ dying') end
    print(('antfarm_embark: site %d/%d at %d,%d -- spread %d, vegetation %d, '
           .. 'temperature %d, evil %d, savagery %d%s')
        :format(i, total, site.x, site.y, site.spread, site.veg, site.temp,
                site.evil, site.savage,
                #warn > 0 and ('   [' .. table.concat(warn, ', ') .. ']') or '   [clear]'))
end

-- Step through the shortlist. `step` is +1 or -1.
function browse(step)
    local scr = on_site_screen()
    if not scr then
        dfhack.printerr('antfarm_embark: not on the embark site selection screen.')
        return false
    end
    local ranked = ranked_cached(false)
    if not ranked or #ranked == 0 then
        dfhack.printerr('antfarm_embark: no candidate sites. Try "antfarm_embark scan".')
        return false
    end
    -- Resize once, so what is on screen is the rectangle that was scored.
    set_embark_size(scr, WIDTH, HEIGHT)

    antfarm_embark.idx = ((antfarm_embark.idx - 1 + step) % #ranked) + 1
    local site = ranked[antfarm_embark.idx]
    move_cursor_to(scr, site.x, site.y)
    describe_here(scr, site, antfarm_embark.idx, #ranked)
    return true
end

function embark_here()
    local scr = on_site_screen()
    if not scr then
        dfhack.printerr('antfarm_embark: not on the embark site selection screen.')
        return false
    end
    local f = embark_flags(scr)
    if f.aquifer then
        dfhack.printerr('antfarm_embark: this site has an AQUIFER -- the guided '
            .. 'build cannot dig here. Use "antfarm_embark next", or embark by '
            .. 'hand if you mean it.')
        return false
    end
    key(scr, 'SETUP_EMBARK')
    print('antfarm_embark: embarking.')
    return true
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
if args[1] == 'next' then
    browse(1)
elseif args[1] == 'prev' then
    browse(-1)
elseif args[1] == 'here' then
    embark_here()
elseif args[1] == 'scan' then
    local show = tonumber(args[2]) or 10
    local ranked, err, rejected = scan(WIDTH, HEIGHT)
    if err then
        dfhack.printerr('antfarm_embark: ' .. err)
        return
    end
    print(('antfarm_embark: %d candidate %dx%d site(s) with elevation spread <= %d')
        :format(#ranked, WIDTH, HEIGHT, MAX_ELEV_SPREAD))
    print(('  rejected: %d ocean, %d sloped, %d evil, %d savage, %d cold, %d barren')
        :format(rejected.ocean, rejected.slope, rejected.evil, rejected.savage,
                rejected.cold, rejected.barren))
    for i = 1, math.min(show, #ranked) do
        local s = ranked[i]
        print(('  %2d. %3d,%-3d  score %6.0f  spread %d  veg %3d  temp %3d  '
               .. 'drain %3d  evil %3d  savagery %3d')
            :format(i, s.x, s.y, s.score, s.spread, s.veg, s.temp, s.drain,
                    s.evil, s.savage))
    end
    if #ranked > 0 then
        antfarm_embark.cache = ranked
        antfarm_embark.idx = 0
        print('Ctrl-N / Ctrl-P step through these on the map; "antfarm_embark here"')
        print('embarks where the cursor is, "antfarm_embark" takes the best usable one.')
    end
elseif args[1] == 'dry' then
    run(WIDTH, HEIGHT, true)
else
    run(WIDTH, HEIGHT, false)
end
