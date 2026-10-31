-- Regression test for the DFHack 0.47 on-map automatic job priorities.
-- Brewing is a CustomReaction filtered by reaction name, not a "Brew" job type.
-- Run: lua tests/test_init_priorities.lua

local path = 'game/dfhack-config/init/onMapLoad.init'
local file = assert(io.open(path, 'r'))
local content = file:read('*a')
file:close()

local pass, fail = 0, 0
local function check(name, ok)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print('  FAIL  ' .. name)
    end
end

local expected_brew =
    'prioritize -a CustomReaction -n BREW_DRINK_FROM_PLANT,BREW_DRINK_FROM_PLANT_GROWTH'
local expected_food =
    'prioritize -a PlantSeeds ProcessPlants ProcessPlantsBarrel MillPlants PrepareMeal'

check('plant brewing uses registered CustomReaction reaction names',
      content:find(expected_brew, 1, true) ~= nil)
check('farm and food jobs have a separate valid priority command',
      content:find(expected_food, 1, true) ~= nil)

local invalid_brew_job = false
for line in content:gmatch('[^\n]+') do
    local command = line:match('^%s*(prioritize.-)$')
    if command and command:match('%f[%w]Brew%f[%W]') then
        invalid_brew_job = true
    end
end
check('no prioritize command refers to a nonexistent Brew job type',
      not invalid_brew_job)

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d init-priority tests failed'):format(fail)) end
