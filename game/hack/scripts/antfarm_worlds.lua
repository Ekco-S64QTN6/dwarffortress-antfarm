-- antfarm_worlds.lua
-- List every world DF can see, and which menu it appears under.
--
-- DF splits saves across two menus and they are easy to confuse:
--   "Continue Playing" -> viewscreen_loadgamest.saves        (worlds WITH a fort)
--   "Start Playing"    -> viewscreen_titlest.start_savegames (worlds with NO fort yet)
-- A freshly generated world (./df -gen ...) has no fortress, so it only ever
-- shows up under "Start Playing".
--
-- Run it on the title screen for the full picture; it also works mid-game and
-- will fall back to listing what is on disk.

--@module = true

local function scan_disk()
    local out = {}
    local ok, entries = pcall(dfhack.filesystem.listdir, 'data/save')
    if not ok or not entries then return out end
    for _, name in ipairs(entries) do
        if name ~= '.' and name ~= '..' and name ~= 'current'
                and dfhack.filesystem.isdir('data/save/' .. name) then
            local has_fort  = dfhack.filesystem.exists('data/save/' .. name .. '/world.sav')
            local has_world = dfhack.filesystem.exists('data/save/' .. name .. '/world.dat')
            table.insert(out, {name = name, fort = has_fort, world = has_world})
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local OUT_FILE = 'antfarm_worlds.txt'
local buf = {}
local function print(...)   -- luacheck: ignore
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts+1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    table.insert(buf, line)
    _G.print(line)
end
local function flush()
    local f = io.open(OUT_FILE, 'w')
    if f then f:write(table.concat(buf, '\n') .. '\n'); f:close() end
end

function list()
    buf = {}
    print('Worlds on disk (data/save):')
    local disk = scan_disk()
    if #disk == 0 then print('  none found') end
    for _, w in ipairs(disk) do
        local menu
        if w.fort then
            menu = 'Continue Playing  (has an active fortress)'
        elseif w.world then
            menu = 'Start Playing     (no fort yet -- embark here)'
        else
            menu = 'UNRECOGNISED      (neither world.sav nor world.dat)'
        end
        print(string.format('  %-14s %s', w.name, menu))
    end

    -- If we are sitting on the title screen, show what DF itself has listed.
    local title = dfhack.gui.getViewscreenByType(df.viewscreen_titlest, 0)
    if title then
        print('')
        local ok = pcall(function()
            print('DF "Start Playing" list (' .. #title.start_savegames .. '):')
            for i = 0, #title.start_savegames - 1 do
                local sg = title.start_savegames[i]
                print(string.format('  [%d] %s', i, tostring(sg.folder_name or sg.world_name or '?')))
            end
        end)
        if not ok then print('  (could not read start_savegames on this build)') end
    else
        print('')
        print('Run this on the title screen to also see DF\'s own "Start Playing" list.')
    end
    flush()
end

if dfhack_flags and dfhack_flags.module then
    return
end

list()
