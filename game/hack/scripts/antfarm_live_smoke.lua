-- antfarm_live_smoke.lua
--
-- Opt-in, READ-ONLY live-game evidence capture for an operator-designated
-- disposable fortress. This script never runs a repair, order, placement,
-- assignment, blueprint, nickname, pause, or camera command.
--
-- The Python launcher requires both a marker file in the selected save folder
-- and an explicit operator confirmation before it invokes this script.
--
-- Usage:
--   dfhack-run antfarm_live_smoke <32-character-hex-run-id>
--
-- Output is a small aggregate-only report in the DF installation directory:
--   antfarm_live_smoke_<run-id>.txt
--
-- Keep this diagnostic separate from the offline test suite. See README.md and
-- docs/ROADMAP.md for the disposable-save workflow.

--@module = true

local args = {...}
local run_id = tostring(args[1] or '')
if #run_id ~= 32 or not run_id:match('^[0-9a-f]+$') then
    qerror('antfarm_live_smoke: expected a 32-character lowercase hex run id')
end

local rows = {
    'format=antfarm-live-smoke-v1',
    'run_id=' .. run_id,
}
local function clean(value)
    return tostring(value == nil and 'unknown' or value)
        :gsub('[\r\n\t]', ' ')
        :gsub('=', ':')
end
local function put(key, value)
    table.insert(rows, key .. '=' .. clean(value))
end
local function put_error(prefix, err)
    put(prefix .. '_status', 'error')
    put(prefix .. '_error', err)
end
local function module_report(name, method)
    local ok, mod = pcall(reqscript, name)
    if not ok or type(mod) ~= 'table' then
        return nil, 'could not load ' .. name .. ': ' .. tostring(mod)
    end
    if type(mod[method]) ~= 'function' then
        return nil, name .. ' does not export ' .. method .. '()'
    end
    local ok_report, value = pcall(mod[method])
    if not ok_report or type(value) ~= 'table' then
        return nil, name .. '.' .. method .. ' failed: ' .. tostring(value)
    end
    return value
end

local ok_map, map_loaded = pcall(dfhack.isMapLoaded)
map_loaded = ok_map and map_loaded == true
put('map_loaded', map_loaded)

if map_loaded then
    -- This audit is explicitly read-only. It only reads manager-order flags,
    -- job requirements and manager-office readiness; it never writes them.
    local audit, audit_error = module_report('antfarm_orders', 'audit')
    if audit then
        local c = audit.counts or {}
        put('orders_status', 'ok')
        put('orders_total', c.orders or 0)
        put('orders_validated', c.validated or 0)
        put('orders_unvalidated', c.unvalidated or 0)
        put('orders_validation_unknown', c.validation_unknown or 0)
        put('orders_active', c.active or 0)
        put('orders_inactive', c.inactive or 0)
        put('orders_activity_unknown', c.activity_unknown or 0)
        put('orders_impossible', c.impossible or 0)
        put('orders_stalled_jobs', c.stalled_jobs or 0)
        put('orders_unmet_requirements', c.unmet_requirements or 0)
        put('manager_office_status',
            audit.manager_office and audit.manager_office.status or 'unknown')
        put('manager_office_citizens',
            audit.manager_office and audit.manager_office.citizens or 'unknown')
    else
        put_error('orders', audit_error)
    end

    -- report() only counts existing beds/rooms/furniture. It does not place,
    -- define, assign, or order any item.
    local housing, housing_error = module_report('antfarm_quarters', 'report')
    if housing then
        put('quarters_status', 'ok')
        put('citizens', housing.citizens or 0)
        put('beds', housing.beds or 0)
        put('bedrooms_defined', housing.rooms or 0)
        put('beds_owned', housing.owned or 0)
        put('unhoused', housing.unhoused or 0)
        put('doors', housing.doors or 0)
        put('chests', housing.chests or 0)
        put('cabinets', housing.cabinets or 0)
    else
        put_error('quarters', housing_error)
    end

    -- The checklist's report() is a read-only aggregation of module reports
    -- and direct state counts. Do not call its command-line repair suggestions.
    local checks, checks_error = module_report('antfarm_checklist', 'report')
    if checks then
        put('checklist_status', 'ok')
        put('checklist_pass', checks.pass or 0)
        put('checklist_fail', checks.fail or 0)
        put('checklist_todo', checks.todo or 0)
        put('checklist_warn', checks.warn or 0)
    else
        put_error('checklist', checks_error)
    end

    put('game_year', df.global.cur_year or 0)
    put('game_paused', df.global.pause_state == true)
    local ok_df, df_version = pcall(dfhack.getDFVersion)
    if ok_df then put('df_version', df_version) end
    local ok_dfhack, dfhack_version = pcall(dfhack.getDFHackVersion)
    if ok_dfhack then put('dfhack_version', dfhack_version) end
else
    put('orders_status', 'not_run')
    put('quarters_status', 'not_run')
    put('checklist_status', 'not_run')
end

local ok_path, df_path = pcall(dfhack.getDFPath)
if not ok_path or type(df_path) ~= 'string' or df_path == '' then
    qerror('antfarm_live_smoke: dfhack.getDFPath() did not return the DF root')
end
local filename = df_path .. '/antfarm_live_smoke_' .. run_id .. '.txt'
local temporary = filename .. '.tmp'
local file, open_error = io.open(temporary, 'w')
if not file then
    qerror('antfarm_live_smoke: cannot open report file: ' .. tostring(open_error))
end

file:write(table.concat(rows, '\n'), '\n')
file:flush()
file:close()

local renamed, rename_error = os.rename(temporary, filename)
if not renamed then
    os.remove(temporary)
    qerror('antfarm_live_smoke: cannot publish report file: ' .. tostring(rename_error))
end

print('antfarm_live_smoke: wrote read-only report ' .. filename)
