-- antfarm_autostart.lua
-- Get from the title screen to a fort that is being played, with nobody at the
-- keyboard.
--
-- WHY
--
-- Everything else assumed a fort was already loaded. Reaching one took a human:
-- pick Start Playing, pick Dwarf Fortress, wait out the region update, choose a
-- site, press Play Now, then dismiss the arrival text. That last one is the
-- worst of them -- the intro is a plain textviewer, and an unattended fort sat
-- on it indefinitely. antfarm_ui *can* dismiss a textviewer, but its screen
-- dismissal is armed only while a client is driving the fort, and at embark time
-- there is no fort to drive yet.
--
-- The sequence below was mapped by walking a live 0.47 title screen, not guessed:
--
--   titlest subpage 0   menu_line_id == Continue (a fort exists) or Start
--   titlest subpage 2   submenu Dwarf Fortress / Adventurer / Legends
--   update_regionst     DF advances world history; can take minutes
--   choose_start_sitest antfarm_embark ranks sites and presses `e`
--   setupdwarfgamest    our embark profile, then SETUP_EMBARK; see drive_setup
--   textviewerst        the arrival text -- dismissed on the first poll
--   dwarfmodest         playing
--
-- HOW
--
-- A screen-driven stepper, not a fixed script: each poll looks at what is
-- actually on screen and does the one thing that screen needs. Waits are
-- therefore unbounded where DF is slow (region update) without any sleep
-- guesses, and a screen that appears out of order is still handled.
--
-- Frames, not ticks: none of this runs while the simulation is stopped, and the
-- title screen has no simulation at all (CLAUDE.md).
--
-- Usage:
--   antfarm_autostart           report what it would do, change nothing
--   antfarm_autostart go        drive the sequence
--   antfarm_autostart stop      give up

--@module = true

local gui = require('gui')

local POLL_FRAMES = 10        -- ~6x a second; the intro goes in well under a second
local MAX_SECONDS = 1800      -- region update on a large world is genuinely slow
local EMBARK_RETRIES = 6      -- candidates to try before giving up on the world

antfarm_autostart = antfarm_autostart or {
    running = false,
    timer = nil,
    started_at = 0,
    last = nil,
    embark_tries = 0,
    notes = {},
    done = false,
    failed = nil,
}

local function note(text)
    if antfarm_autostart.last == text then return end   -- don't log a wait twice
    antfarm_autostart.last = text
    table.insert(antfarm_autostart.notes, 1, text)
    while #antfarm_autostart.notes > 14 do table.remove(antfarm_autostart.notes) end
    print('antfarm_autostart: ' .. text)
end

local function is_a(name, scr)
    local t = df[name]
    if not t then return false end
    local ok, hit = pcall(function() return t:is_instance(scr) end)
    return ok and hit or false
end

-- ---------------------------------------------------------------- --
-- the screens                                                      --
-- ---------------------------------------------------------------- --

-- Title menu: prefer continuing an existing fort over starting a new one.
local function drive_title(scr)
    local subpage = scr.sel_subpage or 0

    if subpage == 0 then
        local want = {
            df.viewscreen_titlest.T_menu_line_id.Continue,
            df.viewscreen_titlest.T_menu_line_id.Start,
        }
        for _, id in ipairs(want) do
            for i = 0, #scr.menu_line_id - 1 do
                if scr.menu_line_id[i] == id then
                    scr.sel_menu_line = i
                    gui.simulateInput(scr, 'SELECT')
                    note(id == want[1] and 'continuing the existing fort'
                                       or 'starting a new fort')
                    return
                end
            end
        end
        antfarm_autostart.failed = 'the title menu offers neither Continue nor Start'
        return
    end

    if subpage == 2 then
        -- Dwarf Fortress / Adventurer / Legends. Index 0 is Dwarf Fortress.
        for i = 0, #scr.submenu_line_id - 1 do
            if scr.submenu_line_id[i] == 0 then
                scr.sel_submenu_line = i
                gui.simulateInput(scr, 'SELECT')
                note('chose Dwarf Fortress mode')
                return
            end
        end
    end

    note('waiting on the title screen (subpage ' .. tostring(subpage) .. ')')
end

-- Continue Playing. DFHack draws its own load screen over the vanilla one, and
-- nothing can be typed into that, so hand the choice to DFHack's load-save, which
-- works from either and clears the overlay itself (verified live, 2026-11-02).
-- Like the launcher, never guess between saves: take the only one, or the one
-- ANTFARM_REGION names, and otherwise stop and say so.
function choose_save(names, want)
    if want and want ~= '' then
        for _, name in ipairs(names) do
            if name == want then return name end
        end
        return nil, ('ANTFARM_REGION=%s is not among the saves: %s'):format(want, table.concat(names, ' '))
    end
    if #names == 1 then return names[1] end
    if #names == 0 then return nil, 'no saves to continue' end
    return nil, ('several saves to continue (%s); set ANTFARM_REGION to choose one')
        :format(table.concat(names, ' '))
