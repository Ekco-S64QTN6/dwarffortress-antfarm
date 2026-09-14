-- antfarm_legends.lua
-- exportlegends, writing into <repo>/legends/ instead of the game directory.
--
-- DFHack's own `exportlegends` drops a dated folder plus a pile of maps and
-- XML wherever DF's working directory happens to be, which is the game
-- directory -- so a world export scatters a dozen files in among the game's own
-- files and they are easy to mistake for part of the install.
--
-- exportlegends takes an optional output folder as its second argument, so this
-- is a thin wrapper that always passes ../legends. antfarm/legends_parser.py
-- looks there first.
--
-- Must be run from the legends screen, same as exportlegends itself:
--   1. abandon or retire the fort, or use a copy of the save
--   2. main menu -> Legends -> pick the world
--   3. in the DFHack console:  antfarm_legends
--
-- Then build the searchable database the dashboard reads:
--   .venv/bin/python -m antfarm.legends_parser

--@module = true

local OUT_DIR = '../legends'

function export(what)
    what = what or 'all'
    -- The folder has to exist before exportlegends chdir()s into it.
    if not dfhack.filesystem.isdir(OUT_DIR) then
        if not dfhack.filesystem.mkdir(OUT_DIR) then
            dfhack.printerr('antfarm_legends: could not create ' .. OUT_DIR)
            return false
        end
    end

    local focus = dfhack.gui.getCurFocus()
    if focus ~= 'legends' and focus ~= 'dfhack/lua/legends' then
        dfhack.printerr('antfarm_legends: this only works from the legends screen.')
        dfhack.printerr('  Abandon or retire the fort, then: main menu -> Legends.')
        dfhack.printerr('  (current screen: ' .. tostring(focus) .. ')')
        return false
    end

    -- Name the run after the world and date so successive exports do not land
    -- on top of each other.
    local name = OUT_DIR
    local ok, save = pcall(function() return df.global.world.cur_savegame.save_dir end)
    if ok and save and save ~= '' then
        name = OUT_DIR .. '/' .. save
    end

    print('antfarm_legends: exporting to ' .. name)
    local ok2, err = pcall(dfhack.run_command, 'exportlegends ' .. what .. ' ' .. name)
    if not ok2 then
        dfhack.printerr('antfarm_legends: export failed: ' .. tostring(err))
        return false
    end
    print('antfarm_legends: done. Build the database with:')
    print('  .venv/bin/python -m antfarm.legends_parser')
    return true
end

if dfhack_flags and dfhack_flags.module then
    return
end

local args = {...}
export(args[1])
