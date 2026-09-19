-- antfarm_metals.lua
-- What metals this embark can actually produce.
--
-- The fort spent an in-game season cancelling `Forge iron Anvil: Needs 3 iron
-- bars` on a map with no iron ore on it. Nothing could ever satisfy that job,
-- but nothing knew that either: the orders libraries are imported wholesale and
-- assume a normal embark. This module answers the question once, from the raws
-- and the map, so every other subsystem can stop guessing.
--
-- Usage:
--   antfarm_metals              report what this embark can smelt
--   antfarm_metals <METAL>      is this metal obtainable? (exit text only)

--@module = true

-- Cached: walking every map block is far too heavy to repeat on a tick, and the
-- answer cannot change without a new embark.
antfarm_metals_cache = antfarm_metals_cache or nil

-- Ores that look like iron and are not. PYRITE and MARCASITE carry no
-- `metal_ore` entry in this build, so they are excluded by the scan itself --
-- they are named here only so the report can say *why* an iron-looking embark
-- yields no iron.
local IRON_DECOYS = {PYRITE = true, MARCASITE = true}

-- Metals a fort is expected to want. Anything absent from the survey but
-- present here is reported as a gap rather than silently omitted.
local WANTED = {'IRON', 'COPPER', 'TIN', 'ZINC', 'SILVER', 'GOLD', 'LEAD',
                'NICKEL', 'PLATINUM', 'ALUMINUM'}

-- Alloys worth knowing about, since an embark with no iron may still arm itself.
-- {alloy = {required component metals}}
local ALLOYS = {
    BRONZE      = {'COPPER', 'TIN'},
    BRASS       = {'COPPER', 'ZINC'},
    BILLON      = {'COPPER', 'SILVER'},
    ELECTRUM    = {'GOLD', 'SILVER'},
    STERLING_SILVER = {'SILVER', 'COPPER'},
    -- Steel needs iron, so it is unobtainable wherever iron is.
    STEEL       = {'IRON'},
    PIG_IRON    = {'IRON'},
}

-- Which inorganics yield which metals, straight out of the raws rather than a
-- hardcoded table -- mods change this, and a wrong answer here is worse than no
-- answer.
local function ore_yields()
    local yields = {}
    for i = 0, #df.global.world.raws.inorganics - 1 do
        local r = df.global.world.raws.inorganics[i]
        local ok = pcall(function()
            if #r.metal_ore.mat_index > 0 then
                local metals = {}
                for j = 0, #r.metal_ore.mat_index - 1 do
                    local mi = dfhack.matinfo.decode(0, r.metal_ore.mat_index[j])
                    if mi and mi.inorganic then table.insert(metals, mi.inorganic.id) end
                end
                if #metals > 0 then yields[r.id] = metals end
            end
        end)
        if not ok then yields[r.id] = nil end
    end
    return yields
end

-- Walk every mineral event on the map once. This is the expensive part (a few
-- seconds on a large embark) and is why the result is cached for the session.
function survey(force)
    if antfarm_metals_cache and not force then return antfarm_metals_cache end

    local yields = ore_yields()
    local ores, decoys = {}, {}

    for _, block in ipairs(df.global.world.map.map_blocks) do
        for _, ev in ipairs(block.block_events) do
            local ok = pcall(function()
                if ev:getType() ~= df.block_square_event_type.mineral then return end
                local mi = dfhack.matinfo.decode(0, ev.inorganic_mat)
                if not (mi and mi.inorganic) then return end
                local id = mi.inorganic.id
                local z = block.map_pos.z
                local bucket
                if yields[id] then
                    bucket = ores
                elseif IRON_DECOYS[id] then
                    bucket = decoys
                else
                    return
                end
                local e = bucket[id]
                if not e then
                    e = {blocks = 0, min_z = 99999, max_z = -1}
                    bucket[id] = e
                end
                e.blocks = e.blocks + 1
                if z < e.min_z then e.min_z = z end
                if z > e.max_z then e.max_z = z end
            end)
            if not ok then break end
        end
    end

    -- Fold ores up into metals: a metal is available if any ore yielding it is
    -- on the map. Keep the ore list so the mining module knows where to dig.
    local metals = {}
    for ore, info in pairs(ores) do
        for _, metal in ipairs(yields[ore]) do
            local m = metals[metal]
            if not m then
                m = {blocks = 0, min_z = 99999, max_z = -1, ores = {}}
                metals[metal] = m
            end
            m.blocks = m.blocks + info.blocks
            if info.min_z < m.min_z then m.min_z = info.min_z end
            if info.max_z > m.max_z then m.max_z = info.max_z end
            table.insert(m.ores, {ore = ore, blocks = info.blocks,
                                  min_z = info.min_z, max_z = info.max_z})
        end
    end

    local missing = {}
    for _, metal in ipairs(WANTED) do
        if not metals[metal] then table.insert(missing, metal) end
    end

    -- An alloy is makeable only if every component metal is on the map.
    local alloys = {}
    for alloy, parts in pairs(ALLOYS) do
        local ok = true
        for _, part in ipairs(parts) do
            if not metals[part] then ok = false break end
        end
        alloys[alloy] = ok
    end

    antfarm_metals_cache = {
        metals = metals,
        missing = missing,
        alloys = alloys,
        decoys = decoys,
        surveyed = true,
    }
    return antfarm_metals_cache
