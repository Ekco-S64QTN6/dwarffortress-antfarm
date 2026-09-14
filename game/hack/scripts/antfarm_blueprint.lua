-- antfarm_blueprint.lua
-- Drives a real fortress build instead of just punching holes in rock.
--
-- Dwarf Fortress ships (via DFHack) the Dreamfort blueprint set: a complete,
-- community-tuned fortress with proper traffic flow, a trap-corridor entrance,
-- farming, industry, services, guildhalls and apartments -- including the
-- furniture, stockpiles, zones and room assignments, not just the digging.
-- This script surveys the embark's geology, picks sensible z-levels for each
-- Dreamfort layer, and walks the official build checklist, gating each step on
-- whether the previous one's digging and construction actually finished.
--
--   antfarm_blueprint survey            report geology and level choices
--   antfarm_blueprint here              anchor the fort at the cursor
--   antfarm_blueprint autostart         pick a site by itself and start building
--   antfarm_blueprint status            progress through the checklist
--   antfarm_blueprint list              the full plan
--   antfarm_blueprint next [--force]    apply the next step
--   antfarm_blueprint auto on|off       apply steps as their gates clear
--   antfarm_blueprint orders            enqueue manager orders for what is next
--   antfarm_blueprint unstick           clear designations the miners keep
--                                       cancelling (damp/warm stone)
--   antfarm_blueprint reset             forget progress (designations stay)
--   antfarm_blueprint simple [-d N]     the old standalone digger; works anywhere
--
-- See AGENTS.md 6.1.1-6.1.3 for the designation-API pitfalls encoded here.

--@module = true

local json = require('json')
local utils = require('utils')

local PLAN_FILE = 'antfarm_plan.json'
local DREAMFORT = 'library/dreamfort.csv'

-- Dreamfort's surface fort is about 45x45; the underground levels are smaller.
local FOOTPRINT = 45
local SURVEY_SAMPLE = 5     -- half-width of the column we sample for geology

-- Dreamfort's underground levels are NOT independently placeable. Its /dig_all
-- blueprint is anchored once, on the industry level, and digs everything below
-- at fixed offsets (read straight out of dreamfort.csv):
--     /industry1  #>  /services1  #>4  /guildhall1  #>  /suites1  #>
--     /apartments1 repeat(down 5)
-- so only the surface, the farming level and the industry level are free
-- choices; the rest follow. Surveying them independently would place blueprints
-- where /dig_all never dug.
local DREAMFORT_ZOFF = {
    industry   = 0,
    services   = -1,
    guildhall  = -5,
    suites     = -6,
    apartments = -7,     -- and four more below it, via repeat(down 5)
}
local DREAMFORT_DEPTH = 12   -- levels of rock needed below the industry level

-- A quickfort run that reports success but touches nothing has not actually
-- done the step. Retry it this many times before giving up and moving on with
-- a recorded warning -- silently skipping a build step is how a fort ends up
-- with no still and no farm plots. (Report finding F-05.)
local MAX_STEP_ATTEMPTS = 3
-- A gate that has not moved in this long is not "waiting", it is stuck.
local STALL_SEC = 900
-- Cap the damp-stone sweep: it walks tiles and must not hitch the game.
local UNSTICK_CAP = 4000

antfarm_plan = antfarm_plan or nil

