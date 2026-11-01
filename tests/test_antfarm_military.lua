-- antfarm_military: who can lead a new squad, and when tick() asks for one.
-- Run: lua tests/test_antfarm_military.lua

local stub = dofile('tests/df_stub.lua')
local SCRIPT = 'game/hack/scripts/antfarm_military.lua'

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

-- A fort entity with leader positions, shaped as the live one read on
-- region_smoke: positions.own carry squad_size, positions.assignments carry
-- histfig (-1 = vacant) and squad_id (-1 = no squad yet).
local function fresh(assignments, citizens)
    local w = stub.new()
    local own = stub.vector{
        {id = 1, code = 'MILITIA_COMMANDER', squad_size = 10},
        {id = 2, code = 'MILITIA_CAPTAIN', squad_size = 10},
        {id = 3, code = 'MANAGER', squad_size = 0},
    }
    local entity = {squads = stub.vector{}, positions = {own = own, assignments = stub.vector(assignments)}}
    w.df.global.ui.group_id = 1
    w.df.historical_entity = {find = function(id) return id == 1 and entity or nil end}
    w.df.squad = {find = function() return nil end}
    w.dfhack.units.isAdult = function() return true end
    for i = 1, citizens or 0 do
        w.df.global.world.units.active:push({id = 100 + i, mood = -1, military = {squad_id = -1}})
    end
    local requests = {}
    w.scripts = {antfarm_ui = {request_squad = function(operator)
        table.insert(requests, operator and 'operator' or 'auto')
        return true, 'driver started'
    end}}
    local env = stub.load(w, SCRIPT)
    return w, env, requests
end

print('antfarm_military')

do
    local _, env = fresh({
        {position_id = 1, histfig = 7, squad_id = -1},   -- commander, no squad
        {position_id = 2, histfig = -1, squad_id = -1},  -- captain post vacant
        {position_id = 3, histfig = 8, squad_id = -1},   -- manager: not a squad post
    })
    local free = env.leaders_without_squad()
    check('an appointed commander without a squad can lead one',
          #free == 1 and free[1] == 'MILITIA_COMMANDER', table.concat(free, ','))
end

do
    local _, env = fresh({{position_id = 1, histfig = 7, squad_id = 35}})
    check('a leader who already has a squad is not counted', #env.leaders_without_squad() == 0)
    local ok, why = env.create_squad(true)
    check('create refuses when every leader has a squad', not ok and why:find('already has a squad'), why)
end

do
    -- 7 able citizens: df-ai's one-in-five target is 1 soldier, 0 slots exist.
    local w, env, requests = fresh({{position_id = 1, histfig = 7, squad_id = -1}}, 7)
    w.advance(1000000)
    env.tick()
    check('tick asks the UI driver for a squad when below target', #requests == 1 and requests[1] == 'auto',
          table.concat(requests, ','))
    check('and records why in its notes', env.antfarm_military_state.notes[1]
          and env.antfarm_military_state.notes[1]:find('creating a squad'))
end

do
    -- 4 able citizens: target 0, so no squad is wanted yet.
    local w, env, requests = fresh({{position_id = 1, histfig = 7, squad_id = -1}}, 4)
    w.advance(1000000)
    env.tick()
    check('no squad is requested below five able citizens', #requests == 0)
end

do
    local _, env, requests = fresh({{position_id = 1, histfig = 7, squad_id = -1}})
    local ok = env.create_squad(true)
    check('the create verb passes operator permission through', ok and requests[1] == 'operator')
end

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_military tests failed'):format(fail)) end
