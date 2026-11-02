-- Regression tests for DFHack 0.47 autolabor command result handling.
-- Run: lua tests/test_antfarm_sustenance.lua

local stub = dofile('tests/df_stub.lua')
local SCRIPT = 'game/hack/scripts/antfarm_sustenance.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and (' -- ' .. tostring(detail)) or ''))
    end
end

local function fresh(command_result)
    local w = stub.new()
    w.df.item_type = {WEAPON = 1, TOOL = 2}
    w.df.building_type = {Civzone = 1, Workshop = 2}
    w.df.workshop_type = {Still = 1, Kitchen = 2, Farmers = 3}
    w.df.civzone_type = {ActivityZone = 1}
    w.df.global.world.items = {all = {}}
    w.df.global.world.buildings = {all = {}}
    w.df.global.world.units.active = {}

    local calls = {}
    w.dfhack.run_command = function(...)
        calls[#calls + 1] = {...}
        if type(command_result) == 'function' then
            return command_result(...)
        end
        return command_result == nil and 0 or command_result
    end
    local env = stub.load(w, SCRIPT)
    return w, env, calls
end

local function add_tool(w, subtype)
    table.insert(w.df.global.world.items.all, {
        getType = function() return w.df.item_type.WEAPON end,
        subtype = {id = subtype},
    })
end

print('antfarm_sustenance')

-- A small fort keeps hands free: miners do not haul, and the labour must not take
-- everyone just because the picks exist.
do
    local w, env, calls = fresh(0)
    for _ = 1, 7 do add_tool(w, 'ITEM_WEAPON_PICK') end
    local citizens = {}
    for i = 1, 7 do table.insert(citizens, {id = i}) end
    w.df.global.world.units.active = citizens
    w.dfhack.units = w.dfhack.units or {}
    w.dfhack.units.isCitizen = function() return true end
    env.tune_labour()
    local mine
    for _, call in ipairs(calls) do if call[2] == 'MINE' then mine = call[3] end end
    check('seven picks on seven dwarves does not mean seven miners', mine == '4', mine)
end

-- The surface stairs: workshops placed before them cut the fort in half.
do
    local w, env = fresh(0)
    w.scripts = {antfarm_blueprint = {plan_summary = function()
        return {anchor = {x = 100, y = 100}, levels = {surface = 72}, step = 3}
    end}}
    check('the opening is recognised', env.opening_in_progress() == true)
    w.df.global.world.items.other = {WOOD = stub.vector{{flags = {}}}}
    w.dfhack.buildings = {constructBuilding = function() error('must not be placed') end}
    local placed, why = env.ensure_workshops()
    check('no workshops while the guided build lays out the surface',
          #placed == 0 and why:find('guided build', 1, true), why)
    check('a 3x3 touching the stairs is refused', not env.clear_of_stairs(98, 98, 3, 3))
    check('so is one just inside the margin', not env.clear_of_stairs(103, 100, 3, 3))
    check('clear of it is fine', env.clear_of_stairs(104, 100, 3, 3))

    w.scripts = {antfarm_blueprint = {plan_summary = function()
        return {anchor = {x = 100, y = 100}, levels = {surface = 72}, step = 6}
    end}}
    check('once /surface2 has run the backstop is live again', env.opening_in_progress() == false)
end

-- A workshop placed with nothing to build it from is cancelled and vanishes.
do
    local w, env = fresh(0)
    local log = {flags = {in_building = true}}
    w.df.global.world.items.other = {WOOD = stub.vector{log}}
    check('logs inside the wagon are not building material', not env.building_material_on_hand())
    log.flags.in_building = false
    check('logs on the ground are', env.building_material_on_hand())
    log.flags.forbid = true
    check('forbidden logs are not', not env.building_material_on_hand())

    w.dfhack.buildings = {constructBuilding = function() error('must not be placed') end}
    w.dfhack.units = w.dfhack.units or {}
    w.dfhack.units.isCitizen = function() return true end
    w.df.global.world.units.active = {{pos = {x = 10, y = 10, z = 5}}}
    local placed, why = env.ensure_workshops()
    check('nothing is placed without material', #placed == 0 and why == 'nothing to build with yet', why)
end

-- A successful pcall is not enough: only CR_OK confirms DFHack accepted the
-- autolabor change. Verify argument order and all four target labor commands.
do
    local w, env, calls = fresh(0)
    add_tool(w, 'ITEM_WEAPON_PICK')
    add_tool(w, 'ITEM_WEAPON_PICK')
    add_tool(w, 'ITEM_WEAPON_AXE_BATTLE')

    local notes = env.tune_labour()
    local by_labor = {}
    for _, call in ipairs(calls) do
        if call[1] == 'autolabor' then
            by_labor[call[2]] = {minimum = call[3], maximum = call[4]}
        end
    end

    check('submits mining, woodcutting, herbalist and planting targets', #calls == 4,
          tostring(#calls))
    -- The minimum must match the picks too: autolabor will not add a second,
    -- unskilled miner on its own, and the spare pick lies on the floor.
    check('mining minimum and maximum both equal the two picks',
          by_labor.MINE and by_labor.MINE.minimum == '2'
          and by_labor.MINE.maximum == '2',
          by_labor.MINE and (by_labor.MINE.minimum .. '/' .. by_labor.MINE.maximum))
    check('woodcutting maximum is capped to the one axe',
          by_labor.CUTWOOD and by_labor.CUTWOOD.minimum == '1'
          and by_labor.CUTWOOD.maximum == '1')
    check('herbalist and planting minimums are submitted',
          by_labor.HERBALIST and by_labor.HERBALIST.minimum == '3'
          and by_labor.PLANT and by_labor.PLANT.minimum == '2')
    local all_success = true
    for _, message in ipairs(notes) do
        if message:find('autolabor failed:', 1, true) then all_success = false end
    end
    check('CR_OK is reported as successful labor configuration', all_success)
end

-- Command return codes must be reported even when pcall itself succeeds.
do
    local w, env, calls = fresh(7)
    local notes = env.tune_labour()
    check('non-CR_OK results produce one warning per target labor',
          #notes == 4 and #calls == 4,
          ('notes=%d calls=%d'):format(#notes, #calls))
    local warnings = {}
    for _, message in ipairs(notes) do
        if message:find('autolabor failed:', 1, true) then
            warnings[#warnings + 1] = message
        end
    end
    check('all rejected autolabor commands are explicitly identified',
          #warnings == 4 and table.concat(warnings, ' '):find('command returned 7', 1, true) ~= nil,
          table.concat(warnings, ' | '))
end

-- Lua exceptions are distinct from a normal DFHack command rejection.
do
    local w, env = fresh(function() error('simulated RPC failure') end)
    local notes = env.tune_labour()
    local warnings = {}
    for _, message in ipairs(notes) do
        if message:find('autolabor failed:', 1, true) then
            warnings[#warnings + 1] = message
        end
    end
    check('thrown command errors are converted into labor warnings',
          #warnings == 4 and table.concat(warnings, ' '):find('simulated RPC failure', 1, true) ~= nil)
end

-- Background tuning must preserve failures for the state/dashboard reporter.
do
    local w, env = fresh(function(_, labor)
        if labor == 'HERBALIST' then return 9 end
        return 0
    end)
    -- The production tick interval is five minutes; move the fake game clock
    -- past its first eligible run before asserting the background behavior.
    w.advance(300000)
    env.tick()
    local notes = table.concat(env.antfarm_sustenance_state.notes, ' | ')
    check('background tick publishes rejected labor settings',
          notes:find('HERBALIST autolabor failed:', 1, true) ~= nil,
          notes)
    check('background tick does not report accepted labor settings as errors',
          notes:find('MINE autolabor failed:', 1, true) == nil
          and notes:find('PLANT autolabor failed:', 1, true) == nil,
          notes)
end

-- ---------------------------------------------------------------- --
-- brewing orders                                                    --
-- ---------------------------------------------------------------- --

local function add_still(w, finished)
    table.insert(w.df.global.world.buildings.all, {
        type = w.df.workshop_type.Still,
        getType = function() return w.df.building_type.Workshop end,
        getBuildStage = function() return finished and 1 or 0 end,
        getMaxBuildStage = function() return 1 end,
    })
end

-- Wire the real blueprint module in, so this exercises the actual plan
-- bookkeeping rather than a stand-in for it.
local function with_blueprint(w)
    w.df.global.world.manager_orders = {}
    local bp = stub.load(w, 'game/hack/scripts/antfarm_blueprint.lua')
    w.scripts = {antfarm_blueprint = bp}
    return bp
end

local function imports(calls)
    local n = 0
    for _, call in ipairs(calls) do
        if call[1] == 'orders import library/basic' then n = n + 1 end
    end
    return n
end

-- The live failure: a still and no brew order, because library/basic waits for
-- build step 5. No still yet is a wait, not an error.
do
    local w, env, calls = fresh(0)
    local bp = with_blueprint(w)
    local ok, why = env.ensure_brew_orders()
    check('no still: nothing imported and no failure reported',
          ok == nil and imports(calls) == 0, tostring(why))

    add_still(w, false)
    ok = env.ensure_brew_orders()
    check('an unbuilt still does not import the brewing orders',
          ok == nil and imports(calls) == 0)

    w.df.global.world.buildings.all = {}
    add_still(w, true)
    ok = env.ensure_brew_orders()
    check('a finished still imports library/basic ahead of build step 5',
          ok == true and imports(calls) == 1, tostring(imports(calls)))
    check('the import is recorded in the plan',
          bp.antfarm_plan.orders_done['library/basic'] == true)

    env.ensure_brew_orders()
    check('a recorded import is not repeated', imports(calls) == 1)
end

-- Re-anchoring clears orders_done but the fort keeps its orders. Importing
-- again would duplicate all 46, so the game itself is the source of truth.
do
    local w, env, calls = fresh(0)
    local bp = with_blueprint(w)
    w.df.global.world.manager_orders = {{reaction_name = 'BREW_DRINK_FROM_PLANT'}}
    add_still(w, true)
    local ok = env.ensure_brew_orders()
    check('brew orders already in the fort are adopted, not re-imported',
          ok == true and imports(calls) == 0
          and bp.antfarm_plan.orders_done['library/basic'] == true)
end

-- A rejected import is a failure with a reason, and stays retryable.
do
    local w, env, calls = fresh(function(cmd)
        if cmd == 'orders import library/basic' then return 3 end
        return 0
    end)
    local bp = with_blueprint(w)
    add_still(w, true)
    local ok, why = env.ensure_brew_orders()
    check('a rejected import reports the DFHack return code',
          ok == false and tostring(why):find('command returned 3', 1, true) ~= nil,
          tostring(why))
    check('a rejected import is not recorded as done',
          not bp.antfarm_plan.orders_done['library/basic'])
end

-- The background tick places workshops and imports the orders in one pass,
-- and notes the placement it made (it used to run placement twice and lose it).
do
    local w, env, calls = fresh(0)
    with_blueprint(w)
    add_still(w, true)
    w.advance(300000)
    env.tick()
    local notes = table.concat(env.antfarm_sustenance_state.notes, ' | ')
    check('tick imports the brewing orders once a still is finished',
          imports(calls) == 1 and notes:find('brewing orders in place', 1, true) ~= nil,
          notes)
    check('report exposes the brewing-order state', env.report().brew_orders == true)
end

do
    local w, env = fresh(0)
    local placements = 0
    env.ensure_workshops = function()
        placements = placements + 1
        return {'Kitchen'}
    end
    w.advance(300000)
    env.tick()
    local notes = table.concat(env.antfarm_sustenance_state.notes, ' | ')
    check('tick runs workshop placement exactly once', placements == 1, tostring(placements))
    check('tick notes the workshop it placed',
          notes:find('placed a Kitchen', 1, true) ~= nil, notes)
end

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_sustenance tests failed'):format(fail)) end
