-- Read-only diagnostics for manager order validation/activity flags.
--
-- Run: lua tests/test_antfarm_orders.lua (from repository root)
-- The status proxies below throw on every write. This is deliberate: a
-- regression that writes status.validated/status.active must fail the test.

local stub = dofile('tests/df_stub.lua')
local ORDERS = 'game/hack/scripts/antfarm_orders.lua'

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

local function office_fixture(population, manager_histfig, chair_owner)
    local w = stub.new()
    w.scripts = {
        antfarm_nobles = {
            positions = function()
                return {MANAGER = {histfig = manager_histfig}}
            end,
        },
    }
    w.df.building_type = {Chair = 99}
    w.df.historical_figure = {
        find = function(id)
            if id ~= manager_histfig then return nil end
            return {unit_id = 1}
        end,
    }
    for i = 1, population do
        w.add_citizen(i, 1, 1, 1)
    end
    w.df.global.world.buildings = {all = stub.vector{}}
    if chair_owner ~= nil then
        w.df.global.world.buildings.all:push({
            owner_id = chair_owner,
            is_room = true,
            getType = function() return 99 end,
        })
    end
    local env = stub.load(w, ORDERS)
    return env.audit().manager_office
end

local function read_only_status(values, unreadable)
    local writes = {count = 0}
    local status = setmetatable({}, {
        __index = function(_, key)
            if unreadable and unreadable[key] then
                error('status field unavailable: ' .. key)
            end
            return values[key]
        end,
        __newindex = function(_, key, value)
            writes.count = writes.count + 1
            error('attempted write to protected order status.' .. tostring(key))
        end,
    })
    return status, writes
end

local w = stub.new()
w.df.job_type[1] = 'BrewDrink'
w.df.job_type[2] = 'ConstructBed'
w.df.job_type[3] = 'ConstructDoor'

local writes = {}
local status_a, writes_a = read_only_status({validated = false, active = false})
local status_b, writes_b = read_only_status({validated = true, active = true})
local status_c, writes_c = read_only_status(
    {active = true}, {validated = true}
)
writes = {writes_a, writes_b, writes_c}

w.df.global.world.manager_orders:push({
    job_type = 1, mat_type = -1, mat_index = -1, amount_left = 12,
    status = status_a,
})
w.df.global.world.manager_orders:push({
    job_type = 2, mat_type = -1, mat_index = -1, amount_left = 4,
    status = status_b,
})
w.df.global.world.manager_orders:push({
    job_type = 3, mat_type = -1, mat_index = -1, amount_left = 2,
    status = status_c,
})

-- No actual metals module is needed for this audit fixture: all orders are
-- material-agnostic and are not eligible for the impossible-order reaper.
w.scripts = {}
local env = stub.load(w, ORDERS)

print('antfarm_orders')

do
    local rows = env.scan()
    check('all manager orders are read', #rows == 3, tostring(#rows))
    check('false validated is distinguished from unknown',
          rows[1].validated == false and rows[3].validated == nil)
    check('false active is distinguished from true active',
          rows[1].active == false and rows[2].active == true)
    check('order identity and amount remain visible',
          rows[1].job == 'BrewDrink' and rows[1].amount_left == 12)
end

do
    local result = env.audit()
    local c = result.counts
    check('audit counts validated and unvalidated orders',
          c.validated == 1 and c.unvalidated == 1,
          ('validated=%d unvalidated=%d'):format(c.validated, c.unvalidated))
    check('audit counts unreadable flags as unknown, not false',
          c.validation_unknown == 1, tostring(c.validation_unknown))
    check('audit counts active, inactive and unknown activity',
          c.active == 2 and c.inactive == 1 and c.activity_unknown == 0,
          ('active=%d inactive=%d unknown=%d'):format(
              c.active, c.inactive, c.activity_unknown))
    check('audit includes stalled-job and unmet-input counts',
          c.stalled_jobs == 0 and c.unmet_requirements == 0)
    check('office is not required before 20 citizens',
          result.manager_office.status == 'not_required')
end

do
    local r = env.report()
    check('report exports order-validation counts to the bridge',
          r.orders == 3 and r.validated == 1 and r.unvalidated == 1
          and r.validation_unknown == 1)
    check('report exports active-state counts',
          r.active == 2 and r.inactive == 1 and r.activity_unknown == 0)
end

do
    local below_threshold = office_fixture(19, -1, nil)
    local vacant_manager = office_fixture(20, -1, nil)
    local missing_office = office_fixture(20, 500, nil)
    local owned_office = office_fixture(20, 500, 1)
    check('manager office is not required below 20 citizens',
          below_threshold.status == 'not_required',
          tostring(below_threshold.status) .. ' ' .. tostring(below_threshold.detail))
    check('missing manager assignment is reported separately',
          vacant_manager.status == 'manager_missing',
          tostring(vacant_manager.status) .. ' ' .. tostring(vacant_manager.detail))
    check('missing manager chair-room is detected',
          missing_office.status == 'missing',
          tostring(missing_office.status) .. ' ' .. tostring(missing_office.detail))
    check('manager-owned chair-room satisfies the office check',
          owned_office.status == 'present',
          tostring(owned_office.status) .. ' ' .. tostring(owned_office.detail))
end

do
    local total_writes = 0
    for _, tracker in ipairs(writes) do total_writes = total_writes + tracker.count end
    check('audit and report never write protected DF status flags', total_writes == 0,
          tostring(total_writes))
    check('audit has no command side effects', #w.commands == 0, tostring(#w.commands))
    check('audit leaves the manager-order vector unchanged',
          #w.df.global.world.manager_orders == 3)
end

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_orders tests failed'):format(fail)) end
