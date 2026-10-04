-- antfarm_checklist.lua
-- One command that answers "is this fort actually going to survive?"
--
-- WHY
--
-- Problems were being found by watching the game and noticing something wrong:
-- dwarves standing in the rain, sleeping on the floor, twelve drinks and no
-- still, four miners sharing two picks. Every one of those is cheap to detect
-- and was invisible until a human happened to look.
--
-- This is the systematic version. Each check is one thing a fort needs in order
-- not to die, in rough dependency order, with the command that fixes it. It
-- reads state only -- it never changes the fort -- so it is safe to run at any
-- time and on any schedule.
--
-- Usage:
--   antfarm_checklist           every check, grouped
--   antfarm_checklist fail      only what is wrong
--   antfarm_checklist <group>   survival | infrastructure | governance | health | hazards

--@module = true

local function mod(name)
    local ok, m = pcall(reqscript, name)
    if ok and type(m) == 'table' then return m end
    return nil
end

local function rep(name)
    local m = mod(name)
    if not m or not m.report then return nil end
    local ok, r = pcall(m.report)
    return ok and r or nil
end

local function citizens()
    local n = 0
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is then n = n + 1 end
    end
    return n
end

local function count_items(t)
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == t then n = n + 1 end
    end
    return n
end

local function count_buildings(btype, kind)
    local n = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == btype then
            if kind == nil then n = n + 1
            else
                local ok, t = pcall(function() return b.type end)
                if ok and t == kind then n = n + 1 end
            end
        end
    end
    return n
end

local function count_tool(subtype_id)
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        local t = it:getType()
        if t == df.item_type.WEAPON or t == df.item_type.TOOL then
            local ok, def = pcall(function() return it.subtype end)
            if ok and def and def.id == subtype_id then n = n + 1 end
        end
    end
    return n
end

local function zone_with(flag)
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Civzone then
            local ok, v = pcall(function() return b.zone_flags[flag] end)
            if ok and v then return b end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- --
-- the checks                                                       --
-- ---------------------------------------------------------------- --
-- Each returns ok, detail. `ok == nil` means "cannot tell yet", which is
-- reported as a warning rather than a failure: a fort three minutes old has not
-- failed to build a hospital.