end

local LOAD_WAIT_SEC = 300     -- a big fort takes a while, but not forever

local function drive_load()
    if antfarm_autostart.load_requested then
        if os.time() - antfarm_autostart.load_requested > LOAD_WAIT_SEC then
            antfarm_autostart.failed = 'load-save did not bring the fort up'
        end
        return
    end
    local scr = dfhack.gui.getViewscreenByType(df.viewscreen_loadgamest, 0)
    if not scr then
        note('waiting for the save list')
        return
    end
    local names = {}
    for i = 0, #scr.saves - 1 do table.insert(names, scr.saves[i].folder_name) end
    local name, why = choose_save(names, os.getenv('ANTFARM_REGION'))
    if not name then
        antfarm_autostart.failed = why
        return
    end
    antfarm_autostart.load_requested = os.time()
    note('loading ' .. name)
    dfhack.run_command('load-save', name)
end

-- Site selection. antfarm_embark ranks sites and presses `e`; if the press does
-- not take (an occupied tile needs reclaim, not embark) step to the next
-- candidate rather than pressing the same dead key forever.
local function drive_site(scr)
    local em = select(2, pcall(reqscript, 'antfarm_embark'))
    if type(em) ~= 'table' then
        antfarm_autostart.failed = 'antfarm_embark did not load'
        return
    end

    antfarm_autostart.embark_tries = antfarm_autostart.embark_tries + 1
    if antfarm_autostart.embark_tries > EMBARK_RETRIES then
        antfarm_autostart.failed =
            ('no embarkable site after %d attempts'):format(EMBARK_RETRIES)
        return
    end

    if antfarm_autostart.embark_tries == 1 then
        note('choosing an embark site')
        pcall(em.run, nil, nil, false)
    else
        -- Still here, so the last attempt did nothing. Move on.
        note(('embark did not take; trying candidate %d')
            :format(antfarm_autostart.embark_tries))
        pcall(em.browse, 1)
        pcall(em.embark_here)
    end
end

-- "Prepare for the Journey": load a community embark preset from
-- data/init/embark_profiles.txt, falling back on Play Now. Play Now brings 2 picks
-- and 12 drinks and leaves the embark points unspent, the slowest possible start
-- for a fort nobody is minding. Of the presets in that file this one has the most
-- picks of those that also bring a brewer, grower, cook, carpenter, mason and an
-- anvil; on a 1504-point world it leaves 13 points over.
--
-- Mapped on a live 0.47 setup screen (2026-11-02):
--   choices[i].name          profile title, where choice_types[i] == Profile
--   SELECT on a Profile      loads it; show_play_now drops to 0 and
--                            points_remaining is what is left of the budget
--   in_problems = 1          lists what this civ cannot supply (`problems`) and
--                            drops those items; LEAVESCREEN acknowledges it
--   SETUP_EMBARK             embark; with points left over, embark_prompt = 1
--   SELECT on that prompt    confirms it (POST_PREPARE_EMBARK_CONFIRMATION)
PROFILE_TITLE = 'GORNYS EASY PEASY START'

local function find_profile(scr)
    local Profile = df.viewscreen_setupdwarfgamest.T_choice_types.Profile
    for i = 0, #scr.choice_types - 1 do
        if scr.choice_types[i] == Profile then
            local ok, name = pcall(function() return scr.choices[i].name end)
            if ok and name == PROFILE_TITLE then return i end
        end
    end
    return nil
end

