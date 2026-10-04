-- antfarm_autoslab.lua

-- dfhack.units.getReadableName is a v50 addition; on this 0.47 build it is nil
-- and raises. This path only runs when there is actually something to name, so
-- it stayed latent until a ghost (or a shuffled prayer target) appeared.
local function readable_name(unit)
    local ok, vis = pcall(dfhack.units.getVisibleName, unit)
    if ok and vis then
        local ok2, t = pcall(dfhack.TranslateName, vis)
        if ok2 and t and t ~= '' then return t end
    end
    return 'unit #' .. tostring(unit and unit.id or '?')
end

-- Automatically queue orders to carve memorial slabs for ghosts before tantrums occur.
--
-- DFHack 0.47 does not have an autoslab plugin. When dwarves die with unreachable
-- or destroyed remains (in caverns, deep water, magma, or on raids), they return
-- as ghosts, terrifying civilians, causing severe negative thoughts, and
-- inflicting physical harm. Memorializing them on an engraved slab lays their
-- spirit to rest immediately.
--
-- Ported from upstream DFHack autoslab.cpp logic directly to pure Lua.
--
-- Usage:
--   antfarm_autoslab             status report of ghosts, slabs, and orders
--   antfarm_autoslab check       queue slab orders for all active ghosts
--   antfarm_autoslab craft       ensure blank slabs are in stock for engraving

--@module = true

local function get_ghosts()
    local ghosts = {}
    if not df.global.world or not df.global.world.units then return ghosts end
    local units = df.global.world.units.all or df.global.world.units.active
    if not units then return ghosts end

    for i = 0, #units - 1 do
        local u = units[i]
        -- `flags3.bits.ghostly` is a v50 shape and raises here (AGENTS.md
        -- 6.1.11: prefer dfhack.units.* over raw flag access -- the API helpers
        -- are stable across versions, the bitfields are not). This errored on
        -- every scheduled run.
        local ok_ghost, is_ghost = pcall(dfhack.units.isGhost, u)
        is_ghost = ok_ghost and is_ghost or false

        if is_ghost and u.hist_figure_id and u.hist_figure_id ~= -1 then
            local name = "Unknown Ghost"
            pcall(function()
                name = readable_name(u)
            end)
            table.insert(ghosts, {
                unit = u,
                hist_figure_id = u.hist_figure_id,
                name = name
            })
        end
    end
    return ghosts
end

local function get_slab_data()
    local memorial_topics = {}
    local blank_count = 0
    if not df.global.world or not df.global.world.items or not df.global.world.items.other then
        return memorial_topics, blank_count
    end

    local slabs = df.global.world.items.other.SLAB
    if not slabs then return memorial_topics, blank_count end

    for i = 0, #slabs - 1 do
        local slab = slabs[i]
        local is_memorial = false
        pcall(function()
            if slab.engraving_type == df.slab_engraving_type.Memorial then
                is_memorial = true
                if slab.topic and slab.topic ~= -1 then
                    memorial_topics[slab.topic] = true
                end
            end
        end)
        if not is_memorial and not slab.flags.forbid and not slab.flags.in_job then
            blank_count = blank_count + 1
        end
    end
    return memorial_topics, blank_count
end

local function get_existing_orders()
    local engrave_orders = {}
    local craft_slab_orders = 0
    if not df.global.world or not df.global.world.manager_orders then
        return engrave_orders, craft_slab_orders
    end

    local orders = df.global.world.manager_orders
    for i = 0, #orders - 1 do
        local o = orders[i]
        if o.job_type == df.job_type.EngraveSlab then
            if o.hist_figure_id and o.hist_figure_id ~= -1 then
                engrave_orders[o.hist_figure_id] = o.id
            end
        elseif o.job_type == df.job_type.ConstructSlab then
            craft_slab_orders = craft_slab_orders + (o.amount_left or 1)
        end
    end
    return engrave_orders, craft_slab_orders
end

function ensure_blank_slabs(needed)
    local _, blank_count = get_slab_data()
    local _, craft_orders = get_existing_orders()
    local deficit = (needed or 1) - (blank_count + craft_orders)
    if deficit <= 0 then return 0 end

    local order = df.manager_order:new()
    order.id = df.global.world.manager_order_next_id
    df.global.world.manager_order_next_id = df.global.world.manager_order_next_id + 1
    order.job_type = df.job_type.ConstructSlab
    order.item_type = df.item_type.SLAB
    order.item_subtype = -1
    order.mat_type = -1
    order.mat_index = -1
    order.amount_left = deficit
    order.amount_total = deficit
    order.frequency = df.manager_order.T_frequency.OneTime
    df.global.world.manager_orders:insert('#', order)
    return deficit
end

