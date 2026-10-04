-- Tests for antfarm_autoslab.lua: memorial slab engraver for ghosts.
--
-- Run: lua tests/test_antfarm_autoslab.lua   (from repository root)

local stub = dofile('tests/df_stub.lua')
local AUTOSLAB = 'game/hack/scripts/antfarm_autoslab.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
    end
end

local function fresh()
    local w = stub.new()
    local env = stub.load(w, AUTOSLAB)
    return w, env
end

print('antfarm_autoslab')

-- ---------------------------------------------------------------- --
-- 1. Clean state report                                            --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local r = env.report()
    check('clean state reports zero ghosts', r.ghost_count == 0, tostring(r.ghost_count))
    check('clean state reports zero memorial slabs', r.memorialized_slabs == 0, tostring(r.memorialized_slabs))
    check('clean state reports zero blank slabs', r.blank_slabs == 0, tostring(r.blank_slabs))
    check('clean state reports zero engrave orders', r.pending_engrave_orders == 0, tostring(r.pending_engrave_orders))
end

-- ---------------------------------------------------------------- --
-- 2. Detect ghost and queue engrave order                          --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local ghost_unit = {
        id = 42,
        name = "Urist McGhost",
        hist_figure_id = 101,
        flags3 = {ghostly = true},
    }
    w.df.global.world.units.all:push(ghost_unit)

    local r = env.report()
    check('ghost detected in scan', r.ghost_count == 1, tostring(r.ghost_count))

    local queued = env.auto_engrave()
    check('auto_engrave returns queued ghost name', #queued == 1 and queued[1] == "Urist McGhost",
          string.format("count=%d, name=%s", #queued, tostring(queued[1])))

    local orders = w.df.global.world.manager_orders
    -- 1 EngraveSlab + 1 ConstructSlab (because blank slabs was 0)
    check('manager orders contains engrave and construct orders', #orders == 2, tostring(#orders))

    local engrave_order = orders[0]
    check('first order is EngraveSlab for ghost hist_figure_id',
          engrave_order.job_type == w.df.job_type.EngraveSlab and engrave_order.hist_figure_id == 101,
          string.format("job=%s, hf=%s", tostring(engrave_order.job_type), tostring(engrave_order.hist_figure_id)))

    local craft_order = orders[1]
    check('second order is ConstructSlab for blank slab',
          craft_order.job_type == w.df.job_type.ConstructSlab and craft_order.amount_left == 1,
          string.format("job=%s, amt=%s", tostring(craft_order.job_type), tostring(craft_order.amount_left)))

    -- Calling auto_engrave again does not duplicate orders
    local queued2 = env.auto_engrave()
    check('second auto_engrave call does not duplicate orders', #queued2 == 0, tostring(#queued2))
    check('manager order count unchanged on second call', #orders == 2, tostring(#orders))
end

-- ---------------------------------------------------------------- --
-- 3. Existing memorial slab skips order                            --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local ghost_unit = {
        id = 43,
        name = "Kogan McHaunted",
        hist_figure_id = 202,
        flags3 = {ghostly = true},
    }
    w.df.global.world.units.all:push(ghost_unit)

    -- Add an already-carved memorial slab for hist_figure_id 202
    local slab_item = {
        engraving_type = w.df.slab_engraving_type.Memorial,
        topic = 202,
        flags = {forbid = false, in_job = false},
    }
    w.df.global.world.items.other.SLAB:push(slab_item)

    local r = env.report()
    check('memorialized slab recognized in report', r.memorialized_slabs == 1, tostring(r.memorialized_slabs))

    local queued = env.auto_engrave()
    check('already memorialized ghost is not queued again', #queued == 0, tostring(#queued))
    check('no manager orders placed for already memorialized ghost', #w.df.global.world.manager_orders == 0,
          tostring(#w.df.global.world.manager_orders))
end

-- ---------------------------------------------------------------- --
-- 4. Blank slabs deficit calculation                               --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    -- Put 2 blank slabs in items
    w.df.global.world.items.other.SLAB:push({
        engraving_type = 0,
        topic = -1,
        flags = {forbid = false, in_job = false},
    })
    w.df.global.world.items.other.SLAB:push({
        engraving_type = 0,
        topic = -1,
        flags = {forbid = false, in_job = false},
    })
    -- Put 1 pending craft order for 1 slab
    local pending = w.df.manager_order:new()
    pending.job_type = w.df.job_type.ConstructSlab
    pending.amount_left = 1
    w.df.global.world.manager_orders:push(pending)

    local r = env.report()
    check('blank slabs count reported as 2', r.blank_slabs == 2, tostring(r.blank_slabs))
    check('pending craft orders count reported as 1', r.pending_craft_orders == 1, tostring(r.pending_craft_orders))

    -- We need 5 blank slabs. Currently 2 in stock + 1 pending order = 3 available. Deficit = 2.
    local queued = env.ensure_blank_slabs(5)
    check('ensure_blank_slabs orders the exact deficit of 2', queued == 2, tostring(queued))
    check('manager orders count now 2', #w.df.global.world.manager_orders == 2,
          tostring(#w.df.global.world.manager_orders))

    local new_order = w.df.global.world.manager_orders[1]
    check('new order amount_left matches deficit', new_order.amount_left == 2, tostring(new_order.amount_left))
end

-- ---------------------------------------------------------------- --
-- 5. Unplaced memorial slabs detection                             --
-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    local unplaced_slab = {
        engraving_type = w.df.slab_engraving_type.Memorial,
        topic = 303,
        flags = {forbid = false, in_job = false, in_building = false},
    }
    local placed_slab = {
        engraving_type = w.df.slab_engraving_type.Memorial,
        topic = 304,
        flags = {forbid = false, in_job = false, in_building = true},
    }
    w.df.global.world.items.other.SLAB:push(unplaced_slab)
    w.df.global.world.items.other.SLAB:push(placed_slab)

    local r = env.report()
    check('total memorialized slabs is 2', r.memorialized_slabs == 2, tostring(r.memorialized_slabs))
    check('unplaced memorials count is 1', r.unplaced_memorials == 1, tostring(r.unplaced_memorials))

    local unplaced_list = env.get_unplaced_slabs()
    check('get_unplaced_slabs returns exactly the unbuilt slab', #unplaced_list == 1 and unplaced_list[1].topic == 303,
          string.format("count=%d, topic=%s", #unplaced_list, tostring(unplaced_list[1] and unplaced_list[1].topic)))
end

print(string.format('\nResults: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

