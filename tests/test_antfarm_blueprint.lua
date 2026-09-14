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

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
