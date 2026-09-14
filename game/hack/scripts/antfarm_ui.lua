-- antfarm_ui.lua
-- Keeps an unattended fortress running when Dwarf Fortress stops to ask a
-- question. This is the piece that "knows to click OK".
--
-- WHY THIS EXISTS
--
-- DF halts on things a player dismisses without thinking: the "You have
-- discovered an expansive cavern!" box when the miners break through, the
-- liaison's meeting screen, a caravan agreement, a text viewer left on top of
-- the map. On a stream that is a hard stop with no visible cause -- the fort
-- freezes and every dwarf reports Idle forever.
--
-- PRIOR ART
--
-- Ben Lubar's df-ai (https://github.com/BenLubar/df-ai) solved most of this in
-- C++ and its solutions are ported here rather than reinvented:
--
--   * pause.cpp AI::unpause()      -- clear popups with CLOSE_MEGA_ANNOUNCEMENT
--                                     (the key a player presses), then D_PAUSE.
--   * pause.cpp AI::statechanged() -- the viewscreen -> interface_key table
--                                     below is df-ai's, key for key.
--   * pause.cpp handle_pause_event -- classify a pause by the ANNOUNCEMENT TYPE
--                                     that caused it, read out of
--                                     d_init.announcements.flags[type].PAUSE,
--                                     instead of matching announcement text.
--   * ai.cpp is_dwarfmode_viewscreen() -- the "is the game drivable right now"
--                                     precondition for any automation.
--   * ai.cpp pause_onupdate         -- if the game has been stuck paused for
--                                     ten seconds, force an unpause.
--   * camera.cpp ignore_pause()     -- an announcement with RECENTER steals the
--                                     camera; put it back after unpausing.
--
-- WHERE WE GO FURTHER
--
--   1. df-ai only dismisses viewscreens it recognises, by matching exact
--      English diplomat dialogue; anything else logs
--      "[ERROR] paused in unknown textviewerst" and the fort stays frozen.
--      Here an unrecognised screen is still dismissed, just after a longer
--      grace period, and escalates LEAVESCREEN -> LEAVESCREEN_ALL ->
--      screen.dismiss. Unknown unknowns are the whole problem on a stream.
--   2. df-ai's unpause() is `while (!popups.empty()) feed_key(...)` -- an
--      unbounded loop inside the game's own update. If the key ever fails to
--      take, DF hangs. Attempts are bounded here, with a direct queue-clear as
--      the documented-lossy fallback.
--   3. Dismissal is gated on a client actually driving the fort, so a human
--      playing with the bridge idle never has a menu closed under them.
--   4. Everything dismissed is reported into the state file, so the dashboard
--      and chat can say what happened instead of the fort silently skipping it.
--
-- Usage:
--   antfarm_ui status      what the watchdog has seen and done
--   antfarm_ui screen      identify the current viewscreen (diagnostics)
--   antfarm_ui dismiss     dismiss whatever is on screen right now, once
--   antfarm_ui unpause     clear popups and unpause, the way df-ai does
--   antfarm_ui on | off    enable/disable viewscreen dismissal

--@module = true

local gui = require('gui')

-- A screen we RECOGNISE blocks the game and we know the key, so it only waits
-- long enough for the dashboard to show viewers what it said.
local KNOWN_GRACE_MS = 3000
-- A screen we do NOT recognise waits much longer: it might be the operator
-- reading something. df-ai never closes these at all; we do, eventually.
local UNKNOWN_GRACE_MS = 15000
-- Popups block the simulation outright, so they get the shortest fuse.
local POPUP_GRACE_MS = 600
-- DF needs a frame or two to actually process a key.
local RETRY_MS = 400
local MAX_ATTEMPTS = 6
-- Stop hammering a screen we have failed to dismiss; re-arm after this long in
-- case a later instance of the same screen behaves differently.
local GIVE_UP_MS = 120000
-- df-ai: if the game has been paused or popup-blocked this long with nothing
-- else clearing it, force an unpause. The backstop for every case below that
-- we did not anticipate.
local STUCK_PAUSE_MS = 10000
-- A screen driver gets this many resumes (one per poll) before it is abandoned.
-- Without a cap, a driver whose screen never appears sits in the way of every
-- other watchdog for the rest of the session.
local DRIVER_BUDGET = 60
-- ...and this long before another one is attempted, so a driver that cannot
-- work does not restart on the very next poll forever.
local DRIVER_COOLDOWN_MS = 60000
local LOG_MAX = 16
local POPUP_MEMORY = 24
local TEXT_CLIP = 300

