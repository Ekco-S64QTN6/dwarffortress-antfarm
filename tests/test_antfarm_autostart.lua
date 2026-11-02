-- Tests for the embark-setup step of antfarm_autostart.lua.
-- Run: lua tests/test_antfarm_autostart.lua   (from the repository root)

local stub = dofile('tests/df_stub.lua')
local SCRIPT = 'game/hack/scripts/antfarm_autostart.lua'

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print('  ok    ' .. name)
    else
        fail = fail + 1
        print(('  FAIL  %s%s'):format(name, detail and ('  -- ' .. tostring(detail)) or ''))
    end
end

-- The setup screen as read live: profile loading stays on this one screen, and
-- only fields change.
local function setup_world(opts)
    opts = opts or {}
    local w = stub.new()
    local T = {PlayNow = 0, Prepare = 1, Profile = 2}
    w.df.viewscreen_setupdwarfgamest.T_choice_types = T
    local types, choices = {T.PlayNow, T.Prepare}, {{}, {}}
    for _, title in ipairs(opts.profiles or {'Wiki - miners', 'GORNYS EASY PEASY START'}) do
        table.insert(types, T.Profile)
        table.insert(choices, {name = title})
    end
    local scr = {vtype = 'viewscreen_setupdwarfgamest', mode = 0, choice = 0,
                 show_play_now = 1, embark_prompt = 0, in_problems = 0,
                 points_remaining = 400, problems = stub.vector{},
                 choice_types = stub.vector(types), choices = stub.vector(choices)}
    w.push(scr)
    local state = {}
    w.on_key = function(_, key)
        if key == 'SELECT' and scr.embark_prompt ~= 0 then
            state.embarked = true
        elseif key == 'SELECT' and scr.show_play_now ~= 0 then
            local chosen = scr.choices[scr.choice]
            state.loaded = chosen.name or 'Play Now'
            if chosen.name then
                scr.show_play_now = 0
                scr.points_remaining = opts.left or 13
                if opts.problems then
                    scr.in_problems = 1
                    scr.problems = stub.vector{{value = 'No sand available'}}
                end
            else
                state.embarked = true
            end
        elseif key == 'LEAVESCREEN' then
            scr.in_problems = 0
        elseif key == 'SETUP_EMBARK' then
            if scr.points_remaining > 0 then scr.embark_prompt = 1 else state.embarked = true end
        end
    end
    local pending
    w.dfhack.timeout = function(_, _, fn) pending = fn; return 1 end
    w.dfhack.gui.getCurFocus = function() return 'setupdwarfgame' end
    w.scripts = {}
    local env = stub.load(w, SCRIPT)
    local function run(n)
        env.go()
        for _ = 1, n or 6 do
            if state.embarked or not pending then break end
            local fn = pending
            pending = nil
            fn()
        end
    end
    return w, env, state, run
end

print('antfarm_autostart')

do
    local w, _, state, run = setup_world()
    run()
    check('loads the preset rather than Play Now', state.loaded == 'GORNYS EASY PEASY START', state.loaded)
    check('and embarks', state.embarked)
    local keys = table.concat(w.keys_pressed(), ',')
    check('load, embark, confirm', keys == 'SELECT,SETUP_EMBARK,SELECT', keys)
end

do
    local w, _, state, run = setup_world({problems = true})
    run()
    check('acknowledges what the civ cannot supply, then embarks', state.embarked)
    local keys = table.concat(w.keys_pressed(), ',')
    check('the problem list is closed with Escape',
          keys == 'SELECT,LEAVESCREEN,SETUP_EMBARK,SELECT', keys)
end

do
    local w, _, state, run = setup_world({left = 0})
    run()
    check('no prompt with nothing left over',
          table.concat(w.keys_pressed(), ',') == 'SELECT,SETUP_EMBARK', table.concat(w.keys_pressed(), ','))
    check('embarks all the same', state.embarked)
end

do
    local _, _, state, run = setup_world({profiles = {'Something else'}})
    run()
    check('a missing preset falls back on Play Now', state.loaded == 'Play Now' and state.embarked, state.loaded)
end

do
    local w, env, state, run = setup_world({left = -50})
    run()
    check('over budget is reported, not pressed forever', not state.embarked
          and tostring(env.report().failed):find('over this world', 1, true), env.report().failed)
    check('no embark key sent over budget', table.concat(w.keys_pressed(), ',') == 'SELECT')
end

print(('%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