local function drive_setup(scr)
    local ok = pcall(function()
        if scr.mode ~= 0 then return end        -- inside a sub-editor; leave it

        if scr.in_problems ~= 0 then
            gui.simulateInput(scr, 'LEAVESCREEN')
            note(('this civ cannot supply %d item(s) in the profile'):format(#scr.problems))
            return
        end

        -- The "points remain" confirmation sits on this same screen.
        if scr.embark_prompt ~= 0 then
            gui.simulateInput(scr, 'SELECT')
            note('confirmed the embark')
            return
        end

        if scr.show_play_now ~= 0 then
            local i = find_profile(scr)
            if i then
                scr.choice = i
                gui.simulateInput(scr, 'SELECT')
                note('loaded the ' .. PROFILE_TITLE .. ' embark profile')
                return
            end
            local PlayNow = df.viewscreen_setupdwarfgamest.T_choice_types.PlayNow
            for j = 0, #scr.choice_types - 1 do
                if scr.choice_types[j] == PlayNow then
                    scr.choice = j
                    gui.simulateInput(scr, 'SELECT')
                    note('no ' .. PROFILE_TITLE .. ' profile; Play Now')
                    return
                end
            end
        end

        -- A profile is loaded, or nothing was offered (a reclaim). DF will not
        -- embark over budget, and pressing the key forever would hide why.
        if scr.points_remaining < 0 then
            antfarm_autostart.failed = ('the %s profile is %d points over this world\'s embark budget'):format(
                PROFILE_TITLE, -scr.points_remaining)
            return
        end
        gui.simulateInput(scr, 'SETUP_EMBARK')
        note('embarking')
    end)
    if not ok then note('could not read the embark profile list') end
end

-- ---------------------------------------------------------------- --
-- the stepper                                                      --
-- ---------------------------------------------------------------- --

local function step()
    if not antfarm_autostart.running then return end

    if os.time() - antfarm_autostart.started_at > MAX_SECONDS then
        antfarm_autostart.failed = 'gave up after ' .. MAX_SECONDS .. 's'
    end
    if antfarm_autostart.failed then
        note('FAILED: ' .. antfarm_autostart.failed)
        antfarm_autostart.running = false
        return
    end

    local ok, scr = pcall(dfhack.gui.getCurViewscreen)
    if ok and scr then
        if is_a('viewscreen_dwarfmodest', scr) then
            -- Reaching dwarfmode is not the same as playing. Anchor the guided
            -- build and turn auto mode on, or the fort stands around doing
            -- nothing: the Python engine only autobuilds when its own heuristic
            -- says the fort looks untouched, and that heuristic reads the build
            -- plan -- which is exactly what is not populated yet on a brand new
            -- embark. `autostart` is idempotent, so an already-anchored fort
            -- just has its auto mode confirmed.
            local ok, bp = pcall(reqscript, 'antfarm_blueprint')
            if ok and type(bp) == 'table' and bp.autostart then
                local started = pcall(bp.autostart)
                note(started and 'anchored the fort and turned the build on'
                             or 'could not start the guided build')
            end
            antfarm_autostart.done = true
            antfarm_autostart.running = false
            note('the fort is live')
            return
        elseif is_a('viewscreen_textviewerst', scr) then
            -- The arrival text, and anything else narrative on the way in. This
            -- is the screen that used to stop an unattended start dead.
            gui.simulateInput(scr, 'LEAVESCREEN')
            note('dismissed the arrival text')
        elseif is_a('viewscreen_setupdwarfgamest', scr) then
            drive_setup(scr)
        elseif is_a('viewscreen_choose_start_sitest', scr) then
            drive_site(scr)
        elseif is_a('viewscreen_update_regionst', scr) then
            note('DF is advancing world history (this takes a while)')
        elseif is_a('viewscreen_loadgamest', scr) then
            drive_load()
        elseif is_a('viewscreen_titlest', scr) then
            drive_title(scr)
        else
            local focus = tostring(dfhack.gui.getCurFocus(true))
            if focus:find('load_screen', 1, true) then
                drive_load()
            else
                note('waiting on ' .. focus)
            end
        end
    end

    antfarm_autostart.timer = dfhack.timeout(POLL_FRAMES, 'frames', step)
end

function go()
    if antfarm_autostart.running then return false, 'already running' end
    antfarm_autostart.running = true
    antfarm_autostart.started_at = os.time()
    antfarm_autostart.embark_tries = 0
    antfarm_autostart.load_requested = nil
    antfarm_autostart.done = false
    antfarm_autostart.failed = nil
    antfarm_autostart.last = nil
    antfarm_autostart.notes = {}
    note('started')
    step()
    return true
end

function stop()
    antfarm_autostart.running = false
    antfarm_autostart.failed = nil
    note('stopped')
end

function report()
    return {
        running = antfarm_autostart.running and true or false,
        done = antfarm_autostart.done and true or false,
        failed = antfarm_autostart.failed,
        screen = tostring(dfhack.gui.getCurFocus(true)),
        notes = antfarm_autostart.notes,
    }
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
local verb = (args[1] or 'status'):lower()

if verb == 'go' then
    local ok, why = go()
    if not ok then print('antfarm_autostart: ' .. tostring(why)) end
elseif verb == 'stop' then
    stop()
else
    local r = report()
    print('antfarm_autostart: screen  = ' .. r.screen)
    print('antfarm_autostart: running = ' .. tostring(r.running)
        .. (r.done and '  (fort is live)' or ''))
    if r.failed then print('antfarm_autostart: failed  = ' .. r.failed) end
    for _, n in ipairs(r.notes) do print('   ' .. n) end
end