function auto_engrave()
    local ghosts = get_ghosts()
    local memorial_topics, blank_count = get_slab_data()
    local engrave_orders, _ = get_existing_orders()

    local queued = {}
    for _, ghost in ipairs(ghosts) do
        local hf_id = ghost.hist_figure_id
        if not memorial_topics[hf_id] and not engrave_orders[hf_id] then
            local order = df.manager_order:new()
            order.id = df.global.world.manager_order_next_id
            df.global.world.manager_order_next_id = df.global.world.manager_order_next_id + 1
            order.job_type = df.job_type.EngraveSlab
            order.hist_figure_id = hf_id
            order.amount_left = 1
            order.amount_total = 1
            order.frequency = df.manager_order.T_frequency.OneTime

            df.global.world.manager_orders:insert('#', order)
            engrave_orders[hf_id] = order.id
            table.insert(queued, ghost.name)
        end
    end

    if #queued > 0 then
        ensure_blank_slabs(#queued)
    end

    return queued
end

function get_unplaced_slabs()
    local unplaced = {}
    if not df.global.world or not df.global.world.items or not df.global.world.items.other then
        return unplaced
    end
    local slabs = df.global.world.items.other.SLAB
    if not slabs then return unplaced end

    for i = 0, #slabs - 1 do
        local slab = slabs[i]
        local is_memorial = false
        pcall(function()
            if slab.engraving_type == df.slab_engraving_type.Memorial and slab.topic and slab.topic ~= -1 then
                is_memorial = true
            end
        end)
        local in_bld = slab.flags and slab.flags.in_building
        local in_job = slab.flags and slab.flags.in_job
        local forbid = slab.flags and slab.flags.forbid
        if is_memorial and not in_bld and not in_job and not forbid then
            table.insert(unplaced, slab)
        end
    end
    return unplaced
end

local function find_slab_tile()
    if not df.global.world or not df.global.world.map then return nil end
    local cx, cy, z = nil, nil, nil
    local bp_ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if bp_ok and bp and bp.plan and bp.plan.anchor then
        cx, cy = bp.plan.anchor.x, bp.plan.anchor.y
        if bp.plan.levels and bp.plan.levels.suites then
            z = bp.plan.levels.suites
        elseif bp.plan.levels and bp.plan.levels.surface then
            z = bp.plan.levels.surface
        end
    end
    if not z and df.global.cursor and df.global.cursor.x ~= -1 then
        cx, cy, z = df.global.cursor.x, df.global.cursor.y, df.global.cursor.z
    end
    if not z or not cx or not cy then return nil end

    for r = 1, 25 do
        for dx = -r, r do
            for dy = -r, r do
                local pos = {x = cx + dx, y = cy + dy, z = z}
                local tt_ok, tt = pcall(dfhack.maps.getTileType, pos)
                if tt_ok and tt and df.tiletype.attrs[tt] and df.tiletype.attrs[tt].shape == df.tiletype_shape.Floor then
                    local occ_ok, occ = pcall(dfhack.maps.getTileOccupancy, pos)
                    if occ_ok and occ and not occ.building and not occ.unit then
                        local bld_ok, bld = pcall(dfhack.buildings.findAtTile, pos)
                        if bld_ok and not bld then
                            return pos
                        end
                    end
                end
            end
        end
    end
    return nil
end

function place_memorial_slabs()
    local unplaced = get_unplaced_slabs()
    if #unplaced == 0 then return 0 end

    local placed_count = 0
    for _, slab in ipairs(unplaced) do
        local pos = find_slab_tile()
        if not pos then break end

        local ok, bld = pcall(dfhack.buildings.constructBuilding, {
            type = df.building_type.Slab,
            pos = pos,
            items = {slab}
        })
        if ok and bld then
            placed_count = placed_count + 1
            if slab.flags then slab.flags.in_job = true end
        end
    end

    if placed_count > 0 then
        pcall(dfhack.run_command, 'prioritize', '-a', 'ConstructBuilding')
    end
    return placed_count
end

function report()
    local ghosts = get_ghosts()
    local memorial_topics, blank_count = get_slab_data()
    local engrave_orders, craft_orders = get_existing_orders()
    local unplaced = get_unplaced_slabs()

    local memorialized = 0
    for _ in pairs(memorial_topics) do memorialized = memorialized + 1 end

    local pending = 0
    for _ in pairs(engrave_orders) do pending = pending + 1 end

    return {
        ghost_count = #ghosts,
        memorialized_slabs = memorialized,
        blank_slabs = blank_count,
        unplaced_memorials = #unplaced,
        pending_engrave_orders = pending,
        pending_craft_orders = craft_orders
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'check'):lower()

if verb == 'status' or verb == 'report' then
    local r = report()
    print(string.format('antfarm_autoslab: %d active ghost(s), %d blank slab(s), %d unplaced memorial(s), %d pending engrave order(s)',
          r.ghost_count, r.blank_slabs, r.unplaced_memorials, r.pending_engrave_orders))
elseif verb == 'check' or verb == 'engrave' then
    local queued = auto_engrave()
    local placed = place_memorial_slabs()
    if #queued == 0 and placed == 0 then
        print('antfarm_autoslab: no unhandled ghosts or unplaced slabs found')
    else
        for _, name in ipairs(queued) do
            print('antfarm_autoslab: queued memorial slab for ghost: ' .. name)
        end
        if placed > 0 then
            print(string.format('antfarm_autoslab: placed %d memorial slab building(s)', placed))
        end
    end
elseif verb == 'place' then
    local placed = place_memorial_slabs()
    print(string.format('antfarm_autoslab: placed %d memorial slab building(s)', placed))
elseif verb == 'craft' then
    local queued = ensure_blank_slabs(tonumber(args[2]) or 5)
    print(string.format('antfarm_autoslab: queued %d blank slab order(s)', queued))
else
    print('usage: antfarm_autoslab [status|check|place|craft]')
end