antfarm_ui = antfarm_ui or {
    -- Viewscreen dismissal is opt-in: antfarm_server turns it on while a client
    -- is driving the fort. Popup dismissal defaults on because a popup is never
    -- something the player is interacting with -- it is a full stop.
    screens_enabled = false,
    popups_enabled = true,
    auto_unpause = true,

    focus = nil,          -- identity of the screen we are watching
    focus_since = 0,
    last_action = 0,
    attempts = 0,
    gave_up = {},

    popup_attempts = 0,
    popup_since = 0,
    seen_popups = {},
    -- A keystroke sent with gui.simulateInput is QUEUED, not applied: DF feeds
    -- it on a later frame. Checking whether it worked in the same call always
    -- reads the pre-keystroke screen, so what was attempted is recorded here
    -- and confirmed on a subsequent tick.
    pending = nil,
    pending_popup = nil,

    was_paused = false,
    paused_since = 0,
    last_pause_reason = nil,

    -- The unit antfarm_server has the camera locked onto, so it can be restored
    -- after an announcement with RECENTER drags the view somewhere else.
    camera_unit = -1,

    driver = nil,         -- running coroutine screen driver, if any
    driver_name = nil,
    driver_budget = 0,    -- resumes left before we abort it
    driver_retry_at = 0,  -- wall ms before which we will not start another

    log = {},
    stats = {popups = 0, screens = 0, failures = 0, unpauses = 0, petitions = 0},
}

local function wall_ms()
    local ok, ms = pcall(dfhack.getTickCount)
    if ok and ms then return ms end
    return os.time() * 1000
end

local function clip(s, n)
    s = tostring(s or '')
    if #s <= (n or TEXT_CLIP) then return s end
    return s:sub(1, (n or TEXT_CLIP) - 3) .. '...'
end

local function note(kind, text)
    text = clip(text)
    table.insert(antfarm_ui.log, {t = os.time(), kind = kind, text = text})
    while #antfarm_ui.log > LOG_MAX do table.remove(antfarm_ui.log, 1) end
    print(('antfarm_ui: %s -- %s'):format(kind, text))
end

local function utf(s)
    local ok, conv = pcall(dfhack.df2utf, tostring(s or ''))
    return (ok and conv) or tostring(s or '')
end

-- ---------------------------------------------------------------- --
-- is the game drivable right now?                                  --
-- ---------------------------------------------------------------- --

-- Port of df-ai ai.cpp AI::is_dwarfmode_viewscreen(). Anything that sends keys
-- or designates tiles must check this first: quickfort applied while a menu is
-- open lands its keystrokes in the menu.
function is_dwarfmode()
    local ok, result = pcall(function()
        if not dfhack.isMapLoaded() then return false end
        if df.global.ui.main.mode ~= df.ui_sidebar_mode.Default then return false end
        if #df.global.world.status.popups > 0 then return false end
        local scr = dfhack.gui.getCurViewscreen()
        if not scr then return false end
        if dfhack.screen.isDismissed(scr) then return false end
        if not df.viewscreen_dwarfmodest:is_instance(scr) then return false end
        return true
    end)
    return ok and result or false
end

-- ---------------------------------------------------------------- --
-- screen identification                                            --
-- ---------------------------------------------------------------- --

-- df-ai's table, key for key (pause.cpp AI::statechanged). Ordered: the first
-- matching type wins. `keys` is the escalation ladder for that screen.
local HANDLERS = {
    {type = 'viewscreen_topicmeetingst',
     keys = {'OPTION1', 'OPTION1', 'LEAVESCREEN'},
     why = 'diplomat meeting'},
    {type = 'viewscreen_topicmeeting_takerequestsst',
     keys = {'LEAVESCREEN'}, why = 'diplomat requests'},
    {type = 'viewscreen_topicmeeting_fill_land_holder_positionsst',
     keys = {'LEAVESCREEN'}, why = 'land holder positions'},
    {type = 'viewscreen_requestagreementst',
     keys = {'LEAVESCREEN'}, why = 'request agreement'},
    {type = 'viewscreen_textviewerst',
     keys = {'LEAVESCREEN', 'SELECT', 'LEAVESCREEN'}, why = 'text viewer'},
    {type = 'viewscreen_announcelistst',
     keys = {'LEAVESCREEN'}, why = 'announcement list'},
    {type = 'viewscreen_reportlistst',
     keys = {'LEAVESCREEN'}, why = 'combat report list'},
    {type = 'viewscreen_movieplayerst',
     keys = {'LEAVESCREEN'}, why = 'movie player'},
    {type = 'viewscreen_petitionsst',
     keys = {'LEAVESCREEN'}, why = 'petitions'},
}

-- Screens the operator drives. Dismissing any of these throws away their work
-- or quits the game, so they are never touched however long they sit there.
local PROTECTED = {
    viewscreen_titlest = true,
    viewscreen_loadgamest = true,
    viewscreen_savegamest = true,
    viewscreen_new_regionst = true,
    viewscreen_update_regionst = true,
    viewscreen_adopt_regionst = true,
    viewscreen_choose_start_sitest = true,
    viewscreen_setupdwarfgamest = true,
    viewscreen_setupadventurest = true,
    viewscreen_export_regionst = true,
    viewscreen_export_graphical_mapst = true,
    viewscreen_legendsst = true,
    viewscreen_dungeonmodest = true,
    viewscreen_game_cleanerst = true,
    viewscreen_layer_world_gen_paramst = true,
    viewscreen_layer_world_gen_param_presetst = true,
}

