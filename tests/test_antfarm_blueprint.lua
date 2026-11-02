-- Tests for antfarm_blueprint.lua: the guided Dreamfort build.
--
-- Run: lua tests/test_antfarm_blueprint.lua   (from the repository root)

local stub = dofile('tests/df_stub.lua')
local BP = 'game/hack/scripts/antfarm_blueprint.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1; print('  ok    ' .. name); return end
    fail = fail + 1
    print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
end

local function fresh()
    local w = stub.new()
    w.center_x, w.center_y = 96, 96
    local env = stub.load(w, BP)
    return w, env
end

-- Build a column the survey should accept: air above, walkable ground, soil,
-- then deep clean rock. Mirrors the layout in AGENTS.md 6.4.
local function good_column(w, cx, cy)
    local M, S = w.df.tiletype_material, w.df.tiletype_shape
    local half = 10
    local function fill(z, mat, shape, opts)
        for x = cx - half, cx + half do
            for y = cy - half, cy + half do
                w.set_tile(x, y, z, mat, shape, opts)
            end
        end
    end
    for z = 42, 50 do fill(z, M.AIR, S.EMPTY) end
    fill(41, M.SOIL, S.FLOOR)                 -- the surface: where dwarves stand
    fill(40, M.SOIL, S.WALL)                  -- farming: soil
    for z = 39, 20, -1 do fill(z, M.STONE, S.WALL) end  -- deep clean rock
    return 41, 40, 39
end

print('antfarm_blueprint')

-- ---------------------------------------------------------------- --
-- geology survey                                                    --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    good_column(w, 96, 96)
    local levels, report = env.survey(96, 96)
    check('survey finds a site in a clean column', levels ~= nil, report)
    if levels then
        check('the surface is the walkable level, not the first solid one',
              levels.surface == 41, tostring(levels.surface))
        check('farming lands on the soil layer', levels.farming == 40,
              tostring(levels.farming))
        check('industry lands on rock', levels.industry == 39, tostring(levels.industry))
        -- Report finding D-04: fort_zlevels reads levels.stairs_top, which
        -- nothing used to write, so a stairs-gated step saw zero pending work.
        check('stairs_top is stored, not just computed on the fly',
              levels.stairs_top == 40, tostring(levels.stairs_top))
        check('the derived levels follow Dreamfort offsets',
              levels.services == 38 and levels.guildhall == 34
              and levels.suites == 33 and levels.apartments == 32,
              ('services=%s guildhall=%s suites=%s apartments=%s'):format(
                  levels.services, levels.guildhall, levels.suites, levels.apartments))
    end
end

do
    local w, env = fresh()
    local M, S = w.df.tiletype_material, w.df.tiletype_shape
    for z = 42, 50 do w.fill_level(z, M.AIR, S.EMPTY, 10) end
    w.fill_level(41, M.SOIL, S.FLOOR, 10)
    w.fill_level(40, M.SOIL, S.WALL, 10, {water_table = true})
    for z = 39, 20, -1 do w.fill_level(z, M.STONE, S.WALL, 10, {water_table = true}) end
    local levels, report = env.survey(96, 96)
    check('an aquifer column is refused rather than anchored', levels == nil, report)
end

-- ---------------------------------------------------------------- --
-- counting outstanding work                                         --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local levels = {surface = 41, farming = 40, industry = 39}
    -- Put the only designation in the very first map block. ipairs() on a DF
    -- vector starts at index 1, so this tile used to be invisible to the gate
    -- and the gate stayed open with work outstanding (AGENTS.md 6.1.4).
    w.designate(0, 0, 40)
    local n = env.count_pending_digs(levels)
    check('a designation in the first map block is counted', n == 1, tostring(n))
end

do
    local w, env = fresh()
    local levels = {surface = 41, farming = 40, industry = 39}
    w.designate(50, 50, 41)
    w.designate(60, 60, 40)
    check('scoping to one level ignores the others',
          env.count_pending_digs(levels, {'surface'}) == 1,
          tostring(env.count_pending_digs(levels, {'surface'})))
    check('the unscoped count sees both', env.count_pending_digs(levels) == 2,
          tostring(env.count_pending_digs(levels)))
