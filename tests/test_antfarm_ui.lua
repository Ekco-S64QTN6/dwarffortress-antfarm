-- Tests for antfarm_ui.lua, the modal/popup watchdog.
--
-- Run: lua tests/test_antfarm_ui.lua   (from the repository root)

local stub = dofile('tests/df_stub.lua')
local UI = 'game/hack/scripts/antfarm_ui.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
        return
    end
    print('  ok    ' .. name)
end
local function has(list, want)
    for _, v in ipairs(list) do if v == want then return true end end
    return false
end
local function count(list, want)
    local n = 0
    for _, v in ipairs(list) do if v == want then n = n + 1 end end
    return n
end

-- Fresh world + freshly loaded module for each test: the script keeps state in
-- a global that persists across reloads inside DF, which is exactly what we do
-- NOT want leaking between cases.
local function fresh()
    local w = stub.new()
    local env = stub.load(w, UI)
    return w, env
end

-- Drive `tick()` for a simulated duration, advancing the clock in poll-sized
-- steps so the grace periods and RETRY_MS backoff behave as they do in game.
local function run(env, w, ms, step)
    step = step or 200
    local results = {}
    for _ = 1, math.max(1, math.floor(ms / step)) do
        w.advance(step)
        table.insert(results, env.tick())
    end
    return results
end

print('antfarm_ui')

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    w.add_popup('You have discovered an expansive cavern!')
    local results = run(env, w, 3000)

    local reported
    for _, r in ipairs(results) do
        for _, t in ipairs(r.popups or {}) do reported = t end
    end
    check('cavern popup is dismissed', env.popup_count() == 0,
          ('%d popup(s) left'):format(env.popup_count()))
    check('dismissal uses CLOSE_MEGA_ANNOUNCEMENT',
          has(w.keys_pressed(), 'CLOSE_MEGA_ANNOUNCEMENT'),
          table.concat(w.keys_pressed(), ','))
    check('popup text is reported before it is cleared',
          reported == 'You have discovered an expansive cavern!', tostring(reported))
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    w.add_popup('one')
    w.add_popup('two')
    w.add_popup('three')
    run(env, w, 6000)
    check('a queue of popups is drained completely', env.popup_count() == 0,
          ('%d left'):format(env.popup_count()))
end

-- ---------------------------------------------------------------- --
do
    -- The failure df-ai would hang on: the key does nothing.
    local w, env = fresh()
    w.on_key = function() end          -- swallow every keystroke
    w.add_popup('unkillable')
    run(env, w, 8000)
    check('a popup the key cannot clear is force-cleared, not looped on',
          env.popup_count() == 0, ('%d left'):format(env.popup_count()))
    check('the force-clear is recorded as a failure',
          env.report().failures >= 1, tostring(env.report().failures))
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.push{vtype = 'viewscreen_topicmeetingst'}
    run(env, w, 6000)
    check('the liaison meeting screen is closed', w.top().vtype == 'viewscreen_dwarfmodest',
          w.top().vtype)
    check('it is closed with OPTION1, as df-ai does', has(w.keys_pressed(), 'OPTION1'),
          table.concat(w.keys_pressed(), ','))
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.push{vtype = 'viewscreen_requestagreementst'}
    run(env, w, 6000)
    check('a caravan agreement screen is closed',
          w.top().vtype == 'viewscreen_dwarfmodest', w.top().vtype)
end