-- Identify a viewscreen by df-structures type name. is_instance is the
-- authoritative check (it compares DFHack's virtual identity), so probe the
-- types we care about first and only fall back to the runtime label.
local function is_a(typename, scr)
    local t = df[typename]
    if not t then return false end
    local ok, hit = pcall(function() return t:is_instance(scr) end)
    return ok and hit and true or false
end

local function screen_typename(scr)
    if not scr then return nil end
    for _, h in ipairs(HANDLERS) do
        if is_a(h.type, scr) then return h.type end
    end
    for pname in pairs(PROTECTED) do
        if is_a(pname, scr) then return pname end
    end
    if is_a('viewscreen_dwarfmodest', scr) then return 'viewscreen_dwarfmodest' end
    -- Not one we know. Report whatever DF calls it so an operator reading the
    -- log can add a handler, rather than a bare "unknown".
    local ok, label = pcall(function() return tostring(scr._type) end)
    if ok and label then
        local short = label:match('([%w_]+st)') or label:match('([%w_]+)%s*>%s*$')
        if short then return short end
    end
    return 'unknown'
end

local function focus_of(scr)
    local ok, focus = pcall(dfhack.gui.getFocusString, scr)
    if ok and focus and focus ~= '' then return focus end
    return '?'
end

function current_screen()
    local ok, scr = pcall(dfhack.gui.getCurViewscreen)
    if not ok or not scr then return nil, 'none', '?' end
    return scr, screen_typename(scr), focus_of(scr)
end

local function handler_for(scr)
    for _, h in ipairs(HANDLERS) do
        if is_a(h.type, scr) then return h end
    end
    return nil
end

-- Everything a text viewer is showing, flattened. Both diagnostics and good
-- stream material: this is where "You have struck adamantine!" lives.
local function textviewer_text(scr)
    local parts = {}
    pcall(function()
        for i = 0, #scr.formatted_text - 1 do
            local span = scr.formatted_text[i]
            if span and span.text then table.insert(parts, tostring(span.text)) end
        end
    end)
    local joined = table.concat(parts, ' '):gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    return utf(joined)
end

-- Whether we may send keys to this screen at all.
local function actionable(scr, tname)
    if not scr then return false, 'no screen' end
    local ok, parent = pcall(function() return scr.parent end)
    -- Parentless screens are the root of the stack: LEAVESCREEN on dwarfmode
    -- opens the abandon-fortress menu, and screen.dismiss on a parentless
    -- screen exits DF immediately (see DFHack devel/pop-screen).
    if not ok or not parent then return false, 'root screen' end
    if tname == 'viewscreen_dwarfmodest' then return false, 'the map itself' end
    if PROTECTED[tname] then return false, 'operator screen' end
    local focus = focus_of(scr)
    if focus:find('^dfhack/') then return false, 'a DFHack screen' end
    return true, nil
end

-- ---------------------------------------------------------------- --
-- mega-announcement popups                                         --
-- ---------------------------------------------------------------- --

-- `text` is a plain string on some builds and a vector of lines on others.
local function popup_text(p)
    if not p then return nil end
    local ok, t = pcall(function() return p.text end)
    if not ok or not t then return nil end
    if type(t) ~= 'string' then
        local parts = {}
        if not pcall(function()
            for j = 0, #t - 1 do table.insert(parts, tostring(t[j])) end
        end) then return nil end
        t = table.concat(parts, ' ')
    end
    t = tostring(t)
    if t == '' then return nil end
    return utf(t)
end

function pending_popups()
    local texts = {}
    if not dfhack.isMapLoaded() then return texts end
    pcall(function()
        local popups = df.global.world.status.popups
        for i = 0, #popups - 1 do
            local t = popup_text(popups[i])
            if t then table.insert(texts, t) end
        end
    end)
    return texts
end

function popup_count()
    local n = 0
    pcall(function() n = #df.global.world.status.popups end)
    return n
end

local function remember_popup(text)
    for _, seen in ipairs(antfarm_ui.seen_popups) do
        if seen == text then return false end
    end
    table.insert(antfarm_ui.seen_popups, text)
    while #antfarm_ui.seen_popups > POPUP_MEMORY do
        table.remove(antfarm_ui.seen_popups, 1)
    end
    return true
end

-- One bounded attempt at clearing the popup queue. df-ai loops here without a
-- bound; if the key ever stops working that loop never returns.
-- Returns the texts of popups seen for the first time this tick.
local function handle_popups(now, force)
    local n = popup_count()

    -- Confirm whatever the previous tick pressed Enter at.
    local pp = antfarm_ui.pending_popup
    if pp then
        if n < pp.n then
            antfarm_ui.stats.popups = antfarm_ui.stats.popups + (pp.n - n)
            for _, t in ipairs(pp.texts) do note('popup dismissed', t) end
            antfarm_ui.pending_popup = nil
            if n == 0 then
                antfarm_ui.popup_attempts = 0
                antfarm_ui.popup_since = 0
            end
        else
            antfarm_ui.pending_popup = nil
        end
    end

    if n == 0 then
        antfarm_ui.popup_attempts = 0
        antfarm_ui.popup_since = 0
        return {}
    end

    local texts = pending_popups()
    local fresh = {}
    for _, t in ipairs(texts) do
        if remember_popup(t) then table.insert(fresh, t) end
    end

    if not antfarm_ui.popups_enabled then return fresh end

    if antfarm_ui.popup_since == 0 then
        -- Report on the frame we first see it and dismiss on a later one: the
        -- text must reach the dashboard before it is thrown away.
        antfarm_ui.popup_since = now
        if not force then return fresh end
    end
    if not force then
        if now - antfarm_ui.popup_since < POPUP_GRACE_MS then return fresh end
        if now - antfarm_ui.last_action < RETRY_MS then return fresh end
    end
    antfarm_ui.last_action = now

    local scr = select(1, current_screen())
    antfarm_ui.popup_attempts = antfarm_ui.popup_attempts + 1

    if antfarm_ui.popup_attempts <= MAX_ATTEMPTS and scr then
        -- Exactly what a player presses: Enter, bound to
        -- CLOSE_MEGA_ANNOUNCEMENT in data/init/interface.txt. The key is
        -- queued, so the result is checked on the next tick.
        pcall(gui.simulateInput, scr, 'CLOSE_MEGA_ANNOUNCEMENT')
        antfarm_ui.pending_popup = {n = n, texts = texts}
    else
        -- The key did not take. Clear the queue so the fortress runs again, and
        -- say so: this path skips DF's own teardown and leaks the message
        -- objects, so it is a failure to report, not a normal outcome.
        local cleared = pcall(function() df.global.world.status.popups:resize(0) end)
        antfarm_ui.stats.failures = antfarm_ui.stats.failures + 1
        note('popup force-cleared',
             ('%d popup(s) would not close with Enter; cleared the queue directly (%s)')
             :format(n, cleared and 'ok' or 'FAILED'))
        antfarm_ui.popup_attempts = 0
        antfarm_ui.popup_since = 0
    end
    return fresh
end

-- ---------------------------------------------------------------- --
-- pausing                                                          --
-- ---------------------------------------------------------------- --

-- Which announcement types are dramatic enough that a stream should sit on the
-- pause for a beat before carrying on, and which the audience needs told about.
-- Everything not listed is treated as routine and unpaused immediately.
local DANGER = {
    MEGABEAST_ARRIVAL = true, UNDEAD_ATTACK = true, BERSERK_CITIZEN = true,
    CAVE_COLLAPSE = true, NIGHT_ATTACK_STARTS = true, CITIZEN_SNATCHED = true,
    CITIZEN_DEATH = true, POSSESSED_TANTRUM = true, CITIZEN_TANTRUM = true,
}

-- Reported to chat/dashboard but never worth holding the game for.
local NOTABLE = {
    FEATURE_DISCOVERY = true, STRUCK_DEEP_METAL = true, STRANGE_MOOD = true,
    MADE_ARTIFACT = true, NAMED_ARTIFACT = true, ARTIFACT_BEGUN = true,
    MIGRANT_ARRIVAL = true, D_MIGRANTS_ARRIVAL = true, D_MIGRANT_ARRIVAL = true,
    CARAVAN_ARRIVAL = true, LIAISON_ARRIVAL = true, DIPLOMAT_ARRIVAL = true,
    NOBLE_ARRIVAL = true, BIRTH_CITIZEN = true, MOOD_BUILDING_CLAIMED = true,
}

-- df-ai handle_pause_event: the announcement that caused this pause is the most
-- recent one whose TYPE is configured to pause, and which happened this very
-- tick. Reading the type out of d_init beats matching the text -- it does not
-- care about wording, language, or a siege's follow-up combat spam.
function pause_cause()
    local found
    pcall(function()
        local anns = df.global.world.status.announcements
        local flags = df.global.d_init.announcements.flags
        for i = #anns - 1, 0, -1 do
            local a = anns[i]
            if a and flags[a.type] and flags[a.type].PAUSE then
                found = {
                    type = tostring(df.announcement_type[a.type] or a.type),
                    text = utf(a.text or ''),
                    fresh = (a.year == df.global.cur_year and a.time == df.global.cur_year_tick),
                    id = a.id,
                }
                break
            end
        end
    end)
    return found
end

local function ambush(type_name)
    return type_name and type_name:sub(1, 6) == 'AMBUSH'
end

function classify_pause(cause)
    if not cause then return 'unknown', 'paused with no pausing announcement' end
    if DANGER[cause.type] or ambush(cause.type) then
        return 'danger', cause.type
    end
    if NOTABLE[cause.type] then return 'notable', cause.type end
    return 'routine', cause.type
end

-- Put the camera back where the Director had it. An announcement with RECENTER
-- drags the view to wherever the event happened and drops the follow lock;
-- without this the stream ends up staring at an empty corridor.
local function restore_camera()
    if antfarm_ui.camera_unit == nil or antfarm_ui.camera_unit == -1 then return end
    pcall(function()
        local u = df.unit.find(antfarm_ui.camera_unit)
        if not u then return end
        df.global.ui.follow_unit = antfarm_ui.camera_unit
        pcall(dfhack.gui.revealInDwarfmodeMap, u.pos, true)
    end)
end

function set_camera_unit(unit_id)
    antfarm_ui.camera_unit = unit_id or -1
end

-- df-ai AI::unpause(), with the unbounded popup loop replaced by the bounded
-- one above and a direct pause_state write as the last resort.
function unpause()
    local now = wall_ms()
    if popup_count() > 0 then
        -- Clear the queue now rather than waiting out the reporting grace:
        -- nothing else in the game moves while a popup is up.
        handle_popups(now, true)
        if popup_count() > 0 then return false end
    end
    local paused = false
    pcall(function() paused = df.global.pause_state and true or false end)
    if not paused then
        restore_camera()
        return true
    end
    if is_dwarfmode() then
        local scr = select(1, current_screen())
        if scr then pcall(gui.simulateInput, scr, 'D_PAUSE') end
    end
    pcall(function()
        if df.global.pause_state then
            -- DFHack 0.47 has no `unpause` command; poke the flag. Feeding
            -- D_PAUSE above is preferred because it is what the player does,
            -- but it only works from dwarfmode.
            df.global.pause_state = false
        end
    end)
    antfarm_ui.stats.unpauses = antfarm_ui.stats.unpauses + 1
    restore_camera()
    return true
end

-- Returns the classification of the current pause, or nil when running.
local function handle_pause(now)
    local paused = false
    pcall(function() paused = df.global.pause_state and true or false end)
    local blocked = paused or popup_count() > 0

    if not blocked then
        antfarm_ui.was_paused = false
        antfarm_ui.paused_since = 0
        antfarm_ui.last_pause_reason = nil
        return nil
    end

    if not antfarm_ui.was_paused then
        antfarm_ui.was_paused = true
        antfarm_ui.paused_since = now
        local cause = pause_cause()
        local kind, what = classify_pause(cause)
        antfarm_ui.last_pause_reason = {kind = kind, type = what,
                                        text = cause and cause.text or ''}
        if kind ~= 'routine' then
            note('paused', ('%s: %s'):format(kind, cause and cause.text or what))
        end
    end

    if not antfarm_ui.auto_unpause then return antfarm_ui.last_pause_reason end

    local reason = antfarm_ui.last_pause_reason or {kind = 'unknown'}
    -- Danger holds the pause long enough for the audience to see what happened,
    -- then carries on -- the old keyword check could suppress the unpause for
    -- the rest of the session because the last announcement never changed.
    local hold = (reason.kind == 'danger') and 6000 or 1200
    if now - antfarm_ui.paused_since < hold then return reason end
    if now - antfarm_ui.last_action < RETRY_MS then return reason end
    antfarm_ui.last_action = now
    unpause()

    -- df-ai's backstop: still stuck well past the hold, force it and log.
    if now - antfarm_ui.paused_since > STUCK_PAUSE_MS then
        note('pause watchdog',
             ('still blocked %ds after "%s"; forcing'):format(
                math.floor((now - antfarm_ui.paused_since) / 1000), tostring(reason.type)))
        pcall(function() df.global.pause_state = false end)
        antfarm_ui.paused_since = now
    end
    return reason
end

-- ---------------------------------------------------------------- --
-- stuck viewscreens                                                --
-- ---------------------------------------------------------------- --

local function key_for(handler, attempt)
    if handler and handler.keys and handler.keys[attempt] then
        return handler.keys[attempt]
    end
    if attempt <= 3 then return 'LEAVESCREEN' end
    if attempt <= 5 then return 'LEAVESCREEN_ALL' end
    return nil   -- caller falls back to screen.dismiss
end

-- Dismiss whatever is on top, once. Returns acted, what.
function dismiss_current(force)
    local scr, tname = current_screen()
    local ok, why = actionable(scr, tname)
    if not ok then
        if force then
            dfhack.printerr('antfarm_ui: refusing to dismiss ' .. tostring(tname) .. ' -- ' .. why)
        end
        return false, why
    end
    local attempt = force and 1 or (antfarm_ui.attempts + 1)
    local key = key_for(handler_for(scr), attempt)
    if key then
        pcall(gui.simulateInput, scr, key)
    else
        -- Guarded above: scr.parent is non-nil here, so this cannot be the
        -- DF-exiting case.
        pcall(dfhack.screen.dismiss, scr)
        key = 'screen.dismiss'
    end
    return true, key
end

local function handle_screen(now)
    if not antfarm_ui.screens_enabled then
        antfarm_ui.focus = nil
        return nil
    end

    local scr, tname, focus = current_screen()
    local ident = tostring(tname) .. '|' .. tostring(focus)
    if ident ~= antfarm_ui.focus then
        antfarm_ui.focus = ident
        antfarm_ui.focus_since = now
        antfarm_ui.attempts = 0
        return nil
    end

    local gave_up_at = antfarm_ui.gave_up[ident]
    if gave_up_at then
        if now - gave_up_at < GIVE_UP_MS then return nil end
        antfarm_ui.gave_up[ident] = nil
        antfarm_ui.attempts = 0
    end

    if not actionable(scr, tname) then return nil end

    local handler = handler_for(scr)
    -- A screen we recognise is a known blocker; an unrecognised one might be
    -- the operator reading something, so it waits far longer.
    local grace = handler and KNOWN_GRACE_MS or UNKNOWN_GRACE_MS
    if now - antfarm_ui.focus_since < grace then return nil end
    if now - antfarm_ui.last_action < RETRY_MS then return nil end

    antfarm_ui.last_action = now
    antfarm_ui.attempts = antfarm_ui.attempts + 1

    if antfarm_ui.attempts > MAX_ATTEMPTS then
        antfarm_ui.gave_up[ident] = now
        antfarm_ui.stats.failures = antfarm_ui.stats.failures + 1
        note('screen stuck',
             ('could not dismiss %s (%s) after %d attempts; leaving it alone')
             :format(tostring(tname), tostring(focus), MAX_ATTEMPTS))
        return nil
    end

    -- Capture what it said before it goes; a text viewer is often the most
    -- interesting thing that happened all hour.
    local said
    if handler and handler.type == 'viewscreen_textviewerst' then
        said = textviewer_text(scr)
    end

    local key = key_for(handler, antfarm_ui.attempts)
    if key then
        pcall(gui.simulateInput, scr, key)
    else
        pcall(dfhack.screen.dismiss, scr)
        key = 'screen.dismiss'
    end

    -- Whether it worked cannot be known yet; confirm_pending() checks on a
    -- later tick, once DF has actually fed the key.
    antfarm_ui.pending = {
        ident = ident,
        screen = tostring(tname),
        why = handler and handler.why or 'unrecognised',
        key = key,
        text = said,
        at = now,
        waited = now - antfarm_ui.focus_since,
    }
    return nil
end

-- Did the keystroke we sent last tick actually close the screen? Returns the
-- dismissal record when it did, so the caller can report it.
local function confirm_pending(now)
    local p = antfarm_ui.pending
    if not p then return nil end
    local _, tname, focus = current_screen()
    local ident = tostring(tname) .. '|' .. tostring(focus)
    if ident ~= p.ident then
        antfarm_ui.pending = nil
        antfarm_ui.stats.screens = antfarm_ui.stats.screens + 1
        note('screen dismissed', ('%s (%s) closed with %s after %ds%s')
             :format(p.screen, p.why, p.key, math.floor(p.waited / 1000),
                     p.text and (' -- ' .. p.text) or ''))
        antfarm_ui.focus = nil
        antfarm_ui.attempts = 0
        return {screen = p.screen, why = p.why, text = p.text}
    end
    -- Still there. Give DF a couple of frames before writing the attempt off;
    -- the escalation ladder in handle_screen takes it from here.
    if now - p.at > 2000 then antfarm_ui.pending = nil end
    return nil
end

-- ---------------------------------------------------------------- --
-- coroutine screen driver                                          --
-- ---------------------------------------------------------------- --
-- df-ai's ExclusiveCallback, in Lua. The rule it encodes is the important one:
-- never send a key without first confirming you are on the screen you think you
-- are on. Blind keystrokes are how UI automation corrupts a fort.

local Driver = {}
Driver.__index = Driver

function Driver:delay(frames)
    for _ = 1, (frames or 1) do coroutine.yield() end
end

-- Wait until the current screen is `typename`, up to `tries` resumes.
function Driver:expect(typename, tries)
    tries = tries or 40
    for _ = 1, tries do
        local scr = select(1, current_screen())
        local t = df[typename]
        if scr and t then
            local ok, hit = pcall(function() return t:is_instance(scr) end)
            if ok and hit then return scr end
        end
        coroutine.yield()
    end
    error(('expected %s, got %s'):format(typename, tostring(select(2, current_screen()))))
end

function Driver:key(k)
    local scr = select(1, current_screen())
    if not scr then error('no viewscreen to send ' .. tostring(k)) end
    local ok, err = pcall(gui.simulateInput, scr, k)
    if not ok then error(('key %s failed: %s'):format(tostring(k), tostring(err))) end
    self:delay(1)
end

function start_driver(name, body)
    if antfarm_ui.driver then return false end
    if wall_ms() < (antfarm_ui.driver_retry_at or 0) then return false end
    antfarm_ui.driver_name = name
    antfarm_ui.driver_budget = DRIVER_BUDGET
    antfarm_ui.driver = coroutine.create(function()
        body(setmetatable({}, Driver))
    end)
    return true
end

local function end_driver(failed, why)
    if failed then
        antfarm_ui.stats.failures = antfarm_ui.stats.failures + 1
        antfarm_ui.driver_retry_at = wall_ms() + DRIVER_COOLDOWN_MS
        note('driver failed', ('%s: %s'):format(tostring(antfarm_ui.driver_name), tostring(why)))
    end
    antfarm_ui.driver, antfarm_ui.driver_name = nil, nil
    antfarm_ui.driver_budget = 0
end

local function pump_driver()
    if not antfarm_ui.driver then return end
    local co = antfarm_ui.driver
    if coroutine.status(co) == 'dead' then return end_driver(false) end

    antfarm_ui.driver_budget = antfarm_ui.driver_budget - 1
    if antfarm_ui.driver_budget < 0 then
        return end_driver(true, 'ran out of time waiting for its screen')
    end

    local ok, err = coroutine.resume(co)
    if not ok then return end_driver(true, err) end
    if coroutine.status(co) == 'dead' then return end_driver(false) end
end

-- ---------------------------------------------------------------- --
-- petitions                                                        --
-- ---------------------------------------------------------------- --
-- Ported from df-ai population_occupations.cpp CheckPetitionsExclusive.
-- Residency and citizenship are accepted; anything we cannot honour is
-- rejected rather than left to expire, which is what angers the petitioner.

local function petition_count()
    local n = 0
    pcall(function() n = #df.global.ui.petitions end)
    return n
end

local ACCEPT = {Residency = true, Citizenship = true}

local function petitions_body(d)
    if petition_count() == 0 then return end
    if not is_dwarfmode() then return end

    d:expect('viewscreen_dwarfmodest')
    d:key('D_PETITIONS')
    local view = d:expect('viewscreen_petitionsst')

    if not view.can_manage or view.can_manage == 0 then
        note('petitions', 'nobody is available to manage petitions')
        d:key('LEAVESCREEN')
        return
    end

    local guard = 0
    while guard < 32 do
        guard = guard + 1
        -- Answering the last petition closes the screen, which would leave
        -- `view` dangling; re-check before touching it.
        local scr = select(1, current_screen())
        if not is_a('viewscreen_petitionsst', scr) then return end
        if #view.list == 0 then break end
        local kind = 'unknown'
        pcall(function()
            local p = view.list[view.cursor]
            local det = p.details[0]
            kind = tostring(df.agreement_details_type[det.type] or det.type)
        end)
        if ACCEPT[kind] then
            note('petition accepted', kind)
            d:key('OPTION1')
        else
            -- We have no room planner to satisfy a temple or guildhall request,
            -- so decline it cleanly instead of letting it lapse.
            note('petition rejected', kind)
            d:key('OPTION2')
        end
        antfarm_ui.stats.petitions = antfarm_ui.stats.petitions + 1
        d:delay(1)
    end

    d:key('LEAVESCREEN')
    d:expect('viewscreen_dwarfmodest')
end

function check_petitions()
    if petition_count() == 0 then return false end
    return start_driver('petitions', petitions_body)
end

-- ---------------------------------------------------------------- --
-- entry points                                                     --
-- ---------------------------------------------------------------- --

function set_screens_enabled(on)
    antfarm_ui.screens_enabled = on and true or false
    if not antfarm_ui.screens_enabled then
        antfarm_ui.focus = nil
        antfarm_ui.attempts = 0
    end
end

function set_popups_enabled(on)
    antfarm_ui.popups_enabled = on and true or false
end

function set_auto_unpause(on)
    antfarm_ui.auto_unpause = on and true or false
end

-- Quieten the combat/hunting/sparring report indicators. df-ai clears these
-- every camera update; left set they keep re-opening the combat report list.
local function quiet_status_flags()
    pcall(function()
        local f = df.global.world.status.flags
        f.combat = false
        f.hunting = false
        f.sparring = false
    end)
end

-- Called once per bridge poll. Returns what happened, for the state file.
function tick()
    local now = wall_ms()

    -- A driver owns the UI while it runs, so screen dismissal and the pause
    -- handler stand down -- but popups do not: a mega-announcement blocks the
    -- driver too, and leaving it up would deadlock the pair of them.
    if antfarm_ui.driver then
        local popups = handle_popups(now)
        pump_driver()
        return {driver = antfarm_ui.driver_name, popups = popups, dismissed = nil}
    end

    quiet_status_flags()
    -- Confirm last tick's keystroke first: until that is resolved, the screen
    -- handler cannot tell a screen it just closed from one that will not close.
    local dismissed = confirm_pending(now)
    local popups = handle_popups(now)
    local pause = handle_pause(now)
    if not dismissed then dismissed = handle_screen(now) end

    if antfarm_ui.screens_enabled and is_dwarfmode() and petition_count() > 0 then
        check_petitions()
    end

    return {popups = popups, dismissed = dismissed, pause = pause,
            driver = antfarm_ui.driver_name}
end

function report()
    local entries = {}
    for _, e in ipairs(antfarm_ui.log) do
        table.insert(entries, {t = e.t, kind = e.kind, text = e.text})
    end
    local _, tname, focus = current_screen()
    local paused = false
    pcall(function() paused = df.global.pause_state and true or false end)
    return {
        screen = tostring(tname),
        focus = tostring(focus),
        drivable = is_dwarfmode(),
        paused = paused,
        pause_kind = antfarm_ui.last_pause_reason and antfarm_ui.last_pause_reason.kind or '',
        pause_type = antfarm_ui.last_pause_reason and tostring(antfarm_ui.last_pause_reason.type) or '',
        screens_enabled = antfarm_ui.screens_enabled and true or false,
        popups_enabled = antfarm_ui.popups_enabled and true or false,
        auto_unpause = antfarm_ui.auto_unpause and true or false,
        pending_popups = popup_count(),
        pending_petitions = petition_count(),
        driver = antfarm_ui.driver_name or '',
        popups_dismissed = antfarm_ui.stats.popups,
        screens_dismissed = antfarm_ui.stats.screens,
        petitions_answered = antfarm_ui.stats.petitions,
        unpauses = antfarm_ui.stats.unpauses,
        failures = antfarm_ui.stats.failures,
        log = entries,
    }
end

-- DFHack's `confirm` plugin adds modal are-you-sure dialogs. df-ai runs
-- `disable confirm` at startup for exactly this reason: every one of them is a
-- screen an unattended fort would sit on.
function disable_confirm_plugin()
    pcall(dfhack.run_command, 'disable confirm')
end

dfhack.onStateChange.antfarm_ui = function(code)
    if code == SC_MAP_UNLOADED or code == SC_WORLD_UNLOADED then
        antfarm_ui.focus = nil
        antfarm_ui.attempts = 0
        antfarm_ui.popup_attempts = 0
        antfarm_ui.popup_since = 0
        antfarm_ui.seen_popups = {}
        antfarm_ui.gave_up = {}
        antfarm_ui.pending = nil
        antfarm_ui.pending_popup = nil
        antfarm_ui.was_paused = false
        antfarm_ui.paused_since = 0
        antfarm_ui.last_pause_reason = nil
        antfarm_ui.camera_unit = -1
        antfarm_ui.driver = nil
        antfarm_ui.driver_name = nil
        antfarm_ui.driver_budget = 0
        antfarm_ui.driver_retry_at = 0
    end
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'status' then
    local r = report()
    print('antfarm_ui:')
    print('  current screen:   ' .. r.screen .. '  (' .. r.focus .. ')')
    print('  drivable:         ' .. tostring(r.drivable) ..
          (r.paused and '   [PAUSED: ' .. r.pause_kind .. ' ' .. r.pause_type .. ']' or ''))
    print('  popup dismissal:  ' .. (r.popups_enabled and 'ON' or 'off'))
    print('  screen dismissal: ' .. (r.screens_enabled and 'ON' or 'off (no client attached)'))
    print('  auto-unpause:     ' .. (r.auto_unpause and 'ON' or 'off'))
    print(('  pending:          %d popup(s), %d petition(s)')
          :format(r.pending_popups, r.pending_petitions))
    print(('  handled so far:   %d popup(s), %d screen(s), %d petition(s), %d unpause(s), %d failure(s)')
          :format(r.popups_dismissed, r.screens_dismissed, r.petitions_answered,
                  r.unpauses, r.failures))
    if #r.log == 0 then
        print('  nothing logged yet.')
    else
        print('  recent:')
        for _, e in ipairs(r.log) do print(('    [%s] %s'):format(e.kind, e.text)) end
    end
elseif verb == 'screen' then
    local scr, tname, focus = current_screen()
    local ok, why = actionable(scr, tname)
    local h = scr and handler_for(scr)
    print('antfarm_ui: ' .. tostring(tname) .. '  focus=' .. tostring(focus))
    print('  recognised:  ' .. (h and h.why or 'no -- would use the generic LEAVESCREEN ladder'))
    print('  dismissable: ' .. (ok and 'yes' or ('no -- ' .. tostring(why))))
    print('  drivable:    ' .. tostring(is_dwarfmode()))
    print(('  pending mega-announcement popups: %d'):format(popup_count()))
    for _, t in ipairs(pending_popups()) do print('    * ' .. t) end
    if scr and df.viewscreen_textviewerst:is_instance(scr) then
        print('  text: ' .. clip(textviewer_text(scr), 600))
    end
elseif verb == 'dismiss' then
    local n = popup_count()
    if n > 0 then
        local scr = select(1, current_screen())
        if scr then pcall(gui.simulateInput, scr, 'CLOSE_MEGA_ANNOUNCEMENT') end
        print(('antfarm_ui: sent Enter to %d popup(s); %d left'):format(n, popup_count()))
    else
        local ok, what = dismiss_current(true)
        print('antfarm_ui: ' .. (ok and ('sent ' .. tostring(what))
                                   or ('did nothing -- ' .. tostring(what))))
    end
elseif verb == 'unpause' then
    print('antfarm_ui: ' .. (unpause() and 'unpaused' or 'still blocked'))
elseif verb == 'petitions' then
    print(('antfarm_ui: %d pending petition(s)'):format(petition_count()))
    if not check_petitions() then print('  nothing to do (or a driver is already running)') end
elseif verb == 'on' then
    set_screens_enabled(true)
    print('antfarm_ui: viewscreen dismissal ON')
elseif verb == 'off' then
    set_screens_enabled(false)
    print('antfarm_ui: viewscreen dismissal off')
else
    print('usage: antfarm_ui [status|screen|dismiss|unpause|petitions|on|off]')
end