end

do
    local w, env = fresh()
    w.job_list = {
        {job_type = w.df.job_type.ConstructBuilding, pos = {x = 1, y = 1, z = 41}},
        {job_type = w.df.job_type.ConstructBuilding, pos = {x = 1, y = 1, z = 39}},
        {job_type = w.df.job_type.Dig, pos = {x = 1, y = 1, z = 39}},
    }
    check('construction jobs are counted', env.count_pending_builds() == 2,
          tostring(env.count_pending_builds()))
    check('and can be scoped to a level, so a mason on the surface does not '
          .. 'hold up the industry level',
          env.count_pending_builds({[39] = true}) == 1,
          tostring(env.count_pending_builds({[39] = true})))
end

-- ---------------------------------------------------------------- --
-- picking a site with no human                                      --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    good_column(w, 96, 96)
    w.add_citizen(1, 94, 96, 41)
    w.add_citizen(2, 98, 96, 41)
    local best, rejected = env.best_anchor(96, 96, 0)
    check('a site is found near the dwarves', best ~= nil,
          rejected and table.concat(rejected, '; '))
    if best then
        check('it anchors on the surveyed column', best.x == 96 and best.y == 96,
              ('%d,%d'):format(best.x, best.y))
    end
end

do
    local w, env = fresh()
    -- No geology at all: every candidate must be refused, and it must say so
    -- rather than anchoring somewhere unbuildable.
    w.add_citizen(1, 96, 96, 41)
    local ok = env.autostart()
    check('autostart refuses when there is nowhere to build', ok == false)
    check('and explains why', #w.errors > 0, tostring(#w.errors))
end

do
    local w, env = fresh()
    good_column(w, 96, 96)
    w.add_citizen(1, 96, 96, 41)
    local ok = env.autostart(0)
    check('autostart anchors and starts the build', ok == true)
    local prog = env.progress()
    check('the plan reports itself anchored', prog.anchored == true)
    check('auto mode is on', prog.auto == true)
    check('it starts at step 1', prog.step == 1, tostring(prog.step))
end

do
    local w, env = fresh()
    good_column(w, 96, 96)
    w.add_citizen(1, 96, 96, 41)
    env.autostart(0)
    local before = env.progress().anchor
    env.autostart(0)   -- second call must not re-site the fort
    check('autostart is idempotent', env.progress().anchor == before,
          tostring(env.progress().anchor))
end

-- ---------------------------------------------------------------- --
-- a step that reports success but does nothing (report F-05)        --
-- ---------------------------------------------------------------- --
-- Anchor a fort and hand the tests a clean slate.
--
-- autostart turns auto mode on, and auto mode applies the first step straight
-- away -- which is the point of it. Give that first step a successful quickfort
-- so it does not leave a warning behind, then take auto off so each test drives
-- apply_step itself.
local QF_OK = 'run of dreamfort.csv successfully completed\n'
           .. '  Tiles designated for digging: 431\n'

local function anchored(w, env)
    good_column(w, 96, 96)
    w.add_citizen(1, 96, 96, 41)
    w.command_output = setmetatable({}, {__index = function() return QF_OK end})
    env.autostart(0)
    env.set_auto(false)
    w.commands = {}
end

-- Dreamfort's vents assume farming sits one level under the surface; ours is deeper.
do
    local w, env = fresh()
    anchored(w, env)
    local plan = {anchor = {x = 100, y = 101}, levels = {surface = 72, farming = 70}}
    w.commands = {}
    local tiles = env.extend_vents(plan)
    local joined = table.concat(w.commands, '|')
    check('vents repeat on the level between the surface and farming',
          joined:find('/surface_channel --cursor 100,101,71', 1, true) ~= nil, joined)
    check('they do not touch the farming level itself',
          joined:find('100,101,70', 1, true) == nil, joined)
    check('the tiles are counted', tiles > 0, tiles)
    w.commands = {}
    env.extend_vents(plan)
    check('and it only happens once', #w.commands == 0, #w.commands)

    local shallow = {anchor = {x = 1, y = 1}, levels = {surface = 72, farming = 71}}
    w.commands = {}
    env.extend_vents(shallow)
    check('a farming level right under the surface needs nothing', #w.commands == 0, #w.commands)
end

-- Sealed designations: drop them only when nothing could ever reach them.
do
    local function sealed_world()
        local w, env = fresh()
        local z = 40
        w.set_tile(50, 50, z, w.df.tiletype_material.SOIL, w.df.tiletype_shape.WALL)
        w.designate(50, 50, z, w.df.tile_dig_designation.Default)
        local plan = {levels = {surface = 42, farming = z}}
        return w, env, plan, w.block_at(50, 50, z), z
    end

    local w, env, plan, block = sealed_world()
    check('a level nobody has reached is left alone',
          env.clear_sealed(plan, {'farming'}) == 0 and block.designation[2][2].dig ~= 0)

    block.walkable[15][15] = 7
    check('sealed tiles on a reached level are dropped',
          env.clear_sealed(plan, {'farming'}) == 1 and block.designation[2][2].dig == 0)

    w, env, plan, block = sealed_world()
    block.walkable[15][15] = 7
    block.walkable[3][3] = 7
    check('a tile with a way in is kept: miners can still get to it',
          env.clear_sealed(plan, {'farming'}) == 0 and block.designation[2][2].dig ~= 0)
end

-- Stockpile links cross one z-level in Dreamfort; ours cross the real depth.
do
    local w, env = fresh()
    local csv = table.concat({
        '#query label(other) start(1; 1)', 'keep,<&',
        '#query label(farming_link) start(16; 18) hidden() set links', '',
        ',,t{Down 6}{Left 10}<&,`,t{Up 2}{Right 11}<&',
        '#query label(after) start(1; 1)', 'keep,<&', ''}, '\n')
    local text = env.link_blueprint_text(csv, 'farming_link', 2)
    check('the label line is kept, so quickfort can find it',
          text:find('label(farming_link)', 1, true) ~= nil)
    check('every link climbs the real depth',
          text:find('t{Down 6}{Left 10}<<&', 1, true) and text:find('t{Up 2}{Right 11}<<&', 1, true), text)
    check('other blueprints stay out of it', not text:find('keep', 1, true), text)
    check('a missing label is not an empty file', env.link_blueprint_text(csv, 'nope', 2) == nil)
end

do
    -- At depth 2 /farming2 runs section by section, without Dreamfort's own link.
    local w, env = fresh()
    anchored(w, env)
    local plan = env.progress()
    local levels = env.antfarm_plan.levels
    levels.farming = levels.surface - 2
    env.antfarm_plan.step = 7
    w.commands = {}
    check('the farming step advances', env.apply_step(7, true) == true)
    local joined = table.concat(w.commands, '|')
    check('its sections run one by one', joined:find('-n /farming_build', 1, true) ~= nil
          and joined:find('-n /farming_query_stockpiles', 1, true) ~= nil, joined)
    check('the meta blueprint with the one-level links does not',
          joined:find('run library/dreamfort.csv -n /farming2', 1, true) == nil, joined)
    check('orders still come from the meta blueprint',
          joined:find('orders library/dreamfort.csv -n /farming2', 1, true) ~= nil, joined)
end

-- A step that keeps failing: bounded retries, and its orders imported only once.
do
    local w, env = fresh()
    anchored(w, env)
    local step_before = env.progress().step
    env.antfarm_plan.step = 5
    w.command_status = 1
    w.commands = {}
    check('first failure holds the step', env.apply_step(5, false) == false and env.progress().step == 5)
    check('second failure holds it too', env.apply_step(5, false) == false and env.progress().step == 5)
    check('the third moves on instead of blocking the fort for good',
          env.apply_step(5, false) == true and env.progress().step == 6, env.progress().step)
    local warned = table.concat(env.progress().warnings, ' | ')
    check('and says so', warned:find('moving on', 1, true) ~= nil, warned)
end

do
    local w, env = fresh()
    anchored(w, env)
    env.antfarm_plan.step = 5
    w.commands = {}
    local real = w.dfhack.run_command_silent
    w.dfhack.run_command_silent = function(cmd)
        table.insert(w.commands, cmd)
        if cmd:find('quickfort run', 1, true) then return 'boom', 1 end
        return QF_OK, 0
    end
    env.apply_step(5, false)
    env.apply_step(5, false)
    local orders = 0
    for _, c in ipairs(w.commands) do if c:find('quickfort orders', 1, true) then orders = orders + 1 end end
    check('a retry does not import the orders again', orders == 1, orders)
    w.dfhack.run_command_silent = real
end

-- The fort's front door: surface stairs that went missing are put back.
do
    local function door_world()
        local w, env = fresh()
        local M, S = w.df.tiletype_material, w.df.tiletype_shape
        w.set_tile(99, 50, 42, M.SOIL, S.FLOOR)
        w.set_tile(101, 50, 42, M.SOIL, S.FLOOR)
        local plan = {step = 7, anchor = {x = 100, y = 50}, levels = {surface = 42, farming = 40}}
        return w, env, plan, w.block_at(99, 50, 42), w.block_at(101, 50, 42)
    end
    local D = 'DownStair'

    local w, env, plan, a, b = door_world()
    check('missing surface stairs are designated again', env.ensure_entrance(plan) == 2, plan.entrance_tries)
    check('as down-stairs', a.designation[99 % 16][50 % 16].dig == w.df.tile_dig_designation[D]
          and b.designation[101 % 16][50 % 16].dig == w.df.tile_dig_designation[D])
    check('not twice while they are still designated', env.ensure_entrance(plan) == 0)

    w, env, plan, a = door_world()
    local M, S = w.df.tiletype_material, w.df.tiletype_shape
    w.set_tile(99, 50, 42, M.SOIL, S.STAIR_DOWN)
    check('one finished stair is a working door', env.ensure_entrance(plan) == 0)

    w, env, plan = door_world()
    plan.step = 2
    check('too early: /surface1 has not run yet', env.ensure_entrance(plan) == 0)

    w, env, plan, a = door_world()
    plan.entrance_tries = 5
    check('gives up rather than fight DF forever', env.ensure_entrance(plan) == 0)
end

-- The opening must not be paced. A live embark spent four real minutes getting to
-- /surface2 with five of seven dwarves idle, because every step waited 60 seconds
-- behind the last whether or not it had anything to wait for.
local function drive_auto(w, env, seconds)
    local pending
    w.dfhack.timeout = function(_, _, fn) pending = fn; return 1 end
    env.set_auto(true)
    for _ = 1, seconds * 2 do
        w.advance(500)
        local fn = pending
        pending = nil
        if fn then fn() end
    end
end

do
    local w, env = fresh()
    anchored(w, env)
    drive_auto(w, env, 5)
    check('ungated opening steps run back to back, no waiting between them',
          env.progress().step >= 5, env.progress().step)
end

do
    -- ...but a step that did nothing keeps its pace, or three retries burn off in
    -- a second and it is written off before the level it needs is dug.
    local w, env = fresh()
    anchored(w, env)
    w.command_output = setmetatable({}, {__index = function()
        return 'run of dreamfort.csv successfully completed\n'
            .. '  Tiles designated for digging: 0\n'
    end})
    local step_before = env.progress().step
    drive_auto(w, env, 30)
    check('a step that did nothing is not retried at full speed',
          env.progress().step == step_before, env.progress().step)
    check('and is not written off', #env.progress().warnings == 0)
end

do
    local w, env = fresh()
    anchored(w, env)
    w.command_output = setmetatable({}, {__index = function()
        return 'run of dreamfort.csv -n /setup successfully completed\n'
            .. '  Tiles designated for digging: 0\n'
            .. '  Tiles outside map boundary: 120\n'
    end})
    local step_before = env.progress().step
    local applied = env.apply_step(step_before, false)
    check('a blueprint that affects 0 tiles does not advance the checklist',
          applied == false and env.progress().step == step_before,
          ('applied=%s step=%d'):format(tostring(applied), env.progress().step))
    check('the attempt is counted', env.progress().attempts == 1,
          tostring(env.progress().attempts))

    env.apply_step(step_before, false)
    env.apply_step(step_before, false)
    check('after the retry budget it moves on rather than wedging the build',
          env.progress().step == step_before + 1, tostring(env.progress().step))
    check('and records a warning saying what is missing',
          #env.progress().warnings > 0,
          table.concat(env.progress().warnings, ' | '))
end

do
    local w, env = fresh()
    anchored(w, env)
    w.command_output = setmetatable({}, {__index = function()
        return 'run of dreamfort.csv -n /setup successfully completed\n'
            .. '  Tiles designated for digging: 431\n'
    end})
    local step_before = env.progress().step
    check('a blueprint that did real work advances the checklist',
          env.apply_step(step_before, false) == true
          and env.progress().step == step_before + 1,
          tostring(env.progress().step))
    check('and leaves no warning', #env.progress().warnings == 0)
end

do
    local w, env = fresh()
    anchored(w, env)
    -- quickfort erroring out (bad cursor, missing blueprint) must never look
    -- like a completed step.
    w.command_output = setmetatable({}, {__index = function()
        return 'ERROR: could not find blueprint\n'
    end})
    local step_before = env.progress().step
    check('a quickfort error never advances the checklist',
          env.apply_step(step_before, false) == false
          and env.progress().step == step_before)
    check('the failure is recorded', #env.progress().warnings > 0,
          table.concat(env.progress().warnings, ' | '))
end

do
    local w, env = fresh()
    anchored(w, env)
    w.command_output = setmetatable({}, {__index = function() return '' end})
    -- df-ai's precondition: never drive the UI when the game is not on the map.
    w.push{vtype = 'viewscreen_topicmeetingst'}
    w.scripts = {antfarm_ui = {is_dwarfmode = function() return false end}}
    local step_before = env.progress().step
    check('no blueprint is applied while a menu is open',
          env.apply_step(step_before, false) == false
          and env.progress().step == step_before)
    check('and quickfort was never invoked', #w.commands == 0,
          table.concat(w.commands, ' | '))
end

-- ---------------------------------------------------------------- --
-- getting unstuck from damp stone                                   --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local levels = {surface = 41, farming = 40, industry = 39}
    -- A designated tile next to water: the miner cancels this forever.
    w.designate(50, 50, 40)
    w.set_tile(51, 50, 40, w.df.tiletype_material.POOL, w.df.tiletype_shape.WALL)
    -- ...and one nowhere near water, which must be left alone.
    w.designate(70, 70, 40)
    local cleared = env.unstick(levels)
    check('a designation touching water is cleared', cleared == 1, tostring(cleared))
    check('the dry designation is left alone', w.count_designated() == 1,
          tostring(w.count_designated()))
end

do
    local w, env = fresh()
    local levels = {surface = 41, farming = 40, industry = 39}
    w.designate(50, 50, 40)
    w.set_tile(50, 50, 39, w.df.tiletype_material.STONE, w.df.tiletype_shape.WALL,
               {water_table = true})
    check('an aquifer tile directly below also counts', env.unstick(levels) == 1)
end

-- ---------------------------------------------------------------- --
-- auto on|off is strict (report D-05)                               --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    anchored(w, env)
    env.set_auto(false)
    check('set_auto(false) turns auto off', env.progress().auto == false)
    env.set_auto(true)
    check('set_auto(true) turns auto on', env.progress().auto == true)
end

-- A rejected orders-library import must remain pending for a later retry.
-- run_command can return a failure code without throwing, so pcall alone is
-- not evidence that the library was imported.
do
    local w, env = fresh()
    anchored(w, env)
    local attempts = 0
    w.dfhack.run_command = function(command)
        if command == 'orders import library/basic' then
            attempts = attempts + 1
            if attempts == 1 then return 5 end -- simulated non-CR_OK result
        end
        return 0
    end

    check('forced step 5 advances to the basic-order import milestone',
          env.apply_step(5, true) == true)
    check('a failed library import is attempted once and reported',
          attempts == 1 and #w.errors > 0,
          ('attempts=%d errors=%d'):format(attempts, #w.errors))

    env.apply_step(5, true)
    check('the failed basic-order import is retried on a later completed step',
          attempts == 2, tostring(attempts))

    env.apply_step(5, true)
    check('a successful basic-order import is not repeated',
          attempts == 2, tostring(attempts))
end

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
