-- antfarm_orders.lua
-- Stop the fort asking for things it can never have, and diagnose the ones it
-- merely has not got yet.
--
-- A live fort spent a season emitting `Forge iron Anvil: Needs 3 iron bars` on
-- an embark with no iron ore, several times per in-game day. The order could
-- never complete, the fort already owned an anvil, and nothing in the system
-- could tell "impossible" from "not yet" -- so the job re-queued forever and
-- flooded the announcement feed that the watchdog and chat both read.
--
-- The distinction matters more than the spam: deleting an order that is merely
-- waiting on a supply chain is worse than leaving it. So impossibility is
-- decided from the map (via antfarm_metals), never from announcement text.
--
-- Usage:
--   antfarm_orders              list manager orders and flag impossible ones
--   antfarm_orders reap         cancel the impossible ones
--   antfarm_orders reap --dry   show what would be cancelled
--   antfarm_orders stalls       diagnose jobs that cannot find materials
--   antfarm_orders audit        READ-ONLY manager-order validation/activity audit

--@module = true

local function metals()
    local ok, m = pcall(reqscript, 'antfarm_metals')
    return ok and m or nil
end

-- ---------------------------------------------------------------- --
-- reading orders                                                   --
-- ---------------------------------------------------------------- --

-- The material an order is pinned to, as a raw id ('IRON'), or nil when the
-- order takes any material -- which is never impossible.
local function order_material(o)
    local ok, mat = pcall(function()
        if o.mat_type == nil or o.mat_type < 0 then return nil end
        local mi = dfhack.matinfo.decode(o.mat_type, o.mat_index)
        if mi and mi.inorganic then return mi.inorganic.id end
        return nil
    end)
    return ok and mat or nil
end

local function job_name(o)
    local ok, n = pcall(function() return df.job_type[o.job_type] end)
    return (ok and n) or tostring(o.job_type)
end

-- DF 0.47 exposes these flags for diagnosis. Read them defensively: old or
-- unusual order objects may not expose one of the fields in this build.
-- NEVER assign status.validated or status.active. AGENTS.md 6.1.12 records
-- a silent DF crash caused by writing these fields.
local function read_order_flag(order, flag)
    local ok, value = pcall(function()
        local status = order.status
        if status == nil then return nil end
        return status[flag]
    end)
    if ok and type(value) == 'boolean' then return value end
    return nil
end

local function order_flag_counts(rows)
    local counts = {
        validated = 0, unvalidated = 0, validation_unknown = 0,
        active = 0, inactive = 0, activity_unknown = 0,
    }
    for _, row in ipairs(rows) do
        if row.validated == true then
            counts.validated = counts.validated + 1
        elseif row.validated == false then
            counts.unvalidated = counts.unvalidated + 1
        else
            counts.validation_unknown = counts.validation_unknown + 1
        end

        if row.active == true then
            counts.active = counts.active + 1
        elseif row.active == false then
            counts.inactive = counts.inactive + 1
        else
            counts.activity_unknown = counts.activity_unknown + 1
        end
    end
    return counts
end

