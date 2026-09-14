-- antfarm_server.lua
-- Antfarm IPC bridge: streams fortress/citizen state out of DF and accepts
-- camera + automation commands from the Antfarm TUI (app/tui.py).
--
-- Transport is file-based and atomic by default:
--   antfarm_state.json   written by us every POLL_MS (tmp file + rename)
--   antfarm_cmd/*.json   one command per file, written by the client, eaten here
--   antfarm_cmd.json     legacy single-command file, still honoured
--
-- Usage:
--   antfarm_server start | stop | status
--
-- See AGENTS.md section 6.1 before editing: the DFHack API gotchas listed there
-- are all load-bearing here (0-indexed vectors, TranslateName(nil), timing).

--@module = true

local STATE_FILE = 'antfarm_state.json'
local CMD_DIR    = 'antfarm_cmd'
local CMD_FILE   = 'antfarm_cmd.json'   -- legacy single-shot channel
-- dfhack.timeout accepts only 'frames', 'ticks', 'days', 'months' and 'years'
-- in this build -- there is no real-time unit (verified by probe; an earlier
-- 'msec' here made the whole bridge fail to start).
--
-- It must be 'frames', not 'ticks': ticks are simulation time and stop dead
-- while the game is paused, which is exactly when the bridge still has to run
-- for auto-unpause and for the dashboard to show anything. Measured: a 'frames'
-- timeout fired 1120 times over 12s while paused; a 'ticks' timeout fired 0.
--
-- Frame rate varies, so we are called every frame and gate the real work on the
-- wall clock to hold a steady cadence whatever the FPS.
local POLL_MS     = 200
local POLL_FRAMES = 1
local START_DELAY_FRAMES = 60
local HEARTBEAT_SEC = 5                 -- release the camera if the client goes away
local MAX_CITIZENS = 200
-- DF queues blocking "You have discovered..." popups that halt the game until
-- someone presses Enter, and stops on diplomat meetings, agreements and text
-- viewers the same way. antfarm_ui is the watchdog for all of it: it presses
-- the key a player would press and reports what it dismissed. Set this to false
-- to leave every blocking screen for a human.
local AUTO_DISMISS_POPUPS = true
-- Concurrent probe requests to keep answers for, and how long each lives.
local MAX_PROBES = 8
local MAX_ANNOUNCEMENTS = 5
local MAX_SKILLS = 8
local MAX_THOUGHTS = 4

-- Persist across script reloads so `antfarm_server start` twice is harmless.
antfarm = antfarm or {
    running = false,
    timer = nil,
    mode = 'idle',
    follow_id = -1,
    last_cmd_time = 0,
    ticks = 0,
    last_frame = 0,
    last_clock = 0,
    fps = 0,
    -- Probes are keyed by unit id, not a single slot. Two viewers typing
    -- !stats at once used to overwrite each other's request and both time out.
    probes = {},
    build_cache = nil,
    build_time = 0,
    last_poll = 0,
    popup_clear_at = 0,
    ui_report = nil,
    ui_events = nil,
    ui_enabled = false,
}

-- ---------------------------------------------------------------- --
-- minimal JSON encoder                                             --
-- ---------------------------------------------------------------- --
-- We roll our own rather than using hack/lua/json.lua because we need to
-- control array-vs-object encoding explicitly: an empty citizen list must
-- serialise as [] and not {}, or the Python client iterates a dict.

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function esc_char(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
end

local function json_string(s)
    if type(s) ~= 'string' then s = tostring(s) end
    -- DF stores text as CP437; convert so the client can read plain UTF-8.
    local ok, conv = pcall(dfhack.df2utf, s)
    if ok and conv then s = conv end
    return '"' .. s:gsub('[%c"\\]', esc_char) .. '"'
end

local function json_number(n)
    if n ~= n or n == math.huge or n == -math.huge then return '0' end
    if n == math.floor(n) then return string.format('%d', n) end
    return string.format('%.4f', n)
end

local json_encode

-- `arr` forces list encoding for tables we know are sequences.
local function json_array(t)
    local parts = {}
    for i = 1, #t do parts[i] = json_encode(t[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
end

local function json_object(t)
    local keys = {}
    for k in pairs(t) do
        if type(k) == 'string' then table.insert(keys, k) end
    end
    table.sort(keys)  -- stable output makes diffing the stream tractable
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, json_string(k) .. ':' .. json_encode(t[k]))
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

json_encode = function(v)
    local tv = type(v)
    if v == nil then return 'null'
    elseif tv == 'boolean' then return v and 'true' or 'false'
    elseif tv == 'number' then return json_number(v)
    elseif tv == 'string' then return json_string(v)
    elseif tv == 'table' then
        -- An explicit marker wins; otherwise a table with [1] is a list.
        if v.__array or (v[1] ~= nil) then return json_array(v) end
        if next(v) == nil then return '{}' end
        return json_object(v)
    end
    return 'null'
end

local EMPTY_ARRAY = setmetatable({}, {__index = {__array = true}})
local function arr(t) t = t or {}; t.__array = true; return t end

-- ---------------------------------------------------------------- --
-- DF readers                                                       --
-- ---------------------------------------------------------------- --

local function map_loaded()
    return dfhack.isMapLoaded() and df.global.world ~= nil
end

-- AGENTS.md 6.1.8: getVisibleName() is nil for plenty of units and
-- TranslateName(nil) raises. Never call it unguarded.
local function unit_name(unit)
    if not unit then return 'Unknown' end
    local ok, name = pcall(function()
        local vis = dfhack.units.getVisibleName(unit)
        if not vis then return nil end
        return dfhack.TranslateName(vis)
    end)
    if ok and name and name ~= '' then return name end
    local ok2, prof = pcall(dfhack.units.getProfessionName, unit)
    if ok2 and prof and prof ~= '' then return prof end
    return 'Unnamed'
end

local function unit_profession(unit)
    local ok, prof = pcall(dfhack.units.getProfessionName, unit)
    if ok and prof and prof ~= '' then return prof end
    return 'Peasant'
end

local function unit_job(unit)
    if not unit or not unit.job or not unit.job.current_job then return 'Idle' end
    local ok, name = pcall(dfhack.job.getName, unit.job.current_job)
    if ok and name and name ~= '' then return name end
    return 'Working'
end

local function unit_soul(unit)
    if not unit or not unit.status then return nil end
    return unit.status.current_soul
end

local function unit_stress(unit)
    local soul = unit_soul(unit)
    if not soul then return 0 end
    return soul.personality.stress_level or 0
end

local function unit_gender(unit)
    if not unit then return 'unknown' end
    if unit.sex == 1 then return 'male'
    elseif unit.sex == 0 then return 'female' end
    return 'unknown'
end

local function unit_age(unit)
    local ok, age = pcall(dfhack.units.getAge, unit, true)
    if ok and age then return math.floor(age) end
    return 0
end

local function unit_skills(unit)
    local out = arr{}
    local soul = unit_soul(unit)
    if not soul then return out end
    local ranked = {}
    -- AGENTS.md 6.1.4: DF vectors are 0-indexed; ipairs() is not safe here.
    for i = 0, #soul.skills - 1 do
        local sk = soul.skills[i]
        if sk and sk.rating and sk.rating > 0 then
            table.insert(ranked, {id = sk.id, rating = sk.rating})
        end
    end
    table.sort(ranked, function(a, b) return a.rating > b.rating end)
    for i = 1, math.min(#ranked, MAX_SKILLS) do
        local sk = ranked[i]
        local name = df.job_skill.attrs[sk.id] and df.job_skill.attrs[sk.id].caption
        table.insert(out, {
            name = name or tostring(df.job_skill[sk.id] or sk.id),
            rating = sk.rating,
        })
    end
    return out
end

local PHYS_ATTRS = {'STRENGTH', 'AGILITY', 'TOUGHNESS', 'ENDURANCE', 'RECUPERATION', 'DISEASE_RESISTANCE'}

local function unit_attributes(unit)
    local physical = {}
    if unit and unit.body and unit.body.physical_attrs then
        for _, key in ipairs(PHYS_ATTRS) do
            local idx = df.physical_attribute_type[key]
            local a = idx and unit.body.physical_attrs[idx]
            if a then physical[key] = a.value or 0 end
        end
    end
    if next(physical) == nil then physical = {STRENGTH = 0} end
    return {physical = physical}
end

local function unit_needs(unit)
    local out = arr{}
    local soul = unit_soul(unit)
    if not soul or not soul.personality.needs then return out end
    local needs = soul.personality.needs
    for i = 0, #needs - 1 do
        local n = needs[i]
        if n then
            table.insert(out, {
                type = tostring(df.need_type[n.id] or n.id),
                -- focus_level runs negative (unmet) to positive (satisfied);
                -- the TUI gauges want 0..1000, so rebase it.
                level = math.max(0, math.min(1000, (n.focus_level or 0) + 500)),
            })
        end
    end
    return out
end

local function unit_thoughts(unit)
    local out = arr{}
    local soul = unit_soul(unit)
    if not soul or not soul.personality.emotions then return out end
    local emotions = soul.personality.emotions
    local first = math.max(0, #emotions - MAX_THOUGHTS)
    for i = #emotions - 1, first, -1 do
        local e = emotions[i]
        if e then
            table.insert(out, {
                emotion = tostring(df.emotion_type[e.type] or 'Feeling'),
                thought = tostring(df.unit_thought_type[e.thought] or 'something'),
            })
        end
    end
    return out
end

local function unit_health(unit)
    local h = {wounds = 0, blood_pct = 100, unconscious = false, dead = false, status = 'Healthy'}
    if not unit then return h end
    pcall(function()
        h.dead = not dfhack.units.isActive(unit)
        h.wounds = #unit.body.wounds
        if unit.body.blood_max and unit.body.blood_max > 0 then
            h.blood_pct = math.floor(100 * unit.body.blood_count / unit.body.blood_max)
        end
        h.unconscious = (unit.counters.unconscious or 0) > 0
    end)
    if h.dead then h.status = 'Dead'
    elseif h.unconscious then h.status = 'Unconscious'
    elseif h.blood_pct < 50 then h.status = 'Bleeding out'
    elseif h.wounds > 4 then h.status = 'Badly wounded'
    elseif h.wounds > 0 then h.status = 'Wounded'
    end
    return h
end

-- Kill tallies live on the historical figure, not the unit, and the vectors are
-- parallel (race id <-> count). Missing info is normal for unnamed dwarves.
local function unit_kills(unit)
    local out = {total = 0, notable = arr{}}
    if not unit or not unit.hist_figure_id or unit.hist_figure_id == -1 then return out end
    pcall(function()
        local hf = df.historical_figure.find(unit.hist_figure_id)
        if not hf or not hf.info or not hf.info.kills then return end
        local k = hf.info.kills
        local tally = {}
        for i = 0, #k.killed_count - 1 do
            local n = k.killed_count[i] or 0
            out.total = out.total + n
            local race_id = k.killed_race[i]
            local cr = race_id and race_id >= 0 and df.creature_raw.find(race_id)
            table.insert(tally, {name = cr and cr.name[0] or 'creature', count = n})
        end
        table.sort(tally, function(a, b) return a.count > b.count end)
        for i = 1, math.min(#tally, 3) do table.insert(out.notable, tally[i]) end
    end)
    return out
end

-- `full` profiles are expensive; only the focused dwarf gets one.
local function unit_profile(unit, full)
    if not unit then return nil end
    local nick = ''
    if unit.name and unit.name.nickname then
        local ok, conv = pcall(dfhack.df2utf, unit.name.nickname)
        nick = (ok and conv) or unit.name.nickname or ''
    end
    local u = {
        id = unit.id,
        hist_id = unit.hist_figure_id or -1,
        name = unit_name(unit),
        -- `nick` is how the Twitch bridge tracks which citizens a viewer has
        -- already claimed; empty means unclaimed.
        nick = nick,
        claimed = nick ~= '',
        profession = unit_profession(unit),
        current_job = unit_job(unit),
        stress = unit_stress(unit),
        pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z},
    }
    if not full then return u end
    u.age = unit_age(unit)
    u.gender = unit_gender(unit)
    u.skills = unit_skills(unit)
    u.attributes = unit_attributes(unit)
    u.needs = unit_needs(unit)
    u.thoughts = unit_thoughts(unit)
    u.health = unit_health(unit)
    u.kills = unit_kills(unit)
    return u
end

local function citizen_units()
    local out = {}
    if not map_loaded() then return out end
    local active = df.global.world.units.active
    for i = 0, #active - 1 do
        local u = active[i]
        -- `u.flags1.dead` is not present in this build's symbols and raises
        -- "Cannot read field unit_flags1.dead". dfhack.units.isActive covers
        -- both dead and inactive and is the version-stable check.
        local ok, is_cit = pcall(dfhack.units.isCitizen, u)
        local alive = select(2, pcall(dfhack.units.isActive, u))
        if ok and is_cit and alive then
            table.insert(out, u)
            if #out >= MAX_CITIZENS then break end
        end
    end
    return out
end

-- Spatial density: how many other citizens share this dwarf's z-level within
-- a 10-tile box. The Director AI weights crowded dwarves as more watchable.
local function annotate_density(profiles, units)
    for i, p in ipairs(profiles) do
        local n = 0
        local a = units[i].pos
        for j, other in ipairs(units) do
            if i ~= j then
                local b = other.pos
                if b.z == a.z and math.abs(b.x - a.x) <= 10 and math.abs(b.y - a.y) <= 10 then
                    n = n + 1
                end
            end
        end
        p.density = n
    end
end

local SEASONS = {[0] = 'Spring', [1] = 'Summer', [2] = 'Autumn', [3] = 'Winter'}

-- Wall-clock milliseconds. Lua's os.clock() is process CPU time, which in a
-- multi-threaded process runs faster than real time and would make the derived
-- FPS read low.
local function wall_ms()
    local ok, ms = pcall(dfhack.getTickCount)
    if ok and ms then return ms end
    return os.time() * 1000
end

local function current_fps()
    -- df.global.enabler.fps is the configured cap, not the achieved rate, so
    -- derive the real one from frame_counter deltas against the wall clock.
    local now = wall_ms() / 1000
    local frame = df.global.world.frame_counter or 0
    if antfarm.last_clock > 0 then
        local dt = now - antfarm.last_clock
        if dt >= 1.0 then
            antfarm.fps = math.floor((frame - antfarm.last_frame) / dt)
            antfarm.last_frame = frame
            antfarm.last_clock = now
        end
    else
        antfarm.last_frame = frame
        antfarm.last_clock = now
    end
    return math.max(0, antfarm.fps)
end

local function recent_announcements()
    local out = arr{}
    if not map_loaded() then return out end
    local anns = df.global.world.status.announcements
    local first = math.max(0, #anns - MAX_ANNOUNCEMENTS)
    for i = #anns - 1, first, -1 do
        local a = anns[i]
        if a and a.text and a.text ~= '' then table.insert(out, a.text) end
    end
    return out
end

local function focused_unit(citizens)
    -- Prefer an explicit lock, then the player's own selection.
    if antfarm.follow_id and antfarm.follow_id ~= -1 then
        local u = df.unit.find(antfarm.follow_id)
        if u and select(2, pcall(dfhack.units.isActive, u)) then return u end
        antfarm.follow_id = -1
    end
    local ok, sel = pcall(dfhack.gui.getSelectedUnit, true)
    if ok and sel then return sel end
    return citizens[1]
end

-- A probe is answered for a few seconds and then expires, so a stale request
-- never pins a unit profile in the stream forever.
--
-- Timed on wall_ms(), not os.time(): the Python client polls every 150ms
-- against time.time(), and second-granularity os.time() could expire a probe
-- inside the caller's own 3s window and hand the viewer nothing.
local PROBE_TTL_SEC = 5

local function expire_probes(now_sec)
    for id, t in pairs(antfarm.probes) do
        if now_sec - t > PROBE_TTL_SEC then antfarm.probes[id] = nil end
    end
end

-- Every live probe, newest first. Serving a list rather than one slot is what
-- lets several viewers ask about different dwarves at the same time.
local function probe_results()
    local now_sec = wall_ms() / 1000
    expire_probes(now_sec)
    local ids = {}
    for id, t in pairs(antfarm.probes) do table.insert(ids, {id = id, t = t}) end
    if #ids == 0 then return nil, nil end
    table.sort(ids, function(a, b) return a.t > b.t end)
    local out = arr{}
    for i = 1, math.min(#ids, MAX_PROBES) do
        local u = df.unit.find(ids[i].id)
        if u then
            local p = unit_profile(u, true)
            if p then table.insert(out, p) end
        else
            antfarm.probes[ids[i].id] = nil
        end
    end
    if #out == 0 then return nil, nil end
    -- `probe_data` stays a single object for older clients; `probes` is the
    -- list every current caller should read.
    return out[1], out
end

-- Build progress comes from antfarm_blueprint, whose gate checks walk every
-- map block on the fort's levels. That is far too heavy for a 200ms tick, so
-- recompute on a slow timer and serve the cached answer in between.
local BUILD_REFRESH_SEC = 10

local function build_progress()
    local now = wall_ms() / 1000
    if antfarm.build_cache and now - (antfarm.build_time or 0) < BUILD_REFRESH_SEC then
        return antfarm.build_cache
    end
    local ok, bp = pcall(reqscript, 'antfarm_blueprint')
    if not ok or not bp or not bp.progress then return nil end
    local ok2, prog = pcall(bp.progress)
    if not ok2 then return antfarm.build_cache end
    antfarm.build_cache = prog
    antfarm.build_time = now
    return prog
end

local function collect_state()
    if not map_loaded() then
        return {
            protocol = 2,
            map_loaded = false,
            fortress_stats = {pop = 0, year = 0, season = 'Spring', fps = 0, paused = true},
            unit_data = nil,
            citizens = EMPTY_ARRAY,
            announcements = EMPTY_ARRAY,
            mode = antfarm.mode,
            ui = antfarm.ui_report,
        }
    end

    local units = citizen_units()
    local profiles = {}
    for i, u in ipairs(units) do profiles[i] = unit_profile(u, false) end
    annotate_density(profiles, units)

    local focus = focused_unit(units)
    local probe_one, probe_list = probe_results()

    return {
        protocol = 2,
        map_loaded = true,
        mode = antfarm.mode,
        follow_id = antfarm.follow_id,
        fortress_stats = {
            pop = #units,
            year = df.global.cur_year or 0,
            season = SEASONS[df.global.cur_season] or 'Spring',
            fps = current_fps(),
            paused = df.global.pause_state and true or false,
        },
        unit_data = unit_profile(focus, true),
        citizens = arr(profiles),
        announcements = recent_announcements(),
        -- `probe <id>` asks for one full profile out-of-band, so the Twitch
        -- bridge can answer !stats/!skills/!health about any dwarf without
        -- inflating every 200ms state frame with the whole roster's detail.
        probe_data = probe_one,
        probes = probe_list,
        build = build_progress(),
        -- What the modal watchdog is seeing and what it has dismissed. The
        -- dashboard shows it so a blocked fort is visible instead of silent.
        ui = antfarm.ui_report,
        ui_events = arr(antfarm.ui_events or {}),
    }
end

-- ---------------------------------------------------------------- --
-- transport                                                        --
-- ---------------------------------------------------------------- --

local function write_state()
    local ok, payload = pcall(function() return json_encode(collect_state()) end)
    if not ok then
        dfhack.printerr('antfarm_server: failed to serialise state: ' .. tostring(payload))
        return
    end
    local tmp = STATE_FILE .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return end
    f:write(payload)
    f:close()
    -- rename() replaces atomically on POSIX. Removing first would leave the
    -- state file missing for a moment on every 200ms tick, which readers hit as
    -- a skipped poll or an outright FileNotFoundError.
    os.rename(tmp, STATE_FILE)
end

-- Loaded lazily: reqscript runs the script in module mode, so this neither
-- starts anything nor recurses back into us.
local function ui_module()
    local ok, mod = pcall(reqscript, 'antfarm_ui')
    if ok and mod then return mod end
    return nil
end

local function set_follow(unit_id)
    local u = df.unit.find(unit_id)
    if not u then return false end
    antfarm.follow_id = unit_id
    df.global.ui.follow_unit = unit_id
    -- An announcement with RECENTER drops the follow lock and drags the view.
    -- The watchdog restores this unit after every unpause it performs.
    local ui = ui_module()
    if ui and ui.set_camera_unit then pcall(ui.set_camera_unit, unit_id) end
    -- Snap the viewport onto the unit so the lock is visible immediately.
    local ok, guidm = pcall(require, 'gui.dwarfmode')
    if ok and guidm and guidm.centerViewscreen then
        pcall(guidm.centerViewscreen, u.pos)
    end
    return true
end

local function release_follow()
    antfarm.follow_id = -1
    local ui = ui_module()
    if ui and ui.set_camera_unit then pcall(ui.set_camera_unit, -1) end
    if map_loaded() then df.global.ui.follow_unit = -1 end
end

local function handle_command(cmd)
    if not cmd or cmd == '' then return end
    antfarm.last_cmd_time = os.time()

    local verb, rest = cmd:match('^(%S+)%s*(.*)$')
    if not verb then return end
    verb = verb:lower()

    if verb == 'ping' then
        return
    elseif verb == 'focus' then
        local id = tonumber(rest)
        if id then set_follow(id) end
    elseif verb == 'unfocus' then
        release_follow()
    elseif verb == 'mode' then
        local new_mode = (rest ~= '' and rest) or 'idle'
        -- The client resends its mode as a heartbeat every second. Only act on
        -- an actual transition, or 'idle' would yank the camera back from the
        -- player once a second for as long as the TUI is open.
        if new_mode ~= antfarm.mode then
            antfarm.mode = new_mode
            if new_mode == 'idle' then release_follow() end
        end
    elseif verb == 'unpause' then
        -- DFHack has no `unpause` command in 0.47; poke the flag directly.
        if map_loaded() then df.global.pause_state = false end
    elseif verb == 'pause' then
        if map_loaded() then df.global.pause_state = true end
    elseif verb == 'stop' then
        antfarm.running = false
        release_follow()
    elseif verb == 'build' then
        -- `build <subcommand>` drives the guided Dreamfort construction.
        local sub = (rest ~= '' and rest) or 'status'
        -- Report failures: a bare pcall here hid a blueprint error behind
        -- complete silence, which is indistinguishable from "it did nothing".
        local ok, err = pcall(dfhack.run_command, 'antfarm_blueprint ' .. sub)
        if not ok then
            dfhack.printerr('antfarm_server: build ' .. sub .. ' failed: ' .. tostring(err))
        end
        antfarm.build_cache = nil   -- force a refresh on the next frame
    elseif verb == 'probe' then
        local id = tonumber(rest)
        if id then
            antfarm.probes[id] = wall_ms() / 1000
            -- Bound the table: a chat raid could otherwise ask about hundreds
            -- of dwarves inside one TTL window.
            local n = 0
            for _ in pairs(antfarm.probes) do n = n + 1 end
            if n > MAX_PROBES * 4 then
                local oldest, oldest_t
                for pid, t in pairs(antfarm.probes) do
                    if not oldest_t or t < oldest_t then oldest, oldest_t = pid, t end
                end
                if oldest then antfarm.probes[oldest] = nil end
            end
        end
    elseif verb == 'nick' then
        -- `nick <unit_id> <nickname>` -- used by the Twitch !name command so a
        -- viewer can claim a migrant. Nicknames may contain spaces.
        local id_str, nickname = rest:match('^(%S+)%s+(.*)$')
        local id = tonumber(id_str)
        if id then
            local u = df.unit.find(id)
            if u then
                local ok, err = pcall(dfhack.units.setNickname, u, nickname or '')
                if not ok then
                    dfhack.printerr('antfarm_server: setNickname failed: ' .. tostring(err))
                end
            end
        end
    elseif verb == 'ui' then
        -- `ui <sub>` drives the modal watchdog: on/off/dismiss/unpause.
        local sub = (rest ~= '' and rest) or 'status'
        local ok, err = pcall(dfhack.run_command, 'antfarm_ui ' .. sub)
        if not ok then
            dfhack.printerr('antfarm_server: ui ' .. sub .. ' failed: ' .. tostring(err))
        end
    elseif verb == 'command' then
        if rest ~= '' then
            local ok, err = pcall(dfhack.run_command, rest)
            if not ok then
                dfhack.printerr('antfarm_server: command failed: ' .. rest .. ': ' .. tostring(err))
            end
        end
    else
        dfhack.printerr('antfarm_server: unknown command: ' .. cmd)
    end
end

-- Pull one string value out of a flat JSON object.
--
-- A non-greedy '"(.-)"' pattern stops at the first backslash-escaped quote and
-- silently truncates the command, so scan properly: walk the string honouring
-- escapes, and decode \uXXXX back to UTF-8 for clients that send ASCII-safe
-- JSON. Dwarf names are full of accented characters and a truncated or
-- mis-decoded name means `focus`/`nick` quietly targets nobody.
local function utf8_from_codepoint(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    else
        -- Above the BMP. DF names never reach here, but a Twitch login passed
        -- to `nick` can contain an emoji, and emitting three bytes for a
        -- four-byte codepoint produced garbage rather than a dropped character.
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + (math.floor(cp / 0x1000) % 0x40),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
end

local STR_ESCAPES = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
    n = '\n', r = '\r', t = '\t',
}

function extract_json_string(content, key)
    local start = content:find('"' .. key .. '"%s*:%s*"')
    if not start then return nil end
    local i = content:find('"', content:find(':', start + #key + 2, true)) + 1

    local out = {}
    while i <= #content do
        local c = content:sub(i, i)
        if c == '"' then
            return table.concat(out)
        elseif c == '\\' then
            local nxt = content:sub(i + 1, i + 1)
            if nxt == 'u' then
                local cp = tonumber(content:sub(i + 2, i + 5), 16)
                i = i + 6
                -- A codepoint above the BMP arrives as a surrogate PAIR
                -- (\uD83D\uDE00). Decoding the halves separately emits two
                -- invalid characters; combine them into the real codepoint.
                if cp and cp >= 0xD800 and cp <= 0xDBFF
                        and content:sub(i, i + 1) == '\\u' then
                    local lo = tonumber(content:sub(i + 2, i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                table.insert(out, cp and utf8_from_codepoint(cp) or '?')
            else
                table.insert(out, STR_ESCAPES[nxt] or nxt)
                i = i + 2
            end
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    return nil  -- unterminated string: the file was read mid-write
end

local function read_command_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local content = f:read('*all')
    f:close()
    if not content or content == '' then return nil end
    -- The wire format is {"command": "..."}; fall back to treating the whole
    -- file as a bare command string so a hand-written file still works.
    local cmd = extract_json_string(content, 'command')
    if not cmd then
        -- Only fall back to "the file is one bare command" when it was never
        -- JSON to begin with. A file that opens with '{' but does not parse is
        -- truncated, and running its raw text as a DFHack command is worse
        -- than dropping it.
        if content:match('^%s*{') then return nil end
        cmd = content:match('^%s*(.-)%s*$')
    end
    if cmd == '' then return nil end
    return cmd
end

local function list_cmd_files()
    if not dfhack.filesystem.isdir(CMD_DIR) then return {} end
    local names = {}
    local ok, entries = pcall(dfhack.filesystem.listdir, CMD_DIR)
    if not ok or not entries then
        -- Older builds only expose listdir_recursive, which yields {path=...}.
        ok, entries = pcall(dfhack.filesystem.listdir_recursive, CMD_DIR, 0, false)
    end
    if ok and entries then
        for _, e in ipairs(entries) do
            local name = type(e) == 'table' and e.path or e
            if type(name) == 'string' and name:sub(-5) == '.json' then
                -- listdir_recursive is called with include_prefix=false, so
                -- these are bare filenames. Strip a directory component anyway:
                -- a build that ignored the flag would make every path
                -- antfarm_cmd/antfarm_cmd/x.json and drop the command in
                -- silence.
                table.insert(names, name:match('([^/\\]+)$') or name)
            end
        end
    end
    -- Client names spool files with a monotonic counter, so lexical sort on a
    -- zero-padded name preserves send order.
    table.sort(names)
    return names
end

local function process_commands()
    for _, name in ipairs(list_cmd_files()) do
        local path = CMD_DIR .. '/' .. name
        local cmd = read_command_file(path)
        os.remove(path)
        if cmd then handle_command(cmd) end
    end
    -- Legacy single-file channel.
    if dfhack.filesystem.exists(CMD_FILE) then
        local cmd = read_command_file(CMD_FILE)
        os.remove(CMD_FILE)
        if cmd then handle_command(cmd) end
    end
end

local function check_heartbeat()
    if antfarm.follow_id == -1 then return end
    if antfarm.last_cmd_time == 0 then return end
    if os.time() - antfarm.last_cmd_time > HEARTBEAT_SEC then
        -- The client is gone. Hand the camera back to the player.
        release_follow()
        antfarm.mode = 'idle'
    end
end

-- Drives antfarm_ui once per poll and folds its findings into the state file.
--
-- Screen dismissal is only armed while a client is actually driving the fort:
-- with the bridge idle the operator is playing by hand and must not have menus
-- closed under them. Popup dismissal is unconditional (subject to
-- AUTO_DISMISS_POPUPS) because a mega-announcement is never something the
-- player is interacting with -- it is a full stop on the whole simulation.
local function run_ui_watchdog()
    local ui = ui_module()
    if not ui or not ui.tick then return end

    local client_live = antfarm.last_cmd_time > 0
        and (os.time() - antfarm.last_cmd_time) <= HEARTBEAT_SEC
        and antfarm.mode ~= 'idle'
    if client_live ~= antfarm.ui_enabled then
        antfarm.ui_enabled = client_live
        pcall(ui.set_screens_enabled, client_live)
    end
    pcall(ui.set_popups_enabled, AUTO_DISMISS_POPUPS)

    local ok, result = pcall(ui.tick)
    if ok and result then
        local events = {}
        for _, t in ipairs(result.popups or {}) do
            table.insert(events, {kind = 'popup', text = t})
        end
        if result.dismissed then
            table.insert(events, {kind = 'screen',
                                  text = (result.dismissed.why or 'screen') ..
                                         (result.dismissed.text and (': ' .. result.dismissed.text) or '')})
        end
        if #events > 0 then
            antfarm.ui_events = events
            antfarm.popup_clear_at = wall_ms() + 30000
        elseif antfarm.popup_clear_at and wall_ms() > antfarm.popup_clear_at then
            antfarm.ui_events = nil
        end
    end

    local ok2, rep = pcall(ui.report)
    if ok2 then antfarm.ui_report = rep end
end

local poll

poll = function()
    if not antfarm.running then return end

    local now = wall_ms()
    if now - (antfarm.last_poll or 0) >= POLL_MS then
        antfarm.last_poll = now
        antfarm.ticks = antfarm.ticks + 1

        local ok, err = pcall(function()
            process_commands()
            check_heartbeat()
            -- Run the modal watchdog before writing state, so a popup is
            -- reported in the same frame it is dismissed and never lost.
            run_ui_watchdog()
            write_state()
        end)
        if not ok then
            dfhack.printerr('antfarm_server: poll error: ' .. tostring(err))
        end
    end

    antfarm.timer = dfhack.timeout(POLL_FRAMES, 'frames', poll)
end

-- ---------------------------------------------------------------- --
-- lifecycle                                                        --
-- ---------------------------------------------------------------- --

function start()
    if antfarm.running then
        print('antfarm_server: already running')
        return
    end
    antfarm.running = true
    antfarm.mode = 'idle'
    antfarm.follow_id = -1
    antfarm.last_cmd_time = 0
    antfarm.last_clock = 0
    antfarm.probes = {}
    antfarm.ui_enabled = false
    antfarm.ui_events = nil
    -- DFHack's `confirm` plugin adds modal are-you-sure dialogs. Every one of
    -- them is a screen an unattended fort would sit on forever; df-ai disables
    -- it at startup for the same reason.
    local ui = ui_module()
    if ui and ui.disable_confirm_plugin then pcall(ui.disable_confirm_plugin) end
    if not dfhack.filesystem.isdir(CMD_DIR) then
        pcall(dfhack.filesystem.mkdir, CMD_DIR)
    end
    -- AGENTS.md 6.1.9: onLoad/onMapLoad fire while DF is still finishing its
    -- viewscreen and map setup. Give it a moment before the first scan.
    antfarm.last_poll = 0
    antfarm.timer = dfhack.timeout(START_DELAY_FRAMES, 'frames', poll)
    print('antfarm_server: started (state=' .. STATE_FILE .. ', cmds=' .. CMD_DIR .. '/)')
end

function stop()
    if not antfarm.running then
        print('antfarm_server: not running')
        return
    end
    antfarm.running = false
    if antfarm.timer then
        pcall(dfhack.timeout_active, antfarm.timer, nil)
        antfarm.timer = nil
    end
    release_follow()
    os.remove(STATE_FILE)
    print('antfarm_server: stopped, camera released')
end

function status()
    print('antfarm_server: ' .. (antfarm.running and 'running' or 'stopped'))
    print('  mode:      ' .. tostring(antfarm.mode))
    print('  follow_id: ' .. tostring(antfarm.follow_id))
    print('  ticks:     ' .. tostring(antfarm.ticks))
    print('  map:       ' .. tostring(map_loaded()))
    local r = antfarm.ui_report
    if r then
        print('  screen:    ' .. tostring(r.screen) ..
              (r.paused and ('  [PAUSED ' .. tostring(r.pause_kind) .. ']') or ''))
        print(('  watchdog:  %s  (%d popup(s), %d screen(s) dismissed, %d failure(s))')
              :format(r.screens_enabled and 'armed' or 'idle',
                      r.popups_dismissed or 0, r.screens_dismissed or 0, r.failures or 0))
    end
end

dfhack.onStateChange.antfarm_server = function(code)
    if code == SC_MAP_UNLOADED or code == SC_WORLD_UNLOADED then
        -- The script's globals survive a world unload but the pending timeout
        -- does not (repeat-util clears its own table on SC_WORLD_UNLOADED for
        -- the same reason). Leaving `running` true meant the `antfarm_server
        -- start` in onMapLoad.init hit the "already running" guard and returned
        -- without rescheduling, so the bridge was silently dead for the rest of
        -- the session after the first save-and-reload.
        antfarm.running = false
        antfarm.timer = nil
        antfarm.follow_id = -1
        antfarm.build_cache = nil
        antfarm.probes = {}
        antfarm.ui_report = nil
        antfarm.ui_events = nil
        antfarm.ui_enabled = false
        os.remove(STATE_FILE)
    end
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'start'):lower()

if verb == 'start' or verb == 'enable' then
    start()
elseif verb == 'stop' or verb == 'disable' then
    stop()
elseif verb == 'status' then
    status()
else
    print('usage: antfarm_server [start|stop|status]')
end