end

-- The question every other module actually asks.
function can_make(metal)
    if not metal then return false end
    local s = survey()
    local up = tostring(metal):upper()
    if s.metals[up] then return true end
    -- Alloys are not ores; answer those from the alloy table.
    if s.alloys[up] ~= nil then return s.alloys[up] end
    return false
end

-- True when we are confident the fort can NEVER produce this metal locally.
-- Deliberately conservative: an unknown name is not reported as impossible,
-- because deleting a work order on a guess is worse than leaving it.
function is_impossible(metal)
    if not metal then return false end
    local s = survey()
    local up = tostring(metal):upper()
    if s.metals[up] then return false end
    if s.alloys[up] ~= nil then return not s.alloys[up] end
    for _, known in ipairs(WANTED) do
        if known == up then return true end
    end
    return false
end

-- The best armour/weapon metal this embark can actually reach, so the military
-- module does not queue a uniform the fort can never forge.
local MARTIAL_PREFERENCE = {'STEEL', 'IRON', 'BRONZE', 'BRASS', 'COPPER'}

function best_martial_metal()
    for _, metal in ipairs(MARTIAL_PREFERENCE) do
        if can_make(metal) then return metal end
    end
    return nil
end

function report()
    local ok, s = pcall(survey)
    if not ok or not s then return nil end
    local available, missing = {}, {}
    for metal, info in pairs(s.metals) do
        table.insert(available, {metal = metal, blocks = info.blocks,
                                 min_z = info.min_z, max_z = info.max_z})
    end
    table.sort(available, function(a, b) return a.blocks > b.blocks end)
    for _, m in ipairs(s.missing) do table.insert(missing, m) end
    local alloys = {}
    for alloy, makeable in pairs(s.alloys) do
        if makeable then table.insert(alloys, alloy) end
    end
    table.sort(alloys)
    return {
        available = available,
        missing = missing,
        alloys = alloys,
        martial = best_martial_metal(),
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
if args[1] then
    local metal = args[1]:upper()
    print(('antfarm_metals: %s -- %s'):format(metal,
        can_make(metal) and 'obtainable on this embark'
        or (is_impossible(metal) and 'IMPOSSIBLE: no ore on this map'
            or 'unknown metal')))
    return
end

local s = survey(true)
print('antfarm_metals: metal-bearing ore on this embark')
local rows = {}
for metal, info in pairs(s.metals) do table.insert(rows, {metal, info}) end
table.sort(rows, function(a, b) return a[2].blocks > b[2].blocks end)
for _, row in ipairs(rows) do
    local ores = {}
    for _, o in ipairs(row[2].ores) do table.insert(ores, o.ore) end
    print(('  %-10s blocks=%-6d z %d..%d   from %s')
        :format(row[1], row[2].blocks, row[2].min_z, row[2].max_z,
                table.concat(ores, ', ')))
end
if #s.missing > 0 then
    print('  MISSING (cannot be smelted here): ' .. table.concat(s.missing, ', '))
end
for ore, info in pairs(s.decoys) do
    print(('  note: %s is present (%d blocks) but yields no metal in this build')
        :format(ore, info.blocks))
end
local alloys = {}
for alloy, makeable in pairs(s.alloys) do
    if makeable then table.insert(alloys, alloy) end
end
table.sort(alloys)
print('  alloys available: ' .. (#alloys > 0 and table.concat(alloys, ', ') or 'none'))
print('  best martial metal: ' .. (best_martial_metal() or 'NONE -- trade for arms'))
