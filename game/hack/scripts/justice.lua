local argparse = require('argparse')

-- 0.47 compatibility shims. Upstream targets DFHack v50, where these exist;
-- on this build they do not, and the script raised before doing any work.
--   plotinfo          -> ui                    (field renamed in v50)
--   getCitizens()     -> isCitizen/isActive loop
--   getReadableName() -> TranslateName(getVisibleName())
local function fort_citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        local ok, is = pcall(dfhack.units.isCitizen, u)
        local ok_alive, alive = pcall(dfhack.units.isActive, u)
        if ok and is and (not ok_alive or alive) then table.insert(out, u) end
    end
    return out
end

local function readable_name(unit)
    local ok, vis = pcall(dfhack.units.getVisibleName, unit)
    if ok and vis then
        local ok2, t = pcall(dfhack.TranslateName, vis)
        if ok2 and t and t ~= '' then return t end
    end
    return 'unit #' .. tostring(unit and unit.id or '?')
end


local TICKS_PER_SEASON_TICK = 10
local TICKS_PER_DAY = 1200

local function list_convicts()
    local found = false
    for _,punishment in ipairs(df.global.ui.punishments) do
        local unit = df.unit.find(punishment.criminal)
        if unit and punishment.prison_counter > 0 then
            found = true
            local days = math.ceil((punishment.prison_counter * TICKS_PER_SEASON_TICK) / TICKS_PER_DAY)
            print(('%s (id: %d): serving a sentence of %d day(s)'):format(
                readable_name(unit), unit.id, days))
        end
    end
    if not found then
        print('No criminals currently serving sentences.')
    end
end

local function pardon_unit(unit)
    for _,punishment in ipairs(df.global.ui.punishments) do
        if punishment.criminal == unit.id then
            punishment.prison_counter = 0
            return
        end
    end
    qerror('Unit is not currently serving a sentence!')
end

local function command_pardon(unit_id)
    local unit = nil
    if not unit_id then
        unit = dfhack.gui.getSelectedUnit(true)
        if not unit then qerror('No unit selected!') end
    else
        unit = df.unit.find(unit_id)
        if not unit then qerror(('No unit with id %d'):format(unit_id)) end
    end
    pardon_unit(unit)
end

local unit_id = nil

local positionals = argparse.processArgsGetopt({...},
    {
        {'u', 'unit', hasArg=true,
            handler=function(optarg) unit_id = argparse.nonnegativeInt(optarg, 'unit') end},
    }
)

local command = positionals[1]

if command == 'pardon' then
    command_pardon(unit_id)
elseif not command or command == 'list' then
    list_convicts()
else
    qerror(('Unrecognised command: %s'):format(command))
end
