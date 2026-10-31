-- Regression tests for furniture production/placement ordering in antfarm_quarters.
--
-- Run: lua tests/test_antfarm_quarters.lua (from repository root)

local stub = dofile('tests/df_stub.lua')
local QUARTERS = 'game/hack/scripts/antfarm_quarters.lua'

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

local function fresh(population)
    local w = stub.new()
    w.df.building_type = {
        Bed = 1, Door = 2, Box = 3, Cabinet = 4,
        Table = 5, Chair = 6, Coffin = 7,
    }
    w.df.item_type.BED = 12
    w.df.item_type.WOOD = 13
    w.df.job_type.ConstructBed = 21
    w.df.job_type.ConstructDoor = 22
    w.df.job_type.ConstructChest = 23
    w.df.job_type.ConstructCabinet = 24
    w.df.global.world.buildings = {all = stub.vector{}}
    w.df.global.world.items = {all = stub.vector{}}
    for i = 1, population do w.add_citizen(i, 8, 8, 10) end
    local env = stub.load(w, QUARTERS)
    return w, env
end

local function floor_block(w)
    local block = {tiletype = {}, designation = {}}
    local floor = w.tt(w.df.tiletype_material.STONE, w.df.tiletype_shape.FLOOR)
    for x = 0, 15 do
        block.tiletype[x], block.designation[x] = {}, {}
        for y = 0, 15 do
            block.tiletype[x][y] = floor
            block.designation[x][y] = {
                outside = false,
                dig = w.df.tile_dig_designation.No,
                flow_size = 0,
            }
        end
    end
    return block
end

print('antfarm_quarters')