local CHECKS = {
{group = 'survival', critical = true, name = 'drink stock',
 fix = 'antfarm_sustenance all', check = function()
    local pop, drink = citizens(), count_items(df.item_type.DRINK)
    if pop == 0 then return nil, 'no citizens' end
    local per = drink / pop
    return per >= 2, ('%d drink for %d citizens (%.1f each)'):format(drink, pop, per)
 end},

{group = 'survival', critical = true, name = 'booze production',
 fix = 'antfarm_sustenance workshops', check = function()
    local still = count_buildings(df.building_type.Workshop, df.workshop_type.Still)
    local plants = count_items(df.item_type.PLANT)
    local brew = 0
    pcall(function()
        for _, o in ipairs(df.global.world.manager_orders) do
            if o.job_type == df.job_type.CustomReaction then
                local ok, r = pcall(function() return o.reaction_name end)
                if ok and tostring(r):find('BREW') then brew = brew + o.amount_left end
            end
        end
    end)
    return still > 0 and plants > 0 and brew > 0,
        ('%d still(s), %d plants, %d brew order(s)'):format(still, plants, brew)
 end},

{group = 'survival', critical = true, name = 'food stock',
 fix = 'antfarm_sustenance all', check = function()
    local pop = citizens()
    if pop == 0 then return nil, 'no citizens' end
    local food = count_items(df.item_type.FOOD) + count_items(df.item_type.MEAT)
               + count_items(df.item_type.FISH) + count_items(df.item_type.PLANT)
               + count_items(df.item_type.CHEESE)
    return food >= pop * 2, ('%d edible item(s) for %d citizens'):format(food, pop)
 end},

{group = 'survival', critical = true, name = 'a bed for everyone',
 fix = 'antfarm_quarters beds', check = function()
    local r = rep('antfarm_quarters')
    if not r then return nil, 'quarters module unavailable' end
    return (r.beds or 0) >= (r.citizens or 0),
        ('%d bed(s) for %d citizens, %d owned'):format(r.beds or 0, r.citizens or 0, r.owned or 0)
 end},

{group = 'survival', critical = true, name = 'indoor meeting area',
 fix = 'antfarm_locations hall', check = function()
    local r = rep('antfarm_locations')
    local zone = zone_with('meeting_area')
    if not zone then return false, 'no meeting area at all' end
    local outside = false
    pcall(function()
        local b = dfhack.maps.getTileBlock(zone.x1, zone.y1, zone.z)
        if b then outside = b.designation[zone.x1 % 16][zone.y1 % 16].outside end
    end)
    return not outside,
        outside and ('meeting area is OUTSIDE at z=%d -- dwarves stand in the rain'):format(zone.z)
                 or ('indoors at z=%d'):format(zone.z)
 end},

{group = 'survival', critical = false, name = 'plant gathering',
 fix = 'antfarm_sustenance gather', check = function()
    local r = rep('antfarm_sustenance')
    if not r then return nil, 'sustenance module unavailable' end
    return r.gather_zone and (r.gather_shrubs or 0) > 0,
        r.gather_zone and ('zone with %d shrub(s)'):format(r.gather_shrubs or 0)
                      or 'no gathering zone'
 end},

{group = 'infrastructure', critical = false, name = 'farm plots',
 fix = 'let the build reach /farming2, or antfarm_sustenance workshops', check = function()
    local plots = count_buildings(df.building_type.FarmPlot)
    return plots > 0, ('%d farm plot(s)'):format(plots)
 end},

{group = 'infrastructure', critical = false, name = 'tools match the labour',
 fix = 'antfarm_sustenance labour', check = function()
    local picks = count_tool('ITEM_WEAPON_PICK')
    local axes = count_tool('ITEM_WEAPON_AXE_BATTLE')
    local miners = 0
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        if ok and is then
            local okl, has = pcall(function() return u.status.labors[df.unit_labor.MINE] end)
            if okl and has then miners = miners + 1 end
        end
    end
    return miners <= picks,
        ('%d pick(s), %d axe(s), %d dwarf/dwarves set to mine'):format(picks, axes, miners)
 end},

{group = 'infrastructure', critical = false, name = 'trade depot',
 fix = 'antfarm_trade depot', check = function()
    local r = rep('antfarm_trade')
    if not r then return nil, 'trade module unavailable' end
    return r.depot and true or false, r.depot and 'built or building' or 'none -- caravans cannot trade'
 end},

{group = 'infrastructure', critical = false, name = 'stockpiles',
 fix = 'the build does this at /surface2', check = function()
    local n = count_buildings(df.building_type.Stockpile)
    return n > 0, ('%d stockpile(s)'):format(n)
 end},

{group = 'governance', critical = false, name = 'key officers appointed',
 fix = 'antfarm_nobles appoint', check = function()
    local m = mod('antfarm_nobles')
    if not m or not m.positions then return nil, 'nobles module unavailable' end
    local ok, pos = pcall(m.positions)
    if not ok then return nil, 'could not read positions' end
    local want = {'MANAGER', 'BOOKKEEPER', 'BROKER', 'CHIEF_MEDICAL_DWARF'}
    local missing = {}
    for _, code in ipairs(want) do
        if not pos[code] or pos[code].histfig == -1 then table.insert(missing, code) end
    end
    return #missing == 0,
        #missing == 0 and 'manager, bookkeeper, broker, chief medical dwarf'
                      or ('vacant: ' .. table.concat(missing, ', '))
 end},

{group = 'governance', critical = false, name = 'military exists',
 fix = 'antfarm_military create, then antfarm_military enlist', check = function()
    local r = rep('antfarm_military')
    if not r then return nil, 'military module unavailable' end
    return (r.squads or 0) > 0,
        ('%d squad(s), %d soldier(s), uniform metal %s')
            :format(r.squads or 0, r.soldiers or 0, tostring(r.metal))
 end},

{group = 'governance', critical = false, name = 'justice: sheriff and a jail',
 fix = 'antfarm_nobles appoint (jail is still unimplemented)', check = function()
    local m = mod('antfarm_nobles')
    local sheriff = false
    if m and m.positions then
        local ok, pos = pcall(m.positions)
        if ok then
            sheriff = (pos.SHERIFF and pos.SHERIFF.histfig ~= -1)
                   or (pos.CAPTAIN_OF_THE_GUARD and pos.CAPTAIN_OF_THE_GUARD.histfig ~= -1)
        end
    end
    local chains = count_buildings(df.building_type.Chain)
    local cages = count_buildings(df.building_type.Cage)
    return sheriff and (chains + cages) > 0,
        ('sheriff %s, %d chain(s), %d cage(s)')
            :format(sheriff and 'yes' or 'VACANT', chains, cages)
 end},

{group = 'health', critical = false, name = 'burial capacity',
 fix = 'burial / antfarm_autoslab check', check = function()
    local coffins = count_buildings(df.building_type.Coffin)
    local r = rep('antfarm_autoslab')
    local ghosts = r and r.ghost_count or 0
    return coffins > 0 or ghosts == 0,
        ('%d coffin(s), %d ghost(s)'):format(coffins, ghosts)
 end},

{group = 'health', critical = false, name = 'water source',
 fix = 'dig a cistern or build a well', check = function()
    local wells = count_buildings(df.building_type.Well)
    local zone = zone_with('water_source')
    return wells > 0 or zone ~= nil,
        ('%d well(s), %s water-source zone'):format(wells, zone and 'a' or 'no')
 end},

{group = 'hazards', critical = true, name = 'no impossible work orders',
 fix = 'antfarm_orders reap', check = function()
    local r = rep('antfarm_orders')
    if not r then return nil, 'orders module unavailable' end
    local n = #(r.impossible or {})
    return n == 0, n == 0 and ('%d order(s), none impossible'):format(r.orders or 0)
                          or ('impossible: ' .. table.concat(r.impossible, ', '))
 end},

{group = 'hazards', critical = false, name = 'defence at the entrance',
 fix = 'antfarm_defence traps && antfarm_defence dogs', check = function()
    local r = rep('antfarm_defence')
    if not r then return nil, 'defence module unavailable' end
    return (r.cage_traps or 0) > 0 or (r.restraints or 0) > 0,
        ('%d cage trap(s), %d restraint(s), %d dog(s)')
            :format(r.cage_traps or 0, r.restraints or 0, r.dogs or 0)
 end},

{group = 'hazards', critical = false, name = 'lockdown lever',
 fix = 'name a lever with "gate" or "drawbridge"', check = function()
    local m = mod('antfarm_lever')
    if not m or not m.find_defence_levers then return nil, 'lever module unavailable' end
    local ok, levers = pcall(m.find_defence_levers)
    if not ok then return nil, 'could not scan levers' end
    return #levers > 0, ('%d defence lever(s)'):format(#levers)
 end},

{group = 'hazards', critical = false, name = 'metals the fort can actually use',
 fix = 'antfarm_trade (iron may only be tradeable)', check = function()
    local r = rep('antfarm_metals')
    if not r then return nil, 'metals module unavailable' end
    return r.martial ~= nil,
        ('best martial metal %s; missing %s')
            :format(tostring(r.martial), table.concat(r.missing or {}, ', '))
 end},
}