-- ---------------------------------------------------------------- --
-- the build checklist                                              --
-- ---------------------------------------------------------------- --
-- Transcribed from Dreamfort's own `#notes checklist` blueprint, which is the
-- authoritative build order. `level` names which surveyed z-level the blueprint
-- is anchored on; `gate` says what must be quiet before the step may run:
--   dig   - no outstanding dig designations ON THE LEVELS THAT STEP NEEDS
--   build - the above, plus no outstanding construction jobs
--   none  - safe to run immediately after the previous step
--
-- `gate_levels` names which surveyed levels must be clear; it defaults to the
-- step's own level. This matters enormously: gating every 'dig' step on the
-- WHOLE excavation meant /surface2 -- which builds the starting workshops,
-- including the still -- waited behind all ~6000 tiles of /dig_all. The fort ran
-- out of booze with no still and no farm plots built. Dreamfort's checklist is
-- explicit that each step waits only on its own level ("Run when the farming
-- level has been dug out").
local PLAN = {
    {bp = '/setup',        level = 'surface',  gate = 'none',  orders = false,
     note = 'fort-wide settings; must run before manual tweaks'},
    {bp = '/surface1',     level = 'surface',  gate = 'none',  orders = false,
     note = 'clear trees and mark the central stairs'},
    {bp = '/dig_all',      level = 'industry', gate = 'none',  orders = false,
     note = 'designate industry, services, guildhall, suites and apartments'},
    {bp = '/central_stairs', level = 'stairs_top', gate = 'none', orders = false,
     repeat_down = true,
     note = 'spiral stairs linking the farming level down to industry'},
    -- The still, the food stockpiles and the starting workshops live here.
    -- Dreamfort: "Run after initial trees are cleared" -- surface only.
    {bp = '/surface2',     level = 'surface',  gate = 'dig',   orders = true,
     gate_levels = {'surface'},
     note = 'starting workshops and stockpiles (still + food)'},
    -- Dreamfort: "Run when channels are dug and the additional designated
    -- trees are cleared" -- that work is on the surface, not the farm level.
    {bp = '/farming1',     level = 'farming',  gate = 'dig',   orders = false,
     gate_levels = {'surface'},
     note = 'dig the farming level in the soil layer'},
    {bp = '/farming2',     level = 'farming',  gate = 'dig',   orders = true,
     note = 'farm plots, workshops and stockpiles'},
    {bp = '/surface3',     level = 'surface',  gate = 'none',  orders = true,
     note = 'surface walls and floors'},
    {bp = '/farming3',     level = 'farming',  gate = 'build', orders = true,
     note = 'configure rooms, build farm plots and furniture'},
    {bp = '/industry2',    level = 'industry', gate = 'dig',   orders = true,
     note = 'industry workshops and stockpiles'},
    {bp = '/surface4',     level = 'surface',  gate = 'build', orders = true,
     note = 'remaining surface construction'},
    {bp = '/services2',    level = 'services', gate = 'dig',   orders = true,
     note = 'well, hospital and dining room'},
    {bp = '/surface5',     level = 'surface',  gate = 'build', orders = true,
     note = 'surface roof and defences'},
    {bp = '/surface6',     level = 'surface',  gate = 'build', orders = true,
     note = 'bridges and beehives'},
    {bp = '/surface7',     level = 'surface',  gate = 'build', orders = true,
     note = 'complete the outer walls'},
    {bp = '/suites2',      level = 'suites',   gate = 'dig',   orders = true,
     note = 'noble suites'},
    {bp = '/apartments2',  level = 'apartments', gate = 'dig', orders = true,
     note = 'apartment beds and doors'},
    {bp = '/services3',    level = 'services', gate = 'build', orders = true,
     note = 'grand dining hall and tavern'},
    {bp = '/guildhall2',   level = 'guildhall', gate = 'dig',  orders = true,
     note = 'guildhalls'},
    {bp = '/apartments3',  level = 'apartments', gate = 'build', orders = true,
     note = 'assign apartments as bedrooms'},
    {bp = '/farming4',     level = 'farming',  gate = 'build', orders = true,
     note = 'seasonal fertilisation (needs a potash stock)'},
    {bp = '/services4',    level = 'services', gate = 'build', orders = true,
     note = 'jail and decorative furniture'},
}

-- Orders libraries worth importing once the fort has the dwarves to use them.
local ORDER_LIBS = {
    -- Imported as soon as the starting workshops exist (step 5 = /surface2),
    -- not deep into the build: it carries the food and plant-processing orders,
    -- and waiting until step 6+ left the fort with nothing brewing.
    {after = 5,  lib = 'library/basic',     note = 'basic production (food/drink)'},
    {after = 12, lib = 'library/furnace',   note = 'furnace products'},
    {after = 18, lib = 'library/smelting',  note = 'metal bars'},
    {after = 18, lib = 'library/rockstock', note = 'stock of rock furniture'},
}

-- ---------------------------------------------------------------- --
-- plan persistence                                                 --
-- ---------------------------------------------------------------- --

local function default_plan()
    return {
        anchor = nil,       -- {x=, y=}
        levels = nil,       -- {surface=, farming=, industry=, ...}
        step = 1,           -- next index into PLAN
        auto = false,
        last_run = 0,
        orders_done = {},
        -- Per-step attempt counts, so a step that quietly does nothing is
        -- retried a bounded number of times rather than skipped on the spot.
        attempts = {},
        -- Steps that were applied but did no work, kept so the dashboard can
        -- say which parts of the fort may be missing.
        warnings = {},
        -- Stall detection: when the current gate was first seen closed, and how
        -- much work was outstanding then. If that number never falls the fort
        -- is not slow, it is stuck.
        gate_since = 0,
        gate_pending = -1,
        stalled = false,
        stall_reason = nil,
    }
end

local function load_plan()
    if antfarm_plan then return antfarm_plan end
    local ok, data = pcall(json.decode_file, PLAN_FILE)
    antfarm_plan = (ok and type(data) == 'table') and data or default_plan()
    antfarm_plan.orders_done = antfarm_plan.orders_done or {}
    -- Fields added after a plan file may have been written; a fort mid-build
    -- must not break because its saved plan predates them.
    antfarm_plan.attempts = antfarm_plan.attempts or {}
    antfarm_plan.warnings = antfarm_plan.warnings or {}
    antfarm_plan.gate_since = antfarm_plan.gate_since or 0
    if antfarm_plan.gate_pending == nil then antfarm_plan.gate_pending = -1 end
    return antfarm_plan
end

local function save_plan()
    if not antfarm_plan then return end
    pcall(json.encode_file, antfarm_plan, PLAN_FILE)
end

-- ---------------------------------------------------------------- --
-- geology survey                                                   --
-- ---------------------------------------------------------------- --

local function tile_at(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return nil end
    return block, block.designation[x % 16][y % 16], block.tiletype[x % 16][y % 16]
end

local function tile_material(x, y, z)
    local block, _, tt = tile_at(x, y, z)
    if not block then return nil end
    return df.tiletype.attrs[tt].material, df.tiletype.attrs[tt].shape
end

local function has_aquifer(x, y, z)
    local _, des = tile_at(x, y, z)
    return des and des.water_table
end

-- Classify one z-level by sampling a column around the anchor: what most of the
-- tiles are made of decides whether this level is soil, rock, or already open.
local WALKABLE = {
    [df.tiletype_shape.FLOOR] = true,
    [df.tiletype_shape.RAMP] = true,
    [df.tiletype_shape.STAIR_UP] = true,
    [df.tiletype_shape.STAIR_DOWN] = true,
    [df.tiletype_shape.STAIR_UPDOWN] = true,
    [df.tiletype_shape.BOULDER] = true,
    [df.tiletype_shape.PEBBLES] = true,
    [df.tiletype_shape.SHRUB] = true,
    [df.tiletype_shape.SAPLING] = true,
}

local function classify_level(cx, cy, z)
    local counts = {solid = 0, open = 0, floor = 0, empty = 0,
                    soil = 0, rock = 0, water = 0, aquifer = 0, total = 0}
    for x = cx - SURVEY_SAMPLE, cx + SURVEY_SAMPLE do
        for y = cy - SURVEY_SAMPLE, cy + SURVEY_SAMPLE do
            local mat, shape = tile_material(x, y, z)
            if mat then
                counts.total = counts.total + 1
                if has_aquifer(x, y, z) then counts.aquifer = counts.aquifer + 1 end
                if mat == df.tiletype_material.MAGMA or mat == df.tiletype_material.POOL
                        or mat == df.tiletype_material.RIVER or mat == df.tiletype_material.BROOK then
                    counts.water = counts.water + 1
                elseif shape == df.tiletype_shape.WALL then
                    counts.solid = counts.solid + 1
                    if mat == df.tiletype_material.SOIL then
                        counts.soil = counts.soil + 1
                    elseif mat == df.tiletype_material.STONE or mat == df.tiletype_material.MINERAL
                            or mat == df.tiletype_material.LAVA_STONE then
                        counts.rock = counts.rock + 1
                    end
                else
                    counts.open = counts.open + 1
                    -- Air and walkable ground are both "not wall", but only one
                    -- of them is a surface a dwarf can stand on.
                    if shape == df.tiletype_shape.EMPTY then
                        counts.empty = counts.empty + 1
                    elseif WALKABLE[shape] then
                        counts.floor = counts.floor + 1
                    end
                end
            end
        end
    end
    return counts
end

-- Walk down from the sky to pick a z-level for each Dreamfort layer:
-- surface (first mostly-solid ground), farming (uppermost soil), then four
-- rock levels for industry, services, guildhall, suites and apartments.
function survey(cx, cy)
    local _, _, mz = dfhack.maps.getTileSize()
    local levels, report = {}, {}

    -- The surface is the level dwarves WALK ON, which is the floor sitting on
    -- top of the ground -- not the first solid level. Picking the first solid
    -- one puts the whole surface fort a z-level inside the dirt, so nothing
    -- connects to where the dwarves actually are.
    local surface_z
    for z = mz - 1, 1, -1 do
        local c = classify_level(cx, cy, z)
        if c.total > 0 and c.floor > c.total * 0.5 and c.water == 0 then
            surface_z = z
            break
        end
    end
    if not surface_z then
        return nil, 'could not find walkable ground under the anchor'
    end
    levels.surface = surface_z
    -- The connecting stairway starts one level UNDER the surface. Store it:
    -- fort_zlevels() and every gate scoped to 'stairs_top' read this key, and
    -- while nothing wrote it those gates silently saw zero pending work.
    levels.stairs_top = surface_z - 1
    table.insert(report, ('surface   z=%d  (walkable ground)'):format(surface_z))

    -- Farming wants soil; it is dug in the uppermost soil layer below grade.
    -- surface_z is walkable, so the first *diggable* level is surface_z - 1.
    local farming_z
    for z = surface_z - 1, math.max(1, surface_z - 30), -1 do
        local c = classify_level(cx, cy, z)
        if c.aquifer == 0 and c.water == 0 and c.soil > c.total * 0.5 then
            farming_z = z
            break
        end
    end
    -- Embarks with no soil column still need somewhere to farm; fall back to
    -- three levels down and let the player move it.
    levels.farming = farming_z or math.max(1, surface_z - 3)
    table.insert(report, ('farming   z=%d%s'):format(levels.farming,
        farming_z and ' (soil)' or ' (no soil layer found -- consider relocating)'))

    -- One rock anchor: the industry level. Everything below it is derived from
    -- Dreamfort's own offsets, so the blueprints land where /dig_all dug.
    local industry_z
    for z = levels.farming - 1, DREAMFORT_DEPTH, -1 do
        local c = classify_level(cx, cy, z)
        -- Must be *rock*, not merely solid: a soil layer passes a solidity test
        -- but Dreamfort's industry level wants stone for furniture and forges.
        if c.aquifer == 0 and c.water == 0 and c.rock > c.total * 0.8 then
            -- Check there is enough clean rock beneath for the whole stack.
            local clear = true
            for dz = 1, DREAMFORT_DEPTH - 1 do
                local below = classify_level(cx, cy, z - dz)
                if below.total == 0 or below.aquifer > 0 or below.water > 0
                        or below.solid < below.total * 0.6 then
                    clear = false
                    break
                end
            end
            if clear then
                industry_z = z
                break
            end
        end
    end
    if not industry_z then
        return nil, ('no rock column with %d clear levels found below the farming level')
            :format(DREAMFORT_DEPTH)
    end

    for name, off in pairs(DREAMFORT_ZOFF) do
        levels[name] = industry_z + off
    end
    table.insert(report, ('industry  z=%d  (services %d, guildhall %d, suites %d, apartments %d..%d)')
        :format(industry_z, levels.services, levels.guildhall, levels.suites,
                levels.apartments, levels.apartments - 4))

    return levels, table.concat(report, '\n  ')
end

-- How much of the Dreamfort footprint is actually usable at the anchor.
local function footprint_quality(cx, cy, z)
    local half = math.floor(FOOTPRINT / 2)
    local ok_tiles, total = 0, 0
    for x = cx - half, cx + half, 3 do
        for y = cy - half, cy + half, 3 do
            local mat, shape = tile_material(x, y, z)
            total = total + 1
            if mat and mat ~= df.tiletype_material.MAGMA and mat ~= df.tiletype_material.POOL
                    and mat ~= df.tiletype_material.RIVER and mat ~= df.tiletype_material.BROOK then
                ok_tiles = ok_tiles + 1
            end
        end
    end
    if total == 0 then return 0 end
    return math.floor(100 * ok_tiles / total)
end

-- ---------------------------------------------------------------- --
-- gates: is the fort ready for the next step?                      --
-- ---------------------------------------------------------------- --

-- Counting designated tiles runs inside DF's event loop, so it has to stay
-- cheap: a 4x4 embark has thousands of blocks on the fort's levels and 256
-- tiles each, which is millions of indexed reads per sweep and a visible hitch.
--
-- Two bounds keep it honest: only the z-levels the fort actually occupies are
-- examined, and counting stops at DIG_COUNT_CAP. The gate only needs to know
-- whether anything is outstanding, so an exact count above the cap is wasted
-- work; the caller renders it as "400+".
local DIG_COUNT_CAP = 400

-- The apartments blueprint repeats down five levels, so gating on the anchor
-- level alone would miss most of its digging.
local function fort_zlevels(levels)
    local zs = {}
    if levels.stairs_top then zs[levels.stairs_top] = true end
    for name, z in pairs(levels) do
        zs[z] = true
        if name == 'apartments' then
            for dz = 1, 4 do zs[z - dz] = true end
        end
    end
    return zs
end

-- `only` optionally restricts the scan to named levels (e.g. {'surface'}).
function count_pending_digs(levels, only)
    if not levels then return 0 end
    local n = 0
    local scope = levels
    if only then
        scope = {}
        for _, name in ipairs(only) do
            if levels[name] then scope[name] = levels[name] end
        end
    end
    local zs = fort_zlevels(scope)
    -- AGENTS.md 6.1.4: DF vectors are 0-indexed. ipairs() starts at 1, so the
    -- first map block was never examined -- 256 tiles that could hold the last
    -- outstanding designation and hold a gate open forever.
    local blocks = df.global.world.map.map_blocks
    for i = 0, #blocks - 1 do
        local block = blocks[i]
        if block and zs[block.map_pos.z] then
            local des = block.designation
            for bx = 0, 15 do
                local col = des[bx]
                for by = 0, 15 do
                    if col[by].dig ~= df.tile_dig_designation.No then
                        n = n + 1
                        if n >= DIG_COUNT_CAP then return n, true end
                    end
                end
            end
        end
    end
    return n, false
end

-- Renders a possibly-capped count for display.
local function dig_count_text(n, capped)
    if capped then return ('%d+'):format(n) end
    return tostring(n)
end

-- `zs` optionally restricts the count to a set of z-levels. Counting
-- construction jobs fort-wide is the same mistake as gating a dig step on the
-- whole excavation: /farming3 would wait behind a mason still working on the
-- surface, on a level it does not care about.
function count_pending_builds(zs)
    local n = 0
    -- utils.listpairs is the supported way to walk DF's intrusive job list.
    for _, job in utils.listpairs(df.global.world.job_list) do
        if job and (job.job_type == df.job_type.ConstructBuilding
                or job.job_type == df.job_type.DestroyBuilding) then
            if not zs then
                n = n + 1
            else
                local ok, z = pcall(function() return job.pos.z end)
                if not ok or z == nil or zs[z] then n = n + 1 end
            end
        end
    end
    return n
end

local function gate_open(step, plan)
    if step.gate == 'none' then return true, 'ready', 0 end
    -- Default the scope to the step's own level; that is what "run when the X
    -- level has been dug out" means.
    local scope = step.gate_levels or {step.level}
    local scope_name = table.concat(scope, '+')

    if step.gate == 'dig' then
        local pending, capped = count_pending_digs(plan.levels, scope)
        if pending > 0 then
            return false, ('waiting on %s dig designation(s) on %s')
                :format(dig_count_text(pending, capped), scope_name), pending
        end
        return true, scope_name .. ' digging complete', 0
    end
    if step.gate == 'build' then
        local digs, capped = count_pending_digs(plan.levels, scope)
        if digs > 0 then
            return false, ('waiting on %s dig designation(s) on %s')
                :format(dig_count_text(digs, capped), scope_name), digs
        end
        local builds = count_pending_builds(fort_zlevels(
            (function()
                local sc = {}
                for _, name in ipairs(scope) do
                    if plan.levels[name] then sc[name] = plan.levels[name] end
                end
                return sc
            end)()))
        if builds > 0 then
            return false, ('waiting on %d construction job(s) on %s')
                :format(builds, scope_name), builds
        end
        return true, 'construction complete', 0
    end
    return true, 'ready', 0
end

-- ---------------------------------------------------------------- --
-- running steps                                                    --
-- ---------------------------------------------------------------- --

local function cursor_arg(plan, level)
    if not plan.levels then return nil end
    local z = plan.levels[level]
    -- Synthetic anchor: the connecting stairs start one level under the SURFACE.
    -- Anchoring at farming-1 left z-levels between the surface and the farming
    -- level with no stairway at all -- /surface1 digs the surface, /dig_all digs
    -- from industry down, and nothing joined them, so the fort was unreachable.
    if level == 'stairs_top' then z = plan.levels.surface - 1 end
    if not z then return nil end
    return ('%d,%d,%d'):format(plan.anchor.x, plan.anchor.y, z)
end

-- Stat labels quickfort prints for work it did NOT do. Everything else counts
-- as progress. Matched as substrings because the dig labels are built with a
-- prefix ("Tiles designated for digging" / "Tiles marked for digging").
local NON_PROGRESS = {
    'outside map boundary',
    'Invalid key sequences',
    'could not be designated',
    'missing buildings',
    'skipped',
}

local function is_progress(label)
    for _, bad in ipairs(NON_PROGRESS) do
        if label:find(bad, 1, true) then return false end
    end
    return true
end

-- Run one quickfort command and find out what it actually did.
--
-- `dfhack.run_command` only reports Lua errors through pcall; quickfort
-- returning "0 tiles affected" because the cursor was out of bounds, or the
-- blueprint matched nothing, looks exactly like success. That is how build
-- steps were being marked complete without ever running (report finding F-05).
-- run_command_silent hands us the output, which quickfort ends with
-- "<command> successfully completed" and a line per statistic.
local function run_quickfort(verb, bp, cursor, repeat_arg)
    local cmd = ('quickfort %s %s -n %s --cursor %s'):format(verb, DREAMFORT, bp, cursor)
    if repeat_arg then cmd = cmd .. ' --repeat ' .. repeat_arg end
    print('  > ' .. cmd)

    local ok, output, status = pcall(dfhack.run_command_silent, cmd)
    if not ok then
        dfhack.printerr('antfarm_blueprint: ' .. tostring(output))
        return {ok = false, reason = tostring(output), effective = 0}
    end
    output = output or ''
    if status ~= nil and status ~= CR_OK then
        dfhack.printerr(('antfarm_blueprint: %s returned %s'):format(cmd, tostring(status)))
        return {ok = false, reason = 'quickfort reported failure', effective = 0,
                output = output}
    end

    local completed = output:find('successfully completed', 1, true) ~= nil
    local effective, wasted = 0, 0
    for label, value in output:gmatch('\n%s+([^:\n]+):%s*(%d+)') do
        local n = tonumber(value) or 0
        if is_progress(label) then effective = effective + n else wasted = wasted + n end
    end

    for line in output:gmatch('[^\n]+') do
        if line:find('^%s*%*') or line:lower():find('error') then print('  ' .. line) end
    end

    if not completed then
        return {ok = false, reason = 'quickfort did not report completion',
                effective = effective, output = output}
    end
    return {ok = true, effective = effective, wasted = wasted, output = output}
end

-- The game must actually be on the map before quickfort touches anything.
-- Ported from df-ai ai.cpp is_dwarfmode_viewscreen(): applying a blueprint
-- while a menu is open sends its keystrokes into that menu.
local function game_is_drivable()
    local ok, ui = pcall(reqscript, 'antfarm_ui')
    if ok and ui and ui.is_dwarfmode then
        local ok2, drivable = pcall(ui.is_dwarfmode)
        if ok2 then return drivable end
    end
    -- antfarm_ui unavailable: fall back to the map check alone.
    return dfhack.isMapLoaded()
end

local function record_warning(plan, step, index, text)
    table.insert(plan.warnings, {step = index, bp = step.bp, note = text})
    while #plan.warnings > 12 do table.remove(plan.warnings, 1) end
    dfhack.printerr(('antfarm_blueprint: step %d (%s) %s'):format(index, step.bp, text))
end

function apply_step(index, force)
    local plan = load_plan()
    local step = PLAN[index]
    if not step then
        print('antfarm_blueprint: the checklist is complete.')
        return false
    end
    if not plan.anchor or not plan.levels then
        dfhack.printerr('antfarm_blueprint: no anchor set. Put the cursor where the '
            .. 'central stairs should go and run: antfarm_blueprint here'
            .. '  (or: antfarm_blueprint autostart)')
        return false
    end

    if not game_is_drivable() then
        print('antfarm_blueprint: the game is not on the map right now '
              .. '(menu, popup or pause screen); holding step ' .. index .. '.')
        return false
    end

    local open, why = gate_open(step, plan)
    if not open and not force then
        print(('antfarm_blueprint: step %d (%s) held -- %s'):format(index, step.bp, why))
        return false
    end

    local cursor = cursor_arg(plan, step.level)
    if not cursor then
        dfhack.printerr('antfarm_blueprint: no z-level surveyed for ' .. step.level)
        return false
    end

    print(('antfarm_blueprint: step %d/%d  %s (%s level) -- %s')
        :format(index, #PLAN, step.bp, step.level, step.note))

    -- /central_stairs lays two levels per application; repeat it from just
    -- below the surface all the way down to the industry level so every level
    -- in between is joined. Overlapping the farming level's own stairs is
    -- harmless -- it is the same designation on the same tile.
    local repeat_arg
    if step.repeat_down then
        local span = (plan.levels.surface - 1) - plan.levels.industry + 1
        repeat_arg = 'down,' .. math.max(1, math.ceil(span / 2))
    end

    if step.orders then
        run_quickfort('orders', step.bp, cursor, repeat_arg)
    end
    local result = run_quickfort('run', step.bp, cursor, repeat_arg)

    if not result.ok then
        -- A hard failure never advances the checklist: the fort would be
        -- missing whatever this step builds and nothing would say so.
        record_warning(plan, step, index, 'failed -- ' .. tostring(result.reason))
        plan.last_run = os.time()
        save_plan()
        return false
    end

    local attempts = (plan.attempts[tostring(index)] or 0) + 1
    plan.attempts[tostring(index)] = attempts

    if result.effective == 0 and not force then
        if attempts < MAX_STEP_ATTEMPTS then
            -- Quickfort said "successfully completed" and touched nothing. The
            -- usual causes are transient (the level is not dug yet, materials
            -- are missing), so hold the step and try again next cycle.
            plan.last_run = os.time()
            save_plan()
            print(('antfarm_blueprint: step %d (%s) affected 0 tiles; '
                   .. 'retrying (attempt %d/%d)')
                  :format(index, step.bp, attempts, MAX_STEP_ATTEMPTS))
            return false
        end
        -- Out of retries. Move on rather than wedging the whole build, but
        -- record it loudly: something this step should have built is missing.
        record_warning(plan, step, index,
            ('affected 0 tiles after %d attempts; moving on -- whatever it '
             .. 'builds is NOT there'):format(attempts))
    end

    plan.step = index + 1
    plan.last_run = os.time()
    plan.gate_since = 0
    plan.gate_pending = -1
    plan.stalled = false
    plan.stall_reason = nil
    save_plan()

    -- Import an orders library once the fort is far enough along to use it.
    for _, ol in ipairs(ORDER_LIBS) do
        if plan.step > ol.after and not plan.orders_done[ol.lib] then
            plan.orders_done[ol.lib] = true
            print('  > orders import ' .. ol.lib .. '  (' .. ol.note .. ')')
            pcall(dfhack.run_command, 'orders import ' .. ol.lib)
        end
    end
    save_plan()

    -- Freshly placed workshops are worthless until someone builds them.
    pcall(dfhack.run_command, 'prioritize ConstructBuilding')
    return true
end

-- ---------------------------------------------------------------- --
-- picking a site without a human                                    --
-- ---------------------------------------------------------------- --
-- The guided build used to require someone to place the cursor and type
-- `antfarm_blueprint here`. Nothing ever did, so on an unattended stream the
-- checklist sat at "not anchored" forever and the fort never got built. This
-- picks a site the way a player would: start where the dwarves actually are,
-- try a few offsets around them, and take the best one the survey accepts.

-- Where the fortress currently lives: the average position of its citizens,
-- which on a fresh embark is the wagon.
local function citizen_centroid()
    local n, sx, sy = 0, 0, 0
    local ok = pcall(function()
        local active = df.global.world.units.active
        for i = 0, #active - 1 do
            local u = active[i]
            local is_cit = select(2, pcall(dfhack.units.isCitizen, u))
            local alive = select(2, pcall(dfhack.units.isActive, u))
            if is_cit and alive then
                n = n + 1
                sx = sx + u.pos.x
                sy = sy + u.pos.y
            end
        end
    end)
    if not ok or n == 0 then return nil end
    return math.floor(sx / n), math.floor(sy / n)
end

-- Candidate anchors: the centroid first, then a ring at one footprint out, so
-- a site rejected for water or shallow rock has somewhere to move to.
local function candidate_anchors(cx, cy)
    local mx, my = dfhack.maps.getTileSize()
    local half = math.floor(FOOTPRINT / 2) + 2
    local out = {{x = cx, y = cy}}
    local step = FOOTPRINT
    for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}) do
        table.insert(out, {x = cx + d[1] * step, y = cy + d[2] * step})
    end
    -- Drop anything whose footprint would hang off the map.
    local keep = {}
    for _, c in ipairs(out) do
        if c.x - half >= 1 and c.y - half >= 1 and c.x + half < mx - 1 and c.y + half < my - 1 then
            table.insert(keep, c)
        end
    end
    return keep
end

-- Survey every candidate and score it. Returns the best {x, y, levels, report,
-- quality, score} or nil plus the reasons each candidate was rejected.
function best_anchor(cx, cy, min_quality)
    min_quality = min_quality or 70
    local rejected = {}
    local best
    for _, c in ipairs(candidate_anchors(cx, cy)) do
        local levels, report = survey(c.x, c.y)
        if not levels then
            table.insert(rejected, ('%d,%d: %s'):format(c.x, c.y, tostring(report)))
        else
            local quality = footprint_quality(c.x, c.y, levels.surface)
            -- Prefer a usable footprint, then staying near the dwarves: a
            -- perfect site half the map away means a long haul for every item
            -- the fort starts with.
            local dist = math.abs(c.x - cx) + math.abs(c.y - cy)
            local score = quality - dist * 0.05
            if quality < min_quality then
                table.insert(rejected, ('%d,%d: footprint only %d%% usable')
                    :format(c.x, c.y, quality))
            elseif not best or score > best.score then
                best = {x = c.x, y = c.y, levels = levels, report = report,
                        quality = quality, score = score}
            end
        end
    end
    return best, rejected
end

-- Anchor the fort somewhere sensible and start building. Idempotent: calling it
-- on a fort that is already anchored just makes sure auto mode is running.
function autostart(min_quality)
    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_blueprint: no fortress map loaded')
        return false
    end
    local plan = load_plan()
    if plan.anchor and plan.levels then
        if not plan.auto then set_auto(true) end
        print(('antfarm_blueprint: already anchored at %d,%d (step %d/%d); auto is on.')
            :format(plan.anchor.x, plan.anchor.y, plan.step, #PLAN))
        return true
    end

    local cx, cy = citizen_centroid()
    if not cx then
        local mx, my = dfhack.maps.getTileSize()
        cx, cy = math.floor(mx / 2), math.floor(my / 2)
        print('antfarm_blueprint: no citizens found; searching from the map centre.')
    else
        print(('antfarm_blueprint: searching for a site around the dwarves at %d,%d')
            :format(cx, cy))
    end

    local best, rejected = best_anchor(cx, cy, min_quality)
    if not best then
        dfhack.printerr('antfarm_blueprint: no usable site found near the dwarves.')
        for _, r in ipairs(rejected) do dfhack.printerr('  rejected ' .. r) end
        dfhack.printerr('  Place the cursor somewhere better and run: antfarm_blueprint here')
        return false
    end

    plan.anchor = {x = best.x, y = best.y}
    plan.levels = best.levels
    plan.step = 1
    plan.orders_done = {}
    plan.attempts = {}
    plan.warnings = {}
    plan.gate_since = 0
    plan.gate_pending = -1
    plan.stalled = false
    save_plan()

    print(('antfarm_blueprint: anchored at %d,%d  (footprint %d%% usable)')
        :format(best.x, best.y, best.quality))
    print('  ' .. best.report)
    set_auto(true)
    return true
end

-- ---------------------------------------------------------------- --
-- getting unstuck                                                   --
-- ---------------------------------------------------------------- --
-- "Digging designation cancelled: damp stone located" repeats forever: the
-- designation stays, the miner refuses it, and the gate never clears. df-ai
-- treats DIG_CANCEL_DAMP as a pause to be dismissed; that stops the popups but
-- not the stall. Removing the designations that touch water is the actual fix.

local function tile_is_wet(x, y, z)
    local block, des, tt = tile_at(x, y, z)
    if not block then return false end
    if des.water_table then return true end
    if des.flow_size and des.flow_size > 0 then return true end
    local mat = df.tiletype.attrs[tt].material
    return mat == df.tiletype_material.MAGMA or mat == df.tiletype_material.POOL
        or mat == df.tiletype_material.RIVER or mat == df.tiletype_material.BROOK
end

-- Undesignate dig orders on tiles next to water (in any of the 6 directions).
-- Returns how many were cleared.
function unstick(levels)
    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_blueprint: no fortress map loaded')
        return 0
    end
    local plan = load_plan()
    levels = levels or plan.levels
    if not levels then
        dfhack.printerr('antfarm_blueprint: no surveyed levels; nothing to sweep.')
        return 0
    end
    local zs = fort_zlevels(levels)
    local cleared, looked = 0, 0
    local blocks = df.global.world.map.map_blocks
    for i = 0, #blocks - 1 do
        local block = blocks[i]
        if block and zs[block.map_pos.z] then
            for bx = 0, 15 do
                for by = 0, 15 do
                    local des = block.designation[bx][by]
                    if des.dig ~= df.tile_dig_designation.No then
                        looked = looked + 1
                        if looked > UNSTICK_CAP then
                            print(('antfarm_blueprint: unstick stopped at %d tiles examined '
                                   .. '(cap); run it again to continue.'):format(UNSTICK_CAP))
                            return cleared
                        end
                        local x = block.map_pos.x + bx
                        local y = block.map_pos.y + by
                        local z = block.map_pos.z
                        local wet = false
                        for _, d in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
                            if tile_is_wet(x + d[1], y + d[2], z + d[3]) then wet = true; break end
                        end
                        if wet then
                            des.dig = df.tile_dig_designation.No
                            block.flags.designated = true
                            cleared = cleared + 1
                        end
                    end
                end
            end
        end
    end
    if cleared > 0 then
        print(('antfarm_blueprint: cleared %d dig designation(s) touching water.')
            :format(cleared))
    end
    return cleared
end

-- Try to get a held gate moving again. Cheap remediations first.
local function remediate(plan, reason)
    print('antfarm_blueprint: build stalled -- ' .. tostring(reason))
    -- Suspended constructions are the commonest cause and the cheapest fix.
    pcall(dfhack.run_command, 'unsuspend')
    pcall(dfhack.run_command, 'prioritize -a Dig CarveFortification DetailWall '
                              .. 'ConstructBuilding DestroyBuilding')
    local cleared = unstick(plan.levels)
    if cleared > 0 then
        return ('cleared %d damp designation(s)'):format(cleared)
    end
    return 'unsuspended constructions and re-prioritised digging'
end

-- ---------------------------------------------------------------- --
-- auto mode                                                        --
-- ---------------------------------------------------------------- --

local MIN_STEP_INTERVAL = 60   -- seconds; gives jobs a chance to be picked up
local AUTO_POLL_SEC = 10
local AUTO_FRAMES = 30         -- see antfarm_server: 'frames' is the only unit
                               -- that keeps running while the game is paused
local auto_timer
local auto_last = 0

local function wall_sec()
    local ok, ms = pcall(dfhack.getTickCount)
    if ok and ms then return ms / 1000 end
    return os.time()
end

-- A gate that is merely slow has a pending count that keeps falling. One that
-- is stuck -- unreachable designations, damp stone, suspended constructions --
-- sits on the same number forever, and the fort quietly stops building. Notice
-- that, try the cheap fixes, and record it where the dashboard can see it.
local function track_stall(plan, why, pending)
    local now = os.time()
    pending = pending or -1
    if plan.gate_since == 0 or plan.gate_pending < 0 or pending < plan.gate_pending then
        plan.gate_since = now
        plan.gate_pending = pending
        plan.stalled = false
        plan.stall_reason = nil
        save_plan()
        return
    end
    if now - plan.gate_since < STALL_SEC then return end

    plan.stalled = true
    local did = remediate(plan, why)
    plan.stall_reason = ('%s -- no progress for %dm; %s')
        :format(why, math.floor((now - plan.gate_since) / 60), did)
    -- Give the remediation a full stall window to take effect before trying
    -- anything else, so this does not fire every poll.
    plan.gate_since = now
    save_plan()
end

local function auto_tick()
    local plan = load_plan()
    if not plan.auto then
        -- Drop the handle as the chain ends, or set_auto's `if not auto_timer`
        -- guard sees a stale one and never restarts the loop.
        auto_timer = nil
        return
    end

    -- Called every AUTO_FRAMES; only does work every AUTO_POLL_SEC of real time,
    -- so the cadence holds whatever the frame rate is doing.
    local now = wall_sec()
    if now - auto_last >= AUTO_POLL_SEC then
        auto_last = now
        if dfhack.isMapLoaded() and plan.anchor and plan.step <= #PLAN then
            if os.time() - (plan.last_run or 0) >= MIN_STEP_INTERVAL then
                local step = PLAN[plan.step]
                local open, why, pending = gate_open(step, plan)
                if open then
                    plan.gate_since = 0
                    plan.gate_pending = -1
                    plan.stalled = false
                    plan.stall_reason = nil
                    apply_step(plan.step, false)
                else
                    track_stall(plan, why, pending)
                end
            end
        end
    end

    auto_timer = dfhack.timeout(AUTO_FRAMES, 'frames', auto_tick)
end

function set_auto(on)
    local plan = load_plan()
    plan.auto = on and true or false
    save_plan()
    if plan.auto then
        if not auto_timer then auto_tick() end
        print('antfarm_blueprint: auto mode ON -- steps apply as their gates clear.')
    else
        print('antfarm_blueprint: auto mode OFF.')
    end
end

-- Published into the Antfarm state file so the dashboard and chat can report
-- build progress without re-deriving any of this.
function progress()
    local plan = load_plan()
    local step = PLAN[plan.step]
    local out = {
        step = plan.step,
        total = #PLAN,
        auto = plan.auto and true or false,
        anchored = plan.anchor ~= nil,
        label = step and step.bp or 'complete',
        note = step and step.note or 'the checklist is finished',
    }
    out.stalled = plan.stalled and true or false
    out.stall_reason = plan.stall_reason or ''
    out.attempts = plan.attempts[tostring(plan.step)] or 0
    -- The steps that ran but built nothing. This is the difference between a
    -- fort that is behind schedule and one that is missing its still.
    local warns = {}
    for _, w in ipairs(plan.warnings) do
        table.insert(warns, ('%d %s: %s'):format(w.step, w.bp, w.note))
    end
    out.warnings = warns
    if plan.anchor then
        out.anchor = ('%d,%d'):format(plan.anchor.x, plan.anchor.y)
    end
    if plan.anchor and dfhack.isMapLoaded() then
        local open, why = true, 'done'
        if step then open, why = gate_open(step, plan) end
        out.ready = open and true or false
        out.status = why
    else
        out.ready = false
        out.status = plan.anchor and 'no map' or 'not anchored'
    end
    return out
end

-- ---------------------------------------------------------------- --
-- the standalone digger (works on any embark, no Dreamfort needed)  --
-- ---------------------------------------------------------------- --

local simple_stats

local function simple_designate(x, y, z, kind)
    local mx, my, mz = dfhack.maps.getTileSize()
    if x < 1 or y < 1 or z < 0 or x >= mx - 1 or y >= my - 1 or z >= mz then return false end
    local block, des, tt = tile_at(x, y, z)
    if not block then return false end
    if des.water_table then simple_stats.aquifer = simple_stats.aquifer + 1; return false end
    if des.flow_size and des.flow_size > 0 then simple_stats.liquid = simple_stats.liquid + 1; return false end

    local attrs = df.tiletype.attrs[tt]
    local mat = attrs.material
    if mat == df.tiletype_material.MAGMA or mat == df.tiletype_material.POOL
            or mat == df.tiletype_material.RIVER or mat == df.tiletype_material.BROOK then
        simple_stats.liquid = simple_stats.liquid + 1
        return false
    end
    if attrs.shape ~= df.tiletype_shape.WALL then
        simple_stats.open = simple_stats.open + 1
        return false
    end
    if des.dig ~= df.tile_dig_designation.No then
        simple_stats.already = simple_stats.already + 1
        return false
    end

    des.dig = kind or df.tile_dig_designation.Default
    block.flags.designated = true
    simple_stats.dug = simple_stats.dug + 1
    return true
end

local function simple_rect(x1, y1, x2, y2, z)
    for x = math.min(x1, x2), math.max(x1, x2) do
        for y = math.min(y1, y2), math.max(y1, y2) do
            simple_designate(x, y, z)
        end
    end
end

function simple(depth)
    depth = depth or 4
    simple_stats = {dug = 0, open = 0, aquifer = 0, liquid = 0, already = 0}

    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_blueprint: no fortress map loaded')
        return
    end

    local mx, my = dfhack.maps.getTileSize()
    local cx, cy, z_top
    local cursor = df.global.cursor
    if cursor and cursor.x and cursor.x >= 0 then
        cx, cy, z_top = cursor.x, cursor.y, cursor.z
    else
        cx, cy = math.floor(mx / 2), math.floor(my / 2)
        z_top = df.global.window_z
    end
    local z_bottom = math.max(0, z_top - depth)

    -- Levels connect only when the upper tile has a DOWN component and the
    -- lower tile has an UP component. Capping the shaft with a bare DownStair
    -- leaves the bottom level -- where every room below is dug -- unreachable.
    for z = z_top, z_bottom + 1, -1 do
        simple_designate(cx, cy, z, df.tile_dig_designation.UpDownStair)
    end
    simple_designate(cx, cy, z_bottom, df.tile_dig_designation.UpStair)

    -- Trunk corridor, meeting hall, stockpile bay, workshops, bedroom rows.
    simple_rect(cx - 18, cy - 1, cx + 18, cy + 1, z_bottom)
    simple_rect(cx - 29, cy - 4, cx - 18, cy + 4, z_bottom)
    simple_rect(cx + 18, cy - 4, cx + 29, cy + 4, z_bottom)
    for i = 0, 1 do
        local wx = cx + 4 + i * 9
        simple_rect(wx, cy - 7, wx + 7, cy - 2, z_bottom)
    end
    for row = 0, 3 do
        local by = cy + 3 + row * 3
        simple_rect(cx - 18, by, cx + 18, by, z_bottom)
        simple_rect(cx - 1, cy + 2, cx + 1, by, z_bottom)
        for slot = -4, 4 do
            if slot ~= 0 then simple_rect(cx + slot * 3, by + 1, cx + slot * 3 + 1, by + 1, z_bottom) end
        end
    end

    print(('antfarm_blueprint simple: %d tiles designated at %d,%d (z%d..%d)')
        :format(simple_stats.dug, cx, cy, z_bottom, z_top))
    print(('  skipped: %d open, %d aquifer, %d liquid, %d already designated')
        :format(simple_stats.open, simple_stats.aquifer, simple_stats.liquid, simple_stats.already))
end

-- ---------------------------------------------------------------- --
-- commands                                                         --
-- ---------------------------------------------------------------- --

local function cmd_here()
    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_blueprint: no fortress map loaded')
        return
    end
    local cursor = df.global.cursor
    local cx, cy
    if cursor and cursor.x and cursor.x >= 0 then
        cx, cy = cursor.x, cursor.y
    else
        local mx, my = dfhack.maps.getTileSize()
        cx, cy = math.floor(mx / 2), math.floor(my / 2)
        print('antfarm_blueprint: no cursor, anchoring at the map centre.')
    end

    local levels, report = survey(cx, cy)
    if not levels then
        dfhack.printerr('antfarm_blueprint: survey failed -- ' .. tostring(report))
        return
    end

    local plan = load_plan()
    plan.anchor = {x = cx, y = cy}
    plan.levels = levels
    plan.step = 1
    plan.orders_done = {}
    save_plan()

    local quality = footprint_quality(cx, cy, levels.surface)
    print(('antfarm_blueprint: anchored at %d,%d'):format(cx, cy))
    print('  ' .. report)
    print(('  surface footprint usable: %d%%'):format(quality))
    if quality < 85 then
        print('  WARNING: Dreamfort wants a large flat area. Water or cliffs here')
        print('           will make the surface fort awkward; consider re-anchoring.')
    end
    print('Next: antfarm_blueprint next   (or: antfarm_blueprint auto on)')
end

local function cmd_status()
    local plan = load_plan()
    if not plan.anchor then
        print('antfarm_blueprint: not anchored. Place the cursor and run: antfarm_blueprint here')
        return
    end
    print(('antfarm_blueprint: anchor %d,%d   step %d/%d   auto %s')
        :format(plan.anchor.x, plan.anchor.y, plan.step, #PLAN, plan.auto and 'ON' or 'off'))
    if plan.levels then
        local names = {}
        for name, z in pairs(plan.levels) do table.insert(names, ('%s=%d'):format(name, z)) end
        table.sort(names)
        print('  levels: ' .. table.concat(names, '  '))
    end
    local step = PLAN[plan.step]
    if not step then
        print('  the checklist is complete.')
        return
    end
    local open, why = gate_open(step, plan)
    print(('  next:   %s (%s) -- %s'):format(step.bp, step.level, step.note))
    print(('  gate:   %s -- %s'):format(open and 'OPEN' or 'HELD', why))
    if plan.stalled then
        print('  STALLED: ' .. tostring(plan.stall_reason))
        print('           try: antfarm_blueprint unstick   or   antfarm_blueprint next --force')
    end
    local attempts = plan.attempts[tostring(plan.step)] or 0
    if attempts > 0 then
        print(('  retries: %d/%d on this step'):format(attempts, MAX_STEP_ATTEMPTS))
    end
    if #plan.warnings > 0 then
        print('  warnings (steps that ran but built nothing):')
        for _, w in ipairs(plan.warnings) do
            print(('    step %d %s: %s'):format(w.step, w.bp, w.note))
        end
    end
end

local function cmd_list()
    local plan = load_plan()
    for i, step in ipairs(PLAN) do
        local mark = i < plan.step and 'x' or (i == plan.step and '>' or ' ')
        print(('  [%s] %2d. %-14s %-11s %-6s %s')
            :format(mark, i, step.bp, step.level, step.gate, step.note))
    end
end

local function cmd_orders()
    local plan = load_plan()
    local step = PLAN[plan.step]
    if not step or not plan.anchor then
        print('antfarm_blueprint: nothing to order.')
        return
    end
    local cursor = cursor_arg(plan, step.level)
    if cursor then run_quickfort('orders', step.bp, cursor) end
end

-- Auto mode has the same reload problem as the bridge: `antfarm_plan.auto`
-- persists (it is on disk) but the pending timeout does not survive a world
-- unload, so after a save-and-reload the plan claimed auto was on while nothing
-- was driving it. Re-arm on map load, and drop the stale handle on unload.
dfhack.onStateChange.antfarm_blueprint = function(code)
    if code == SC_MAP_UNLOADED or code == SC_WORLD_UNLOADED then
        auto_timer = nil
        antfarm_plan = nil       -- force a re-read of the plan file next time
    elseif code == SC_MAP_LOADED then
        local plan = load_plan()
        if plan.auto and not auto_timer then
            auto_last = 0
            auto_tick()
            print('antfarm_blueprint: auto mode resumed after load.')
        end
    end
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'here' or verb == 'anchor' then
    cmd_here()
elseif verb == 'survey' then
    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_blueprint: no fortress map loaded')
    else
        local cursor = df.global.cursor
        local mx, my = dfhack.maps.getTileSize()
        local cx = (cursor and cursor.x and cursor.x >= 0) and cursor.x or math.floor(mx / 2)
        local cy = (cursor and cursor.y and cursor.y >= 0) and cursor.y or math.floor(my / 2)
        local levels, report = survey(cx, cy)
        if levels then
            print(('antfarm_blueprint survey at %d,%d:'):format(cx, cy))
            print('  ' .. report)
            print(('  surface footprint usable: %d%%'):format(footprint_quality(cx, cy, levels.surface)))
        else
            dfhack.printerr('survey failed -- ' .. tostring(report))
        end
    end
elseif verb == 'status' then
    cmd_status()
elseif verb == 'list' then
    cmd_list()
elseif verb == 'next' then
    local force = args[2] == '--force' or args[2] == '-f'
    local plan = load_plan()
    apply_step(plan.step, force)
elseif verb == 'autostart' then
    local q
    for i = 2, #args do
        if (args[i] == '-q' or args[i] == '--min-quality') and args[i + 1] then
            q = tonumber(args[i + 1])
        end
    end
    autostart(q)
elseif verb == 'unstick' then
    local n = unstick()
    if n == 0 then print('antfarm_blueprint: no designations were touching water.') end
elseif verb == 'auto' then
    -- Strict on/off. `auto foo` used to silently enable auto mode because the
    -- test was `args[2] ~= 'off'`, so any typo turned the build loose.
    local arg = (args[2] or ''):lower()
    if arg == 'on' then
        set_auto(true)
    elseif arg == 'off' then
        set_auto(false)
    else
        local plan = load_plan()
        print(('antfarm_blueprint: auto is %s. Usage: antfarm_blueprint auto on|off')
            :format(plan.auto and 'ON' or 'off'))
    end
elseif verb == 'orders' then
    cmd_orders()
elseif verb == 'reset' then
    antfarm_plan = default_plan()
    save_plan()
    print('antfarm_blueprint: progress reset (existing designations are untouched).')
elseif verb == 'simple' then
    local depth = 4
    for i = 2, #args do
        if (args[i] == '-d' or args[i] == '--depth') and args[i + 1] then
            depth = tonumber(args[i + 1]) or 4
        end
    end
    simple(depth)
else
    print(dfhack.script_help and dfhack.script_help() or
        'usage: antfarm_blueprint survey|here|autostart|status|list|next|auto|orders|'
        .. 'unstick|reset|simple')
end
