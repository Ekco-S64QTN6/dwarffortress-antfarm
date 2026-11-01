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
    check('mining maximum is capped to the two picks',
          by_labor.MINE and by_labor.MINE.minimum == '1'
          and by_labor.MINE.maximum == '2')
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

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_sustenance tests failed'):format(fail)) end
