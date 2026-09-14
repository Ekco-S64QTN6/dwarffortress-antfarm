-- antfarm_lever.lua
-- Emergency lockdown: queue high-priority pull jobs on every lever whose name
-- marks it as a defensive control, so drawbridges and gates close the moment a
-- siege is announced.
--
-- Called by the Antfarm TUI (`command antfarm_lever`) when a threat shows up in
-- the announcement feed, and usable by hand from the DFHack console.
--
-- Usage:
--   antfarm_lever            pull every matching defence lever
--   antfarm_lever list       show what would be pulled, change nothing
--   antfarm_lever <word>...  use a custom set of name keywords

--@module = true

-- Job creation is delegated to the shipped `lever` script rather than being
-- hand-rolled here: building a df.job and linking it by hand is exactly the
-- kind of thing that segfaults DF when a field moves between versions.
--
-- Keywords are deliberately specific. The list used to include 'door', 'lock'
-- and 'raise', which match ordinary furniture: a lever named "Pantry Door" or
-- "Cold Storage Door" got a high-priority pull the moment a siege was
-- announced, sealing the fortress off from its own food. A lockdown that
-- starves the fort is worse than no lockdown.
--
-- To enrol a lever explicitly, name it with one of these words in-game
-- (q -> the lever -> N), e.g. "Main Gate" or "[defence] cistern floodgate".
local DEFAULT_KEYWORDS = {
    'gate', 'drawbridge', 'lockdown', 'portcullis',
    'defence', 'defense', 'floodgate', 'sealgate',
}

-- Words that used to be matched and no longer are. Reported by `list` so an
-- operator who relied on the old behaviour can see which levers dropped out.
local RETIRED_KEYWORDS = {'bridge', 'lock', 'seal', 'raise', 'door'}

local RECHECK_SEC = 30  -- don't re-queue the same lever more often than this

antfarm_lever_state = antfarm_lever_state or {last_pull = {}}

local function is_lever(bld)
    return bld:getType() == df.building_type.Trap
        and bld.trap_type == df.trap_type.Lever
end

local function lever_name(bld)
    local name = bld.name
    if not name or name == '' then return nil end
    local ok, conv = pcall(dfhack.df2utf, name)
    return (ok and conv) or name
end

local function matches(name, keywords)
    if not name then return false end
    local lowered = name:lower()
    for _, kw in ipairs(keywords) do
        if lowered:find(kw, 1, true) then return true end
    end
    return false
end

local function has_pending_pull(bld)
    -- AGENTS.md 6.1.4: building job vectors are 0-indexed DF vectors.
    for i = 0, #bld.jobs - 1 do
        local j = bld.jobs[i]
        if j and j.job_type == df.job_type.PullLever then return true end
    end
    return false
end

function find_defence_levers(keywords)
    local found = {}
    if not dfhack.isMapLoaded() then return found end
    local all = df.global.world.buildings.all
    for i = 0, #all - 1 do
        local bld = all[i]
        local ok, matched = pcall(function()
            return is_lever(bld) and matches(lever_name(bld), keywords)
        end)
        if ok and matched then
            table.insert(found, bld)
        end
    end
    return found
end

function lockdown(keywords, dry_run)
    keywords = keywords or DEFAULT_KEYWORDS
    if not dfhack.isMapLoaded() then
        dfhack.printerr('antfarm_lever: no map loaded')
        return 0
    end

    local levers = find_defence_levers(keywords)
    if #levers == 0 then
        print('antfarm_lever: no levers matched ' .. table.concat(keywords, '/'))
        print('  Name a lever in-game (q -> the lever -> N) to enrol it.')
        return 0
    end

    local now = os.time()
    local pulled = 0
    for _, bld in ipairs(levers) do
        local name = lever_name(bld) or ('lever #' .. bld.id)
        if dry_run then
            local state = has_pending_pull(bld) and 'pull already queued' or 'ready'
            print(string.format('  #%d %-28s @ %d,%d,%d  (%s)',
                bld.id, name, bld.centerx, bld.centery, bld.z, state))
        elseif has_pending_pull(bld) then
            -- Already on the job list; re-queueing would just pile up pulls.
        else
            local last = antfarm_lever_state.last_pull[bld.id] or 0
            if now - last >= RECHECK_SEC then
                local ok, err = pcall(dfhack.run_command, 'lever pull ' .. bld.id .. ' --high')
                if ok then
                    antfarm_lever_state.last_pull[bld.id] = now
                    pulled = pulled + 1
                    print(string.format('antfarm_lever: LOCKDOWN pull queued on %s (#%d)', name, bld.id))
                else
                    dfhack.printerr('antfarm_lever: failed to pull #' .. bld.id .. ': ' .. tostring(err))
                end
            end
        end
    end

    if not dry_run then
        print(string.format('antfarm_lever: %d/%d defence lever(s) triggered.', pulled, #levers))
    end
    return pulled
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
if args[1] == 'list' then
    print('antfarm_lever: defence levers on this map:')
    lockdown(DEFAULT_KEYWORDS, true)
    -- Show what the old, looser keyword set would also have pulled, so the
    -- change from 'door'/'lock'/'raise' is visible rather than silent.
    local extra = find_defence_levers(RETIRED_KEYWORDS)
    local shown = {}
    for _, bld in ipairs(find_defence_levers(DEFAULT_KEYWORDS)) do shown[bld.id] = true end
    local first = true
    for _, bld in ipairs(extra) do
        if not shown[bld.id] then
            if first then
                print('  not enrolled (name matches a retired keyword only -- rename it')
                print('   with gate/drawbridge/portcullis/floodgate/defence to include it):')
                first = false
            end
            print(string.format('    #%d %s', bld.id, lever_name(bld) or '?'))
        end
    end
elseif #args > 0 then
    lockdown(args, false)
else
    lockdown(DEFAULT_KEYWORDS, false)
end
