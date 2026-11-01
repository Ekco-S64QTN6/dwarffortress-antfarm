-- Regression test for the 0.47.05 on-map idle-gap setting.
-- workNow 2 asks DF to reassign a dwarf as soon as their current job finishes.
-- Run: lua tests/test_init_worknow.lua

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

local count = 0
for line in content:gmatch('[^\\n]+') do
    if line:match('^%s*workNow%s+2%s*$') then count = count + 1 end
end

check('job completion immediately triggers a new assignment pass', count == 1)
check('paused-only workNow mode is not used instead', 
      content:match('^%s*workNow%s+1%s*$') == nil)

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d workNow init tests failed'):format(fail)) end