-- The DFHack 0.47 workorder command interprets an explicit "material" as a
-- concrete matinfo id. A category label such as "INORGANIC" is not one. Leave
-- material unspecified so the workshop picks a valid material for the job.
do
    local w, env = fresh(3)
    local calls = {}
    w.dfhack.run_command = function(...)
        local call = {...}
        calls[#calls + 1] = call
        return 0
    end

    local queued, why = env.queue_furniture()
    check('queues all four furniture work orders', #queued == 4,
          tostring(#queued) .. ' / ' .. tostring(why))
    check('workorder command invoked four times', #calls == 4, tostring(#calls))

    local jobs = {
        ConstructBed = false,
        ConstructDoor = false,
        ConstructChest = false,
        ConstructCabinet = false,
    }
    local valid_json = true
    for _, call in ipairs(calls) do
        local json = call[2] or ''
        if call[1] ~= 'workorder' or json:find('"material"')
                or not json:find('"__reduce_amount":true', 1, true) then
            valid_json = false
        end
        for job in pairs(jobs) do
            if json:find('"job":"' .. job .. '"', 1, true)
                    and json:find('"amount_total":3', 1, true) then
                jobs[job] = true
            end
        end
    end
    check('orders omit the invalid INORGANIC material token', valid_json)
    check('each order targets the expected job and amount',
          jobs.ConstructBed and jobs.ConstructDoor
          and jobs.ConstructChest and jobs.ConstructCabinet)

    local _, second_detail = env.queue_furniture()
    check('second pass tells DFHack to reconcile matching open orders',
          #calls == 8 and valid_json,
          ('calls=%d detail=%s'):format(#calls, tostring(second_detail)))
end

-- An existing matching order uses the requested total as its target. DFHack's
-- __reduce_amount behavior adjusts the open order instead of adding a duplicate.
do
    local w, env = fresh(3)
    w.df.global.world.manager_orders:push({
        job_type = w.df.job_type.ConstructBed,
        amount_left = 1,
    })
    local calls = {}
    w.dfhack.run_command = function(...)
        calls[#calls + 1] = {...}
        return 0
    end

    local queued = env.queue_furniture()
    local bed_amount, bed_reduce, other_amounts = nil, false, 0
    for _, call in ipairs(calls) do
        local json = call[2] or ''
        local job = json:match('"job":"([^"]+)"')
        local amount = tonumber(json:match('"amount_total":(%d+)'))
        if job == 'ConstructBed' then
            bed_amount = amount
            bed_reduce = json:find('"__reduce_amount":true', 1, true) ~= nil
        else
            other_amounts = other_amounts + (amount or 0)
        end
    end
    check('matching bed order receives desired total, not an additive delta',
          bed_amount == 3 and bed_reduce, tostring(bed_amount))
    check('unrelated furniture orders retain their full target',
          other_amounts == 9, tostring(other_amounts))
end

-- A rejected DFHack command is not a successfully queued manager order.
do
    local w, env = fresh(2)
    local calls = 0
    w.dfhack.run_command = function() calls = calls + 1; return 5 end
    local queued, detail = env.queue_furniture()
    check('non-CR_OK workorder results are not counted as queued',
          #queued == 0 and calls == 4, ('queued=%d calls=%d'):format(#queued, calls))
    check('rejected workorders are surfaced as safe warnings',
          tostring(detail):find('workorder command failed', 1, true) ~= nil,
          tostring(detail))
end

-- Accessory furniture has its own shortfall and is not gated by the bed
-- count. Otherwise getting the final bed built early would suppress all later
-- door/chest/cabinet orders.
do
    local w, env = fresh(3)
    for i = 1, 3 do
        w.df.global.world.buildings.all:push({
            getType = function() return w.df.building_type.Bed end,
            owner_id = i,
            is_room = true,
        })
    end
    local calls = {}
    w.dfhack.run_command = function(...)
        calls[#calls + 1] = {...}
        return 0
    end
    local queued = env.queue_furniture()
    local jobs = {}
    for _, call in ipairs(calls) do
        local json = call[2] or ''
        local job = json:match('"job":"([^"]+)"')
        local amount = tonumber(json:match('"amount_total":(%d+)'))
        if job then jobs[job] = amount end
    end
    check('accessory orders still queue after every citizen has a bed',
          #queued == 3 and #calls == 3)
    check('only doors, chests and cabinets are queued when beds are complete',
          jobs.ConstructDoor == 3 and jobs.ConstructChest == 3
          and jobs.ConstructCabinet == 3 and jobs.ConstructBed == nil)
end

-- A log is a workshop input, not the finished bed item consumed by the build
-- menu. The placer must do nothing until a free BED item exists.
do
    local w, env = fresh(2)
    local constructions = 0
    local block = floor_block(w)
    w.dfhack.maps.getTileBlock = function() return block end
    w.dfhack.buildings = {
        findAtTile = function() return nil end,
        constructBuilding = function()
            constructions = constructions + 1
            return {}
        end,
    }
    w.scripts = {
        antfarm_blueprint = {
            plan_summary = function()
                return {anchor = {x = 8, y = 8}, levels = {farming = 10}}
            end,
        },
    }
    env.xyz2pos = function(x, y, z) return {x = x, y = y, z = z} end

    w.df.global.world.items.all:push({
        getType = function() return w.df.item_type.WOOD end,
        flags = {forbid = false, in_job = false, in_building = false},
    })

    local messages, why = env.place_beds()
    check('logs alone do not trigger bed construction',
          constructions == 0, tostring(constructions))
    check('missing finished beds are reported honestly',
          #messages == 0 and tostring(why):find('finished bed items', 1, true) ~= nil,
          tostring(why))
end

-- Reserved and forbidden finished beds are not available. One unreserved BED
-- item permits exactly one queued construction.
do
    local w, env = fresh(2)
    local constructions = {}
    local block = floor_block(w)
    w.dfhack.maps.getTileBlock = function() return block end
    w.dfhack.buildings = {
        findAtTile = function() return nil end,
        constructBuilding = function(spec)
            constructions[#constructions + 1] = spec
            return {}
        end,
    }
    w.scripts = {
        antfarm_blueprint = {
            plan_summary = function()
                return {anchor = {x = 8, y = 8}, levels = {farming = 10}}
            end,
        },
    }
    env.xyz2pos = function(x, y, z) return {x = x, y = y, z = z} end

    w.df.global.world.items.all:push({
        getType = function() return w.df.item_type.BED end,
        flags = {forbid = true, in_job = false, in_building = false},
    })
    w.df.global.world.items.all:push({
        getType = function() return w.df.item_type.BED end,
        flags = {forbid = false, in_job = true, in_building = false},
    })
    w.df.global.world.items.all:push({
        getType = function() return w.df.item_type.BED end,
        flags = {forbid = false, in_job = false, in_building = false},
    })

    local messages, why = env.place_beds()
    check('only the free finished bed item is used',
          #constructions == 1, tostring(#constructions))
    check('result says queued, not already placed',
          #messages == 1 and messages[1]:find('queued 1 bed construction', 1, true) ~= nil,
          messages[1] or tostring(why))
    check('construction targets the dug indoor floor',
          constructions[1] and constructions[1].type == w.df.building_type.Bed
          and constructions[1].pos.x >= 0)
end

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error(('%d antfarm_quarters tests failed'):format(fail)) end