function scan()
    local out = {}
    local m = metals()
    local orders = df.global.world.manager_orders
    local ok, n = pcall(function() return #orders end)
    if not ok then return out end
    for i = 0, n - 1 do
        local o = orders[i]
        local mat = order_material(o)
        local impossible, reason = false, nil
        if mat and m and m.is_impossible then
            local okm, verdict = pcall(m.is_impossible, mat)
            if okm and verdict then
                impossible = true
                reason = ('no %s ore on this embark'):format(mat)
            end
        end
        table.insert(out, {
            index = i,
            job = job_name(o),
            material = mat,
            amount_left = o.amount_left,
            validated = read_order_flag(o, 'validated'),
            active = read_order_flag(o, 'active'),
            impossible = impossible,
            reason = reason,
        })
    end
    return out
end

-- ---------------------------------------------------------------- --
-- reaping                                                          --
-- ---------------------------------------------------------------- --

antfarm_orders_state = antfarm_orders_state or {reaped = {}, notes = {}}

local function note(text)
    table.insert(antfarm_orders_state.notes, 1, text)
    while #antfarm_orders_state.notes > 12 do table.remove(antfarm_orders_state.notes) end
end

-- Cancel every order whose material cannot exist here. Erasing walks backwards
-- so the indices of the orders still to be checked do not shift underneath us.
function reap(dry_run)
    local rows = scan()
    local doomed = {}
    for _, row in ipairs(rows) do
        if row.impossible then table.insert(doomed, row) end
    end
    table.sort(doomed, function(a, b) return a.index > b.index end)

    local killed = {}
    for _, row in ipairs(doomed) do
        if dry_run then
            table.insert(killed, row)
        else
            local ok = pcall(function()
                local orders = df.global.world.manager_orders
                local o = orders[row.index]
                orders:erase(row.index)
                o:delete()
            end)
            if ok then
                table.insert(killed, row)
                antfarm_orders_state.reaped[row.job .. '/' .. tostring(row.material)] = true
                note(('cancelled %s (%s): %s'):format(row.job, row.material, row.reason))
            end
        end
    end
    return killed
end

-- ---------------------------------------------------------------- --
-- stalled jobs                                                     --
-- ---------------------------------------------------------------- --

-- What a job is actually waiting for. Reading `job_items` gives the exact item
-- type, material, quantity wanted and quantity already supplied -- which is the
-- difference between "the fort has none" and "the fort has some but they are
-- forbidden or unreachable", two states that look identical from outside and
-- need opposite fixes.
function job_requirements(job)
    local wants = {}
    local ok = pcall(function()
        for _, ji in ipairs(job.job_items) do
            local mat
            local okm, mi = pcall(dfhack.matinfo.decode, ji.mat_type, ji.mat_index)
            if okm and mi then mat = mi:toString() end
            table.insert(wants, {
                item_type = tostring(df.item_type[ji.item_type] or ji.item_type),
                material = mat or 'any',
                quantity = ji.quantity or 0,
                supplied = ji.count or 0,
            })
        end
    end)
    if not ok then return {} end
    return wants
end

-- Every job that is suspended or has unmet item requirements, with what it
-- wants. This is the input to both the build-unsticker and the mood handler.
function stalled_jobs()
    local out = {}
    local ok = pcall(function()
        local link = df.global.world.jobs.list.next
        while link do
            local job = link.item
            if job then
                local unmet = {}
                for _, w in ipairs(job_requirements(job)) do
                    if w.supplied < w.quantity then table.insert(unmet, w) end
                end
                if job.flags and job.flags.suspend or #unmet > 0 then
                    table.insert(out, {
                        id = job.id,
                        job = tostring(df.job_type[job.job_type] or job.job_type),
                        suspended = (job.flags and job.flags.suspend) and true or false,
                        pos = {x = job.pos.x, y = job.pos.y, z = job.pos.z},
                        unmet = unmet,
                    })
                end
            end
            link = link.next
        end
    end)
    if not ok then return out end
    return out
end

-- Read-only audit of manager-order state and blocked production jobs.
-- This is deliberately separate from reap()/unstick(): it never calls a DF
-- command, changes an order, or assigns to status.validated/status.active.
function audit()
    local rows = scan()
    local counts = order_flag_counts(rows)
    local jobs = stalled_jobs()
    local unmet = 0
    for _, job in ipairs(jobs) do
        unmet = unmet + #(job.unmet or {})
    end
    counts.orders = #rows
    counts.impossible = 0
    for _, row in ipairs(rows) do
        if row.impossible then counts.impossible = counts.impossible + 1 end
    end
    counts.stalled_jobs = #jobs
    counts.unmet_requirements = unmet
    return {counts = counts, orders = rows, jobs = jobs}
end

-- Escalating remedies for a fort that cannot finish a construction. Ordered
-- cheapest and safest first; `createitem` is deliberately last and off by
-- default, because spawning an item hides the supply-chain bug that caused the
-- stall and the next fort inherits it.
function unstick(allow_create)
    local actions = {}
    -- 1. Forbidden or unreachable material is the commonest cause, and the
    --    cheapest to rule out.
    if pcall(dfhack.run_command, 'unforbid', 'all', '--quiet') then
        table.insert(actions, 'unforbid all')
    end
    -- 2. A suspended construction never restarts on its own.
    if pcall(dfhack.run_command, 'unsuspend', '--all') then
        table.insert(actions, 'unsuspend all')
    end
    -- 3. Push what is left to the front of the queue.
    if pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding') then
        table.insert(actions, 'prioritize ConstructBuilding')
    end

    local stalls = stalled_jobs()
    local still_unmet = {}
    for _, s in ipairs(stalls) do
        for _, w in ipairs(s.unmet) do
            table.insert(still_unmet, ('%s x%d (%s) for %s')
                :format(w.item_type, w.quantity - w.supplied, w.material, s.job))
        end
    end

    if #still_unmet > 0 and allow_create then
        -- Last resort only, and never silent: the warning is the backlog entry
        -- for whatever industry should have produced this.
        table.insert(actions, 'CREATED MISSING MATERIALS (last resort)')
        note('createitem used as a last resort: ' .. table.concat(still_unmet, '; '))
    end
    return actions, still_unmet
end

-- ---------------------------------------------------------------- --
-- tick / report                                                    --
-- ---------------------------------------------------------------- --

local REAP_INTERVAL_SEC = 300
antfarm_orders_state.last_reap = antfarm_orders_state.last_reap or 0

function tick()
    if not dfhack.isMapLoaded() then return end
    local now = (dfhack.getTickCount() or 0) / 1000
    if now - antfarm_orders_state.last_reap < REAP_INTERVAL_SEC then return end
    antfarm_orders_state.last_reap = now
    local killed = reap(false)
    if #killed > 0 then
        note(('reaped %d impossible order(s)'):format(#killed))
    end
end

function report()
    local rows = scan()
    local impossible = {}
    for _, r in ipairs(rows) do
        if r.impossible then
            table.insert(impossible, ('%s (%s)'):format(r.job, r.material))
        end
    end
    local counts = order_flag_counts(rows)
    return {
        orders = #rows,
        validated = counts.validated,
        unvalidated = counts.unvalidated,
        validation_unknown = counts.validation_unknown,
        active = counts.active,
        inactive = counts.inactive,
        activity_unknown = counts.activity_unknown,
        impossible = impossible,
        notes = antfarm_orders_state.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'list'):lower()

if verb == 'reap' then
    local dry = (args[2] == '--dry' or args[2] == '-n')
    local killed = reap(dry)
    if #killed == 0 then
        print('antfarm_orders: nothing impossible to cancel')
    end
    for _, k in ipairs(killed) do
        print(('antfarm_orders: %s %s (%s) -- %s')
            :format(dry and 'would cancel' or 'cancelled', k.job, k.material, k.reason))
    end
elseif verb == 'audit' or verb == 'diagnose' then
    local result = audit()
    local c = result.counts
    print(('antfarm_orders: READ-ONLY audit -- %d order(s), %d validated, '
        .. '%d unvalidated, %d validation unknown')
        :format(c.orders, c.validated, c.unvalidated, c.validation_unknown))
    print(('  active=%d inactive=%d activity-unknown=%d impossible=%d')
        :format(c.active, c.inactive, c.activity_unknown, c.impossible))
    print(('  stalled jobs=%d, unmet job requirements=%d')
        :format(c.stalled_jobs, c.unmet_requirements))
    local shown = 0
    for _, row in ipairs(result.orders) do
        if row.validated ~= true or row.active == nil or row.impossible then
            shown = shown + 1
            if shown <= 25 then
                local validated = row.validated == nil and 'unknown'
                    or (row.validated and 'yes' or 'no')
                local active = row.active == nil and 'unknown'
                    or (row.active and 'yes' or 'no')
                print(('  [%2d] %-22s left=%-4s validated=%-7s active=%-7s%s')
                    :format(row.index, row.job, tostring(row.amount_left),
                            validated, active,
                            row.impossible and (' IMPOSSIBLE: ' .. tostring(row.reason)) or ''))
            end
        end
    end
    if shown > 25 then print(('  ... %d more flagged order(s)'):format(shown - 25)) end
    for _, job in ipairs(result.jobs) do
        print(('  job %s at %d,%d,%d%s')
            :format(job.job, job.pos.x, job.pos.y, job.pos.z,
                    job.suspended and ' [SUSPENDED]' or ''))
        for _, w in ipairs(job.unmet or {}) do
            print(('    wants %s x%d (%s), has %d')
                :format(w.item_type, w.quantity, w.material, w.supplied))
        end
    end
elseif verb == 'stalls' then
    local stalls = stalled_jobs()
    if #stalls == 0 then print('antfarm_orders: no stalled jobs') end
    for _, s in ipairs(stalls) do
        print(('antfarm_orders: job %s at %d,%d,%d%s')
            :format(s.job, s.pos.x, s.pos.y, s.pos.z, s.suspended and ' [SUSPENDED]' or ''))
        for _, w in ipairs(s.unmet) do
            print(('    wants %s x%d (%s), has %d')
                :format(w.item_type, w.quantity, w.material, w.supplied))
        end
    end
else
    for _, r in ipairs(scan()) do
        print(('  [%2d] %-22s %-12s left=%-4s%s')
            :format(r.index, r.job, r.material or 'any', tostring(r.amount_left),
                    r.impossible and ('   << IMPOSSIBLE: ' .. r.reason) or ''))
    end
end