-- ---------------------------------------------------------------- --
do
    -- Where df-ai stops: an unrecognised screen. It logs and leaves the fort
    -- frozen; we close it after a longer grace.
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.push{vtype = 'viewscreen_unitst'}
    run(env, w, 5000)
    check('an unknown screen is left alone during its grace period',
          w.top().vtype == 'viewscreen_unitst', w.top().vtype)
    run(env, w, 20000)
    check('an unknown screen is eventually dismissed anyway',
          w.top().vtype == 'viewscreen_dwarfmodest', w.top().vtype)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.push{vtype = 'viewscreen_titlest'}
    run(env, w, 60000)
    check('the title screen is never touched', w.top().vtype == 'viewscreen_titlest',
          w.top().vtype)
    check('no keys were sent to it', #w.keys == 0, table.concat(w.keys_pressed(), ','))
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.push{vtype = 'viewscreen_setupdwarfgamest'}
    run(env, w, 60000)
    check('the embark screen is never touched',
          w.top().vtype == 'viewscreen_setupdwarfgamest', w.top().vtype)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    -- Dismissal disabled: this is the bridge idle / human playing case.
    w.push{vtype = 'viewscreen_topicmeetingst'}
    run(env, w, 30000)
    check('screens are left alone while no client is driving',
          w.top().vtype == 'viewscreen_topicmeetingst', w.top().vtype)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.on_key = function() end          -- keys do nothing...
    w.dfhack.screen.dismiss = function() end   -- ...and neither does dismiss
    w.push{vtype = 'viewscreen_textviewerst'}
    local before = #w.keys
    run(env, w, 30000)
    local after_giveup = #w.keys
    run(env, w, 30000)
    check('a screen that will not close is given up on, not hammered forever',
          #w.keys == after_giveup, ('%d -> %d keys'):format(after_giveup, #w.keys))
    check('giving up is recorded', env.report().failures >= 1)
    check('it tried a bounded number of times', after_giveup - before <= 7,
          tostring(after_giveup - before))
end

-- ---------------------------------------------------------------- --
do
    -- Pause classification by announcement TYPE, replacing text keywords.
    local w, env = fresh()
    w.add_announcement('MEGABEAST_ARRIVAL', 'A dragon has come!', {pauses = true})
    w.df.global.pause_state = true
    local cause = env.pause_cause()
    check('the pausing announcement is identified by type',
          cause and cause.type == 'MEGABEAST_ARRIVAL', cause and cause.type or 'nil')
    local kind = env.classify_pause(cause)
    check('a megabeast is classified as danger', kind == 'danger', kind)
end

do
    local w, env = fresh()
    w.add_announcement('MIGRANT_ARRIVAL', 'Some migrants have arrived.', {pauses = true})
    w.df.global.pause_state = true
    local kind = env.classify_pause(env.pause_cause())
    check('migrants are classified as notable, not danger', kind == 'notable', kind)
end

do
    local w, env = fresh()
    w.add_announcement('AMBUSH_SNATCHER', 'A snatcher!', {pauses = true})
    w.df.global.pause_state = true
    local kind = env.classify_pause(env.pause_cause())
    check('any AMBUSH_* type is danger', kind == 'danger', kind)
end

-- ---------------------------------------------------------------- --
do
    -- B-05: the old keyword check kept the fort paused forever once a siege
    -- announcement became the newest one and stopped changing.
    local w, env = fresh()
    w.add_announcement('MEGABEAST_ARRIVAL', 'A dragon has come!', {pauses = true})
    w.df.global.pause_state = true
    run(env, w, 20000)
    check('the game is unpaused again after a danger hold',
          w.df.global.pause_state == false, 'still paused')
end

do
    local w, env = fresh()
    w.add_announcement('SEASON_SPRING', 'Spring has arrived.', {pauses = true})
    w.df.global.pause_state = true
    run(env, w, 4000)
    check('a routine pause is cleared quickly', w.df.global.pause_state == false,
          'still paused')
end

-- ---------------------------------------------------------------- --
do
    -- Paused with a popup up: the popup must go first, then the pause.
    local w, env = fresh()
    w.df.global.pause_state = true
    w.add_popup('You have struck adamantine!')
    run(env, w, 20000)
    check('a popup blocking a pause is cleared', env.popup_count() == 0)
    check('and the game then unpauses', w.df.global.pause_state == false)
end

-- ---------------------------------------------------------------- --
do
    -- The df-ai backstop: stuck with no identifiable cause at all.
    local w, env = fresh()
    w.df.global.pause_state = true
    w.on_key = function() end          -- D_PAUSE does nothing
    run(env, w, 25000)
    check('a pause with no cause is force-cleared by the watchdog',
          w.df.global.pause_state == false, 'still paused')
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    w.units[42] = {id = 42, pos = {x = 1, y = 2, z = 3}}
    env.set_camera_unit(42)
    w.df.global.ui.follow_unit = -1     -- an announcement dropped the lock
    w.df.global.pause_state = true
    run(env, w, 6000)
    check('the camera lock is restored after an unpause',
          w.df.global.ui.follow_unit == 42, tostring(w.df.global.ui.follow_unit))
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    check('is_dwarfmode is true on a clean map', env.is_dwarfmode() == true)
    w.add_popup('blocked')
    check('is_dwarfmode is false while a popup is queued', env.is_dwarfmode() == false)
    w.df.global.world.status.popups:resize(0)
    w.df.global.ui.main.mode = w.df.ui_sidebar_mode.Build
    check('is_dwarfmode is false in a sidebar mode', env.is_dwarfmode() == false)
    w.df.global.ui.main.mode = 0
    w.push{vtype = 'viewscreen_unitst'}
    check('is_dwarfmode is false under another viewscreen', env.is_dwarfmode() == false)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    w.df.global.world.status.flags.combat = true
    w.df.global.world.status.flags.hunting = true
    run(env, w, 400)
    check('the combat/hunting report indicators are cleared',
          w.df.global.world.status.flags.combat == false
          and w.df.global.world.status.flags.hunting == false)
end

-- ---------------------------------------------------------------- --
do
    -- Petitions: accept residency, reject what we cannot build.
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.df.global.ui.petitions:push(1)
    local petitions = {
        vtype = 'viewscreen_petitionsst',
        can_manage = 1,
        cursor = 0,
        list = stub.vector{
            {details = stub.vector{{type = w.df.agreement_details_type.Residency}}},
        },
    }
    w.on_key = function(scr, key)
        if key == 'D_PETITIONS' then w.push(petitions) end
        if key == 'OPTION1' or key == 'OPTION2' then
            petitions.list:resize(0)
            w.df.global.ui.petitions:resize(0)
        end
        if key == 'LEAVESCREEN' and w.top().vtype == 'viewscreen_petitionsst' then w.pop() end
    end
    run(env, w, 6000)
    check('a residency petition is accepted', has(w.keys_pressed(), 'OPTION1'),
          table.concat(w.keys_pressed(), ','))
    check('the petitions screen is closed again',
          w.top().vtype == 'viewscreen_dwarfmodest', w.top().vtype)
    check('the answer is counted', env.report().petitions_answered >= 1)
end

do
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.df.global.ui.petitions:push(1)
    local petitions = {
        vtype = 'viewscreen_petitionsst',
        can_manage = 1, cursor = 0,
        list = stub.vector{
            {details = stub.vector{{type = w.df.agreement_details_type.Parley}}},
        },
    }
    w.on_key = function(scr, key)
        if key == 'D_PETITIONS' then w.push(petitions) end
        if key == 'OPTION1' or key == 'OPTION2' then
            petitions.list:resize(0); w.df.global.ui.petitions:resize(0)
        end
        if key == 'LEAVESCREEN' and w.top().vtype == 'viewscreen_petitionsst' then w.pop() end
    end
    run(env, w, 6000)
    check('a petition we cannot honour is rejected rather than left to lapse',
          has(w.keys_pressed(), 'OPTION2'), table.concat(w.keys_pressed(), ','))
end

do
    -- A driver that goes wrong must not wedge the watchdog.
    local w, env = fresh()
    env.set_screens_enabled(true)
    w.df.global.ui.petitions:push(1)
    w.on_key = function() end   -- D_PETITIONS never opens the screen
    run(env, w, 30000)
    check('a driver that never gets its screen gives up',
          env.report().driver == '', env.report().driver)
    check('and the failure is recorded', env.report().failures >= 1)
    -- The watchdog must still work afterwards.
    w.on_key = nil
    w.add_popup('later popup')
    run(env, w, 4000)
    check('the watchdog still works after a driver failure', env.popup_count() == 0)
end

-- ---------------------------------------------------------------- --
do
    local w, env = fresh()
    w.map_loaded = false
    local ok = pcall(function() run(env, w, 2000) end)
    check('tick survives with no map loaded', ok)
end

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