local GROUP_ORDER = {'survival', 'infrastructure', 'governance', 'health', 'hazards'}

function run(only_group, only_fail)
    local rows = {}
    for _, c in ipairs(CHECKS) do
        if not only_group or c.group == only_group then
            local ok, detail = nil, 'check raised'
            local safe, a, b = pcall(c.check)
            if safe then ok, detail = a, b end
            local status = (ok == true) and 'PASS'
                or (ok == nil) and 'WARN'
                or (c.critical and 'FAIL' or 'TODO')
            if not only_fail or status == 'FAIL' or status == 'TODO' then
                table.insert(rows, {group = c.group, name = c.name, status = status,
                                    detail = detail, fix = c.fix})
            end
        end
    end
    return rows
end

function report()
    local rows = run(nil, false)
    local tally = {PASS = 0, FAIL = 0, TODO = 0, WARN = 0}
    local failing = {}
    for _, r in ipairs(rows) do
        tally[r.status] = (tally[r.status] or 0) + 1
        if r.status == 'FAIL' then table.insert(failing, r.name) end
    end
    return {
        pass = tally.PASS, fail = tally.FAIL, todo = tally.TODO, warn = tally.WARN,
        failing = failing,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local arg1 = (args[1] or ''):lower()
local only_fail = (arg1 == 'fail' or arg1 == 'failed')
local group = nil
for _, g in ipairs(GROUP_ORDER) do if arg1 == g then group = g end end

local rows = run(group, only_fail)
local by_group = {}
for _, r in ipairs(rows) do
    by_group[r.group] = by_group[r.group] or {}
    table.insert(by_group[r.group], r)
end

print('antfarm_checklist: can this fort survive?')
for _, g in ipairs(GROUP_ORDER) do
    if by_group[g] then
        print('')
        print('  [' .. g:upper() .. ']')
        for _, r in ipairs(by_group[g]) do
            print(('   %-5s %-28s %s'):format(r.status, r.name, tostring(r.detail)))
            if r.status == 'FAIL' or r.status == 'TODO' then
                print(('         fix: %s'):format(r.fix))
            end
        end
    end
end
local t = report()
print('')
print(('  %d pass, %d FAIL, %d todo, %d unknown'):format(t.pass, t.fail, t.todo, t.warn))
